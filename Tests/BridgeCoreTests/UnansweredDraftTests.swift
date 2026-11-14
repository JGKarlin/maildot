import XCTest
@testable import BridgeCore

final class UnansweredDraftTests:XCTestCase {
    func testAMessageDotDoesNotAnswerAboutIsOfferedOnceMoreThenSaysSo() throws {
        var state=MailTriageState()
        let entry=MailTriageEntry(messageID:"<slow@example.invalid>",sender:"a@example.invalid",senderName:nil,subject:"Schedule",receivedAt:Date(),
                                  verdict:MailTriage.Verdict(essential:true,reason:"r"),automatic:true)
        state.record(entry)
        let start=Date()
        state.markAsked(entry.id,requestID:"r1",now:start)
        XCTAssertEqual(state.expireUnanswered(now:start.addingTimeInterval(14*60)),0,"still within the limit")
        XCTAssertEqual(state.expireUnanswered(now:start.addingTimeInterval(16*60)),1)
        XCTAssertEqual(state.entries.first?.outcome,.pending,"offered to Dot once more")
        XCTAssertNil(state.entries.first?.requestID)
        state.markAsked(entry.id,requestID:"r2",now:start.addingTimeInterval(17*60))
        state.expireUnanswered(now:start.addingTimeInterval(33*60))
        XCTAssertEqual(state.entries.first?.outcome,.failed,"then it says Dot did not answer")
        XCTAssertNotNil(state.entries.first?.dotNote)
        state.accept(requestID:"r1",stage:.ready,summary:"late")
        XCTAssertEqual(state.entries.first?.outcome,.failed,"a late answer to a request given up on changes nothing")
    }
}
