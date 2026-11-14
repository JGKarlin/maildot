import XCTest
import BridgeCore
@testable import BridgeAutomation

@MainActor final class MailUISendDispatchTests:XCTestCase {
    func testChangedDraftNeverConsumesOrPressesSend() async throws {
        let token=UUID().uuidString,original=draft()
        let review=SendReview(draft:original,editorToken:token)
        var changed=original; changed.body="Later owner edit"
        var consumed=false,pressed=false
        do {
            try await MailUISendDispatch.perform(review:review,token:token,verify:{changed},checkTarget:{},consume:{_ in consumed=true},press:{pressed=true})
            XCTFail("Changed draft must refuse")
        } catch { }
        XCTAssertFalse(consumed); XCTAssertFalse(pressed)
    }
    func testConsumptionFailurePreventsSend() async throws {
        let token=UUID().uuidString,value=draft()
        var pressed=false
        do {
            try await MailUISendDispatch.perform(review:SendReview(draft:value,editorToken:token),token:token,verify:{value},checkTarget:{},consume:{_ in throw BridgeFailure("Review already consumed")},press:{pressed=true})
            XCTFail("Must refuse")
        } catch { }
        XCTAssertFalse(pressed)
    }
    func testDispatchFailureIsUncertainAndNeverRetried() async throws {
        let token=UUID().uuidString,value=draft()
        var consumed=false,presses=0
        do {
            try await MailUISendDispatch.perform(review:SendReview(draft:value,editorToken:token),token:token,verify:{value},checkTarget:{},consume:{_ in consumed=true},press:{
                XCTAssertTrue(consumed)
                presses += 1
                throw BridgeFailure("No action response")
            })
            XCTFail("Must report uncertain outcome")
        } catch { XCTAssertTrue(error.localizedDescription.contains("uncertain")) }
        XCTAssertTrue(consumed); XCTAssertEqual(presses,1)
    }
    func testSuccessfulDispatchVerifiesThenConsumesThenPressesOnce() async throws {
        let token=UUID().uuidString,value=draft()
        var steps:[String]=[]
        try await MailUISendDispatch.perform(review:SendReview(draft:value,editorToken:token),token:token,verify:{
            steps.append("verify"); return value
        },checkTarget:{steps.append("target")},consume:{ live in
            XCTAssertEqual(live.fingerprint,value.fingerprint)
            steps.append("consume")
        },press:{steps.append("press")})
        XCTAssertEqual(steps,["verify","target","consume","press"])
    }
    func testReplacedOrDisabledTargetNeverConsumes() async throws {
        let token=UUID().uuidString,value=draft()
        var consumed=false,pressed=false
        do {
            try await MailUISendDispatch.perform(review:SendReview(draft:value,editorToken:token),token:token,verify:{value},checkTarget:{
                throw BridgeFailure("Bound target is unavailable")
            },consume:{_ in consumed=true},press:{pressed=true})
            XCTFail("Unavailable target must refuse")
        } catch { }
        XCTAssertFalse(consumed); XCTAssertFalse(pressed)
    }
    func testUnknownAttachmentsAndExpiredOrMismatchedReviewsNeverDispatch() async throws {
        let token=UUID().uuidString,value=draft()
        var unknown=value; unknown.attachmentCount = -1
        let cases:[(SendReview,MailDraft,String)]=[
            (SendReview(draft:unknown,editorToken:token),unknown,token),
            (SendReview(draft:value,now:Date().addingTimeInterval(-3600),editorToken:token),value,token),
            (SendReview(draft:value,editorToken:token),value,UUID().uuidString)
        ]
        for (review,live,currentToken) in cases {
            var consumed=false,pressed=false
            do {
                try await MailUISendDispatch.perform(review:review,token:currentToken,verify:{live},checkTarget:{},consume:{_ in consumed=true},press:{pressed=true})
                XCTFail("Unsafe review must refuse")
            } catch { }
            XCTAssertFalse(consumed); XCTAssertFalse(pressed)
        }
    }
    func testScriptingReviewCannotAuthorizeUIDispatch() async throws {
        var value=draft(); value.id=42
        var consumed=false,pressed=false
        do {
            try await MailUISendDispatch.perform(review:SendReview(draft:value),token:UUID().uuidString,verify:{value},checkTarget:{},consume:{_ in consumed=true},press:{pressed=true})
            XCTFail("A scripting review cannot authorize UI dispatch")
        } catch { }
        XCTAssertFalse(consumed); XCTAssertFalse(pressed)
    }
    func testCancellationDuringVerificationNeverConsumesOrDispatches() async throws {
        let token=UUID().uuidString,value=draft()
        let result=await Task { @MainActor in
            var consumed=false,pressed=false,cancelled=false
            do {
                try await MailUISendDispatch.perform(review:SendReview(draft:value,editorToken:token),token:token,verify:{
                    await Task.yield()
                    withUnsafeCurrentTask { $0?.cancel() }
                    return value
                },checkTarget:{},consume:{_ in consumed=true},press:{pressed=true})
            } catch is CancellationError { cancelled=true }
            catch { XCTFail("Expected cancellation, got \(error)") }
            return (consumed,pressed,cancelled)
        }.value
        XCTAssertFalse(result.0); XCTAssertFalse(result.1); XCTAssertTrue(result.2)
    }
    private func draft()->MailDraft { MailDraft(id:-1,subject:"Synthetic",sender:"owner@example.invalid",to:["self@example.invalid"],cc:[],bcc:[],body:"Reviewed",attachmentCount:0) }
}
