import XCTest
@testable import BridgeCore

final class FasterDraftingTests:XCTestCase {
    private func opened() -> ReplyContext {
        var context=ReplyContext(id:"reply",envelope:MailDraft(id: -1,subject:"Re: Seminar",sender:"owner@example.invalid",to:["sam@example.invalid"],cc:[],bcc:[],body:"",attachmentCount:0))
        var shared=context.envelope; shared.body="Thursday at 14:00?\n\nOn Monday Sam wrote:\n> Shall we meet?"
        BridgeCoordinator.share(shared,with:&context)
        BridgeCoordinator.ownerOpensPanel(context:&context)
        return context
    }

    func testDotIsGivenTheMessageTextOnceAndNoneOfThePanelsBookkeeping() throws {
        var context=opened()
        context.insertedTop="Hi Sam,\n\n"; context.lastToCorrespondent="Hi Sam,"
        let given=context.forDot
        XCTAssertEqual(given.envelope.body,"","the text is not sent a second time")
        XCTAssertEqual(given.snapshot?.body,context.snapshot?.body)
        XCTAssertNil(given.ownerRequest); XCTAssertNil(given.insertedTop); XCTAssertNil(given.lastToCorrespondent)
        let encoded=try String(decoding:JSONEncoder().encode(given),as:UTF8.self)
        XCTAssertEqual(encoded.components(separatedBy:"Shall we meet?").count-1,1)
    }

    func testADraftRequestCarriesOnlyItsOwnInstructions() {
        let reply=MailWorkflowTools.instructions(for:.reply),all=MailWorkflowTools.instructions(for:nil)
        XCTAssertTrue(reply.contains("For action reply"))
        XCTAssertFalse(reply.contains("For compose"),"nothing about other requests")
        XCTAssertFalse(reply.contains("readFull"))
        XCTAssertLessThan(reply.count,all.count/2)
        XCTAssertTrue(MailWorkflowTools.instructions(for:.draftCheck).contains("For action draftCheck"))
    }

    func testDotIsGivenTheOwnersLastWordsToThePersonAndAnOrderToLookIn() throws {
        var context=opened()
        context.lastToCorrespondent="Hi Sam,\nThanks for the notes."
        context.lastToCorrespondentAt=Date(timeIntervalSince1970:1_790_000_000)
        let told=try XCTUnwrap(BridgeCoordinator.instruction(for:context,preferences:["en-US"]))
        XCTAssertTrue(told.contains("The owner's most recent message to this person (sent 2026-"))
        XCTAssertTrue(told.contains("«Hi Sam,\nThanks for the notes.»"))
        XCTAssertTrue(told.contains("their calendar only when the message names a date, a time or a meeting"))
        XCTAssertTrue(told.contains("Ask a drafting question only when the reply depends on something your context and the owner's past mail do not answer reliably"),"the context-first rule stands")
    }

    func testTheProgressLineReadsMailDotsOwnRecordsOfTheRequest() throws {
        var state=MailWorkflowState()
        let asked=Date(timeIntervalSince1970:1_000)
        let id=UUID().uuidString
        let request=try state.requestReply(accountIDs:["gmail:g"],allowedAccountIDs:["gmail:g"],contextID:id,now:asked)
        XCTAssertEqual(state.replyProgress(contextID:id)?.askedAt,asked)
        XCTAssertNil(state.replyProgress(contextID:id)?.readAt)
        state.markRead(request.id,now:asked.addingTimeInterval(28))
        XCTAssertEqual(state.replyProgress(contextID:id)?.readAt,asked.addingTimeInterval(28))
        state.markRead(request.id,now:asked.addingTimeInterval(60))
        XCTAssertEqual(state.replyProgress(contextID:id)?.readAt,asked.addingTimeInterval(28),"the first read is kept")
    }

    func testOnePressOnAnAnswerShowsDotsReadyDraftWithoutAskingDotAgain() throws {
        var context=opened()
        context.dotQuestion="Can you attend on Thursday? 1) Yes 2) No"
        context.answerDrafts=BridgeCoordinator.answerDrafts(["Hi Sam,\nYes, Thursday works.","Hi Sam,\nSorry, I cannot make Thursday."],for:context)
        XCTAssertEqual(context.answerDrafts?.count,2)
        XCTAssertNil(BridgeCoordinator.answerDrafts(["only one"],for:context),"one draft per numbered answer, or none")
        var state=BridgeState(); state.contexts["reply"]=context
        let askedBefore=try XCTUnwrap(state.contexts["reply"]?.ownerRequest?.askedAt)
        XCTAssertTrue(try BridgeCoordinator.ownerAnswersWithDraft(1,contextID:"reply",state:&state))
        let after=try XCTUnwrap(state.contexts["reply"])
        XCTAssertEqual(after.proposal?.body,"Hi Sam,\nSorry, I cannot make Thursday.")
        XCTAssertNil(after.dotQuestion); XCTAssertNil(after.answerDrafts)
        XCTAssertEqual(after.ownerRequest?.answers.last?.answer,"No","the answer is kept for any later request")
        XCTAssertEqual(after.ownerRequest?.askedAt,askedBefore,"Dot is not asked again")
        XCTAssertFalse(try BridgeCoordinator.ownerAnswersWithDraft(0,contextID:"reply",state:&state),"no question, no draft")
    }
}
