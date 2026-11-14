import Foundation

/// Where a reply the owner asked Dot to draft stands, for showing outside the Mail Dot panel: in a
/// notification, and on the reply window itself. The panel shows the same states in its own way.
public enum ReplyIndicator: Equatable, Sendable {
    /// Dot is writing the draft, or changing it after the owner's direction or answer.
    case drafting(revising: Bool)
    /// Dot's draft is in the panel, waiting for the owner to choose what becomes of it.
    case draftReady(preview: String, revision: Int)
    /// Dot cannot draft without the owner's answer.
    case question(text: String, answers: [String])
    /// Dot's reply is in the message and the owner must confirm before it is sent.
    case confirmSend
    /// Dot's reply is in the message, saved; nothing more is asked of the owner.
    case placed

    /// Nil when there is nothing to show: no request from the panel, the message set aside, or not yet read.
    public init?(_ context: ReplyContext) {
        guard let request = context.ownerRequest, !request.ignored, let snapshot = context.snapshot else { return nil }
        if context.sendConfirmation != nil { self = .confirmSend; return }
        if let asked = context.dotQuestion, !asked.isEmpty {
            let parsed = BridgeCoordinator.answers(in: asked)
            self = .question(text: parsed.question, answers: parsed.answers); return
        }
        guard let proposal = context.proposal else { self = .drafting(revising: false); return }
        if request.askedAt > (context.lastDotUpdate ?? .distantPast) { self = .drafting(revising: true); return }
        if proposal.appliedFingerprint == snapshot.fingerprint { self = .placed; return }
        let flat = proposal.body.split(whereSeparator: \.isNewline).joined(separator: " ")
        self = .draftReady(preview: flat.count > 180 ? String(flat.prefix(177)) + "…" : flat, revision: proposal.revision)
    }

    /// Changes whenever the owner should be told again: a new draft, a new question, a new round of drafting.
    public func key(for context: ReplyContext) -> String {
        switch self {
        case .drafting: "drafting:\(Int(context.ownerRequest?.askedAt.timeIntervalSince1970 ?? 0))"
        case .draftReady(_, let revision): "ready:\(revision)"
        case .question(let text, _): "question:\(text.count):\(text.prefix(48))"
        case .confirmSend: "confirm:\(context.sendConfirmation?.id ?? "")"
        case .placed: "placed:\(context.proposal?.revision ?? 0)"
        }
    }
    /// A few words for the owner. `who` is whom the reply is to.
    public func title(to who: String?) -> String {
        let to = who.map { " to \($0)" } ?? ""
        switch self {
        case .drafting(let revising): return revising ? "Dot is revising your reply\(to)" : "Dot is drafting your reply\(to)"
        case .draftReady: return "Dot’s draft is ready: reply\(to)"
        case .question: return "Dot needs to know, for your reply\(to)"
        case .confirmSend: return "Confirm to send your reply\(to)"
        case .placed: return "Dot’s reply is in your message\(to)"
        }
    }
    /// The words shown on the reply window itself, where Mail lets an extension mark the recipient's address.
    public var mark: String {
        switch self {
        case .drafting(let revising): revising ? "Mail Dot: Dot is revising your reply." : "Mail Dot: Dot is drafting your reply."
        case .draftReady: "Mail Dot: Dot’s draft is ready. Open Mail Dot in the toolbar to insert, save, send or ignore it."
        case .question(let text, _): "Mail Dot: Dot needs to know before it can draft. \(text) Open Mail Dot in the toolbar to answer."
        case .confirmSend: "Mail Dot: Dot’s reply is in this message. Confirm in Mail Dot to send it."
        case .placed: "Mail Dot: Dot’s reply is in this message. Nothing was sent."
        }
    }
    /// Whether the owner has something to do, as opposed to something to wait for.
    public var needsOwner: Bool {
        switch self {
        case .drafting, .placed: false
        case .draftReady, .question, .confirmSend: true
        }
    }
}

extension ReplyContext {
    /// Whom the reply is to, by name where Mail gave one.
    public var replyingTo: String? {
        let original = originalSender.trimmingCharacters(in: .whitespaces)
        // A draft reopened from Drafts names the owner as its "original"; then the recipient is meant.
        let fromOwner = MailMessageIdentity.address(in: original).map { $0 == MailMessageIdentity.address(in: envelope.sender) } ?? false
        if !original.isEmpty && !fromOwner {
            let name = original.split(separator: "<").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) } ?? ""
            return name.isEmpty ? original.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) : name
        }
        return envelope.to.first
    }
}
