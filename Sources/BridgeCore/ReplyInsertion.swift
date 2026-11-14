import Foundation

/// Placing Dot's reply in a message without disturbing what is already there. Dot's text goes at the very
/// top, above the quoted mail, which stays exactly as Mail has it: its formatting, its quoting and every
/// character of it. Nothing below the reply is retyped.
public enum ReplyInsertion {
    private static func plain(_ line: Substring) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        while text.hasPrefix(">") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Dot's text without any of the thread it repeated. Dot is asked for the reply alone, but an older
    /// copy of its instructions tells it to keep the quoted mail, so a repeated thread is cut off here.
    /// The cut is made only where two consecutive lines of the message as it stands in Mail appear
    /// consecutively in Dot's text (one line is enough when it is long), so a closing line that happens to
    /// match a line of the quoted mail is never mistaken for it.
    public static func replyOnly(_ proposal: String, above remainder: String) -> String {
        let existing = remainder.split(whereSeparator: \.isNewline).map(plain).filter { !$0.isEmpty }
        let lines = proposal.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let shown = lines.enumerated().compactMap { index, line -> (Int, String)? in
            let text = plain(line); return text.isEmpty ? nil : (index, text)
        }
        var cut: Int?
        for (position, entry) in shown.enumerated() where cut == nil {
            for anchor in existing.indices.prefix(6) where existing[anchor] == entry.1 {
                let following = anchor + 1 < existing.count ? existing[anchor + 1] : nil
                let next = position + 1 < shown.count ? shown[position + 1].1 : nil
                if let following { if following == next { cut = entry.0; break } }
                else if entry.1.count >= 20 { cut = entry.0; break }
            }
        }
        guard let cut else { return trimmedEnd(proposal) }
        let kept = trimmedEnd(lines[..<cut].joined(separator: "\n"))
        return kept.isEmpty ? trimmedEnd(proposal) : kept
    }
    private static func trimmedEnd(_ text: String) -> String {
        var result = Substring(text)
        while let last = result.last, last.isWhitespace || last.isNewline { result = result.dropLast() }
        return String(result)
    }

    /// What is typed at the top: the reply, and blank space after it only if the message does not already
    /// begin with it. A new reply in Mail begins with an empty line and a blank line before the quoted mail.
    public static func typed(reply: String, above remainder: String) -> String {
        let text = trimmedEnd(reply)
        if remainder.isEmpty || remainder.hasPrefix("\n\n") { return text }
        return text + (remainder.hasPrefix("\n") ? "\n" : "\n\n")
    }
}
