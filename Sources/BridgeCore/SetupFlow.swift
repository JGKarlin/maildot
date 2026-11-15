import Foundation

/// What Set Up Mail Dot shows (installer design review, 15 November 2026; the owner approved all twelve
/// recommendations). Four steps, each checked against the Mac. Accessibility comes first because with it Mail Dot
/// can open Mail's Settings at Extensions for the user; ChatGPT is no step of its own, since Mail Dot can verify
/// only that the app is there, and opens it itself when Dot is asked to connect.
public enum SetupFlow {
    public enum Step: Int, CaseIterable, Sendable { case accessibility, mail, extensionOn, connect }
    public struct Facts: Equatable, Sendable {
        public var accessibility = false
        public var mailAllowed = false
        public var extensionOn = false
        public var chatGPTInstalled = true
        /// Mail Dot has its connection and Dot is listening on it.
        public var connected = false
        public init() {}
    }
    public static func done(_ step: Step, _ facts: Facts, reports: [SetupThroughDot.Report] = []) -> Bool {
        switch step {
        case .accessibility: facts.accessibility
        case .mail: facts.mailAllowed
        case .extensionOn: facts.extensionOn
        case .connect: facts.connected || reports.contains { $0.step == "done" }
        }
    }
    /// The step that needs the user now: the first one not done.
    public static func current(_ facts: Facts, reports: [SetupThroughDot.Report] = []) -> Step? {
        Step.allCases.first { !done($0, facts, reports: reports) }
    }

    /// The stages Dot reports while it sets up the connection, in order.
    public static let stages = ["started", "tunnel_created", "key_created", "connection_saved", "plugin_added", "done"]
    /// Without a new report for this long, the connection step says so instead of spinning on.
    public static let stallAfter: TimeInterval = 180

    public enum Connection: Equatable, Sendable {
        case noChatGPT
        /// Dot has not been asked yet.
        case ready
        /// Dot is at work: this many stages are reported, and the next one is pending.
        case working(reached: Int)
        /// No report for three minutes. `last` is the last stage reached, if any.
        case stalled(last: String?)
        /// Dot reported that something stops it, in its own sentence.
        case blocked(note: String, last: String?)
        case complete
    }
    public static func connection(_ facts: Facts, askedAt: Date?, reports: [SetupThroughDot.Report], now: Date = .now) -> Connection {
        if done(.connect, facts, reports: reports) { return .complete }
        guard let askedAt else { return facts.chatGPTInstalled ? .ready : .noChatGPT }
        let reached = stages.indices.last { index in reports.contains { $0.step == stages[index] } }.map { $0 + 1 } ?? 0
        let last = reached > 0 ? stages[reached - 1] : nil
        let times = reports.compactMap { try? Date($0.at, strategy: .iso8601) }
        // A report of being stopped holds until Dot is asked to continue.
        if let latest = reports.last, latest.step == "blocked", (times.last ?? .distantPast) >= askedAt {
            return .blocked(note: latest.note.trimmingCharacters(in: .whitespacesAndNewlines), last: last)
        }
        let heard = max(askedAt, times.max() ?? .distantPast)
        return now.timeIntervalSince(heard) >= stallAfter ? .stalled(last: last) : .working(reached: reached)
    }
}

extension SetupThroughDot {
    /// When Dot was last asked to connect or to continue, kept beside its reports.
    public static func askedAt(in store: URL) -> Date? {
        guard let saved = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: store.appendingPathComponent("setup-state.json"))) else { return nil }
        return saved["askedAt"].flatMap { try? Date($0, strategy: .iso8601) }
    }
    /// Notes that Dot was asked. A first request starts over, so an earlier attempt's reports do not show as this one's.
    public static func noteAsked(in store: URL, fresh: Bool, now: Date = .now) throws {
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        if fresh { try? FileManager.default.removeItem(at: store.appendingPathComponent("setup-progress.json")) }
        try JSONEncoder().encode(["askedAt": now.ISO8601Format()]).write(to: store.appendingPathComponent("setup-state.json"), options: .atomic)
    }
    /// The setup window says it is open, every two seconds while it is.
    public static func noteWindowOpen(in store: URL, now: Date = .now) {
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try? Data(now.ISO8601Format().utf8).write(to: store.appendingPathComponent("setup-window"), options: .atomic)
    }
    public static func windowOpen(in store: URL, now: Date = .now) -> Bool {
        guard let text = try? String(contentsOf: store.appendingPathComponent("setup-window"), encoding: .utf8), let seen = try? Date(text, strategy: .iso8601) else { return false }
        return abs(now.timeIntervalSince(seen)) < 15
    }
    /// Why the setup step is refused now, or nil (independent review of build 170, M9). The step replaces Mail Dot's
    /// tunnel and key, so it works only on the owner's press: while the setup window is open, within the half hour
    /// after the press, and until it has once connected.
    public static func refusal(in store: URL, now: Date = .now) -> String? {
        guard windowOpen(in: store, now: now) else { return "Mail Dot's setup window is not open on this Mac, so the connection cannot be set up now." }
        guard let saved = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: store.appendingPathComponent("setup-state.json"))),
              let asked = saved["askedAt"].flatMap({ try? Date($0, strategy: .iso8601) }), now.timeIntervalSince(asked) <= entryLimit else {
            return "The owner has not asked for setup in the last half hour. Ask them to press Ask Dot to Continue in Mail Dot's setup window."
        }
        if saved["connectedAt"] != nil { return "The connection was already set up after the owner's last press. Ask them to press Ask Dot to Continue if it must be set up again." }
        return nil
    }
    /// The setup step has connected: it is not taken again until the owner presses again.
    public static func noteConnected(in store: URL, now: Date = .now) {
        let file = store.appendingPathComponent("setup-state.json")
        guard var saved = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: file)) else { return }
        saved["connectedAt"] = now.ISO8601Format()
        try? JSONEncoder().encode(saved).write(to: file, options: .atomic)
    }
    /// Setup is over or given up: nothing of it is kept.
    public static func forgetAsked(in store: URL) {
        try? FileManager.default.removeItem(at: store.appendingPathComponent("setup-state.json"))
    }

    /// What Mail Dot writes to Dot when setup has stopped part-way. It names what is already done, so Dot does not
    /// create a second tunnel and key under the same name.
    public static func continuation(name: String, completed: [String]) -> String {
        let described = ["started": "you started the task on this computer", "tunnel_created": "the tunnel exists", "key_created": "the key exists",
                         "connection_saved": "Mail Dot has the tunnel ID and the key, and its connection is running", "plugin_added": "the plugin is added in ChatGPT"]
        let done = SetupFlow.stages.filter(completed.contains).compactMap { described[$0] }
        return """
        Mail Dot asks you to continue setting up its private connection to you, named "\(name)", from where it stopped. Do not start over and do not create a second tunnel, key, plugin or task: \(done.isEmpty ? "first check on platform.openai.com and in ChatGPT what already exists under that name, and reuse it" : "already done: " + done.joined(separator: "; ") + ". Reuse what exists under that name").

        Carry out only the steps that remain, in the task on this computer, and call report_setup_progress of the MCP server maildot at each: tunnel_created and key_created (a Secure MCP Tunnel and a restricted API key that can only read and use tunnels, on platform.openai.com), connection_saved (after calling setup_connection of maildot with the tunnel_id and the key), plugin_added (a custom plugin in ChatGPT that uses that tunnel), done (after subscribing to mail.reply_context_changed, mail.settings_requested and mail.workflow_requested and creating the hourly task "\(name) · Keep connected"). If the key can no longer be read, create a new key with the same name and delete the old one. If something stops you, report blocked with a one-sentence reason. Never show the key in this chat.
        """
    }

    /// Mail Dot's entry in ChatGPT's local-tools settings is one written for setup.
    public static func isRegisteredForSetup(in contents: String) -> Bool {
        var inside = false
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { inside = trimmed.hasPrefix("[mcp_servers.maildot.env") }
            else if inside, trimmed.hasPrefix("MAILDOT_SETUP_MODE") { return true }
        }
        return false
    }
    /// How long the setup entry may stand without a report from Dot.
    public static let entryLimit: TimeInterval = 1_800
    /// Whether the setup entry is taken out of ChatGPT's settings now: setup is complete, was never asked for on
    /// this Mac, or the owner's press is more than thirty minutes old. The entry is the one piece of setup that grants a
    /// capability (replacing the stored tunnel and key), so it does not outlive the setup it was written for.
    public static func shouldWithdraw(complete: Bool, askedAt: Date?, reports: [Report], now: Date = .now) -> Bool {
        guard !complete, let askedAt else { return true }
        // Counted from the owner's press alone: a task that keeps reporting does not keep the entry (review, M9).
        return now.timeIntervalSince(askedAt) > entryLimit
    }
}

/// The name of the Extensions tab in Mail's Settings, as Mail itself shows it (installer design review,
/// recommendation 11). Mail Dot takes it from Mail's own table of that window rather than carrying 47 translations
/// of Apple's word, so it matches whatever Mail shows on this system.
public enum MailSettingsNames {
    /// `table` is Mail's PreferencesWindow table: language, then key, then text. The tab is found by its English
    /// title, and its title in the first of `languages` that Mail has is returned.
    public static func extensionsTitle(table: [String: [String: String]], languages: [String]) -> String? {
        guard let english = table["en"],
              let key = english.first(where: { $0.value == "Extensions" && $0.key.hasSuffix(".title") })?.key else { return nil }
        for language in Bundle.preferredLocalizations(from: Array(table.keys), forPreferences: languages) {
            if let title = table[language]?[key], !title.isEmpty { return title }
        }
        return english[key]
    }
}
