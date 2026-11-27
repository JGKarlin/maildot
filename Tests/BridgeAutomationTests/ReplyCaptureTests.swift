import XCTest
import BridgeCore
@testable import BridgeAutomation

final class ReplyCaptureTests:XCTestCase {
    func testNativeAccountProviderUsesExactGmailHosts() {
        XCTAssertTrue(NativeMailAccount(id:"one",name:"Work",addresses:["a@work.invalid"],server:"imap.gmail.com").isGmail)
        XCTAssertFalse(NativeMailAccount(id:"two",name:"Other",addresses:["a@work.invalid"],server:"notgmail.com").isGmail)
    }
    func testRejectsUncommittedRecipientTextAndMissingTokens() throws {
        XCTAssertEqual(try ReplyCapturePolicy.tokenCount("\u{fffc}\u{fffc}"),2)
        XCTAssertEqual(try ReplyCapturePolicy.tokenCount(""),0)
        XCTAssertThrowsError(try ReplyCapturePolicy.tokenCount("\u{fffc}other@example.invalid"))
        XCTAssertThrowsError(try ReplyCapturePolicy.tokenCount(String(repeating:"\u{fffc}",count:13)))
    }
    func testRequiresOneUnambiguousCheckedAddress() throws {
        XCTAssertEqual(try ReplyCapturePolicy.checkedAddress(["one@example.invalid"]),"one@example.invalid")
        for values in [[],["one@example.invalid","two@example.invalid"],["One <one@example.invalid>"],["one@example.invalid\nother@example.invalid"]] {
            XCTAssertThrowsError(try ReplyCapturePolicy.checkedAddress(values))
        }
    }
    func testCaptureMustMatchCompleteEnvelopeAndKeepNativeIdentityUnknown() throws {
        let expected = MailDraft(id:-1,subject:"Message",sender:"owner@example.invalid",to:["one@example.invalid"],cc:[],bcc:[],body:"",attachmentCount:-1)
        var captured = expected; captured.body = "Visible message\nQuoted text"; captured.id = 42; captured.attachmentCount = 0
        let result = try ReplyCapturePolicy.validate(captured,matching:expected)
        XCTAssertEqual(result.id,-1); XCTAssertEqual(result.attachmentCount,-1)
        XCTAssertEqual(result.body,captured.body)
        captured.bcc = ["hidden@example.invalid"]
        XCTAssertThrowsError(try ReplyCapturePolicy.validate(captured,matching:expected))
    }
    func testRequiresExactCompleteBodyLengthAndBoundedText() throws {
        XCTAssertNoThrow(try ReplyCapturePolicy.validateBody("A😀\n",length:4))
        XCTAssertNoThrow(try ReplyCapturePolicy.validateBody("A😀\n",length:3),"a line break Mail's count leaves out is no missing text")
        // Owner report, 27 November 2026: a long Japanese reply came back 9 characters longer than Mail's count.
        XCTAssertNoThrow(try ReplyCapturePolicy.validateBody(String(repeating:"返信の本文。\n",count:562)+String(repeating:"\n",count:9),length:3934))
        XCTAssertNoThrow(try ReplyCapturePolicy.validateBody(String(repeating:"a",count:5000),length:5003),"an image in the quoted mail is a character without text")
        XCTAssertThrowsError(try ReplyCapturePolicy.validateBody(String(repeating:"a",count:100),length:5000),"most of the text missing")
        // A long thread of quoted replies is read; only a message past the bound for real threads is refused.
        XCTAssertNoThrow(try ReplyCapturePolicy.validateBody(String(repeating:"a",count:65537),length:65537))
        let over=MailBodyLimits.characters+1
        XCTAssertThrowsError(try ReplyCapturePolicy.validateBody(String(repeating:"a",count:over),length:over))
    }
}
