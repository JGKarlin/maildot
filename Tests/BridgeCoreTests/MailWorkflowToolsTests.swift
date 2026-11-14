import XCTest
@testable import BridgeCore

final class MailWorkflowToolsTests:XCTestCase {
    func testComposeReportCannotSubstituteAnotherSenderAccount() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let settings=MailSettingsStore(bridgeDirectory:root),workflow=MailWorkflowStore(bridgeDirectory:root)
        try settings.transaction {
            var profile=MailConnection(id:"profile",email:"owner@example.invalid",connectionID:"link")
            profile.observedAt=Date(); $0.connections=[profile]
        }
        let request=try MailWorkflowRequest(action:.compose,accountIDs:["gmail:profile"])
        try workflow.transaction { try $0.enqueue(request,allowedAccountIDs:["gmail:profile"]) }
        var report=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"Proposed message",items:[])
        report.composition=MailWorkflowComposition(accountID:"gmail:profile",sender:"other@example.invalid",to:["recipient@example.invalid"],cc:[],bcc:[],subject:"Meeting",body:"Hello",delivery:.save)
        XCTAssertThrowsError(try MailWorkflowTools.call("report_mail_workflow",arguments:["report":try .encode(report)],bridgeDirectory:root))
        XCTAssertEqual(try workflow.read().requests[0].revision,0)
        report.composition?.sender="owner@example.invalid"; report.composition?.delivery = .save
        _ = try MailWorkflowTools.call("report_mail_workflow",arguments:["report":try .encode(report)],bridgeDirectory:root)
        XCTAssertEqual(try workflow.read().requests[0].report?.composition?.sender,"owner@example.invalid")
    }
    func testFullReadRoundTripsEscapedTextThroughMCPAndStore() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let settings=MailSettingsStore(bridgeDirectory:root),workflow=MailWorkflowStore(bridgeDirectory:root)
        try settings.transaction {
            var profile=MailConnection(id:"profile",email:"owner@example.invalid",connectionID:"link")
            profile.observedAt=Date(); $0.connections=[profile]
        }
        var listing=try MailWorkflowRequest(action:.drafts,accountIDs:["gmail:profile"])
        let item=MailWorkflowItem(id:"draft",accountID:"gmail:profile",sourceID:"source",revision:1,kind:.draft,subject:"Fixture",summary:"Fixture",checkedAt:Date())
        try listing.accept(MailWorkflowReport(requestID:listing.id,expectedRevision:0,stage:.ready,summary:"One draft",items:[item]))
        let read=try MailWorkflowRequest(action:.readFull,accountIDs:["gmail:profile"],itemID:"draft",itemRevision:1,sourceID:"source")
        try workflow.transaction { state in
            try state.enqueue(listing,allowedAccountIDs:["gmail:profile"])
            try state.enqueue(read,allowedAccountIDs:["gmail:profile"])
        }
        let text="Body\n" + String(repeating:"\u{0001}",count:60_000)
        var report=MailWorkflowReport(requestID:read.id,expectedRevision:0,stage:.ready,summary:"Full text",items:[])
        report.readback=MailWorkflowReadback(itemID:"draft",accountID:"gmail:profile",sourceID:"source",itemRevision:1,text:text)
        let router=MCPRouter(store:BridgeStore(directory:root),statelessTunnel:true)
        let request:JSONValue=["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"report_mail_workflow","arguments":["report":try .encode(report)]]]
        let response=await router.response(try request.text())
        let decoded=try JSONDecoder().decode(JSONValue.self,from:Data(try XCTUnwrap(response).utf8))
        XCTAssertNil(decoded["error"].object)
        XCTAssertEqual(decoded["result"]["isError"],false)
        let fetched=try MailWorkflowTools.call("get_mail_workflow",arguments:["request_id":.string(read.id)],bridgeDirectory:root)
        XCTAssertTrue(fetched["request"]["report"]["readback"]["text"].string == text,"Complete text must survive the tool and storage round trip unchanged")
        let fetch:JSONValue=["jsonrpc":"2.0","id":2,"method":"tools/call","params":["name":"get_mail_workflow","arguments":["request_id":.string(read.id)]]]
        let fetchedResponse=await router.response(try fetch.text())
        let fetchedRPC=try JSONDecoder().decode(JSONValue.self,from:Data(try XCTUnwrap(fetchedResponse).utf8))
        XCTAssertEqual(fetchedRPC["result"]["isError"],false)
        XCTAssertTrue(fetchedRPC["result"]["structuredContent"]["request"]["report"]["readback"]["text"].string == text)
        let content=try XCTUnwrap(fetchedRPC["result"]["content"].array?.first?["text"].string)
        let textual=try JSONDecoder().decode(JSONValue.self,from:Data(content.utf8))
        XCTAssertTrue(textual["request"]["report"]["readback"]["text"].string == text)
        let oversized=await router.response(String(repeating:" ",count:524_289))
        let rejected=try JSONDecoder().decode(JSONValue.self,from:Data(try XCTUnwrap(oversized).utf8))
        XCTAssertEqual(rejected["error"]["code"].integer,-32600)
    }
    func testLateReportAfterCancellationCannotRecreateRequest() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let settings=MailSettingsStore(bridgeDirectory:root),workflow=MailWorkflowStore(bridgeDirectory:root)
        try settings.transaction {
            var profile=MailConnection(id:"profile",email:"owner@example.invalid",connectionID:"link")
            profile.observedAt=Date(); $0.connections=[profile]
        }
        let request=try MailWorkflowRequest(action:.status,accountIDs:["gmail:profile"])
        try workflow.transaction { try $0.enqueue(request,allowedAccountIDs:["gmail:profile"]) }
        try workflow.transaction { try $0.dismiss(request.id) }
        let report=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"Late response",items:[])
        XCTAssertThrowsError(try MailWorkflowTools.call("report_mail_workflow",arguments:["report":try .encode(report)],bridgeDirectory:root))
        XCTAssertTrue(try workflow.read().requests.isEmpty)
    }

    func testRevocationWhileDotWorksRejectsReportWithoutChangingSavedProgress() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let settings=MailSettingsStore(bridgeDirectory:root),workflow=MailWorkflowStore(bridgeDirectory:root)
        try settings.transaction {
            var profile=MailConnection(id:"profile",email:"owner@example.invalid",connectionID:"link")
            profile.observedAt=Date(); $0.connections=[profile]
        }
        let request=try MailWorkflowRequest(action:.status,accountIDs:["gmail:profile"])
        try workflow.transaction { try $0.enqueue(request,allowedAccountIDs:["gmail:profile"]) }
        let progress=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.working,summary:"Checking selected account",items:[])
        _ = try MailWorkflowTools.call("report_mail_workflow",arguments:["report":try .encode(progress)],bridgeDirectory:root)
        try settings.transaction { $0.connections[0].available=false }
        let final=MailWorkflowReport(requestID:request.id,expectedRevision:1,stage:.ready,summary:"Late completion",items:[])
        XCTAssertThrowsError(try MailWorkflowTools.call("report_mail_workflow",arguments:["report":try .encode(final)],bridgeDirectory:root))
        let saved=try XCTUnwrap(workflow.read().requests.first)
        XCTAssertEqual(saved.revision,1)
        XCTAssertEqual(saved.stage,.working)
        XCTAssertEqual(saved.report?.summary,"Checking selected account")
    }

    func testStructuredReportAndRevokedAccountRefusal() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let settings=MailSettingsStore(bridgeDirectory:root),workflow=MailWorkflowStore(bridgeDirectory:root)
        try settings.transaction {
            var profile=MailConnection(id:"profile",email:"owner@example.invalid",connectionID:"link")
            profile.observedAt=Date(); $0.connections=[profile]
        }
        let request=try MailWorkflowRequest(action:.status,accountIDs:["gmail:profile"])
        try workflow.transaction { try $0.enqueue(request,allowedAccountIDs:["gmail:profile"]) }
        let fetched=try MailWorkflowTools.call("get_mail_workflow",arguments:["request_id":.string(request.id)],bridgeDirectory:root)
        XCTAssertEqual(fetched["request"]["id"].string,request.id)
        let report=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"Checked; no pending messages",items:[])
        let saved=try MailWorkflowTools.call("report_mail_workflow",arguments:["report":try .encode(report)],bridgeDirectory:root)
        XCTAssertEqual(saved["saved"],true)
        XCTAssertThrowsError(try MailWorkflowTools.call("report_mail_workflow",arguments:["report":try .encode(report)],bridgeDirectory:root))
        try settings.transaction { $0.connections[0].available=false }
        XCTAssertThrowsError(try MailWorkflowTools.call("get_mail_workflow",arguments:["request_id":.string(request.id)],bridgeDirectory:root))
        let index=try MailWorkflowTools.call("get_mail_workflow",arguments:[:],bridgeDirectory:root)
        XCTAssertEqual(index["requests"],[])
    }
}
