import Foundation

/// Dot's report on a message's thread: where it began, how it developed, what is decided, what is still to
/// decide, and any meeting it sets (owner request, 13 November 2026: the Mail Dot window shows "a report or
/// summary of the thread outlining its origin, development, and current status"). Dot sends it with its
/// answer about the message, as one line beginning `Thread report:` followed by JSON, read here and taken
/// out of the text shown elsewhere. Every field is optional; a report that cannot be read is ignored.
public struct ThreadReport:Codable,Sendable,Equatable {
    public struct Thread:Codable,Sendable,Equatable {
        public var messageCount:Int?
        public var participants:[String]?
        public var first:String?
        public var last:String?
    }
    public struct Dated:Codable,Sendable,Equatable {
        public var date:String?
        public var text:String
        public init(date:String?,text:String) { self.date=date; self.text=text }
    }
    public struct Development:Codable,Sendable,Equatable {
        public var from:String?
        public var to:String?
        public var text:String
    }
    public struct Decided:Codable,Sendable,Equatable {
        public var item:String
        public var value:String?
        public var by:String?
        public var date:String?
        public init(item:String,value:String?=nil,by:String?=nil,date:String?=nil) { self.item=item; self.value=value; self.by=by; self.date=date }
    }
    public struct Open:Codable,Sendable,Equatable {
        public var item:String
        /// "you", or the name of whoever decides it.
        public var owner:String?
        public var due:String?
        public var note:String?
        /// The matter Dot's question concerns.
        public var asked:Bool?
        public var isOwners:Bool { owner?.trimmingCharacters(in:.whitespaces).lowercased() == "you" }
    }
    public struct Meeting:Codable,Sendable,Equatable {
        public var title:String
        public var start:String
        public var end:String?
        public var platform:String?
        public var link:String?
        public var meetingID:String?
        public var passcode:String?
        public var location:String?
        /// "free", "busy" or "unknown", from Dot's look at the owner's calendar.
        public var availability:String?
        public var conflict:String?
        /// Dot has already put it in the owner's calendar.
        public var added:Bool?
        public var startDate:Date? { ThreadReport.date(start) }
        public var endDate:Date? { end.flatMap(ThreadReport.date) }
        /// A link that opens in a browser or meeting app, only http(s).
        public var url:URL? {
            guard let link,let url=URL(string:link.trimmingCharacters(in:.whitespaces)),["http","https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        }
    }
    public struct Work:Codable,Sendable,Equatable {
        public var text:String
        public var source:String?
        public var sourceLabel:String?
        /// "done" or "needsOwner".
        public var state:String?
        public init(text:String,source:String?=nil,sourceLabel:String?=nil,state:String?=nil) { self.text=text; self.source=source; self.sourceLabel=sourceLabel; self.state=state }
        public var needsOwner:Bool { state == "needsOwner" }
        /// The chip's words: Dot's own label, or the name of the source.
        public var chip:String? {
            if let sourceLabel,!sourceLabel.isEmpty { return sourceLabel }
            guard let source,let known=MailUpdateWorkSource(rawValue:source),known != .none else { return nil }
            return known.title
        }
    }
    public var thread:Thread?
    public var now:String?
    public var origin:Dated?
    public var development:Development?
    public var steps:[Dated]?
    public var thisMessage:Dated?
    public var decided:[Decided]?
    public var open:[Open]?
    public var next:String?
    public var questionContext:String?
    public var answerNotes:[String]?
    public var meeting:Meeting?
    public var work:[Work]?
    public var checkedAt:String?

    public init() {}

    /// The marker Dot writes before the JSON, in English whatever language the rest is in.
    public static let marker="thread report:"
    /// The longest report line read.
    public static let limit=6000

    /// The report in Dot's summary, if there is one, and the summary without it. Dot was asked for a line
    /// beginning "Thread report:"; it has also put the marker at the end of the line before, or sent the JSON
    /// on a line of its own with no marker (seen 13 November 2026), so a line that is a report's JSON is taken too.
    public static func extract(from summary:String) -> (report:ThreadReport?,rest:String) {
        var report:ThreadReport?
        var kept:[String]=[]
        for line in summary.split(omittingEmptySubsequences:false,whereSeparator:\.isNewline).map(String.init) {
            if let range=line.range(of:marker,options:.caseInsensitive) {
                let before=String(line[..<range.lowerBound]).trimmingCharacters(in:.whitespaces)
                let after=String(line[range.upperBound...]).trimmingCharacters(in:.whitespaces)
                if after.isEmpty || after.hasPrefix("{") {
                    if report == nil,!after.isEmpty { report=parse(after) }
                    if !before.isEmpty { kept.append(before) }
                    continue
                }
            }
            let trimmed=line.trimmingCharacters(in:.whitespaces)
            if trimmed.hasPrefix("{"),trimmed.hasSuffix("}"),let found=parse(trimmed) {
                if report == nil { report=found }
                continue
            }
            kept.append(line)
        }
        return (report,kept.joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines))
    }
    public static func parse(_ text:String) -> ThreadReport? {
        let json=text.trimmingCharacters(in:.whitespaces)
        guard json.utf8.count <= limit,json.hasPrefix("{"),let data=json.data(using:.utf8),
              var report=try? JSONDecoder().decode(ThreadReport.self,from:data) else { return nil }
        report.bound()
        return report.isEmpty ? nil : report
    }
    /// Lists and texts held to the sizes the window is laid out for.
    mutating func bound() {
        func cut(_ value:String?,_ length:Int) -> String? {
            guard let value=value?.trimmingCharacters(in:.whitespacesAndNewlines),!value.isEmpty else { return nil }
            return value.count > length ? String(value.prefix(length-1))+"…" : value
        }
        if let people=thread?.participants { thread?.participants=Array(people.prefix(8)) }
        now=cut(now,240)
        origin=origin.flatMap{ o in cut(o.text,360).map{Dated(date:o.date,text:$0)} }
        if let d=development,let text=cut(d.text,600) { development?.text=text } else { development=nil }
        steps=steps.map{ $0.prefix(6).compactMap{ s in cut(s.text,240).map{Dated(date:s.date,text:$0)} } }
        thisMessage=thisMessage.flatMap{ m in cut(m.text,360).map{Dated(date:m.date,text:$0)} }
        decided=decided.map{ Array($0.prefix(6)).filter{!$0.item.isEmpty} }
        // The owner's matters first, as Dot was asked; otherwise in Dot's order.
        open=open.map{ list in let items=Array(list.prefix(6)).filter{!$0.item.isEmpty}; return items.filter(\.isOwners)+items.filter{!$0.isOwners} }
        next=cut(next,240)
        questionContext=cut(questionContext,200)
        answerNotes=answerNotes.map{ $0.prefix(4).map{ cut($0,40) ?? "" } }
        work=work.map{ Array($0.prefix(8)).filter{!$0.text.isEmpty} }
        if meeting?.title.isEmpty == true || meeting?.startDate == nil { meeting=nil }
    }
    /// Whether a sentence is about putting something in a calendar.
    static func mentionsCalendar(_ text:String) -> Bool {
        let lower=text.lowercased()
        return ["calendar","カレンダー","予定表","日历","行事曆","캘린더"].contains{ lower.contains($0) }
    }
    /// The report once the owner has added its meeting to their calendar (owner report, 13 November 2026): the meeting
    /// is marked added, and Dot's statements about the calendar, in its summary and its work, give way to that fact.
    public func withMeetingAdded() -> ThreadReport {
        var report=self
        report.meeting?.added=true
        if let now {
            let clauses=now.components(separatedBy:CharacterSet(charactersIn:";；")).map{$0.trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty}
            let kept=clauses.filter{ !Self.mentionsCalendar($0) }
            report.now=kept.isEmpty ? nil : kept.joined(separator:"; ")+(kept.count < clauses.count && !(kept.last ?? "").hasSuffix(".") ? "." : "")
        }
        report.work=Self.replacingCalendarWork(work)
        return report
    }
    /// Dot's work, with its entries about the calendar replaced by one saying the meeting is in the owner's calendar.
    public static func replacingCalendarWork(_ work:[Work]?) -> [Work] {
        let others=(work ?? []).filter{ item in
            let text=item.text.lowercased()
            return item.source != "calendar" && !Self.mentionsCalendar(text)
        }
        return [Work(text:String(localized:"Added the meeting to your calendar."),source:"calendar",state:"done")]+others
    }
    public var isEmpty:Bool {
        now == nil && origin == nil && development == nil && (steps ?? []).isEmpty && thisMessage == nil
            && (decided ?? []).isEmpty && (open ?? []).isEmpty && meeting == nil && (work ?? []).isEmpty
    }

    /// A date or date-time as Dot writes it: ISO 8601 with or without a time and zone.
    public static func date(_ text:String) -> Date? {
        let value=text.trimmingCharacters(in:.whitespaces)
        for options:ISO8601DateFormatter.Options in [[.withInternetDateTime],[.withInternetDateTime,.withFractionalSeconds],[.withFullDate,.withTime,.withColonSeparatorInTime,.withDashSeparatorInDate]] {
            let formatter=ISO8601DateFormatter(); formatter.formatOptions=options
            if options.contains(.withFullDate) { formatter.timeZone = .current }
            if let date=formatter.date(from:value) { return date }
        }
        let day=ISO8601DateFormatter(); day.formatOptions=[.withFullDate,.withDashSeparatorInDate]; day.timeZone = .current
        return day.date(from:String(value.prefix(10)))
    }
    /// Whether the text names a time of day as well as a date.
    public static func hasTime(_ text:String) -> Bool { text.count > 10 && text.contains(":") }
}

/// What Dot is asked to send with every answer about a message, for the Mail Dot window.
public enum ThreadReportInstructions {
    public static let text="With every report about this message, whatever its stage (a draft, No reply needed, Already replied, or a question), add one more line to the summary that begins with the words Thread report: and continues on that same line with a single JSON object (no line breaks, at most 4000 characters) describing the message's thread for the owner's Mail Dot window. Write its texts in the owner's language named in these instructions, not the language of the message. State only what the thread or your own sources support; invent no decision, and if you could not read the whole thread say so in now. Every field is optional; omit what does not apply. Fields: thread {messageCount, participants (up to 8 names), first, last (dates)}, omitted for a single message; now (one sentence, at most 200 characters, on where the matter stands and what waits on whom); origin {date, text ≤300: how the thread began}; development {from, to, text ≤500: what happened between the origin and this message}, omitted for a single message; steps (0 to 6 of {date, text ≤200}: the same development as dated steps); thisMessage {date, text ≤300: what this message says or asks}; decided (0 to 6 of {item ≤40, value ≤80, by ≤60, date}: matters settled in the thread); open (0 to 6 of {item ≤40, owner: \"you\" or a name, due (date, optional), note ≤80, asked (true for the one matter your question concerns)}, the owner's first); next (≤200: what follows once the owner acts); questionContext (≤160: a fact from your own sources, such as Drive, the calendar or mail history, that bears on your question); answerNotes (up to 4 short consequences, ≤30 each, one per answer you offer, in order); meeting {title ≤80, start, end (date-times with time zone), platform ≤30, link (URL), meetingID, passcode, location, availability (free, busy or unknown, from your look at the owner's calendar), conflict ≤80, added (true only if you have already put it in the owner's calendar)} when the message sets or proposes a meeting; work (0 to 8 of {text ≤200, source (drive, calendar, mailHistory, mail, connector, schedule, dotChat), sourceLabel ≤24, state (done or needsOwner)}: what you did or checked, which replaces Done: lines); checkedAt (now, date-time). Dates are ISO 8601 (2026-11-03, or 2026-11-19T10:00:00+09:00). Mail Dot reads the marker Thread report: like the others, so write it exactly so, in English."
}

extension ThreadReport {
    /// The report with the owner's answer to Dot's question kept in it: the matter the question concerned moves from
    /// Still to decide to Decided, with the answer, until Dot's next report says it itself (owner decision, 16 November
    /// 2026: an answered question is recorded in the Mail Dot window).
    public func answered(_ answer:String?,question:String?,by you:String,on date:String?) -> ThreadReport {
        guard let answer=answer?.trimmingCharacters(in:.whitespacesAndNewlines),!answer.isEmpty else { return self }
        var value=self
        var open=value.open ?? []
        let asked=open.firstIndex{ $0.asked == true } ?? open.firstIndex(where:\.isOwners)
        let item=asked.map{ open[$0].item } ?? String((question ?? answer).prefix(40))
        if let asked { open.remove(at:asked) }
        var decided=value.decided ?? []
        if !decided.contains(where:{ $0.item == item }) { decided.append(Decided(item:item,value:String(answer.prefix(80)),by:you,date:date)) }
        value.open=open.isEmpty ? nil : open
        value.decided=decided
        return value
    }
}
