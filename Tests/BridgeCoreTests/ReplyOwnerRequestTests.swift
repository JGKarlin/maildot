import XCTest
@testable import BridgeCore

/// The reply panel as the owner specified it: opening it sets Dot drafting; the owner says on the panel
/// whether the reply is saved, sent or ignored; Dot's questions are answered there with one press or a line
/// of text; and one confirmation on the Mac is all a send needs.
final class ReplyOwnerRequestTests:XCTestCase {
    private let draft=MailDraft(id:-1,subject:"Re: Meeting",sender:"owner@example.invalid",to:["colleague@example.invalid"],cc:[],bcc:[],body:"\n\nOn Monday a colleague wrote:\n> Thursday at 14:00?",attachmentCount:0)
    private func shared(opened:Bool=true) -> BridgeState {
        var state=BridgeState()
        var context=ReplyContext(id:"reply",envelope:draft,originalSubject:"Meeting",originalSender:"Colleague <colleague@example.invalid>")
        if opened { BridgeCoordinator.ownerOpensPanel(context:&context) }
        BridgeCoordinator.share(draft,with:&context)
        context.uiEditorToken=UUID().uuidString
        state.contexts["reply"]=context; state.activeContextID="reply"
        return state
    }

    func testOpeningThePanelAsksDotForADraftAtOnce() throws {
        let state=shared()
        let context=try XCTUnwrap(state.contexts["reply"])
        XCTAssertEqual(context.ownerRequest?.ignored,false)
        XCTAssertNil(context.ownerRequest?.delivery,"the owner has not yet said save or send")
        let told=try XCTUnwrap(BridgeCoordinator.instruction(for:context))
        XCTAssertTrue(told.contains("Draft the reply now"),told)
        XCTAssertTrue(told.contains("Do not ask the owner whether to save or send"),told)
        XCTAssertTrue(told.contains("delivery save"),"until the owner chooses, the draft is only saved: \(told)")
        XCTAssertNil(BridgeCoordinator.instruction(for:shared(opened:false).contexts["reply"]!),"a message shared the old way carries no request")
    }
    func testOpeningThePanelAgainChangesNothing() throws {
        var state=shared()
        try BridgeCoordinator.ownerChooses(.send,contextID:"reply",state:&state)
        let before=state.contexts["reply"]?.ownerRequest
        BridgeCoordinator.ownerOpensPanel(context:&state.contexts["reply"]!)
        XCTAssertEqual(state.contexts["reply"]?.ownerRequest,before)
    }
    func testTheOwnersChoiceOfSaveOrSendIsToldToDotAndGovernsTheDraft() throws {
        var state=shared()
        let firstEvent=state.contexts["reply"]?.event?.id
        try BridgeCoordinator.ownerChooses(.send,contextID:"reply",state:&state)
        var context=try XCTUnwrap(state.contexts["reply"])
        XCTAssertEqual(context.ownerRequest?.delivery,.send)
        XCTAssertNotEqual(context.event?.id,firstEvent,"Dot is told by a new event")
        XCTAssertTrue(try XCTUnwrap(BridgeCoordinator.instruction(for:context)).contains("delivery send"))
        // Dot proposes as save, having read the message before the choice: the owner's own choice stands.
        try BridgeCoordinator.propose("Thursday at 14:00 suits me.",expectedRevision:context.snapshotRevision,eventID:nil,delivery:.save,context:&context)
        XCTAssertEqual(context.proposal?.delivery,.send,"what the owner pressed on the Mac outranks what Dot reports of it")
        state.contexts["reply"]=context
        try BridgeCoordinator.ownerChooses(.save,contextID:"reply",state:&state)
        XCTAssertEqual(state.contexts["reply"]?.proposal?.delivery,.save)
    }
    func testChangingToSaveWithdrawsAnythingReadyToSend() throws {
        var state=shared()
        try BridgeCoordinator.ownerChooses(.send,contextID:"reply",state:&state)
        var context=try XCTUnwrap(state.contexts["reply"])
        try BridgeCoordinator.propose("Thursday suits me.",expectedRevision:context.snapshotRevision,eventID:nil,delivery:.send,context:&context)
        context.proposal?.appliedFingerprint=context.snapshot?.fingerprint
        try BridgeCoordinator.requestSendConfirmation(context:&context)
        state.contexts["reply"]=context
        try BridgeCoordinator.ownerChooses(.save,contextID:"reply",state:&state)
        XCTAssertNil(state.contexts["reply"]?.sendConfirmation)
        XCTAssertNil(state.contexts["reply"]?.review)
    }
    func testADirectionReachesDotAndReplacesTheEarlierOne() throws {
        var state=shared()
        try BridgeCoordinator.ownerDirects("  Decline politely; I am travelling that week. ",contextID:"reply",state:&state)
        try BridgeCoordinator.ownerDirects("Accept, but ask for 15:00.",contextID:"reply",state:&state)
        let context=try XCTUnwrap(state.contexts["reply"])
        XCTAssertEqual(context.ownerRequest?.direction,"Accept, but ask for 15:00.")
        let told=try XCTUnwrap(BridgeCoordinator.instruction(for:context))
        XCTAssertTrue(told.contains("Accept, but ask for 15:00."))
        XCTAssertFalse(told.contains("Decline politely"))
        XCTAssertThrowsError(try BridgeCoordinator.ownerDirects("   ",contextID:"reply",state:&state))
        XCTAssertThrowsError(try BridgeCoordinator.ownerDirects(String(repeating:"x",count:ReplyOwnerRequest.textLimit+1),contextID:"reply",state:&state))
    }
    func testDotsQuestionIsSplitIntoOnePressAnswers() {
        let parsed=BridgeCoordinator.answers(in:"Which time should I propose? 1) Thursday 14:00 2) Friday 10:00 3) Ask them to choose")
        XCTAssertEqual(parsed.question,"Which time should I propose?")
        XCTAssertEqual(parsed.answers,["Thursday 14:00","Friday 10:00","Ask them to choose"])
        let lines=BridgeCoordinator.answers(in:"Accept the invitation?\n1. Yes\n2. No")
        XCTAssertEqual(lines.question,"Accept the invitation?")
        XCTAssertEqual(lines.answers,["Yes","No"])
        let plain=BridgeCoordinator.answers(in:"What should the reply say about the budget of 1) the trip?")
        XCTAssertEqual(plain.answers,[],"one numbered fragment is not a set of answers")
        XCTAssertEqual(plain.question,"What should the reply say about the budget of 1) the trip?")
        XCTAssertEqual(BridgeCoordinator.answers(in:"Send it on 2026-11-12 or 2026-11-13?").answers,[])
    }
    func testAnAnswerGoesToDotWithItsQuestionAndClearsTheQuestion() throws {
        var state=shared()
        state.contexts["reply"]?.dotQuestion="Which time? 1) Thursday 2) Friday"
        try BridgeCoordinator.ownerAnswers("Friday",contextID:"reply",state:&state)
        let context=try XCTUnwrap(state.contexts["reply"])
        XCTAssertNil(context.dotQuestion,"an answered question is no longer asked")
        XCTAssertEqual(context.ownerRequest?.answers.last?.question,"Which time? 1) Thursday 2) Friday")
        XCTAssertEqual(context.ownerRequest?.answers.last?.answer,"Friday")
        XCTAssertTrue(try XCTUnwrap(BridgeCoordinator.instruction(for:context)).contains("Friday"))
        XCTAssertThrowsError(try BridgeCoordinator.ownerAnswers("Thursday",contextID:"reply",state:&state),"there is no question left to answer")
    }
    func testIgnoringTellsDotToLeaveTheMessageAndWithdrawsEverything() throws {
        var state=shared()
        try BridgeCoordinator.ownerChooses(.send,contextID:"reply",state:&state)
        try BridgeCoordinator.ownerIgnores(contextID:"reply",state:&state)
        var context=try XCTUnwrap(state.contexts["reply"])
        XCTAssertEqual(context.ownerRequest?.ignored,true)
        XCTAssertNil(context.sendConfirmation); XCTAssertNil(context.review)
        let told=try XCTUnwrap(BridgeCoordinator.instruction(for:context))
        XCTAssertTrue(told.contains("ignore"),told)
        XCTAssertFalse(told.contains("Draft the reply now"))
        XCTAssertThrowsError(try BridgeCoordinator.propose("Text",expectedRevision:context.snapshotRevision,eventID:nil,delivery:.save,context:&context),"Dot cannot draft a reply the owner set aside")
        try BridgeCoordinator.ownerResumes(contextID:"reply",state:&state)
        XCTAssertEqual(state.contexts["reply"]?.ownerRequest?.ignored,false)
    }

    // MARK: One confirmation, then Mail Dot sends

    private func confirmed() throws -> (BridgeState,String) {
        var state=shared()
        try BridgeCoordinator.ownerChooses(.send,contextID:"reply",state:&state)
        var context=try XCTUnwrap(state.contexts["reply"])
        try BridgeCoordinator.propose("Thursday suits me.",expectedRevision:context.snapshotRevision,eventID:nil,delivery:.send,context:&context)
        var applied=draft; applied.body="Thursday suits me."
        context.snapshot=applied; context.snapshotRevision += 1
        context.proposal?.snapshotRevision=context.snapshotRevision; context.proposal?.appliedFingerprint=applied.fingerprint
        try BridgeCoordinator.requestSendConfirmation(context:&context)
        state.contexts["reply"]=context
        let confirmation=try XCTUnwrap(context.sendConfirmation)
        try BridgeCoordinator.confirmSendFromPanel(contextID:"reply",confirmationID:confirmation.id,state:&state)
        return (state,applied.fingerprint)
    }
    func testConfirmingOnThePanelQueuesTheReviewAndRemembersThatTheOwnerConfirmed() throws {
        let (state,_)=try confirmed()
        XCTAssertEqual(state.operations.map(\.kind),["review"])
        XCTAssertNotNil(state.contexts["reply"]?.ownerRequest?.sendConfirmedAt)
        XCTAssertNil(state.contexts["reply"]?.sendConfirmation)
    }
    func testAfterTheReviewMailDotQueuesTheSendOnceWithoutWaitingForDot() throws {
        var (state,_)=try confirmed()
        XCTAssertNil(try BridgeCoordinator.enqueueOwnerSend(contextID:"reply",state:&state),"nothing is sent before the review of the exact draft is granted")
        var context=try XCTUnwrap(state.contexts["reply"])
        let live=try XCTUnwrap(context.snapshot)
        try BridgeCoordinator.grantUIReview(live:live,displayedFingerprint:live.fingerprint,expectedRevision:context.snapshotRevision,token:try XCTUnwrap(context.uiEditorToken),context:&context)
        state.contexts["reply"]=context
        let id=try XCTUnwrap(try BridgeCoordinator.enqueueOwnerSend(contextID:"reply",state:&state))
        let send=try XCTUnwrap(state.operations.first{$0.id == id})
        XCTAssertEqual(send.kind,"send"); XCTAssertEqual(send.reviewID,context.review?.id)
        XCTAssertTrue(send.approvalText?.contains("Confirm Send") == true)
        XCTAssertNil(state.contexts["reply"]?.ownerRequest?.sendConfirmedAt,"the confirmation is spent")
        XCTAssertNil(try BridgeCoordinator.enqueueOwnerSend(contextID:"reply",state:&state),"one confirmation sends once")
        XCTAssertEqual(state.operations.filter{$0.kind == "send"}.count,1)
    }
    func testNothingIsSentIfTheOwnerDidNotConfirmOnThePanelOrChangedTheirMind() throws {
        // Confirmed the older way (notification, or Dot's voice flow): Dot still has to be told to send.
        var state=shared()
        var context=try XCTUnwrap(state.contexts["reply"])
        try BridgeCoordinator.propose("Thursday suits me.",expectedRevision:context.snapshotRevision,eventID:nil,delivery:.send,context:&context)
        context.proposal?.appliedFingerprint=context.snapshot?.fingerprint
        let live=try XCTUnwrap(context.snapshot)
        try BridgeCoordinator.grantUIReview(live:live,displayedFingerprint:live.fingerprint,expectedRevision:context.snapshotRevision,token:try XCTUnwrap(context.uiEditorToken),context:&context)
        state.contexts["reply"]=context
        XCTAssertNil(try BridgeCoordinator.enqueueOwnerSend(contextID:"reply",state:&state))
        // Confirmed on the panel, then ignored before the review came back.
        var (later,_)=try confirmed()
        try BridgeCoordinator.ownerIgnores(contextID:"reply",state:&later)
        XCTAssertNil(try BridgeCoordinator.enqueueOwnerSend(contextID:"reply",state:&later))
        // Confirmed on the panel, then changed to save.
        var (saved,_)=try confirmed()
        try BridgeCoordinator.ownerChooses(.save,contextID:"reply",state:&saved)
        XCTAssertNil(try BridgeCoordinator.enqueueOwnerSend(contextID:"reply",state:&saved))
    }
    func testAnOldConfirmationSendsNothing() throws {
        var (state,_)=try confirmed()
        var context=try XCTUnwrap(state.contexts["reply"])
        let live=try XCTUnwrap(context.snapshot)
        try BridgeCoordinator.grantUIReview(live:live,displayedFingerprint:live.fingerprint,expectedRevision:context.snapshotRevision,token:try XCTUnwrap(context.uiEditorToken),context:&context)
        state.contexts["reply"]=context
        XCTAssertNil(try BridgeCoordinator.enqueueOwnerSend(contextID:"reply",state:&state,now:Date().addingTimeInterval(SendConfirmation.lifetime+1)))
        XCTAssertTrue(state.operations.filter{$0.kind == "send"}.isEmpty)
    }

    // MARK: Through the tools Dot uses

    func testDotReadsTheOwnersRequestWithTheMessage() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("maildot-reply-"+UUID().uuidString)
        let store=BridgeStore(directory:root)
        var seeded=shared()
        try BridgeCoordinator.ownerDirects("Keep it to two sentences.",contextID:"reply",state:&seeded)
        try store.transaction { $0=seeded }
        let line:JSONValue=["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"get_active_reply","arguments":[:]]]
        let answer=await MCPRouter(store:store,statelessTunnel:true).response(try line.text())
        let response=try XCTUnwrap(answer)
        XCTAssertTrue(response.contains("Keep it to two sentences."),response)
        XCTAssertTrue(response.contains("Draft the reply now"),response)
    }
    func testDotNeedNotSayDeliveryWhereTheOwnerChoosesOnThePanel() async throws {
        // Dot's saved copy of the tool list may be from before the delivery field existed.
        let (state,answer)=try await propose(shared(),delivery:nil)
        XCTAssertEqual(state.contexts["reply"]?.proposal?.body,"Thursday at 14:00 suits me.",answer)
        XCTAssertNil(state.contexts["reply"]?.proposal?.delivery,"still the owner's to choose")
        XCTAssertTrue(state.operations.isEmpty)
        var chosen=shared()
        try BridgeCoordinator.ownerChooses(.save,contextID:"reply",state:&chosen)
        let (placed,_)=try await propose(chosen,delivery:nil)
        XCTAssertEqual(placed.contexts["reply"]?.proposal?.delivery,.save)
        XCTAssertEqual(placed.operations.map(\.kind),["apply"])
        let (old,refusal)=try await propose(shared(opened:false),delivery:nil)
        XCTAssertNil(old.contexts["reply"]?.proposal,"without the panel's request Dot must still ask first")
        XCTAssertTrue(refusal.contains("draft and save or draft and send"),refusal)
    }
    private func propose(_ seeded:BridgeState,delivery:String?) async throws -> (BridgeState,String) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("maildot-reply-"+UUID().uuidString)
        let store=BridgeStore(directory:root)
        try store.transaction { $0=seeded }
        let revision=try XCTUnwrap(seeded.contexts["reply"]).snapshotRevision
        var arguments:[String:JSONValue]=["context_id":"reply","snapshot_revision":.number(Double(revision)),"proposal_revision":0,"body":"Thursday at 14:00 suits me."]
        if let delivery { arguments["delivery"] = .string(delivery) }
        let line:JSONValue=["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"propose_reply","arguments":.object(arguments)]]
        let answer=await MCPRouter(store:store,statelessTunnel:true).response(try line.text())
        return (try store.read(),try XCTUnwrap(answer))
    }
    func testADraftNeverGoesIntoTheMessageBeforeTheOwnerHasChosen() async throws {
        let (state,answer)=try await propose(shared(),delivery:"save")
        XCTAssertNotNil(state.contexts["reply"]?.proposal,"the draft is kept, to be shown on the panel")
        XCTAssertTrue(state.operations.isEmpty,"nothing may overwrite the text of the open message until the owner chooses: \(state.operations.map(\.kind))")
        XCTAssertTrue(answer.contains("shown to the owner"),answer)
        XCTAssertFalse(answer.contains("applying_to_mail_draft"),answer)
    }
    func testOnceTheOwnerHasChosenTheDraftGoesIntoTheMessage() async throws {
        var seeded=shared()
        try BridgeCoordinator.ownerChooses(.send,contextID:"reply",state:&seeded)
        let (state,answer)=try await propose(seeded,delivery:"save")
        XCTAssertEqual(state.operations.map(\.kind),["apply"])
        XCTAssertEqual(state.contexts["reply"]?.proposal?.delivery,.send)
        XCTAssertTrue(answer.contains("Mail Dot then sends"),answer)
        XCTAssertFalse(answer.contains("call send_reviewed_reply only after"),answer)
    }
    func testAMessageSharedWithoutThePanelsRequestBehavesAsBefore() async throws {
        let (state,answer)=try await propose(shared(opened:false),delivery:"save")
        XCTAssertEqual(state.operations.map(\.kind),["apply"])
        XCTAssertTrue(answer.contains("applying_to_mail_draft"),answer)
    }
    func testAnswersNumberedInJapaneseStyleBecomeButtonsToo() {
        XCTAssertEqual(BridgeCoordinator.answers(in:"どの日時を提案しますか？ １）木曜16時 ２）金曜10時").answers,["木曜16時","金曜10時"])
        XCTAssertEqual(BridgeCoordinator.answers(in:"どうしますか？\n① 承諾する\n② 断る\n③ 保留").answers,["承諾する","断る","保留"])
        XCTAssertEqual(BridgeCoordinator.answers(in:"Which? (1) Accept (2) Decline").answers,["Accept","Decline"])
        XCTAssertEqual(BridgeCoordinator.answers(in:"どうしますか？ 1、承諾 2、辞退").answers,["承諾","辞退"])
    }
    // MARK: The request reaches Dot on the channel it acts on

    func testDotIsOwedWordOnceTheMessageIsReadAndWheneverTheRequestChanges() throws {
        var context=ReplyContext(id:"reply",envelope:draft)
        BridgeCoordinator.ownerOpensPanel(context:&context)
        XCTAssertFalse(BridgeCoordinator.dotIsOwedWord(context),"there is nothing to draft from until the message has been read")
        BridgeCoordinator.share(draft,with:&context)
        XCTAssertTrue(BridgeCoordinator.dotIsOwedWord(context))
        context.ownerRequest?.toldDotAt=Date()
        XCTAssertFalse(BridgeCoordinator.dotIsOwedWord(context))
        var state=BridgeState(); state.contexts["reply"]=context
        try BridgeCoordinator.ownerChooses(.send,contextID:"reply",state:&state,now:Date().addingTimeInterval(1))
        XCTAssertFalse(BridgeCoordinator.dotIsOwedWord(state.contexts["reply"]!),"choosing save or send asks nothing of Dot")
        try BridgeCoordinator.ownerDirects("Shorter.",contextID:"reply",state:&state,now:Date().addingTimeInterval(2))
        XCTAssertTrue(BridgeCoordinator.dotIsOwedWord(state.contexts["reply"]!))
        state.contexts["reply"]?.ownerRequest?.toldDotAt=Date().addingTimeInterval(3)
        try BridgeCoordinator.ownerIgnores(contextID:"reply",state:&state,now:Date().addingTimeInterval(4))
        XCTAssertTrue(BridgeCoordinator.dotIsOwedWord(state.contexts["reply"]!),"Dot is told the message was set aside")
        XCTAssertFalse(BridgeCoordinator.dotIsOwedWord(shared(opened:false).contexts["reply"]!))
    }
    func testAReplyRequestNamesItsMessageAndANewerOneReplacesIt() throws {
        let id=UUID().uuidString
        var state=MailWorkflowState()
        let first=try state.requestReply(accountIDs:["mail:a"],allowedAccountIDs:["mail:a"],contextID:id)
        let other=try state.requestReply(accountIDs:["mail:a"],allowedAccountIDs:["mail:a"],contextID:UUID().uuidString)
        let second=try state.requestReply(accountIDs:["mail:a"],allowedAccountIDs:["mail:a"],contextID:id)
        XCTAssertEqual(Set(state.requests.map(\.id)),[other.id,second.id])
        XCTAssertFalse(state.requests.contains{$0.id == first.id})
        XCTAssertTrue(second.needsEventDelivery); XCTAssertFalse(second.opensCall)
        XCTAssertThrowsError(try MailWorkflowRequest(action:.reply,accountIDs:["mail:a"]),"a reply request must name its message")
        XCTAssertThrowsError(try MailWorkflowRequest(action:.reply,accountIDs:["mail:a"],contextID:"not-an-identifier"))
    }
    func testDotIsHandedTheMessageAndTheOwnersRequestInOneRead() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("maildot-reply-"+UUID().uuidString)
        let id=UUID().uuidString
        var context=ReplyContext(id:id,envelope:draft,originalSender:"Colleague <colleague@example.invalid>")
        BridgeCoordinator.ownerOpensPanel(context:&context)
        BridgeCoordinator.share(draft,with:&context)
        try BridgeStore(directory:root).transaction { $0.contexts[id]=context; $0.activeContextID=id }
        var settings=MailSettings()
        var profile=MailConnection(id:"profile",email:"owner@example.invalid",connectionID:"link"); profile.observedAt=Date()
        settings.connections=[profile]
        var schedule=MailSchedule(id:"schedule",title:"General email review",accountEmails:[profile.email],cadence:"Every hour",conditions:"Report mail that needs a decision")
        schedule.observedAt=Date(); schedule.sources=[MailScheduleSource(kind:"gmail",id:profile.id,addresses:[profile.email],connectionID:profile.connectionID)]
        settings.schedules=[schedule]; settings.linkedScheduleIDs=[schedule.id]
        try MailSettingsStore(bridgeDirectory:root).transaction { $0=settings }
        let available=try MailWorkflowAccount.available(settings:MailSettingsStore(bridgeDirectory:root).read(),native:NativeMailStore(bridgeDirectory:root).read())
        try XCTSkipIf(available.isEmpty,"no account could be seeded for this store")
        let request=try MailWorkflowStore(bridgeDirectory:root).transaction { try $0.requestReply(accountIDs:available.map(\.id),allowedAccountIDs:Set(available.map(\.id)),contextID:id) }
        let read=try MailWorkflowTools.call("get_mail_workflow",arguments:["request_id":.string(request.id)],bridgeDirectory:root)
        XCTAssertEqual(read["reply"]["available"],.bool(true))
        XCTAssertEqual(read["reply"]["context"]["id"].string,id)
        XCTAssertTrue(read["reply"]["owner_request"].string?.contains("Draft the reply now") == true)
        XCTAssertTrue(read["instructions"].string?.contains("For action reply") == true)
        try BridgeStore(directory:root).transaction { $0.contexts.removeValue(forKey:id) }
        XCTAssertEqual(try MailWorkflowTools.call("get_mail_workflow",arguments:["request_id":.string(request.id)],bridgeDirectory:root)["reply"]["available"],.bool(false))
    }
    // MARK: What is shown outside the panel

    func testTheIndicatorFollowsTheReplyFromDraftingToReady() throws {
        var unread=ReplyContext(id:"reply",envelope:draft)
        BridgeCoordinator.ownerOpensPanel(context:&unread)
        XCTAssertNil(ReplyIndicator(unread),"nothing is shown until the message has been read")
        XCTAssertNil(ReplyIndicator(shared(opened:false).contexts["reply"]!),"nor for a message shared without the panel's request")
        var state=shared()
        var context=try XCTUnwrap(state.contexts["reply"])
        XCTAssertEqual(ReplyIndicator(context),.drafting(revising:false))
        let drafting=ReplyIndicator(context)!.key(for:context)
        try BridgeCoordinator.propose("Thursday at 14:00 suits me.\nAlex",expectedRevision:context.snapshotRevision,eventID:nil,delivery:nil,context:&context)
        XCTAssertEqual(ReplyIndicator(context),.draftReady(preview:"Thursday at 14:00 suits me. Alex",revision:1))
        XCTAssertNotEqual(ReplyIndicator(context)!.key(for:context),drafting,"a new state is announced once")
        XCTAssertTrue(ReplyIndicator(context)!.needsOwner)
        state.contexts["reply"]=context
        try BridgeCoordinator.ownerDirects("Shorter.",contextID:"reply",state:&state,now:Date().addingTimeInterval(5))
        XCTAssertEqual(ReplyIndicator(state.contexts["reply"]!),.drafting(revising:true))
        context=state.contexts["reply"]!
        try BridgeCoordinator.propose("Thursday suits me.",expectedRevision:context.snapshotRevision,expectedProposalRevision:1,eventID:nil,delivery:nil,context:&context)
        context.lastDotUpdate=Date().addingTimeInterval(10)
        XCTAssertEqual(ReplyIndicator(context),.draftReady(preview:"Thursday suits me.",revision:2))
        context.proposal?.appliedFingerprint=context.snapshot?.fingerprint
        XCTAssertEqual(ReplyIndicator(context),.placed)
        XCTAssertFalse(ReplyIndicator(context)!.needsOwner)
    }
    func testAQuestionAndAPendingConfirmationComeFirst() throws {
        var state=shared()
        state.contexts["reply"]?.dotQuestion="Which time? 1) Thursday 2) Friday"
        XCTAssertEqual(ReplyIndicator(state.contexts["reply"]!),.question(text:"Which time?",answers:["Thursday","Friday"]))
        XCTAssertTrue(ReplyIndicator(state.contexts["reply"]!)!.mark.contains("Which time?"))
        try BridgeCoordinator.ownerAnswers("Friday",contextID:"reply",state:&state)
        XCTAssertEqual(ReplyIndicator(state.contexts["reply"]!),.drafting(revising:false))
        try BridgeCoordinator.ownerChooses(.send,contextID:"reply",state:&state)
        var context=state.contexts["reply"]!
        try BridgeCoordinator.propose("Friday suits me.",expectedRevision:context.snapshotRevision,eventID:nil,delivery:nil,context:&context)
        context.lastDotUpdate=Date().addingTimeInterval(5)
        context.proposal?.appliedFingerprint=context.snapshot?.fingerprint
        try BridgeCoordinator.requestSendConfirmation(context:&context)
        XCTAssertEqual(ReplyIndicator(context),.confirmSend)
        state.contexts["reply"]=context
        try BridgeCoordinator.ownerIgnores(contextID:"reply",state:&state)
        XCTAssertNil(ReplyIndicator(state.contexts["reply"]!),"a message set aside shows nothing")
    }
    func testTheWordsNameWhomTheReplyIsTo() {
        var context=ReplyContext(id:"reply",envelope:draft,originalSender:"Aiko Tanaka <tanaka@example.invalid>")
        XCTAssertEqual(context.replyingTo,"Aiko Tanaka")
        XCTAssertEqual(ReplyIndicator.drafting(revising:false).title(to:context.replyingTo),"Dot is drafting your reply to Aiko Tanaka")
        context.originalSender=""
        XCTAssertEqual(context.replyingTo,"colleague@example.invalid")
        context.originalSender="\"Owner\" <OWNER@example.invalid>"
        XCTAssertEqual(context.replyingTo,"colleague@example.invalid","seen live: a draft reopened from Drafts named the owner")
        XCTAssertEqual(ReplyIndicator.draftReady(preview:"",revision:1).title(to:nil),"Dot’s draft is ready: reply")
    }
    // MARK: The reply goes above the quoted mail, which is left alone

    private let japanese="\n\n2026/11/11 20:00、田中 愛子 <tanaka@example.invalid>のメール:\n\n田中です。\n\n来週の研究会は木曜日の14時からでよろしいでしょうか。\n\n先週のメール（合成データ）:\n会場は3号館の会議室を予定しています。\n\nよろしくお願いいたします。\n田中\n"
    func testAThreadDotRepeatedIsCutOffTheReply() {
        let reply="田中様\n\n木曜日の14時で問題ありません。\n\nよろしくお願いいたします。\n鈴木"
        XCTAssertEqual(ReplyInsertion.replyOnly(reply+japanese,above:japanese),reply,"the quoted Japanese thread is not typed again")
        let quoted=reply+"\n\n> 2026/11/11 20:00、田中 愛子 <tanaka@example.invalid>のメール:\n>\n> 田中です。\n> 来週の研究会は木曜日の14時からでよろしいでしょうか。"
        XCTAssertEqual(ReplyInsertion.replyOnly(quoted,above:japanese),reply,"nor when Dot marks it as quoted")
        XCTAssertEqual(ReplyInsertion.replyOnly(reply,above:japanese),reply,"a reply that repeats nothing is kept whole, its closing line included, though the quoted mail closes the same way")
        XCTAssertEqual(ReplyInsertion.replyOnly("Thank you.\n\nAlex\n",above:"\n\nOn Nov 9, 2026, at 9:00, Mail Bridge Test <sender@example.invalid> wrote:\n\nThank you.\n\nAlex"),"Thank you.\n\nAlex")
        XCTAssertEqual(ReplyInsertion.replyOnly("Agreed.\n\nOn Nov 9, 2026, at 9:00, Mail Bridge Test <sender@example.invalid> wrote:\n",above:"\n\nOn Nov 9, 2026, at 9:00, Mail Bridge Test <sender@example.invalid> wrote:"),"Agreed.","one long line of the message is enough to recognise it")
        XCTAssertEqual(ReplyInsertion.replyOnly(japanese,above:japanese),ReplyInsertion.replyOnly(japanese,above:""),"a text that is nothing but the thread is not reduced to nothing")
    }
    func testOnlyTheReplyIsTypedAndBlankSpaceOnlyIfTheMessageLacksIt() {
        XCTAssertEqual(ReplyInsertion.typed(reply:"木曜日で結構です。\n\n",above:japanese),"木曜日で結構です。","a new reply in Mail already begins with an empty line and a blank line")
        XCTAssertEqual(ReplyInsertion.typed(reply:"Agreed.",above:"\nOn Monday…"),"Agreed.\n")
        XCTAssertEqual(ReplyInsertion.typed(reply:"Agreed.",above:"Text the owner typed"),"Agreed.\n\n")
        XCTAssertEqual(ReplyInsertion.typed(reply:"Agreed.",above:""),"Agreed.")
    }
    func testOnThePanelsRequestDotsDraftIsKeptAsTheReplyAlone() throws {
        var context=ReplyContext(id:"reply",envelope:draft)
        BridgeCoordinator.ownerOpensPanel(context:&context)
        var message=draft; message.body=japanese
        BridgeCoordinator.share(message,with:&context)
        try BridgeCoordinator.propose("木曜日の14時で問題ありません。"+japanese,expectedRevision:context.snapshotRevision,eventID:nil,delivery:nil,context:&context)
        XCTAssertEqual(context.proposal?.body,"木曜日の14時で問題ありません。")
        // Once inserted, a revision is compared with the message below the earlier reply, not with that reply.
        context.insertedTop="木曜日の14時で問題ありません。"
        var placed=message; placed.body="木曜日の14時で問題ありません。"+japanese
        BridgeCoordinator.share(placed,with:&context)
        XCTAssertEqual(context.insertedTop,"木曜日の14時で問題ありません。")
        XCTAssertEqual(context.bodyBelowReply,japanese)
        var edited=placed; edited.body="自分で書き直しました。"+japanese
        BridgeCoordinator.share(edited,with:&context)
        XCTAssertNil(context.insertedTop,"text the owner changed at the top is the owner's, and is never replaced")
        // Without the panel's request the older behaviour stands: the whole text is Dot's.
        var old=ReplyContext(id:"old",envelope:draft)
        BridgeCoordinator.share(message,with:&old)
        try BridgeCoordinator.propose("Reply."+japanese,expectedRevision:old.snapshotRevision,eventID:nil,delivery:.save,context:&old)
        XCTAssertEqual(old.proposal?.body,"Reply."+japanese)
    }
    func testUndoAfterAFailedInsertionNeverTouchesTheQuotedMail() {
        let original=japanese,typed="木曜日で結構です。"
        XCTAssertEqual(UndoRestoration.next(current:"木曜日で"+original,original:original,typed:typed,remainder:original,presses:0,piecesTyped:2),.press)
        XCTAssertEqual(UndoRestoration.next(current:original,original:original,typed:typed,remainder:original,presses:1,piecesTyped:2),.restored)
        XCTAssertEqual(UndoRestoration.next(current:"木曜日で"+String(original.dropLast(5)),original:original,typed:typed,remainder:original,presses:0,piecesTyped:2),.stop,"if the quoted mail no longer reads as it did, nothing more is undone")
        XCTAssertEqual(UndoRestoration.next(current:"別の文"+original,original:original,typed:typed,remainder:original,presses:0,piecesTyped:2),.stop,"text that is not Mail Dot's typing is not undone")
        XCTAssertEqual(UndoRestoration.next(current:"木曜日で"+original,original:original,typed:typed,remainder:original,presses:4,piecesTyped:2),.stop)
    }
    // MARK: Automatic drafts

    private func settings(automatic:Bool?) -> MailSettings {
        var settings=MailSettings()
        var profile=MailConnection(id:"profile",email:"owner@example.invalid",connectionID:"link"); profile.observedAt=Date()
        settings.connections=[profile]
        var schedule=MailSchedule(id:"schedule",title:"General email review",accountEmails:[profile.email],cadence:"Every hour",conditions:"Report mail that needs a decision")
        schedule.observedAt=Date(); schedule.sources=[MailScheduleSource(kind:"gmail",id:profile.id,addresses:[profile.email],connectionID:profile.connectionID)]
        settings.schedules=[schedule]; settings.linkedScheduleIDs=[schedule.id]
        settings.automaticDrafts=automatic
        return settings
    }
    private func update(_ shape:(inout ScheduledMailUpdate)->Void) throws -> ScheduledMailUpdate {
        let fields:[String:Any]=["id":"item","scheduleID":"schedule","runID":"run","revision":0,"accountIDs":["gmail:profile"],"sourceIDs":["gmail:message:18c0ffee18c0ffee"],
            "title":"Tanaka asks about Thursday","summary":"Tanaka proposes Thursday at 14:00.","action":"reply","actionText":"Reply to confirm the time.","checkedAt":Date().addingTimeInterval(-600).ISO8601Format(),"coverage":"One message read in full."]
        let decoder=JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var value=try decoder.decode(ScheduledMailUpdate.self,from:JSONSerialization.data(withJSONObject:fields))
        shape(&value)
        return value
    }
    func testAutomaticRepliesAreOnForEveryAccountUntilTheOwnerSwitchesOneOff() throws {
        var settings=settings(automatic:nil)
        settings.nativeAccounts=[NativeMailAccount(id:"icloud",name:"iCloud",addresses:["owner@icloud.example.invalid"],server:"imap.mail.me.com")]
        XCTAssertTrue(settings.automaticReplies(account:"gmail:profile"),"on by default")
        XCTAssertTrue(settings.automaticReplies(forRecipients:["owner@example.invalid"]))
        XCTAssertTrue(settings.automaticReplies(forRecipients:[]),"mail to no known account follows the default")
        settings.setAutomaticReplies(false,account:"mail:icloud")
        XCTAssertFalse(settings.automaticReplies(forRecipients:["OWNER@icloud.example.invalid"]),"off for the iCloud account")
        XCTAssertTrue(settings.automaticReplies(forRecipients:["owner@example.invalid"]),"still on for Gmail")
        XCTAssertEqual(settings.accountIDs(receiving:["owner@example.invalid","owner@icloud.example.invalid"]),["gmail:profile","mail:icloud"])
        settings.setAutomaticReplies(true,account:"mail:icloud")
        XCTAssertNil(settings.automaticRepliesOff)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(MailSettings())) as? [String:Any])
        object.removeValue(forKey:"automaticRepliesOff")
        XCTAssertTrue(try JSONDecoder().decode(MailSettings.self,from:JSONSerialization.data(withJSONObject:object)).automaticReplies(forRecipients:["a@example.invalid"]),"settings saved before this build load with replies on")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("maildot-auto-"+UUID().uuidString)
        try MailSettingsStore(bridgeDirectory:root).transaction { $0=settings }
        let told=try ScheduledMailUpdateTools.call("get_scheduled_mail_updates",arguments:[:],bridgeDirectory:root)["instructions"].string ?? ""
        XCTAssertFalse(told.contains("automatic drafting"),"the scheduled reviews are not told to triage all mail; the Mac's filter decides what Dot is asked")
    }
    func testAReplyDotWroteAheadIsReadFromEitherPlaceItCanPutIt() throws {
        let reply="田中様\n\n木曜日の14時で問題ありません。"
        XCTAssertEqual(try update { $0.draft=MailUpdateDraft(delivery:.save,to:["tanaka@example.invalid"],preview:"田中様 木曜日の…",text:reply) }.preparedReply,reply)
        let older=try update { $0.actionText="Reply to confirm the time.\nDraft reply:\n"+reply }
        XCTAssertEqual(older.preparedReply,reply,"an older tool list carries it after a line in actionText")
        XCTAssertEqual(older.actionTextShown,"Reply to confirm the time.","and the owner is not shown it twice")
        XCTAssertEqual(MailUpdatePresentation(older).status,.draftedQueued)
        XCTAssertEqual(try update { $0.draft=MailUpdateDraft(delivery:.save,to:["a@example.invalid"],preview:"Thursday suits me.") }.preparedReply,"Thursday suits me.")
        XCTAssertNil(try update { $0.draft=MailUpdateDraft(delivery:.save,to:["a@example.invalid"],preview:"Thursday suits me, and…") }.preparedReply,"a preview that was cut short is not the reply")
        XCTAssertNil(try update { _ in }.preparedReply)
        XCTAssertThrowsError(try update { $0.draft=MailUpdateDraft(delivery:.save,to:["a@example.invalid"],preview:"x",text:String(repeating:"x",count:MailUpdateDraft.textLimit+1)) }.validate())
    }
    func testADraftWrittenAheadIsWaitingInThePanelWhenTheOwnerOpensReply() throws {
        let reply="木曜日の14時で問題ありません。"
        let written=try update { $0.message=MailUpdateMessage(sender:"tanaka@example.invalid",subject:"研究会の日程"); $0.draft=MailUpdateDraft(delivery:.save,to:["tanaka@example.invalid"],preview:reply,text:reply+"\n\n2026/11/11 20:00、田中 愛子 <tanaka@example.invalid>のメール:\n\n田中です。") }
        var reports=ScheduledMailUpdateState()
        let linked=settings(automatic:true)
        try reports.accept(written,settings:linked,accounts:try MailWorkflowAccount.available(settings:linked,native:NativeMailState()))
        var message=draft; message.subject="Re: 研究会の日程"; message.body="\n\n2026/11/11 20:00、田中 愛子 <tanaka@example.invalid>のメール:\n\n田中です。\n"
        var context=ReplyContext(id:"reply",envelope:message,originalSubject:"研究会の日程",originalSender:"田中 愛子 <Tanaka@example.invalid>")
        BridgeCoordinator.ownerOpensPanel(context:&context)
        BridgeCoordinator.share(message,with:&context)
        let prepared=try XCTUnwrap(reports.preparedReply(forReplyTo:context))
        XCTAssertTrue(BridgeCoordinator.usePreparedReply(prepared.text,writtenAt:prepared.writtenAt,context:&context))
        XCTAssertEqual(context.proposal?.body,reply,"the reply alone; the thread Dot repeated is cut off")
        XCTAssertEqual(ReplyIndicator(context),.draftReady(preview:reply,revision:1))
        XCTAssertFalse(BridgeCoordinator.dotIsOwedWord(context),"Dot is not asked again for what it has already written")
        XCTAssertNotNil(context.ownerRequest?.preparedAt)
        XCTAssertEqual(context.snapshot?.body,message.body,"and the message itself is untouched")
        XCTAssertFalse(BridgeCoordinator.usePreparedReply("Another",writtenAt:Date(),context:&context),"a reply that has a draft keeps it")
        // A reply to a different message finds nothing.
        var other=ReplyContext(id:"other",envelope:message,originalSubject:"別の件",originalSender:"tanaka@example.invalid")
        BridgeCoordinator.ownerOpensPanel(context:&other); BridgeCoordinator.share(message,with:&other)
        XCTAssertNil(reports.preparedReply(forReplyTo:other))
        // A message shared without the panel's request never takes a prepared draft.
        var old=ReplyContext(id:"old",envelope:message,originalSubject:"研究会の日程",originalSender:"tanaka@example.invalid")
        BridgeCoordinator.share(message,with:&old)
        XCTAssertFalse(BridgeCoordinator.usePreparedReply(reply,writtenAt:Date(),context:&old))
    }
    func testADraftCheckNamesOneEssentialMessageAndDotsAnswerReachesTheList() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("maildot-check-"+UUID().uuidString)
        try MailSettingsStore(bridgeDirectory:root).transaction { $0=settings(automatic:true) }
        let available=try MailWorkflowAccount.available(settings:MailSettingsStore(bridgeDirectory:root).read(),native:NativeMailState())
        let verdict=MailTriage.assess(MailTriage.Input(messageID:"<t@example.invalid>",senderAddress:"tanaka@example.invalid",senderName:"田中 愛子",to:["owner@example.invalid"],cc:[],subject:"研究会の日程",receivedAt:Date(),headers:[:]),owner:["owner@example.invalid"])
        let entry=MailTriageEntry(messageID:"t@example.invalid",sender:"tanaka@example.invalid",senderName:"田中 愛子",subject:"研究会の日程",receivedAt:Date(),verdict:verdict,automatic:true)
        try MailTriageStore(bridgeDirectory:root).transaction { $0.record(entry) }
        XCTAssertThrowsError(try MailWorkflowRequest(action:.draftCheck,accountIDs:available.map(\.id)),"a draft check names its message")
        let request=try MailWorkflowRequest(action:.draftCheck,accountIDs:available.map(\.id),triageID:entry.id)
        try MailWorkflowStore(bridgeDirectory:root).transaction { try $0.enqueue(request,allowedAccountIDs:Set(available.map(\.id))) }
        try MailTriageStore(bridgeDirectory:root).transaction { $0.markAsked(entry.id,requestID:request.id) }
        let read=try MailWorkflowTools.call("get_mail_workflow",arguments:["request_id":.string(request.id)],bridgeDirectory:root)
        XCTAssertEqual(read["message"]["message_id"].string,"t@example.invalid")
        XCTAssertEqual(read["message"]["why_offered"].string,"田中 愛子 wrote to you directly.")
        XCTAssertTrue(read["instructions"].string?.contains("For action draftCheck") == true)
        let report:JSONValue=["requestID":.string(request.id),"expectedRevision":0,"stage":"ready","summary":"Tanaka asks whether Thursday works.\nDraft reply:\n木曜日の14時で問題ありません。","items":[]]
        _ = try MailWorkflowTools.call("report_mail_workflow",arguments:["report":report],bridgeDirectory:root)
        let after=try MailTriageStore(bridgeDirectory:root).read()
        XCTAssertEqual(after.entries.first?.outcome,.drafted)
        XCTAssertEqual(after.entries.first?.draft,"木曜日の14時で問題ありません。")
    }
    func testADraftDotWritesAfterThePanelClosedIsKeptAndShownOnItsMessage() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("maildot-closed-"+UUID().uuidString)
        let store=BridgeStore(directory:root)
        var seeded=shared()
        seeded.contexts["reply"]?.originalMessageID="<orig@example.invalid>"
        seeded.contexts["reply"]?.originalSubject="Meeting"
        try store.transaction { $0=seeded }
        // The panel is closed: nothing of it is running. Dot answers the request it was sent.
        let line:JSONValue=["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"propose_reply","arguments":["context_id":"reply","snapshot_revision":.number(Double(seeded.contexts["reply"]!.snapshotRevision)),"proposal_revision":0,"body":"Thursday at 14:00 suits me."]]]
        _ = await MCPRouter(store:store,statelessTunnel:true).response(try line.text())
        XCTAssertEqual(try store.read().contexts["reply"]?.proposal?.body,"Thursday at 14:00 suits me.","the draft waits for the panel to open again")
        let triage=try MailTriageStore(bridgeDirectory:root).read()
        let entry=try XCTUnwrap(triage.entry(forMessageID:"orig@example.invalid"))
        XCTAssertEqual(entry.outcome,.drafted,"and the message itself shows the draft is ready")
        XCTAssertEqual(entry.listMark,.draftReady)
        XCTAssertEqual(entry.draft,"Thursday at 14:00 suits me.")
        XCTAssertNotNil(entry.announcedAt,"the reply's own notification already says it; it is not said twice")
    }
    func testDotsLaterProgressNoteDoesNotWithdrawItsUnansweredQuestion() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("maildot-question-"+UUID().uuidString)
        let store=BridgeStore(directory:root)
        let seeded=shared()
        try store.transaction { $0=seeded }
        let revision=Double(seeded.contexts["reply"]!.snapshotRevision)
        func call(_ arguments:[String:JSONValue]) async throws {
            var all=arguments; all["context_id"]="reply"; all["snapshot_revision"] = .number(revision)
            let line:JSONValue=["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"report_progress","arguments":.object(all)]]
            _ = await MCPRouter(store:store,statelessTunnel:true).response(try line.text())
        }
        try await call(["status":"I need one thing.","question":"Thursday or Friday? 1) Thursday 2) Friday"])
        try await call(["status":"Waiting for your answer."])
        XCTAssertEqual(try store.read().contexts["reply"]?.dotQuestion,"Thursday or Friday? 1) Thursday 2) Friday","as seen live: Dot's next note had erased the question before the owner could answer")
        try await call(["status":"Never mind.","question":""])
        XCTAssertNil(try store.read().contexts["reply"]?.dotQuestion,"an empty question withdraws it")
        var context=try XCTUnwrap(store.read().contexts["reply"])
        context.dotQuestion="Still open?"
        try BridgeCoordinator.propose("Thursday suits me.",expectedRevision:context.snapshotRevision,eventID:nil,delivery:nil,context:&context)
        XCTAssertNil(context.dotQuestion,"Dot's draft settles its question")
    }
    func testSaveDraftAsksForASaveAndInsertDoesNot() throws {
        var state=shared()
        try BridgeCoordinator.ownerChooses(.save,saveToDrafts:true,contextID:"reply",state:&state)
        XCTAssertEqual(state.contexts["reply"]?.ownerRequest?.saveToDrafts,true)
        XCTAssertEqual(state.contexts["reply"]?.ownerRequest?.delivery,.save)
        try BridgeCoordinator.ownerChooses(.save,contextID:"reply",state:&state)
        XCTAssertNil(state.contexts["reply"]?.ownerRequest?.saveToDrafts,"Insert only puts the reply in the message")
        try BridgeCoordinator.ownerChooses(.send,saveToDrafts:true,contextID:"reply",state:&state)
        XCTAssertNil(state.contexts["reply"]?.ownerRequest?.saveToDrafts,"Send has no separate save")
    }
    func testADraftCheckTellsDotHowToReachTheMessage() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("maildot-reach-"+UUID().uuidString)
        var linked=settings(automatic:nil)
        linked.nativeAccounts=[NativeMailAccount(id:"icloud",name:"iCloud",addresses:["owner@icloud.example.invalid"],server:"imap.mail.me.com")]
        try MailSettingsStore(bridgeDirectory:root).transaction { $0=linked }
        let inbox=NativeMailbox(accountID:"icloud",path:["INBOX"])
        try NativeMailStore(bridgeDirectory:root).transaction { try NativeMailCoordinator.authorize(accountID:"icloud",mailboxes:[inbox],state:&$0) }
        let available=try MailWorkflowAccount.available(settings:linked,native:NativeMailState())
        var entry=MailTriageEntry(messageID:"r@example.invalid",sender:"tanaka@example.invalid",senderName:nil,subject:"研究会",receivedAt:Date(),
                                  verdict:MailTriage.Verdict(essential:true,reason:"r"),automatic:true)
        entry.recipients=["owner@icloud.example.invalid"]
        try MailTriageStore(bridgeDirectory:root).transaction { $0.record(entry) }
        let request=try MailWorkflowRequest(action:.draftCheck,accountIDs:available.map(\.id),triageID:entry.id)
        try MailWorkflowStore(bridgeDirectory:root).transaction { try $0.enqueue(request,allowedAccountIDs:Set(available.map(\.id))) }
        let read=try MailWorkflowTools.call("get_mail_workflow",arguments:["request_id":.string(request.id)],bridgeDirectory:root)
        let route=try XCTUnwrap(read["message"]["reach"].array?.first)
        XCTAssertEqual(route["route"].string,"mail_on_this_mac")
        XCTAssertEqual(route["mailboxes"].array?.first?["mailbox_id"].string,inbox.id)
        XCTAssertTrue(read["instructions"].string?.contains("native_mail_list_messages") == true)
    }
    func testAStateSavedBeforeThisBuildStillLoads() throws {
        var context=ReplyContext(id:"old",envelope:draft)
        BridgeCoordinator.share(draft,with:&context)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(context)) as? [String:Any])
        object.removeValue(forKey:"ownerRequest")
        let decoded=try JSONDecoder().decode(ReplyContext.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertNil(decoded.ownerRequest)
    }
}
