import XCTest
@testable import BridgeCore

final class OwnerRepliedTests:XCTestCase {
    func testAReplySentFromMailIsRecordedAndMarksTheMessageReplied() throws {
        var state=MailTriageState()
        XCTAssertTrue(state.record(MailTriageEntry(messageID:"<abc@example.invalid>",sender:"a@example.invalid",senderName:nil,subject:"Hello",receivedAt:Date(),verdict:MailTriage.Verdict(essential:true,reason:"r"),automatic:true)))
        XCTAssertFalse(state.ownerHasReplied("abc@example.invalid"))
        state.noteOwnerReplied(messageID:"<abc@example.invalid>")
        XCTAssertTrue(state.ownerHasReplied("abc@example.invalid"),"with or without angle brackets")
        XCTAssertEqual(state.entries.first?.outcome,.replied)
    }

    func testTheRecordStaysBounded() {
        var state=MailTriageState()
        let start=Date(timeIntervalSince1970:1_000_000)
        for n in 0..<(MailTriageState.ownerRepliedLimit+20) { state.noteOwnerReplied(messageID:"<m\(n)@example.invalid>",now:start.addingTimeInterval(Double(n))) }
        XCTAssertEqual(state.ownerReplied?.count,MailTriageState.ownerRepliedLimit)
        XCTAssertFalse(state.ownerHasReplied("<m0@example.invalid>"),"the oldest go first")
        XCTAssertTrue(state.ownerHasReplied("<m\(MailTriageState.ownerRepliedLimit+19)@example.invalid>"))
    }
}
