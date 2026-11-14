import XCTest
@testable import BridgeCore

final class NativeCompositionStoreTests:XCTestCase {
    private func fixture() throws -> (MailWorkflowRequest,[MailWorkflowAccount],[NativeMailAccount],NativeCompositionPlan) {
        let p=MailWorkflowComposition(accountID:"mail:owner",sender:"owner@example.com",to:["recipient@example.com"],cc:[],bcc:[],subject:"Synthetic",body:"Not sent.",delivery:.save)
        var request=try MailWorkflowRequest(action:.compose,accountIDs:[p.accountID])
        var report=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"Proposal",items:[])
        report.composition=p; try request.accept(report)
        let accounts=[MailWorkflowAccount(id:p.accountID,label:"Owner",route:"mail",sourceID:"owner",connectionID:nil,senderAddresses:[p.sender])]
        let native=[NativeMailAccount(id:"owner",name:"Owner",addresses:[p.sender],server:"imap.example.com")]
        return (request,accounts,native,try NativeCompositionPlan(request:request,displayedRevision:1,displayed:p,accounts:accounts,nativeAccounts:native))
    }
    func testReopeningCannotClaimOrConsumeAnAttemptTwice() throws {
        let (request,accounts,native,plan)=try fixture()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=NativeCompositionStore(bridgeDirectory:root)
        let op=try store.transaction{try $0.enqueue(plan)}
        XCTAssertEqual(try store.transaction{$0.claimNext()}?.id,op.id)
        let reopened=NativeCompositionStore(bridgeDirectory:root)
        XCTAssertNil(try reopened.transaction{$0.claimNext()})
        try reopened.transaction{try $0.consume(op.id,request:request,accounts:accounts,nativeAccounts:native)}
        XCTAssertThrowsError(try reopened.transaction{try $0.consume(op.id,request:request,accounts:accounts,nativeAccounts:native)})
        XCTAssertThrowsError(try reopened.transaction{try $0.enqueue(plan)})
    }
    func testRevocationOrDismissalStopsConsumption() throws {
        let (request,accounts,native,plan)=try fixture()
        var state=NativeCompositionState(); let op=try state.enqueue(plan)
        _=state.claimNext()
        XCTAssertThrowsError(try state.consume(op.id,request:nil,accounts:accounts,nativeAccounts:native))
        XCTAssertThrowsError(try state.consume(op.id,request:request,accounts:[],nativeAccounts:native))
        XCTAssertNil(state.operations[0].consumedAt)
    }
    func testRestartMarksClaimedWorkForInspectionWithoutReplay() throws {
        let (_,_,_,plan)=try fixture()
        var state=NativeCompositionState(); _=try state.enqueue(plan); _=state.claimNext()
        state.recoverInterrupted()
        XCTAssertNotNil(state.operations[0].error)
        XCTAssertNil(state.claimNext())
        XCTAssertThrowsError(try state.enqueue(plan))
    }
    func testSuccessfulResultRequiresConsumptionAndExactDraft() throws {
        let (request,accounts,native,plan)=try fixture()
        var state=NativeCompositionState(); let op=try state.enqueue(plan); _=state.claimNext()
        let p=plan.composition
        let draft=MailDraft(id:4,subject:p.subject,sender:p.sender,to:p.to,cc:p.cc,bcc:p.bcc,body:p.body,attachmentCount:0)
        XCTAssertThrowsError(try state.complete(op.id,draft:draft))
        try state.consume(op.id,request:request,accounts:accounts,nativeAccounts:native)
        var changed=draft; changed.body="Unexpected"
        XCTAssertThrowsError(try state.complete(op.id,draft:changed))
        try state.complete(op.id,draft:draft)
        XCTAssertEqual(state.operations[0].draft,draft)
        XCTAssertThrowsError(try state.complete(op.id,draft:draft))
        try state.validate()
    }
    func testStateSymlinkIsRejectedAndFailedTransactionRollsBack() throws {
        let (_,_,_,plan)=try fixture()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=NativeCompositionStore(bridgeDirectory:root)
        _=try store.transaction{try $0.enqueue(plan)}
        XCTAssertThrowsError(try store.transaction{state in _=state.claimNext(); throw BridgeFailure("Abort")})
        XCTAssertNil(try store.read().operations[0].claimedAt)
        let file=store.directory.appendingPathComponent("compositions.json")
        let other=root.appendingPathComponent("other.json")
        try FileManager.default.moveItem(at:file,to:other)
        try FileManager.default.createSymbolicLink(at:file,withDestinationURL:other)
        XCTAssertThrowsError(try store.read())
    }
}
