import XCTest
@testable import BridgeCore

final class OwnerSentTests: XCTestCase {
    private func entry(_ id:String,sender:String,outcome:MailTriageEntry.Outcome,reason:String="test") -> MailTriageEntry {
        var value=MailTriageEntry(messageID:id,sender:sender,senderName:nil,subject:"Thesis meeting",receivedAt:nil,verdict:.init(essential:true,reason:reason),automatic:false)
        value.outcome=outcome; return value
    }
    func testAReplyWrittenInMailMarksTheMessageItAnswersReplied() {
        var state=MailTriageState()
        var drafted=entry("question@example.invalid",sender:"sam@example.invalid",outcome:.drafted); drafted.draft="Thursday works."
        state.entries=[drafted]
        XCTAssertTrue(state.noteOwnerSent(inReplyTo:"<question@example.invalid>"))
        XCTAssertEqual(state.entries[0].outcome,.replied)
        XCTAssertNil(state.entries[0].draft)
        XCTAssertTrue(state.ownerHasReplied("question@example.invalid"))
        XCTAssertFalse(state.noteOwnerSent(inReplyTo:"<question@example.invalid>"),"noted once")
    }
    func testAMessageWithoutInReplyToChangesNothing() {
        var state=MailTriageState(); state.entries=[entry("q@example.invalid",sender:"sam@example.invalid",outcome:.drafted)]
        XCTAssertFalse(state.noteOwnerSent(inReplyTo:nil))
        XCTAssertEqual(state.entries[0].outcome,.drafted)
    }
    func testTheOwnersOwnMailHasNoBanner() {
        XCTAssertNil(MailDotBanner(entry("mine@example.invalid",sender:"me@example.invalid",outcome:.skipped,reason:MailTriage.sentByOwnerReason)))
        XCTAssertEqual(MailDotBanner(entry("x@example.invalid",sender:"sam@example.invalid",outcome:.skipped,reason:MailTriage.copiedOnlyReason)),.ccOnly)
    }
    func testASentReplyReadsReplied() {
        XCTAssertEqual(MailDotBanner(report:.draftedSent),.replied)
    }
    func testInReplyToIsReadFromTheHeaders() {
        let raw=Data("From: Alex <me@example.invalid>\r\nIn-Reply-To: <question@example.invalid> <older@example.invalid>\r\nMessage-ID: <reply@example.invalid>\r\n\r\nBody\r\n".utf8)
        let headers=MailMessageHeaders(rawMessage:raw)
        XCTAssertEqual(headers.inReplyTo,"question@example.invalid")
        XCTAssertEqual(headers.senderAddress,"me@example.invalid")
    }
}
