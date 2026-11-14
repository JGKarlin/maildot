import XCTest
@testable import BridgeCore

/// Dot's thread report travels as one marked line in its summary (13 November 2026).
final class ThreadReportTests:XCTestCase {
    private let line=#"Thread report: {"now":"Waiting on you for the room.","origin":{"date":"2026-11-03","text":"A colleague asked the group to fix a date."},"decided":[{"item":"Date","value":"March 11","by":"All","date":"2026-11-11"}],"open":[{"item":"Budget","owner":"A colleague"},{"item":"Room","owner":"you","due":"2026-11-16","asked":true}],"meeting":{"title":"Planning call","start":"2026-11-19T10:00:00+09:00","end":"2026-11-19T10:45:00+09:00","platform":"Zoom","link":"https://example.invalid/j/1","availability":"free"},"answerNotes":["needs budget","within budget"]}"#

    func testTheReportIsReadAndTakenOutOfTheSummary() throws {
        let summary="The message asks which room to book.\n\(line)\nDraft reply: Dear colleague,\nThe larger room, please."
        let (report,rest)=ThreadReport.extract(from:summary)
        let value=try XCTUnwrap(report)
        XCTAssertEqual(value.now,"Waiting on you for the room.")
        XCTAssertEqual(value.open?.first?.item,"Room","The owner's matters come first")
        XCTAssertEqual(value.open?.first?.asked,true)
        XCTAssertEqual(value.meeting?.url?.host,"example.invalid")
        XCTAssertNotNil(value.meeting?.startDate)
        XCTAssertFalse(rest.lowercased().contains("thread report"))
        XCTAssertTrue(rest.contains("Draft reply:"))
    }
    func testTriageKeepsTheReportAndStillReadsTheDraft() {
        var state=MailTriageState()
        var entry=MailTriageEntry(messageID:"a@example.invalid",sender:"one@example.invalid",senderName:nil,subject:"Room",receivedAt:Date(),verdict:.init(essential:true,reason:"Direct"),automatic:true)
        entry.outcome = .asked; entry.requestID="r1"
        state.record(entry)
        state.accept(requestID:"r1",stage:.ready,summary:"Asks about the room.\n\(line)\nDraft reply: The larger room, please.")
        XCTAssertEqual(state.entries[0].outcome,.drafted)
        XCTAssertEqual(state.entries[0].draft,"The larger room, please.")
        XCTAssertEqual(state.entries[0].dotNote,"Asks about the room.")
        XCTAssertEqual(state.entries[0].report?.decided?.first?.value,"March 11")
        XCTAssertNotNil(state.entries[0].reportedAt)
    }
    func testABrokenOrMissingReportIsIgnored() {
        XCTAssertNil(ThreadReport.extract(from:"Thread report: {not json").report)
        XCTAssertNil(ThreadReport.extract(from:"Thread report: {}").report,"An empty report is no report")
        XCTAssertNil(ThreadReport.extract(from:"No reply needed: a notice.").report)
        // A meeting without a readable start is dropped, not shown with a wrong time.
        let report=ThreadReport.extract(from:#"Thread report: {"now":"Settled.","meeting":{"title":"Call","start":"sometime"}}"#).report
        XCTAssertEqual(report?.now,"Settled."); XCTAssertNil(report?.meeting)
    }
    func testTheOwnersOwnVerdictAndCalendarRequest() throws {
        var state=MailTriageState()
        var entry=MailTriageEntry(messageID:"b@example.invalid",sender:"one@example.invalid",senderName:nil,subject:"Room",receivedAt:Date(),verdict:.init(essential:true,reason:"Direct"),automatic:true)
        entry.outcome = .needsGuidance
        state.record(entry)
        let id=state.entries[0].id
        XCTAssertThrowsError(try state.requestCalendar(id),"No meeting, nothing to add")
        state.entries[0].report=ThreadReport.extract(from:line).report
        try state.requestCalendar(id)
        XCTAssertNotNil(state.entries[0].calendarRequestedAt)
        state.entries[0].report?.work=[ThreadReport.Work(text:"Calendar creation was refused; no event was created.",source:"calendar",state:"needsOwner"),ThreadReport.Work(text:"Read the thread.",source:"mail",state:"done")]
        state.noteCalendar(id,added:true,note:nil)
        XCTAssertEqual(state.entries[0].report?.work?.map(\.text),["Added the meeting to your calendar.","Read the thread."],"a stale refusal gives way to what happened")
        XCTAssertEqual(state.entries[0].calendarAdded,true); XCTAssertNil(state.entries[0].calendarRequestedAt)
        try state.markNoReplyNeeded(id)
        XCTAssertEqual(state.entries[0].outcome,.noDraft)
    }
    func testTheLayoutIsOptionalInSavedSettings() throws {
        let saved=try JSONEncoder().encode(MailSettings())
        XCTAssertNil(try JSONDecoder().decode(MailSettings.self,from:saved).windowLayout)
        var settings=MailSettings(); settings.windowLayout = .ledger
        XCTAssertEqual(try JSONDecoder().decode(MailSettings.self,from:JSONEncoder().encode(settings)).windowLayout,.ledger)
    }
    /// Dot has sent the JSON on a line of its own, and with the marker at the end of the line before.
    func testTheReportIsReadInTheFormsDotActuallySends() throws {
        let json=String(line.dropFirst("Thread report: ".count))
        for summary in ["No reply needed: a notice.\n\(json)","No reply needed: a notice. Thread report:\n\(json)","No reply needed: a notice. Thread report: \(json)"] {
            let (report,rest)=ThreadReport.extract(from:summary)
            XCTAssertEqual(report?.now,"Waiting on you for the room.",summary)
            XCTAssertEqual(rest,"No reply needed: a notice.",summary)
        }
        // A line that merely mentions braces is kept as text.
        XCTAssertEqual(ThreadReport.extract(from:"Use {name} in the reply.").rest,"Use {name} in the reply.")
        var state=MailTriageState()
        var entry=MailTriageEntry(messageID:"c@example.invalid",sender:"one@example.invalid",senderName:nil,subject:"Room",receivedAt:Date(),verdict:.init(essential:true,reason:"Direct"),automatic:true)
        entry.outcome = .noDraft; entry.dotNote="No reply needed: a notice.\n\(json)"
        state.record(entry)
        XCTAssertEqual(state.recoverReports(),1)
        XCTAssertEqual(state.entries[0].dotNote,"No reply needed: a notice.")
        XCTAssertNotNil(state.entries[0].report)
        XCTAssertEqual(state.recoverReports(),0)
    }
    func testAnAddedMeetingCorrectsDotsCalendarStatements() throws {
        var report=try XCTUnwrap(ThreadReport.extract(from:line).report)
        report.now="The meeting is confirmed for March 15, 4–5 pm; calendar creation was blocked pending explicit approval."
        report.work=[ThreadReport.Work(text:"Calendar creation was refused.",source:"calendar",state:"needsOwner")]
        let fixed=report.withMeetingAdded()
        XCTAssertEqual(fixed.now,"The meeting is confirmed for March 15, 4–5 pm.")
        XCTAssertEqual(fixed.meeting?.added,true)
        XCTAssertEqual(fixed.work?.map(\.text),["Added the meeting to your calendar."])
        // Dot's next answer about the message cannot bring the stale statement back.
        var state=MailTriageState()
        var entry=MailTriageEntry(messageID:"d@example.invalid",sender:"one@example.invalid",senderName:nil,subject:"Room",receivedAt:Date(),verdict:.init(essential:true,reason:"Direct"),automatic:true)
        entry.outcome = .asked; entry.requestID="r2"; entry.calendarAdded=true
        state.record(entry)
        state.accept(requestID:"r2",stage:.ready,summary:"No reply needed: an FYI.\nThread report: {\"now\":\"Confirmed; calendar creation was blocked.\",\"meeting\":{\"title\":\"Call\",\"start\":\"2027-03-15T16:00:00+09:00\"}}")
        XCTAssertEqual(state.entries[0].report?.now,"Confirmed.")
        XCTAssertEqual(state.entries[0].report?.meeting?.added,true)
    }
    /// Ask Dot for a Report: the report alone; the message's state, and any draft, are untouched (13 November 2026).
    func testAReportOnlyRequestKeepsTheMessageAsItWas() throws {
        var state=MailTriageState()
        var entry=MailTriageEntry(messageID:"e@example.invalid",sender:"me@example.invalid",senderName:nil,subject:"Fence",receivedAt:Date(),verdict:.init(essential:false,reason:"Sent by you."),automatic:true)
        entry.outcome = .skipped
        state.record(entry)
        let id=state.entries[0].id
        try state.requestReport(id)
        XCTAssertEqual(state.reportsDue().map(\.id),[id])
        state.markReportAsked(id,requestID:"r9")
        XCTAssertTrue(state.reportsDue().isEmpty)
        XCTAssertTrue(state.queueForDot().isEmpty,"a report request is not a request for a draft")
        state.accept(requestID:"r9",stage:.ready,summary:"A neighbour asked about the fence.\n\(line)")
        XCTAssertEqual(state.entries[0].outcome,.skipped)
        XCTAssertNil(state.entries[0].draft)
        XCTAssertNotNil(state.entries[0].report)
        XCTAssertFalse(state.entries[0].reportPending)
        // Dot not answering in time is said, and the owner can try again.
        try state.requestReport(id); state.markReportAsked(id,requestID:"r10")
        XCTAssertEqual(state.expireReportRequests(now:Date().addingTimeInterval(MailTriageState.answerLimit+60)),1)
        XCTAssertNotNil(state.entries[0].reportFailed)
        XCTAssertFalse(state.entries[0].reportPending)
    }
    func testDotIsAskedForTheReport() {
        XCTAssertTrue(MailWorkflowTools.draftCheckInstructions.contains("Thread report:"))
        XCTAssertTrue(MailWorkflowTools.draftCheckInstructions.contains("report_only"))
    }
}
