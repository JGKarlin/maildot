import XCTest
@testable import BridgeCore

/// Ask Dot: a question about the whole account, answered by Dot with a citation for every statement (14 November 2026).
final class AskDotTests:XCTestCase {
    func testTheAnswerAndItsSourcesAreRead() {
        let summary="The seminar is on December 10 [1], and the room was booked on Monday [2].\nSources: [{\"n\":2,\"sender\":\"Front Desk\",\"subject\":\"Room\",\"date\":\"2026-11-09\",\"message_id\":\"<b@example.invalid>\"},{\"n\":1,\"sender\":\"A Colleague\",\"subject\":\"Seminar\",\"date\":\"2026-11-13\",\"message_id\":\"a@example.invalid\",\"web_url\":\"https://mail.example.invalid/x\"}]"
        let (answer,sources)=AskDot.parse(summary)
        XCTAssertEqual(answer,"The seminar is on December 10 [1], and the room was booked on Monday [2].")
        XCTAssertEqual(sources.map(\.n),[1,2])
        XCTAssertEqual(AskDot.citations(in:answer),[1,2])
        XCTAssertEqual(sources[0].mailURL?.absoluteString,"message://%3Ca@example.invalid%3E")
        XCTAssertEqual(sources[1].mailURL?.absoluteString,"message://%3Cb@example.invalid%3E","angle brackets in Dot's Message-ID are not doubled")
        XCTAssertNotNil(sources[0].webAddress)
        // The array on a line of its own, without the marker, is read too; an answer without sources has none.
        XCTAssertEqual(AskDot.parse("Found it [1].\n[{\"n\":1,\"subject\":\"X\"}]").sources.count,1)
        XCTAssertTrue(AskDot.parse("Nothing found.").sources.isEmpty)
        XCTAssertNil(AskDot.Source(n:1,sender:nil,subject:nil,date:nil,messageID:nil,webURL:"http://insecure.example.invalid").webAddress,"only https opens on the web")
    }
    func testThePeriodsCountBackFromTodayAndCalendarYearsAreCalendarYears() throws {
        var calendar=Calendar(identifier:.gregorian); calendar.timeZone=TimeZone(identifier:"Asia/Tokyo")!
        let now=calendar.date(from:DateComponents(year:2026,month:11,day:14,hour:15))!
        func day(_ y:Int,_ m:Int,_ d:Int) -> Date { calendar.date(from:DateComponents(year:y,month:m,day:d))! }
        XCTAssertNil(AskDot.Period.anyTime.range(now:now,calendar:calendar))
        XCTAssertEqual(AskDot.Period.today.range(now:now,calendar:calendar)?.from,day(2026,11,14))
        let yesterday=try XCTUnwrap(AskDot.Period.yesterday.range(now:now,calendar:calendar))
        XCTAssertEqual(yesterday.from,day(2026,11,13)); XCTAssertEqual(yesterday.to,day(2026,11,14))
        XCTAssertEqual(AskDot.Period.last7Days.range(now:now,calendar:calendar)?.from,day(2026,11,7))
        XCTAssertEqual(AskDot.Period.last30Days.range(now:now,calendar:calendar)?.from,day(2026,10,15))
        XCTAssertEqual(AskDot.Period.last3Months.range(now:now,calendar:calendar)?.from,day(2026,8,14))
        XCTAssertEqual(AskDot.Period.last12Months.range(now:now,calendar:calendar)?.from,day(2025,11,14))
        XCTAssertEqual(AskDot.Period.thisYear.range(now:now,calendar:calendar)?.from,day(2026,1,1))
        let lastYear=try XCTUnwrap(AskDot.Period.lastYear.range(now:now,calendar:calendar))
        XCTAssertEqual(lastYear.from,day(2025,1,1)); XCTAssertEqual(lastYear.to,day(2026,1,1))
        var custom=AskDot.Filters(); custom.period = .custom; custom.customFrom=day(2026,3,5); custom.customTo=day(2026,3,1)
        let range=try XCTUnwrap(custom.range(now:now,calendar:calendar))
        XCTAssertEqual(range.from,day(2026,3,1)); XCTAssertEqual(range.to,day(2026,3,6),"both days are included, whichever order they were given in")
    }
    func testAQuestionGoesToDotOnceAndItsAnswerComesBack() throws {
        var state=MailTriageState()
        XCTAssertThrowsError(try state.ask("   ",filters:nil))
        let question=try state.ask("When is the seminar?",filters:AskDot.Filters())
        XCTAssertNil(question.filters,"filters that narrow nothing are not kept")
        XCTAssertEqual(state.asksDue().map(\.id),[question.id])
        state.markAskSent(question.id,requestID:"q1")
        XCTAssertTrue(state.asksDue().isEmpty)
        XCTAssertTrue(state.queueForDot().isEmpty,"a question is not a draft request")
        XCTAssertFalse(state.acceptAsk(requestID:"other",stage:.ready,summary:"x"))
        XCTAssertTrue(state.acceptAsk(requestID:"q1",stage:.ready,summary:"December 10 [1].\nSources: [{\"n\":1,\"subject\":\"Seminar\",\"message_id\":\"a@example.invalid\"}]"))
        XCTAssertEqual(state.askList[0].state,.answered)
        XCTAssertEqual(state.askList[0].sources?.count,1)
        // Unanswered questions are given up after the answer limit; only the latest questions are kept.
        let late=try state.ask("And the room?",filters:nil); state.markAskSent(late.id,requestID:"q2")
        XCTAssertEqual(state.expireAsks(now:Date().addingTimeInterval(MailTriageState.answerLimit+60)),1)
        XCTAssertEqual(state.askList.last?.state,.failed)
        for index in 0..<30 { try state.ask("Question \(index)",filters:nil) }
        XCTAssertEqual(state.askList.count,AskDot.keep)
    }
    func testOlderSavedListsStillLoadAndDotIsToldToCite() throws {
        let saved=try JSONEncoder().encode(MailTriageState())
        XCTAssertTrue(try JSONDecoder().decode(MailTriageState.self,from:saved).askList.isEmpty)
        XCTAssertTrue(MailWorkflowTools.instructions(for:.ask).contains("Sources:"))
        XCTAssertTrue(MailWorkflowTools.instructions(for:.ask).contains("message_id"))
    }
    func testDraftingNotesArePolishedByDotAndOldNotesCarryOver() throws {
        // A note saved before 14 November 2026, one text, becomes one entry.
        let legacy=try JSONDecoder().decode(SenderNote.self,from:Data(#"{"text":"Formal Japanese.","name":"田中"}"#.utf8))
        XCTAssertEqual(legacy.items.map(\.text),["Formal Japanese."]); XCTAssertEqual(legacy.name,"田中")
        var settings=MailSettings()
        try settings.addSenderNote("adress him as dr hartman",for:"leon@example.invalid",name:"Leon")
        try settings.addSenderNote("short replys",for:"leon@example.invalid",name:nil)
        let ids=settings.senderNote(for:"leon@example.invalid")!.items.map(\.id)
        XCTAssertEqual(settings.senderNote(for:"leon@example.invalid")?.waitingForPolish.count,2)
        for _ in 0..<8 { try settings.addSenderNote("more",for:"leon@example.invalid",name:nil) }
        XCTAssertThrowsError(try settings.addSenderNote("one too many",for:"leon@example.invalid",name:nil))
        for id in settings.senderNote(for:"leon@example.invalid")!.items.map(\.id).dropFirst(2) { settings.removeSenderNote(id,for:"leon@example.invalid") }
        settings.markNotesPolishAsked(for:"Leon@example.invalid")
        // Dot's answer replaces the words of each note it names; the others keep the owner's.
        settings.applyPolishedNotes(for:"leon@example.invalid",answer:"Here: [{\"id\":\"\(ids[0])\",\"text\":\"Address him as Dr. Hartman.\"}]")
        let note=settings.senderNote(for:"leon@example.invalid")!
        XCTAssertEqual(note.items.map(\.text),["Address him as Dr. Hartman.","short replys"])
        XCTAssertTrue(note.waitingForPolish.isEmpty); XCTAssertNil(note.polishAskedAt)
        // An edit waits again; an answer that never comes is given up, keeping the owner's words.
        try settings.updateSenderNote(ids[1],text:"Keep replies short.",for:"leon@example.invalid")
        settings.markNotesPolishAsked(for:"leon@example.invalid",now:Date(timeIntervalSinceNow:-3600))
        XCTAssertEqual(settings.expireNotePolish(),1)
        XCTAssertEqual(settings.senderNote(for:"leon@example.invalid")?.items.last?.text,"Keep replies short.")
        XCTAssertTrue(settings.senderNote(for:"leon@example.invalid")!.waitingForPolish.isEmpty)
        XCTAssertNoThrow(try MailWorkflowRequest(action:.noteCleanup,accountIDs:["gmail:a@example.invalid"],noteAddress:"leon@example.invalid"))
        XCTAssertThrowsError(try MailWorkflowRequest(action:.noteCleanup,accountIDs:["gmail:a@example.invalid"]))
        XCTAssertTrue(MailWorkflowTools.instructions(for:.noteCleanup).contains("JSON array"))
    }
    func testSenderNotesReachDotAndReportRulesApply() throws {
        var settings=MailSettings()
        XCTAssertNil(settings.senderNotesInstruction(for:["tanaka@example.invalid"]))
        try settings.addSenderNote("Reply in formal Japanese.",for:"Tanaka@Example.invalid",name:"田中")
        try settings.addSenderNote("Keep it short.",for:"tanaka@example.invalid",name:nil)
        XCTAssertTrue(settings.senderNotesInstruction(for:["田中 <Tanaka@example.invalid>"])?.contains("tanaka@example.invalid: Reply in formal Japanese. / Keep it short.") == true)
        try settings.addSenderNote("Sign as J.",for:"other@example.invalid",name:nil)
        XCTAssertFalse(settings.senderNotesInstruction(for:["tanaka@example.invalid"])!.contains("other@"),"only the recipient's notes go with a request")
        XCTAssertNil(settings.senderNotesInstruction(for:["nobody@example.invalid"]))
        settings.removeSenderNote(settings.senderNote(for:"other@example.invalid")!.items[0].id,for:"other@example.invalid")
        XCTAssertEqual(settings.senderNote(for:"tanaka@example.invalid")?.name,"田中")
        XCTAssertThrowsError(try settings.addSenderNote(String(repeating:"x",count:SenderNote.textLimit+1),for:"a@example.invalid",name:nil))
        for id in settings.senderNote(for:"tanaka@example.invalid")!.items.map(\.id) { settings.removeSenderNote(id,for:"tanaka@example.invalid") }
        XCTAssertNil(settings.senderNotes,"deleting the last note removes the person")
        // Always: a skipped message from the sender gets a report-only request. Never: no automatic report is kept.
        var state=MailTriageState()
        state.setReportRule(.always,for:"List@example.invalid")
        var skipped=MailTriageEntry(messageID:"s@example.invalid",sender:"list@example.invalid",senderName:nil,subject:"News",receivedAt:Date(),verdict:.init(essential:false,reason:"Bulk mail."),automatic:true)
        skipped.outcome = .skipped
        state.record(skipped)
        state.requestReportIfAlways(messageID:"s@example.invalid")
        XCTAssertEqual(state.reportsDue().count,1)
        XCTAssertTrue(state.queueForDot().isEmpty,"a report is never a draft request")
        state.setReportRule(.never,for:"quiet@example.invalid")
        var asked=MailTriageEntry(messageID:"n@example.invalid",sender:"quiet@example.invalid",senderName:nil,subject:"Hello",receivedAt:Date(),verdict:.init(essential:true,reason:"Direct"),automatic:true)
        asked.outcome = .asked; asked.requestID="r1"
        state.record(asked)
        state.accept(requestID:"r1",stage:.ready,summary:"No reply needed: a greeting.\nThread report: {\"now\":\"Nothing waits on you.\"}")
        XCTAssertNil(state.entries.last?.report)
        XCTAssertEqual(state.entries.last?.outcome,.noDraft)
        state.setReportRule(nil,for:"quiet@example.invalid")
        XCTAssertNil(state.reportRule(for:"quiet@example.invalid"))
    }
    func testAskDotGoesBeforeAutomaticRequests() throws {
        var state=MailTriageState()
        var entry=MailTriageEntry(messageID:"p@example.invalid",sender:"a@example.invalid",senderName:nil,subject:"Hi",receivedAt:Date(),verdict:.init(essential:true,reason:"Direct"),automatic:true)
        entry.outcome = .pending
        state.record(entry)
        XCTAssertEqual(state.dueForDot().count,1)
        let question=try state.ask("Where is the budget?",filters:nil)
        XCTAssertTrue(state.dueForDot().isEmpty,"nothing automatic starts while the owner's question waits")
        state.markAskSent(question.id,requestID:"q")
        XCTAssertTrue(state.dueForDot().isEmpty)
        state.acceptAsk(requestID:"q",stage:.ready,summary:"Nothing found.")
        XCTAssertEqual(state.dueForDot().count,1,"the queue resumes once Dot has answered")
    }
    func testPersonAndAttachmentFilters() throws {
        var filters=AskDot.Filters()
        XCTAssertTrue(filters.isEmpty)
        filters.person="Yuko"
        XCTAssertFalse(filters.isEmpty)
        filters.person=nil; filters.hasAttachments=true
        XCTAssertFalse(filters.isEmpty)
        var state=MailTriageState()
        let question=try state.ask("The budget PDF",filters:filters)
        XCTAssertEqual(question.filters?.hasAttachments,true)
        XCTAssertTrue(MailWorkflowTools.instructions(for:.ask).contains("has_attachments"))
        XCTAssertTrue(MailWorkflowTools.instructions(for:.ask).contains("person"))
    }
    func testPeopleAreSuggestedAsTheOwnerTypes() {
        var state=MailTriageState()
        for (name,address) in [("Yuko Ishida","ishida@example.invalid"),("Daniel Reyes","daniel@example.invalid"),("Priya Nair","p.nair@example.invalid")] {
            state.record(MailTriageEntry(messageID:"\(address)-m",sender:address,senderName:name,subject:"x",receivedAt:Date(),verdict:.init(essential:true,reason:"Direct"),automatic:true))
        }
        state.learnCorrespondent("yuki@example.invalid")
        XCTAssertEqual(state.peopleMatching("yu").map(\.address),["ishida@example.invalid","yuki@example.invalid"],"names and addresses that begin with the text")
        XCTAssertEqual(state.peopleMatching("Reyes").first?.name,"Daniel Reyes","a surname matches too")
        XCTAssertEqual(state.peopleMatching("nair").first?.address,"p.nair@example.invalid")
        XCTAssertTrue(state.peopleMatching("").isEmpty)
    }
}

/// Release review, 14 November 2026: waiting that never ended, and answers that arrived unseen.
final class ReviewFollowUpTests:XCTestCase {
    func testARuleStopsWaitingForDotAfterTheAnswerLimitAndKeepsTheOwnersWords() throws {
        var settings=MailSettings()
        try settings.addDraftingRule("Sign off with my first name")
        let id=try XCTUnwrap(settings.rulesToTidy.last?.id)
        XCTAssertEqual(settings.expireRuleTidying(now:Date().addingTimeInterval(60)),0)
        XCTAssertEqual(settings.rulesToTidy.count,1)
        XCTAssertEqual(settings.expireRuleTidying(now:Date().addingTimeInterval(MailTriageState.answerLimit+1)),1)
        XCTAssertTrue(settings.rulesToTidy.isEmpty)
        XCTAssertEqual(settings.draftingRules?.first{$0.id == id}?.text,"Sign off with my first name")
        // A late answer no longer replaces the words.
        settings.applyTidiedRule(id,text:"Something else")
        XCTAssertEqual(settings.draftingRules?.first{$0.id == id}?.text,"Sign off with my first name")
    }
    func testARuleSavedWaitingByAnEarlierBuildIsGivenTheLimitFromNow() throws {
        var settings=MailSettings()
        var rule=DraftingRule(text:"Keep replies short"); rule.tidying=true
        settings.draftingRules=[rule]
        let now=Date()
        XCTAssertEqual(settings.expireRuleTidying(now:now),0)
        XCTAssertEqual(settings.draftingRules?[0].tidyingSince,now)
        XCTAssertEqual(settings.expireRuleTidying(now:now.addingTimeInterval(MailTriageState.answerLimit+1)),1)
        XCTAssertNil(settings.draftingRules?[0].tidying)
    }
    func testAnAnswerIsUnreadUntilShown() throws {
        var state=MailTriageState()
        let question=try state.ask("When is the board meeting?",filters:nil)
        XCTAssertNil(state.askList[0].unread)
        state.markAskSent(question.id,requestID:"r1")
        XCTAssertTrue(state.acceptAsk(requestID:"r1",stage:.ready,summary:"Thursday at 10."))
        XCTAssertEqual(state.askList[0].unread,true)
        XCTAssertFalse(state.markAsksRead(["another"]))
        XCTAssertTrue(state.markAsksRead([question.id]))
        XCTAssertNil(state.askList[0].unread)
        XCTAssertFalse(state.markAsksRead([question.id]))
    }
    func testQuestionsSavedByEarlierBuildsCountAsRead() throws {
        var state=MailTriageState()
        try state.ask("Earlier question",filters:nil)
        var data=try JSONEncoder().encode(state.askList)
        data=Data(String(decoding:data,as:UTF8.self).replacingOccurrences(of:"\"unread\":true,",with:"").utf8)
        XCTAssertNil(try JSONDecoder().decode([AskDot.Question].self,from:data)[0].unread)
    }
}

