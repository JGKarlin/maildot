import XCTest
@testable import BridgeCore

/// A subscription whose renewal is late must not silently disable Mail Dot. Until Dot renews it, the
/// callback endpoint's own answer decides whether it is still alive.
@MainActor final class SubscriptionRenewalTests: XCTestCase {
    let secret = "whsec_" + Data(repeating:7,count:32).base64EncodedString()
    func store() -> BridgeStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        return BridgeStore(directory:url)
    }
    func params(_ name:String = "mail.settings_requested", url:String = "https://chatgpt.com/test-callback") -> JSONValue {
        ["name":.string(name),"arguments":["queue_id":"personal"],
         "delivery":["mode":"webhook","url":.string(url),"secret":.string(secret)],"ttlMs":120000]
    }
    func expire(_ store:BridgeStore, url:String = "https://chatgpt.com/test-callback", ago seconds:TimeInterval) throws {
        try store.transaction { state in
            for index in state.subscriptions.indices where state.subscriptions[index].callbackURL == url {
                state.subscriptions[index].expiresAt = Date().addingTimeInterval(-seconds)
            }
        }
    }
    /// One settings request, the plainest event Mail Dot sends, stands for any event here. The keep-connected job
    /// counts as confirmed, so that Mail Dot does not add a request of its own to the deliveries being counted.
    func askDot(_ store:BridgeStore) throws {
        try MailSettingsStore(bridgeDirectory:store.directory).transaction {
            $0.keepConnectedConfirmedAt = .now
            _ = try MailSettingsCoordinator.request(.refresh,instruction:"Read actual settings",settings:&$0)
        }
    }
    func event(_ store:BridgeStore) throws -> BridgeEvent {
        try XCTUnwrap(MailSettingsStore(bridgeDirectory:store.directory).read().requests.first).event
    }

    func testOverdueSubscriptionStillReceivesEvents() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        _ = try await hub.subscribe(params())
        try expire(store,ago:3600)
        try askDot(store)
        await hub.pump()
        let event = try event(store)
        XCTAssertNotNil(event.receiptAt)
        XCTAssertEqual(try store.read().subscriptions.count,1)
    }

    func testOverdueSubscriptionRejectedByItsEndpointIsRemovedAndTheEventWaitsForRenewal() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        _ = try await hub.subscribe(params())
        try expire(store,ago:3600)
        try askDot(store)
        await recorder.setEventStatus(410)
        await hub.pump()
        XCTAssertTrue(try store.read().subscriptions.isEmpty)
        let waiting = try event(store)
        XCTAssertEqual(waiting.attempts,0)
        XCTAssertNil(waiting.receiptAt)
        await recorder.setEventStatus(200)
        _ = try await hub.subscribe(params())
        await hub.pump()
        XCTAssertNotNil(try event(store).receiptAt)
    }

    func testSubscriptionOverdueBeyondTheGracePeriodIsNotUsed() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        _ = try await hub.subscribe(params())
        try expire(store,ago:EventHub.renewalGrace + 60)
        try askDot(store)
        await hub.pump()
        let event = try event(store)
        XCTAssertNil(event.receiptAt)
        XCTAssertEqual(event.attempts,0)
        let deliveries = await recorder.eventDeliveries
        XCTAssertEqual(deliveries,0)
    }

    func testEventIsSentToOneSubscriptionEvenWhenTwoAreLive() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        _ = try await hub.subscribe(params(url:"https://chatgpt.com/first"))
        _ = try await hub.subscribe(params(url:"https://chatgpt.com/second"))
        try askDot(store)
        await hub.pump(); await hub.pump()
        let targets = await recorder.eventTargets
        XCTAssertEqual(targets,["https://chatgpt.com/second"])
    }

    func testOverdueSubscriptionSurvivesARateLimitOrOtherTemporaryRefusal() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        _ = try await hub.subscribe(params())
        try expire(store,ago:3600)
        try askDot(store)
        await recorder.setEventStatus(429)
        await hub.pump()
        XCTAssertEqual(try store.read().subscriptions.count,1)
    }

    func testRequestNobodyCouldReceiveExpiresAndIsNotDeliveredLate() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        try askDot(store)
        try MailSettingsStore(bridgeDirectory:store.directory).transaction { $0.requests[0].event.occurredAt = Date().addingTimeInterval(-EventHub.undeliveredLimit - 60) }
        await hub.pump()
        let expired = try event(store)
        XCTAssertEqual(expired.attempts,8)
        XCTAssertEqual(expired.lastError,EventHub.undeliveredMessage)
        _ = try await hub.subscribe(params())
        await hub.pump()
        let deliveries = await recorder.eventDeliveries
        XCTAssertEqual(deliveries,0)
    }

    func testActiveSubscriptionIsUsedInPreferenceToAnOverdueOne() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        _ = try await hub.subscribe(params(url:"https://chatgpt.com/old"))
        _ = try await hub.subscribe(params(url:"https://chatgpt.com/new"))
        try expire(store,url:"https://chatgpt.com/old",ago:3600)
        try askDot(store)
        await hub.pump()
        let targets = await recorder.eventTargets
        XCTAssertEqual(targets,["https://chatgpt.com/new"])
    }

    func testRenewalRemovesSupersededAndDeadSubscriptions() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        _ = try await hub.subscribe(params(url:"https://chatgpt.com/settings-old"))
        _ = try await hub.subscribe(params("mail.workflow_requested",url:"https://chatgpt.com/menu-dead"))
        _ = try await hub.subscribe(params("mail.workflow_requested",url:"https://chatgpt.com/menu-overdue"))
        try expire(store,url:"https://chatgpt.com/settings-old",ago:3600)
        try expire(store,url:"https://chatgpt.com/menu-dead",ago:EventHub.renewalGrace + 60)
        try expire(store,url:"https://chatgpt.com/menu-overdue",ago:3600)
        _ = try await hub.subscribe(params(url:"https://chatgpt.com/settings-new"))
        let remaining = Set(try store.read().subscriptions.map(\.callbackURL))
        XCTAssertEqual(remaining,["https://chatgpt.com/settings-new","https://chatgpt.com/menu-overdue"])
    }

    func testManyRenewalsWithChangingAddressesNeverFillTheStore() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        for index in 0..<15 {
            _ = try await hub.subscribe(params(url:"https://chatgpt.com/callback-\(index)"))
            try expire(store,url:"https://chatgpt.com/callback-\(index)",ago:3600)
        }
        XCTAssertEqual(try store.read().subscriptions.count,1)
    }

    func testBridgeStatusTellsDotWhichSubscriptionsNeedRenewal() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        _ = try await hub.subscribe(params())
        _ = try await hub.subscribe(params("mail.workflow_requested",url:"https://chatgpt.com/menu"))
        try expire(store,url:"https://chatgpt.com/menu",ago:3600)
        try store.transaction { state in
            for index in state.subscriptions.indices where state.subscriptions[index].callbackURL == "https://chatgpt.com/test-callback" {
                state.subscriptions[index].expiresAt = Date().addingTimeInterval(86_000)
            }
        }
        let router = MCPRouter(store:store,statelessTunnel:true)
        let line:JSONValue = ["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"bridge_status","arguments":[:]]]
        let raw = await router.response(try line.text())
        let status = try JSONDecoder().decode(JSONValue.self,from:Data(try XCTUnwrap(raw).utf8))["result"]["structuredContent"]
        let states = Dictionary(uniqueKeysWithValues:(status["subscriptions"].array ?? []).compactMap { item in
            item["event"].string.flatMap { name in item["state"].string.map { (name,$0) } }
        })
        XCTAssertEqual(states,["mail.settings_requested":"active","mail.workflow_requested":"overdue"])
        XCTAssertEqual(status["renewal_needed"],true)
        XCTAssertEqual(status["subscription_count"].integer,1)
        XCTAssertEqual(status["requested_lifetime_ms"].integer,86_400_000)
    }

    func testShortSubscriptionPastHalfItsLifeIsReportedForRenewal() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        for name in EventHub.eventNames { _ = try await hub.subscribe(params(name,url:"https://chatgpt.com/" + name)) }
        // A one-hour subscription with twenty minutes left: still live, but past the point where ChatGPT
        // should have renewed it, so the check must repair it.
        try store.transaction { state in
            for index in state.subscriptions.indices {
                state.subscriptions[index].verifiedAt = Date().addingTimeInterval(-2400)
                state.subscriptions[index].expiresAt = Date().addingTimeInterval(1200)
            }
        }
        let router = MCPRouter(store:store,statelessTunnel:true)
        let line:JSONValue = ["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"bridge_status","arguments":[:]]]
        let raw = await router.response(try line.text())
        let status = try JSONDecoder().decode(JSONValue.self,from:Data(try XCTUnwrap(raw).utf8))["result"]["structuredContent"]
        XCTAssertEqual(status["renewal_needed"],true)
        XCTAssertEqual(Set((status["subscriptions"].array ?? []).compactMap { $0["state"].string }),["overdue"])
        XCTAssertEqual(status["subscription_count"].integer,2)
    }

    func testFreshOneHourSubscriptionIsNotReportedForRenewalAtEveryCheck() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        for name in EventHub.eventNames { _ = try await hub.subscribe(params(name,url:"https://chatgpt.com/" + name)) }
        try store.transaction { state in
            for index in state.subscriptions.indices {
                state.subscriptions[index].verifiedAt = Date().addingTimeInterval(-600)
                state.subscriptions[index].expiresAt = Date().addingTimeInterval(3000)
            }
        }
        let router = MCPRouter(store:store,statelessTunnel:true)
        let line:JSONValue = ["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"bridge_status","arguments":[:]]]
        let raw = await router.response(try line.text())
        let status = try JSONDecoder().decode(JSONValue.self,from:Data(try XCTUnwrap(raw).utf8))["result"]["structuredContent"]
        XCTAssertEqual(status["renewal_needed"],false)
        XCTAssertEqual(Set((status["subscriptions"].array ?? []).compactMap { $0["state"].string }),["active"])
    }
}

extension SubscriptionRenewalTests {
    func status(_ store:BridgeStore,arguments:JSONValue = [:]) async throws -> JSONValue {
        let router = MCPRouter(store:store,statelessTunnel:true)
        let line:JSONValue = ["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"bridge_status","arguments":arguments]]
        let raw = await router.response(try line.text())
        return try JSONDecoder().decode(JSONValue.self,from:Data(try XCTUnwrap(raw).utf8))["result"]["structuredContent"]
    }

    /// ChatGPT asked for an hour, or for nothing, and renewed 70 to 98 times a day. Every grant is now a day.
    func testEverySubscriptionIsGrantedADayWhateverIsAskedFor() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        var asked = params().object!
        for ttl:JSONValue? in [nil,3_600_000,120_000,.null,172_800_000] {
            asked["ttlMs"] = ttl
            let answer = try await hub.subscribe(.object(asked))
            let granted = try XCTUnwrap(store.read().subscriptions.first).expiresAt.timeIntervalSinceNow
            XCTAssertEqual(granted,86_400,accuracy:5,"asked for \(String(describing:ttl))")
            XCTAssertNotNil(answer["refreshBefore"].string)
        }
    }

    /// Dot's check runs every six hours, so a one-day subscription is due for renewal in its last six hours and ten minutes.
    func testOneDaySubscriptionIsDueOnlyWithinOneCheckOfLapsing() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        for name in EventHub.eventNames { _ = try await hub.subscribe(params(name,url:"https://chatgpt.com/" + name)) }
        func states(remaining:TimeInterval) async throws -> Set<String> {
            try store.transaction { state in
                for index in state.subscriptions.indices {
                    state.subscriptions[index].verifiedAt = Date().addingTimeInterval(remaining - 86_400)
                    state.subscriptions[index].expiresAt = Date().addingTimeInterval(remaining)
                }
            }
            return Set((try await status(store)["subscriptions"].array ?? []).compactMap { $0["state"].string })
        }
        var found = try await states(remaining:86_000)
        XCTAssertEqual(found,["active"])
        found = try await states(remaining:7 * 3600)
        XCTAssertEqual(found,["active"],"the next check, six hours on, still finds it live")
        found = try await states(remaining:5 * 3600)
        XCTAssertEqual(found,["overdue"],"it would lapse before the next check")
        XCTAssertEqual(EventHub.renewalLead,DotHandlers.keepConnectedInterval + 600)
    }

    /// The event for a message shared from Mail is retired: it is not listed, not renewed and not sent.
    func testRetiredReplyEventIsRefusedDroppedAndNeverSent() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        do { _ = try await hub.subscribe(params(EventHub.retiredEventName)); XCTFail("the retired event was accepted") } catch {}
        // An installation updated from an earlier build still holds its subscription and a shared message's event.
        try store.transaction { state in
            var old = EventSubscription(id:"sub_old",callbackURL:"https://chatgpt.com/old",secret:secret,expiresAt:Date().addingTimeInterval(3000),verifiedAt:.now)
            old.eventName = EventHub.retiredEventName
            state.subscriptions.append(old)
            let draft = MailDraft(id:1,subject:"Test",sender:"sender@example.invalid",to:["recipient@example.invalid"],cc:[],bcc:[],body:"Synthetic",attachmentCount:0)
            var context = ReplyContext(id:"synthetic",envelope:draft)
            BridgeCoordinator.share(draft,with:&context)
            state.contexts[context.id] = context
        }
        await hub.pump(); await hub.pump()
        let state = try store.read()
        XCTAssertTrue(state.subscriptions.isEmpty)
        XCTAssertEqual(state.contexts["synthetic"]?.event?.attempts,8)
        XCTAssertNil(state.contexts["synthetic"]?.event?.lastError)
        let deliveries = await recorder.eventDeliveries
        XCTAssertEqual(deliveries,0)
        let listed = try await status(store)["subscriptions"].array?.compactMap { $0["event"].string }
        XCTAssertEqual(listed,EventHub.eventNames)
        // Dot can still unsubscribe from it without an error.
        _ = try await hub.unsubscribe(params(EventHub.retiredEventName,url:"https://chatgpt.com/old"))
    }
}

private actor RenewalRecorder {
    private var eventStatus = 200
    private(set) var eventTargets:[String] = []
    var eventDeliveries:Int { eventTargets.count }
    func setEventStatus(_ status:Int) { eventStatus = status }
    func respond(_ request:URLRequest) throws -> (Data,Int) {
        let body = try JSONDecoder().decode(JSONValue.self,from:request.httpBody!)
        if body["type"] == "verification" { return (Data(try JSONValue.object(["challenge":body["challenge"]]).text().utf8),200) }
        eventTargets.append(request.url?.absoluteString ?? "")
        return (Data(),eventStatus)
    }
}
