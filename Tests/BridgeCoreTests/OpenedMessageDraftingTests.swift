import XCTest
@testable import BridgeCore

final class OpenedMessageDraftingTests:XCTestCase {
    private let owner:Set<String>=["owner@example.invalid"]
    private func raw(from:String="\"Sam Lee\" <sam@example.invalid>",to:String="Owner <owner@example.invalid>",extra:String="") -> Data {
        Data("Message-ID: <m1@example.invalid>\r\nFrom: \(from)\r\nTo: \(to),\r\n \"Other, Person\" <other@example.invalid>\r\nSubject: Seminar room\r\nDate: Wed, 11 Nov 2026 10:00:00 +0900\r\n\(extra)\r\nHello,\r\nFrom: not a header\r\n".utf8)
    }

    func testTheHeadersOfARawMessageFeedTheFilter() {
        let input=MailTriage.Input(rawMessage:raw())
        XCTAssertEqual(input.messageID,"m1@example.invalid")
        XCTAssertEqual(input.senderAddress,"sam@example.invalid")
        XCTAssertEqual(input.to,["owner@example.invalid","other@example.invalid"],"a quoted comma inside a name does not split it")
        XCTAssertEqual(input.subject,"Seminar room")
        XCTAssertNotNil(input.receivedAt)
        XCTAssertTrue(MailTriage.assess(input,owner:owner).essential)
        XCTAssertFalse(MailTriage.assess(MailTriage.Input(rawMessage:raw(extra:"List-Id: <list.example.invalid>\r\n")),owner:owner).essential,"list mail is still filtered out")
    }

    func testOpeningAnOlderImportantMessageRecordsItAsDueAndOpened() throws {
        var state=MailTriageState()
        XCTAssertTrue(state.noteOpened(MailTriage.Input(rawMessage:raw()),owner:owner,automatic:true))
        let entry=try XCTUnwrap(state.entries.first)
        XCTAssertNotNil(entry.openedAt)
        XCTAssertEqual(entry.outcome,.pending)
        XCTAssertEqual(state.dueForDot().map(\.id),[entry.id])
        XCTAssertFalse(state.noteOpened(MailTriage.Input(rawMessage:raw()),owner:owner,automatic:true),"noted once")
    }

    func testAMessageHeldAsOlderStaysHeldWhenOpened() throws {
        var state=MailTriageState()
        let input=MailTriage.Input(rawMessage:raw())
        state.record(MailTriageEntry(messageID:input.messageID,sender:input.senderAddress,senderName:nil,subject:input.subject,receivedAt:input.receivedAt,
                                     verdict:MailTriage.assess(input,owner:owner),automatic:true))
        let id=try XCTUnwrap(state.entries.first?.id)
        state.hold(id,older:true)
        XCTAssertTrue(state.noteOpened(input,owner:owner,automatic:true))
        XCTAssertEqual(state.entries.first?.outcome,.held,"older mail is drafted only when the owner asks")
        XCTAssertEqual(state.entries.first?.heldAsOlder,true)
        XCTAssertNotNil(state.entries.first?.openedAt)
    }

    func testAnOpenedMessageTheFilterSkipsStaysSkipped() throws {
        var state=MailTriageState()
        state.noteOpened(MailTriage.Input(rawMessage:raw(from:"Owner <owner@example.invalid>",to:"sam@example.invalid")),owner:owner,automatic:true)
        XCTAssertEqual(state.entries.first?.outcome,.skipped,"the owner's own mail is never drafted")
        XCTAssertTrue(state.dueForDot().isEmpty)
    }
}
