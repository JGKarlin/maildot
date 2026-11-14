import XCTest
@testable import BridgeCore

@MainActor final class EventHubTests: XCTestCase {
    let secret = "whsec_" + Data(repeating:7,count:32).base64EncodedString()
    func store() -> BridgeStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        return BridgeStore(directory:url)
    }
    func params() -> JSONValue {
        ["name":"mail.reply_context_changed","arguments":["queue_id":"personal"],
         "delivery":["mode":"webhook","url":"https://chatgpt.com/test-callback","secret":.string(secret)],"ttlMs":120000]
    }
    func testVerifiedSubscriptionPersistsAndRefreshIsIdempotent() async throws {
        let store = store(), recorder = CallbackRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        let first = try await hub.subscribe(params())
        let second = try await hub.subscribe(params())
        XCTAssertEqual(first["id"],second["id"])
        let restored = try BridgeStore(directory:store.directory).read()
        XCTAssertEqual(restored.subscriptions.count,1)
        XCTAssertLessThanOrEqual(restored.subscriptions[0].expiresAt.timeIntervalSinceNow,120)
        let requests = await recorder.requests
        let verification = try XCTUnwrap(requests.first)
        let id = try XCTUnwrap(verification.value(forHTTPHeaderField:"webhook-id"))
        let time = try XCTUnwrap(Int(verification.value(forHTTPHeaderField:"webhook-timestamp") ?? ""))
        XCTAssertEqual(verification.value(forHTTPHeaderField:"webhook-signature"),
                       try WebhookSecurity.signature(id:id,timestamp:time,body:verification.httpBody!,secret:secret))
    }
    func testBadChallengeNeverActivatesSubscription() async throws {
        let store = store()
        let hub = EventHub(store:store,sender:{ _ in (Data("{\"challenge\":\"wrong\"}".utf8),200) })
        do { _ = try await hub.subscribe(params()); XCTFail("Wrong challenge accepted") } catch {}
        XCTAssertTrue(try store.read().subscriptions.isEmpty)
    }
    func testSettingsEventsAreSeparateFromReplySubscriptions() async throws {
        let store=store(),recorder=CallbackRecorder()
        let hub=EventHub(store:store,sender:{ try await recorder.respond($0) })
        _ = try await hub.subscribe(params())
        let settings=MailSettingsStore(bridgeDirectory:store.directory)
        let pending=try settings.transaction { try MailSettingsCoordinator.request(.refresh,instruction:"Read actual settings",settings:&$0) }
        await hub.pump()
        XCTAssertNil(try settings.read().requests[0].event.receiptAt)
        var settingsObject=params().object!; settingsObject["name"] = "mail.settings_requested"
        let settingsParams=JSONValue.object(settingsObject)
        _ = try await hub.subscribe(settingsParams)
        // A previously loaded compose extension preserves IDs but drops new optional fields.
        try store.transaction { for index in $0.subscriptions.indices { $0.subscriptions[index].eventName=nil } }
        await hub.pump()
        XCTAssertNotNil(try settings.read().requests[0].event.receiptAt)
        let delivered=await recorder.requests.filter { $0.value(forHTTPHeaderField:"webhook-id") == pending.event.id }
        XCTAssertEqual(delivered.count,1)
        let body=try JSONDecoder().decode(JSONValue.self,from:XCTUnwrap(delivered.first?.httpBody))
        XCTAssertEqual(body["name"],"mail.settings_requested")
        XCTAssertEqual(body["data"]["request_id"].string,pending.id)
        _ = try await hub.unsubscribe(settingsParams)
        XCTAssertEqual(try store.read().subscriptions.count,1)
    }
    func testReceiptDoesNotClaimDotReviewedAndUnsubscribeStopsDelivery() async throws {
        let store = store(), recorder = CallbackRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        _ = try await hub.subscribe(params())
        try store.transaction { state in
            let draft = MailDraft(id:1,subject:"Test",sender:"sender@example.invalid",to:["recipient@example.invalid"],cc:[],bcc:[],body:"Synthetic",attachmentCount:0)
            var context = ReplyContext(id:"synthetic",envelope:draft)
            BridgeCoordinator.share(draft,with:&context)
            state.contexts[context.id] = context
        }
        await hub.pump(); await hub.pump()
        let event = try XCTUnwrap(store.read().contexts["synthetic"]?.event)
        XCTAssertNotNil(event.receiptAt)
        XCTAssertNil(event.reviewedAt)
        let delivered = await recorder.requests.filter { $0.value(forHTTPHeaderField:"webhook-id") == event.id }
        XCTAssertEqual(delivered.count,1)
        _ = try await hub.unsubscribe(params())
        XCTAssertTrue(try store.read().subscriptions.isEmpty)
    }
    func testPermanentRejectionIsNotRetried() async throws {
        let store = store(), recorder = CallbackRecorder(eventStatus:410)
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        _ = try await hub.subscribe(params())
        try store.transaction { state in
            var context = ReplyContext(id:"synthetic",envelope:MailDraft(id:1,subject:"",sender:"",to:[],cc:[],bcc:[],body:"",attachmentCount:0))
            context.event = BridgeEvent(); state.contexts[context.id] = context
        }
        await hub.pump(); await hub.pump()
        XCTAssertEqual(try store.read().contexts["synthetic"]?.event?.attempts,8)
        XCTAssertNil(try store.read().contexts["synthetic"]?.event?.receiptAt)
        let count = await recorder.requests.count
        XCTAssertEqual(count,2) // verification + one delivery
    }
    func testDotIsNotToldOfARequestAWorkerHoldsOrAListenerIsAboutToTake() async throws {
        let store=store(),recorder=CallbackRecorder()
        let hub=EventHub(store:store,sender:{try await recorder.respond($0)})
        let workflow=MailWorkflowStore(bridgeDirectory:store.directory)
        try MailSettingsStore(bridgeDirectory:store.directory).transaction {
            var profile=MailConnection(id:"profile",email:"owner@example.invalid",connectionID:"link")
            profile.observedAt=Date(); $0.connections=[profile]
        }
        var object=params().object!; object["name"]="mail.workflow_requested"
        _ = try await hub.subscribe(.object(object))
        let request=try MailWorkflowRequest(action:.check,accountIDs:["gmail:profile"])
        try workflow.transaction { try $0.enqueue(request,allowedAccountIDs:["gmail:profile"]); $0.listenerSeenAt=Date() }
        func delivered() async -> Int { await recorder.requests.filter{$0.value(forHTTPHeaderField:"webhook-id") == request.event.id}.count }
        await hub.pump(); await hub.pump()
        var count=await delivered()
        XCTAssertEqual(count,0,"a listener on the Mac is waiting, so it is given time to take a new request")
        try workflow.transaction { $0.listenerSeenAt=nil; XCTAssertTrue($0.take(request.id,worker:"mac")) }
        await hub.pump(); await hub.pump()
        count=await delivered()
        XCTAssertEqual(count,0,"a worker holds it")
        try workflow.transaction { XCTAssertTrue($0.take(request.id,worker:"mac",now:Date().addingTimeInterval(-MailWorkflowRequest.claimLease-1))) }
        await hub.pump(); await hub.pump()
        count=await delivered()
        XCTAssertEqual(count,1,"with no listener and no worker, Dot is told")
    }
    func testWorkflowDeliveryUsesItsOwnSubscriptionAndCurrentAccountScope() async throws {
        let store=store(),recorder=CallbackRecorder()
        let hub=EventHub(store:store,sender:{try await recorder.respond($0)})
        let settings=MailSettingsStore(bridgeDirectory:store.directory)
        let workflow=MailWorkflowStore(bridgeDirectory:store.directory)
        try settings.transaction {
            var profile=MailConnection(id:"profile",email:"owner@example.invalid",connectionID:"link")
            profile.observedAt=Date(); $0.connections=[profile]
        }
        let request=try MailWorkflowRequest(action:.status,accountIDs:["gmail:profile"])
        try workflow.transaction { try $0.enqueue(request,allowedAccountIDs:["gmail:profile"]) }
        _ = try await hub.subscribe(params())
        await hub.pump()
        XCTAssertNil(try workflow.read().requests[0].event.receiptAt)
        var object=params().object!; object["name"]="mail.workflow_requested"
        _ = try await hub.subscribe(.object(object))
        try store.transaction { for index in $0.subscriptions.indices { $0.subscriptions[index].eventName=nil } }
        try settings.transaction { $0.connections[0].available=false }
        await hub.pump()
        XCTAssertNil(try workflow.read().requests[0].event.receiptAt)
        try settings.transaction { $0.connections[0].available=true }
        await hub.pump(); await hub.pump()
        let event=try workflow.read().requests[0].event
        XCTAssertNotNil(event.receiptAt); XCTAssertNil(event.reviewedAt)
        let delivered=await recorder.requests.filter{$0.value(forHTTPHeaderField:"webhook-id") == request.event.id}
        XCTAssertEqual(delivered.count,1)
        let payload=try JSONDecoder().decode(JSONValue.self,from:XCTUnwrap(delivered.first?.httpBody))
        XCTAssertEqual(payload["name"],"mail.workflow_requested")
        XCTAssertEqual(payload["data"].object?.count,2)
        XCTAssertEqual(payload["data"]["request_id"].string,request.id)
        _ = try await hub.unsubscribe(.object(object))
        XCTAssertEqual(try store.read().subscriptions.count,1)
    }
}

private actor CallbackRecorder {
    var requests:[URLRequest] = []
    let eventStatus:Int
    init(eventStatus:Int = 200) { self.eventStatus = eventStatus }
    func respond(_ request:URLRequest) throws -> (Data,Int) {
        requests.append(request)
        let body = try JSONDecoder().decode(JSONValue.self,from:request.httpBody!)
        if body["type"] == "verification" { return (Data(try JSONValue.object(["challenge":body["challenge"]]).text().utf8),200) }
        return (Data(),eventStatus)
    }
}
