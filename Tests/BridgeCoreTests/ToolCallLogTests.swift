import XCTest
@testable import BridgeCore

/// The call log exists to answer "did Dot call, and was it refused?" without storing correspondence.
final class ToolCallLogTests: XCTestCase {
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func send(_ router: MCPRouter, method: String, params: JSONValue = [:]) async throws -> JSONValue {
        let line: JSONValue = ["jsonrpc":"2.0", "id":1, "method":.string(method), "params":params]
        let response = await router.response(try line.text())
        return try JSONDecoder().decode(JSONValue.self, from: Data(try XCTUnwrap(response).utf8))
    }
    private func rawLog(_ root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent("CallLog/calls.json"), encoding: .utf8)
    }
    private func update(scheduleID: String = "schedule") -> ScheduledMailUpdate {
        ScheduledMailUpdate(id:"meeting", scheduleID:scheduleID, runID:"run-1", revision:0, accountIDs:["gmail:profile"],
                            sourceIDs:["message-1"], title:"MARKER-TITLE", summary:"MARKER-SUMMARY", action:.decision,
                            actionText:"MARKER-ACTION", checkedAt:Date(), coverage:"MARKER-COVERAGE")
    }

    func testAcceptedToolCallIsRecordedWithToolNameAndNoDetail() async throws {
        let root = root()
        let router = MCPRouter(store: BridgeStore(directory: root), statelessTunnel: true)
        let before = Date()
        _ = try await send(router, method: "tools/call", params: ["name":"bridge_status", "arguments":[:]])
        let records = try ToolCallLogStore(bridgeDirectory: root).read()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.method, "tools/call")
        XCTAssertEqual(records.first?.tool, "bridge_status")
        XCTAssertEqual(records.first?.outcome, .ok)
        XCTAssertNil(records.first?.detail)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(records.first).at.timeIntervalSince(before), -1)
    }

    func testRefusedScheduledReportRecordsItsReasonButNoneOfItsContent() async throws {
        let root = root()
        let router = MCPRouter(store: BridgeStore(directory: root), statelessTunnel: true)
        let response = try await send(router, method: "tools/call",
                                      params: ["name":"report_scheduled_mail_update", "arguments":["update":try .encode(update())]])
        XCTAssertEqual(response["result"]["isError"], true)
        let record = try XCTUnwrap(ToolCallLogStore(bridgeDirectory: root).read().last)
        XCTAssertEqual(record.tool, "report_scheduled_mail_update")
        XCTAssertEqual(record.outcome, .refused)
        XCTAssertEqual(record.detail, "Link this verified schedule and its email accounts in Mail Dot before reporting updates.")
        XCTAssertFalse(try rawLog(root).contains("MARKER"))
    }

    func testRefusalFromAnyOtherToolRecordsOutcomeWithoutItsMessage() async throws {
        let root = root()
        let router = MCPRouter(store: BridgeStore(directory: root), statelessTunnel: true)
        let response = try await send(router, method: "tools/call", params: ["name":"get_active_reply", "arguments":[:]])
        XCTAssertEqual(response["result"]["isError"], true)
        let record = try XCTUnwrap(ToolCallLogStore(bridgeDirectory: root).read().last)
        XCTAssertEqual(record.tool, "get_active_reply")
        XCTAssertEqual(record.outcome, .refused)
        XCTAssertNil(record.detail)
    }

    func testUnrecognisedToolAndMethodNamesAreNotStoredVerbatim() async throws {
        let root = root()
        let router = MCPRouter(store: BridgeStore(directory: root), statelessTunnel: true)
        _ = try await send(router, method: "tools/call", params: ["name":"MARKER-TOOL", "arguments":[:]])
        _ = try await send(router, method: "MARKER-METHOD")
        let records = try ToolCallLogStore(bridgeDirectory: root).read()
        XCTAssertEqual(records.map(\.method), ["tools/call", "other"])
        XCTAssertEqual(records.first?.tool, "unknown")
        XCTAssertEqual(records.map(\.outcome), [.refused, .refused])
        XCTAssertFalse(try rawLog(root).contains("MARKER"))
    }

    func testSubscriptionAttemptsAndDiscoveryAreRecorded() async throws {
        let root = root()
        let router = MCPRouter(store: BridgeStore(directory: root), statelessTunnel: true)
        _ = try await send(router, method: "tools/list")
        _ = try await send(router, method: "events/subscribe", params: ["name":"mail.workflow_requested"])
        let records = try ToolCallLogStore(bridgeDirectory: root).read()
        XCTAssertEqual(records.map(\.method), ["tools/list", "events/subscribe"])
        XCTAssertEqual(records.map(\.outcome), [.ok, .refused])
        XCTAssertEqual(records.map(\.tool), [nil, nil])
    }

    func testCallsAreMirroredAsPlainLinesOutsideTheProtectedStore() async throws {
        let root = root(), mirror = root.appendingPathComponent("Logs/tool-calls.log")
        let router = MCPRouter(store: BridgeStore(directory: root), statelessTunnel: true, callLogMirror: mirror)
        _ = try await send(router, method: "tools/call", params: ["name":"bridge_status", "arguments":[:]])
        _ = try await send(router, method: "tools/call", params: ["name":"MARKER-TOOL", "arguments":["text":"MARKER-ARGUMENT"]])
        let lines = try String(contentsOf: mirror, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" tools/call bridge_status ok -"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix(" tools/call unknown refused -"), lines[1])
        XCTAssertFalse(lines.joined().contains("MARKER"))
        let mode = try FileManager.default.attributesOfItem(atPath: mirror.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testLogKeepsOnlyTheNewestRecords() throws {
        let store = ToolCallLogStore(bridgeDirectory: root())
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<(ToolCallLogStore.limit + 5) {
            try store.append(ToolCallRecord(at: start.addingTimeInterval(Double(index)), method: "tools/call",
                                            tool: "bridge_status", outcome: .ok, detail: nil))
        }
        let records = try store.read()
        XCTAssertEqual(records.count, ToolCallLogStore.limit)
        XCTAssertEqual(records.first?.at, start.addingTimeInterval(5))
        XCTAssertEqual(records.last?.at, start.addingTimeInterval(Double(ToolCallLogStore.limit + 4)))
    }

    func testMalformedScheduledReportNamesTheFieldInItsRefusal() async throws {
        let root = root()
        let router = MCPRouter(store: BridgeStore(directory: root), statelessTunnel: true)
        var missing = try XCTUnwrap(JSONValue.encode(update()).object)
        missing.removeValue(forKey: "coverage")
        let first = try await send(router, method: "tools/call",
                                   params: ["name":"report_scheduled_mail_update", "arguments":["update":.object(missing)]])
        XCTAssertEqual(first["result"]["isError"], true)
        XCTAssertEqual(first["result"]["content"].array?.first?["text"].string,
                       "Scheduled update is malformed: field \"coverage\" is missing.")
        var invalid = try XCTUnwrap(JSONValue.encode(update()).object)
        invalid["checkedAt"] = "MARKER-NOT-A-DATE"
        let second = try await send(router, method: "tools/call",
                                    params: ["name":"report_scheduled_mail_update", "arguments":["update":.object(invalid)]])
        XCTAssertEqual(second["result"]["content"].array?.first?["text"].string,
                       "Scheduled update is malformed: field \"checkedAt\" has an invalid value.")
        let details = try ToolCallLogStore(bridgeDirectory: root).read().map(\.detail)
        XCTAssertEqual(details, ["Scheduled update is malformed: field \"coverage\" is missing.",
                                 "Scheduled update is malformed: field \"checkedAt\" has an invalid value."])
        XCTAssertFalse(try rawLog(root).contains("MARKER"))
    }
}
