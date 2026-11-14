import XCTest
@testable import BridgeCore

/// The owner's rule: every mail is either drafted and saved, or drafted and sent, and Dot must ask which.
@MainActor final class DeliveryModeTests: XCTestCase {
    func sharedReply() throws -> (BridgeStore, MCPRouter, ReplyContext) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        let store = BridgeStore(directory:url)
        let context = try store.transaction { state -> ReplyContext in
            let draft = MailDraft(id:1,subject:"Re: Test",sender:"owner@example.invalid",to:["recipient@example.invalid"],cc:[],bcc:[],body:"Original",attachmentCount:0)
            var context = ReplyContext(id:"message",envelope:draft)
            BridgeCoordinator.share(draft,with:&context)
            state.contexts[context.id] = context; state.activeContextID = context.id
            return context
        }
        return (store, MCPRouter(store:store,statelessTunnel:true), context)
    }
    func call(_ router:MCPRouter,_ name:String,_ arguments:JSONValue) async throws -> JSONValue {
        let line:JSONValue = ["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":.string(name),"arguments":arguments]]
        let raw = await router.response(try line.text())
        return try JSONDecoder().decode(JSONValue.self,from:Data(try XCTUnwrap(raw).utf8))["result"]
    }
    func propose(_ router:MCPRouter,_ context:ReplyContext,delivery:String?) async throws -> JSONValue {
        var arguments:[String:JSONValue] = ["context_id":.string(context.id),"snapshot_revision":.number(Double(context.snapshotRevision)),"proposal_revision":0,"body":"Thank you. I will attend."]
        if let delivery { arguments["delivery"] = .string(delivery) }
        return try await call(router,"propose_reply",.object(arguments))
    }

    func testProposalRecordsTheOwnersChoiceAndQueuesItForTheMailDraft() async throws {
        let (store, router, context) = try sharedReply()
        let result = try await propose(router,context,delivery:"send")
        XCTAssertEqual(result["isError"],false)
        let state = try store.read()
        XCTAssertEqual(state.contexts["message"]?.proposal?.delivery,.send)
        let queued = state.operations.filter { $0.kind == "apply" && $0.contextID == "message" }
        XCTAssertEqual(queued.count,1)
        XCTAssertEqual(queued.first?.expectedFingerprint,context.snapshot?.fingerprint)
        XCTAssertEqual(queued.first?.proposalRevision,1)
    }

    func testDraftAndSaveIsRecordedAndAlsoQueued() async throws {
        let (store, router, context) = try sharedReply()
        _ = try await propose(router,context,delivery:"save")
        XCTAssertEqual(try store.read().contexts["message"]?.proposal?.delivery,.save)
        XCTAssertEqual(try store.read().operations.filter { $0.kind == "apply" }.count,1)
    }

    func testProposalMadeWithoutAskingIsRefusedAndTellsDotToAsk() async throws {
        let (store, router, context) = try sharedReply()
        let result = try await propose(router,context,delivery:nil)
        XCTAssertEqual(result["isError"],true)
        XCTAssertEqual(result["content"].array?.first?["text"].string,"Ask the owner whether to draft and save or draft and send, then call propose_reply again with delivery set to save or send.")
        XCTAssertNil(try store.read().contexts["message"]?.proposal)
        XCTAssertTrue(try store.read().operations.isEmpty)
    }

    func testMailWhoseModeWasNeverChosenCannotBeSent() async throws {
        let (store, router, _) = try sharedReply()
        let reviewID = try store.transaction { state -> String in
            var context = try XCTUnwrap(state.contexts["message"])
            try BridgeCoordinator.propose("Text from an older build",expectedRevision:context.snapshotRevision,eventID:nil,context:&context)
            let review = SendReview(draft:try XCTUnwrap(context.snapshot))
            context.review = review; state.contexts["message"] = context
            return review.id
        }
        let result = try await call(router,"send_reviewed_reply",["context_id":"message","review_id":.string(reviewID),"operation_id":.string(UUID().uuidString),"approval_text":"send it"])
        XCTAssertEqual(result["isError"],true)
        XCTAssertTrue(try store.read().operations.filter { $0.kind == "send" }.isEmpty)
    }

    func testUnknownChoiceIsRefused() async throws {
        let (store, router, context) = try sharedReply()
        let result = try await propose(router,context,delivery:"later")
        XCTAssertEqual(result["isError"],true)
        XCTAssertNil(try store.read().contexts["message"]?.proposal)
    }

    func testDraftOnlyMailCannotBeSent() async throws {
        let (store, router, context) = try sharedReply()
        _ = try await propose(router,context,delivery:"save")
        let reviewID = try store.transaction { state -> String in
            let draft = try XCTUnwrap(state.contexts["message"]?.snapshot)
            let review = SendReview(draft:draft)
            state.contexts["message"]?.review = review
            return review.id
        }
        let result = try await call(router,"send_reviewed_reply",["context_id":"message","review_id":.string(reviewID),"operation_id":.string(UUID().uuidString),"approval_text":"send it"])
        XCTAssertEqual(result["isError"],true)
        XCTAssertEqual(result["content"].array?.first?["text"].string,"The owner chose draft and save for this mail, so nothing was sent. Ask the owner again before sending.")
        XCTAssertTrue(try store.read().operations.filter { $0.kind == "send" }.isEmpty)
    }

    func testProposalThatApplyCouldNotTypeIsRefusedWhenItIsMade() async throws {
        let (store, router, context) = try sharedReply()
        for body in [String(repeating:"x",count:ApplyLimits.maximumUTF16 + 1),"Column\tColumn"] {
            let arguments:JSONValue = ["context_id":.string(context.id),"snapshot_revision":.number(Double(context.snapshotRevision)),"proposal_revision":0,"body":.string(body),"delivery":"save"]
            let result = try await call(router,"propose_reply",arguments)
            XCTAssertEqual(result["isError"],true)
        }
        XCTAssertNil(try store.read().contexts["message"]?.proposal)
        XCTAssertTrue(try store.read().operations.isEmpty)
    }

    func testSendRecordsWhatAuthorizedItAndItsResultCanBeReadLater() async throws {
        let (store, router, context) = try sharedReply()
        _ = try await propose(router,context,delivery:"send")
        let reviewID = try store.transaction { state -> String in
            state.operations.removeAll()
            let review = SendReview(draft:try XCTUnwrap(state.contexts["message"]?.snapshot))
            state.contexts["message"]?.review = review
            return review.id
        }
        let operationID = UUID().uuidString
        // No companion runs in this test, so the send tool waits and then reports that no result arrived.
        let request:JSONValue = ["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"send_reviewed_reply","arguments":["context_id":"message","review_id":.string(reviewID),"operation_id":.string(operationID),"approval_text":"Yes, send that message now."]]]
        let requestText = try request.text()
        let sending = Task { await router.response(requestText) }
        try await Task.sleep(for:.milliseconds(300))
        XCTAssertEqual(try store.read().operations.first { $0.id == operationID }?.approvalText,"Yes, send that message now.")
        let pending = try await call(router,"get_send_result",["operation_id":.string(operationID)])
        XCTAssertEqual(pending["structuredContent"]["state"],"pending")
        try store.transaction { state in
            let index = try XCTUnwrap(state.operations.firstIndex { $0.id == operationID })
            state.operations[index].result = "Mail accepted the reviewed Send action. Delivery is not confirmed."
        }
        let finishedText = await sending.value
        let finished = try JSONDecoder().decode(JSONValue.self,from:Data(try XCTUnwrap(finishedText).utf8))["result"]
        XCTAssertEqual(finished["isError"],false)
        let done = try await call(router,"get_send_result",["operation_id":.string(operationID)])
        XCTAssertEqual(done["structuredContent"]["state"],"finished")
        let unknown = try await call(router,"get_send_result",["operation_id":.string(UUID().uuidString)])
        XCTAssertEqual(unknown["isError"],true)
    }

    func testDotIsToldToAskAndHowToAnswer() throws {
        XCTAssertTrue(MCPRouter.instructions.contains("draft and save or draft and send"))
        let tool = try XCTUnwrap(MCPRouter.tools.first { $0["name"] == "propose_reply" })
        XCTAssertEqual(tool["inputSchema"]["properties"]["delivery"]["enum"].array,["save","send"])
        XCTAssertTrue(tool["inputSchema"]["required"].array?.contains("delivery") == true)
        XCTAssertTrue(MailWorkflowTools.instructions.contains("draft and save or draft and send"))
        XCTAssertTrue(ScheduledMailUpdateTools.instructions.contains("never sends"))
    }
}
