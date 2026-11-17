import Foundation

/// How Dot hands Mail Dot its connection during setup (owner approval, 14 November 2026: "Yes" to a one-time setup
/// step that Dot uses). Dot creates the user's OpenAI tunnel and its restricted key on OpenAI's site, then, in a task
/// on this Mac, calls this tool with both. Mail Dot keeps the key in the Keychain, writes its connection settings and
/// starts the connection. The key is never shown to the user, written to a file, logged or returned.
///
/// The tool is offered only by a helper started for setup (MAILDOT_SETUP_MODE=1 in its environment). The helper
/// that the tunnel runs for Dot in the cloud never offers it, so nothing arriving through the connection can replace
/// the connection.
public enum ConnectionSetup {
    public static let toolName = "setup_connection"
    public static let progressToolName = "report_setup_progress"
    public static var enabled: Bool { ProcessInfo.processInfo.environment["MAILDOT_SETUP_MODE"] == "1" }

    static let definition: JSONValue = [
        "name": .string(toolName),
        "description": "Only while setting up Mail Dot on this Mac: give Mail Dot the ID of the OpenAI tunnel you created for it (it begins with tunnel_) and the restricted key you created for that tunnel. Mail Dot stores the key in the Mac's Keychain and starts the connection, then says whether it is connected. Never show, repeat or save the key anywhere else.",
        "inputSchema": ["type": "object",
                        "properties": ["tunnel_id": ["type": "string"], "api_key": ["type": "string"]],
                        "required": ["tunnel_id", "api_key"], "additionalProperties": false],
        "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
    ]

    /// Dot says where it is in setup, and what stops it, so that Mail Dot can show it without reading Dot's chat.
    static let progressDefinition: JSONValue = [
        "name": .string(progressToolName),
        "description": "While setting up Mail Dot on this Mac: report each step as you reach it, and anything that stops you, in one short sentence. Steps: started, tunnel_created, key_created, connection_saved, plugin_added, done, or blocked (say why). Never include the key.",
        "inputSchema": ["type": "object",
                        "properties": ["step": ["type": "string"], "note": ["type": "string"]],
                        "required": ["step"], "additionalProperties": false],
        "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
    ]
    public static let steps: Set<String> = ["started", "tunnel_created", "key_created", "connection_saved", "plugin_added", "done", "blocked"]

    /// Keeps the report, newest last, in the helper's store. A note that looks like a key is not kept.
    static func recordProgress(arguments: [String: JSONValue], store: URL, now: Date = Date()) throws -> JSONValue {
        guard let step = arguments["step"]?.string, steps.contains(step) else {
            throw BridgeFailure("step must be one of: started, tunnel_created, key_created, connection_saved, plugin_added, done, blocked.")
        }
        var note = String((arguments["note"]?.string ?? "").prefix(500))
        if note.range(of: #"sk-[A-Za-z0-9_\-]{8,}"#, options: .regularExpression) != nil { note = "(note withheld: it looked like a key)" }
        let file = store.appendingPathComponent("setup-progress.json")
        var entries = (try? JSONDecoder().decode([[String: String]].self, from: Data(contentsOf: file))) ?? []
        entries.append(["at": now.ISO8601Format(), "step": step, "note": note])
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(entries.suffix(50))).write(to: file, options: .atomic)
        return ["recorded": true, "step": .string(step)]
    }

    /// Where setup writes. Normally the user's own folders and Keychain item; a test of setup (MAILDOT_SETUP_HOME)
    /// writes into another folder and Keychain item and starts its own connection, leaving the real one alone.
    struct Target {
        let paths: RuntimeSetup.Paths
        let keyService: String
        let agentArguments: [String]
        let test: Bool
        static func current(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Target {
            // The test target exists in debug builds only (review of build 170, L1).
            #if DEBUG
            if let home = environment["MAILDOT_SETUP_HOME"], home.hasPrefix("/") {
                return Target(paths: RuntimeSetup.Paths(home: URL(fileURLWithPath: home, isDirectory: true)),
                              keyService: environment["MAILDOT_KEY_SERVICE"] ?? RuntimeSetup.keyService + ".test",
                              agentArguments: environment["MAILDOT_SETUP_STORE"].map { ["--store", $0] } ?? [], test: true)
            }
            #endif
            return Target(paths: RuntimeSetup.Paths(home: FileManager.default.homeDirectoryForCurrentUser),
                          keyService: RuntimeSetup.keyService, agentArguments: [], test: false)
        }
    }

    static func run(arguments: [String: JSONValue], agent: URL, target: Target = .current()) async throws -> JSONValue {
        guard let tunnelID = arguments["tunnel_id"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), RuntimeSetup.validTunnelID(tunnelID) else {
            throw BridgeFailure("tunnel_id must be the tunnel's ID as OpenAI shows it, beginning with tunnel_.")
        }
        guard let key = arguments["api_key"]?.string, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeFailure("api_key must be the restricted key created for this tunnel.")
        }
        let helpers = agent.deletingLastPathComponent()
        let runtime = helpers.appendingPathComponent("MailDotRuntime")
        guard FileManager.default.isExecutableFile(atPath: runtime.path) else { throw BridgeFailure("Mail Dot could not find its connection helper.") }
        let app = helpers.deletingLastPathComponent().deletingLastPathComponent()
        var trusted = [runtime.path]
        if app.pathExtension == "app" { trusted.insert(app.path, at: 0) }
        try RuntimeSetup.storeKey(key, trustedPaths: trusted, service: target.keyService)
        // The tunnel client inside this copy of Mail Dot, or else the installed one.
        let client = [helpers.appendingPathComponent("tunnel-client").path, "/Applications/Mail Dot.app/Contents/Helpers/tunnel-client"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        try RuntimeSetup.write(tunnelID: tunnelID, agentPath: agent.path, agentArguments: target.agentArguments,
                               clientPath: client, paths: target.paths)
        try? FileManager.default.removeItem(at: target.paths.runtime.appendingPathComponent("health.url"))
        try start(runtime: runtime, target: target)
        let running = await waitUntilReady(target.paths.runtime.appendingPathComponent("health.url"), seconds: 30)
        // Ready on this Mac says only that the client started; whether OpenAI accepted the tunnel and key is in its log.
        let refusal = running ? await openAIRefusal(target.paths.log, within: 8) : nil
        let connected = running && refusal == nil
        var answer: [String: JSONValue] = ["saved": true, "connected": .bool(connected), "tunnel_id": .string(tunnelID)]
        if let refusal { answer["openai_said"] = .string(refusal) }
        answer["next"] = .string(connected ? "The connection is running. Add Mail Dot to ChatGPT as a plugin that uses this tunnel."
            : refusal != nil ? "OpenAI refused the connection. Check that the tunnel ID and the key belong together and that the key may read and use tunnels, then call setup_connection again."
            : "The key is saved, but the connection has not started yet. Wait a minute and call setup_connection again.")
        return .object(answer)
    }

    /// The user's connection is the background job Mail Dot registered with macOS; a test starts its own copy.
    static func start(runtime: URL, target: Target) throws {
        let process = Process()
        if target.test {
            process.executableURL = runtime
            process.arguments = ["--runtime-dir", target.paths.runtime.path, "--key-service", target.keyService]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", "-k", "gui/\(getuid())/org.jgkarlin.MailBridge.Runtime"]
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw BridgeFailure("Mail Dot's connection helper is not registered yet. Open Mail Dot once, then try again.") }
        }
    }

    /// OpenAI's refusal, as the tunnel client logged it in the last seconds, or nil when it logged none. Only the
    /// reason is kept: an HTTP status and OpenAI's error code, never anything that could hold the key.
    static func openAIRefusal(_ log: URL, within seconds: Int) async -> String? {
        try? await Task.sleep(for: .seconds(seconds))
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").suffix(20).reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (entry["msg"] as? String)?.hasPrefix("poll failed") == true, let error = entry["error"] as? String else { continue }
            if let match = error.range(of: #"status \d{3}: [a-z_]+"#, options: .regularExpression) { return String(error[match]) }
            return "unreachable"
        }
        return nil
    }

    /// The connection reports ready on its own address on this Mac only.
    static func waitUntilReady(_ urlFile: URL, seconds: Int) async -> Bool {
        let session = URLSession(configuration: .ephemeral)
        for _ in 0..<seconds {
            if let text = try? String(contentsOf: urlFile, encoding: .utf8),
               let base = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), base.host == "127.0.0.1" {
                var request = URLRequest(url: base.appendingPathComponent("readyz")); request.timeoutInterval = 2
                if let (_, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 { return true }
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }
}

/// Setup through Dot, as the installer starts it (owner request, 14 November 2026: an installer he can test).
public enum SetupThroughDot {
    /// ChatGPT's local-tools settings with Mail Dot's helper listed for setup: the helper then offers setup_connection
    /// and report_setup_progress to Dot's tasks on this Mac. Every earlier Mail Dot entry is replaced.
    public static func registering(agentPath: String, in contents: String?) -> String {
        let kept = removing(in: contents ?? "")
        let entry = "[mcp_servers.maildot]\ncommand = \"\(escaped(agentPath))\"\nstartup_timeout_sec = 30\ntool_timeout_sec = 120\n\n[mcp_servers.maildot.env]\nMAILDOT_SETUP_MODE = \"1\"\n"
        return kept.isEmpty ? entry : kept + (kept.hasSuffix("\n") ? "\n" : "\n\n") + entry
    }
    /// The same settings with Mail Dot's entries taken out, everything else as it was.
    public static func removing(in contents: String) -> String {
        var kept: [Substring] = [], skipping = false
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { skipping = trimmed == "[mcp_servers.maildot]" || trimmed.hasPrefix("[mcp_servers.maildot.") }
            if !skipping { kept.append(line) }
        }
        var text = kept.joined(separator: "\n")
        while text.hasSuffix("\n\n") { text.removeLast() }
        return text
    }
    public static func isRegistered(in contents: String) -> Bool { contents.contains("[mcp_servers.maildot]") }
    private static func escaped(_ text: String) -> String { text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

    /// What Mail Dot writes to Dot in ChatGPT to have it set up the connection. In English whatever the interface
    /// language: it is an instruction to the assistant, not text the user reads. `name` names everything Dot creates,
    /// so that a second Mac or Mac account never touches another's connection (owner's test, 14 November 2026).
    public static func request(name: String) -> String {
        """
        Mail Dot asks you to set up its private connection to you, on my OpenAI account. Please carry it out to the end, asking me only where OpenAI or ChatGPT needs my click. Everything you create is named "\(name)". Do not touch any tunnel, key, plugin or task with another name, including ones named just "Mail Dot".

        First, start a task on this computer and call the tool report_setup_progress of the MCP server maildot with step "started". In that task, call report_setup_progress at every step below, and with step "blocked" and a one-sentence reason if anything stops you.

        1. In my browser, on platform.openai.com, create a Secure MCP Tunnel named "\(name)" and a restricted API key named "\(name)" that can only read and use tunnels. Report tunnel_created and key_created. Never show the key in this chat and do not save it anywhere.
        2. In the task on this computer, call setup_connection of maildot with the tunnel's tunnel_id and the key as api_key. Mail Dot keeps the key in the Mac's Keychain and starts the connection. Report connection_saved with what it answered.
        3. When it answers connected, add a custom plugin in ChatGPT named "\(name)" that uses that tunnel. Report plugin_added.
        4. Using that plugin, subscribe to its two events, each with ttlMs 86400000 and its own handler: mail.workflow_requested, with exactly these handler instructions: "\(DotHandlers.workflowPrompt)"; and mail.settings_requested, with exactly these: "\(DotHandlers.settingsPrompt)". Then create a task named "\(DotHandlers.keepConnectedTitle(name: name))" that runs \(DotHandlers.keepConnectedSchedule), with exactly these instructions: "\(DotHandlers.keepConnectedPrompt)". Run that task once now, so that Mail Dot sees it work; its schedule continues after. Report done.
        """
    }
    /// The name for this Mac account's connection.
    public static func connectionName(user: String = NSUserName()) -> String { "Mail Dot (\(user))" }

    /// Dot's reports, oldest first, from the helper's store.
    public struct Report: Decodable, Equatable, Sendable {
        public let at: String; public let step: String; public let note: String
        public init(at: String, step: String, note: String = "") { self.at = at; self.step = step; self.note = note }
    }
    public static func reports(in store: URL) -> [Report] {
        (try? JSONDecoder().decode([Report].self, from: Data(contentsOf: store.appendingPathComponent("setup-progress.json")))) ?? []
    }
}
