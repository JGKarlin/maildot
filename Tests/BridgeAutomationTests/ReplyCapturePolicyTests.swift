import XCTest
import BridgeCore
@testable import BridgeAutomation

/// A new message's MailKit session kept the subject empty after the owner typed one (owner report, 24 November 2026).
final class ReplyCapturePolicyTests:XCTestCase {
    private func draft(subject:String,to:[String]=["sam@example.invalid"],cc:[String]=[]) -> MailDraft {
        MailDraft(id: -1,subject:subject,sender:"owner@example.invalid",to:to,cc:cc,bcc:[],body:"",attachmentCount: -1)
    }
    func testASubjectMailKitDoesNotKnowYetIsTakenFromMail() throws {
        let read=try ReplyCapturePolicy.validate(draft(subject:"Lunch on Friday"),matching:draft(subject:""))
        XCTAssertEqual(read.subject,"Lunch on Friday","the subject the owner typed is the one shared")
    }
    func testEverythingElseMustStillMatch() {
        XCTAssertThrowsError(try ReplyCapturePolicy.validate(draft(subject:"Lunch"),matching:draft(subject:"Dinner")),"a different known subject")
        XCTAssertThrowsError(try ReplyCapturePolicy.validate(draft(subject:"Lunch",to:["kim@example.invalid"]),matching:draft(subject:"")),"a different recipient")
        XCTAssertThrowsError(try ReplyCapturePolicy.validate(draft(subject:"Lunch",cc:["kim@example.invalid"]),matching:draft(subject:"")),"an extra Cc")
        XCTAssertNoThrow(try ReplyCapturePolicy.validate(draft(subject:"Re: Plans"),matching:draft(subject:"Re: Plans")))
    }
}
