import XCTest
@testable import BridgeCore

/// What Dot keeps in ChatGPT for Mail Dot is brought up to date by the build that is installed, and an unstarted
/// request is announced once more, not three times (connection review, 17 November 2026).
@MainActor final class DotHandlersTests: XCTestCase {
    let secret = "whsec_" + Data(repeating:7,count:32).base64EncodedString()
    func store() -> BridgeStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        return BridgeStore(directory:url)
    }
    func call(_ store:BridgeStore,_ method:String,_ params:JSONValue) async throws -> JSONValue {
        let router = MCPRouter(store:store,statelessTunnel:true)
        let line:JSONValue = ["jsonrpc":"2.0","id":1,"method":.string(method),"params":params]
        let raw = await router.response(try line.text())
        return try JSONDecoder().decode(JSONValue.self,from:Data(try XCTUnwrap(raw).utf8))["result"]
    }
    func status(_ store:BridgeStore,_ arguments:JSONValue = [:]) async throws -> JSONValue {
        try await call(store,"tools/call",["name":"bridge_status","arguments":arguments])["structuredContent"]
    }

    func testDotIsToldToUpdateItsHandlersUntilItReportsThisVersion() async throws {
        let store = store()
        // The hourly task of an earlier build names no version.
        var answer = try await status(store)
        XCTAssertEqual(answer["handler_update"]["version"].integer,DotHandlers.version)
        XCTAssertEqual(answer["handler_update"]["workflow_prompt"].string,DotHandlers.workflowPrompt)
        XCTAssertEqual(answer["handler_update"]["settings_prompt"].string,DotHandlers.settingsPrompt)
        XCTAssertEqual(answer["handler_update"]["keep_connected_prompt"].string,DotHandlers.keepConnectedPrompt)
        XCTAssertTrue(answer["handler_update"]["instruction"].string?.contains("mail.reply_context_changed") == true)
        // Another call soon after, a voice call's for instance, is not told again.
        answer = try await status(store)
        XCTAssertEqual(answer["handler_update"],.null)
        // After the interval it is.
        try store.transaction { $0.handlerUpdateOfferedAt = Date().addingTimeInterval(-DotHandlers.updateOfferInterval - 1) }
        answer = try await status(store)
        XCTAssertNotEqual(answer["handler_update"],.null)
        // A task that names an older version is always told.
        answer = try await status(store,["handler_version":.number(Double(DotHandlers.version - 1))])
        XCTAssertNotEqual(answer["handler_update"],.null)
        // Once the task names this version, nobody is told again.
        answer = try await status(store,["handler_version":.number(Double(DotHandlers.version))])
        XCTAssertEqual(answer["handler_update"],.null)
        XCTAssertEqual(try store.read().handlerVersion,DotHandlers.version)
        answer = try await status(store)
        XCTAssertEqual(answer["handler_update"],.null)
    }

    func testHandlersOnlyFetchTheRequestAndTheBuildSuppliesTheRest() async throws {
        let store = store()
        for prompt in [DotHandlers.workflowPrompt,DotHandlers.settingsPrompt] { XCTAssertLessThan(prompt.count,300,prompt) }
        XCTAssertTrue(DotHandlers.workflowPrompt.contains("get_mail_workflow"))
        XCTAssertTrue(DotHandlers.settingsPrompt.contains("get_mail_settings"))
        XCTAssertTrue(DotHandlers.keepConnectedPrompt.contains("handler_version \(DotHandlers.version)"))
        // Every text that sets the connection up names the same prompts, six hours and two events.
        let texts = [MailSettingsCoordinator.keepConnectedInstruction,SetupThroughDot.request(name:"Mail Dot (test)"),
                     SetupThroughDot.continuation(name:"Mail Dot (test)",completed:["started"])]
        for text in texts {
            XCTAssertTrue(text.contains(DotHandlers.keepConnectedPrompt),text)
            XCTAssertTrue(text.contains("every six hours"),text)
            XCTAssertFalse(text.contains("hourly") || text.contains("every hour"),text)
            XCTAssertFalse(text.contains("mail.reply_context_changed"),text)
        }
        for text in texts.dropFirst() {
            XCTAssertTrue(text.contains(DotHandlers.workflowPrompt) && text.contains(DotHandlers.settingsPrompt),text)
        }
        // The plugin lists two events, and bridge_status takes the version.
        let events = try await call(store,"events/list",[:])["events"].array?.compactMap { $0["name"].string }
        XCTAssertEqual(events.map(Set.init),Set(EventHub.eventNames))
        let tools = try await call(store,"tools/list",[:])["tools"].array ?? []
        let bridgeStatus = try XCTUnwrap(tools.first { $0["name"].string == "bridge_status" })
        XCTAssertEqual(bridgeStatus["inputSchema"]["properties"]["handler_version"]["type"].string,"integer")
        XCTAssertFalse(MCPRouter.instructions.contains("three Mail Dot event subscriptions"))
    }

    func testRequestDotDidNotStartIsAnnouncedOnceMoreAfterFiveMinutes() async throws {
        let store = store(), recorder = AnnouncementRecorder()
        let hub = EventHub(store:store,sender:{ try await recorder.respond($0) })
        let workflow = MailWorkflowStore(bridgeDirectory:store.directory)
        try MailSettingsStore(bridgeDirectory:store.directory).transaction {
            var profile = MailConnection(id:"profile",email:"owner@example.invalid",connectionID:"link")
            profile.observedAt = Date(); $0.connections = [profile]; $0.keepConnectedConfirmedAt = .now
        }
        _ = try await hub.subscribe(["name":"mail.workflow_requested","arguments":["queue_id":"personal"],
                                     "delivery":["mode":"webhook","url":"https://chatgpt.com/menu","secret":.string(secret)]])
        let request = try MailWorkflowRequest(action:.status,accountIDs:["gmail:profile"])
        try workflow.transaction { try $0.enqueue(request,allowedAccountIDs:["gmail:profile"]) }
        func received(ago seconds:TimeInterval) throws {
            try workflow.transaction { $0.requests[0].event.receiptAt = Date().addingTimeInterval(-seconds) }
        }
        await hub.pump(); await hub.pump()
        var announced = await recorder.announcements
        XCTAssertEqual(announced,1)
        // Four minutes without a start: nothing more is sent (it was 90 seconds).
        try received(ago:240)
        await hub.pump(); await hub.pump()
        announced = await recorder.announcements
        XCTAssertEqual(announced,1)
        // Past five minutes it is announced again, once.
        try received(ago:EventHub.unreadRedelivery + 5)
        await hub.pump(); await hub.pump()
        announced = await recorder.announcements
        XCTAssertEqual(announced,2)
        XCTAssertEqual(try workflow.read().requests[0].redeliveries,1)
        // And never a third time (it was up to three more).
        try received(ago:3600)
        await hub.pump(); await hub.pump()
        announced = await recorder.announcements
        XCTAssertEqual(announced,2)
    }
}

private actor AnnouncementRecorder {
    private(set) var announcements = 0
    func respond(_ request:URLRequest) throws -> (Data,Int) {
        let body = try JSONDecoder().decode(JSONValue.self,from:request.httpBody!)
        if body["type"] == "verification" { return (Data(try JSONValue.object(["challenge":body["challenge"]]).text().utf8),200) }
        announcements += 1
        return (Data(),200)
    }
}
