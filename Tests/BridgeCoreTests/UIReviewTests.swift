import XCTest
@testable import BridgeCore

final class UIReviewTests:XCTestCase {
    func testReviewQueueBindsDisplayedRevisionAndEditor() throws {
        let draft=MailDraft(id:-1,subject:"Synthetic",sender:"owner@example.invalid",to:["self@example.invalid"],cc:[],bcc:[],body:"Reviewed",attachmentCount:0)
        let token=UUID().uuidString
        var state=BridgeState(),context=ReplyContext(id:"synthetic",envelope:draft)
        context.snapshot=draft; context.snapshotRevision=3; context.uiEditorToken=token
        state.contexts[context.id]=context
        XCTAssertThrowsError(try BridgeCoordinator.enqueueReview(contextID:context.id,displayedFingerprint:draft.fingerprint,displayedRevision:2,editorToken:token,state:&state))
        XCTAssertThrowsError(try BridgeCoordinator.enqueueReview(contextID:context.id,displayedFingerprint:draft.fingerprint,displayedRevision:3,editorToken:UUID().uuidString,state:&state))
        try BridgeCoordinator.enqueueReview(contextID:context.id,displayedFingerprint:draft.fingerprint,displayedRevision:3,editorToken:token,state:&state)
        XCTAssertEqual(state.operations.count,1)
        XCTAssertEqual(state.operations[0].expectedSnapshotRevision,3)
        XCTAssertEqual(state.operations[0].expectedEditorToken,token)
        let queued=state.operations[0]
        for rebind in [false,true] {
            var changed=context
            if rebind { changed.uiEditorToken=UUID().uuidString } else { changed.snapshotRevision += 1 }
            XCTAssertThrowsError(try BridgeCoordinator.grantUIReview(live:draft,displayedFingerprint:try XCTUnwrap(queued.expectedFingerprint),expectedRevision:try XCTUnwrap(queued.expectedSnapshotRevision),token:try XCTUnwrap(queued.expectedEditorToken),context:&changed))
            XCTAssertNil(changed.review)
        }
    }
    /// Pictures and files in a reply (quoted photos, a signature logo) no longer block its review: the live
    /// count is bound into the review. An unknown live count, or a changed body, still refuses.
    func testNativeReviewBindsTheLiveCountOfPicturesAndFiles() throws {
        for (displayedCount,liveCount) in [(-1,0),(-1,4),(2,4),(0,1)] {
            var draft=MailDraft(id:-1,subject:"Synthetic",sender:"owner@example.invalid",to:["self@example.invalid"],cc:[],bcc:[],body:"Reviewed",attachmentCount:displayedCount)
            let token=UUID().uuidString
            var context=ReplyContext(id:"synthetic",envelope:draft)
            context.snapshot=draft; context.uiEditorToken=token
            let displayed=draft.fingerprint; draft.attachmentCount=liveCount
            try BridgeCoordinator.grantUIReview(live:draft,displayedFingerprint:displayed,expectedRevision:0,token:token,context:&context)
            XCTAssertNotNil(context.review)
            XCTAssertEqual(context.snapshot?.attachmentCount,liveCount)
        }
        for change in 0..<2 {
            var draft=MailDraft(id:-1,subject:"Synthetic",sender:"owner@example.invalid",to:["self@example.invalid"],cc:[],bcc:[],body:"Reviewed",attachmentCount:-1)
            let token=UUID().uuidString
            var context=ReplyContext(id:"synthetic",envelope:draft)
            context.snapshot=draft; context.uiEditorToken=token
            let displayed=draft.fingerprint
            if change == 0 { draft.attachmentCount = -1 } else { draft.attachmentCount=1; draft.body="Edited" }
            XCTAssertThrowsError(try BridgeCoordinator.grantUIReview(live:draft,displayedFingerprint:displayed,expectedRevision:0,token:token,context:&context))
            XCTAssertNil(context.review)
        }
    }
    func testFinalUIConsumptionRequiresCurrentOperationAndContext() throws {
        let draft=MailDraft(id:-1,subject:"Synthetic",sender:"owner@example.invalid",to:["self@example.invalid"],cc:[],bcc:[],body:"Reviewed",attachmentCount:0)
        let token=UUID().uuidString,review=SendReview(draft:draft,editorToken:token)
        var original=BridgeState(),context=ReplyContext(id:"synthetic",envelope:draft)
        context.snapshot=draft; context.snapshotRevision=3; context.uiEditorToken=token; context.review=review
        original.contexts[context.id]=context
        var operation=NativeOperation(contextID:context.id,kind:"send",reviewID:review.id)
        operation.claimedAt=Date(); original.operations=[operation]
        for change in 0..<7 {
            var state=original
            switch change {
            case 0: state.operations[0].claimedAt=nil
            case 1: state.operations[0].result="Already finished"
            case 2: state.operations[0].reviewID=UUID().uuidString
            case 3: state.contexts[context.id]?.snapshotRevision=4
            case 4: state.contexts[context.id]?.snapshot?.body="New edit"
            case 5: state.contexts[context.id]?.uiEditorToken=UUID().uuidString
            default: state.operations[0].kind="apply"
            }
            XCTAssertThrowsError(try BridgeCoordinator.consumeUISend(operationID:operation.id,contextID:context.id,reviewID:review.id,expectedFingerprint:draft.fingerprint,expectedRevision:3,token:token,live:draft,state:&state))
            XCTAssertEqual(state.contexts[context.id]?.review?.consumed,false)
        }
        try BridgeCoordinator.consumeUISend(operationID:operation.id,contextID:context.id,reviewID:review.id,expectedFingerprint:draft.fingerprint,expectedRevision:3,token:token,live:draft,state:&original)
        XCTAssertEqual(original.contexts[context.id]?.review?.consumed,true)
        XCTAssertThrowsError(try BridgeCoordinator.consumeUISend(operationID:operation.id,contextID:context.id,reviewID:review.id,expectedFingerprint:draft.fingerprint,expectedRevision:3,token:token,live:draft,state:&original))
    }
    func testNativeReviewPromotesOnlyVerifiedAttachmentMetadata() throws {
        var displayed=MailDraft(id:-1,subject:"Synthetic",sender:"owner@example.invalid",to:["self@example.invalid"],cc:[],bcc:[],body:"Reviewed",attachmentCount:-1)
        let token=UUID().uuidString
        var context=ReplyContext(id:"synthetic",envelope:displayed)
        context.snapshot=displayed; context.snapshotRevision=3; context.uiEditorToken=token
        context.proposal=DotProposal(body:"Reviewed",revision:2,snapshotRevision:3)
        context.proposal?.appliedFingerprint=displayed.fingerprint
        let expected=displayed.fingerprint
        displayed.attachmentCount=0
        try BridgeCoordinator.grantUIReview(live:displayed,displayedFingerprint:expected,expectedRevision:3,token:token,context:&context)
        XCTAssertEqual(context.snapshotRevision,4)
        XCTAssertEqual(context.snapshot?.attachmentCount,0)
        XCTAssertEqual(context.proposal?.snapshotRevision,4)
        XCTAssertEqual(context.proposal?.appliedFingerprint,displayed.fingerprint)
        try XCTUnwrap(context.review).validate(draft:displayed,editorToken:token)
    }
    func testNativeReviewRejectsChangedBodyBindingAndConcurrentRevision() throws {
        let draft=MailDraft(id:-1,subject:"Synthetic",sender:"owner@example.invalid",to:["self@example.invalid"],cc:[],bcc:[],body:"Reviewed",attachmentCount:0)
        let token=UUID().uuidString
        for change in 0..<3 {
            var context=ReplyContext(id:"synthetic",envelope:draft)
            context.snapshot=draft; context.snapshotRevision=1; context.uiEditorToken=token
            var live=draft
            if change == 0 { live.body="Edited" }
            if change == 1 { context.uiEditorToken=UUID().uuidString }
            if change == 2 { context.snapshotRevision=2 }
            XCTAssertThrowsError(try BridgeCoordinator.grantUIReview(live:live,displayedFingerprint:draft.fingerprint,expectedRevision:1,token:token,context:&context))
            XCTAssertNil(context.review)
            XCTAssertEqual(context.snapshot?.body,"Reviewed")
        }
    }
    func testUIReviewRequiresSameLiveEditorAndKnownEmptyAttachments() throws {
        var draft=MailDraft(id:-1,subject:"Synthetic",sender:"owner@example.invalid",to:["self@example.invalid"],cc:[],bcc:[],body:"Reviewed",attachmentCount:0)
        let token=UUID().uuidString
        let review=SendReview(draft:draft,editorToken:token)
        try review.validate(draft:draft,editorToken:token)
        XCTAssertThrowsError(try review.validate(draft:draft))
        XCTAssertThrowsError(try review.validate(draft:draft,editorToken:UUID().uuidString))
        XCTAssertThrowsError(try SendReview(draft:draft).validate(draft:draft))
        draft.attachmentCount = -1
        XCTAssertThrowsError(try SendReview(draft:draft,editorToken:token).validate(draft:draft,editorToken:token))
    }
    func testRestartedBindingCannotConsumeReview() throws {
        let draft=MailDraft(id:-1,subject:"Synthetic",sender:"owner@example.invalid",to:["self@example.invalid"],cc:[],bcc:[],body:"Reviewed",attachmentCount:0)
        let token=UUID().uuidString
        var context=ReplyContext(id:"synthetic",envelope:draft)
        context.snapshot=draft
        context.uiEditorToken=token
        context.review=SendReview(draft:draft,editorToken:token)
        let id=try XCTUnwrap(context.review?.id)
        context.uiEditorToken=nil
        XCTAssertThrowsError(try BridgeCoordinator.consumeReview(id,live:draft,context:&context))
        XCTAssertEqual(context.review?.consumed,false)
        context.uiEditorToken=token
        try BridgeCoordinator.consumeReview(id,live:draft,context:&context)
        XCTAssertEqual(context.review?.consumed,true)
    }
}
