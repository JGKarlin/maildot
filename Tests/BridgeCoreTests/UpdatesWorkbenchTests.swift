import XCTest
@testable import BridgeCore

/// The Updates workbench (docs/updates-workbench-spec.md): what Dot reports in fields, where the app says a
/// matter stands, which control Return means, and what the owner's actions record.
final class UpdatesWorkbenchTests:XCTestCase {
    private func update(_ id:String="item",revision:Int=0,action:ScheduledMailAction = .decision,_ shape:(inout ScheduledMailUpdate)->Void={_ in}) throws -> ScheduledMailUpdate {
        let fields:[String:Any]=["id":id,"scheduleID":"schedule","runID":"run","revision":revision,"accountIDs":["gmail:profile"],"sourceIDs":["message-1"],
            "title":"Invitation to review a manuscript","summary":"The editor invites a review. The report is due December 9.",
            "action":action.rawValue,"actionText":action == .none ? "" : "Decide whether to accept.","checkedAt":Date().addingTimeInterval(-60).ISO8601Format(),"coverage":"One message read in full."]
        let decoder=JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var value=try decoder.decode(ScheduledMailUpdate.self,from:JSONSerialization.data(withJSONObject:fields))
        shape(&value)
        return value
    }
    private let options=[
        MailUpdateOption(id:"accept",label:"Accept for December 9",detail:"Agree to the stated deadline.",effect:.draftReply,replyPreview:"Thank you. I accept."),
        MailUpdateOption(id:"decline",label:"Decline",detail:"A brief, courteous refusal.",effect:.draftReply),
        MailUpdateOption(id:"later",label:"Decide later",detail:"Leave it open.",effect:.resolve)
    ]
    private func linked() throws -> (MailSettings,[MailWorkflowAccount]) {
        var settings=MailSettings()
        var profile=MailConnection(id:"profile",email:"owner@example.invalid",connectionID:"link"); profile.observedAt=Date()
        settings.connections=[profile]
        var schedule=MailSchedule(id:"schedule",title:"General email review",accountEmails:[profile.email],cadence:"Every hour",conditions:"Report mail that needs a decision")
        schedule.observedAt=Date(); schedule.sources=[MailScheduleSource(kind:"gmail",id:profile.id,addresses:[profile.email],connectionID:profile.connectionID)]
        settings.schedules=[schedule]; settings.linkedScheduleIDs=[schedule.id]
        return (settings,try MailWorkflowAccount.available(settings:settings,native:NativeMailState()))
    }
    private func state(with updates:[ScheduledMailUpdate]) throws -> ScheduledMailUpdateState {
        let (settings,accounts)=try linked()
        var state=ScheduledMailUpdateState()
        for update in updates { try state.accept(update,settings:settings,accounts:accounts) }
        return state
    }

    // MARK: What Dot reports

    func testAnUpdateWithoutTheNewFieldsStillValidatesAndDisplays() throws {
        let old=try update()
        XCTAssertNoThrow(try old.validate())
        XCTAssertFalse(old.isStructured)
        let shown=MailUpdatePresentation(old)
        XCTAssertEqual(shown.subject,"Invitation to review a manuscript")
        XCTAssertEqual(shown.gist,"The editor invites a review.")
        XCTAssertEqual(shown.points,["The editor invites a review.","The report is due December 9."],"an older report's one block is shown statement by statement")
        XCTAssertEqual(MailUpdatePresentation.statements(in:"査読の依頼です。締切は12月9日です。 Costs are 1.5 million yen (about US$9,700). Reply by Dec. 9."),["査読の依頼です。","締切は12月9日です。","Costs are 1.5 million yen (about US$9,700).","Reply by Dec. 9."])
        XCTAssertEqual(MailUpdatePresentation.statements(in:"One line only"),["One line only"])
        XCTAssertEqual(MailUpdatePresentation.statements(in:(1...9).map{"Statement \($0)."}.joined(separator:" ")).count,6,"never more than six points; the rest stay with the sixth")
        XCTAssertEqual(shown.followUp,"Decide whether to accept.")
        XCTAssertNil(shown.decision)
        XCTAssertEqual(shown.status,.awaitingInstruction)
    }
    func testTheOldActionMapsToAStatus() throws {
        let expected:[ScheduledMailAction:MailUpdateStatus]=[.decision:.awaitingInstruction,.reply:.awaitingInstruction,.reviewDraft:.draftedQueued,.none:.information,.followUp:.information,.resolved:.information]
        for (action,status) in expected { XCTAssertEqual(MailUpdatePresentation(try update(action:action)).status,status,"\(action)") }
    }
    func testStructuredFieldsAreShownAsReported() throws {
        let full=try update {
            $0.message=MailUpdateMessage(sender:"Journal editorial office",subject:"Invitation to review",receivedAt:Date().addingTimeInterval(-3600))
            $0.gist="A review is requested by December 9."
            $0.summaryPoints=["The editor invites a review.","The report is due December 9."]
            $0.unverified=["whether the deadline can move"]
            $0.status = .awaitingInstruction
            $0.decision=MailUpdateDecision(question:"How should Dot reply?",options:self.options,recommended:"accept")
            $0.work=[MailUpdateWork(state:.done,text:"Checked the week of December 7",source:.calendar),MailUpdateWork(state:.needsOwner,text:"Could not open the manuscript",source:.none)]
            $0.tags=[MailUpdateTag(state:.done,label:"Calendar checked")]
        }
        XCTAssertNoThrow(try full.validate())
        let shown=MailUpdatePresentation(full)
        XCTAssertTrue(shown.structured)
        XCTAssertEqual(shown.subject,"Invitation to review")
        XCTAssertEqual(shown.sender,"Journal editorial office")
        XCTAssertEqual(shown.gist,"A review is requested by December 9.")
        XCTAssertEqual(shown.points.count,2)
        XCTAssertNil(shown.followUp,"a decision replaces the old line on what is needed")
        XCTAssertTrue(shown.needsOwner)
        XCTAssertEqual(shown.work.last?.sourceTitle,"No access")
    }
    func testStructuredFieldsOutsideTheirLimitsAreRefused() throws {
        XCTAssertThrowsError(try update { $0.summaryPoints=[] }.validate())
        XCTAssertThrowsError(try update { $0.summaryPoints=Array(repeating:"A point.",count:7) }.validate())
        XCTAssertThrowsError(try update { $0.gist=String(repeating:"a",count:241) }.validate())
        XCTAssertThrowsError(try update { $0.decision=MailUpdateDecision(question:"Which?",options:[self.options[0]]) }.validate(),"one option is no choice")
        XCTAssertThrowsError(try update { $0.decision=MailUpdateDecision(question:"Which?",options:self.options,recommended:"missing") }.validate())
        XCTAssertThrowsError(try update { $0.decision=MailUpdateDecision(question:"Which?",options:[self.options[0],self.options[0]]) }.validate(),"option ids must differ")
        XCTAssertThrowsError(try update { $0.tags=Array(repeating:MailUpdateTag(state:.done,label:"Tag"),count:4) }.validate())
        XCTAssertThrowsError(try update { $0.draft=MailUpdateDraft(delivery:.save,to:[],preview:"Text") }.validate())
        XCTAssertThrowsError(try update { $0.draft=MailUpdateDraft(delivery:.save,to:["a@example.invalid"],preview:String(repeating:"a",count:2001)) }.validate())
    }
    func testADraftWithoutItsDeliveryIsRefusedWhenReported() throws {
        let payload:[String:Any]=["to":["a@example.invalid"],"preview":"Thank you."]
        XCTAssertThrowsError(try JSONDecoder().decode(MailUpdateDraft.self,from:JSONSerialization.data(withJSONObject:payload)))
    }

    // MARK: Status, derived by the app

    func testOnlyMailDotsOwnRecordPutsAnUpdateUnderSent() throws {
        let draft=MailUpdateDraft(reference:"context-1",delivery:.send,to:["office@example.invalid"],preview:"Please find the form attached.")
        let claimed=try update { $0.status = .draftedSent; $0.draft=draft }
        XCTAssertEqual(MailUpdatePresentation(claimed).status,.draftedQueued,"Dot's claim that it was sent is not enough")
        XCTAssertEqual(MailUpdatePresentation(claimed,sentReferences:["context-1"]).status,.draftedSent)
        XCTAssertEqual(MailUpdatePresentation(try update { $0.status = .draftedSent }).status,.information)
    }
    func testQueuedNeedsADraft() throws {
        XCTAssertEqual(MailUpdatePresentation(try update { $0.status = .draftedQueued }).status,.awaitingInstruction)
        let draft=MailUpdateDraft(delivery:.save,to:["a@example.invalid"],preview:"Thank you.")
        XCTAssertEqual(MailUpdatePresentation(try update { $0.draft=draft }).status,.draftedQueued)
        XCTAssertEqual(MailUpdatePresentation(try update { $0.draft=draft; $0.status = .awaitingInstruction }).status,.awaitingInstruction,"Dot may still have a question about a draft")
    }

    // MARK: Which control Return means

    private func controls(_ shape:(inout ScheduledMailUpdate)->Void,chosen:String?=nil,handled:MailUpdateOwnerState.Handled?=nil,bound:Bool=false) throws -> [MailUpdatePrimary] {
        let owner=chosen == nil && handled == nil ? nil : MailUpdateOwnerState(revision:0,chosen:chosen,handled:handled,note:nil,at:Date(),requestID:nil)
        return MailUpdatePrimary.controls(for:MailUpdatePresentation(try update { shape(&$0) }),owner:owner,draftIsBound:bound)
    }
    func testBeforeAChoiceTheBarAsksForOne() throws {
        XCTAssertEqual(try controls { $0.decision=MailUpdateDecision(question:"How?",options:self.options) },[.choose(count:3)])
    }
    func testAReplyOptionOffersDraftAndSaveAndDraftAndSend() throws {
        XCTAssertEqual(try controls({ $0.decision=MailUpdateDecision(question:"How?",options:self.options) },chosen:"accept"),[.draftAndSave,.draftAndSend])
    }
    func testOtherOptionsAreApplied() throws {
        XCTAssertEqual(try controls({ $0.decision=MailUpdateDecision(question:"How?",options:self.options) },chosen:"later"),[.apply(.resolve)])
    }
    func testAQueuedDraftIsSentOnlyWhereMailDotIsBoundToIt() throws {
        let draft=MailUpdateDraft(reference:"context-1",delivery:.save,to:["a@example.invalid"],preview:"Thank you.")
        XCTAssertEqual(try controls({ $0.draft=draft },bound:true),[.sendDraft])
        XCTAssertEqual(try controls({ $0.draft=draft },bound:false),[.openDraftInMail],"without a verified binding nothing is sent from here")
        let approve=[MailUpdateOption(id:"send",label:"Send it as drafted",detail:"As written.",effect:.sendAsDrafted),MailUpdateOption(id:"hold",label:"Hold it",detail:"Decide later.",effect:.close)]
        XCTAssertEqual(try controls({ $0.draft=draft; $0.decision=MailUpdateDecision(question:"What now?",options:approve) },chosen:"send",bound:true),[.sendDraft])
        XCTAssertEqual(try controls({ $0.draft=draft; $0.decision=MailUpdateDecision(question:"What now?",options:approve) },chosen:"hold",bound:true),[.apply(.close)])
    }
    func testAnAnswerToDotsQuestionGoesToDotBeforeAnythingIsSent() throws {
        let draft=MailUpdateDraft(reference:"context-1",delivery:.send,to:["a@example.invalid"],preview:"The total is 48,260 yen.")
        let question=MailUpdateDecision(kind:.question,question:"Which date applies?",options:[
            MailUpdateOption(id:"sixth",label:"November 6",detail:"The day you arrived.",effect:.answer),MailUpdateOption(id:"seventh",label:"November 7",detail:"The day of the symposium.",effect:.answer)])
        XCTAssertEqual(try controls({ $0.draft=draft; $0.decision=question },chosen:"sixth",bound:true),[.apply(.answer)],"the answer may change the draft")
    }
    func testOnceInstructedNothingMoreIsOfferedUntilDotReports() throws {
        XCTAssertEqual(try controls({ $0.decision=MailUpdateDecision(question:"How?",options:self.options) },chosen:"accept",handled:.instructed),[.sentToDot])
    }
    func testASentUpdateOffersNothingToSend() throws {
        let draft=MailUpdateDraft(reference:"context-1",delivery:.send,to:["a@example.invalid"],preview:"Done.")
        let shown=MailUpdatePresentation(try update { $0.draft=draft },sentReferences:["context-1"])
        XCTAssertEqual(MailUpdatePrimary.controls(for:shown,owner:nil,draftIsBound:true),[])
    }

    // MARK: What the owner's actions record

    func testChoosingAnOptionRecordsItAndChoosingItAgainClearsIt() throws {
        var state=try state(with:[update { $0.decision=MailUpdateDecision(question:"How?",options:self.options) }])
        let id=state.records[0].id
        try state.choose(id,revision:0,option:"accept")
        XCTAssertEqual(state.records[0].ownerState?.chosen,"accept")
        XCTAssertTrue(state.records[0].unread,"choosing has no side effect")
        try state.choose(id,revision:0,option:"accept")
        XCTAssertNil(state.records[0].ownerState)
        XCTAssertThrowsError(try state.choose(id,revision:0,option:"missing"))
        XCTAssertThrowsError(try state.choose(id,revision:1,option:"accept"),"a choice names the revision it was made on")
        XCTAssertNoThrow(try state.validate())
    }
    func testIgnoringClosesTheUpdateMarksItReadAndCanBeUndone() throws {
        var state=try state(with:[update()])
        let id=state.records[0].id
        try state.handle(id,revision:0,as:.ignored,note:nil,requestID:nil)
        XCTAssertTrue(state.records[0].dismissedByOwner)
        XCTAssertFalse(state.records[0].unread)
        XCTAssertNil(try state.undo(id))
        XCTAssertFalse(state.records[0].dismissedByOwner)
        XCTAssertThrowsError(try state.undo(id),"nothing left to undo")
    }
    func testAnInstructionStaysWithTheUpdateAndItsRequestCanBeCancelled() throws {
        var state=try state(with:[update { $0.decision=MailUpdateDecision(question:"How?",options:self.options) }])
        let id=state.records[0].id
        try state.choose(id,revision:0,option:"accept")
        try state.handle(id,revision:0,as:.instructed,note:"Accept for December 9 · draft and save",requestID:"request-1")
        XCTAssertFalse(state.records[0].dismissedByOwner,"it stays in place, marked as sent to Dot")
        XCTAssertEqual(state.records[0].ownerState?.note,"Accept for December 9 · draft and save")
        XCTAssertEqual(try state.undo(id),"request-1")
        XCTAssertEqual(state.records[0].ownerState?.chosen,"accept","the choice is kept, ready to apply again")
        XCTAssertNil(state.records[0].ownerState?.handled)
    }
    func testANewRevisionFromDotStartsAfreshAndIsUnread() throws {
        let (settings,accounts)=try linked()
        var state=try state(with:[update { $0.decision=MailUpdateDecision(question:"How?",options:self.options) }])
        let id=state.records[0].id
        try state.handle(id,revision:0,as:.instructed,note:"Accept",requestID:"request-1")
        try state.accept(update(revision:1) { $0.draft=MailUpdateDraft(delivery:.save,to:["editor@example.invalid"],preview:"Thank you. I accept.") },settings:settings,accounts:accounts)
        XCTAssertNil(state.records[0].ownerState,"the owner's instruction belonged to the earlier revision")
        XCTAssertTrue(state.records[0].unread)
        XCTAssertEqual(MailUpdatePresentation(state.records[0].update).status,.draftedQueued)
    }
    func testMarkingUnreadAndReadAgain() throws {
        var state=try state(with:[update()])
        let id=state.records[0].id
        try state.markRead(id,revision:0)
        XCTAssertFalse(state.records[0].unread)
        try state.markUnread(id)
        XCTAssertTrue(state.records[0].unread)
    }
    func testStateSavedBeforeTheWorkbenchStillLoads() throws {
        var state=try state(with:[update()])
        try state.markRead(state.records[0].id,revision:0)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(state)) as? [String:Any])
        var records=try XCTUnwrap(object["records"] as? [[String:Any]])
        records[0].removeValue(forKey:"owner")
        object["records"]=records
        let loaded=try JSONDecoder().decode(ScheduledMailUpdateState.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertNoThrow(try loaded.validate())
        XCTAssertNil(loaded.records[0].ownerState)
    }

    // MARK: Carrying the owner's choice to Dot

    func testAnOptionInstructionNamesTheUpdateRevisionOptionAndDelivery() throws {
        let instruction=MailUpdateInstruction(kind:.option,updateID:"item",scheduleID:"schedule",revision:0,optionID:"accept",optionLabel:"Accept for December 9",effect:.draftReply,delivery:.save)
        XCTAssertNoThrow(try instruction.validate())
        XCTAssertEqual(instruction.summary,"Accept for December 9 · draft and save")
        let request=try MailWorkflowRequest(action:.instruction,accountIDs:["gmail:profile"],instruction:instruction)
        XCTAssertEqual(request.instruction,instruction)
        XCTAssertFalse(request.opensCall)
    }
    func testAReplyOptionWithoutDraftAndSaveOrDraftAndSendIsRefused() {
        XCTAssertThrowsError(try MailUpdateInstruction(kind:.option,updateID:"item",scheduleID:"schedule",revision:0,optionID:"accept",optionLabel:"Accept",effect:.draftReply).validate(),"every draft instruction carries a mode")
        XCTAssertThrowsError(try MailUpdateInstruction(kind:.option,updateID:"item",scheduleID:"schedule",revision:0,optionID:"later",optionLabel:"Later",effect:.resolve,delivery:.send).validate())
    }
    func testOnlyAnInstructionRequestCarriesAnInstruction() {
        let instruction=MailUpdateInstruction(kind:.discuss,updateID:"item",scheduleID:"schedule",revision:0,text:"Make the reply shorter.")
        XCTAssertThrowsError(try MailWorkflowRequest(action:.status,accountIDs:["gmail:profile"],instruction:instruction))
        XCTAssertThrowsError(try MailWorkflowRequest(action:.instruction,accountIDs:["gmail:profile"]))
        XCTAssertThrowsError(try MailUpdateInstruction(kind:.discuss,updateID:"item",scheduleID:"schedule",revision:0,text:"  ").validate())
    }

    // MARK: Recognising the message inside Mail

    func testTheMessageIDIsReadFromAMessagesHeaders() {
        let raw=Data("Received: from a\r\nSubject: Invitation to review\r\nMessage-ID: <CAF123@mail.example.invalid>\r\nFrom: Editor <editor@example.invalid>\r\n\r\nBody mentions Message-ID: <other@example.invalid>\r\n".utf8)
        XCTAssertEqual(MailMessageIdentity.messageID(inRawMessage:raw),"CAF123@mail.example.invalid")
        let folded=Data("Message-Id:\r\n <folded.line@example.invalid>\r\nSubject: x\r\n\r\nbody".utf8)
        XCTAssertEqual(MailMessageIdentity.messageID(inRawMessage:folded),"folded.line@example.invalid","a header may continue on the next line")
        XCTAssertNil(MailMessageIdentity.messageID(inRawMessage:Data("Subject: none\r\n\r\nMessage-ID: <body@example.invalid>".utf8)),"a line in the body is not a header")
        XCTAssertNil(MailMessageIdentity.messageID(inRawMessage:Data()))
    }
    func testAReportIsFoundByItsMessageIDFromEitherPlaceDotPutsIt() throws {
        let named=try update("a") { $0.message=MailUpdateMessage(sender:"Editor",subject:"Invitation",messageID:"<CAF123@mail.example.invalid>") }
        var other=try update("b")
        other.sourceIDs=["<plain.source@example.invalid>","gmail-thread-18c"]
        let state=try state(with:[named,other])
        XCTAssertEqual(state.record(forMessageID:"CAF123@mail.example.invalid")?.update.id,"a")
        XCTAssertEqual(state.record(forMessageID:" <plain.source@example.invalid> ")?.update.id,"b","the angle brackets and space do not matter")
        XCTAssertNil(state.record(forMessageID:"unknown@example.invalid"))
        XCTAssertNil(state.record(forMessageID:"gmail-thread-18c"),"a connector's own identifier is not a Message-ID")
    }
    func testAReportTheOwnerIgnoredNoLongerShowsOnItsMessage() throws {
        var state=try state(with:[update("a") { $0.message=MailUpdateMessage(sender:"Editor",messageID:"<CAF123@mail.example.invalid>") }])
        try state.handle(state.records[0].id,revision:0,as:.ignored,note:nil,requestID:nil)
        XCTAssertNil(state.record(forMessageID:"CAF123@mail.example.invalid"))
    }
    func testAMalformedMessageIDIsRefused() throws {
        XCTAssertThrowsError(try update { $0.message=MailUpdateMessage(sender:"Editor",messageID:"not an identifier") }.validate())
        XCTAssertNoThrow(try update { $0.message=MailUpdateMessage(sender:"Editor",messageID:"<ok@example.invalid>") }.validate())
    }

    // MARK: Recognising the message when Dot cannot give its Message-ID

    func testAMessagesHeadersAreReadWithEncodedWordsDecoded() {
        let raw=Data("Received: by mx.example.invalid; Mon, 9 Nov 2026 10:15:02 +0900\r\nFrom: =?UTF-8?B?5bGx55Sw?= <Yamada@Example.invalid>\r\nSubject: =?UTF-8?B?44GK55+l44KJ44Gb?=\r\n =?UTF-8?Q?_part_two?=\r\nDate: Mon, 9 Nov 2026 10:15:00 +0900 (JST)\r\nMessage-ID: <a@example.invalid>\r\n\r\nSubject: in the body".utf8)
        let headers=MailMessageHeaders(rawMessage:raw)
        XCTAssertEqual(headers.messageID,"a@example.invalid")
        XCTAssertEqual(headers.senderAddress,"yamada@example.invalid","addresses compare without regard to case")
        XCTAssertEqual(headers.senderName,"山田")
        XCTAssertEqual(headers.subject,"お知らせ part two","the space between two encoded words is not part of the text")
        XCTAssertEqual(headers.date,ISO8601DateFormatter().date(from:"2026-11-09T01:15:00Z"))
        let japanese=MailMessageHeaders(rawMessage:Data("From: editor@example.invalid\r\nSubject: =?ISO-2022-JP?B?GyRCOjpGSSROJCo0aiQkGyhC?=\r\n\r\n".utf8))
        XCTAssertEqual(japanese.subject,"査読のお願い")
        XCTAssertEqual(japanese.senderAddress,"editor@example.invalid")
        let split=MailMessageHeaders(rawMessage:Data("Subject: =?UTF-8?B?44GK558=?= =?UTF-8?B?peOCieOBmw==?=\r\n\r\n".utf8))
        XCTAssertEqual(split.subject,"お知らせ","a character divided between two encoded words is put back together")
        XCTAssertEqual(MailMessageHeaders(rawMessage:Data()),MailMessageHeaders())
    }
    func testAReportWithoutAMessageIDIsFoundBySenderSubjectAndTime() throws {
        let received=ISO8601DateFormatter().date(from:"2026-11-09T01:15:00Z")!
        let state=try state(with:[update("a") { $0.message=MailUpdateMessage(sender:"Yamada Taro <Yamada@example.invalid>",subject:"Invitation to review",receivedAt:received) }])
        func headers(_ sender:String="yamada@example.invalid",_ subject:String="Invitation to review",_ date:Date?=received,id:String?="x@example.invalid") -> MailMessageHeaders {
            MailMessageHeaders(messageID:id,senderAddress:sender,senderName:nil,subject:subject,date:date)
        }
        XCTAssertEqual(state.record(for:headers())?.update.id,"a")
        XCTAssertEqual(state.record(for:headers("yamada@example.invalid","RE:  invitation to   Review"))?.update.id,"a","a reply prefix, case and spacing do not matter")
        XCTAssertEqual(state.record(for:headers("yamada@example.invalid","Invitation to review",received.addingTimeInterval(3600)))?.update.id,"a","clocks differ")
        XCTAssertEqual(state.record(for:headers("yamada@example.invalid","Invitation to review",nil))?.update.id,"a")
        XCTAssertNil(state.record(for:headers("someone.else@example.invalid")),"another sender's message with the same subject is another message")
        XCTAssertNil(state.record(for:headers("yamada@example.invalid","Invitation to dinner")))
        XCTAssertNil(state.record(for:headers("yamada@example.invalid","Invitation to review",received.addingTimeInterval(4*86_400))),"the same subject days later is another message")
    }
    func testAReportThatNamesAMessageIDIsNeverMatchedByHeadersInstead() throws {
        let state=try state(with:[update("a") { $0.message=MailUpdateMessage(sender:"yamada@example.invalid",subject:"Invitation to review",messageID:"<first@example.invalid>") }])
        let other=MailMessageHeaders(messageID:"second@example.invalid",senderAddress:"yamada@example.invalid",senderName:nil,subject:"Re: Invitation to review",date:nil)
        XCTAssertNil(state.record(for:other),"Dot named one message exactly; another in the thread is not it")
        XCTAssertEqual(state.record(for:MailMessageHeaders(messageID:"first@example.invalid",senderAddress:nil,senderName:nil,subject:nil,date:nil))?.update.id,"a")
    }
    func testASenderGivenOnlyByNameMatchesTheNameMailShows() throws {
        let state=try state(with:[update("a") { $0.message=MailUpdateMessage(sender:"山田 太郎",subject:"査読のお願い") }])
        XCTAssertEqual(state.record(for:MailMessageHeaders(messageID:nil,senderAddress:"yamada@example.invalid",senderName:"山田 太郎",subject:"査読のお願い",date:nil))?.update.id,"a")
        XCTAssertNil(state.record(for:MailMessageHeaders(messageID:nil,senderAddress:"yamada@example.invalid",senderName:"別人",subject:"査読のお願い",date:nil)))
    }
    func testAnOlderToolListCanNameTheMessageInItsSources() throws {
        let state=try state(with:[update("a") { $0.sourceIDs=["gmail:message:18c0ffee18c0ffee","from Yamada@example.invalid subject Invitation to review"] }])
        XCTAssertEqual(state.record(for:MailMessageHeaders(messageID:"x@example.invalid",senderAddress:"yamada@example.invalid",senderName:nil,subject:"Invitation to review",date:nil))?.update.id,"a")
        XCTAssertNil(state.record(for:MailMessageHeaders(messageID:"x@example.invalid",senderAddress:"yamada@example.invalid",senderName:nil,subject:"Something else",date:nil)))
        XCTAssertNil(try self.state(with:[update("b")]).record(for:MailMessageHeaders(messageID:"x@example.invalid",senderAddress:"yamada@example.invalid",senderName:nil,subject:"Invitation to review a manuscript",date:nil)),
                     "a report that names no message is shown on none")
    }

    // MARK: The list of Dot's reports, by where each stands

    func testTheQueueGroupsReportsByWhereTheyStandAndOrdersThem() throws {
        let state=try state(with:[
            update("note",action:.none),
            update("decide"),
            update("drafted") { $0.draft=MailUpdateDraft(reference:"context-1",delivery:.save,to:["a@example.invalid"],preview:"Thank you.") },
            update("sent") { $0.draft=MailUpdateDraft(reference:"context-2",delivery:.send,to:["a@example.invalid"],preview:"Thank you.") },
            update("ignored")
        ])
        var ignored=state
        try ignored.handle(ignored.records.first{$0.update.id == "ignored"}!.id,revision:0,as:.ignored,note:nil,requestID:nil)
        let queue=MailUpdateQueue(ignored,sentReferences:["context-2"])
        XCTAssertEqual(queue.groups.map(\.status),[.awaitingInstruction,.draftedQueued,.draftedSent,.information])
        XCTAssertEqual(queue.groups.map{$0.records.map(\.update.id)},[["decide"],["drafted"],["sent"],["note"]],"a report the owner ignored is not listed")
        XCTAssertEqual(queue.count(.awaitingInstruction),1)
        let first=ignored.records.first{$0.update.id == "decide"}!.id
        XCTAssertEqual(queue.next(after:nil)?.id,first,"Next begins with what awaits the owner")
        XCTAssertEqual(queue.next(after:first)?.update.id,"drafted")
        XCTAssertEqual(queue.next(after:ignored.records.first{$0.update.id == "note"}!.id)?.id,first,"and comes round again")
        XCTAssertNil(MailUpdateQueue(ScheduledMailUpdateState()).next(after:nil))
    }

    // MARK: Through the tools Dot uses

    private func linkedStore() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        let (settings,_)=try linked()
        try MailSettingsStore(bridgeDirectory:root).transaction { $0=settings }
        return root
    }
    private func payload(_ update:ScheduledMailUpdate) throws -> JSONValue {
        let encoder=JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self,from:encoder.encode(update))
    }
    func testDotReportsStructuredFieldsThroughTheExistingTool() throws {
        let root=try linkedStore()
        let full=try update {
            $0.message=MailUpdateMessage(sender:"Journal editorial office",subject:"Invitation to review")
            $0.summaryPoints=["The editor invites a review."]
            $0.decision=MailUpdateDecision(question:"How should Dot reply?",options:self.options,recommended:"accept")
            $0.work=[MailUpdateWork(state:.done,text:"Checked the calendar",source:.calendar)]
        }
        let saved=try ScheduledMailUpdateTools.call("report_scheduled_mail_update",arguments:["update":try payload(full)],bridgeDirectory:root)
        XCTAssertEqual(saved["saved"],true)
        let record=try XCTUnwrap(ScheduledMailUpdateStore(bridgeDirectory:root).read().records.first)
        XCTAssertEqual(record.update.decision?.recommended,"accept")
        XCTAssertEqual(record.update.work?.first?.source,.calendar)
        let read=try ScheduledMailUpdateTools.call("get_scheduled_mail_updates",arguments:[:],bridgeDirectory:root)
        XCTAssertTrue(read["instructions"].string?.contains("summaryPoints") == true,"Dot is told to report in fields each time it reads")
        XCTAssertTrue(read["instructions"].string?.contains("never report a reply as sent") == true)
    }
    func testAMalformedStructuredFieldIsNamedToDot() throws {
        let root=try linkedStore()
        var object=try XCTUnwrap(try payload(update()).object)
        object["decision"]=["kind":"decision","question":"Which?","options":"none"]
        XCTAssertThrowsError(try ScheduledMailUpdateTools.call("report_scheduled_mail_update",arguments:["update":.object(object)],bridgeDirectory:root)) { error in
            XCTAssertTrue(error.localizedDescription.contains("\"decision\""),error.localizedDescription)
        }
    }
    func testDotReadsTheOwnersInstructionWithTheUpdateAsItStands() throws {
        let root=try linkedStore()
        let item=try update { $0.decision=MailUpdateDecision(question:"How should Dot reply?",options:self.options) }
        _ = try ScheduledMailUpdateTools.call("report_scheduled_mail_update",arguments:["update":try payload(item)],bridgeDirectory:root)
        let instruction=MailUpdateInstruction(kind:.option,updateID:"item",scheduleID:"schedule",revision:0,optionID:"accept",optionLabel:"Accept for December 9",effect:.draftReply,delivery:.save)
        let request=try MailWorkflowRequest(action:.instruction,accountIDs:["gmail:profile"],instruction:instruction)
        try MailWorkflowStore(bridgeDirectory:root).transaction { try $0.enqueue(request,allowedAccountIDs:["gmail:profile"]) }
        let read=try MailWorkflowTools.call("get_mail_workflow",arguments:["request_id":.string(request.id)],bridgeDirectory:root)
        XCTAssertEqual(read["request"]["action"],"instruction")
        XCTAssertEqual(read["request"]["instruction"]["optionID"],"accept")
        XCTAssertEqual(read["request"]["instruction"]["delivery"],"save")
        XCTAssertEqual(read["update"]["current"],true)
        XCTAssertEqual(read["update"]["title"],"Invitation to review a manuscript")
        XCTAssertTrue(MailWorkflowTools.instructions.contains("action instruction"))
        XCTAssertTrue(MailWorkflowTools.instructions.contains("you never send it yourself"))
    }
}
