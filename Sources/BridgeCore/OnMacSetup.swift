import Foundation

/// Mail Dot's entry in ChatGPT's local tools (release review, 14 November 2026). A task that Dot or Codex starts on
/// this Mac reads `~/.codex/config.toml` and starts each helper listed under `mcp_servers`; one entry there is all
/// that the on-Mac route needs in place of the tunnel, its key and the ChatGPT plugin. Mail Dot writes the entry
/// itself, naming this copy of its helper. Everything else in the file is left exactly as it was.
public enum CodexRegistration {
    public static let name = "maildot"
    private static let header = "[mcp_servers.\(name)]"

    /// The helper path the file names for Mail Dot, or nil when it has no entry.
    public static func registeredPath(in contents: String) -> String? {
        guard let table = tableLines(in: contents) else { return nil }
        for line in contents.components(separatedBy: "\n")[table] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("command"), let equals = trimmed.firstIndex(of: "=") else { continue }
            guard trimmed[..<equals].trimmingCharacters(in: .whitespaces) == "command" else { continue }
            return unquoted(String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// The file's contents with Mail Dot's entry naming `agentPath`, or nil when it already does. An existing entry
    /// keeps its other lines; a missing one is added at the end. `contents` is nil when there is no file yet.
    public static func registering(agentPath: String, in contents: String?) -> String? {
        let command = "command = \(quoted(agentPath))"
        guard let contents, !contents.isEmpty else { return "\(header)\n\(command)\n" }
        if registeredPath(in: contents) == agentPath { return nil }
        var lines = contents.components(separatedBy: "\n")
        if let table = tableLines(in: contents) {
            if let index = lines[table].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("command") }) {
                lines[index] = command
            } else {
                lines.insert(command, at: table.lowerBound)
            }
            return lines.joined(separator: "\n")
        }
        return contents + (contents.hasSuffix("\n") ? "\n" : "\n\n") + "\(header)\n\(command)\n"
    }

    /// The lines of Mail Dot's own table, after its header and before the next table of any name.
    private static func tableLines(in contents: String) -> Range<Int>? {
        let lines = contents.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else { return nil }
        let end = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) ?? lines.count
        return (start + 1)..<end
    }
    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    private static func unquoted(_ text: String) -> String? {
        if text.hasPrefix("'"), text.hasSuffix("'"), text.count >= 2 { return String(text.dropFirst().dropLast()) }
        guard text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 else { return nil }
        return String(text.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
}

/// Whether a worker on this Mac is taking Mail Dot's requests, and what Mail Dot does when none is (release review,
/// 14 November 2026). Dot is asked to listen through the ChatGPT app; asking again is spaced out and then stops, so a
/// Dot that cannot listen is not asked all day. A request left waiting meanwhile goes to a task Mail Dot starts.
public enum ListenerWatch {
    /// A listener that has neither asked for work nor reported on any for this long is gone.
    public static let gone: TimeInterval = 180
    /// A request no worker has taken for this long is handed to a task.
    public static let patience: TimeInterval = 60
    /// Asked this many times without a listener appearing, Mail Dot stops asking by itself.
    public static let askLimit = 3

    public struct Input: Sendable {
        public var now = Date()
        /// When a listener last asked for work.
        public var listenerSeenAt: Date?
        /// The latest moment any worker took or reported on a request.
        public var lastClaimAt: Date?
        /// When Mail Dot last asked Dot to listen, and how many times since a listener was last present.
        public var lastAskedAt: Date?
        public var asks = 0
        /// The oldest request no worker holds, by when it was made.
        public var oldestWaiting: Date?
        /// The ChatGPT app is open and Mail Dot may type into it.
        public var canReachDot = false
        /// A task can be started on this Mac in Dot's place.
        public var canStartTask = false
        public init() {}
    }
    public enum Step: Equatable, Sendable { case nothing, askDotToListen, startTask }

    public static func listening(_ input: Input) -> Bool {
        [input.listenerSeenAt, input.lastClaimAt].compactMap { $0 }.contains { input.now.timeIntervalSince($0) < gone }
    }
    /// How long after the last ask before the next: ten minutes, then twenty, then forty.
    public static func wait(afterAsks asks: Int) -> TimeInterval { 600 * pow(2, Double(max(asks, 1) - 1)) }

    public static func step(_ input: Input) -> Step {
        guard !listening(input) else { return .nothing }
        if input.canStartTask, let waiting = input.oldestWaiting, input.now.timeIntervalSince(waiting) > patience { return .startTask }
        guard input.canReachDot, input.asks < askLimit else { return .nothing }
        if let asked = input.lastAskedAt, input.now.timeIntervalSince(asked) < wait(afterAsks: input.asks) { return .nothing }
        return .askDotToListen
    }
}
