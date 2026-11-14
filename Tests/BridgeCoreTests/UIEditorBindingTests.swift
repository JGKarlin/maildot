import XCTest
@testable import BridgeCore

final class UIEditorBindingTests:XCTestCase {
    func testHeaderChangeInvalidatesUIEditorBinding() {
        let draft=MailDraft(id:-1,subject:"Message",sender:"owner@example.invalid",to:["one@example.invalid"],cc:[],bcc:[],body:"Original",attachmentCount:-1)
        var context=ReplyContext(id:"context",envelope:draft); context.snapshot=draft; context.uiEditorToken="token"
        var changed=draft; changed.to=["two@example.invalid"]
        BridgeCoordinator.observeEnvelope(changed,context:&context)
        XCTAssertNil(context.uiEditorToken)
        XCTAssertNil(context.snapshot)
    }
    func testReadOnlyUIBindingDoesNotQualifyForSending() throws {
        let draft=MailDraft(id:-1,subject:"Message",sender:"owner@example.invalid",to:["one@example.invalid"],cc:[],bcc:[],body:"Original",attachmentCount:-1)
        XCTAssertThrowsError(try SendReview(draft:draft).validate(draft:draft))
    }
}
