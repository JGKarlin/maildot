import XCTest
@testable import BridgeCore

final class MailWorkflowCreationStatusTests:XCTestCase {
    private func fixture(_ root:URL) throws -> (MailWorkflowRequest,[MailWorkflowAccount],[NativeMailAccount],NativeCompositionPlan) {
        var profile=MailConnection(id:"profile",email:"owner@example.invalid",connectionID:"link"); profile.observedAt=Date()
        try MailSettingsStore(bridgeDirectory:root).transaction{$0.connections=[profile]}
        let p=MailWorkflowComposition(accountID:"gmail:profile",sender:profile.email,to:["recipient@example.invalid"],cc:[],bcc:[],subject:"Fixture",body:"Unsent synthetic draft.",delivery:.save)
        var request=try MailWorkflowRequest(action:.compose,accountIDs:[p.accountID])
        var report=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"Proposal",items:[])
        report.composition=p; report.composition?.delivery = .save; try request.accept(report)
        try MailWorkflowStore(bridgeDirectory:root).transaction{try $0.enqueue(request,allowedAccountIDs:[p.accountID])}
        let accounts=try MailWorkflowAccount.available(settings:MailSettingsStore(bridgeDirectory:root).read(),native:NativeMailState())
        let native=[NativeMailAccount(id:"owner",name:"Owner",addresses:[p.sender],server:"imap.example.invalid")]
        return (request,accounts,native,try NativeCompositionPlan(request:request,displayedRevision:1,displayed:p,accounts:accounts,nativeAccounts:native))
    }
    func testDotCanDistinguishProposalPendingAttemptAndConfirmedCreation() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let (request,accounts,native,plan)=try fixture(root)
        func status() throws -> JSONValue {try MailWorkflowTools.call("get_mail_workflow",arguments:["request_id":.string(request.id)],bridgeDirectory:root)["native_creation"]}
        XCTAssertEqual(try status()["state"].string,"not_requested")
        let queue=NativeCompositionStore(bridgeDirectory:root)
        let op=try queue.transaction{try $0.enqueue(plan)}
        XCTAssertEqual(try status()["state"].string,"pending")
        _=try queue.transaction{$0.claimNext()}
        XCTAssertEqual(try status()["state"].string,"unconfirmed")
        let p=plan.composition
        try queue.transaction {
            try $0.consume(op.id,request:request,accounts:accounts,nativeAccounts:native)
            try $0.complete(op.id,draft:MailDraft(id:42,subject:p.subject,sender:p.sender,to:p.to,cc:p.cc,bcc:p.bcc,body:p.body,attachmentCount:0))
        }
        let confirmed=try status()
        XCTAssertEqual(confirmed["state"].string,"created")
        XCTAssertEqual(confirmed["proposal_revision"].integer,1)
        XCTAssertEqual(confirmed["grants_send_authority"],false)
        XCTAssertEqual(confirmed["is_current_draft_snapshot"],false)
        XCTAssertNil(confirmed["body"].string)
        XCTAssertNil(confirmed["draft"].object)
    }
    func testCreationResultIsUnavailableAfterAccountRevocationOrRequestDismissal() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let (request,_,_,plan)=try fixture(root)
        _=try NativeCompositionStore(bridgeDirectory:root).transaction{try $0.enqueue(plan)}
        try MailSettingsStore(bridgeDirectory:root).transaction{$0.connections[0].available=false}
        XCTAssertThrowsError(try MailWorkflowTools.call("get_mail_workflow",arguments:["request_id":.string(request.id)],bridgeDirectory:root))
        try MailSettingsStore(bridgeDirectory:root).transaction{$0.connections[0].available=true}
        try MailWorkflowStore(bridgeDirectory:root).transaction{try $0.dismiss(request.id)}
        XCTAssertThrowsError(try MailWorkflowTools.call("get_mail_workflow",arguments:["request_id":.string(request.id)],bridgeDirectory:root))
    }
    func testFailedCreationIsNotReportedAsSuccess() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let (request,_,_,plan)=try fixture(root)
        try NativeCompositionStore(bridgeDirectory:root).transaction {
            let op=try $0.enqueue(plan); _=$0.claimNext(); $0.fail(op.id,error:"Outcome uncertain; inspect Mail")
        }
        let response=try MailWorkflowTools.call("get_mail_workflow",arguments:["request_id":.string(request.id)],bridgeDirectory:root)
        XCTAssertEqual(response["native_creation"]["state"].string,"failed")
        XCTAssertEqual(response["native_creation"]["error"].string,"Outcome uncertain; inspect Mail")
    }
}
