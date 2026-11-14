import XCTest
@testable import BridgeCore

final class SafetyTests: XCTestCase {
    func draft(_ body: String = "Original", to: [String] = ["recipient@example.invalid"]) -> MailDraft {
        MailDraft(id: 41, subject: "Re: Synthetic", sender: "sender@example.invalid", to: to,
                  cc: [], bcc: [], body: body, attachmentCount: 0)
    }

    func testRecipientChangeChangesFingerprint() {
        XCTAssertNotEqual(draft().fingerprint, draft(to: ["different@example.invalid"]).fingerprint)
    }

    func testBodyChangeChangesFingerprint() {
        XCTAssertNotEqual(draft().fingerprint, draft("Edited").fingerprint)
    }

    func testRecipientOrderAndCaseDoNotBreakBinding() throws {
        let first = draft(to: ["A@example.invalid", "b@example.invalid"])
        let second = draft(to: ["B@example.invalid", "a@example.invalid"])
        XCTAssertEqual(try DraftMatcher.unique([first], matching: second).id, 41)
    }

    func testAmbiguousDraftsAreRefused() {
        XCTAssertThrowsError(try DraftMatcher.unique([draft(), draft()], matching: draft()))
    }

    func testMissingDraftIsRefused() {
        XCTAssertThrowsError(try DraftMatcher.unique([], matching: draft()))
    }

    func testReviewRejectsEditsAndExpires() throws {
        let review = SendReview(draft: draft(), now: Date(timeIntervalSince1970: 10))
        XCTAssertNoThrow(try review.validate(draft: draft(), now: Date(timeIntervalSince1970: 11)))
        XCTAssertThrowsError(try review.validate(draft: draft("Edited"), now: Date(timeIntervalSince1970: 11)))
        XCTAssertThrowsError(try review.validate(draft: draft(), now: Date(timeIntervalSince1970: 1000)))
    }

    func testReviewRejectsAttachmentsAndEmptyRecipients() {
        var attached = draft()
        attached.attachmentCount = 1
        XCTAssertThrowsError(try SendReview(draft: attached).validate(draft: attached))
        let empty = draft(to: [])
        XCTAssertThrowsError(try SendReview(draft: empty).validate(draft: empty))
    }

    func testReviewRejectsCaseOnlyAddressEdits() {
        let original = draft()
        let review = SendReview(draft:original)
        var recipientChanged = original
        recipientChanged.to = ["Recipient@example.invalid"]
        XCTAssertThrowsError(try review.validate(draft:recipientChanged))
        var senderChanged = original
        senderChanged.sender = "Sender@example.invalid"
        XCTAssertThrowsError(try review.validate(draft:senderChanged))
    }

    func testFingerprintPreservesRecipientListStructure() {
        let separate = draft(to:["a@example.invalid","b@example.invalid"])
        let combined = draft(to:["a@example.invalid\nb@example.invalid"])
        XCTAssertNotEqual(separate.fingerprint,combined.fingerprint)
    }
}
