import AppKit
import EventKit
import BridgeCore

/// Add to Calendar, done by the background app (owner request, 13 November 2026): the meeting in Dot's report goes
/// into the owner's own calendar, with its link, meeting ID and passcode in the notes. It never accepts or
/// declines an invitation and notifies no one. Mail Dot asks only to add events, never to read the calendar;
/// if the owner refuses that, the meeting is opened in Calendar as a file for them to add.
@MainActor enum MeetingCalendar {
    private static var working=Set<String>()
    static func addRequested(_ store:MailTriageStore) async {
        guard let state=try? store.read() else { return }
        for entry in state.entries where entry.calendarRequestedAt != nil && !working.contains(entry.id) {
            guard let meeting=entry.report?.meeting else { try? store.transaction { $0.noteCalendar(entry.id,added:false,note:nil) }; continue }
            working.insert(entry.id); defer { working.remove(entry.id) }
            let (added,note)=await add(meeting,subject:entry.subject)
            try? store.transaction { $0.noteCalendar(entry.id,added:added,note:note) }
        }
    }
    private static func add(_ meeting:ThreadReport.Meeting,subject:String) async -> (Bool,String?) {
        guard let start=meeting.startDate else { return (false,String(localized:"Dot’s report gives no time Mail Dot can read for this meeting.")) }
        let end=meeting.endDate ?? start.addingTimeInterval(3600)
        let store=EKEventStore()
        let granted=(try? await store.requestWriteOnlyAccessToEvents()) ?? false
        if granted,let calendar=store.defaultCalendarForNewEvents {
            let event=EKEvent(eventStore:store)
            event.calendar=calendar; event.title=meeting.title; event.startDate=start; event.endDate=end
            event.location=meeting.location ?? meeting.url?.absoluteString
            event.url=meeting.url; event.notes=notes(meeting,subject:subject)
            do { try store.save(event,span:.thisEvent); return (true,nil) }
            catch { return (false,String(localized:"Calendar did not add the meeting: \(error.localizedDescription)")) }
        }
        // Without permission: Calendar opens the meeting for the owner to add with one press.
        if openFile(meeting,start:start,end:end,subject:subject) { return (true,String(localized:"Mail Dot may not add events, so the meeting opened in Calendar for you to add.")) }
        return (false,String(localized:"Mail Dot may not add events to your calendar. Allow it in System Settings, Privacy & Security, Calendars."))
    }
    private static func notes(_ meeting:ThreadReport.Meeting,subject:String) -> String {
        [meeting.platform,meeting.url?.absoluteString,meeting.meetingID.map{String(localized:"Meeting ID: \($0)")},meeting.passcode.map{String(localized:"Passcode: \($0)")},
         String(localized:"From the message: \(subject)")].compactMap{$0}.joined(separator:"\n")
    }
    private static func openFile(_ meeting:ThreadReport.Meeting,start:Date,end:Date,subject:String) -> Bool {
        func stamp(_ date:Date) -> String { let f=ISO8601DateFormatter(); f.formatOptions=[.withYear,.withMonth,.withDay,.withTime,.withTimeZone]; f.timeZone=TimeZone(identifier:"UTC"); return f.string(from:date).replacingOccurrences(of:"-",with:"").replacingOccurrences(of:":",with:"") }
        func escape(_ text:String) -> String { text.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:";",with:"\\;").replacingOccurrences(of:",",with:"\\,").replacingOccurrences(of:"\n",with:"\\n") }
        var lines=["BEGIN:VCALENDAR","VERSION:2.0","PRODID:-//Mail Dot//EN","BEGIN:VEVENT","UID:\(UUID().uuidString)","DTSTAMP:\(stamp(.now))","DTSTART:\(stamp(start))","DTEND:\(stamp(end))","SUMMARY:\(escape(meeting.title))","DESCRIPTION:\(escape(notes(meeting,subject:subject)))"]
        if let location=meeting.location ?? meeting.url?.absoluteString { lines.append("LOCATION:\(escape(location))") }
        if let url=meeting.url { lines.append("URL:\(url.absoluteString)") }
        lines += ["END:VEVENT","END:VCALENDAR"]
        let file=FileManager.default.temporaryDirectory.appendingPathComponent("Mail Dot meeting \(UUID().uuidString.prefix(8)).ics")
        guard (try? lines.joined(separator:"\r\n").write(to:file,atomically:true,encoding:.utf8)) != nil,
              let calendar=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.iCal") else { return false }
        NSWorkspace.shared.open([file],withApplicationAt:calendar,configuration:NSWorkspace.OpenConfiguration()) { _,_ in }
        return true
    }
}
