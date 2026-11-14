import XCTest
@testable import BridgeCore

final class NativeCompositionPlanTests:XCTestCase {
    private func fixture() throws -> (MailWorkflowRequest,MailWorkflowComposition,[MailWorkflowAccount],[NativeMailAccount]) {
        let composition=MailWorkflowComposition(accountID:"gmail:profile",sender:"owner@example.com",to:["recipient@example.com"],cc:[],bcc:[],subject:"Synthetic draft",body:"Not sent.",delivery:.save)
        var request=try MailWorkflowRequest(action:.compose,accountIDs:[composition.accountID])
        var report=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"Proposal",items:[])
        report.composition=composition; try request.accept(report)
        let account=MailWorkflowAccount(id:composition.accountID,label:"Owner",route:"gmail",sourceID:"profile",connectionID:"connection",senderAddresses:[composition.sender])
        let native=NativeMailAccount(id:"native-owner",name:"Owner",addresses:[composition.sender],server:"imap.gmail.com")
        return (request,composition,[account],[native])
    }

    func testPlanBindsDisplayedProposalAndUnambiguousNativeAccount() throws {
        let (request,proposal,accounts,native)=try fixture()
        let plan=try NativeCompositionPlan(request:request,displayedRevision:1,displayed:proposal,accounts:accounts,nativeAccounts:native)
        XCTAssertEqual(plan.nativeAccountID,"native-owner")
        XCTAssertEqual(plan.requestID,request.id)
        XCTAssertNoThrow(try plan.validate(request:request,accounts:accounts,nativeAccounts:native))
        XCTAssertThrowsError(try NativeCompositionPlan(request:request,displayedRevision:0,displayed:proposal,accounts:accounts,nativeAccounts:native))
        var edited=proposal; edited.body="Changed after display"
        XCTAssertThrowsError(try NativeCompositionPlan(request:request,displayedRevision:1,displayed:edited,accounts:accounts,nativeAccounts:native))
    }

    func testRevokedSenderAndMissingOrAmbiguousNativeMappingRefuseCreation() throws {
        let (request,proposal,accounts,native)=try fixture()
        let plan=try NativeCompositionPlan(request:request,displayedRevision:1,displayed:proposal,accounts:accounts,nativeAccounts:native)
        XCTAssertThrowsError(try plan.validate(request:request,accounts:[],nativeAccounts:native))
        XCTAssertThrowsError(try plan.validate(request:request,accounts:accounts,nativeAccounts:[]))
        var duplicate=native[0]; duplicate.id="other-account"
        XCTAssertThrowsError(try plan.validate(request:request,accounts:accounts,nativeAccounts:native+[duplicate]))
        XCTAssertThrowsError(try plan.validate(request:request,accounts:accounts,nativeAccounts:[duplicate]))
        var changed=native[0]; changed.addresses=["other@example.com"]
        XCTAssertThrowsError(try plan.validate(request:request,accounts:accounts,nativeAccounts:[changed]))
    }

    func testReadbackMustMatchAllProposedFieldsAndContainNoAttachments() throws {
        let (request,proposal,accounts,native)=try fixture()
        let plan=try NativeCompositionPlan(request:request,displayedRevision:1,displayed:proposal,accounts:accounts,nativeAccounts:native)
        let draft=MailDraft(id:42,subject:proposal.subject,sender:proposal.sender,to:proposal.to,cc:[],bcc:[],body:proposal.body,attachmentCount:0)
        XCTAssertNoThrow(try plan.validateCreated(draft))
        var changed=draft; changed.body += "Default signature"
        XCTAssertThrowsError(try plan.validateCreated(changed))
        changed=draft; changed.bcc=["unexpected@example.com"]
        XCTAssertThrowsError(try plan.validateCreated(changed))
        changed=draft; changed.sender="other@example.com"
        XCTAssertThrowsError(try plan.validateCreated(changed))
        changed=draft; changed.attachmentCount = -1
        XCTAssertThrowsError(try plan.validateCreated(changed))
        changed=draft; changed.id = -1
        XCTAssertThrowsError(try plan.validateCreated(changed))
    }

    func testNativeRouteCannotUseASharedSenderOrDifferentAccount() throws {
        let (_,original,_,native)=try fixture()
        var proposal=original; proposal.accountID="mail:native-owner"
        var request=try MailWorkflowRequest(action:.compose,accountIDs:[proposal.accountID])
        var report=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"Proposal",items:[])
        report.composition=proposal; try request.accept(report)
        let account=MailWorkflowAccount(id:proposal.accountID,label:"Owner",route:"mail",sourceID:"native-owner",connectionID:nil,senderAddresses:[proposal.sender])
        XCTAssertNoThrow(try NativeCompositionPlan(request:request,displayedRevision:1,displayed:proposal,accounts:[account],nativeAccounts:native))
        var other=native[0]; other.id="other"
        XCTAssertThrowsError(try NativeCompositionPlan(request:request,displayedRevision:1,displayed:proposal,accounts:[account],nativeAccounts:[other]))
        XCTAssertThrowsError(try NativeCompositionPlan(request:request,displayedRevision:1,displayed:proposal,accounts:[account],nativeAccounts:native+[other]))
    }
}
