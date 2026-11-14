import XCTest
@testable import BridgeCore

@MainActor final class MCPTests: XCTestCase {
    func router() throws -> MCPRouter {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return MCPRouter(store: BridgeStore(directory: url))
    }
    func request(_ router: MCPRouter, method: String, params: JSONValue = [:]) async throws -> JSONValue {
        let line: JSONValue = ["jsonrpc":"2.0", "id":1, "method":.string(method), "params":params]
        guard let response = await router.response(try line.text()) else { throw BridgeFailure("No response") }
        return try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
    }
    func testInitializationAdvertisesToolsAndEvents() async throws {
        let router = try router()
        let result = try await request(router, method: "initialize", params: ["protocolVersion":"2025-03-26", "capabilities":[:], "clientInfo":["name":"test","version":"1"]])
        XCTAssertNotNil(result["result"]["capabilities"]["events"].object)
        XCTAssertNotNil(result["result"]["capabilities"]["tools"].object)
    }
    func testModernDiscoveryAdvertisesSupportedVersion() async throws {
        let response = try await request(router(), method: "server/discover")
        XCTAssertEqual(response["result"]["resultType"].string, "complete")
        XCTAssertEqual(response["result"]["supportedVersions"].array, ["2026-07-28"])
    }
    func testMethodsRequireInitialization() async throws {
        let response = try await request(router(), method: "tools/list")
        XCTAssertEqual(response["error"]["code"].integer, -32000)
    }
    func testPrivateTunnelCanResumeCachedSessionAfterHelperRestart() async throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:url) }
        let router=MCPRouter(store:BridgeStore(directory:url),statelessTunnel:true)
        let response=try await request(router,method:"tools/list")
        XCTAssertNil(response["error"].object)
        XCTAssertEqual(response["result"]["resultType"],"complete")
        XCTAssertEqual(response["result"]["tools"].array?.count,19)
        let names=Set(response["result"]["tools"].array?.compactMap{$0["name"].string} ?? [])
        XCTAssertTrue(names.contains("report_scheduled_mail_update"))
        XCTAssertTrue(names.contains("get_scheduled_mail_updates"))
    }
    func testNotificationHasNoResponse() async throws {
        let value = await (try router()).response(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(value)
    }
    func testUnknownMethodIsAnError() async throws {
        let router = try router()
        _ = try await request(router, method: "server/discover")
        let response = try await request(router, method: "arbitrary_script")
        XCTAssertEqual(response["error"]["code"].integer, -32601)
    }
    func testToolCatalogDoesNotExposeArbitraryMailOperations() async throws {
        let router = try router()
        _ = try await request(router, method: "server/discover")
        let result = try await request(router, method: "tools/list")
        let names = result["result"]["tools"].array?.compactMap { $0["name"].string }
        XCTAssertEqual(Set(names ?? []), Set(["bridge_status", "get_active_reply", "report_progress", "propose_reply", "attach_reply_file", "send_reviewed_reply", "get_send_result", "get_mail_settings", "report_mail_settings","native_mail_status","native_mail_list_mailboxes","native_mail_list_messages","native_mail_read_message","get_mail_workflow","report_mail_workflow","ask_owner","close_owner_question","get_scheduled_mail_updates","report_scheduled_mail_update"]))
    }
    func testUnknownToolAndExtraArgumentsAreRefused() async throws {
        let router = try router()
        _ = try await request(router, method: "server/discover")
        let unknown = try await request(router, method: "tools/call", params: ["name":"send_arbitrary_mail","arguments":[:]])
        XCTAssertEqual(unknown["result"]["isError"], true)
        let extra = try await request(router, method: "tools/call", params: ["name":"bridge_status","arguments":["secret":"value"]])
        XCTAssertEqual(extra["result"]["isError"], true)
    }

    func testSettingsReadAndReportRequireAnActualNativeRequest() async throws {
        let router = try router(); _ = try await request(router,method:"initialize")
        let store = await router.store
        let settingsStore = MailSettingsStore(bridgeDirectory:store.directory)
        let pending = try settingsStore.transaction { try MailSettingsCoordinator.request(.refresh,instruction:"Refresh actual accounts and schedules",settings:&$0) }
        let read = try await request(router,method:"tools/call",params:["name":"get_mail_settings","arguments":[:]])
        XCTAssertEqual(read["result"]["structuredContent"]["settings"]["requests"].array?.count,1)
        let bad = try await request(router,method:"tools/call",params:["name":"report_mail_settings","arguments":["request_id":"invented","expected_revision":1,"connections":[],"schedules":[],"outcome":"Read back"]])
        XCTAssertEqual(bad["result"]["isError"],true)
        let good = try await request(router,method:"tools/call",params:["name":"report_mail_settings","arguments":["request_id":.string(pending.id),"expected_revision":1,"stage":"confirmed","result_code":"verified","connections":[],"schedules":[],"outcome":"Read back"]])
        XCTAssertEqual(good["result"]["isError"],false)
        XCTAssertEqual(try settingsStore.read().requests.first?.status,.confirmed)
    }
    func testSettingsRPCDecodesRealProfileScheduleSourcesAndDates() async throws {
        let router=try router(); _ = try await request(router,method:"initialize")
        let store=await router.store
        let settingsStore=MailSettingsStore(bridgeDirectory:store.directory)
        let pending=try settingsStore.transaction { try MailSettingsCoordinator.request(.refresh,instruction:"Complete inventory",settings:&$0) }
        let profile:JSONValue=["id":"profile","email":"owner@example.com","connectionID":"link","provider":"gmail","available":true]
        let source:JSONValue=["kind":"gmail","id":"profile","connectionID":"link","addresses":["owner@example.com","alias@example.com"]]
        let schedule:JSONValue=["id":"job","title":"Review","accountEmails":["owner@example.com","alias@example.com"],"sources":[source],"cadence":"Hourly","conditions":"No sending","trigger":"periodic","timeZone":"Asia/Tokyo","enabled":true,"lastSuccessAt":"2026-11-09T01:00:00Z"]
        let result=try await request(router,method:"tools/call",params:["name":"report_mail_settings","arguments":["request_id":.string(pending.id),"expected_revision":1,"stage":"confirmed","result_code":"verified","connections":[profile],"schedules":[schedule],"outcome":"Actual complete readback"]])
        let detail=try result.text()
        XCTAssertEqual(result["result"]["isError"],false,detail)
        let saved=try settingsStore.read()
        XCTAssertEqual(saved.connections.first?.id,"profile")
        XCTAssertEqual(saved.schedules.first?.sources.first?.connectionID,"link")
        XCTAssertNotNil(saved.schedules.first?.lastSuccessAt)
    }
    func testSettingsQuestionReturnsNativeFormWithoutChangingAccounts() async throws {
        let router=try router(); _ = try await request(router,method:"initialize")
        let store=await router.store
        let settingsStore=MailSettingsStore(bridgeDirectory:store.directory)
        let pending=try settingsStore.transaction { try MailSettingsCoordinator.request(.activate,email:"owner@example.com",instruction:"Set up selected account",settings:&$0) }
        let field:JSONValue=["id":"coverage","label":"Check these messages","kind":"selection","options":["Inbox","All mail"],"required":true]
        let result=try await request(router,method:"tools/call",params:["name":"report_mail_settings","arguments":["request_id":.string(pending.id),"expected_revision":1,"stage":"question","result_code":"needsOwnerInput","form":[field],"connections":[],"schedules":[],"outcome":"Choose account coverage"]])
        XCTAssertEqual(result["result"]["isError"],false)
        let saved=try settingsStore.read()
        XCTAssertEqual(saved.requests.first?.status,.question)
        XCTAssertEqual(saved.requests.first?.form?.first?.options,["Inbox","All mail"])
        XCTAssertTrue(saved.connections.isEmpty)
        XCTAssertNil(saved.requests.first?.question)
    }

    func testSendWithoutNativeReviewQueuesNothing() async throws {
        let router = try router()
        _ = try await request(router,method:"initialize")
        let response = try await request(router,method:"tools/call",params:["name":"send_reviewed_reply","arguments":[
            "context_id":"missing","review_id":"invented","operation_id":.string(UUID().uuidString),
            "approval_text":"Send this reviewed message"]])
        XCTAssertEqual(response["result"]["isError"],true)
        let store = await router.store
        XCTAssertTrue(try store.read().operations.isEmpty)
    }

    func testMalformedJSONUsesParseError() async throws {
        let response = await (try router()).response("not JSON")
        let value = try JSONDecoder().decode(JSONValue.self,from:Data(response!.utf8))
        XCTAssertEqual(value["error"]["code"].integer,-32700)
    }

    func testStatusDoesNotDiscloseCallbackSecrets() async throws {
        let router = try router()
        let store = await router.store
        try store.transaction { state in
            state.subscriptions.append(EventSubscription(id:"test",callbackURL:"https://chatgpt.com/private-callback",secret:"PRIVATE_SECRET",expiresAt:.now.addingTimeInterval(100),verifiedAt:.now))
        }
        _ = try await request(router,method:"initialize")
        let value = try await request(router,method:"tools/call",params:["name":"bridge_status","arguments":[:]])
        let rendered = try value.text()
        XCTAssertFalse(rendered.contains("PRIVATE_SECRET")); XCTAssertFalse(rendered.contains("private-callback"))
    }
}
