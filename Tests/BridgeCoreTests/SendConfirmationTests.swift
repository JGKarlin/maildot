import XCTest
@testable import BridgeCore

/// The owner's decision: in "draft and send", no message leaves without one confirming act on the Mac.
@MainActor final class SendConfirmationTests: XCTestCase {
    func appliedSendReply(id draftID:Int = -1,token:String? = UUID().uuidString) throws -> (BridgeStore,MCPRouter) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        let store = BridgeStore(directory:url)
        try store.transaction { state in
            let draft = MailDraft(id:draftID,subject:"Re: Test",sender:"owner@example.invalid",to:["recipient@example.invalid"],cc:[],bcc:[],body:"Thank you. I will attend.",attachmentCount:draftID < 0 ? -1 : 0)
            var context = ReplyContext(id:"message",envelope:draft)
            BridgeCoordinator.share(draft,with:&context)
            context.uiEditorToken = token
            var proposal = DotProposal(body:draft.body,revision:1,snapshotRevision:context.snapshotRevision)
            proposal.delivery = .send; proposal.appliedFingerprint = draft.fingerprint
            context.proposal = proposal
            state.contexts[context.id] = context; state.activeContextID = context.id
        }
        return (store,MCPRouter(store:store,statelessTunnel:true))
    }

    func testApplyingInSendModeAsksForConfirmationAndGrantsNothing() throws {
        let (store,_) = try appliedSendReply()
        try store.transaction { state in
            var context = try XCTUnwrap(state.contexts["message"])
            try BridgeCoordinator.requestSendConfirmation(context:&context)
            state.contexts["message"] = context
        }
        let context = try XCTUnwrap(store.read().contexts["message"])
        XCTAssertNil(context.review)
        XCTAssertEqual(context.sendConfirmation?.fingerprint,context.snapshot?.fingerprint)
        XCTAssertEqual(context.sendConfirmation?.snapshotRevision,context.snapshotRevision)
        XCTAssertTrue(try store.read().operations.isEmpty)
    }

    func testConfirmationIsOnlyOfferedForAnAppliedDraftAndSendMail() throws {
        let (store,_) = try appliedSendReply()
        var context = try XCTUnwrap(store.read().contexts["message"])
        context.proposal?.delivery = .save
        XCTAssertThrowsError(try BridgeCoordinator.requestSendConfirmation(context:&context))
        context.proposal?.delivery = .send; context.proposal?.appliedFingerprint = nil
        XCTAssertThrowsError(try BridgeCoordinator.requestSendConfirmation(context:&context))
        XCTAssertNil(context.sendConfirmation)
    }

    func testTheOwnersPressQueuesTheOrdinaryReviewOfTheExactDraft() throws {
        let (store,_) = try appliedSendReply()
        let confirmation = try store.transaction { state -> SendConfirmation in
            var context = try XCTUnwrap(state.contexts["message"])
            try BridgeCoordinator.requestSendConfirmation(context:&context)
            state.contexts["message"] = context
            return try XCTUnwrap(context.sendConfirmation)
        }
        try store.transaction { try BridgeCoordinator.confirmSend(contextID:"message",confirmationID:confirmation.id,state:&$0) }
        let state = try store.read()
        let context = try XCTUnwrap(state.contexts["message"])
        XCTAssertNil(context.sendConfirmation)
        XCTAssertNil(context.review, "The press queues the native check; only that check grants the review.")
        let reviews = state.operations.filter { $0.kind == "review" }
        XCTAssertEqual(reviews.count,1)
        XCTAssertEqual(reviews.first?.expectedFingerprint,confirmation.fingerprint)
        XCTAssertEqual(reviews.first?.expectedSnapshotRevision,confirmation.snapshotRevision)
        XCTAssertEqual(reviews.first?.expectedEditorToken,context.uiEditorToken)
    }

    func testStaleMismatchedOrExpiredConfirmationIsRefused() throws {
        let (store,_) = try appliedSendReply()
        let requested = Date()
        let confirmation = try store.transaction { state -> SendConfirmation in
            var context = try XCTUnwrap(state.contexts["message"])
            try BridgeCoordinator.requestSendConfirmation(context:&context,now:requested)
            state.contexts["message"] = context
            return try XCTUnwrap(context.sendConfirmation)
        }
        XCTAssertThrowsError(try store.transaction { try BridgeCoordinator.confirmSend(contextID:"message",confirmationID:UUID().uuidString,state:&$0) })
        XCTAssertThrowsError(try store.transaction { try BridgeCoordinator.confirmSend(contextID:"message",confirmationID:confirmation.id,state:&$0,now:requested.addingTimeInterval(SendConfirmation.lifetime + 1)) })
        try store.transaction { $0.contexts["message"]?.snapshotRevision += 1 }
        XCTAssertThrowsError(try store.transaction { try BridgeCoordinator.confirmSend(contextID:"message",confirmationID:confirmation.id,state:&$0) })
        XCTAssertTrue(try store.read().operations.isEmpty)
    }

    func testAnyChangeToTheReplyWithdrawsTheRequestForConfirmation() throws {
        let (store,_) = try appliedSendReply()
        var context = try XCTUnwrap(store.read().contexts["message"])
        try BridgeCoordinator.requestSendConfirmation(context:&context)
        var shared = context
        BridgeCoordinator.share(try XCTUnwrap(context.snapshot),with:&shared)
        XCTAssertNil(shared.sendConfirmation)
        var proposed = context
        try BridgeCoordinator.propose("New text",expectedRevision:context.snapshotRevision,expectedProposalRevision:1,eventID:nil,delivery:.send,context:&proposed)
        XCTAssertNil(proposed.sendConfirmation)
        var readdressed = context, envelope = context.envelope
        envelope.to = ["someone-else@example.invalid"]
        BridgeCoordinator.observeEnvelope(envelope,context:&readdressed)
        XCTAssertNil(readdressed.sendConfirmation)
    }

    func testOwnerCanWithdrawBothTheRequestAndAGrantedReview() throws {
        let (store,_) = try appliedSendReply(id:1,token:nil)
        try store.transaction { state in
            var context = try XCTUnwrap(state.contexts["message"])
            try BridgeCoordinator.requestSendConfirmation(context:&context)
            context.review = SendReview(draft:try XCTUnwrap(context.snapshot))
            state.contexts["message"] = context
        }
        try store.transaction { try BridgeCoordinator.withdrawSend(contextID:"message",state:&$0) }
        let context = try XCTUnwrap(store.read().contexts["message"])
        XCTAssertNil(context.review); XCTAssertNil(context.sendConfirmation)
    }

    func testDotCannotSendWhileOnlyAConfirmationRequestExists() async throws {
        let (store,router) = try appliedSendReply(id:1,token:nil)
        try store.transaction { state in
            var context = try XCTUnwrap(state.contexts["message"])
            try BridgeCoordinator.requestSendConfirmation(context:&context)
            state.contexts["message"] = context
        }
        let line:JSONValue = ["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"send_reviewed_reply","arguments":["context_id":"message","review_id":.string(UUID().uuidString),"operation_id":.string(UUID().uuidString),"approval_text":"send it"]]]
        let raw = await router.response(try line.text())
        let result = try JSONDecoder().decode(JSONValue.self,from:Data(try XCTUnwrap(raw).utf8))["result"]
        XCTAssertEqual(result["isError"],true)
        XCTAssertTrue(try store.read().operations.filter { $0.kind == "send" }.isEmpty)
    }
}
