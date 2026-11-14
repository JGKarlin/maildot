import Foundation
import XCTest
@testable import BridgeAutomation

final class AttachmentEvidenceTests:XCTestCase {
    func testCompletePlainBodyIncludingStructuralNewlineIsAccepted() throws {
        for body in ["", "\n", "Reviewed message 😀\n"] {
            XCTAssertNoThrow(try AttachmentEvidence.requireAbsent(NSAttributedString(string:body),length:body.utf16.count,matching:body))
        }
    }
    func testMissingTruncatedAndChangedEvidenceIsRejected() {
        XCTAssertThrowsError(try AttachmentEvidence.requireAbsent(nil,length:0,matching:""))
        XCTAssertThrowsError(try AttachmentEvidence.requireAbsent(NSAttributedString(string:"partial"),length:20,matching:"partial"))
        XCTAssertThrowsError(try AttachmentEvidence.requireAbsent(NSAttributedString(string:"changed"),length:7,matching:"reviewed"))
        XCTAssertThrowsError(try AttachmentEvidence.requireAbsent(NSAttributedString(string:"é"),length:1,matching:"e\u{301}"))
    }
    func testObjectAndAttachmentAttributesAreIndependentlyRejected() {
        XCTAssertThrowsError(try AttachmentEvidence.requireAbsent(NSAttributedString(string:"\u{fffc}"),length:1,matching:"\u{fffc}"))
        // Counted, not refused, for a send: a reply quoting two pictures has two objects.
        let quoted="Thanks\n\n> \u{fffc}\n> \u{fffc}\n"
        XCTAssertEqual(try AttachmentEvidence.count(NSAttributedString(string:quoted),length:quoted.utf16.count,matching:quoted),2)
        XCTAssertEqual(try AttachmentEvidence.count(NSAttributedString(string:"plain"),length:5,matching:"plain"),0)
        XCTAssertThrowsError(try AttachmentEvidence.count(nil,length:0,matching:""))
        XCTAssertThrowsError(try AttachmentEvidence.count(NSAttributedString(string:"changed"),length:7,matching:"reviewed"))
        for key in ["AXAttachment","NSAttachment","unknownAttachmentMetadata"] {
            let value=NSAttributedString(string:"x",attributes:[NSAttributedString.Key(key):true])
            XCTAssertThrowsError(try AttachmentEvidence.requireAbsent(value,length:1,matching:"x"))
        }
    }
}
