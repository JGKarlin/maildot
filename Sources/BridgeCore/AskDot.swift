import Foundation

/// Ask Dot (owner request, 14 November 2026): the owner puts a question about their mail to Dot, about the whole
/// account and not one message: to find a message, or to learn what their mail says about something. Dot does
/// the searching, with its own mail tools; nothing is searched on the Mac. Every statement in Dot's answer
/// cites the message it comes from, and each citation opens that message.
public enum AskDot {
    /// The time filter's periods. This list is the standard for every time filter in Mail Dot: the "last"
    /// periods count back from today; "this year" and "last year" are calendar years.
    public enum Period:String,Codable,Sendable,CaseIterable {
        case anyTime,today,yesterday,last7Days,last30Days,last3Months,last12Months,thisYear,lastYear,custom
        /// The span the period covers, or nil for any time. `custom` takes its dates from the filter.
        public func range(now:Date=Date(),calendar:Calendar = .current) -> (from:Date,to:Date)? {
            let startOfToday=calendar.startOfDay(for:now)
            func back(_ component:Calendar.Component,_ value:Int) -> Date { calendar.date(byAdding:component,value:-value,to:startOfToday) ?? startOfToday }
            switch self {
            case .anyTime,.custom: return nil
            case .today: return (startOfToday,now)
            case .yesterday: return (back(.day,1),startOfToday)
            case .last7Days: return (back(.day,7),now)
            case .last30Days: return (back(.day,30),now)
            case .last3Months: return (back(.month,3),now)
            case .last12Months: return (back(.month,12),now)
            case .thisYear:
                let start=calendar.date(from:calendar.dateComponents([.year],from:now)) ?? startOfToday
                return (start,now)
            case .lastYear:
                let thisYear=calendar.date(from:calendar.dateComponents([.year],from:now)) ?? startOfToday
                return (calendar.date(byAdding:.year,value:-1,to:thisYear) ?? thisYear,thisYear)
            }
        }
    }
    public enum Direction:String,Codable,Sendable,CaseIterable { case both,received,sent }
    /// What narrows the search, when the owner ticked Filters. Absent fields narrow nothing.
    public struct Filters:Codable,Sendable,Equatable {
        /// Mail Dot's account ids to search; nil for every account.
        public var accountIDs:[String]?
        /// The account's name, for the owner's record of the question.
        public var accountName:String?
        public var period:Period = .anyTime
        public var customFrom:Date?
        public var customTo:Date?
        public var direction:Direction = .both
        /// A person the mail was exchanged with: a name or an address, as the owner typed it.
        public var person:String?
        /// Only messages that carry attachments.
        public var hasAttachments:Bool?
        public init() {}
        public var isEmpty:Bool { accountIDs == nil && period == .anyTime && direction == .both && (person ?? "").isEmpty && hasAttachments != true }
        public func range(now:Date=Date(),calendar:Calendar = .current) -> (from:Date,to:Date)? {
            if period == .custom {
                guard let from=customFrom,let to=customTo else { return nil }
                let start=calendar.startOfDay(for:min(from,to))
                let end=calendar.date(byAdding:.day,value:1,to:calendar.startOfDay(for:max(from,to))) ?? max(from,to)
                return (start,end)
            }
            return period.range(now:now,calendar:calendar)
        }
    }
    /// One message Dot's answer rests on.
    public struct Source:Codable,Sendable,Equatable,Identifiable {
        public var n:Int
        public var sender:String?
        public var subject:String?
        public var date:String?
        public var messageID:String?
        public var webURL:String?
        public var id:Int { n }
        enum CodingKeys:String,CodingKey { case n,sender,subject,date,messageID="message_id",webURL="web_url" }
        /// The address that opens the message in Mail on this Mac.
        public var mailURL:URL? {
            guard let id=messageID.flatMap(MailMessageIdentity.normalized) else { return nil }
            var allowed=CharacterSet.urlPathAllowed; allowed.remove(charactersIn:"/?#%")
            return id.addingPercentEncoding(withAllowedCharacters:allowed).flatMap{ URL(string:"message://%3C\($0)%3E") }
        }
        /// The message on the web (Gmail), only https.
        public var webAddress:URL? {
            guard let webURL,let url=URL(string:webURL.trimmingCharacters(in:.whitespaces)),url.scheme?.lowercased() == "https" else { return nil }
            return url
        }
    }
    public enum State:String,Codable,Sendable { case waiting,asked,answered,failed }
    public struct Question:Codable,Sendable,Equatable,Identifiable {
        public var id=UUID().uuidString
        public var text:String
        public var filters:Filters?
        public var askedAt=Date()
        public var state:State = .waiting
        public var requestID:String?
        public var answer:String?
        public var sources:[Source]?
        public var failure:String?
        public var answeredAt:Date?
        /// Dot's answer (or its failure) arrived and has not been shown yet. Absent from questions saved by earlier
        /// builds, which count as read.
        public var unread:Bool?
        public init(text:String,filters:Filters?) { self.text=text; self.filters=filters }
    }
    public static let textLimit=2000
    public static let keep=20
    /// The marker Dot writes before the JSON list of its sources, in English whatever language the answer is in.
    public static let marker="sources:"

    /// Dot's answer and its sources, from its summary: the answer's text with [n] markers, then a line
    /// beginning Sources: followed by a JSON array (or that array on a line of its own).
    public static func parse(_ summary:String) -> (answer:String,sources:[Source]) {
        var sources:[Source]=[],kept:[String]=[]
        func decode(_ text:String) -> [Source]? {
            let json=text.trimmingCharacters(in:.whitespaces)
            guard json.hasPrefix("["),let data=json.data(using:.utf8) else { return nil }
            return try? JSONDecoder().decode([Source].self,from:data)
        }
        for line in summary.split(omittingEmptySubsequences:false,whereSeparator:\.isNewline).map(String.init) {
            let trimmed=line.trimmingCharacters(in:.whitespaces)
            if trimmed.lowercased().hasPrefix(marker),let found=decode(String(trimmed.dropFirst(marker.count))) { if sources.isEmpty { sources=found }; continue }
            if trimmed.hasPrefix("[{"),trimmed.hasSuffix("]"),let found=decode(trimmed) { if sources.isEmpty { sources=found }; continue }
            kept.append(line)
        }
        let bounded=Array(sources.filter{$0.n > 0}.sorted{$0.n < $1.n}.prefix(30))
        return (kept.joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines),bounded)
    }
    /// The citation numbers an answer uses, in order of first appearance: [1], [2, 3].
    public static func citations(in answer:String) -> [Int] {
        var seen:[Int]=[]
        guard let pattern=try? NSRegularExpression(pattern:"\\[(\\d{1,2}(?:\\s*,\\s*\\d{1,2})*)\\]") else { return [] }
        let text=answer as NSString
        for match in pattern.matches(in:answer,range:NSRange(location:0,length:text.length)) {
            for part in text.substring(with:match.range(at:1)).split(separator:",") {
                if let n=Int(part.trimmingCharacters(in:.whitespaces)),!seen.contains(n) { seen.append(n) }
            }
        }
        return seen
    }
    public static let instructions="For action ask, the owner put a question about their mail to you from Mail Dot's ask bar; question.text is the question. It concerns the whole of the accounts in this request, not one message: answer it by searching and reading their mail with your own mail tools (your Gmail connector, and Mail Dot's native_mail tools for accounts in Mail on the owner's Mac), as a semantic search of your own and not a keyword match. Honor question.filters when present: accounts limits the accounts, from and to (ISO 8601) limit the dates of the messages, direction is received (mail sent to the owner), sent (mail the owner sent) or both, person (a name or an address) limits the search to mail exchanged with that person, as sender or recipient, and has_attachments true limits it to messages with attachments. Do not draft, send, change or file anything, and do not ask the owner a question back: answer with what you find, or say plainly that you found nothing. Report ready with a summary that is the answer itself, concise, in the owner's language named in these instructions, as plain text without Markdown. Every fact taken from mail MUST carry a citation marker such as [1] or [2] right after it, numbered from 1 in order of first use. After the answer add one line that begins with the words Sources: and continues on that same line with a single JSON array, one object per cited message: n (the citation number), sender (name), subject, date (ISO 8601), message_id (the message's RFC 822 Message-ID header, exactly, which Mail Dot needs to open the message on the Mac) and, for a Gmail message, web_url (its https link in Gmail). If you cannot give a message for a statement, write (no source found) after it instead of a marker. Cite at most 30 messages. If the search cannot be done, report failed with one sentence on why."
}

extension MailTriageState {
    /// The owner's questions to Dot, newest last.
    public var askList:[AskDot.Question] { asks ?? [] }
    @discardableResult public mutating func ask(_ text:String,filters:AskDot.Filters?) throws -> AskDot.Question {
        let words=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !words.isEmpty,words.count <= AskDot.textLimit else { throw BridgeFailure("Write a question of at most \(AskDot.textLimit) characters.") }
        let question=AskDot.Question(text:words,filters:filters.flatMap{$0.isEmpty ? nil : $0})
        var list=asks ?? []
        list.append(question)
        if list.count > AskDot.keep { list.removeFirst(list.count-AskDot.keep) }
        asks=list
        return question
    }
    /// Questions not yet sent to Dot.
    public func asksDue() -> [AskDot.Question] { askList.filter{ $0.state == .waiting } }
    public mutating func markAskSent(_ id:String,requestID:String) {
        guard let index=asks?.firstIndex(where:{$0.id == id}) else { return }
        asks?[index].state = .asked; asks?[index].requestID=requestID
    }
    public mutating func failAsk(_ id:String,_ reason:String,now:Date=Date()) {
        guard let index=asks?.firstIndex(where:{$0.id == id}) else { return }
        asks?[index].state = .failed; asks?[index].failure=reason; asks?[index].answeredAt=now; asks?[index].unread=true
    }
    /// Dot's answer to a question. Returns whether the request was a question's.
    @discardableResult public mutating func acceptAsk(requestID:String,stage:MailWorkflowStage,summary:String,now:Date=Date()) -> Bool {
        guard let index=asks?.firstIndex(where:{$0.requestID == requestID}) else { return false }
        switch stage {
        case .ready:
            let (answer,sources)=AskDot.parse(summary)
            asks?[index].answer=answer; asks?[index].sources=sources; asks?[index].state = .answered; asks?[index].answeredAt=now; asks?[index].unread=true
        case .failed,.awaitingInput:
            asks?[index].state = .failed; asks?[index].failure=summary.trimmingCharacters(in:.whitespacesAndNewlines); asks?[index].answeredAt=now; asks?[index].unread=true
        default: break
        }
        return true
    }
    /// A question Dot has not answered within the answer limit is given up, and can be asked again.
    @discardableResult public mutating func expireAsks(now:Date=Date()) -> Int {
        var count=0
        for index in (asks ?? []).indices where asks?[index].state == .asked && now.timeIntervalSince(asks?[index].askedAt ?? now) > Self.answerLimit {
            asks?[index].state = .failed; asks?[index].failure="Dot did not answer within 15 minutes."; asks?[index].answeredAt=now; asks?[index].unread=true
            count += 1
        }
        return count
    }
    public mutating func removeAsk(_ id:String) { asks?.removeAll{$0.id == id} }
    /// The owner has seen these answers. Returns whether any was unread.
    @discardableResult public mutating func markAsksRead(_ ids:Set<String>) -> Bool {
        var changed=false
        for index in (asks ?? []).indices where asks?[index].unread == true && ids.contains(asks?[index].id ?? "") { asks?[index].unread=nil; changed=true }
        return changed
    }
    /// Clear in the bar's History: every question kept is forgotten.
    public mutating func clearAsks() { asks=nil }
}

extension MailTriageState {
    /// People to suggest in Ask Dot's From or to field as the owner types (owner request, 14 November 2026): those
    /// Mail Dot has seen write to the owner, and those the owner has written to, by name and address. Nothing
    /// is read from Contacts. Best matches first: a name or address that begins with the text, then one
    /// containing it, the most recent first.
    public func peopleMatching(_ text:String,limit:Int=6) -> [(name:String?,address:String)] {
        let wanted=text.trimmingCharacters(in:.whitespaces).lowercased()
        guard wanted.count >= 1 else { return [] }
        var seen=Set<String>(),people:[(name:String?,address:String,recent:Date)]=[]
        for entry in entries.reversed() where !seen.contains(entry.sender) {
            seen.insert(entry.sender); people.append((entry.senderName,entry.sender,entry.receivedAt ?? entry.seenAt))
        }
        for address in correspondents.reversed() where !seen.contains(address) { seen.insert(address); people.append((nil,address,.distantPast)) }
        func rank(_ person:(name:String?,address:String,recent:Date)) -> Int? {
            let name=(person.name ?? "").lowercased(),address=person.address
            if name.hasPrefix(wanted) || address.hasPrefix(wanted) || name.split(separator:" ").contains(where:{$0.hasPrefix(wanted)}) { return 0 }
            if name.contains(wanted) || address.contains(wanted) { return 1 }
            return nil
        }
        return people.compactMap{ person in rank(person).map{($0,person)} }
            .sorted{ $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.recent > $1.1.recent }
            .prefix(limit).map{ ($0.1.name,$0.1.address) }
    }
}
