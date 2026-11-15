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
        XCTAssertTrue(MailWorkflowTools.instructions(for:.ask).contains("MUST also carry sources"))
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

/// Ask Dot review, 15 November 2026: every answer says what was searched in every account asked about.
final class AskCoverageTests:XCTestCase {
    private func bridge() throws -> (URL,MailWorkflowRequest) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("ask-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try MailSettingsStore(bridgeDirectory:root).transaction {
            var first=MailConnection(id:"a",email:"owner@example.invalid",connectionID:"link"); first.observedAt=Date()
            var second=MailConnection(id:"b",email:"owner@work.example.invalid",connectionID:"link2"); second.observedAt=Date()
            $0.connections=[first,second]
            try $0.addDraftingRule("Sign with my first name")
        }
        let request=try MailWorkflowRequest(action:.ask,accountIDs:["gmail:a","gmail:b"])
        try MailWorkflowStore(bridgeDirectory:root).transaction { try $0.enqueue(request,allowedAccountIDs:["gmail:a","gmail:b"]) }
        try MailTriageStore(bridgeDirectory:root).transaction {
            var filters=AskDot.Filters(); filters.accountName="Work"; filters.person="Priya"
            let question=try $0.ask("What did Priya decide?",filters:filters)
            $0.markAskSent(question.id,requestID:request.id)
        }
        return (root,request)
    }
    func testTheRequestGivesEachAccountsRouteAndLeavesOutDraftingRulesAndTheAccountFilter() throws {
        let (root,request)=try bridge(); defer { try? FileManager.default.removeItem(at:root) }
        let read=try MailWorkflowTools.call("get_mail_workflow",arguments:["request_id":.string(request.id)],bridgeDirectory:root)
        let reach=try XCTUnwrap(read["reach"].array)
        XCTAssertEqual(reach.map{ $0["account"].string },["gmail:a","gmail:b"])
        XCTAssertEqual(reach[0]["route"],"gmail_connector")
        XCTAssertNil(read["question"]["filters"].object?["account"],"the accounts are the request's own")
        XCTAssertEqual(read["question"]["filters"]["person"],"Priya")
        let instructions=try XCTUnwrap(read["instructions"].string)
        XCTAssertTrue(instructions.contains("MUST search every account in reach"))
        XCTAssertTrue(instructions.contains("has:attachment"))
        XCTAssertFalse(instructions.contains("Sign with my first name"),"a question drafts nothing, so it carries no drafting rules")
    }
    func testAnAnswerThatDoesNotCoverEveryAccountIsRefusedAndACompleteOneIsShownPerAccount() throws {
        let (root,request)=try bridge(); defer { try? FileManager.default.removeItem(at:root) }
        _ = try MailWorkflowTools.call("get_mail_workflow",arguments:["request_id":.string(request.id)],bridgeDirectory:root)
        var report=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"She chose Harbor Hall [1].\nSources: [{\"n\":1,\"subject\":\"Venue\"}]",items:[])
        XCTAssertThrowsError(try MailWorkflowTools.call("report_mail_workflow",arguments:["report":try .encode(report)],bridgeDirectory:root),"no coverage at all")
        report.coverage=[.init(account:"gmail:a",searched:true,detail:"Inbox and Sent, all dates")]
        XCTAssertThrowsError(try MailWorkflowTools.call("report_mail_workflow",arguments:["report":try .encode(report)],bridgeDirectory:root)) { XCTAssertTrue("\($0)".contains("gmail:b")) }
        XCTAssertEqual(try MailTriageStore(bridgeDirectory:root).read().askList[0].state,.asked,"nothing was shown to the owner")
        report.coverage?.append(.init(account:"GMAIL:B",searched:false,detail:"The connector for this account is signed out."))
        _ = try MailWorkflowTools.call("report_mail_workflow",arguments:["report":try .encode(report)],bridgeDirectory:root)
        let answered=try MailTriageStore(bridgeDirectory:root).read().askList[0]
        XCTAssertEqual(answered.state,.answered)
        XCTAssertEqual(answered.coverage?.map(\.searched),[true,false])
        XCTAssertEqual(answered.coverage?.map(\.account),["gmail:a","gmail:b"])
        XCTAssertEqual(answered.coverage?[1].name,"owner@work.example.invalid")
        // A failure needs no coverage.
        XCTAssertTrue(AskDot.accountsMissing(from:nil,asked:[]).isEmpty)
    }
}

/// Ask Dot review, rank 5: Dot's sources arrive as fields of its report and are checked against Mail on this Mac.
final class AskCitationTests:XCTestCase {
    private let account="ACCOUNT-1"
    private var inbox:NativeMailbox { NativeMailbox(accountID:account,path:["INBOX"]) }
    private func indexed(_ root:URL,complete:Bool) throws -> (MailSearchIndex,[NativeMailGrant]) {
        let index=MailSearchIndex(bridgeDirectory:root)
        try index.add([IndexedMessage(account:account,mailbox:inbox.id,messageID:"<venue@example.invalid>",date:Date(timeIntervalSince1970:1_794_000_000),sender:"Priya Raman <priya@example.invalid>",
                                      recipients:["owner@example.invalid"],subject:"Venue for the spring meeting",sent:false,attachments:0,text:"We will use Harbor Hall.")])
        try index.setProgress(MailIndexProgress(newest:.now,gaps:complete ? [] : [.init(low:MailIndexPass.earliest,high:.now)]),account:account,mailbox:inbox.id)
        return (index,[NativeMailGrant(accountID:account,mailboxes:[inbox])])
    }
    func testAFoundSourceShowsMailsOwnDetailsAndAMissingOneIsMarkedOnlyWhenTheIndexIsComplete() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("cite-\(UUID().uuidString)",isDirectory:true); defer { try? FileManager.default.removeItem(at:root) }
        var (index,grants)=try indexed(root,complete:true)
        var wrong=AskDot.Source(n:1,sender:"Someone Else",subject:"A subject Dot made up",date:"2020-01-01T00:00:00Z",messageID:"venue@example.invalid",account:"mail:\(account)")
        wrong.checked=false
        let sources=[wrong,
                     AskDot.Source(n:2,sender:"Priya",subject:"Catering",messageID:"<invented@example.invalid>",account:"mail:\(account)"),
                     AskDot.Source(n:3,sender:"Priya",subject:"From Gmail",messageID:"<gm@example.invalid>",webURL:"https://mail.example.invalid/1",account:"gmail:a"),
                     AskDot.Source(n:4,sender:"Priya",subject:"No identity",account:"mail:\(account)")]
        var checked=AskDot.check(sources,grants:grants,index:index)
        XCTAssertEqual(checked[0].checked,true)
        XCTAssertEqual(checked[0].sender,"Priya Raman")
        XCTAssertEqual(checked[0].subject,"Venue for the spring meeting")
        XCTAssertEqual(checked[0].date,Date(timeIntervalSince1970:1_794_000_000).ISO8601Format())
        XCTAssertEqual(checked[1].checked,false,"all of the account's mail is indexed and this message is not in it")
        XCTAssertEqual(checked[1].subject,"Catering","what Dot wrote stays, with the mark")
        XCTAssertNil(checked[2].checked,"a Gmail message cannot be checked on this Mac")
        XCTAssertNil(checked[3].checked)
        // While older mail is still being indexed, absence proves nothing.
        try? FileManager.default.removeItem(at:root)
        (index,grants)=try indexed(root,complete:false)
        checked=AskDot.check(sources,grants:grants,index:index)
        XCTAssertEqual(checked.map(\.checked),[true,nil,nil,nil])
        // A withdrawn account answers for nothing.
        grants[0].revokedAt=Date()
        XCTAssertEqual(AskDot.check(sources,grants:grants,index:index).map(\.checked),[nil,nil,nil,nil])
        XCTAssertEqual(AskDot.senderName("\"Raman, Priya\" <priya@example.invalid>"),"Raman, Priya")
        XCTAssertEqual(AskDot.senderName("<priya@example.invalid>"),"priya@example.invalid")
    }
    func testSourcesGivenAsFieldsAreUsedAndTheSummaryLineStillWorks() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("cite-\(UUID().uuidString)",isDirectory:true); defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try MailSettingsStore(bridgeDirectory:root).transaction {
            var first=MailConnection(id:"a",email:"owner@example.invalid",connectionID:"link"); first.observedAt=Date()
            $0.connections=[first]
        }
        let (_,grants)=try indexed(root,complete:true)
        try NativeMailStore(bridgeDirectory:root).transaction { $0.grants=grants }
        func ask(_ report:(String) -> MailWorkflowReport) throws -> AskDot.Question {
            let request=try MailWorkflowRequest(action:.ask,accountIDs:["gmail:a"])
            try MailWorkflowStore(bridgeDirectory:root).transaction { try $0.enqueue(request,allowedAccountIDs:["gmail:a"]) }
            let id=try MailTriageStore(bridgeDirectory:root).transaction { state -> String in
                let question=try state.ask("Where is the spring meeting?",filters:nil); state.markAskSent(question.id,requestID:request.id); return question.id
            }
            _ = try MailWorkflowTools.call("get_mail_workflow",arguments:["request_id":.string(request.id)],bridgeDirectory:root)
            _ = try MailWorkflowTools.call("report_mail_workflow",arguments:["report":try .encode(report(request.id))],bridgeDirectory:root)
            return try XCTUnwrap(MailTriageStore(bridgeDirectory:root).read().askList.first{ $0.id == id })
        }
        // As fields: nothing of the sources is in the summary, and the message found in Mail shows Mail's details.
        var answered=try ask { id in
            var report=MailWorkflowReport(requestID:id,expectedRevision:0,stage:.ready,summary:"Harbor Hall [1].",items:[])
            report.coverage=[.init(account:"gmail:a",searched:true,detail:"All mail")]
            report.sources=[AskDot.Source(n:1,sender:"P.",subject:"venue",messageID:"<venue@example.invalid>",account:"gmail:a")]
            return report
        }
        XCTAssertEqual(answered.answer,"Harbor Hall [1].")
        XCTAssertEqual(answered.sources?.first?.subject,"Venue for the spring meeting")
        XCTAssertEqual(answered.sources?.first?.checked,true)
        XCTAssertNotNil(answered.sources?.first?.mailURL)
        // On the summary's Sources line, as before: still read, still checked.
        answered=try ask { id in
            var report=MailWorkflowReport(requestID:id,expectedRevision:0,stage:.ready,summary:"Harbor Hall [1].\nSources: [{\"n\":1,\"subject\":\"venue\",\"message_id\":\"venue@example.invalid\"}]",items:[])
            report.coverage=[.init(account:"gmail:a",searched:true,detail:"All mail")]
            return report
        }
        XCTAssertEqual(answered.answer,"Harbor Hall [1].")
        XCTAssertEqual(answered.sources?.map(\.sender),["Priya Raman"])
        let tools=MailWorkflowTools.catalog
        XCTAssertTrue(try XCTUnwrap(tools.first{ $0["name"].string == "report_mail_workflow" }).text().contains("message_id"))
        XCTAssertTrue(AskDot.instructions.contains("as a field of the report and not in the summary"))
    }
}
