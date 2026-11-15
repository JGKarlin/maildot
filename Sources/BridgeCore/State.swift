import Foundation

/// The owner's answer to the question Dot must always ask before writing a mail.
public enum ProposalDelivery: String, Codable, Sendable {
    /// Place the text in the Mail draft and send nothing.
    case save
    /// Place the text in the Mail draft and ask the owner to confirm on the Mac. Only after that
    /// confirmation, and the native review it starts, can the mail be sent.
    case send
}

public struct DotProposal: Codable, Sendable {
    /// Absent only on a proposal stored by an earlier build. New proposals must carry it, and a mail
    /// without it cannot be sent.
    public var delivery: ProposalDelivery?
    public var body: String
    public var revision: Int
    public var snapshotRevision: Int
    public var appliedFingerprint: String?
    /// For a new message: the subject line Dot wrote with it. Mail Dot fills it into an empty Subject field.
    public var subject: String?
    /// What Dot did besides writing, one short line each (a calendar event added, a form updated), shown
    /// above the draft.
    public var tasksDone: [String]?
    public init(body: String, revision: Int, snapshotRevision: Int) {
        self.body = body; self.revision = revision; self.snapshotRevision = snapshotRevision
    }
}

public struct BridgeEvent: Codable, Sendable {
    public init() {}
    public var id = UUID().uuidString
    public var occurredAt = Date()
    public var receiptAt: Date?
    public var receipts: [String: Date] = [:]
    public var reviewedAt: Date?
    public var lastError: String?
    public var attempts = 0
    public var nextAttemptAt = Date()
}

/// A request for the owner's confirming act on the Mac. In "draft and send", nothing can be sent until the
/// owner presses Confirm for this exact draft; the press queues the native review, and only the review is
/// what a send consumes. Dot has no tool that can answer this request.
public struct SendConfirmation: Codable, Sendable, Equatable {
    public static let lifetime: TimeInterval = 600
    public let id: String
    public let fingerprint: String
    public let snapshotRevision: Int
    public let requestedAt: Date
    public init(fingerprint: String, snapshotRevision: Int, requestedAt: Date = .now) {
        id = UUID().uuidString; self.fingerprint = fingerprint; self.snapshotRevision = snapshotRevision; self.requestedAt = requestedAt
    }
}

public struct ReplyContext: Codable, Identifiable, Sendable {
    public var id: String
    public var envelope: MailDraft
    public var envelopeObservedAt: Date?
    public var originalSubject: String
    public var originalSender: String
    public var originalMessageID: String
    public var snapshot: MailDraft?
    /// Opaque reference to this helper's retained AX window/body. Never a Mail message ID.
    public var uiEditorToken:String?
    public var snapshotRevision = 0
    public var dotStatus = "Dot has not reported a status for this message."
    public var dotQuestion: String?
    public var lastDotUpdate: Date?
    public var proposal: DotProposal?
    public var review: SendReview?
    public var sendConfirmation: SendConfirmation?
    public var event: BridgeEvent?
    public var localStatus = "Share this message to make its context available to Dot."
    public var updatedAt = Date()
    /// What the owner asked for on the Mail Dot panel of this reply. Dot reads it with the message.
    public var ownerRequest: ReplyOwnerRequest?
    /// A new message the owner is writing, not a reply or a forward. Dot drafts it only once the owner has
    /// named a recipient and said what it should say, and writes its subject line too.
    public var newMessage: Bool?
    /// The opening of the owner's most recent message to this person, from Mail's Sent mailbox, and when it
    /// was sent: how the owner greets and writes to them, given to Dot so that it need not search for it.
    /// Files Dot finished for this reply, attached to the message on Insert or Save Draft.
    public var dotFiles: [ReplyFile]?
    /// The proposal revision whose files are already attached in the message.
    public var filesAttachedRevision: Int?
    /// With Dot's question on the panel: the reply Dot would write for each numbered answer, in order.
    public var answerDrafts: [String]?
    public var lastToCorrespondent: String?
    public var lastToCorrespondentAt: Date?
    public var isNewMessage: Bool { newMessage == true }
    /// What Mail Dot last typed at the top of the message: Dot's reply and any blank space after it. A later
    /// revision replaces exactly this, and nothing else of the message.
    public var insertedTop: String?
    /// When Dot last read this reply with the owner's request. A draft from a run that read it before the owner's latest
    /// words (Tell Dot, or an answer) is not taken: those words take priority (owner decision, 15 November 2026).
    public var dotReadAt: Date?
    /// The message below Dot's reply: all of it, when nothing has been inserted yet.
    public var bodyBelowReply: String? {
        guard let body = snapshot?.body else { return nil }
        if let top = insertedTop, body.hasPrefix(top) { return String(body.dropFirst(top.count)) }
        return body
    }

    /// The message as Dot is given it: its text once, in `snapshot`, not again in `envelope`; and without
    /// Mail Dot's own bookkeeping of the panel, which reaches Dot as the plain words of `owner_request`.
    public var forDot: ReplyContext {
        var value = self
        value.envelope.body = ""
        value.ownerRequest = nil
        value.insertedTop = nil
        value.answerDrafts = nil
        value.filesAttachedRevision = nil
        value.lastToCorrespondent = nil; value.lastToCorrespondentAt = nil
        value.dotReadAt = nil
        return value
    }

    public init(id: String, envelope: MailDraft, originalSubject: String = "", originalSender: String = "", originalMessageID: String = "") {
        self.id = id; self.envelope = envelope; self.originalSubject = originalSubject
        self.originalSender = originalSender; self.originalMessageID = originalMessageID
    }
}

public struct EventSubscription: Codable, Sendable {
    public var id: String
    public var callbackURL: String
    public var secret: String
    public var expiresAt: Date
    public var verifiedAt: Date
    public var eventName:String? = nil
    // IDs survive a Codable round trip through an older, still-loaded compose extension.
    public var resolvedEventName:String { eventName ?? (id.hasPrefix("sub_workflow_") ? "mail.workflow_requested" : (id.hasPrefix("sub_settings_") ? "mail.settings_requested" : "mail.reply_context_changed")) }
}

public struct NativeOperation: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var contextID: String
    public var kind: String
    public var reviewID: String?
    public var expectedFingerprint: String?
    public var expectedSnapshotRevision: Int?
    public var expectedEditorToken: String?
    public var proposalRevision: Int?
    /// For a send: the owner's instruction as Dot quoted it. A record of what authorized the send, not proof.
    public var approvalText: String?
    public var createdAt = Date()
    public var claimedAt: Date?
    public var result: String?
    public var error: String?
    public init(contextID: String, kind: String, reviewID: String? = nil) {
        self.contextID = contextID; self.kind = kind; self.reviewID = reviewID
    }

    /// How long a queued action may wait for the companion. It matches the send tool's own wait, so that
    /// nothing can run after Dot has been told there was no result.
    public static let maximumAge: TimeInterval = 20
    /// The refusal to record instead of running an action that waited too long, or nil if it may run.
    public func refusalIfTooOld(now: Date = .now) -> String? {
        now.timeIntervalSince(createdAt) > Self.maximumAge
            ? "This request waited too long and was not carried out. Nothing was changed or sent. Ask again if you still want it." : nil
    }
}

public struct BridgeState: Codable, Sendable {
    public var schemaVersion = 1
    public var activeContextID: String?
    public var contexts: [String: ReplyContext] = [:]
    public var subscriptions: [EventSubscription] = []
    public var operations: [NativeOperation] = []
    public var audit: [String] = []
    public var agentSeenAt: Date?
    public var agentInitializedAt: Date?
    public var mailPermissionStatus: Int32?
    public init() {}
}

extension BridgeState {
    /// Drops the least recently updated messages until at most `limit` remain. A message with an action
    /// still running, a send waiting for the owner's confirmation, or that is the one open now, is kept.
    /// Returns whether anything was dropped.
    @discardableResult public mutating func pruneContexts(keeping limit: Int) -> Bool {
        guard contexts.count > limit else { return false }
        let busy = Set(operations.filter { $0.result == nil && $0.error == nil }.map(\.contextID))
        let candidates = contexts.values
            .filter { !busy.contains($0.id) && $0.sendConfirmation == nil && $0.id != activeContextID }
            .sorted { $0.updatedAt < $1.updatedAt }
        var dropped = false
        for context in candidates where contexts.count > limit {
            contexts.removeValue(forKey: context.id)
            operations.removeAll { $0.contextID == context.id && ($0.result != nil || $0.error != nil) }
            dropped = true
        }
        return dropped
    }
}
