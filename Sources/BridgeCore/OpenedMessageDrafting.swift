import Foundation

/// Drafting when the owner opens a message (owner request, 12 November 2026): an important message the owner opens
/// in Mail, older mail included, is offered to Dot then, so that its draft is usually ready when the owner
/// presses Reply. The same filter, per-account switches, hourly limit and "already replied" check apply as
/// for arriving mail; only the rule that older mail is never drafted gives way, and only for a message the
/// owner opened.
extension MailTriage.Input {
    /// The input for the triage filter, from a message's raw RFC 822 data: its header block only, at most
    /// 64 KiB, so a large body costs nothing.
    public init(rawMessage data: Data, receivedAt: Date? = nil) {
        var headers: [String: [String]] = [:], current: String?
        let head = data.prefix(65_536)
        if let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) {
            for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                if line.isEmpty { break }
                if line.first == " " || line.first == "\t" {
                    if let current, var values = headers[current], !values.isEmpty { values[values.count - 1] += " " + line.trimmingCharacters(in: .whitespaces); headers[current] = values }
                    continue
                }
                guard let colon = line.firstIndex(of: ":") else { current = nil; continue }
                let key = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                headers[key, default: []].append(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
                current = key
            }
        }
        func addresses(_ key: String) -> [String] {
            (headers[key] ?? []).flatMap { Self.split($0) }.compactMap { MailMessageIdentity.address(in: MailMessageHeaders.decoded($0)) }
        }
        let parsed = MailMessageHeaders(rawMessage: data)
        self.init(messageID: parsed.messageID, senderAddress: parsed.senderAddress ?? "", senderName: parsed.senderName,
                  to: addresses("to"), cc: addresses("cc"), subject: parsed.subject ?? "", receivedAt: receivedAt ?? parsed.date, headers: headers)
    }
    /// An address header's entries, split at commas that are not inside quotes or angle brackets.
    static func split(_ value: String) -> [String] {
        var parts: [String] = [], current = "", quoted = false, angle = 0
        for character in value {
            switch character {
            case "\"": quoted.toggle(); current.append(character)
            case "<": angle += 1; current.append(character)
            case ">": angle = max(0, angle - 1); current.append(character)
            case "," where !quoted && angle == 0: parts.append(current); current = ""
            default: current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts
    }
}

extension MailTriageState {
    /// The owner opened this message in Mail. A message Mail Dot has not seen is judged by the filter now and
    /// recorded; one held only because it arrived before Automatic replies went on is made due again. Either
    /// way it is marked opened, which lets an older message be drafted. Returns whether anything changed.
    @discardableResult public mutating func noteOpened(_ input: MailTriage.Input, owner: Set<String>, automatic: Bool, now: Date = Date()) -> Bool {
        guard let id = input.messageID else { return false }
        if let index = entries.firstIndex(where: { $0.messageID == id }) {
            guard entries[index].openedAt == nil else { return false }
            entries[index].openedAt = now
            // Opening an older message no longer drafts it (owner request, 13 November 2026): automatic drafts are only
            // for mail that arrived after Auto replies was switched on; older mail is drafted when the owner asks.
            return true
        }
        let verdict = MailTriage.assess(input, owner: owner, correspondents: Set(correspondents), rules: rules)
        var entry = MailTriageEntry(messageID: input.messageID, sender: input.senderAddress, senderName: input.senderName, subject: input.subject,
                                    receivedAt: input.receivedAt, verdict: verdict, automatic: automatic)
        entry.recipients = (input.to + input.cc).filter(owner.contains)
        entry.openedAt = now
        return record(entry)
    }
}
