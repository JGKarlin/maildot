import Foundation
import Darwin

@_silgen_name("flock") private func triageFileLock(_ fd:Int32,_ operation:Int32) -> Int32

/// Which arriving mail is essential enough that Dot is asked whether it needs a reply. Decided on the Mac,
/// from the message's headers alone, before anything is sent to Dot: receipts, codes, spam, bulk and
/// automated mail are never offered to Dot (the owner's requirement of 11 November 2026). Only a message a
/// person wrote to the owner directly is, and Dot is then asked about that one message.
public enum MailTriage {
    /// The headers Mail is asked to supply for each arriving message. Lower case.
    public static let requiredHeaders=["message-id","from","to","cc","reply-to","subject","date","in-reply-to","references",
        "list-unsubscribe","list-id","list-post","precedence","auto-submitted","x-auto-response-suppress","feedback-id",
        "x-spam-flag","x-spam-status","x-spam","x-ms-exchange-organization-scl","x-apple-movetofolder","return-path","sender"]

    /// The reason given for a message the owner was only copied on; its banner reads Cc only.
    public static let copiedOnlyReason="You were only copied."
    /// Mail the owner wrote. It gets no Mail Dot state: no banner, no list mark.
    public static let sentByOwnerReason="Sent by you."
    public struct Input:Sendable,Equatable {
        public var messageID:String?
        public var senderAddress:String
        public var senderName:String?
        public var to:[String]
        public var cc:[String]
        public var subject:String
        public var receivedAt:Date?
        /// Header names in lower case.
        public var headers:[String:[String]]
        /// The message's own text names the owner (see MailBodyText); known only when Mail gave its body.
        public var mentionsOwner=false
        public init(messageID:String?,senderAddress:String,senderName:String?,to:[String],cc:[String],subject:String,receivedAt:Date?,headers:[String:[String]]) {
            self.messageID=messageID.flatMap(MailMessageIdentity.normalized); self.senderAddress=senderAddress.lowercased(); self.senderName=senderName
            self.to=to.map{$0.lowercased()}; self.cc=cc.map{$0.lowercased()}; self.subject=subject; self.receivedAt=receivedAt
            self.headers=Dictionary(headers.map{($0.key.lowercased(),$0.value)},uniquingKeysWith:{$0+$1})
        }
    }
    public enum Rule:String,Codable,Sendable { case always,never }
    public struct Verdict:Sendable,Equatable {
        public let essential:Bool
        /// In the owner's words: why it was offered to Dot, or why not.
        public let reason:String
        /// The owner was copied rather than addressed: offered to Dot after mail sent to them directly.
        public var copied=false
        public init(essential:Bool,reason:String,copied:Bool=false) { self.essential=essential; self.reason=reason; self.copied=copied }
    }

    private static let automatedLocalParts=["noreply","no-reply","no_reply","donotreply","do-not-reply","do_not_reply","notification","notifications","notify","alert","alerts","mailer-daemon","postmaster","bounce","bounces","newsletter","news","updates","marketing","receipts","receipt","billing","invoice","invoices","orders","order","shipping","delivery","security","verify","verification","account","accounts","support-noreply","automated","system"]
    private static let transactionalWords=["receipt","invoice","order confirmation","your order","has shipped","shipment","shipping","delivery","delivered","payment","statement","billing","subscription","renewal","password","verify","verification","confirm your","sign in","sign-in","log in","login","security alert","security code","one-time","otp","passcode","two-factor","2fa","unsubscribe","newsletter","webinar",
        "領収書","請求書","ご注文","注文","発送","配送","お届け","お支払","支払い","明細","確認コード","認証コード","ワンタイム","パスワード","ログイン","セキュリティ","メールマガジン","お知らせ配信"]

    /// Whether a message is offered to Dot, and why. `owner` is every address the owner receives mail at;
    /// `correspondents` are addresses the owner has replied to through Mail Dot or chose to always ask about.
    public static func assess(_ input:Input,owner:Set<String>,correspondents:Set<String>=[],rules:[String:Rule]=[:]) -> Verdict {
        let sender=input.senderAddress
        let who=input.senderName.flatMap{$0.isEmpty ? nil : $0} ?? sender
        if let rule=rules[sender] {
            return rule == .always ? Verdict(essential:true,reason:"You chose to always ask Dot about mail from \(who).")
                                   : Verdict(essential:false,reason:"You chose never to ask Dot about mail from \(who).")
        }
        func header(_ name:String) -> String { (input.headers[name] ?? []).joined(separator:" ").trimmingCharacters(in:.whitespaces) }
        let spamFlag=header("x-spam-flag").lowercased(),spamStatus=header("x-spam-status").lowercased(),spam=header("x-spam").lowercased()
        let scl=Int(header("x-ms-exchange-organization-scl")) ?? -1
        if spamFlag.hasPrefix("yes") || spamStatus.hasPrefix("yes") || spam.hasPrefix("yes") || scl >= 5 { return Verdict(essential:false,reason:"Marked as spam.") }
        if owner.contains(sender) { return Verdict(essential:false,reason:MailTriage.sentByOwnerReason) }
        if !header("list-unsubscribe").isEmpty || !header("list-id").isEmpty || !header("list-post").isEmpty || !header("feedback-id").isEmpty {
            return Verdict(essential:false,reason:"Bulk or mailing-list mail.")
        }
        if ["bulk","list","junk"].contains(header("precedence").lowercased()) { return Verdict(essential:false,reason:"Bulk mail.") }
        let auto=header("auto-submitted").lowercased()
        if (!auto.isEmpty && auto != "no") || !header("x-auto-response-suppress").isEmpty { return Verdict(essential:false,reason:"Sent automatically.") }
        let local=sender.split(separator:"@").first.map(String.init) ?? sender
        if automatedLocalParts.contains(where:{local == $0 || local.hasPrefix($0+".") || local.hasPrefix($0+"-") || local.hasPrefix($0+"+")}) || header("return-path") == "<>" {
            return Verdict(essential:false,reason:"From an automated address (\(local)@).")
        }
        let subject=input.subject.lowercased()
        let hasCode=subject.range(of:"(^|[^0-9])[0-9]{4,8}([^0-9]|$)",options:.regularExpression) != nil
        if hasCode && (subject.contains("code") || subject.contains("コード") || subject.contains("pin") || subject.contains("認証")) { return Verdict(essential:false,reason:"Carries a verification or one-time code.") }
        // A word in the subject sets aside only mail from someone the owner has never written to: a colleague's message
        // that happens to say "receipt" still goes to Dot (owner decision, 16 November 2026).
        if !correspondents.contains(sender),let word=transactionalWords.first(where:{subject.contains($0)}) { return Verdict(essential:false,reason:"Looks like a notice, receipt or account message (“\(word)”).") }
        guard input.to.contains(where:owner.contains) else {
            // Copied: offered to Dot like mail sent to the owner, once it has passed the same checks for spam, lists,
            // automated mail and notices above (owner request, 13 November 2026: every message gets Dot's window and report).
            // It waits behind mail sent to the owner directly in Dot's queue.
            if input.cc.contains(where:owner.contains) {
                return Verdict(essential:true,reason:input.mentionsOwner ? "\(who) copied you on this message, and it mentions you by name." : "\(who) copied you on this message.",copied:true)
            }
            return Verdict(essential:false,reason:"Not addressed to you directly.")
        }
        let known=correspondents.contains(sender)
        let conversation = !header("in-reply-to").isEmpty
        return Verdict(essential:true,reason:known ? "\(who) wrote to you directly, and you have written to them before."
                       : conversation ? "\(who) replied to you directly in a conversation." : "\(who) wrote to you directly.")
    }
}

/// One arriving message and what became of it.
public struct MailTriageEntry:Codable,Sendable,Identifiable,Equatable {
    public enum Outcome:String,Codable,Sendable {
        /// Not offered to Dot, for `reason`.
        case skipped
        /// Essential, but automatic drafting was off when it arrived.
        case held
        /// Waiting to be offered to Dot.
        case pending
        /// Offered to Dot; waiting for its answer.
        case asked
        /// Dot read it and judged that no reply is needed.
        case noDraft
        /// Dot wrote a draft reply, kept in `draft`.
        case drafted
        /// Dot cannot draft without the owner's guidance; its question is in `dotNote`.
        case needsGuidance
        /// The owner has replied.
        case replied
        case failed
    }
    public var id=UUID().uuidString
    public var messageID:String?
    public var sender:String
    public var senderName:String?
    public var subject:String
    public var receivedAt:Date?
    public var seenAt=Date()
    public var essential:Bool
    public var reason:String
    public var outcome:Outcome
    /// The owner pressed Ask Dot for this message.
    public var askedByOwner=false
    /// Held because it arrived before Automatic replies were turned on for its account.
    public var heldAsOlder:Bool?
    /// When the owner opened this message in Mail. An opened message is drafted even if it is older mail.
    public var openedAt:Date?
    /// Files Dot finished with its automatic draft, kept under ReplyFiles/triage-<id> until a reply shows them.
    public var files:[ReplyFile]?
    /// What Dot did besides writing, with its automatic draft.
    public var tasksDone:[String]?
    /// The owner's addresses the message was sent to: which of the owner's accounts received it.
    public var recipients:[String]?
    public var requestID:String?
    /// Dot's answer: why no reply is needed, or why it failed.
    public var dotNote:String?
    public var draft:String?
    /// The owner's answer to Dot's question, sent with the next request about this message.
    public var ownerAnswer:String?
    /// The owner asked Dot about this message and the answer is still to come or still to be used.
    public var ownerRequestInFlight:Bool { askedByOwner && [.pending,.asked,.drafted,.needsGuidance].contains(outcome) }
    /// The owner pressed Draft a Reply (owner request, 14 November 2026): Dot writes a reply even if it had found none
    /// needed, following the owner's words for it when they gave any. Both are sent with each request about this message.
    public var draftRequested:Bool?
    public var draftGuidance:String?
    public var announcedAt:Date?
    /// Kept only so that lists saved by build 82, which coloured rows, still load. Unused.
    public var appliedColor:MailListColor?
    /// The flag Mail Dot last put on the message (Mail's flag index), -1 once it took its flag off, nil if it
    /// never touched the message's flag.
    public var appliedFlag:Int?
    /// The owner put a flag of their own on the message: Mail Dot leaves its flag alone from then on.
    public var ownerFlagged:Bool?
    public var checkedRepliedAt:Date?
    /// When Dot was last asked about this message, and whether it was already asked once more after not
    /// answering in time.
    public var askedAt:Date?
    public var retriedUnanswered:Bool?
    /// Dot's report on the message's thread, with its latest answer, and when that answer came.
    public var report:ThreadReport?
    public var reportedAt:Date?
    /// Add to Calendar was pressed for the report's meeting: the background app adds it, then records the result.
    public var calendarRequestedAt:Date?
    public var calendarAdded:Bool?
    public var calendarNote:String?
    /// The owner was only copied: Dot gets it after the messages sent to the owner directly.
    public var copied:Bool?
    /// Ask Dot for a Report (owner choice, 13 November 2026): a request for the thread report alone, never a draft,
    /// for a message without one. When it was pressed, the request sent, and why it failed, if it did.
    public var reportRequestedAt:Date?
    public var reportRequestID:String?
    public var reportFailed:String?
    /// The owner asked for a report and Dot has not delivered it yet.
    public var reportPending:Bool { reportRequestedAt != nil }
    /// Open in Reply (owner decision, 15 November 2026): the owner asked for this draft to be put in a Mail reply,
    /// by the button or by asking for a draft in the Mail Dot window. `openReplyWhenDrafted` waits for the draft
    /// Dot is writing; `openReplyRequestedAt` is a draft ready to open now. Automatic drafts never set either.
    public var openReplyWhenDrafted:Bool?
    public var openReplyRequestedAt:Date?
    /// Why the last reply could not be opened, in plain words for the window.
    public var openReplyFailed:String?
    /// The draft the owner asked for came without a report: Dot is asked for it once the reply has been opened.
    public var reportAfterReply:Bool?
    /// Open in Reply was pressed in the Mail Dot window: the background app closes that window, so the reply can open.
    public var openReplyClosesWindow:Bool?
    /// When the owner asked for a draft of the reply in the reply panel: the message shows Drafting until Dot's draft
    /// arrives, for as long as Dot may take (owner decision, 16 November 2026).
    public var replyPanelDraftingAt:Date?
    public init(messageID:String?,sender:String,senderName:String?,subject:String,receivedAt:Date?,verdict:MailTriage.Verdict,automatic:Bool) {
        self.messageID=messageID; self.sender=sender; self.senderName=senderName; self.subject=subject; self.receivedAt=receivedAt
        essential=verdict.essential; reason=verdict.reason; copied=verdict.copied ? true : nil
        outcome=verdict.essential ? (automatic ? .pending : .held) : .skipped
    }
}

public struct MailTriageState:Codable,Sendable {
    public static let keep=200
    /// At most this many messages are offered to Dot in an hour, however much mail arrives.
    public static let hourlyLimit=30
    public var entries:[MailTriageEntry]=[]
    public var rules:[String:MailTriage.Rule]=[:]
    /// Dot's scheduled reports shown on a message, by that message's Message-ID: report key and when the
    /// owner's reply to it was last looked for. A report on a message the owner has answered, in Mail Dot or
    /// in Mail by hand, is closed. Optional so that lists saved before it still load.
    public var reportLinks:[String:ReportLink]?
    public struct ReportLink:Codable,Sendable,Equatable {
        public var reportKey:String
        public var checkedAt:Date?
        public init(reportKey:String,checkedAt:Date?=nil) { self.reportKey=reportKey; self.checkedAt=checkedAt }
    }
    /// A report was shown on this message. Returns whether this is new.
    @discardableResult public mutating func linkReport(_ reportKey:String,messageID:String) -> Bool {
        guard let id=MailMessageIdentity.normalized(messageID) else { return false }
        var links=reportLinks ?? [:]
        guard links[id]?.reportKey != reportKey else { return false }
        links[id]=ReportLink(reportKey:reportKey)
        if links.count > 200 { for key in links.keys.sorted().prefix(links.count-200) { links.removeValue(forKey:key) } }
        reportLinks=links
        return true
    }
    /// Messages with a report whose reply has not been looked for in the last five minutes.
    public func reportReplyChecksDue(now:Date=Date(),limit:Int=2) -> [(messageID:String,reportKey:String)] {
        (reportLinks ?? [:]).filter{ now.timeIntervalSince($0.value.checkedAt ?? .distantPast) > 300 }
            .sorted{ ($0.value.checkedAt ?? .distantPast) < ($1.value.checkedAt ?? .distantPast) }
            .prefix(limit).map{ ($0.key,$0.value.reportKey) }
    }
    public mutating func noteReportChecked(_ messageID:String,replied:Bool,now:Date=Date()) {
        if replied { reportLinks?.removeValue(forKey:messageID) } else { reportLinks?[messageID]?.checkedAt=now }
    }
    public var correspondents:[String]=[]
    /// The owner's questions to Dot from the ask bar (see AskDot), and when the Mail Dot window's Ask Dot
    /// button last asked for the bar to be shown. Optional so that lists saved before them still load.
    public var asks:[AskDot.Question]?
    /// The owner's rule for Dot's report on a sender's mail, by address (owner request, 14 November 2026): always, a
    /// report on every new message from them, even one not offered for a draft; never, no automatic report.
    public var reportRules:[String:MailTriage.Rule]?
    public mutating func setReportRule(_ rule:MailTriage.Rule?,for sender:String) {
        var rules=reportRules ?? [:]
        rules[sender.lowercased()]=rule
        reportRules=rules.isEmpty ? nil : rules
    }
    public func reportRule(for sender:String) -> MailTriage.Rule? { reportRules?[sender.lowercased()] }
    /// A message just recorded from a sender whose reports are always wanted, and which is not going to Dot
    /// for a draft (so no report would come with one): a report alone is asked for. Never a draft.
    public mutating func requestReportIfAlways(messageID:String?) {
        guard let messageID,let index=entries.lastIndex(where:{$0.messageID == messageID}),reportRule(for:entries[index].sender) == .always,
              [.skipped,.held].contains(entries[index].outcome),entries[index].reason != MailTriage.sentByOwnerReason,entries[index].report == nil,entries[index].reportRequestedAt == nil else { return }
        entries[index].reportRequestedAt=Date(); entries[index].reportFailed=nil
    }
    public var askBarRequestedAt:Date?
    /// What Mail Dot needs in place to work with Dot, as the background app last found it. Absent from lists saved
    /// by earlier builds.
    public var connection:ConnectionState?
    public init() {}

    /// Records an arriving message once; a message Mail hands over again is not recorded twice.
    @discardableResult public mutating func record(_ entry:MailTriageEntry) -> Bool {
        if let id=entry.messageID,entries.contains(where:{$0.messageID == id}) { return false }
        entries.append(entry)
        if entries.count > Self.keep { entries.removeFirst(entries.count-Self.keep) }
        return true
    }
    /// Dot's queue (owner request, 13 November 2026): Dot is never flooded with requests all at once. Until 18
    /// November 2026 messages went one at a time, each its own notice to ChatGPT and its own turn, about a minute
    /// apiece, so mail that arrived while Mail was closed took as many minutes as there were messages. The owner
    /// chose a batch (18 November 2026): up to this many are offered together, ChatGPT is told of the first alone,
    /// and Dot is handed each next one as it reports the last (see MailWorkflowState's chain). The queue is the
    /// waiting entries themselves, kept on disk, so it survives a restart, and nothing in it is dropped.
    public static let inFlightLimit=6
    /// The waiting messages in the order Dot gets them: those the owner asked about first, then those the
    /// owner opened (most recently opened first), then mail sent to the owner directly, then mail they were
    /// copied on, each newest first.
    public func queueForDot() -> [MailTriageEntry] {
        entries.filter{$0.outcome == .pending && $0.requestID == nil}.sorted { a,b in
            if a.askedByOwner != b.askedByOwner { return a.askedByOwner }
            if (a.openedAt != nil) != (b.openedAt != nil) { return a.openedAt != nil }
            if let x=a.openedAt,let y=b.openedAt,x != y { return x > y }
            if (a.copied == true) != (b.copied == true) { return a.copied != true }
            return (a.receivedAt ?? a.seenAt) > (b.receivedAt ?? b.seenAt)
        }
    }
    /// The messages to offer to Dot now: the head of the queue, while Dot has room and within the hourly limit.
    public func dueForDot(now:Date=Date()) -> [MailTriageEntry] {
        // Ask Dot comes first (owner decision, 14 November 2026): while the owner's question waits for Dot, no new
        // automatic request is started, so Dot turns to the question next.
        if askList.contains(where:{ $0.state == .waiting || $0.state == .asked }) { return [] }
        let recent=entries.filter{$0.requestID != nil && now.timeIntervalSince($0.seenAt) < 3600}.count
        let busy=entries.filter{$0.outcome == .asked}.count
        let room=max(0,min(Self.hourlyLimit-recent,Self.inFlightLimit-busy))
        return Array(queueForDot().prefix(room))
    }
    /// Automatic drafting was turned off before a waiting message was offered: it is held, not sent to Dot.
    /// `older`: it arrived before Automatic replies were turned on, so it is never drafted automatically.
    public mutating func hold(_ id:String,older:Bool=false) {
        guard let index=entries.firstIndex(where:{$0.id == id}),entries[index].outcome == .pending,!entries[index].askedByOwner else { return }
        entries[index].outcome = .held
        entries[index].heldAsOlder=older ? true : nil
    }
    public mutating func markAnnounced(_ id:String,now:Date=Date()) {
        guard let index=entries.firstIndex(where:{$0.id == id}) else { return }
        entries[index].announcedAt=now
    }
    /// The owner's Ask Dot: offered to Dot even if skipped, and whether or not automatic drafting is on.
    /// `draft`: pressed as Draft a Reply, with the owner's optional words on what the reply should say. Try Again keeps
    /// whatever an earlier Draft a Reply gave.
    public mutating func ask(_ id:String,draft:Bool=false,guidance:String?=nil) throws {
        let words=guidance?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        guard words.count <= ReplyOwnerRequest.textLimit else { throw BridgeFailure("Write at most \(ReplyOwnerRequest.textLimit) characters for Dot.") }
        guard let index=entries.firstIndex(where:{$0.id == id}) else { throw BridgeFailure("That message is no longer in Mail Dot's list.") }
        guard ![.asked,.pending].contains(entries[index].outcome) else { return }
        entries[index].outcome = .pending; entries[index].askedByOwner=true; entries[index].requestID=nil; entries[index].dotNote=nil
        // The owner's own request starts afresh: an earlier unanswered try does not count against it.
        entries[index].retriedUnanswered=nil
        if draft { entries[index].draftRequested=true; entries[index].draftGuidance=words.isEmpty ? nil : words }
    }
    public mutating func setRule(_ rule:MailTriage.Rule?,for sender:String) {
        let address=sender.lowercased()
        rules[address]=rule
        if rule == .always,!correspondents.contains(address) { correspondents.append(address) }
    }
    public mutating func learnCorrespondent(_ address:String) {
        let value=address.lowercased()
        guard value.contains("@"),!correspondents.contains(value) else { return }
        correspondents.append(value)
        if correspondents.count > 2000 { correspondents.removeFirst(correspondents.count-2000) }
    }
    public mutating func markAsked(_ id:String,requestID:String,now:Date=Date()) {
        guard let index=entries.firstIndex(where:{$0.id == id}) else { return }
        entries[index].outcome = .asked; entries[index].requestID=requestID; entries[index].askedAt=now
    }
    /// The fifteen minutes Dot has for a message count from when Dot takes it, and for messages waiting behind it in
    /// the batch from Dot's last sign of work: a message that is only waiting its turn is not one Dot left unanswered.
    public mutating func noteDotAtWork(requestIDs:Set<String>,now:Date=Date()) {
        for index in entries.indices where entries[index].outcome == .asked {
            if let id=entries[index].requestID,requestIDs.contains(id) { entries[index].askedAt=now }
        }
    }
    /// How long Dot may take to answer about a message before Mail Dot stops waiting.
    public static let answerLimit:TimeInterval=15*60
    /// A message Dot has not answered about in time is never left showing "Drafting": it is offered to Dot
    /// once more, and if Dot again does not answer, it says so, and the owner can ask again (13 November 2026).
    @discardableResult public mutating func expireUnanswered(now:Date=Date()) -> Int {
        var count=0
        for index in entries.indices where entries[index].outcome == .asked && now.timeIntervalSince(entries[index].askedAt ?? entries[index].seenAt) > Self.answerLimit {
            if entries[index].retriedUnanswered != true {
                entries[index].outcome = .pending; entries[index].requestID=nil; entries[index].retriedUnanswered=true
            } else {
                entries[index].outcome = .failed
                entries[index].dotNote="Dot did not answer about this message within 15 minutes. Choose Try Again to ask once more."
            }
            count += 1
        }
        return count
    }
    /// Dot's answer about one message. A summary carrying "Draft reply:" holds the reply after that line;
    /// any other ready summary means no reply is needed.
    public mutating func accept(requestID:String,stage:MailWorkflowStage,summary incoming:String,question:String?=nil,now:Date=Date()) {
        // A report-only request: the report is kept, and nothing else about the message changes.
        if let index=entries.firstIndex(where:{$0.reportRequestID == requestID}) {
            guard [.ready,.awaitingInput,.failed].contains(stage) else { return }
            let report=ThreadReport.extract(from:incoming).report
            entries[index].reportRequestID=nil; entries[index].reportRequestedAt=nil
            if let report {
                entries[index].report=entries[index].calendarAdded == true ? report.withMeetingAdded() : report
                entries[index].reportedAt=now; entries[index].reportFailed=nil
            } else {
                entries[index].reportFailed=stage == .failed ? incoming.trimmingCharacters(in:.whitespacesAndNewlines) : "Dot answered without a report."
            }
            return
        }
        guard let index=entries.firstIndex(where:{$0.requestID == requestID}) else { return }
        entries[index].announcedAt=nil
        // Dot's thread report travels as one marked line; it is kept apart and never shown as text.
        let (report,summary)=ThreadReport.extract(from:incoming)
        if [.ready,.awaitingInput,.failed].contains(stage) {
            // A meeting the owner already added stays added, whatever Dot's new report says about the calendar.
            // No automatic report for a sender the owner chose Never for; Ask Dot for a Report still gives one.
            if let report,reportRule(for:entries[index].sender) != .never { entries[index].report=entries[index].calendarAdded == true ? report.withMeetingAdded() : report }
            // A draft the owner asked for comes without a report (it comes first); when the report was last written stays.
            if report != nil || entries[index].draftRequested != true { entries[index].reportedAt=now }
        }
        switch stage {
        case .failed: entries[index].outcome = .failed; entries[index].dotNote=summary
        case .awaitingInput: entries[index].outcome = .needsGuidance; entries[index].dotNote=question ?? summary
        case .ready:
            let lines=summary.split(omittingEmptySubsequences:false,whereSeparator:\.isNewline)
            // The owner has already answered it, by hand or from another device: Replied, never No reply needed
            // (owner request, 13 November 2026).
            if let first=lines.first(where:{ !$0.trimmingCharacters(in:.whitespaces).isEmpty }),
               first.trimmingCharacters(in:.whitespaces).lowercased().hasPrefix("already replied:") {
                entries[index].outcome = .replied; entries[index].draft=nil
                entries[index].dotNote=summary.trimmingCharacters(in:.whitespacesAndNewlines)
                return
            }
            if let at=lines.firstIndex(where:{$0.trimmingCharacters(in:.whitespaces).lowercased().hasPrefix("draft reply:")}) {
                let first=String(lines[at].trimmingCharacters(in:.whitespaces).dropFirst("draft reply:".count))
                let reply=([first]+lines[(at+1)...].map(String.init)).joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines)
                if !reply.isEmpty {
                    entries[index].outcome = .drafted; entries[index].draft=reply
                    let before=lines[..<at].map{$0.trimmingCharacters(in:.whitespaces)}
                    // Lines beginning "Done:" say what Dot did besides writing; the panel shows them with the draft.
                    let done=before.filter{$0.lowercased().hasPrefix("done:")}.map{String($0.dropFirst(5)).trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty}
                    entries[index].tasksDone=done.isEmpty ? nil : Array(done.prefix(8))
                    entries[index].dotNote=before.filter{!$0.lowercased().hasPrefix("done:")}.joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines)
                    // The draft the owner asked for came first; the report follows in its own request, once the reply
                    // has been opened, or now if no reply is waiting to open (owner decision, 15 November 2026).
                    if entries[index].draftRequested == true,report == nil {
                        if entries[index].openReplyWhenDrafted == true { entries[index].reportAfterReply=true }
                        else { entries[index].reportRequestedAt=now; entries[index].reportRequestID=nil; entries[index].reportFailed=nil }
                    }
                    return
                }
            }
            entries[index].outcome = .noDraft; entries[index].dotNote=summary
        default: break
        }
    }
    /// Dot drafted a reply from a reply window's panel. The draft is recorded on the message it answers,
    /// whether or not the panel is still open, so that the message shows "draft ready" in Mail and the draft
    /// is waiting when the owner comes back to it.
    public mutating func recordReplyDraft(messageID:String,sender:String,senderName:String?,subject:String,draft:String,now:Date=Date()) {
        guard let wanted=MailMessageIdentity.normalized(messageID),!draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        if let index=entries.lastIndex(where:{$0.messageID == wanted}) {
            guard entries[index].outcome != .replied else { return }
            entries[index].outcome = .drafted; entries[index].draft=draft; entries[index].announcedAt=now
            entries[index].replyPanelDraftingAt=nil
            return
        }
        var entry=MailTriageEntry(messageID:wanted,sender:sender.lowercased(),senderName:senderName,subject:subject,receivedAt:nil,
                                  verdict:MailTriage.Verdict(essential:true,reason:"You asked Dot for a reply."),automatic:false)
        entry.outcome = .drafted; entry.draft=draft; entry.announcedAt=now
        record(entry)
    }
    /// Reports Dot sent in a form Mail Dot did not read when they came (13 November 2026): taken out of the stored
    /// note and kept as the report. Returns how many were recovered.
    @discardableResult public mutating func recoverReports() -> Int {
        var count=0
        for index in entries.indices where entries[index].report == nil {
            guard let note=entries[index].dotNote,note.contains("{") else { continue }
            let (report,rest)=ThreadReport.extract(from:note)
            guard let report else { continue }
            entries[index].report=report; entries[index].dotNote=rest
            count += 1
        }
        return count
    }
    /// Ask Dot for a Report: the message waits for a report-only request; nothing else about it changes.
    public mutating func requestReport(_ id:String,now:Date=Date()) throws {
        guard let index=entries.firstIndex(where:{$0.id == id}) else { throw BridgeFailure("That message is no longer in Mail Dot's list.") }
        guard entries[index].reportRequestedAt == nil else { return }
        entries[index].reportRequestedAt=now; entries[index].reportRequestID=nil; entries[index].reportFailed=nil
    }
    /// Report requests the owner made that have not been sent to Dot yet.
    public func reportsDue() -> [MailTriageEntry] { entries.filter{ $0.reportRequestedAt != nil && $0.reportRequestID == nil } }
    public mutating func markReportAsked(_ id:String,requestID:String) {
        guard let index=entries.firstIndex(where:{$0.id == id}) else { return }
        entries[index].reportRequestID=requestID
    }
    public mutating func noteReportFailure(_ id:String,_ reason:String) {
        guard let index=entries.firstIndex(where:{$0.id == id}) else { return }
        entries[index].reportRequestID=nil; entries[index].reportRequestedAt=nil; entries[index].reportFailed=reason
    }
    /// A report Dot has not delivered within the answer limit is given up, and the window offers Try Again.
    @discardableResult public mutating func expireReportRequests(now:Date=Date()) -> Int {
        var count=0
        for index in entries.indices where entries[index].reportRequestID != nil && now.timeIntervalSince(entries[index].reportRequestedAt ?? now) > Self.answerLimit {
            entries[index].reportRequestID=nil; entries[index].reportRequestedAt=nil
            entries[index].reportFailed="Dot did not answer within 15 minutes."
            count += 1
        }
        return count
    }
    /// The owner's own verdict, No Reply Needed: the message is closed without asking Dot.
    public mutating func markNoReplyNeeded(_ id:String) throws {
        guard let index=entries.firstIndex(where:{$0.id == id}) else { throw BridgeFailure("That message is no longer in Mail Dot's list.") }
        entries[index].outcome = .noDraft; entries[index].draft=nil; entries[index].requestID=nil
        entries[index].dotNote="You marked it No reply needed."
    }
    /// Add to Calendar: the background app adds the report's meeting to the owner's calendar.
    public mutating func requestCalendar(_ id:String,now:Date=Date()) throws {
        guard let index=entries.firstIndex(where:{$0.id == id}),entries[index].report?.meeting != nil else { throw BridgeFailure("That meeting is no longer in Dot's report.") }
        entries[index].calendarRequestedAt=now; entries[index].calendarNote=nil
    }
    public mutating func noteCalendar(_ id:String,added:Bool,note:String?) {
        guard let index=entries.firstIndex(where:{$0.id == id}) else { return }
        entries[index].calendarRequestedAt=nil; entries[index].calendarAdded=added ? true : entries[index].calendarAdded; entries[index].calendarNote=note
        // What Dot did must match what happened (owner report, 13 November 2026): Dot's own earlier attempts at the calendar,
        // refused or pending, give way to the event the owner added.
        if added,let report=entries[index].report { entries[index].report=report.withMeetingAdded() }
    }
    /// The owner's answer to Dot's question about a message: Dot is asked again, with the answer.
    public mutating func answer(_ id:String,with text:String) throws {
        let words=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !words.isEmpty,words.count <= ReplyOwnerRequest.textLimit else { throw BridgeFailure("Write an answer of at most \(ReplyOwnerRequest.textLimit) characters.") }
        guard let index=entries.firstIndex(where:{$0.id == id}) else { throw BridgeFailure("That message is no longer in Mail Dot's list.") }
        entries[index].ownerAnswer=words; entries[index].outcome = .pending; entries[index].requestID=nil; entries[index].askedByOwner=true
        entries[index].retriedUnanswered=nil
    }
    /// Messages the owner answered from this Mac's Mail, recorded by Mail Dot's extension as the reply was
    /// sent: normalized Message-ID to when. Knowing this, Mail Dot need not ask Mail through its scripting,
    /// which searches the whole inbox on Mail's main thread and made Mail's cursor spin (13 November 2026).
    public var ownerReplied:[String:Date]?
    /// Set by the extension when its Mail Dot window closes: the companion then has Mail show the visible
    /// messages again, which brings back the banner Mail took away when its button was pressed.
    public var bannerReloadRequestedAt:Date?
    /// Set by the extension while a Mail Dot window is open in Mail. Mail keeps its other windows waiting meanwhile,
    /// so a reply Open in Reply asked for is opened once the window has closed.
    public var mailDotWindowOpenAt:Date?
    public static let ownerRepliedLimit=500
    /// A message the owner wrote, as Mail shows it: sent from this Mac, a phone or the web. It has no state of its
    /// own, and the message it answers is marked replied (owner request, 16 November 2026: a reply written by
    /// hand in Mail left the message on Draft ready, and the reply itself said No reply needed).
    @discardableResult public mutating func noteOwnerSent(inReplyTo parent:String?,now:Date=Date()) -> Bool {
        guard let parent,let id=MailMessageIdentity.normalized(parent) else { return false }
        guard ownerReplied?[id] != nil else { noteOwnerReplied(messageID:id,now:now); return true }
        // A reply already recorded, shown again when its conversation is opened. It still closes an entry left open
        // from before it, but never one the owner has asked Dot about since: that request is newer than the reply
        // (owner report, 17 November 2026: an answer to Dot's question was closed as Replied the moment the
        // conversation showed the owner's earlier reply, and Dot asked the same question again in the reply panel).
        let stale=entries.indices.filter { index in
            entries[index].messageID.flatMap(MailMessageIdentity.normalized) == id && ![.replied,.skipped].contains(entries[index].outcome)
                && !entries[index].ownerRequestInFlight
        }
        guard !stale.isEmpty else { return false }
        for index in stale { entries[index].outcome = .replied; entries[index].draft=nil }
        return true
    }
    public mutating func noteOwnerReplied(messageID:String,now:Date=Date()) {
        guard let id=MailMessageIdentity.normalized(messageID) else { return }
        var replied=ownerReplied ?? [:]
        replied[id]=now
        if replied.count > Self.ownerRepliedLimit {
            for key in replied.sorted(by:{ $0.value < $1.value }).prefix(replied.count-Self.ownerRepliedLimit).map(\.key) { replied.removeValue(forKey:key) }
        }
        ownerReplied=replied
        markReplied(messageID:id)
    }
    public func ownerHasReplied(_ messageID:String) -> Bool {
        guard let id=MailMessageIdentity.normalized(messageID) else { return false }
        return ownerReplied?[id] != nil
    }
    public mutating func markReplied(messageID:String) {
        guard let wanted=MailMessageIdentity.normalized(messageID) else { return }
        for index in entries.indices where entries[index].messageID.flatMap(MailMessageIdentity.normalized) == wanted && entries[index].outcome != .skipped { entries[index].outcome = .replied; entries[index].draft=nil }
    }
    /// How long a draft Dot wrote on its own is kept unused before it is thrown away.
    public static let draftLifetime:TimeInterval=14*86_400
    /// Throws away drafts older than their lifetime. Drafts live only in Mail Dot's own store, never in
    /// Mail's Drafts, so this keeps that store from filling up.
    @discardableResult public mutating func discardOldDrafts(now:Date=Date()) -> Int {
        var count=0
        for index in entries.indices where entries[index].outcome == .drafted && now.timeIntervalSince(entries[index].seenAt) > Self.draftLifetime {
            entries[index].outcome = .noDraft; entries[index].draft=nil; entries[index].dotNote="Dot’s draft was discarded after 14 days unused."; count += 1
        }
        return count
    }
    /// The owner's Discard Draft.
    public mutating func discardDraft(_ id:String) throws {
        guard let index=entries.firstIndex(where:{$0.id == id}) else { throw BridgeFailure("That message is no longer in Mail Dot's list.") }
        entries[index].outcome = .noDraft; entries[index].draft=nil; entries[index].dotNote="You discarded Dot’s draft."
        entries[index].openReplyWhenDrafted=nil; entries[index].openReplyRequestedAt=nil; entries[index].openReplyFailed=nil
    }
    /// Messages whose flag in Mail is not yet what their state calls for, oldest first.
    public func flagsDue(limit:Int=3) -> [MailTriageEntry] {
        Array(entries.filter{$0.messageID != nil && $0.ownerFlagged != true && flagIndex(for:$0.listMark) != ($0.appliedFlag ?? -1)}.prefix(limit))
    }
    /// Messages to look at again for a reply the owner sent from Mail itself, at most every five minutes.
    public func replyChecksDue(now:Date=Date(),limit:Int=2) -> [MailTriageEntry] {
        Array(entries.filter{[.drafted,.needsGuidance,.noDraft,.failed].contains($0.outcome) && $0.messageID != nil && now.timeIntervalSince($0.checkedRepliedAt ?? .distantPast) > 300}.prefix(limit))
    }
    /// What Mail's scripting reported after Mail Dot set or looked at a message's flag.
    public mutating func noteFlag(_ id:String,applied:Int?,ownerFlagged:Bool,replied:Bool,now:Date=Date()) {
        guard let index=entries.firstIndex(where:{$0.id == id}) else { return }
        entries[index].checkedRepliedAt=now
        if ownerFlagged { entries[index].ownerFlagged=true }
        if let applied { entries[index].appliedFlag=applied }
        if replied,entries[index].outcome != .skipped { entries[index].outcome = .replied; entries[index].draft=nil }
    }
    /// Mail's flag index for each mark: the colours the owner chose, or Mail Dot's defaults.
    /// Optional so that lists saved before it existed still load.
    public var flagColors:[String:Int]?
    public func flagIndex(for mark:MailListMark) -> Int {
        guard mark != .none else { return -1 }
        return flagColors?[mark.rawValue] ?? mark.defaultFlagIndex
    }
    /// The entry for the message with this Message-ID, if Mail Dot saw it arrive.
    public func entry(forMessageID id:String) -> MailTriageEntry? {
        guard let wanted=MailMessageIdentity.normalized(id) else { return nil }
        return entries.last{$0.messageID == wanted}
    }
    /// The owner asked for a draft in a reply's panel: the message shows Drafting until Dot's draft arrives.
    public mutating func noteReplyPanelDrafting(messageID id:String,now:Date=Date()) {
        guard let wanted=MailMessageIdentity.normalized(id),let index=entries.lastIndex(where:{$0.messageID == wanted}),
              entries[index].outcome != .replied else { return }
        entries[index].replyPanelDraftingAt=now
    }
    /// Whether Dot is already drafting the message with this Message-ID, for as long as Dot may take to answer. Every
    /// reply request checks this first, so that a reply opened meanwhile waits for that draft or question instead of
    /// asking Dot a second time (owner decision, 15 November 2026: two runs on one message, 13 seconds apart).
    public func dotIsDrafting(messageID id:String,now:Date=Date()) -> Bool {
        guard let entry=entry(forMessageID:id),[.pending,.asked].contains(entry.outcome) else { return false }
        return now.timeIntervalSince(entry.askedAt ?? entry.openedAt ?? entry.seenAt) < Self.answerLimit
    }
    /// The owner told Dot how to write the reply while Dot was still drafting the message on its own: that draft is
    /// superseded (owner decision, 15 November 2026). Returns the request to withdraw, so that its answer is not taken;
    /// the draft written with the owner's words is recorded on the message when it comes.
    public mutating func supersedeDrafting(messageID id:String) -> String? {
        guard let wanted=MailMessageIdentity.normalized(id),let index=entries.lastIndex(where:{$0.messageID == wanted}),
              [.pending,.asked].contains(entries[index].outcome) else { return nil }
        let request=entries[index].requestID
        entries[index].outcome = .held; entries[index].heldAsOlder=nil; entries[index].requestID=nil
        entries[index].dotNote=nil; entries[index].openReplyWhenDrafted=nil
        return request
    }
    /// The draft Dot wrote for the message with this Message-ID, if it wrote one.
    public func draft(forMessageID id:String) -> MailTriageEntry? {
        guard let wanted=MailMessageIdentity.normalized(id) else { return nil }
        return entries.last{$0.messageID == wanted && $0.outcome == .drafted && $0.draft != nil}
    }
}

public struct MailTriageStore:Sendable {
    public let directory:URL
    public init(bridgeDirectory:URL) { directory=bridgeDirectory.appendingPathComponent("Triage",isDirectory:true) }
    public static func shared() throws -> Self { try Self(bridgeDirectory:BridgeStore.shared().directory) }
    public func read() throws -> MailTriageState { try locked { try load() } }
    public func transaction<T>(_ body:(inout MailTriageState) throws -> T) throws -> T {
        try locked {
            var state=try load(); let result=try body(&state)
            let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            let data=try encoder.encode(state)
            guard data.count <= 2_097_152 else { throw BridgeFailure("Mail Dot's list of arriving mail exceeds 2 MiB.") }
            let temporary=directory.appendingPathComponent("triage-\(UUID().uuidString).tmp")
            let fd=Darwin.open(temporary.path,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0o600)
            guard fd >= 0 else { throw BridgeFailure("Cannot create Mail Dot's list of arriving mail.") }
            let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            defer { try? handle.close(); try? FileManager.default.removeItem(at:temporary) }
            try handle.write(contentsOf:data); try handle.synchronize()
            guard Darwin.rename(temporary.path,directory.appendingPathComponent("triage.json").path) == 0 else { throw BridgeFailure("Cannot save Mail Dot's list of arriving mail.") }
            return result
        }
    }
    private func load() throws -> MailTriageState {
        let url=directory.appendingPathComponent("triage.json"); var info=stat()
        if lstat(url.path,&info) != 0 {
            if errno == ENOENT { return MailTriageState() }
            throw BridgeFailure("Cannot inspect Mail Dot's list of arriving mail.")
        }
        guard info.st_mode & S_IFMT == S_IFREG,info.st_size <= 2_097_152 else { throw BridgeFailure("Mail Dot's list of arriving mail is not a bounded regular file.") }
        let decoder=JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MailTriageState.self,from:Data(contentsOf:url))
    }
    private func locked<T>(_ body:() throws -> T) throws -> T {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd=Darwin.open(directory.appendingPathComponent("triage.lock").path,O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw BridgeFailure("Cannot open the lock for Mail Dot's list of arriving mail.") }
        defer { _ = triageFileLock(fd,LOCK_UN); Darwin.close(fd) }
        guard triageFileLock(fd,LOCK_EX) == 0 else { throw BridgeFailure("Cannot lock Mail Dot's list of arriving mail.") }
        return try body()
    }
}

/// Which messages carry a Mail Dot flag in Mail's list: only those that need the owner. A flag is the one
/// icon an extension can place on a message in the list; the owner renames each flag colour in Mail's
/// sidebar, so the flag reads, for example, "Dot: draft ready". Everything else carries no flag.
public enum MailListMark:String,Codable,Sendable,CaseIterable {
    case none,draftReady,needsGuidance,couldNotCheck
    /// Mail's flag index: 0 red, 1 orange, 2 yellow, 3 green, 4 blue, 5 purple, 6 gray.
    var defaultFlagIndex:Int {
        switch self {
        case .draftReady:5
        case .needsGuidance:4
        case .couldNotCheck:6
        case .none:-1
        }
    }
    /// The name the owner gives that flag colour in Mail's sidebar.
    public var flagName:String {
        switch self {
        case .draftReady:"Dot: draft ready"
        case .needsGuidance:"Dot: needs guidance"
        case .couldNotCheck:"Dot: could not check"
        case .none:""
        }
    }
}

/// Build 82 coloured rows; kept so that its saved lists still load. Purple and red
/// are left for the owner. Mail cannot show an icon or hover text in the list.
public enum MailListColor:String,Codable,Sendable,CaseIterable { case none,blue,green,orange,yellow,gray
    public var meaning:String {
        switch self {
        case .blue:"Dot is checking the message or writing a draft"
        case .green:"Dot’s draft is ready"
        case .orange:"Dot needs your guidance before it can draft"
        case .yellow:"Dot could not check the message"
        case .gray:"You have replied"
        case .none:"Skipped, or no reply needed"
        }
    }
}

extension MailTriageEntry {
    public var listMark:MailListMark {
        switch outcome {
        case .drafted:.draftReady
        case .needsGuidance:.needsGuidance
        case .failed:.couldNotCheck
        case .pending,.asked,.skipped,.held,.noDraft,.replied:.none
        }
    }
    public var listColor:MailListColor {
        switch outcome {
        case .pending,.asked:.blue
        case .drafted:.green
        case .needsGuidance:.orange
        case .failed:.yellow
        case .replied:.gray
        case .skipped,.held,.noDraft:.none
        }
    }
    /// One line for the list in Mail Dot's settings, in the language of the owner's Mac. The stored reason
    /// stays in English for Dot and is translated only for display, when it is one of the fixed reasons.
    public var stateLine:String {
        switch outcome {
        case .skipped where reason == MailTriage.copiedOnlyReason:
            // Owner request, 13 November 2026: say why Dot has not read it, and what brings Dot in.
            String(localized:"You were only copied, so Dot hasn’t read this message. Press Draft a Reply if you want Dot’s draft and report.")
        case .skipped:String(localized:"Skipped: \(String(localized:String.LocalizationValue(reason)))")
        case .held:heldAsOlder == true ? String(localized:"Not offered: it arrived before automatic replies were turned on.") : String(localized:"Not offered: automatic drafting was off.")
        case .pending:String(localized:"Waiting to ask Dot.")
        case .asked:String(localized:"Dot is checking it.")
        case .noDraft:String(localized:"No reply needed")+(dotNote.map{": "+$0.replacingOccurrences(of:"No reply needed:",with:"").trimmingCharacters(in:.whitespaces)} ?? ".")
        case .drafted:String(localized:"Dot drafted a reply.")
        case .needsGuidance:String(localized:"Dot asks: ")+(dotNote ?? String(localized:"how to reply."))
        case .replied:String(localized:"You replied.")
        case .failed:String(localized:"Dot could not check it")+(dotNote.map{": "+$0} ?? ".")
        }
    }
}

extension MailTriageState {
    /// The owner opened a message they were only copied on, and its text names them: it is offered to Dot
    /// like one sent to them. Returns whether anything changed.
    @discardableResult public mutating func noteMention(messageID:String,sender:String) -> Bool {
        guard let wanted=MailMessageIdentity.normalized(messageID),
              let index=entries.firstIndex(where:{ $0.messageID.flatMap(MailMessageIdentity.normalized) == wanted }),
              entries[index].outcome == .skipped,entries[index].reason == MailTriage.copiedOnlyReason else { return false }
        entries[index].outcome = .pending
        entries[index].reason="\(entries[index].senderName ?? sender) copied you on this message, and it mentions you by name."
        return true
    }
}

extension MailSettings {
    /// The names a message would call the owner by, for noticing a Cc message that addresses them: the names
    /// the owner set, or else those registered on their accounts in Mail and as the Mac's user, whole and in
    /// parts. Nothing about any one person is built in: Mail Dot is meant for others to use too (owner request,
    /// 13 November 2026).
    public var effectiveOwnerNames:[String] {
        if let ownerNames,!ownerNames.isEmpty { return ownerNames }
        return OwnerNames.derive(from:nativeAccounts.compactMap(\.fullName)+[macUserFullName].compactMap{$0})
    }
    /// Every address the owner receives mail at, from the accounts Mail Dot knows.
    public var ownerAddresses:Set<String> {
        Set((nativeAccounts.flatMap(\.addresses)+connections.map(\.email)).map{$0.lowercased()})
    }
}

/// The names a person goes by, from their registered full names: each whole name and each part long enough
/// to be a name (not an initial), without duplicates. "Hanako Tanaka" gives Hanako Tanaka, Hanako, Tanaka;
/// "田中 花子" gives 田中 花子, 田中, 花子.
public enum OwnerNames {
    public static func derive(from fullNames:[String]) -> [String] {
        var names:[String]=[]
        func add(_ value:String) {
            let name=value.trimmingCharacters(in:CharacterSet.whitespaces.union(CharacterSet(charactersIn:".,")))
            let latin=name.unicodeScalars.allSatisfy{ $0.isASCII }
            guard name.count >= (latin ? 3 : 2),!names.contains(where:{ $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
            names.append(name)
        }
        for full in fullNames {
            add(full)
            full.split(whereSeparator:{ $0 == " " || $0 == "\u{3000}" }).map(String.init).forEach(add)
        }
        return names
    }
}
