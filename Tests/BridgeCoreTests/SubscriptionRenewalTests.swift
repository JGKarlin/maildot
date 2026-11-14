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
    func params(_ name:String = "mail.reply_context_changed", url:String = "https://chatgpt.com/test-callback") -> JSONValue {
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
    func shareSyntheticReply(_ store:BridgeStore) throws {
        try store.transaction { state in
            let draft = MailDraft(id:1,subject:"Test",sender:"sender@example.invalid",to:["recipient@example.invalid"],cc:[],bcc:[],body:"Synthetic",attachmentCount:0)
            var context = ReplyContext(id:"synthetic",envelope:draft)
            BridgeCoordinator.share(draft,with:&context)
            state.contexts[context.id] = context
        }
    }

    func testOverdueSubscriptionStillReceivesEvents() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        _ = try await hub.subscribe(params())
        try expire(store,ago:3600)
        try shareSyntheticReply(store)
        await hub.pump()
        let event = try XCTUnwrap(store.read().contexts["synthetic"]?.event)
        XCTAssertNotNil(event.receiptAt)
        XCTAssertEqual(try store.read().subscriptions.count,1)
    }

    func testOverdueSubscriptionRejectedByItsEndpointIsRemovedAndTheEventWaitsForRenewal() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        _ = try await hub.subscribe(params())
        try expire(store,ago:3600)
        try shareSyntheticReply(store)
        await recorder.setEventStatus(410)
        await hub.pump()
        XCTAssertTrue(try store.read().subscriptions.isEmpty)
        let waiting = try XCTUnwrap(store.read().contexts["synthetic"]?.event)
        XCTAssertEqual(waiting.attempts,0)
        XCTAssertNil(waiting.receiptAt)
        await recorder.setEventStatus(200)
        _ = try await hub.subscribe(params())
        await hub.pump()
        XCTAssertNotNil(try store.read().contexts["synthetic"]?.event?.receiptAt)
    }

    func testSubscriptionOverdueBeyondTheGracePeriodIsNotUsed() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        _ = try await hub.subscribe(params())
        try expire(store,ago:EventHub.renewalGrace + 60)
        try shareSyntheticReply(store)
        await hub.pump()
        let event = try XCTUnwrap(store.read().contexts["synthetic"]?.event)
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
        try shareSyntheticReply(store)
        await hub.pump(); await hub.pump()
        let targets = await recorder.eventTargets
        XCTAssertEqual(targets,["https://chatgpt.com/second"])
    }

    func testOverdueSubscriptionSurvivesARateLimitOrOtherTemporaryRefusal() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        _ = try await hub.subscribe(params())
        try expire(store,ago:3600)
        try shareSyntheticReply(store)
        await recorder.setEventStatus(429)
        await hub.pump()
        XCTAssertEqual(try store.read().subscriptions.count,1)
    }

    func testRequestNobodyCouldReceiveExpiresAndIsNotDeliveredLate() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        try shareSyntheticReply(store)
        try store.transaction { $0.contexts["synthetic"]?.event?.occurredAt = Date().addingTimeInterval(-EventHub.undeliveredLimit - 60) }
        await hub.pump()
        let expired = try XCTUnwrap(store.read().contexts["synthetic"]?.event)
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
        try shareSyntheticReply(store)
        await hub.pump()
        let targets = await recorder.eventTargets
        XCTAssertEqual(targets,["https://chatgpt.com/new"])
    }

    func testRenewalRemovesSupersededAndDeadSubscriptions() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        _ = try await hub.subscribe(params(url:"https://chatgpt.com/message-old"))
        _ = try await hub.subscribe(params("mail.settings_requested",url:"https://chatgpt.com/settings-dead"))
        _ = try await hub.subscribe(params("mail.workflow_requested",url:"https://chatgpt.com/menu-overdue"))
        try expire(store,url:"https://chatgpt.com/message-old",ago:3600)
        try expire(store,url:"https://chatgpt.com/settings-dead",ago:EventHub.renewalGrace + 60)
        try expire(store,url:"https://chatgpt.com/menu-overdue",ago:3600)
        _ = try await hub.subscribe(params(url:"https://chatgpt.com/message-new"))
        let remaining = Set(try store.read().subscriptions.map(\.callbackURL))
        XCTAssertEqual(remaining,["https://chatgpt.com/message-new","https://chatgpt.com/menu-overdue"])
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
        XCTAssertEqual(states,["mail.reply_context_changed":"active","mail.workflow_requested":"overdue","mail.settings_requested":"missing"])
        XCTAssertEqual(status["renewal_needed"],true)
        XCTAssertEqual(status["subscription_count"].integer,1)
        XCTAssertEqual(status["requested_lifetime_ms"].integer,86_400_000)
    }

    func testSubscriptionAboutToLapseBeforeTheNextHourlyCheckIsReportedForRenewal() async throws {
        let store = store(), recorder = RenewalRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        for name in EventHub.eventNames { _ = try await hub.subscribe(params(name,url:"https://chatgpt.com/" + name)) }
        // A one-hour subscription with twenty minutes left: still live, but past the point where ChatGPT
        // should have renewed it, so the hourly check must repair it.
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
        XCTAssertEqual(status["subscription_count"].integer,3)
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
