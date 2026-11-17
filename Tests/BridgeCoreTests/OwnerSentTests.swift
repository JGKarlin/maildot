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

/// An answer the owner gave is kept: an earlier reply shown again does not close it, and a reply window opened
/// afterwards takes it to Dot (owner report, 17 November 2026).
final class OwnerAnswerKeptTests: XCTestCase {
    func testAnEarlierReplyShownAgainDoesNotCloseTheOwnersNewRequest() throws {
        var state = MailTriageState()
        let entry = MailTriageEntry(messageID:"<q@example.invalid>", sender:"colleague@example.invalid", senderName:nil, subject:"Certificate",
                                    receivedAt:Date(), verdict:MailTriage.Verdict(essential:true, reason:"r"), automatic:true)
        state.record(entry)
        // The owner replied once before; Mail Dot recorded it.
        XCTAssertTrue(state.noteOwnerSent(inReplyTo:"<q@example.invalid>"))
        XCTAssertEqual(state.entries[0].outcome, .replied)
        // The owner then answers Dot's question about the same message in the Mail Dot window.
        try state.answer(entry.id, with:"Accept her proposed substitute documents")
        XCTAssertEqual(state.entries[0].outcome, .pending)
        // Opening the conversation shows the earlier reply again: the answer stands.
        XCTAssertFalse(state.noteOwnerSent(inReplyTo:"<q@example.invalid>"))
        XCTAssertEqual(state.entries[0].outcome, .pending)
        XCTAssertEqual(state.entries[0].ownerAnswer, "Accept her proposed substitute documents")
    }

    func testTheReplyWindowTakesTheStoredAnswerToDotOnce() {
        let draft = MailDraft(id:1, subject:"Re: Certificate", sender:"owner@example.invalid", to:["colleague@example.invalid"], cc:[], bcc:[], body:"", attachmentCount:0)
        var context = ReplyContext(id:UUID().uuidString, envelope:draft)
        BridgeCoordinator.share(draft, with:&context)
        BridgeCoordinator.ownerOpensPanel(context:&context)
        context.dotQuestion = "How should this be handled? 1) Accept 2) Decline"
        XCTAssertTrue(BridgeCoordinator.carryOwnerAnswer(question:"How should this be handled? 1) Accept 2) Decline", answer:"Accept", into:&context))
        XCTAssertNil(context.dotQuestion, "the question already answered is not shown again")
        XCTAssertFalse(BridgeCoordinator.carryOwnerAnswer(question:"How should this be handled? 1) Accept 2) Decline", answer:"Accept", into:&context), "added once")
        let told = BridgeCoordinator.instruction(for:context) ?? ""
        XCTAssertTrue(told.contains("The owner answered: Accept"), told)
    }
}

extension OwnerAnswerKeptTests {
    func testAQuestionAlreadyAnsweredIsRecognisedWhateverItsNumberedAnswers() {
        let draft = MailDraft(id:1, subject:"Re: x", sender:"owner@example.invalid", to:["c@example.invalid"], cc:[], bcc:[], body:"", attachmentCount:0)
        var context = ReplyContext(id:UUID().uuidString, envelope:draft)
        BridgeCoordinator.share(draft, with:&context)
        BridgeCoordinator.ownerOpensPanel(context:&context)
        context.dotQuestion = "How should Morimatsu handle the missing certificate? 1) Accept 2) Defer"
        XCTAssertTrue(BridgeCoordinator.carryOwnerAnswer(question:context.dotQuestion, answer:"Accept", into:&context))
        XCTAssertTrue(BridgeCoordinator.alreadyAnswered("How should  Morimatsu handle the missing certificate?  1) Accept her documents 2) Defer 3) Decline", in:context))
        XCTAssertFalse(BridgeCoordinator.alreadyAnswered("Should the course chair be copied?", in:context))
    }
    func testADraftComesBeforeAQuestionInTheIndicator() {
        let draft = MailDraft(id:1, subject:"Re: x", sender:"owner@example.invalid", to:["c@example.invalid"], cc:[], bcc:[], body:"", attachmentCount:0)
        var context = ReplyContext(id:UUID().uuidString, envelope:draft)
        BridgeCoordinator.share(draft, with:&context)
        BridgeCoordinator.ownerOpensPanel(context:&context)
        context.dotQuestion = "Which date? 1) Monday 2) Friday"
        if case .question = ReplyIndicator(context) {} else { XCTFail("with no draft the question shows") }
        try? BridgeCoordinator.propose("Dear colleague, Monday suits me.", expectedRevision:context.snapshotRevision, eventID:nil, delivery:.save, context:&context)
        context.dotQuestion = "Which date? 1) Monday 2) Friday"
        if case .question = ReplyIndicator(context) { XCTFail("a draft already written comes first") }
    }
}

/// "Confirm before sending" in Settings (owner request, 17 November 2026): on by default; off, the panel's Send
/// is the confirmation, while a send Dot drafted by voice still waits for the owner.
final class ConfirmBeforeSendingTests: XCTestCase {
    func state(panelChoseSend:Bool) throws -> (BridgeState,String) {
        let draft = MailDraft(id:1, subject:"Re: x", sender:"owner@example.invalid", to:["c@example.invalid"], cc:[], bcc:[], body:"Hello", attachmentCount:0)
        var context = ReplyContext(id:UUID().uuidString, envelope:draft)
        BridgeCoordinator.share(draft, with:&context)
        if panelChoseSend { BridgeCoordinator.ownerOpensPanel(context:&context); context.ownerRequest?.delivery = .send }
        try BridgeCoordinator.propose("Hello", expectedRevision:context.snapshotRevision, eventID:nil, delivery:.send, context:&context)
        context.proposal?.appliedFingerprint = context.snapshot?.fingerprint
        try BridgeCoordinator.requestSendConfirmation(context:&context)
        var state = BridgeState(); state.contexts[context.id] = context
        return (state,context.id)
    }
    func testOnByDefault() {
        XCTAssertTrue(MailSettings().confirmsPanelSends)
        var settings = MailSettings(); settings.confirmBeforeSending = false
        XCTAssertFalse(settings.confirmsPanelSends)
    }
    func testWithConfirmationOnTheOwnerIsAsked() throws {
        var (state,id) = try state(panelChoseSend:true)
        XCTAssertFalse(try BridgeCoordinator.sendWithoutAsking(contextID:id, confirms:true, state:&state))
        XCTAssertNotNil(state.contexts[id]?.sendConfirmation)
    }
    func testWithConfirmationOffThePanelsSendGoesAhead() throws {
        var (state,id) = try state(panelChoseSend:true)
        XCTAssertTrue(try BridgeCoordinator.sendWithoutAsking(contextID:id, confirms:false, state:&state))
        XCTAssertNil(state.contexts[id]?.sendConfirmation)
        XCTAssertNotNil(state.contexts[id]?.ownerRequest?.sendConfirmedAt)
    }
    func testASendDotDraftedByVoiceStillWaitsForTheOwner() throws {
        var (state,id) = try state(panelChoseSend:false)
        XCTAssertFalse(try BridgeCoordinator.sendWithoutAsking(contextID:id, confirms:false, state:&state))
        XCTAssertNotNil(state.contexts[id]?.sendConfirmation)
    }
}
