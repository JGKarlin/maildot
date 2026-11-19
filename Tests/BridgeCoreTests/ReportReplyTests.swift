import XCTest
@testable import BridgeCore

final class ReportReplyTests:XCTestCase {
    func testAReportShownOnAMessageIsCheckedForTheOwnersReplyUntilAnswered() {
        var state=MailTriageState()
        let now=Date(timeIntervalSince1970:10_000)
        XCTAssertTrue(state.linkReport("report-1",messageID:"<m1@example.invalid>"))
        XCTAssertFalse(state.linkReport("report-1",messageID:"m1@example.invalid"),"linked once")
        XCTAssertEqual(state.reportReplyChecksDue(now:now).map(\.reportKey),["report-1"])
        state.noteReportChecked("m1@example.invalid",replied:false,now:now)
        XCTAssertTrue(state.reportReplyChecksDue(now:now.addingTimeInterval(60)).isEmpty,"not asked again within five minutes")
        XCTAssertEqual(state.reportReplyChecksDue(now:now.addingTimeInterval(301)).count,1)
        state.noteReportChecked("m1@example.invalid",replied:true,now:now.addingTimeInterval(301))
        XCTAssertTrue(state.reportReplyChecksDue(now:now.addingTimeInterval(9999)).isEmpty,"answered: nothing more to look for")
    }

    func testDotIsToldNotToReportMessagesTheOwnerHasAnswered() {
        XCTAssertTrue(ScheduledMailUpdateTools.instructions.contains("Do not report on a message the owner has already replied to, whether through Mail Dot or by hand"))
    }

    func testTriageListsSavedBeforeReportLinksStillLoad() throws {
        var old=try XCTUnwrap(try JSONSerialization.jsonObject(with:JSONEncoder().encode(MailTriageState())) as? [String:Any])
        old.removeValue(forKey:"reportLinks")
        XCTAssertNil(try JSONDecoder().decode(MailTriageState.self,from:JSONSerialization.data(withJSONObject:old)).reportLinks)
    }

    func testAQuestionDotAlreadyAskedIsShownAtOnceAndDotIsNotAskedAgain() throws {
        var context=ReplyContext(id:"reply",envelope:MailDraft(id: -1,subject:"Re: Renewal",sender:"owner@example.invalid",to:["a@example.invalid"],cc:[],bcc:[],body:"",attachmentCount:0))
        context.snapshot=context.envelope
        BridgeCoordinator.ownerOpensPanel(context:&context)
        XCTAssertTrue(BridgeCoordinator.dotIsOwedWord(context))
        XCTAssertTrue(BridgeCoordinator.usePendingQuestion("Renew the appointment? 1) Yes 2) No",context:&context))
        XCTAssertEqual(context.dotQuestion,"Renew the appointment? 1) Yes 2) No")
        XCTAssertFalse(BridgeCoordinator.dotIsOwedWord(context),"no new run until the owner answers")
        var state=BridgeState(); state.contexts["reply"]=context
        try BridgeCoordinator.ownerAnswers("Yes",contextID:"reply",state:&state)
        XCTAssertTrue(BridgeCoordinator.dotIsOwedWord(try XCTUnwrap(state.contexts["reply"])),"the answer goes to Dot")
    }

    func testTheBannerSaysTheStateOnlyWithItsSymbolAndButton() {
        let entry=MailTriageEntry(messageID:"<b@example.invalid>",sender:"a@example.invalid",senderName:nil,subject:"S",receivedAt:Date(),
                                  verdict:MailTriage.Verdict(essential:true,reason:"r"),automatic:true)
        var state=MailTriageState(); state.record(entry)
        // Dot still deciding about a message it reviews on its own: Checking; a reply being written: Drafting.
        XCTAssertEqual(MailDotBanner(state.entries[0]),.checking)
        state.entries[0].draftRequested=true
        XCTAssertEqual(MailDotBanner(state.entries[0]),.drafting)
        XCTAssertEqual(MailDotBanner.question.title,"?⃝ Question for you"); XCTAssertEqual(MailDotBanner.question.action,"⧉ Open Mail Dot")
        XCTAssertEqual(MailDotBanner.draftReady.title,"✓ Draft ready"); XCTAssertEqual(MailDotBanner.draftReady.action,"⧉ Open Mail Dot")
        XCTAssertEqual(MailDotBanner(report:.awaitingInstruction),.question)
        XCTAssertEqual(MailDotBanner(report:.draftedSent).title,"↩︎ Replied")
        state.noteFlag(state.entries[0].id,applied:nil,ownerFlagged:false,replied:true)
        XCTAssertEqual(MailDotBanner(state.entries[0])?.title,"↩︎ Replied","once replied the banner says so")
    }
}
