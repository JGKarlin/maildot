import Foundation

/// When Mail Dot may press Undo to put a reply back after its own typing failed. The rule is conservative:
/// Undo is pressed only while the body still shows nothing but Mail Dot's own typing, and never more often
/// than the pieces it typed plus a small margin. If Mail has merged its undo steps so that the original
/// text is skipped, restoration stops rather than undo the owner's earlier edits.
public enum UndoRestoration {
    public enum Step: Equatable, Sendable { case restored, press, stop }

    /// One step undoes at most one typed piece; two more allow for the selection and a merged first step.
    public static func maximumPresses(piecesTyped: Int) -> Int { max(0, piecesTyped) + 2 }

    /// `remainder` is the part of the message below Mail Dot's typing that it never touched: empty when the
    /// whole body was replaced, and the quoted mail when a reply was inserted at the top.
    public static func next(current: String, original: String, typed: String, remainder: String = "", presses: Int, piecesTyped: Int) -> Step {
        if Data(current.utf8) == Data(original.utf8) { return .restored }
        guard presses < maximumPresses(piecesTyped: piecesTyped) else { return .stop }
        var above = current
        if !remainder.isEmpty {
            // Only Mail Dot's own typing may stand above the untouched part.
            guard current.hasSuffix(remainder) else {
                let trimmed = remainder.hasSuffix("\n") ? String(remainder.dropLast()) : remainder
                guard current.hasSuffix(trimmed) else { return .stop }
                return typed.hasPrefix(String(current.dropLast(trimmed.count))) ? .press : .stop
            }
            above = String(current.dropLast(remainder.count))
            return typed.hasPrefix(above) ? .press : .stop
        }
        // Mail's editor may show one structural line break after the text.
        let shown = above.hasSuffix("\n") ? String(above.dropLast()) : above
        return typed.hasPrefix(shown) || typed.hasPrefix(above) ? .press : .stop
    }
}

/// What the owner is shown before confirming that a reply may be sent. The panel shows the whole text; a
/// notification is small, so it states the length and names both the beginning and the closing line.
public struct SendConfirmationSummary: Equatable, Sendable {
    public let recipients: String
    public let text: String
    public let characterCount: Int
    public let notificationBody: String

    public init(draft: MailDraft) {
        recipients = (draft.to + draft.cc + draft.bcc).joined(separator: ", ")
        text = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        characterCount = draft.body.count
        if text.count <= 240 { notificationBody = text; return }
        let closing = text.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let opening = String(text.prefix(140)).trimmingCharacters(in: .whitespacesAndNewlines)
        notificationBody = "\(draft.body.count) characters. Begins: \(opening)… Ends: \(String(closing.suffix(120)))"
    }
}
