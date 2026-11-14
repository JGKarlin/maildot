import XCTest
@testable import BridgeCore

final class CoordinatorTests: XCTestCase {
    func testAcceptedRevisionClearsObsoleteApplicationStatusOnly() throws {
        var context=initial()
        BridgeCoordinator.share(draft(),with:&context)
        try BridgeCoordinator.propose("First",expectedRevision:1,eventID:nil,context:&context)
        context.localStatus="This exact text is already applied in Mail."
        context.dotStatus="Owner requested another time"
        context.proposal?.appliedFingerprint=draft().fingerprint
        XCTAssertThrowsError(try BridgeCoordinator.propose("Stale",expectedRevision:0,expectedProposalRevision:1,eventID:nil,context:&context))
        XCTAssertTrue(context.localStatus.contains("already applied"))
        try BridgeCoordinator.propose("Revised",expectedRevision:1,expectedProposalRevision:1,eventID:nil,context:&context)
        XCTAssertFalse(context.localStatus.contains("already applied"))
        XCTAssertNil(context.proposal?.appliedFingerprint)
        XCTAssertEqual(context.dotStatus,"Owner requested another time")
    }
    func testCanonicalUnicodeHeaderChangeInvalidatesReview() {
        let draft = MailDraft(id:1,subject:"Caf\u{00e9}",sender:"owner@example.invalid",to:["one@example.invalid"],cc:[],bcc:[],body:"Reviewed message",attachmentCount:0)
        var context = ReplyContext(id:"session",envelope:draft)
        BridgeCoordinator.share(draft,with:&context)
        context.review = SendReview(draft:draft)
        var changed = draft; changed.subject = "Cafe\u{0301}"
        XCTAssertNotEqual(changed.fingerprint,draft.fingerprint)
        BridgeCoordinator.observeEnvelope(changed,context:&context)
        XCTAssertNil(context.snapshot)
        XCTAssertNil(context.review)
    }

    func testInFlightShareCannotUndoHeaderInvalidation() throws {
        let draft = MailDraft(id:1,subject:"Test",sender:"owner@example.invalid",to:["one@example.invalid"],cc:[],bcc:[],body:"Reviewed message",attachmentCount:0)
        var context = ReplyContext(id:"session",envelope:draft)
        BridgeCoordinator.share(draft,with:&context)
        let capturedRevision = context.snapshotRevision
        let capturedEnvelope = context.envelope
        var changed = draft; changed.to = ["two@example.invalid"]
        BridgeCoordinator.observeEnvelope(changed,context:&context)
        var state = BridgeState(); state.contexts[context.id] = context
        XCTAssertThrowsError(try BridgeCoordinator.completeShare(draft,contextID:context.id,expectedRevision:capturedRevision,expectedEnvelope:capturedEnvelope,state:&state))
        XCTAssertNil(state.contexts[context.id]?.snapshot)
        XCTAssertNil(state.activeContextID)
        XCTAssertNil(state.contexts[context.id]?.event)
    }

    func testUnchangedInFlightShareCommits() throws {
        let draft = MailDraft(id:1,subject:"Test",sender:"owner@example.invalid",to:["one@example.invalid"],cc:[],bcc:[],body:"Reviewed message",attachmentCount:0)
        let context = ReplyContext(id:"session",envelope:draft)
        var state = BridgeState(); state.contexts[context.id] = context
        try BridgeCoordinator.completeShare(draft,contextID:context.id,expectedRevision:context.snapshotRevision,expectedEnvelope:context.envelope,state:&state)
        XCTAssertEqual(state.contexts[context.id]?.snapshot?.fingerprint,draft.fingerprint)
        XCTAssertEqual(state.activeContextID,context.id)
    }
    func testFreshHeaderEditInvalidatesSharedSnapshotAndReview() {
        let draft = MailDraft(id:1,subject:"Test",sender:"owner@example.invalid",to:["one@example.invalid"],cc:[],bcc:[],body:"Reviewed message",attachmentCount:0)
        var context = ReplyContext(id:"session",envelope:draft)
        BridgeCoordinator.share(draft,with:&context)
        context.review = SendReview(draft:draft)
        let revision = context.snapshotRevision
        var changed = draft
        changed.to = ["One@example.invalid"]
        BridgeCoordinator.observeEnvelope(changed,context:&context)
        XCTAssertNil(context.snapshot)
        XCTAssertNil(context.review)
        XCTAssertGreaterThan(context.snapshotRevision,revision)
        XCTAssertEqual(context.envelope.to,["One@example.invalid"])
    }

    func testRepeatedHeaderObservationPreservesReview() {
        let draft = MailDraft(id:1,subject:"Test",sender:"owner@example.invalid",to:["one@example.invalid"],cc:[],bcc:[],body:"Reviewed message",attachmentCount:0)
        var envelope = draft; envelope.id = -1; envelope.body = ""; envelope.attachmentCount = -1
        var context = ReplyContext(id:"session",envelope:envelope)
        BridgeCoordinator.share(draft,with:&context)
        let review = SendReview(draft:draft)
        context.review = review
        BridgeCoordinator.observeEnvelope(envelope,context:&context)
        XCTAssertEqual(context.snapshot?.fingerprint,draft.fingerprint)
        XCTAssertEqual(context.review?.id,review.id)
    }
    func draft(_ text: String = "Original") -> MailDraft {
        MailDraft(id: 41, subject: "Re: Synthetic", sender: "sender@example.invalid",
                  to: ["recipient@example.invalid"], cc: [], bcc: [], body: text, attachmentCount: 0)
    }
    func initial() -> ReplyContext { ReplyContext(id: "session-a", envelope: draft()) }

    func testSharePreservesDotStatusAndInvalidatesStaleReview() throws {
        var context = initial()
        context.dotStatus = "Waiting for your decision"
        context.review = SendReview(draft: draft())
        BridgeCoordinator.share(draft("Changed"), with: &context)
        XCTAssertEqual(context.dotStatus, "Waiting for your decision")
        XCTAssertNil(context.review)
        XCTAssertEqual(context.snapshotRevision, 1)
        XCTAssertNotNil(context.event)
    }

    func testProposalRequiresCurrentSnapshotRevision() throws {
        var context = initial()
        BridgeCoordinator.share(draft(), with: &context)
        XCTAssertThrowsError(try BridgeCoordinator.propose("Message", expectedRevision: 0, eventID: nil, context: &context))
        try BridgeCoordinator.propose("Message", expectedRevision: 1, eventID: context.event?.id, context: &context)
        XCTAssertEqual(context.proposal?.body, "Message")
        XCTAssertNotNil(context.event?.reviewedAt)
    }

    func testProposalCannotModifyAnotherEventsReviewReceipt() throws {
        var context = initial()
        BridgeCoordinator.share(draft(), with: &context)
        XCTAssertThrowsError(try BridgeCoordinator.propose("Message", expectedRevision: 1, eventID: "wrong-event", context: &context))
        XCTAssertNil(context.proposal)
    }

    func testSendReviewIsConsumedBeforeNativeSubmission() throws {
        var context = initial()
        BridgeCoordinator.share(draft(), with: &context)
        context.review = SendReview(draft: draft())
        let id = try XCTUnwrap(context.review?.id)
        try BridgeCoordinator.consumeReview(id, live: draft(), context: &context)
        XCTAssertEqual(context.review?.consumed, true)
        XCTAssertThrowsError(try BridgeCoordinator.consumeReview(id, live: draft(), context: &context))
    }

    func testSendReviewRejectsLiveEdits() throws {
        var context = initial()
        BridgeCoordinator.share(draft(), with: &context)
        context.review = SendReview(draft: draft())
        XCTAssertThrowsError(try BridgeCoordinator.consumeReview(context.review!.id, live: draft("Edited"), context: &context))
    }

    func testStaleDotProposalCannotOverwriteEditedText() throws {
        var context = initial()
        BridgeCoordinator.share(draft(), with: &context)
        try BridgeCoordinator.propose("First", expectedRevision: 1, eventID: nil, context: &context)
        context.proposal?.body = "User correction"
        context.proposal?.revision += 1
        XCTAssertThrowsError(try BridgeCoordinator.propose("Stale replacement", expectedRevision: 1, expectedProposalRevision: 1, eventID: nil, context: &context))
        XCTAssertEqual(context.proposal?.body, "User correction")
    }

    func testNativeApplyCannotAdoptANewerUnseenProposal() throws {
        var context = initial()
        BridgeCoordinator.share(draft(),with:&context)
        try BridgeCoordinator.propose("Seen",expectedRevision:1,eventID:nil,context:&context)
        try BridgeCoordinator.propose("Unseen",expectedRevision:1,expectedProposalRevision:1,eventID:nil,context:&context)
        var state = BridgeState(); state.contexts[context.id] = context
        XCTAssertThrowsError(try BridgeCoordinator.enqueueApply(contextID:context.id,displayedFingerprint:draft().fingerprint,
            displayedProposalRevision:1,reviewedBody:"Seen",state:&state))
        XCTAssertTrue(state.operations.isEmpty)
        XCTAssertEqual(state.contexts[context.id]?.proposal?.body,"Unseen")
    }

    func testNativeReviewCannotBindANewerUnseenSnapshot() throws {
        var context = initial()
        BridgeCoordinator.share(draft("Unseen"),with:&context)
        var state = BridgeState(); state.contexts[context.id] = context
        XCTAssertThrowsError(try BridgeCoordinator.enqueueReview(contextID:context.id,displayedFingerprint:draft("Seen").fingerprint,state:&state))
        XCTAssertTrue(state.operations.isEmpty)
    }

    func testEditingAppliedProposalQueuesThatExactVersionAndClearsEvidence() throws {
        var context = initial()
        BridgeCoordinator.share(draft(),with:&context)
        try BridgeCoordinator.propose("Previous",expectedRevision:1,eventID:nil,context:&context)
        context.proposal?.appliedFingerprint = draft().fingerprint
        var state = BridgeState(); state.contexts[context.id] = context
        try BridgeCoordinator.enqueueApply(contextID:context.id,displayedFingerprint:draft().fingerprint,
            displayedProposalRevision:1,reviewedBody:"Edited",state:&state)
        XCTAssertEqual(state.operations.count,1)
        XCTAssertEqual(state.operations[0].proposalRevision,2)
        XCTAssertEqual(state.contexts[context.id]?.proposal?.body,"Edited")
        XCTAssertNil(state.contexts[context.id]?.proposal?.appliedFingerprint)
    }
}
