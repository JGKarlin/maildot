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
        XCTAssertEqual(MailDotBanner.replied.title,"↩︎ Replied")
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
        XCTAssertEqual(MailDotBanner.ccOnly.title,"⊕ Cc only")
        XCTAssertEqual(MailDotBanner.ccOnly.action,"⧉ Open Mail Dot","so the owner can still ask Dot")
        entry.outcome = .held
        XCTAssertEqual(MailDotBanner(entry),.notDrafted)
        let bulk=MailTriageEntry(messageID:"n@example.invalid",sender:"no-reply@example.invalid",senderName:nil,subject:"Receipt",receivedAt:Date(),
                                 verdict:MailTriage.Verdict(essential:false,reason:"Automated mail."),automatic:true)
        XCTAssertEqual(MailDotBanner(bulk),.noReplyNeeded)
    }
}

/// A reply to a message marked No reply needed waits for the owner's words (owner request, 20 November 2026).
final class NoReplyNeededAskFirstTests:XCTestCase {
    private func entry(_ id:String,essential:Bool,reason:String) -> MailTriageEntry {
        MailTriageEntry(messageID:"\(id)@example.invalid",sender:"s@example.invalid",senderName:nil,subject:id,receivedAt:Date(),
                        verdict:MailTriage.Verdict(essential:essential,reason:reason),automatic:true)
    }
    func testOnlyNoReplyNeededAsksFirst() {
        var state=MailTriageState()
        let checked=entry("checked",essential:true,reason:"r"),automated=entry("automated",essential:false,reason:"Automated mail.")
        let copied=entry("copied",essential:false,reason:MailTriage.copiedOnlyReason),drafted=entry("drafted",essential:true,reason:"r")
        [checked,automated,copied,drafted].forEach{ state.record($0) }
        state.markAsked(checked.id,requestID:"r1"); state.accept(requestID:"r1",stage:.ready,summary:"No reply needed.")
        state.markAsked(drafted.id,requestID:"r2")
        XCTAssertEqual(MailDotBanner(state.entries.first{$0.id == checked.id}!),.noReplyNeeded)
        XCTAssertTrue(state.markedNoReplyNeeded(messageID:"<checked@example.invalid>"),"Dot found no reply needed")
        XCTAssertEqual(state.markedNoReplyNeeded(messageID:"<automated@example.invalid>"),MailDotBanner(state.entries.first{$0.id == automated.id}!) == .noReplyNeeded,"the Mac's filter, as the banner shows it")
        XCTAssertFalse(state.markedNoReplyNeeded(messageID:"<copied@example.invalid>"),"Cc only is left as it is")
        XCTAssertFalse(state.markedNoReplyNeeded(messageID:"<drafted@example.invalid>"),"one Dot is still checking")
        XCTAssertFalse(state.markedNoReplyNeeded(messageID:"<unknown@example.invalid>"))
    }
    /// Dot is not asked until the owner says what the reply should say; then it is, as usual.
    func testTheReplyWaitsForTheOwnersWords() throws {
        var context=ReplyContext(id:"reply",envelope:MailDraft(id: -1,subject:"Re: Thanks",sender:"owner@example.invalid",to:["sam@example.invalid"],cc:[],bcc:[],body:"",attachmentCount:0),
                                 originalMessageID:"thanks@example.invalid")
        var shared=context.envelope; shared.body="\n\nOn Monday Sam wrote:\n> Thanks for everything!"
        BridgeCoordinator.share(shared,with:&context)
        BridgeCoordinator.ownerOpensPanel(context:&context)
        XCTAssertTrue(BridgeCoordinator.dotIsOwedWord(context),"opening the panel asks for a draft")
        XCTAssertTrue(BridgeCoordinator.waitsForOwnerWords(context,markedNoReplyNeeded:true),"but a No reply needed message waits")
        XCTAssertFalse(BridgeCoordinator.waitsForOwnerWords(context,markedNoReplyNeeded:false),"any other message is drafted at once")
        var state=BridgeState(); state.contexts[context.id]=context
        try BridgeCoordinator.ownerDirects("Thank Sam and offer to help with the spring workshop.",contextID:context.id,state:&state)
        let directed=try XCTUnwrap(state.contexts[context.id])
        XCTAssertFalse(BridgeCoordinator.waitsForOwnerWords(directed,markedNoReplyNeeded:true),"the owner's words go to Dot")
        XCTAssertTrue(BridgeCoordinator.dotIsOwedWord(directed))
    }
}

/// The morning of 24 November 2026: a message waited its turn in a batch, was asked again after fifteen minutes, and
/// Dot's answer to the first request was thrown away.
final class UnansweredRetryTests:XCTestCase {
    private func entry() -> MailTriageEntry {
        MailTriageEntry(messageID:"sam@example.invalid",sender:"sam@example.invalid",senderName:"Sam Lee",subject:"Plans",receivedAt:Date(),
                        verdict:MailTriage.Verdict(essential:true,reason:"r"),automatic:true)
    }
    private func request(_ at:Date) throws -> MailWorkflowRequest {
        try MailWorkflowRequest(action:.draftCheck,accountIDs:["gmail:profile"],triageID:UUID().uuidString,createdAt:at)
    }

    /// While Dot works through other requests, a message it has not reached is not given up on.
    func testAMessageDotHasNotReachedWaitsWhileDotWorks() throws {
        let t0=Date()
        var triage=MailTriageState(),workflow=MailWorkflowState()
        let message=entry(); triage.record(message)
        let mine=try request(t0),other=try request(t0)
        workflow.requests=[mine,other]
        triage.markAsked(message.id,requestID:mine.id,now:t0)
        workflow.markRead(other.id,now:t0.addingTimeInterval(12*60))
        XCTAssertEqual(triage.expireUnanswered(now:t0.addingTimeInterval(16*60),workflow:workflow),0,"Dot was at work four minutes ago")
        XCTAssertEqual(triage.expireUnanswered(now:t0.addingTimeInterval(28*60),workflow:workflow),1,"fifteen minutes with no sign of Dot")
    }

    /// The fifteen minutes count from when Dot opened the message's own request.
    func testTheLimitCountsFromWhenDotOpenedTheRequest() throws {
        let t0=Date()
        var triage=MailTriageState(),workflow=MailWorkflowState()
        let message=entry(); triage.record(message)
        let mine=try request(t0); workflow.requests=[mine]
        triage.markAsked(message.id,requestID:mine.id,now:t0)
        workflow.markRead(mine.id,now:t0.addingTimeInterval(10*60))
        XCTAssertEqual(triage.expireUnanswered(now:t0.addingTimeInterval(20*60),workflow:workflow),0)
        XCTAssertEqual(triage.expireUnanswered(now:t0.addingTimeInterval(26*60),workflow:workflow),1)
    }

    /// Dot's answer to the first request counts after the message was asked again, and the second is withdrawn.
    func testALateAnswerToTheFirstRequestIsKept() throws {
        let t0=Date()
        var triage=MailTriageState()
        let message=entry(); triage.record(message)
        triage.markAsked(message.id,requestID:"first",now:t0)
        XCTAssertEqual(triage.expireUnanswered(now:t0.addingTimeInterval(16*60)),1)
        triage.markAsked(message.id,requestID:"second",now:t0.addingTimeInterval(17*60))
        let withdrawn=triage.accept(requestID:"first",stage:.ready,summary:"No reply needed.")
        XCTAssertEqual(triage.entries[0].outcome,.noDraft,"Dot's answer is applied")
        XCTAssertEqual(withdrawn,["second"],"the duplicate request is withdrawn")
        XCTAssertNil(triage.entries[0].earlierRequestIDs)
        XCTAssertEqual(triage.accept(requestID:"second",stage:.ready,summary:"Draft reply: Hello"),[],"a later answer to the withdrawn request changes nothing")
        XCTAssertEqual(triage.entries[0].outcome,.noDraft)
    }

    /// A message given up on still takes Dot's late answer: it never stays "Dot couldn't check" when Dot did check.
    func testAGivenUpMessageTakesALateAnswer() throws {
        let t0=Date()
        var triage=MailTriageState()
        let message=entry(); triage.record(message)
        triage.markAsked(message.id,requestID:"first",now:t0)
        triage.expireUnanswered(now:t0.addingTimeInterval(16*60))
        triage.markAsked(message.id,requestID:"second",now:t0.addingTimeInterval(17*60))
        triage.expireUnanswered(now:t0.addingTimeInterval(33*60))
        XCTAssertEqual(triage.entries[0].outcome,.failed)
        triage.accept(requestID:"first",stage:.ready,summary:"Draft reply: Thanks, Sam.")
        XCTAssertEqual(triage.entries[0].outcome,.drafted)
        XCTAssertEqual(triage.entries[0].draft,"Thanks, Sam.")
    }
}

/// The owner's words while Dot drafts replace the request Dot is working on (owner request, 24 November 2026).
final class RedirectWhileDraftingTests:XCTestCase {
    func testADraftForAReplacedRequestIsRefusedAndDotIsSentToTheNewOne() throws {
        var state=MailWorkflowState()
        let reply=UUID().uuidString,other=UUID().uuidString
        let first=try state.requestReply(accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"],contextID:reply)
        XCTAssertNil(state.replyReplacement(named:first.id,contextID:reply),"the current request stands")
        let second=try state.requestReply(accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"],contextID:reply)
        XCTAssertEqual(state.replyReplacement(named:first.id,contextID:reply),second.id,"the old one points to the new one")
        XCTAssertNil(state.replyReplacement(named:second.id,contextID:reply))
        XCTAssertNil(state.replyReplacement(named:first.id,contextID:other),"only for its own reply")
        XCTAssertNil(state.replyReplacement(named:nil,contextID:reply),"a call naming no request is not refused")
        XCTAssertFalse(state.requests.contains{ $0.id == first.id },"the old request is withdrawn")
        let encoded=try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(MailWorkflowState.self,from:encoded).replacedReplies[first.id],reply,"kept across a restart")
    }
}

/// Tell Dot after editing Dot's draft: Dot revises the owner's version (owner report, 24 November 2026).
final class RevisionFromOwnersEditTests:XCTestCase {
    func testTheOwnersEditGoesToDotWithTheirWords() throws {
        var context=ReplyContext(id:UUID().uuidString,envelope:MailDraft(id: -1,subject:"Re: Plans",sender:"owner@example.invalid",to:["sam@example.invalid"],cc:[],bcc:[],body:"",attachmentCount:0),originalMessageID:"plans@example.invalid")
        var shared=context.envelope; shared.body="\n\nOn Monday Sam wrote:\n> Plans?"
        BridgeCoordinator.share(shared,with:&context)
        BridgeCoordinator.ownerOpensPanel(context:&context)
        var state=BridgeState(); state.contexts[context.id]=context
        try BridgeCoordinator.ownerDirects("Mention that Kim will join.",editedDraft:"Dear Sam,\nFriday suits me.",contextID:context.id,state:&state)
        let words=try XCTUnwrap(BridgeCoordinator.instruction(for:try XCTUnwrap(state.contexts[context.id])))
        XCTAssertTrue(words.contains("Mention that Kim will join."))
        XCTAssertTrue(words.contains("Friday suits me."),"Dot revises the owner's edited version")
        try BridgeCoordinator.ownerDirects("Shorter, please.",contextID:context.id,state:&state)
        XCTAssertFalse(try XCTUnwrap(BridgeCoordinator.instruction(for:try XCTUnwrap(state.contexts[context.id]))).contains("Friday suits me."),"an unedited draft sends no edit")
    }
}
