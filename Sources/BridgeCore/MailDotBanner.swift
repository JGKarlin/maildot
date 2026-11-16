import Foundation

/// What Mail Dot's banner on a message says: the state alone, opened by a symbol that shows in color, and a
/// button worded for it (owner request, 12 November 2026). Mail lets an extension set only the banner's text and its
/// button's words; its icon and color are always Mail's, so the symbol is the only visual cue per state.
public enum MailDotBanner: Equatable, Sendable {
    case checking, drafting, draftReady, question, noReplyNeeded, couldNotCheck, replied, ccOnly, notDrafted, note
    /// Dot cannot take requests now (owner approval, 14 November 2026); the Mail Dot window names the reason.
    case dotUnavailable

    public var title: String {
        switch self {
        // While Dot decides whether a message needs a reply, it says Checking; Drafting only once a reply is being
        // written, because the owner asked for one or answered Dot (owner decision, 16 November 2026).
        case .checking: String(localized: "🔎 Checking")
        case .drafting: String(localized: "⏳ Drafting")
        case .draftReady: String(localized: "✅ Draft ready")
        case .question: String(localized: "❓ Question for you")
        case .noReplyNeeded: String(localized: "➖ No reply needed")
        case .couldNotCheck: String(localized: "⚠️ Dot couldn’t check")
        case .replied: String(localized: "↩️ Replied")
        case .ccOnly: String(localized: "👥 Cc only")
        case .notDrafted: String(localized: "⏸ Not drafted")
        case .note: String(localized: "ℹ️ Note from Dot")
        case .dotUnavailable: String(localized: "💤 Dot unavailable")
        }
    }
    /// The banner's one button opens the Mail Dot window, and says so in every state (owner request, 13 November 2026:
    /// "Answer" read as if it answered something).
    /// Mail draws the button from text alone, so its icon is a character (owner choice, 14 November 2026: a small window
    /// symbol, not Mail Dot's own icon, which the banner already shows at its left). Put before each language's wording.
    public var action: String { "⧉ " + String(localized: "Open Mail Dot") }
    /// For a message Mail Dot saw arrive or was opened: always a state, Replied once the owner has answered it.
    public init?(_ entry: MailTriageEntry) {
        // A message the owner wrote has no Mail Dot state at all (owner request, 16 November 2026).
        if entry.reason == MailTriage.sentByOwnerReason { return nil }
        // A draft the owner asked for in the reply panel is being written: Drafting, whatever the message said before.
        if let asked=entry.replyPanelDraftingAt,Date().timeIntervalSince(asked) < MailTriageState.answerLimit,![.drafted,.replied].contains(entry.outcome) {
            self = .drafting; return
        }
        switch entry.outcome {
        case .pending, .asked: self = entry.draftRequested == true || entry.ownerAnswer != nil ? .drafting : .checking
        case .drafted: self = .draftReady
        case .needsGuidance: self = .question
        case .noDraft: self = .noReplyNeeded
        case .failed: self = .couldNotCheck
        case .replied: self = .replied
        // Every message Mail Dot sees has a state (owner request, 13 November 2026). Those the Mac's filter does not
        // offer to Dot are decided here, without Dot: copied only, or not needing a reply at all.
        case .skipped: self = entry.reason == MailTriage.copiedOnlyReason ? .ccOnly : .noReplyNeeded
        // Not offered to Dot automatically: it arrived before Auto replies was on, or Auto replies is off.
        case .held: self = .notDrafted
        }
    }
    /// What the banner shows while Dot cannot take requests: a message waiting on Dot says so in place of
    /// "Drafting", and before Dot has ever answered on this Mac every message does. Other states stand.
    public func shown(_ availability: DotAvailability) -> MailDotBanner {
        switch availability {
        case .available: self
        case .notYetAnswered: .dotUnavailable
        case .notConnected, .silent: self == .drafting || self == .checking ? .dotUnavailable : self
        }
    }
    /// For one of Dot's scheduled reports on the message.
    public init(report status: MailUpdateStatus) {
        switch status {
        case .awaitingInstruction: self = .question
        case .draftedQueued: self = .draftReady
        // Answered, by Dot or by hand, reads Replied (owner request, 16 November 2026: not "Reply sent").
        case .draftedSent: self = .replied
        case .information: self = .note
        }
    }
}
