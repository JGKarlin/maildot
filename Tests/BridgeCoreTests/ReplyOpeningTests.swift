import XCTest
@testable import BridgeCore

final class ReplyOpeningTests: XCTestCase {
    private func state(_ outcome:MailTriageEntry.Outcome,draft:String?) -> (MailTriageState,String) {
        var entry=MailTriageEntry(messageID:"synthetic-1@example.invalid",sender:"sam@example.invalid",senderName:"Sam Lee",subject:"Lunch on Friday?",
                                  receivedAt:nil,verdict:.init(essential:true,reason:"test"),automatic:false)
        entry.outcome=outcome; entry.draft=draft
        var value=MailTriageState(); value.entries=[entry]
        return (value,entry.id)
    }
    func testOpenInReplyOpensTheDraftOnce() throws {
        var (value,id)=state(.drafted,draft:"Friday works.")
        try value.requestOpenReply(id)
        XCTAssertEqual(value.nextReplyToOpen()?.id,id)
        value.noteReplyOpened(id,failure:nil)
        XCTAssertNil(value.nextReplyToOpen())
    }
    func testOpenInReplyNeedsADraft() {
        var (value,id)=state(.noDraft,draft:nil)
        XCTAssertThrowsError(try value.requestOpenReply(id))
    }
    func testADraftAskedForInTheWindowOpensWhenItArrives() {
        var (value,id)=state(.pending,draft:nil)
        value.openReplyWhenDrafted(id)
        XCTAssertNil(value.nextReplyToOpen())
        value.entries[0].outcome = .drafted; value.entries[0].draft="Friday works."
        XCTAssertEqual(value.nextReplyToOpen()?.id,id)
        value.noteReplyOpened(id,failure:nil)
        XCTAssertNil(value.nextReplyToOpen())
        XCTAssertNil(value.entries[0].openReplyWhenDrafted)
    }
    func testAQuestionInsteadOfADraftOpensNothing() {
        var (value,id)=state(.asked,draft:nil)
        value.openReplyWhenDrafted(id)
        value.entries[0].outcome = .needsGuidance
        XCTAssertNil(value.nextReplyToOpen())
        XCTAssertNil(value.entries[0].openReplyWhenDrafted)
        // A later automatic draft does not open a reply on its own.
        value.entries[0].outcome = .drafted; value.entries[0].draft="Automatic."
        XCTAssertNil(value.nextReplyToOpen())
    }
    func testDiscardingTheDraftCancelsTheRequest() throws {
        var (value,id)=state(.drafted,draft:"Friday works.")
        try value.requestOpenReply(id)
        try value.discardDraft(id)
        XCTAssertNil(value.nextReplyToOpen())
    }
    func testTheReportFollowsTheDraftOnceTheReplyIsOpened() {
        var (value,id)=state(.asked,draft:nil)
        value.entries[0].draftRequested=true; value.entries[0].requestID="r1"
        value.openReplyWhenDrafted(id)
        value.accept(requestID:"r1",stage:.ready,summary:"Sam asks about Friday.\nDraft reply: Friday works.")
        XCTAssertEqual(value.entries[0].outcome,.drafted)
        XCTAssertNil(value.entries[0].reportRequestedAt,"the report waits until the reply is open")
        XCTAssertEqual(value.nextReplyToOpen()?.id,id)
        value.noteReplyOpened(id,failure:nil)
        XCTAssertNotNil(value.entries[0].reportRequestedAt)
    }
    func testWithoutAReplyToOpenTheReportIsAskedForAtOnce() {
        var (value,_)=state(.asked,draft:nil)
        value.entries[0].draftRequested=true; value.entries[0].requestID="r1"
        value.accept(requestID:"r1",stage:.ready,summary:"Sam asks about Friday.\nDraft reply: Friday works.")
        XCTAssertNotNil(value.entries[0].reportRequestedAt)
    }
    func testDotIsDraftingHoldsForTheWholeAnswerTime() {
        var (value,_)=state(.asked,draft:nil)
        let asked=Date(timeIntervalSince1970:1_000_000)
        value.entries[0].askedAt=asked
        XCTAssertTrue(value.dotIsDrafting(messageID:"<synthetic-1@example.invalid>",now:asked.addingTimeInterval(10*60)))
        XCTAssertFalse(value.dotIsDrafting(messageID:"<synthetic-1@example.invalid>",now:asked.addingTimeInterval(16*60)))
        value.entries[0].outcome = .needsGuidance
        XCTAssertFalse(value.dotIsDrafting(messageID:"<synthetic-1@example.invalid>",now:asked.addingTimeInterval(60)))
    }
    func testGuidanceSupersedesTheDraftInProgress() {
        var (value,_)=state(.asked,draft:nil)
        value.entries[0].requestID="r1"; value.entries[0].askedAt=Date()
        XCTAssertEqual(value.supersedeDrafting(messageID:"<synthetic-1@example.invalid>"),"r1")
        XCTAssertFalse(value.dotIsDrafting(messageID:"synthetic-1@example.invalid"))
        XCTAssertNil(value.entries[0].requestID)
    }
    func testADraftReadBeforeTheOwnersNewWordsIsNotTaken() throws {
        var context=ReplyContext(id:"c1",envelope:MailDraft(id:-1,subject:"Re: Lunch",sender:"me@example.invalid",to:["sam@example.invalid"],cc:[],bcc:[],body:"",attachmentCount:0))
        context.snapshot=context.envelope
        var request=ReplyOwnerRequest(); request.direction="Say no politely."; request.askedAt=Date()
        context.ownerRequest=request
        context.dotReadAt=request.askedAt.addingTimeInterval(-30)
        XCTAssertThrowsError(try BridgeCoordinator.propose("Yes, Friday works.",expectedRevision:context.snapshotRevision,eventID:nil,context:&context))
        context.dotReadAt=request.askedAt.addingTimeInterval(5)
        XCTAssertNoThrow(try BridgeCoordinator.propose("Sorry, I can't make Friday.",expectedRevision:context.snapshotRevision,eventID:nil,context:&context))
    }
}
