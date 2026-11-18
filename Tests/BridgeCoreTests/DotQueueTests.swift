import XCTest
@testable import BridgeCore

final class DotQueueTests:XCTestCase {
    func entry(_ id:String,received:Date) -> MailTriageEntry {
        MailTriageEntry(messageID:"\(id)@example.invalid",sender:"\(id)@example.invalid",senderName:nil,subject:id,receivedAt:received,
                        verdict:MailTriage.Verdict(essential:true,reason:"r"),automatic:true)
    }
    func testNewestFirstWithTheOwnersMessagesAtTheFront() throws {
        var state=MailTriageState()
        let now=Date()
        let old=entry("old",received:now.addingTimeInterval(-3000)),mid=entry("mid",received:now.addingTimeInterval(-2000)),new=entry("new",received:now.addingTimeInterval(-1000))
        [old,mid,new].forEach{ state.record($0) }
        XCTAssertEqual(state.queueForDot().map(\.subject),["new","mid","old"],"newest first")
        let index=state.entries.firstIndex{$0.id == old.id}!
        state.entries[index].openedAt=now
        XCTAssertEqual(state.queueForDot().first?.subject,"old","a message the owner opened goes to the front")
        state.entries[state.entries.firstIndex{$0.id == mid.id}!].outcome = .skipped
        try state.ask(mid.id)
        XCTAssertEqual(state.queueForDot().first?.subject,"mid","one the owner asked about comes before all")
        XCTAssertEqual(state.dueForDot().map(\.subject),["mid","old","new"],"offered together as one batch, the owner's first (owner's choice, 18 November 2026)")
    }
    func testAnUnansweredRequestFreesItsPlaceAfterTheLimit() {
        var state=MailTriageState()
        let now=Date()
        let batch=(0..<MailTriageState.inFlightLimit).map{ entry("a\($0)",received:now.addingTimeInterval(Double(-$0))) }
        let late=entry("late",received:now.addingTimeInterval(-600))
        batch.forEach{ state.record($0) }; state.record(late)
        XCTAssertEqual(state.dueForDot(now:now).count,MailTriageState.inFlightLimit,"a whole batch is offered")
        for (index,one) in batch.enumerated() { state.markAsked(one.id,requestID:"r\(index)",now:now) }
        XCTAssertTrue(state.dueForDot(now:now).isEmpty,"the next waits while Dot works on the batch")
        state.expireUnanswered(now:now.addingTimeInterval(16*60))
        XCTAssertFalse(state.dueForDot(now:now.addingTimeInterval(16*60)).isEmpty,"after 15 minutes the queue moves on")
    }
    /// A message waiting its turn behind one Dot is working on is not unanswered: its fifteen minutes start when Dot
    /// was last seen at work on the batch.
    func testAMessageWaitingInTheBatchIsNotCountedUnansweredWhileDotWorks() {
        var state=MailTriageState()
        let now=Date()
        let a=entry("a",received:now),b=entry("b",received:now.addingTimeInterval(-60))
        state.record(a); state.record(b)
        state.markAsked(a.id,requestID:"r1",now:now); state.markAsked(b.id,requestID:"r2",now:now)
        // Twelve minutes on, Dot reports on a and is handed b.
        state.accept(requestID:"r1",stage:.ready,summary:"No reply needed.")
        state.noteDotAtWork(requestIDs:["r2"],now:now.addingTimeInterval(12*60))
        XCTAssertEqual(state.expireUnanswered(now:now.addingTimeInterval(16*60)),0,"b has had four minutes, not sixteen")
        XCTAssertEqual(state.expireUnanswered(now:now.addingTimeInterval(28*60)),1)
    }
}

final class AlreadyRepliedTests:XCTestCase {
    func testDotSayingTheOwnerAlreadyRepliedShowsReplied() {
        var state=MailTriageState()
        let entry=MailTriageEntry(messageID:"<q@example.invalid>",sender:"s@example.invalid",senderName:nil,subject:"CMU or cement?",receivedAt:Date(),
                                  verdict:MailTriage.Verdict(essential:true,reason:"r"),automatic:true)
        state.record(entry)
        state.markAsked(entry.id,requestID:"r1")
        state.accept(requestID:"r1",stage:.ready,summary:"Already replied: Alex answered at 13:44.")
        XCTAssertEqual(state.entries[0].outcome,.replied,"never No reply needed")
        XCTAssertEqual(MailDotBanner(state.entries[0]),.replied)
        XCTAssertEqual(MailDotBanner.replied.title,"↩️ Replied")
    }
}

final class EveryMessageHasABannerTests:XCTestCase {
    func testMessagesNotOfferedToDotStillShowAState() {
        let owner:Set<String>=["owner@example.invalid"]
        let cc=MailTriage.Input(messageID:"c@example.invalid",senderAddress:"a@example.invalid",senderName:nil,to:["b@example.invalid"],cc:["owner@example.invalid"],subject:"FYI",receivedAt:Date(),headers:[:])
        // A copied person's message now goes to Dot (13 November 2026); an entry recorded before then still shows Cc only.
        XCTAssertTrue(MailTriage.assess(cc,owner:owner).essential)
        let verdict=MailTriage.Verdict(essential:false,reason:MailTriage.copiedOnlyReason)
        var entry=MailTriageEntry(messageID:"c@example.invalid",sender:"a@example.invalid",senderName:nil,subject:"FYI",receivedAt:Date(),verdict:verdict,automatic:true)
        XCTAssertEqual(entry.outcome,.skipped)
        XCTAssertEqual(MailDotBanner(entry),.ccOnly)
        XCTAssertEqual(MailDotBanner.ccOnly.title,"👥 Cc only")
        XCTAssertEqual(MailDotBanner.ccOnly.action,"⧉ Open Mail Dot","so the owner can still ask Dot")
        entry.outcome = .held
        XCTAssertEqual(MailDotBanner(entry),.notDrafted)
        let bulk=MailTriageEntry(messageID:"n@example.invalid",sender:"no-reply@example.invalid",senderName:nil,subject:"Receipt",receivedAt:Date(),
                                 verdict:MailTriage.Verdict(essential:false,reason:"Automated mail."),automatic:true)
        XCTAssertEqual(MailDotBanner(bulk),.noReplyNeeded)
    }
}
