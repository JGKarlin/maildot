import XCTest
@testable import BridgeCore

/// A queued Mail action must not run long after it was requested, when the owner has moved on.
final class OperationAgeTests: XCTestCase {
    func testFreshOperationMayRun() {
        let operation = NativeOperation(contextID: "message", kind: "send", reviewID: "review")
        XCTAssertNil(operation.refusalIfTooOld(now: operation.createdAt.addingTimeInterval(NativeOperation.maximumAge - 1)))
    }
    func testOperationOlderThanTheLimitIsRefusedWithAnExplanation() {
        for kind in ["send", "apply", "review", "share"] {
            let operation = NativeOperation(contextID: "message", kind: kind)
            let refusal = operation.refusalIfTooOld(now: operation.createdAt.addingTimeInterval(NativeOperation.maximumAge + 1))
            XCTAssertEqual(refusal, "This request waited too long and was not carried out. Nothing was changed or sent. Ask again if you still want it.", kind)
        }
    }
    func testSendIsRefusedAtTheLastMomentIfItHasGrownTooOld() throws {
        let token = UUID().uuidString
        var draft = MailDraft(id:-1,subject:"Re: Test",sender:"owner@example.invalid",to:["recipient@example.invalid"],cc:[],bcc:[],body:"Text",attachmentCount:0)
        var state = BridgeState()
        var context = ReplyContext(id:"message",envelope:draft)
        BridgeCoordinator.share(draft,with:&context)
        draft = try XCTUnwrap(context.snapshot)
        context.uiEditorToken = token
        let review = SendReview(draft:draft,editorToken:token)
        context.review = review
        state.contexts["message"] = context
        var operation = NativeOperation(contextID:"message",kind:"send",reviewID:review.id)
        operation.claimedAt = operation.createdAt
        state.operations = [operation]
        // Claimed in time, but the native checks ran long: the press must not happen.
        let late = operation.createdAt.addingTimeInterval(NativeOperation.maximumAge + 1)
        XCTAssertThrowsError(try BridgeCoordinator.consumeUISend(operationID:operation.id,contextID:"message",reviewID:review.id,expectedFingerprint:draft.fingerprint,expectedRevision:context.snapshotRevision,token:token,live:draft,state:&state,now:late))
        XCTAssertEqual(state.contexts["message"]?.review?.consumed,false)
        try BridgeCoordinator.consumeUISend(operationID:operation.id,contextID:"message",reviewID:review.id,expectedFingerprint:draft.fingerprint,expectedRevision:context.snapshotRevision,token:token,live:draft,state:&state,now:operation.createdAt.addingTimeInterval(5))
        XCTAssertEqual(state.contexts["message"]?.review?.consumed,true)
    }
    func testAgeLimitDoesNotOutlastTheSendToolsOwnWait() {
        // send_reviewed_reply reports "no definitive result" after 20 seconds; nothing may run after that.
        XCTAssertLessThanOrEqual(NativeOperation.maximumAge, 20)
    }
}
