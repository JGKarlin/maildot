import Foundation

// The structured fields of an update, as docs/updates-workbench-spec.md names them. All are optional on
// `ScheduledMailUpdate`, so an update from before build 71 still validates and displays. A report describes;
// nothing in it grants authority to send, delete or mark anything reviewed.

/// Where a matter stands, as the Updates workbench groups it. The order is the order shown.
public enum MailUpdateStatus:String,Codable,Sendable,CaseIterable {
    case awaitingInstruction,draftedQueued,draftedSent,information
    public var title:String {
        switch self {
        case .awaitingInstruction:"Awaiting instruction"
        case .draftedQueued:"Drafted and queued"
        case .draftedSent:"Drafted and sent"
        case .information:"For information"
        }
    }
}

/// What choosing an option leads to. It decides which control the owner is offered next.
public enum MailUpdateEffect:String,Codable,Sendable {
    case draftReply,answer,sendAsDrafted,resolve,close,ignore,delete,discuss
}

public struct MailUpdateOption:Codable,Sendable,Equatable,Identifiable {
    public var id:String
    public var label:String
    public var detail:String
    public var effect:MailUpdateEffect
    /// The reply Dot would write if this option is chosen, when it can say so in advance.
    public var replyPreview:String?
    public init(id:String,label:String,detail:String,effect:MailUpdateEffect,replyPreview:String?=nil) {
        self.id=id; self.label=label; self.detail=detail; self.effect=effect; self.replyPreview=replyPreview
    }
}

public struct MailUpdateDecision:Codable,Sendable,Equatable {
    /// `decision`: the owner chooses a course. `question`: Dot asks what it could not resolve itself.
    public enum Kind:String,Codable,Sendable { case decision,question }
    public var kind:Kind
    public var question:String
    public var options:[MailUpdateOption]
    /// The `id` of the option Dot recommends, if it recommends one.
    public var recommended:String?
    public init(kind:Kind = .decision,question:String,options:[MailUpdateOption],recommended:String?=nil) {
        self.kind=kind; self.question=question; self.options=options; self.recommended=recommended
    }
}

public enum MailUpdateWorkState:String,Codable,Sendable { case done,inProgress,needsOwner }
public enum MailUpdateWorkSource:String,Codable,Sendable {
    case drive,calendar,mailHistory,mail,connector,schedule,dotChat,none
    public var title:String {
        switch self {
        case .drive:"Drive"
        case .calendar:"Calendar"
        case .mailHistory:"Mail history"
        case .mail:"Mail"
        case .connector:"Connector"
        case .schedule:"Schedule"
        case .dotChat:"Dot chat"
        case .none:"No access"
        }
    }
}
/// One thing Dot did, is doing, or judged necessary and could not do, beyond drafting.
public struct MailUpdateWork:Codable,Sendable,Equatable {
    public var state:MailUpdateWorkState
    public var text:String
    public var source:MailUpdateWorkSource
    public var sourceLabel:String?
    public init(state:MailUpdateWorkState,text:String,source:MailUpdateWorkSource,sourceLabel:String?=nil) {
        self.state=state; self.text=text; self.source=source; self.sourceLabel=sourceLabel
    }
    public var sourceTitle:String { sourceLabel ?? source.title }
}
public struct MailUpdateTag:Codable,Sendable,Equatable {
    public var state:MailUpdateWorkState
    public var label:String
    public init(state:MailUpdateWorkState,label:String) { self.state=state; self.label=label }
}
/// The reply Dot has drafted. An association only: it grants no send authority and proves no live Mail draft.
public struct MailUpdateDraft:Codable,Sendable,Equatable {
    /// The shared message (reply context) the draft belongs to, when there is one.
    public var reference:String?
    public var delivery:ProposalDelivery
    public var to:[String]
    public var preview:String
    public var attachments:[String]
    /// The complete reply, when Dot wrote it ahead of being asked. The reply alone, without quoted mail.
    public var text:String?
    public static let textLimit=16_384
    public init(reference:String?=nil,delivery:ProposalDelivery,to:[String],preview:String,attachments:[String]=[],text:String?=nil) {
        self.reference=reference; self.delivery=delivery; self.to=to; self.preview=preview; self.attachments=attachments; self.text=text
    }
    private enum CodingKeys:String,CodingKey { case reference,delivery,to,preview,attachments,text }
    public init(from decoder:Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        reference=try values.decodeIfPresent(String.self,forKey:.reference)
        delivery=try values.decode(ProposalDelivery.self,forKey:.delivery)
        to=try values.decode([String].self,forKey:.to)
        preview=try values.decode(String.self,forKey:.preview)
        attachments=try values.decodeIfPresent([String].self,forKey:.attachments) ?? []
        text=try values.decodeIfPresent(String.self,forKey:.text)
    }
}
/// The message the update concerns.
public struct MailUpdateMessage:Codable,Sendable,Equatable {
    public var sender:String
    public var subject:String?
    public var receivedAt:Date?
    /// The message's own Message-ID header. It is how Mail Dot recognises, inside Mail, the message a
    /// report is about, so that the report can be shown on that message.
    public var messageID:String?
    public init(sender:String,subject:String?=nil,receivedAt:Date?=nil,messageID:String?=nil) { self.sender=sender; self.subject=subject; self.receivedAt=receivedAt; self.messageID=messageID }
}

/// Recognising, inside Mail, the message a report from Dot concerns. Mail hands the extension a message's
/// raw data as it is displayed. The exact link to Dot's report is the Message-ID header; where Dot cannot
/// read that header (its Gmail connector gives it Gmail's own identifiers instead), the message is known by
/// its sender, its subject and its time.
public enum MailMessageIdentity {
    /// A Message-ID without its angle brackets or surrounding space, or nil if nothing is left.
    public static func normalized(_ value:String) -> String? {
        let trimmed=value.trimmingCharacters(in:CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:"<>")))
        return trimmed.isEmpty || trimmed.contains(where:{$0.isWhitespace}) || !trimmed.contains("@") ? nil : trimmed
    }
    /// The Message-ID from a message's raw RFC 822 data.
    public static func messageID(inRawMessage data:Data) -> String? { MailMessageHeaders(rawMessage:data).messageID }
    /// A subject as it is compared: without reply and forward prefixes, in one case, with single spaces.
    public static func comparable(subject:String) -> String {
        var text=subject.precomposedStringWithCompatibilityMapping.lowercased().split(whereSeparator:\.isWhitespace).joined(separator:" ")
        let prefixes=["re:","fwd:","fw:","aw:","返信:","転送:"]
        while let prefix=prefixes.first(where:{text.hasPrefix($0)}) { text=String(text.dropFirst(prefix.count)).trimmingCharacters(in:.whitespaces) }
        return text
    }
    /// The address in a sender given as "Name <address>" or as an address alone, in lower case.
    public static func address(in sender:String) -> String? {
        let inner=sender.lastIndex(of:"<").flatMap{open in sender[open...].firstIndex(of:">").map{String(sender[sender.index(after:open)..<$0])}}
        let candidate=(inner ?? sender.split(whereSeparator:\.isWhitespace).first{$0.contains("@")}.map(String.init) ?? "").trimmingCharacters(in:CharacterSet(charactersIn:"<>\"',;").union(.whitespaces))
        return candidate.contains("@") && !candidate.contains(where:{$0.isWhitespace}) ? candidate.lowercased() : nil
    }
    /// How far the time Dot gives may lie from the message's own Date header: clocks and time zones differ,
    /// but the same subject from the same sender days later is another message.
    public static let timeTolerance:TimeInterval=36*3600
}

/// The few headers by which a displayed message is recognised.
public struct MailMessageHeaders:Sendable,Equatable {
    public var messageID:String?
    public var senderAddress:String?
    public var senderName:String?
    public var subject:String?
    public var date:Date?
    /// The Message-ID of the message this one answers, from its In-Reply-To header.
    public var inReplyTo:String?
    public init(messageID:String?=nil,senderAddress:String?=nil,senderName:String?=nil,subject:String?=nil,date:Date?=nil) {
        self.messageID=messageID.flatMap(MailMessageIdentity.normalized); self.senderAddress=senderAddress?.lowercased(); self.senderName=senderName; self.subject=subject; self.date=date
    }
    /// Reads the header block of a message's raw RFC 822 data: only as far as the first empty line, and only
    /// within the first 64 KiB, so a large body costs nothing and a body line that looks like a header is not one.
    public init(rawMessage data:Data) {
        let head=data.prefix(65_536)
        var found:[String:String]=[:],name:String?
        if let text=String(data:head,encoding:.utf8) ?? String(data:head,encoding:.isoLatin1) {
            for line in text.split(omittingEmptySubsequences:false,whereSeparator:\.isNewline) {
                if line.isEmpty { break }
                // A header continues on lines that begin with space or tab.
                if line.first == " " || line.first == "\t" { if let name { found[name,default:""] += line }; continue }
                name=nil
                guard let colon=line.firstIndex(of:":") else { continue }
                let key=line[..<colon].lowercased()
                guard ["message-id","from","subject","date","in-reply-to"].contains(key),found[key] == nil else { continue }
                found[key]=String(line[line.index(after:colon)...]); name=key
            }
        }
        messageID=found["message-id"].flatMap(MailMessageIdentity.normalized)
        let from=found["from"].map(Self.decoded)
        senderAddress=from.flatMap(MailMessageIdentity.address)
        senderName=from.flatMap { text -> String? in
            guard let open=text.lastIndex(of:"<") else { return nil }
            let name=text[..<open].trimmingCharacters(in:CharacterSet(charactersIn:"\"").union(.whitespaces))
            return name.isEmpty ? nil : name
        }
        subject=found["subject"].map{Self.decoded($0).trimmingCharacters(in:.whitespaces)}
        date=found["date"].flatMap(Self.date)
        inReplyTo=found["in-reply-to"].flatMap(Self.firstMessageID)
    }
    /// The first Message-ID in a header such as In-Reply-To: the first one in angle brackets, or the whole value.
    public static func firstMessageID(_ value:String) -> String? {
        if let open=value.firstIndex(of:"<"),let close=value[open...].firstIndex(of:">") {
            return MailMessageIdentity.normalized(String(value[value.index(after:open)..<close]))
        }
        return MailMessageIdentity.normalized(value)
    }
    /// Decodes RFC 2047 encoded words, such as =?UTF-8?B?…?=, which is how mail carries any header text
    /// that is not plain ASCII. Neighbouring words in one character set are joined before decoding, because
    /// senders divide a character between them.
    public static func decoded(_ header:String) -> String {
        guard header.contains("=?"),let pattern=try? NSRegularExpression(pattern:"=\\?([^?\\s]+)\\?([bBqQ])\\?([^?\\s]*)\\?=") else { return header }
        let text=header as NSString
        var result="",position=0,run:(charset:String,bytes:Data)?
        func flush() {
            guard let pending=run else { return }
            let encoding=CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(pending.charset as CFString))
            result += String(data:pending.bytes,encoding:String.Encoding(rawValue:encoding)) ?? String(decoding:pending.bytes,as:UTF8.self)
            run=nil
        }
        for match in pattern.matches(in:header,range:NSRange(location:0,length:text.length)) {
            let between=text.substring(with:NSRange(location:position,length:match.range.location-position))
            // Space between two encoded words belongs to neither.
            if !(run != nil && between.allSatisfy(\.isWhitespace)) { flush(); result += between }
            let charset=text.substring(with:match.range(at:1)).split(separator:"*").first.map{$0.lowercased()} ?? "utf-8"
            let payload=text.substring(with:match.range(at:3))
            var bytes=Data()
            if text.substring(with:match.range(at:2)).lowercased() == "b" { bytes=Data(base64Encoded:payload,options:.ignoreUnknownCharacters) ?? Data() }
            else {
                var scalars=Array(payload.utf8)[...]
                while let byte=scalars.first {
                    scalars=scalars.dropFirst()
                    if byte == UInt8(ascii:"_") { bytes.append(0x20) }
                    else if byte == UInt8(ascii:"="),scalars.count >= 2,let value=UInt8(String(decoding:scalars.prefix(2),as:UTF8.self),radix:16) { bytes.append(value); scalars=scalars.dropFirst(2) }
                    else { bytes.append(byte) }
                }
            }
            if let pending=run,pending.charset == charset { run=(charset,pending.bytes+bytes) } else { flush(); run=(charset,bytes) }
            position=match.range.location+match.range.length
        }
        flush()
        return result+text.substring(from:position)
    }
    static func date(_ header:String) -> Date? {
        // A trailing comment such as (JST) is not part of the date.
        let bare=(header.firstIndex(of:"(").map{String(header[..<$0])} ?? header).trimmingCharacters(in:.whitespaces)
        let formatter=DateFormatter()
        formatter.locale=Locale(identifier:"en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z","d MMM yyyy HH:mm:ss Z","EEE, d MMM yyyy HH:mm Z","d MMM yyyy HH:mm Z"] {
            formatter.dateFormat=format
            if let date=formatter.date(from:bare) { return date }
        }
        return nil
    }
}

extension ScheduledMailUpdate {
    /// Every Message-ID this update names: in `message.messageID`, and among `sourceIDs`, where Dot is asked
    /// to put it too so that it travels even through an older copy of the tool list.
    public var messageIDs:Set<String> {
        Set(([message?.messageID].compactMap{$0}+sourceIDs).compactMap(MailMessageIdentity.normalized))
    }
    /// The sender and subject by which the message is known when no Message-ID is given: from `message`,
    /// or from a source written as "from <address> subject <subject>", which an older tool list can carry.
    var messageKeys:[(sender:String,subject:String,receivedAt:Date?)] {
        var keys:[(String,String,Date?)]=[]
        if let message,let subject=message.subject { keys.append((message.sender,subject,message.receivedAt)) }
        for source in sourceIDs where source.lowercased().hasPrefix("from ") {
            guard let mark=source.range(of:" subject ",options:.caseInsensitive) else { continue }
            keys.append((String(source[source.index(source.startIndex,offsetBy:5)..<mark.lowerBound]),String(source[mark.upperBound...]),nil))
        }
        return keys
    }
    /// Whether this update is about the message with these headers. An update that names a Message-ID is
    /// about that message alone; otherwise the sender and the subject must agree, and the time when both give one.
    public func concerns(_ headers:MailMessageHeaders) -> Bool {
        let named=messageIDs
        if !named.isEmpty { return headers.messageID.map(named.contains) ?? false }
        guard let subject=headers.subject.map(MailMessageIdentity.comparable),!subject.isEmpty else { return false }
        return messageKeys.contains { key in
            guard MailMessageIdentity.comparable(subject:key.subject) == subject else { return false }
            if let address=MailMessageIdentity.address(in:key.sender) { guard address == headers.senderAddress else { return false } }
            else { guard let name=headers.senderName,name.compare(key.sender.trimmingCharacters(in:.whitespaces),options:[.caseInsensitive,.widthInsensitive]) == .orderedSame else { return false } }
            if let reported=key.receivedAt,let shown=headers.date { return abs(reported.timeIntervalSince(shown)) <= MailMessageIdentity.timeTolerance }
            return true
        }
    }
}
extension ScheduledMailUpdateState {
    /// The newest report, not dismissed by the owner, about the message with this Message-ID.
    public func record(forMessageID id:String) -> ScheduledMailUpdateRecord? { record(for:MailMessageHeaders(messageID:id)) }
    /// The newest report, not dismissed by the owner, about the message with these headers.
    public func record(for headers:MailMessageHeaders) -> ScheduledMailUpdateRecord? {
        records.filter{!$0.dismissedByOwner && $0.update.concerns(headers)}.max{$0.sequence < $1.sequence}
    }
}

extension ScheduledMailUpdateState {
    /// The reply Dot wrote ahead for the message a reply in Mail answers, found by that message's identity.
    public func preparedReply(forReplyTo context:ReplyContext) -> (text:String,writtenAt:Date)? {
        let headers=MailMessageHeaders(messageID:context.originalMessageID,senderAddress:MailMessageIdentity.address(in:context.originalSender),
                                       senderName:nil,subject:context.originalSubject.isEmpty ? nil : context.originalSubject,date:nil)
        guard headers.messageID != nil || (headers.senderAddress != nil && headers.subject != nil),
              let record=record(for:headers),let text=record.update.preparedReply else { return nil }
        return (text,record.update.checkedAt)
    }
}

/// Dot's reports as the owner goes through them in Mail: grouped by where each stands, in the order shown,
/// without those the owner has ignored or closed.
public struct MailUpdateQueue:Sendable {
    public struct Group:Sendable { public let status:MailUpdateStatus; public let records:[ScheduledMailUpdateRecord] }
    public let groups:[Group]
    public init(_ state:ScheduledMailUpdateState,sentReferences:Set<String>=[]) {
        let open=state.records.filter{!$0.dismissedByOwner}.sorted{$0.sequence > $1.sequence}
        let placed=Dictionary(grouping:open){MailUpdatePresentation($0.update,sentReferences:sentReferences).status}
        groups=MailUpdateStatus.allCases.compactMap{status in placed[status].map{Group(status:status,records:$0)}}
    }
    public var records:[ScheduledMailUpdateRecord] { groups.flatMap(\.records) }
    public func count(_ status:MailUpdateStatus) -> Int { groups.first{$0.status == status}?.records.count ?? 0 }
    /// The report after this one in the order shown, coming round to the first; with nil, the first.
    public func next(after id:String?) -> ScheduledMailUpdateRecord? {
        let all=records
        guard let index=all.firstIndex(where:{$0.id == id}) else { return all.first }
        return all.isEmpty ? nil : all[(index+1)%all.count]
    }
}

extension ScheduledMailUpdate {
    /// The line after which an older copy of Dot's tool list carries a reply it wrote ahead, in actionText.
    static let draftMarker="draft reply:"
    private var markedReply:(before:String,reply:String)? {
        let lines=actionText.split(omittingEmptySubsequences:false,whereSeparator:\.isNewline)
        guard let index=lines.firstIndex(where:{$0.trimmingCharacters(in:.whitespaces).lowercased().hasPrefix(Self.draftMarker)}) else { return nil }
        let first=String(lines[index].trimmingCharacters(in:.whitespaces).dropFirst(Self.draftMarker.count))
        let reply=([first]+lines[(index+1)...].map(String.init)).joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines)
        return reply.isEmpty ? nil : (lines[..<index].joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines),reply)
    }
    /// The complete reply Dot wrote ahead for this message, if it wrote one: in the draft field, or, through
    /// an older tool list, after a "Draft reply:" line in actionText. A preview that was cut short is not one.
    public var preparedReply:String? {
        if let text=draft?.text?.trimmingCharacters(in:.whitespacesAndNewlines),!text.isEmpty { return text }
        if let marked=markedReply { return marked.reply }
        if let preview=draft?.preview.trimmingCharacters(in:.whitespacesAndNewlines),!preview.isEmpty,!preview.hasSuffix("…"),!preview.hasSuffix("...") { return preview }
        return nil
    }
    /// What Dot says is needed, without a reply carried after it.
    public var actionTextShown:String { markedReply?.before ?? actionText }
    /// Whether Dot reported any of the structured fields.
    public var isStructured:Bool {
        message != nil || gist != nil || summaryPoints != nil || unverified != nil || status != nil || decision != nil || work != nil || tags != nil || draft != nil
    }
    func validateStructure() throws {
        func text(_ value:String,_ limit:Int)->Bool { !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && value.utf8.count <= limit }
        func fail(_ what:String) -> BridgeFailure { BridgeFailure("Invalid scheduled update: \(what).") }
        if let message {
            guard text(message.sender,256),message.subject.map({text($0,512)}) ?? true,message.receivedAt.map({$0.timeIntervalSince1970.isFinite}) ?? true,
                  message.messageID.map({MailMessageIdentity.normalized($0) != nil && $0.utf8.count <= 998}) ?? true else { throw fail("message needs a sender of at most 256 bytes, a subject of at most 512, and messageID, when given, must be the Message-ID header value") }
        }
        if let gist { guard text(gist,240) else { throw fail("gist is one sentence of at most 240 bytes") } }
        if let summaryPoints { guard (1...6).contains(summaryPoints.count),summaryPoints.allSatisfy({text($0,600)}) else { throw fail("summaryPoints holds one to six statements of at most 600 bytes") } }
        if let unverified { guard unverified.count <= 6,unverified.allSatisfy({text($0,300)}) else { throw fail("unverified holds at most six entries of at most 300 bytes") } }
        if let work { guard work.count <= 20,work.allSatisfy({text($0.text,300) && ($0.sourceLabel.map{text($0,64)} ?? true)}) else { throw fail("work holds at most twenty entries, each with text of at most 300 bytes") } }
        if let tags { guard tags.count <= 3,tags.allSatisfy({text($0.label,32)}) else { throw fail("tags holds at most three labels of at most 32 bytes") } }
        if let decision {
            guard text(decision.question,300),(2...4).contains(decision.options.count),
                  decision.options.allSatisfy({text($0.id,64) && text($0.label,60) && text($0.detail,200) && ($0.replyPreview.map{text($0,2000)} ?? true)}),
                  Set(decision.options.map(\.id)).count == decision.options.count else { throw fail("decision needs a question of at most 300 bytes and two to four options with distinct ids") }
            guard decision.recommended.map({id in decision.options.contains{$0.id == id}}) ?? true else { throw fail("decision.recommended must be the id of one of its options") }
        }
        if let draft {
            guard text(draft.preview,2000),!draft.to.isEmpty,draft.to.count <= 20,draft.to.allSatisfy({text($0,320)}),
                  draft.reference.map({text($0,512)}) ?? true,draft.attachments.count <= 10,draft.attachments.allSatisfy({text($0,255)}),
                  draft.text.map({text($0,MailUpdateDraft.textLimit)}) ?? true else {
                throw fail("draft needs delivery, recipients, a preview of at most 2000 bytes and, when given, text of at most 16384 bytes")
            }
        }
    }
}

/// What the owner has done with one revision of an update. A later revision from Dot starts afresh.
public struct MailUpdateOwnerState:Codable,Sendable,Equatable {
    /// `ignored`, `deleted` and `closed` take the update off the list. `instructed` leaves it in place,
    /// marked "Sent to Dot", until Dot's next revision.
    public enum Handled:String,Codable,Sendable { case ignored,deleted,closed,instructed }
    public var revision:Int
    /// The `id` of the option chosen, before or after it is applied.
    public var chosen:String?
    public var handled:Handled?
    /// What the owner told Dot, in a few words, shown while Dot acts.
    public var note:String?
    public var at:Date
    /// The request carrying the instruction to Dot, so it can be cancelled while it has not gone.
    public var requestID:String?
}

/// The owner's instruction about one update, given in the workbench and carried to Dot as a request bound
/// to the update's key and revision. It is the owner's own act on the Mac, and it never sends mail: a send
/// goes through the confirmation and Mail Dot's native review, which Dot cannot answer.
public struct MailUpdateInstruction:Codable,Sendable,Equatable {
    public enum Kind:String,Codable,Sendable { case option,discuss }
    public var kind:Kind
    public var updateID:String
    public var scheduleID:String
    public var revision:Int
    public var optionID:String?
    public var optionLabel:String?
    public var effect:MailUpdateEffect?
    /// With `draftReply`: the owner's answer to "draft and save or draft and send".
    public var delivery:ProposalDelivery?
    /// With `discuss`: what the owner asked or told Dot.
    public var text:String?
    public init(kind:Kind,updateID:String,scheduleID:String,revision:Int,optionID:String?=nil,optionLabel:String?=nil,effect:MailUpdateEffect?=nil,delivery:ProposalDelivery?=nil,text:String?=nil) {
        self.kind=kind; self.updateID=updateID; self.scheduleID=scheduleID; self.revision=revision
        self.optionID=optionID; self.optionLabel=optionLabel; self.effect=effect; self.delivery=delivery; self.text=text
    }
    public static let textLimit=2000
    public func validate() throws {
        func filled(_ value:String?,_ limit:Int)->Bool { value.map{!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.utf8.count <= limit} ?? false }
        guard filled(updateID,512),filled(scheduleID,512),revision >= 0 else { throw BridgeFailure("An instruction names its update.") }
        switch kind {
        case .option:
            guard filled(optionID,64),filled(optionLabel,60),let effect,text == nil,(effect == .draftReply) == (delivery != nil) else {
                throw BridgeFailure("Choose one of the listed options, and say draft and save or draft and send when it asks for a reply.")
            }
        case .discuss:
            guard filled(text,Self.textLimit),optionID == nil,optionLabel == nil,effect == nil,delivery == nil else {
                throw BridgeFailure("Say what you want Dot to do, in at most 2,000 characters.")
            }
        }
    }
    /// A few words for the list while Dot acts.
    public var summary:String {
        switch kind {
        case .option: (optionLabel ?? "Option")+(delivery.map{$0 == .send ? " · draft and send" : " · draft and save"} ?? "")
        case .discuss: "Discussed with Dot"
        }
    }
}

/// What the workbench shows for one update, whether Dot reported it in fields or in the older single block.
public struct MailUpdatePresentation:Sendable,Equatable {
    public var status:MailUpdateStatus
    public var subject:String
    public var sender:String?
    public var receivedAt:Date?
    public var gist:String
    public var points:[String]
    public var unverified:[String]
    public var decision:MailUpdateDecision?
    /// For an older update: Dot's line on what is needed, shown under "Follow-up needed".
    public var followUp:String?
    public var work:[MailUpdateWork]
    public var tags:[MailUpdateTag]
    public var draft:MailUpdateDraft?
    public var structured:Bool
    public var needsOwner:Bool { work.contains{$0.state == .needsOwner} }

    /// `sentReferences` are the shared messages Mail Dot itself has recorded as sent. Only that record puts
    /// an update under "Drafted and sent"; Dot's own claim of it never does.
    public init(_ update:ScheduledMailUpdate,sentReferences:Set<String>=[]) {
        structured=update.isStructured
        subject=update.message?.subject ?? update.title
        sender=update.message?.sender
        receivedAt=update.message?.receivedAt
        points=update.summaryPoints ?? Self.statements(in:update.summary)
        unverified=update.unverified ?? []
        decision=update.decision
        work=update.work ?? []
        tags=update.tags ?? []
        draft=update.draft
        let note=update.actionTextShown.trimmingCharacters(in:.whitespacesAndNewlines)
        followUp=update.decision == nil && !note.isEmpty ? note : nil
        gist=update.gist ?? update.summaryPoints?.first ?? Self.firstSentence(update.summary)
        if let reference=update.draft?.reference,sentReferences.contains(reference) { status = .draftedSent }
        else if let claimed=update.status {
            switch claimed {
            case .draftedSent: status=update.draft != nil ? .draftedQueued : .information
            case .draftedQueued: status=update.draft != nil ? .draftedQueued : .awaitingInstruction
            case .awaitingInstruction,.information: status=claimed
            }
        } else if update.draft != nil || update.preparedReply != nil { status = .draftedQueued }
        else {
            switch update.action {
            case .decision,.reply: status = .awaitingInstruction
            case .reviewDraft: status = .draftedQueued
            case .none,.followUp,.resolved: status = .information
            }
        }
    }
    /// An older report's single block of text as separate statements, so that it reads as points and not
    /// as one paragraph: at most six, the remainder kept with the sixth.
    public static func statements(in text:String) -> [String] {
        var found:[String]=[]
        let whole=text as NSString
        whole.enumerateSubstrings(in:NSRange(location:0,length:whole.length),options:[.bySentences,.localized]) { part,_,_,_ in
            if let part=part?.trimmingCharacters(in:.whitespacesAndNewlines),!part.isEmpty { found.append(part) }
        }
        if found.count > 6 { found=Array(found.prefix(5))+[found.dropFirst(5).joined(separator:" ")] }
        return found.isEmpty ? [text] : found
    }
    static func firstSentence(_ text:String) -> String {
        let flat=text.split(whereSeparator:\.isNewline).joined(separator:" ")
        let end=flat.range(of:". ").map{flat[..<$0.lowerBound]+"."} ?? Substring(flat)
        return end.count > 200 ? String(end.prefix(197))+"…" : String(end)
    }
}

/// The controls offered first for an update. Kept as a rule of its own so that what Return does is tested.
public enum MailUpdatePrimary:Equatable,Sendable {
    /// Nothing can be applied until an option is chosen; `count` options are offered.
    case choose(count:Int)
    case draftAndSave,draftAndSend
    /// Send the queued draft, after the one confirmation on the Mac. Only with a verified binding to the Mail draft.
    case sendDraft
    /// The draft exists but Mail Dot holds no verified binding to it: it can be shown, not sent, from here.
    case openDraftInMail
    case apply(MailUpdateEffect)
    /// The owner's instruction is with Dot; nothing more to press until Dot reports.
    case sentToDot

    public static func controls(for presentation:MailUpdatePresentation,owner:MailUpdateOwnerState?,draftIsBound:Bool) -> [MailUpdatePrimary] {
        if owner?.handled == .instructed { return [.sentToDot] }
        guard presentation.status != .draftedSent else { return [] }
        let send:MailUpdatePrimary=draftIsBound ? .sendDraft : .openDraftInMail
        guard let decision=presentation.decision else { return presentation.draft != nil ? [send] : [] }
        guard let chosen=owner?.chosen,let option=decision.options.first(where:{$0.id == chosen}) else { return [.choose(count:decision.options.count)] }
        switch option.effect {
        case .draftReply: return [.draftAndSave,.draftAndSend]
        case .sendAsDrafted: return presentation.draft != nil ? [send] : [.apply(.resolve)]
        // An answer goes to Dot first: it may change the draft, which Dot then reports again.
        case let effect: return [.apply(effect)]
        }
    }
}
