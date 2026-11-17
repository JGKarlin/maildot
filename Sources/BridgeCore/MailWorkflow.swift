import Foundation

/// Navigation and conversation requests only. Sending uses the separate native
/// review protocol; no Dot report can grant Mail permissions or mark a draft reviewed.
public enum MailWorkflowAction:String,Codable,Sendable {
    case status,needsInput,drafts,summarize,readFull,revise,compose
    /// The owner opened a voice call with Dot from Mail. Dot speaks first; nothing is read or written by the request itself.
    case call
    /// The owner answered, on the Mac, a question Dot left with ask_owner. The answer is theirs; it grants
    /// nothing beyond the question it answers.
    case answer
    /// The owner told Dot, in the Updates workbench, what to do about one update: an option chosen, a
    /// request to discuss, ignore or delete, or the confirmation to send a draft.
    case instruction
    /// The owner opened the Mail Dot panel on a reply in Mail, which asks Dot for a draft, or changed that
    /// request there: a direction, an answer to Dot's question, or setting the message aside.
    case reply
    /// Mail Dot found an essential message among arriving mail and asks Dot whether it needs a reply,
    /// and if so for the draft. Only messages the Mac judged essential are ever offered.
    case draftCheck
    /// The owner typed a drafting rule in Mail Dot's settings; Dot tidies its wording, which replaces it.
    case ruleCleanup
    /// The owner asked Dot a question about their mail from Mail Dot's ask bar; Dot searches and answers with citations.
    case ask
    /// Mail Dot confirms that Dot answers on this Mac; Dot reports Ready and does nothing else.
    case check
    /// The owner added or changed drafting notes for one correspondent; Dot polishes their wording, which replaces it.
    case noteCleanup
    var requiresItem:Bool { [.summarize,.readFull,.revise].contains(self) }
}
public enum MailWorkflowStage:String,Codable,Sendable { case pending,working,awaitingInput,ready,failed }
public enum MailWorkflowItemKind:String,Codable,Sendable { case needsInput,draft }

public struct MailWorkflowItem:Codable,Sendable,Identifiable {
    public var id:String
    public var accountID:String
    public var sourceID:String
    public var revision:Int
    public var kind:MailWorkflowItemKind
    public var subject:String
    public var summary:String
    public var question:String?
    public var checkedAt:Date
    /// A reported association, never sufficient authorization for a native action.
    public var replyContextID:String?
    public init(id:String,accountID:String,sourceID:String,revision:Int,kind:MailWorkflowItemKind,subject:String,summary:String,question:String?=nil,checkedAt:Date,replyContextID:String?=nil) {
        self.id=id; self.accountID=accountID; self.sourceID=sourceID; self.revision=revision
        self.kind=kind; self.subject=subject; self.summary=summary; self.question=question
        self.checkedAt=checkedAt; self.replyContextID=replyContextID
    }
}
/// Dot-reported complete text of the selected source/version, never native send authority.
public struct MailWorkflowReadback:Codable,Sendable {
    public var itemID:String
    public var accountID:String
    public var sourceID:String
    public var itemRevision:Int
    public var text:String
    public init(itemID:String,accountID:String,sourceID:String,itemRevision:Int,text:String) {
        self.itemID=itemID; self.accountID=accountID; self.sourceID=sourceID
        self.itemRevision=itemRevision; self.text=text
    }
}
/// A proposed new message, not proof that a native Mail draft exists.
public struct MailWorkflowComposition:Codable,Sendable {
    public var accountID:String
    public var sender:String
    public var to:[String]
    public var cc:[String]
    public var bcc:[String]
    public var subject:String
    public var body:String
    /// The owner's answer to "draft and save, or draft and send?". Optional only so that proposals stored
    /// by earlier builds still load; a new proposal without it is refused.
    public var delivery:ProposalDelivery?
    public init(accountID:String,sender:String,to:[String],cc:[String],bcc:[String],subject:String,body:String,delivery:ProposalDelivery?=nil) {
        self.accountID=accountID; self.sender=sender; self.to=to; self.cc=cc; self.bcc=bcc
        self.subject=subject; self.body=body; self.delivery=delivery
    }
    public func validate() throws {
        let recipients=to+cc+bcc
        guard !accountID.isEmpty,accountID.utf8.count <= 1024,Self.address(sender),!to.isEmpty,
              recipients.count <= 100,recipients.allSatisfy(Self.address),
              Set(recipients.map(MailDraft.address)).count == recipients.count,
              !subject.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,subject.utf8.count <= 2048,
              !subject.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              !body.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,body.utf8.count <= 65_536 else {
            throw BridgeFailure("Provide a selected sender, resolved email addresses, subject and complete plain-text body within the prototype limits.")
        }
    }
    private static func address(_ value:String)->Bool {
        let parts=value.split(separator:"@",omittingEmptySubsequences:false)
        guard value.utf8.count <= 254,parts.count == 2,parts[0].utf8.count <= 64 else { return false }
        let letters="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let atom=letters+"!#$%&'*+-/=?^_`{|}~"
        let local=parts[0].split(separator:".",omittingEmptySubsequences:false)
        let domain=parts[1].split(separator:".",omittingEmptySubsequences:false)
        return local.allSatisfy{!$0.isEmpty && $0.allSatisfy{atom.contains($0)}}
            && domain.count >= 2 && domain.allSatisfy { label in
                !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                    && label.allSatisfy{(letters+"-").contains($0)}
            }
    }
}
public struct MailWorkflowReport:Codable,Sendable {
    public var requestID:String
    public var expectedRevision:Int
    public var stage:MailWorkflowStage
    public var summary:String
    public var items:[MailWorkflowItem]
    public var question:String?
    public var readback:MailWorkflowReadback?
    public var composition:MailWorkflowComposition?
    /// For an answer to the owner's question: what was searched in each account asked about.
    public var coverage:[AskDot.Coverage]?
    /// For an answer to the owner's question: the messages it cites.
    public var sources:[AskDot.Source]?
    public init(requestID:String,expectedRevision:Int,stage:MailWorkflowStage,summary:String,items:[MailWorkflowItem],question:String?=nil) {
        self.requestID=requestID; self.expectedRevision=expectedRevision; self.stage=stage
        self.summary=summary; self.items=items; self.question=question
    }
}
/// What happened when Mail Dot asked the ChatGPT app to open the call. `started` means the app was told to,
/// not that Dot answered; Dot taking up the request is the evidence of that.
public struct MailWorkflowCallLaunch:Codable,Sendable,Equatable {
    public let started:Bool
    public let note:String?
    public let at:Date
    /// Whether Mail Dot entered the purpose of the call into the call itself, as a message to Dot.
    /// Absent in launches recorded before build 65.
    public let prompted:Bool?
    public init(started:Bool,note:String?,at:Date,prompted:Bool?=nil) { self.started=started; self.note=note; self.at=at; self.prompted=prompted }
}
public struct MailWorkflowRequest:Codable,Sendable,Identifiable {
    /// How long Dot is not told of a call request while the call is being opened.
    public static let callHold:TimeInterval=30
    /// How long after the call was opened Dot is told, so the event arrives in a connected call.
    public static let callSettle:TimeInterval=6
    /// A request older than this never opens a call: the microphone must not come on long after the press.
    public static let callLaunchWindow:TimeInterval=60
    public let id:String
    public let action:MailWorkflowAction
    public let accountIDs:[String]
    public let itemID:String?
    public let itemRevision:Int?
    public let sourceID:String?
    /// The owner asked to hear this report: Mail Dot reads Dot's summary aloud when it arrives.
    public let spoken:Bool?
    /// For a call: the shared message it is about, or Dot's question it answers. Associations only, never authority.
    public let contextID:String?
    public let questionID:String?
    /// For an instruction: what the owner decided about which update.
    public let instruction:MailUpdateInstruction?
    /// For a draft check: the arriving message, in Mail Dot's list of arriving mail.
    public let triageID:String?
    /// For ruleCleanup: the drafting rule to tidy, by its id in Mail Dot's settings.
    public let ruleID:String?
    /// For noteCleanup: the correspondent whose drafting notes Dot polishes, by address.
    public let noteAddress:String?
    public let createdAt:Date
    public private(set) var revision=0
    public private(set) var stage=MailWorkflowStage.pending
    public private(set) var report:MailWorkflowReport?
    public private(set) var observedItems:[MailWorkflowItem]=[]
    public var event=BridgeEvent()
    /// How many times the request was announced to Dot again because no session started on it (see EventHub).
    public var redeliveries:Int?
    /// The worker handling this request (release review, 14 November 2026). A listener on the Mac and Dot in the cloud
    /// can both take requests; the first to take one holds it for ten minutes and the other leaves it alone.
    public struct Claim:Codable,Sendable,Equatable { public var worker:String; public var at:Date }
    public private(set) var claim:Claim?
    public static let claimLease:TimeInterval=600
    /// The actions Mail Dot starts on its own, or that tidy what the owner typed: everything else is the owner's own
    /// request and goes first.
    public static let backgroundActions:Set<MailWorkflowAction>=[.draftCheck,.ruleCleanup,.noteCleanup]
    /// How long an owner's unstarted request holds automatic ones back. A request no one could receive is closed
    /// after fifteen minutes in any case (EventHub.undeliveredLimit), so this cannot hold drafting back for good.
    public static let ownerPriorityWindow:TimeInterval=900
    public func hasActiveClaim(now:Date=Date()) -> Bool {
        guard let claim,![.ready,.failed].contains(stage) else { return false }
        return now.timeIntervalSince(claim.at) < Self.claimLease
    }
    public func claimed(byAnotherThan worker:String,now:Date=Date()) -> Bool { hasActiveClaim(now:now) && claim?.worker != worker }
    mutating func take(worker:String,now:Date) { claim=Claim(worker:worker,at:now) }
    public private(set) var callLaunch:MailWorkflowCallLaunch?
    /// A call, or a report the owner asked to hear: both need the call open.
    /// A call, and a spoken report: for both the request is spoken to Dot inside a call (the owner's
    /// design of 11 November 2026, after it was shown that the voice answers what it hears and nothing else).
    /// If a spoken report cannot be delivered that way, it is asked of Dot in writing and read aloud here.
    public var opensCall:Bool { action == .call || spoken == true }
    /// How long after the press a report may still be read aloud.
    public static let speakWindow:TimeInterval=600
    public private(set) var spokenAloudAt:Date?
    mutating func markSpoken(now:Date) { spokenAloudAt=now }
    /// The event wakes a background run of Dot, not the voice in a call. Once the purpose has been entered
    /// into the call itself, sending the event too would have two Dots answer one request.
    public var needsEventDelivery:Bool { callLaunch?.prompted != true }
    mutating func recordCallLaunch(started:Bool,note:String?,prompted:Bool,now:Date) {
        callLaunch=MailWorkflowCallLaunch(started:started,note:note,at:now,prompted:prompted)
        event.nextAttemptAt=started ? now.addingTimeInterval(Self.callSettle) : now
    }

    public init(action:MailWorkflowAction,accountIDs:[String],itemID:String?=nil,itemRevision:Int?=nil,sourceID:String?=nil,spoken:Bool?=nil,contextID:String?=nil,questionID:String?=nil,instruction:MailUpdateInstruction?=nil,triageID:String?=nil,ruleID:String?=nil,noteAddress:String?=nil,createdAt:Date=Date()) throws {
        id=UUID().uuidString; self.action=action; self.accountIDs=accountIDs
        self.itemID=itemID; self.itemRevision=itemRevision; self.sourceID=sourceID
        self.spoken=spoken; self.contextID=contextID; self.questionID=questionID; self.instruction=instruction; self.triageID=triageID; self.ruleID=ruleID; self.noteAddress=noteAddress; self.createdAt=createdAt
        try validate()
    }
    public func validate() throws {
        // A check reads no mail, so it names no account: setup tests Dot before any account is linked.
        guard UUID(uuidString:id) != nil,revision >= 0,!accountIDs.isEmpty || action == .check,accountIDs.count <= 30,
              Set(accountIDs).count == accountIDs.count,accountIDs.allSatisfy({Self.text($0,limit:1024)}),
              action.requiresItem ? (itemID.map{Self.text($0,limit:512)} == true && (itemRevision ?? -1) >= 0 && sourceID.map{Self.text($0,limit:1024)} == true) : (itemID == nil && itemRevision == nil && sourceID == nil) else {
            throw BridgeFailure("Select linked accounts and a current item for this Mail Dot action.")
        }
        guard createdAt.timeIntervalSince1970.isFinite else { throw BridgeFailure("Invalid request date.") }
        guard spoken == nil || action == .status,
              contextID == nil || ([.call,.reply].contains(action) && UUID(uuidString:contextID!) != nil),
              action != .reply || contextID != nil,
              (action == .draftCheck) == (triageID.map{UUID(uuidString:$0) != nil} ?? false),
              (action == .ruleCleanup) == (ruleID.map{!$0.isEmpty && $0.utf8.count <= 64} ?? false),
              (action == .noteCleanup) == (noteAddress.map{$0.contains("@") && $0.utf8.count <= 320} ?? false),
              questionID == nil || ([.call,.answer].contains(action) && UUID(uuidString:questionID!) != nil),
              action != .answer || questionID != nil,(action == .instruction) == (instruction != nil) else {
            throw BridgeFailure("Only a call or a reply request names a message, only a call or an answer names a question, only an instruction carries one, and only a mail status report is spoken.")
        }
        try instruction?.validate()
        if let report {
            guard revision > 0,report.expectedRevision == revision-1,report.stage == stage else { throw BridgeFailure("Inconsistent saved workflow report.") }
            try validatePayload(report)
            try validatePayload(MailWorkflowReport(requestID:id,expectedRevision:revision,stage:.working,summary:"Observed item revisions",items:observedItems))
            guard report.items.allSatisfy({ current in observedItems.contains {
                $0.id == current.id && $0.accountID == current.accountID && $0.sourceID == current.sourceID && $0.revision == current.revision
            }}) else { throw BridgeFailure("Inconsistent saved item revision history.") }
        } else if revision != 0 || stage != .pending || !observedItems.isEmpty { throw BridgeFailure("Missing saved workflow report.") }
    }
    public mutating func accept(_ incoming:MailWorkflowReport) throws {
        try validate()
        guard ![.ready,.failed].contains(stage),incoming.expectedRevision == revision,revision < Int.max else {
            throw BridgeFailure("Dot's report is stale or this request is already complete.")
        }
        try validatePayload(incoming)
        // Legacy saved reports remain readable, but new successful full reads
        // must include complete text instead of silently returning a summary.
        guard action != .readFull || incoming.stage != .ready || incoming.readback != nil else {
            throw BridgeFailure("Read in full requires the complete selected text. Report a failure if it is unavailable.")
        }
        guard action != .compose || incoming.stage != .ready || incoming.composition != nil else {
            throw BridgeFailure("A ready new-email request needs the proposed sender, recipients, subject and body.")
        }
        var history=observedItems
        for item in incoming.items {
            if let index=history.firstIndex(where:{$0.id == item.id}) {
                let previous=history[index]
                guard item.accountID == previous.accountID,item.sourceID == previous.sourceID,item.revision >= previous.revision else {
                    throw BridgeFailure("Dot's response changed an item identity or moved its revision backward.")
                }
                history[index]=item
            } else { history.append(item) }
        }
        guard history.count <= 100 else { throw BridgeFailure("Refresh with a new request; this report has reached its item limit.") }
        observedItems=history
        report=incoming; stage=incoming.stage; revision += 1; event.reviewedAt=Date()
    }
    private func validatePayload(_ incoming:MailWorkflowReport) throws {
        guard incoming.requestID == id,incoming.stage != .pending,Self.text(incoming.summary,limit:16384),incoming.items.count <= 100,
              Set(incoming.items.map(\.id)).count == incoming.items.count,
              incoming.stage == .awaitingInput ? incoming.question.map({Self.text($0,limit:4096)}) == true : incoming.question == nil else {
            throw BridgeFailure("Dot's report is stale, incomplete or does not match this request.")
        }
        if let readback=incoming.readback {
            guard action == .readFull,incoming.stage == .ready,
                  accountIDs == [readback.accountID],readback.itemID == itemID,
                  readback.sourceID == sourceID,readback.itemRevision == itemRevision,
                  Self.text(readback.text,limit:65_536) else {
                throw BridgeFailure("Full text must match the selected email and version and fit within 64 KiB.")
            }
        }
        if let composition=incoming.composition {
            guard action == .compose,incoming.stage == .ready,accountIDs.contains(composition.accountID) else {
                throw BridgeFailure("The new-email proposal does not match this action or its selected accounts.")
            }
            try composition.validate()
            guard composition.delivery != nil else {
                throw BridgeFailure("Ask the owner whether to draft and save or draft and send, then report the new message again with delivery set to save or send.")
            }
        }
        for item in incoming.items {
            guard accountIDs.contains(item.accountID),Self.text(item.id,limit:512),Self.text(item.sourceID,limit:1024),
                  item.revision >= 0,Self.text(item.subject,limit:2048),Self.text(item.summary,limit:8192),
                  item.question.map({Self.text($0,limit:4096)}) ?? true,
                  item.kind != .needsInput || item.question != nil,
                  item.replyContextID.map({UUID(uuidString:$0) != nil}) ?? true,
                  item.checkedAt.timeIntervalSince1970.isFinite,item.checkedAt <= Date().addingTimeInterval(60) else {
                throw BridgeFailure("Dot's queue item is invalid or outside the selected accounts.")
            }
            guard action != .drafts || item.kind == .draft,
                  action != .needsInput || item.kind == .needsInput,
                  !action.requiresItem || (item.id == itemID && item.sourceID == sourceID && (action == .revise ? item.revision >= (itemRevision ?? Int.max) : item.revision == itemRevision)) else {
                throw BridgeFailure("Dot's result does not match the requested list or selected item revision.")
            }
        }
    }
    private static func text(_ value:String,limit:Int)->Bool {
        !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && value.utf8.count <= limit
    }
}
