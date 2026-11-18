import XCTest
@testable import BridgeCore

/// The owner's request of 11 November 2026: a call with Dot that can be opened from Mail when Dot needs
/// an answer, and a spoken report of current mail. Mail Dot cannot hold the call itself; it presses the
/// ChatGPT app's own voice command and tells Dot, through the existing request event, why the call opened.
final class CallDotTests:XCTestCase {
    private func linked() throws -> (URL,MailWorkflowStore) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        try MailSettingsStore(bridgeDirectory:root).transaction {
            var profile=MailConnection(id:"profile",email:"owner@example.invalid",connectionID:"link")
            profile.observedAt=Date(); $0.connections=[profile]
        }
        return (root,MailWorkflowStore(bridgeDirectory:root))
    }
    private func tool(_ name:String,_ arguments:[String:JSONValue],_ root:URL) throws -> JSONValue {
        try MailWorkflowTools.call(name,arguments:arguments,bridgeDirectory:root)
    }

    // MARK: ChatGPT's own call control

    func testStartCallIsPressedOnlyWhenNoCallIsOpen() {
        XCTAssertEqual(DotCallControl.state(labels:["Dictate","Start call"]),.canStart)
        XCTAssertEqual(DotCallControl.state(labels:["Dictate","Start new voice chat"]),.absent,"a voice chat in some other thread is not a call with Dot")
        XCTAssertEqual(DotCallControl.state(labels:[]),.absent)
    }
    func testAnOpenCallIsNeverPressedAgain() {
        for label in ["Hang up","Calling…","Call in progress","Mute microphone","Unmute microphone"] {
            XCTAssertEqual(DotCallControl.state(labels:[label]),.inCall,label)
        }
        XCTAssertEqual(DotCallControl.state(labels:["Start call","Call in progress"]),.inCall,"a second press could hang up")
    }

    // MARK: The request Dot receives

    func testACallRequestCarriesTheMessageItIsAbout() throws {
        let (root,workflow)=try linked()
        let context=UUID().uuidString
        let request=try MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"],contextID:context)
        try workflow.transaction { try $0.enqueue(request,allowedAccountIDs:["gmail:profile"]) }
        let read=try tool("get_mail_workflow",["request_id":.string(request.id)],root)
        XCTAssertEqual(read["request"]["action"],"call")
        XCTAssertEqual(read["request"]["contextID"].string,context)
    }
    func testASpokenReportIsAStatusRequestTheOwnerAskedToHear() throws {
        let (root,workflow)=try linked()
        let request=try MailWorkflowRequest(action:.status,accountIDs:["gmail:profile"],spoken:true)
        try workflow.transaction { try $0.enqueue(request,allowedAccountIDs:["gmail:profile"]) }
        XCTAssertEqual(try tool("get_mail_workflow",["request_id":.string(request.id)],root)["request"]["spoken"],true)
    }
    func testOnlyACallNamesAMessageOrAQuestion() {
        XCTAssertThrowsError(try MailWorkflowRequest(action:.status,accountIDs:["gmail:profile"],contextID:UUID().uuidString))
        XCTAssertThrowsError(try MailWorkflowRequest(action:.drafts,accountIDs:["gmail:profile"],questionID:UUID().uuidString))
        XCTAssertThrowsError(try MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"],contextID:"not an identifier"))
    }
    func testRequestsSavedByEarlierBuildsStillLoad() throws {
        let old=try MailWorkflowRequest(action:.status,accountIDs:["gmail:profile"])
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(old)) as? [String:Any])
        for key in ["spoken","contextID","questionID"] { object.removeValue(forKey:key) }
        let state:[String:Any]=["schemaVersion":1,"requests":[object],"dismissedItemVersions":[]]
        let decoded=try JSONDecoder().decode(MailWorkflowState.self,from:JSONSerialization.data(withJSONObject:state))
        XCTAssertEqual(decoded.requests.count,1)
        XCTAssertTrue(decoded.questions.isEmpty)
        XCTAssertNoThrow(try decoded.validate())
    }
    func testACallIsFinishedByAPlainSummary() throws {
        let (root,workflow)=try linked()
        let request=try MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"])
        try workflow.transaction { try $0.enqueue(request,allowedAccountIDs:["gmail:profile"]) }
        let joined=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.working,summary:"On the call.",items:[])
        _ = try tool("report_mail_workflow",["report":try .encode(joined)],root)
        XCTAssertEqual(try workflow.read().requests[0].stage,.working)
    }

    // MARK: Dot asks; the owner is offered the call

    func testDotsQuestionIsKeptForTheOwner() throws {
        let (root,workflow)=try linked()
        let context=UUID().uuidString
        let asked=try tool("ask_owner",["question":"Shall I draft and save, or draft and send, the reply about Friday?","context_id":.string(context)],root)
        let id=try XCTUnwrap(asked["question_id"].string)
        let saved=try XCTUnwrap(workflow.read().questions.first)
        XCTAssertEqual(saved.id,id)
        XCTAssertEqual(saved.text,"Shall I draft and save, or draft and send, the reply about Friday?")
        XCTAssertEqual(saved.contextID,context)
        XCTAssertEqual(try tool("get_mail_workflow",[:],root)["open_questions"].array?.count,1)
    }
    func testTheSameQuestionIsNotAskedTwice() throws {
        let (root,workflow)=try linked()
        let first=try tool("ask_owner",["question":"How should I revise the second paragraph?"],root)
        let second=try tool("ask_owner",["question":"  How should I revise\nthe second paragraph?  "],root)
        XCTAssertEqual(first["question_id"],second["question_id"])
        XCTAssertEqual(try workflow.read().questions.count,1)
    }
    func testQuestionsAreShortPlainAndFew() throws {
        let (root,workflow)=try linked()
        XCTAssertThrowsError(try tool("ask_owner",["question":"   "],root))
        XCTAssertThrowsError(try tool("ask_owner",["question":.string(String(repeating:"a",count:OwnerQuestion.textLimit+1))],root))
        XCTAssertThrowsError(try tool("ask_owner",["question":"Ring\u{07} the bell?"],root))
        XCTAssertThrowsError(try tool("ask_owner",["question":"Which one?","context_id":"not an identifier"],root))
        for number in 1...OwnerQuestion.limit { _ = try tool("ask_owner",["question":.string("Question \(number)?")],root) }
        XCTAssertThrowsError(try tool("ask_owner",["question":"One too many?"],root)) { error in
            XCTAssertTrue(error.localizedDescription.contains("unanswered"),error.localizedDescription)
        }
        XCTAssertEqual(try workflow.read().questions.count,OwnerQuestion.limit)
    }
    func testDotClosesAQuestionOnceItIsAnswered() throws {
        let (root,workflow)=try linked()
        let id=try XCTUnwrap(tool("ask_owner",["question":"Send it today or on Monday?"],root)["question_id"].string)
        XCTAssertEqual(try tool("close_owner_question",["question_id":.string(id)],root)["closed"],true)
        XCTAssertTrue(try workflow.read().questions.isEmpty)
        XCTAssertEqual(try tool("close_owner_question",["question_id":.string(id)],root)["closed"],false,"closing twice is harmless")
    }
    func testACallOpenedForAQuestionTellsDotWhichQuestionAndClosesItWhenDone() throws {
        let (root,workflow)=try linked()
        let id=try XCTUnwrap(tool("ask_owner",["question":"Send it today or on Monday?"],root)["question_id"].string)
        let request=try MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"],questionID:id)
        try workflow.transaction { try $0.enqueue(request,allowedAccountIDs:["gmail:profile"]) }
        let read=try tool("get_mail_workflow",["request_id":.string(request.id)],root)
        XCTAssertEqual(read["question"]["text"],"Send it today or on Monday?")
        let done=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"The owner chose Monday.",items:[])
        _ = try tool("report_mail_workflow",["report":try .encode(done)],root)
        XCTAssertTrue(try workflow.read().questions.isEmpty)
    }
    func testAQuestionNobodyAnsweredLapsesAfterADay() throws {
        var state=MailWorkflowState()
        let asked=Date(timeIntervalSince1970:1_000_000)
        _ = try state.ask("Still relevant?",contextID:nil,now:asked)
        state.expireQuestions(now:asked.addingTimeInterval(OwnerQuestion.lifetime-1))
        XCTAssertEqual(state.questions.count,1)
        state.expireQuestions(now:asked.addingTimeInterval(OwnerQuestion.lifetime+1))
        XCTAssertTrue(state.questions.isEmpty)
    }

    // MARK: Opening the call

    func testPressingCallDotQueuesOneCallAndHoldsItUntilTheCallIsOpen() throws {
        var state=MailWorkflowState()
        let now=Date()
        let first=try state.requestCall(accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"],now:now)
        XCTAssertEqual(first.action,.call)
        XCTAssertEqual(first.event.nextAttemptAt,now.addingTimeInterval(MailWorkflowRequest.callHold),"Dot is told once the call is open, not before")
        XCTAssertEqual(state.callsAwaitingLaunch(now:now).map(\.id),[first.id])
        let second=try state.requestCall(accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"],now:now.addingTimeInterval(5))
        XCTAssertEqual(state.requests.map(\.id),[second.id],"a second press replaces the first instead of opening two calls")
    }
    func testOnceTheCallIsOpenDotIsToldAfterAMomentToConnect() throws {
        var state=MailWorkflowState()
        let now=Date()
        let request=try state.requestCall(accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"],now:now)
        state.recordCallLaunch(requestID:request.id,started:true,note:nil,now:now.addingTimeInterval(2))
        XCTAssertEqual(state.requests[0].callLaunch?.started,true)
        XCTAssertEqual(state.requests[0].event.nextAttemptAt,now.addingTimeInterval(2+MailWorkflowRequest.callSettle))
        XCTAssertTrue(state.callsAwaitingLaunch(now:now).isEmpty,"the call is opened once")
        XCTAssertNoThrow(try state.validate())
    }
    func testACallThatCouldNotBeOpenedSaysWhyAndStillReachesDot() throws {
        var state=MailWorkflowState()
        let now=Date()
        let request=try state.requestCall(accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"],now:now)
        state.recordCallLaunch(requestID:request.id,started:false,note:"The ChatGPT app is not installed.",now:now.addingTimeInterval(1))
        XCTAssertEqual(state.requests[0].callLaunch?.note,"The ChatGPT app is not installed.")
        XCTAssertEqual(state.requests[0].event.nextAttemptAt,now.addingTimeInterval(1),"the request waits for whichever call the owner starts")
    }
    func testAnOldRequestNeverOpensTheMicrophoneLater() throws {
        var state=MailWorkflowState()
        let now=Date()
        _ = try state.requestCall(accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"],now:now)
        XCTAssertEqual(state.callsAwaitingLaunch(now:now.addingTimeInterval(MailWorkflowRequest.callLaunchWindow-1)).count,1)
        XCTAssertTrue(state.callsAwaitingLaunch(now:now.addingTimeInterval(MailWorkflowRequest.callLaunchWindow+1)).isEmpty)
        XCTAssertEqual(state.callsTooOldToLaunch(now:now.addingTimeInterval(MailWorkflowRequest.callLaunchWindow+1)).count,1)
    }
    func testACallForAQuestionThatIsNoLongerOpenIsRefused() throws {
        var state=MailWorkflowState()
        XCTAssertThrowsError(try state.requestCall(accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"],questionID:UUID().uuidString))
        let question=try state.ask("Send it today or on Monday?",contextID:nil)
        XCTAssertNoThrow(try state.requestCall(accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"],questionID:question.id))
    }
    func testASpokenReportIsFirstTriedAsASpokenRequestInACall() throws {
        var state=MailWorkflowState()
        let now=Date()
        let call=try state.requestCall(accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"],now:now)
        let report=try state.requestSpokenReport(accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"],now:now)
        XCTAssertEqual(report.action,.status)
        XCTAssertEqual(report.spoken,true)
        XCTAssertTrue(report.opensCall,"the request is spoken to Dot inside a call, the owner's design of 11 November 2026")
        XCTAssertEqual(report.event.nextAttemptAt,now.addingTimeInterval(MailWorkflowRequest.callHold),"the written route waits while the call is tried")
        XCTAssertEqual(Set(state.callsAwaitingLaunch(now:now).map(\.id)),[call.id,report.id])
        let again=try state.requestSpokenReport(accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"],now:now)
        XCTAssertEqual(Set(state.requests.map(\.id)),[call.id,again.id],"a second press replaces the first report and leaves the call alone")
    }
    func testIfTheSpokenRequestCannotBeDeliveredTheWrittenRouteTakesOver() throws {
        var state=MailWorkflowState()
        let now=Date()
        let report=try state.requestSpokenReport(accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"],now:now)
        state.recordCallLaunch(requestID:report.id,started:false,note:"ChatGPT did not take the Mail Dot Voice microphone.",prompted:false,now:now.addingTimeInterval(9))
        XCTAssertEqual(state.requests[0].event.nextAttemptAt,now.addingTimeInterval(9),"Dot is asked in writing at once")
        XCTAssertTrue(state.requests[0].needsEventDelivery)
        XCTAssertTrue(state.callsAwaitingLaunch(now:now.addingTimeInterval(10)).isEmpty)
    }
    func testOnceTheRequestWasSpokenInTheCallNothingIsLeftWaiting() throws {
        var state=MailWorkflowState()
        let report=try state.requestSpokenReport(accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"])
        try state.finishSpokenInCall(requestID:report.id)
        XCTAssertTrue(state.requests.isEmpty,"Dot answers aloud in the call; there is no written report to wait for")
    }

    // MARK: The prompt entered into the call

    func testASpokenReportNeedsNoMessageTypedIntoChatGPT() throws {
        let request=try MailWorkflowRequest(action:.status,accountIDs:["gmail:profile"],spoken:true)
        XCTAssertNil(DotCallPrompt.text(for:request))
    }
    func testACallPromptIsSentBeforeTheCallAndSaysSo() throws {
        let request=try MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"])
        let prompt=try XCTUnwrap(DotCallPrompt.text(for:request))
        XCTAssertTrue(prompt.contains("about to call"),prompt)
        XCTAssertTrue(prompt.contains("get_mail_workflow"))
    }
    func testACallPromptSaysTheCallIsAboutMail() throws {
        let request=try MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"])
        let prompt=try XCTUnwrap(DotCallPrompt.text(for:request))
        XCTAssertTrue(prompt.contains("about my mail"),prompt)
        XCTAssertTrue(prompt.contains(request.id))
        XCTAssertFalse(prompt.contains("spoken mail report"),"the two commands must not read alike")
    }
    func testACallFromAMessageNamesThatMessageAndTheDeliveryQuestion() throws {
        let context=UUID().uuidString
        let request=try MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"],contextID:context)
        let prompt=try XCTUnwrap(DotCallPrompt.text(for:request))
        XCTAssertTrue(prompt.contains("the message I have shared"),prompt)
        XCTAssertTrue(prompt.contains("draft and save or draft and send"))
        XCTAssertFalse(prompt.contains("reply I have shared"),"what is open in Mail is a message")
    }
    func testACallForDotsQuestionAsksDotToPutIt() throws {
        let request=try MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"],questionID:UUID().uuidString)
        XCTAssertTrue(try XCTUnwrap(DotCallPrompt.text(for:request)).contains("the question you left for me"))
    }
    func testThePromptIsPlainTypableTextAndOnlyForRequestsThatOpenACall() throws {
        let request=try MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"],contextID:UUID().uuidString)
        let prompt=try XCTUnwrap(DotCallPrompt.text(for:request))
        XCTAssertTrue(prompt.unicodeScalars.allSatisfy{$0.isASCII && $0.value >= 32},"one line of ASCII, so no input method can alter it")
        XCTAssertLessThanOrEqual(prompt.count,520,"set as the field's value in one step, so its length is bounded only to stay one short paragraph")
        XCTAssertNil(DotCallPrompt.text(for:try MailWorkflowRequest(action:.drafts,accountIDs:["gmail:profile"])))
    }
    func testOnceThePromptIsInTheCallTheBackgroundEventIsNotSentAsWell() throws {
        var state=MailWorkflowState()
        let now=Date()
        let request=try state.requestCall(accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"],now:now)
        XCTAssertTrue(state.requests[0].needsEventDelivery)
        state.recordCallLaunch(requestID:request.id,started:true,note:nil,prompted:true,now:now)
        XCTAssertEqual(state.requests[0].callLaunch?.prompted,true)
        XCTAssertFalse(state.requests[0].needsEventDelivery,"a second, background Dot would answer the same request and the call's report would be refused")
        let other=try state.requestSpokenReport(accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"],now:now)
        state.recordCallLaunch(requestID:other.id,started:true,note:nil,prompted:false,now:now)
        XCTAssertTrue(state.requests.first{$0.id == other.id}!.needsEventDelivery,"if the prompt could not be entered, the event is still how Dot hears of it")
        XCTAssertNoThrow(try state.validate())
    }
    func testACallLaunchSavedByBuild64StillLoads() throws {
        let saved=Data(#"{"started":true,"at":0}"#.utf8)
        let launch=try JSONDecoder().decode(MailWorkflowCallLaunch.self,from:saved)
        XCTAssertNil(launch.prompted)
    }

    // MARK: The words spoken into the call

    func testTheSpokenRequestGoesStraightToTheReport() throws {
        let request=try MailWorkflowRequest(action:.status,accountIDs:["gmail:profile"],spoken:true)
        let words=try XCTUnwrap(DotVoicePrompt.words(for:request))
        XCTAssertTrue(words.contains("mail report"),words)
        XCTAssertTrue(words.lowercased().contains("no greeting"),words)
        XCTAssertTrue(words.lowercased().contains("connection"),"the owner's requirement: no confirmation of the connection first")
        XCTAssertTrue(words.unicodeScalars.allSatisfy{$0.isASCII && $0.value >= 32})
        XCTAssertLessThanOrEqual(words.split(separator:" ").count,45,"a few seconds of speech")
    }
    func testACallsSpokenOpeningNamesItsSubject() throws {
        let general=try XCTUnwrap(DotVoicePrompt.words(for:MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"])))
        XCTAssertTrue(general.contains("about my mail"),general)
        let message=try XCTUnwrap(DotVoicePrompt.words(for:MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"],contextID:UUID().uuidString)))
        XCTAssertTrue(message.contains("the message I have shared"),message)
        XCTAssertTrue(message.contains("draft and save or draft and send"))
        let question=try XCTUnwrap(DotVoicePrompt.words(for:MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"],questionID:UUID().uuidString)))
        XCTAssertTrue(question.contains("question you left for me"),question)
        XCTAssertNil(DotVoicePrompt.words(for:try MailWorkflowRequest(action:.drafts,accountIDs:["gmail:profile"])))
    }

    // MARK: The report read aloud by Mail Dot

    private func spokenRequest(_ state:inout MailWorkflowState,summary:String?,now:Date) throws -> String {
        let request=try state.requestSpokenReport(accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"],now:now)
        if let summary {
            let index=try XCTUnwrap(state.requests.firstIndex{$0.id == request.id})
            try state.requests[index].accept(MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:summary,items:[]))
        }
        return request.id
    }
    func testDotsReportIsReadAloudOnce() throws {
        var state=MailWorkflowState()
        let now=Date()
        let waiting=try spokenRequest(&state,summary:nil,now:now)
        XCTAssertTrue(state.reportsToSpeak(now:now).isEmpty,"nothing to read until Dot has reported")
        try state.dismiss(waiting)
        let id=try spokenRequest(&state,summary:"  Two messages need you. The dean asks for a date.  ",now:now)
        let due=state.reportsToSpeak(now:now.addingTimeInterval(50))
        XCTAssertEqual(due.map(\.id),[id])
        XCTAssertEqual(SpokenReport.text(for:due[0]),"Two messages need you. The dean asks for a date.")
        state.markSpoken(requestID:id,now:now.addingTimeInterval(50))
        XCTAssertTrue(state.reportsToSpeak(now:now.addingTimeInterval(51)).isEmpty,"read once, not at every look")
        XCTAssertNoThrow(try state.validate())
    }
    func testAReportThatArrivesLongAfterThePressIsNotReadAloud() throws {
        var state=MailWorkflowState()
        let now=Date()
        _ = try spokenRequest(&state,summary:"All quiet.",now:now)
        XCTAssertTrue(state.reportsToSpeak(now:now.addingTimeInterval(MailWorkflowRequest.speakWindow+1)).isEmpty,"the Mac must not start talking long after the owner asked")
    }
    func testAnOrdinaryStatusReportIsNotReadAloud() throws {
        var state=MailWorkflowState()
        let request=try MailWorkflowRequest(action:.status,accountIDs:["gmail:profile"])
        try state.enqueue(request,allowedAccountIDs:["gmail:profile"])
        try state.requests[0].accept(MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"All quiet.",items:[]))
        XCTAssertTrue(state.reportsToSpeak().isEmpty)
    }
    func testAFailedReportIsSaidToHaveFailed() throws {
        var state=MailWorkflowState()
        let now=Date()
        let request=try state.requestSpokenReport(accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"],now:now)
        try state.requests[0].accept(MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.failed,summary:"Gmail did not answer.",items:[]))
        let due=state.reportsToSpeak(now:now)
        XCTAssertEqual(due.count,1)
        XCTAssertEqual(SpokenReport.text(for:due[0]),"Dot could not give the mail report. Gmail did not answer.")
    }
    func testAVeryLongReportIsCutAtASentenceForTheEar() throws {
        var state=MailWorkflowState()
        let long=String(repeating:"This sentence is about mail. ",count:200)
        _ = try spokenRequest(&state,summary:long,now:Date())
        let text=try XCTUnwrap(SpokenReport.text(for:state.requests[0]))
        XCTAssertLessThanOrEqual(text.count,SpokenReport.limit+60)
        XCTAssertTrue(text.hasSuffix("The rest is in Mail Dot."))
        XCTAssertTrue(text.dropLast(" The rest is in Mail Dot.".count).hasSuffix("mail."),"cut between sentences")
    }

    // MARK: The owner answers Dot on the Mac

    func testTheOwnersAnswerIsKeptAndSentToDotAtOnce() throws {
        let (root,workflow)=try linked()
        let id=try XCTUnwrap(tool("ask_owner",["question":"Shall I draft and save, or draft and send?"],root)["question_id"].string)
        let now=Date()
        let request=try workflow.transaction { try $0.answerQuestion(id,with:"  Draft and send.\n",accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"],now:now) }
        XCTAssertEqual(request.action,.answer)
        XCTAssertEqual(request.questionID,id)
        XCTAssertEqual(request.event.nextAttemptAt,now)
        XCTAssertTrue(request.needsEventDelivery)
        XCTAssertFalse(request.opensCall)
        let saved=try XCTUnwrap(workflow.read().questions.first)
        XCTAssertEqual(saved.answer,"Draft and send.")
        XCTAssertEqual(saved.answeredAt,now)
        let read=try tool("get_mail_workflow",["request_id":.string(request.id)],root)
        XCTAssertEqual(read["request"]["action"],"answer")
        XCTAssertEqual(read["question"]["text"],"Shall I draft and save, or draft and send?")
        XCTAssertEqual(read["question"]["answer"],"Draft and send.")
        XCTAssertEqual(try tool("get_mail_workflow",[:],root)["open_questions"].array?.first?["answer"],"Draft and send.")
    }
    func testOnceDotHasActedOnTheAnswerTheQuestionCloses() throws {
        let (root,workflow)=try linked()
        let id=try XCTUnwrap(tool("ask_owner",["question":"How should I revise the second paragraph?"],root)["question_id"].string)
        let request=try workflow.transaction { try $0.answerQuestion(id,with:"Make it shorter and warmer.",accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"]) }
        let working=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.working,summary:"Revising.",items:[])
        _ = try tool("report_mail_workflow",["report":try .encode(working)],root)
        XCTAssertEqual(try workflow.read().questions.count,1,"still open while Dot works")
        let done=MailWorkflowReport(requestID:request.id,expectedRevision:1,stage:.ready,summary:"Revised as asked.",items:[])
        _ = try tool("report_mail_workflow",["report":try .encode(done)],root)
        XCTAssertTrue(try workflow.read().questions.isEmpty)
    }
    func testAnAnswerMustBePlainTextForAnOpenQuestion() throws {
        var state=MailWorkflowState()
        XCTAssertThrowsError(try state.answerQuestion(UUID().uuidString,with:"Yes.",accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"]))
        let question=try state.ask("Send it today or on Monday?",contextID:nil)
        XCTAssertThrowsError(try state.answerQuestion(question.id,with:"   ",accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"]))
        XCTAssertThrowsError(try state.answerQuestion(question.id,with:String(repeating:"a",count:OwnerQuestion.textLimit+1),accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"]))
        XCTAssertNil(state.questions[0].answer)
        XCTAssertTrue(state.requests.isEmpty)
    }
    func testAChangedAnswerReplacesTheEarlierOne() throws {
        var state=MailWorkflowState()
        let question=try state.ask("Send it today or on Monday?",contextID:nil)
        _ = try state.answerQuestion(question.id,with:"Today.",accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"])
        let second=try state.answerQuestion(question.id,with:"No, Monday.",accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"])
        XCTAssertEqual(state.requests.map(\.id),[second.id],"Dot is not left holding a withdrawn answer")
        XCTAssertEqual(state.questions[0].answer,"No, Monday.")
        XCTAssertNoThrow(try state.validate())
    }
    func testAnAnsweredQuestionIsNotAskedAgainAsNew() throws {
        var state=MailWorkflowState()
        let question=try state.ask("Send it today or on Monday?",contextID:nil)
        _ = try state.answerQuestion(question.id,with:"Monday.",accountIDs:["gmail:profile"],allowedAccountIDs:["gmail:profile"])
        XCTAssertEqual(try state.ask("Send it today or on Monday?",contextID:nil).id,question.id)
        XCTAssertEqual(state.questions.count,1)
    }
    func testQuestionsSavedBeforeAnswersExistedStillLoad() throws {
        let saved=Data(#"{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","text":"Which one?","askedAt":0}"#.utf8)
        let question=try JSONDecoder().decode(OwnerQuestion.self,from:saved)
        XCTAssertNil(question.answer)
    }
    func testDotIsToldWhatAnAnswerIsAndIsNot() {
        XCTAssertTrue(MailWorkflowTools.instructions.contains("action answer"))
        XCTAssertTrue(MailWorkflowTools.instructions.contains("still needs their Confirm on the Mac"))
    }

    // MARK: What Dot is told

    func testDotIsToldHowToUseTheCall() {
        let workflow=MailWorkflowTools.instructions
        XCTAssertTrue(workflow.contains("action call"))
        XCTAssertTrue(workflow.contains("spoken"))
        XCTAssertTrue(workflow.contains("draft and save or draft and send"))
        let standing=MCPRouter.instructions
        XCTAssertTrue(standing.contains("ask_owner"))
        XCTAssertTrue(standing.contains("At the start of every voice call"))
        XCTAssertFalse(standing.contains("reply is open"),"the item open in Mail is a message")
    }

    /// Owner's test, 18 November 2026: with ChatGPT in Japanese Mail Dot found neither Start call nor the message
    /// field. The names come from ChatGPT's own translation tables, under keys that are the same in every language.
    func testControlNamesAreReadFromChatGPTsTablesInEveryLanguage() {
        let japanese = Data(#"export const m={x(e){e.exports=JSON.parse('{"a.b":"キャンセル","chatgptConversations.composer.send.ariaLabel":"送信","restricted.orbit.voiceCall.calling":"発信中…","restricted.orbit.voiceCall.hangUp":"通話を終了","restricted.orbit.voiceCall.muteMic":"マイクをミュート","restricted.orbit.voiceCall.sidebarActive":"進行中の通話","restricted.orbit.voiceCall.start":"通話を開始","restricted.orbit.voiceCall.unmuteMic":"マイクのミュートを解除","restricted.orbit.voiceCall.setupWithName.dot":"{hasName, select, true {{name}} other {dot} }に電話する"}')}}"#.utf8)
        let german = Data(#"{"restricted.orbit.voiceCall.start":"Anruf starten","restricted.orbit.voiceCall.hangUp":"Auflegen","composer.submitButtonTooltip.send":"Senden"}"#.utf8)
        let other = Data(#"{"restricted.orbit.voiceCall.hangUp":"not a table: it lacks the start key"}"#.utf8)
        let labels = ChatGPTLabels.reading(tables: [japanese, german, other])
        XCTAssertEqual(labels.start, ["Start call", "通話を開始", "Anruf starten"])
        XCTAssertEqual(labels.hangUp, ["Hang up", "通話を終了", "Auflegen"])
        XCTAssertEqual(labels.send, ["Send", "送信", "Senden"])
        XCTAssertTrue(labels.otherDuringCall.isSuperset(of: ["発信中…", "進行中の通話", "マイクをミュート", "マイクのミュートを解除", "Calling…"]))
        XCTAssertEqual(DotCallControl.state(labels: ["通話を開始"], known: labels), .canStart)
        XCTAssertEqual(DotCallControl.state(labels: ["通話を開始", "進行中の通話"], known: labels), .inCall, "a second press could hang up")
        XCTAssertEqual(DotCallControl.state(labels: ["通話を開始"]), .absent, "English alone does not know it")
        XCTAssertEqual(ChatGPTLabels.reading(tables: []), .english, "nothing read: the English names, as before")
    }

    /// A name that means "start" in one language and "in a call" in another is never a start name.
    func testAStartNameThatIsAlsoADuringCallNameIsDropped() {
        let one = Data(#"{"restricted.orbit.voiceCall.start":"Appel","restricted.orbit.voiceCall.hangUp":"Raccrocher"}"#.utf8)
        let two = Data(#"{"restricted.orbit.voiceCall.start":"Starten","restricted.orbit.voiceCall.sidebarActive":"Appel"}"#.utf8)
        let labels = ChatGPTLabels.reading(tables: [one, two])
        XCTAssertFalse(labels.start.contains("Appel"))
        XCTAssertEqual(DotCallControl.state(labels: ["Appel"], known: labels), .inCall)
        XCTAssertTrue(labels.start.contains("Start call"))
    }

    // MARK: The call waits for Dot to have read the request (owner's report, 18 November 2026)

    private func read(_ id:String,at:Date,tool:String="get_mail_workflow",outcome:ToolCallRecord.Outcome = .ok) -> ToolCallRecord {
        ToolCallRecord(at:at,method:"tools/call",tool:tool,outcome:outcome,detail:nil,request:id)
    }
    /// A clock the test moves, and a record of Dot's calls that fills as time passes.
    private final class Stage:@unchecked Sendable {
        var now:Date; var arrivals:[(at:Date,record:ToolCallRecord)]=[]; var pauses=0
        init(_ start:Date) { now=start }
        var seen:[ToolCallRecord] { arrivals.filter{ $0.at <= now }.map(\.record) }
    }

    func testANormalLaunchOpensAsSoonAsDotHasReadTheRequest() async throws {
        let start=Date(timeIntervalSince1970:1_800_000_000)
        let request=try MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"],createdAt:start)
        let stage=Stage(start)
        stage.arrivals=[(start.addingTimeInterval(4),read(request.id,at:start.addingTimeInterval(4)))]
        let results=await CallHandoff.wait(for:[request],clock:{ stage.now },records:{ stage.seen },pause:{ stage.now.addTimeInterval(1); stage.pauses += 1 })
        XCTAssertEqual(results[request.id],.read(after:4))
        XCTAssertEqual(stage.pauses,4,"it ends on the read, not on a fixed delay")
    }

    func testADelayedHandoffStillOpensOnTheReadWithinTheLimit() async throws {
        let start=Date(timeIntervalSince1970:1_800_000_000)
        let request=try MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"],createdAt:start)
        let stage=Stage(start)
        stage.arrivals=[(start.addingTimeInterval(43),read(request.id,at:start.addingTimeInterval(43)))]
        let results=await CallHandoff.wait(for:[request],limit:45,clock:{ stage.now },records:{ stage.seen },pause:{ stage.now.addTimeInterval(1) })
        XCTAssertEqual(results[request.id],.read(after:43),"with the hold set to 45 seconds, a read at 43, as for request B039210B, opens the call")
        // With the hold as shipped the call has opened by then, and Dot's first words ask the owner to hold on.
        let again=Stage(start); again.arrivals=stage.arrivals
        let shipped=await CallHandoff.wait(for:[request],clock:{ again.now },records:{ again.seen },pause:{ again.now.addTimeInterval(1) })
        XCTAssertEqual(shipped[request.id],.unread)
    }

    func testATimeoutEndsTheWaitAndNamesTheRequestUnread() async throws {
        let start=Date(timeIntervalSince1970:1_800_000_000)
        let request=try MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"],createdAt:start)
        let stage=Stage(start)
        let results=await CallHandoff.wait(for:[request],clock:{ stage.now },records:{ stage.seen },pause:{ stage.now.addTimeInterval(1) })
        XCTAssertEqual(results[request.id],.unread)
        XCTAssertEqual(stage.now.timeIntervalSince(start),CallHandoff.limit,accuracy:1,"bounded")
        // The hold is short: the owner is not kept waiting for a read that usually takes Dot longer.
        XCTAssertLessThanOrEqual(CallHandoff.limit,15)
        XCTAssertEqual(CallHandoff.limit(set:nil),CallHandoff.limit)
        XCTAssertEqual(CallHandoff.limit(set:45),45,"a longer hold can be set for a test of the handoff")
        XCTAssertEqual(CallHandoff.limit(set:600),CallHandoff.limit,"never an unbounded one")
        XCTAssertEqual(CallHandoff.limit(set:0),0)
    }

    func testTwoCloseRequestsAreNeverConfusedAndAnOlderReadDoesNotCount() async throws {
        let start=Date(timeIntervalSince1970:1_800_000_000)
        let first=try MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"],createdAt:start)
        let second=try MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"],createdAt:start.addingTimeInterval(2))
        // Dot reads the first request; that says nothing about the second.
        XCTAssertFalse(CallHandoff.acknowledged(second,records:[read(first.id,at:start.addingTimeInterval(5))]))
        XCTAssertTrue(CallHandoff.acknowledged(first,records:[read(first.id,at:start.addingTimeInterval(5))]))
        // A read recorded before the request was made, a refused read and another tool do not count.
        XCTAssertFalse(CallHandoff.acknowledged(second,records:[read(second.id,at:start.addingTimeInterval(1))]),"stale: from before the request existed")
        XCTAssertFalse(CallHandoff.acknowledged(second,records:[read(second.id,at:start.addingTimeInterval(6),outcome:.refused)]))
        XCTAssertFalse(CallHandoff.acknowledged(second,records:[read(second.id,at:start.addingTimeInterval(6),tool:"report_mail_workflow")]))
        // Both held together: the first is read, the second times out, and each is told apart.
        let stage=Stage(start.addingTimeInterval(2))
        stage.arrivals=[(start.addingTimeInterval(9),read(first.id,at:start.addingTimeInterval(9)))]
        let results=await CallHandoff.wait(for:[first,second],limit:45,clock:{ stage.now },records:{ stage.seen },pause:{ stage.now.addTimeInterval(1) })
        XCTAssertEqual(results[first.id],.read(after:7))
        XCTAssertEqual(results[second.id],.unread)
    }

    /// Owner's instruction, 18 November 2026: on answering, Dot acknowledges the request and, if it needs more time,
    /// asks the owner to hold on the line while it looks into it.
    func testEveryCallMessageSaysWhatDotsFirstWordsAre() throws {
        let general=try XCTUnwrap(DotCallPrompt.text(for:try MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"])))
        let message=try XCTUnwrap(DotCallPrompt.text(for:try MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"],contextID:UUID().uuidString)))
        let question=try XCTUnwrap(DotCallPrompt.text(for:try MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"],questionID:UUID().uuidString)))
        for text in [general,message,question] {
            XCTAssertTrue(text.contains("first tell me you have my Mail Dot request"),text)
            XCTAssertTrue(text.contains("ask me to hold on while you look into it"),text)
            XCTAssertTrue(text.contains("I couldn't load the Mail Dot context"),text)
            XCTAssertTrue(text.unicodeScalars.allSatisfy{ $0.isASCII && $0.value >= 32 })
        }
        XCTAssertTrue(general.contains("Then ask what I need help with in my mail"),general)
        XCTAssertTrue(question.contains("Then put that question to me"),question)
        XCTAssertTrue(MailWorkflowTools.instructions(for:nil).contains("ask the owner to hold on the line while you look into it"))
    }

    /// The order in use since the owner's trial of 18 November 2026: the message goes into the open call, worded as he
    /// heard it work, and the earlier order is only for a test on a Mac.
    func testAMessageSentIntoAnOpenCallSaysTheCallIsOpen() throws {
        XCTAssertEqual(CallHandoff.messageFirstKey,"CallPromptBeforeLaunch","the earlier order is the one that needs a setting")
        let request=try MailWorkflowRequest(action:.call,accountIDs:["gmail:profile"])
        let text=try XCTUnwrap(DotCallPrompt.text(for:request,callOpen:true))
        XCTAssertTrue(text.contains("I have just called you"),text)
        XCTAssertFalse(text.contains("about to call"),text)
        XCTAssertTrue(text.contains("Now tell me you have my Mail Dot request"),text)
        XCTAssertEqual(text,"Mail Dot: I have just called you from Mail. This call is about my mail. Read Mail Dot request \(request.id) with get_mail_workflow now. Now tell me you have my Mail Dot request and, if you are still reading it, ask me to hold on while you look into it. If you cannot read it, say \"I couldn't load the Mail Dot context\". Then ask what I need help with in my mail.","exactly the words that worked in the owner's trial")
        XCTAssertTrue(text.contains(request.id))
        XCTAssertTrue(text.unicodeScalars.allSatisfy{ $0.isASCII && $0.value >= 32 })
        XCTAssertLessThanOrEqual(text.count,520)
    }
}
