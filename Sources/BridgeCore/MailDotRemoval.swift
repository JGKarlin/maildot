import Foundation

/// Removing Mail Dot from a Mac (installer design review, recommendation 8, approved by the owner on 15 November
/// 2026): what the removal script did, done by the app. Everything Mail Dot put on the Mac is moved to one dated
/// folder in the Trash, so nothing is lost until the Trash is emptied, and only things under Mail Dot's own
/// identifiers are touched. This part moves files; stopping the helper, withdrawing the extension, deleting the key
/// and resetting the privacy grants are the app's.
public enum MailDotRemoval {
    public static let identifier = "org.jgkarlin.MailBridge"

    public struct Outcome: Equatable, Sendable {
        /// The folder in the Trash that now holds what was removed.
        public var folder: URL
        public var moved: [String] = []
        /// What macOS would not let Mail Dot move; the user drags these to the Trash.
        public var left: [String] = []
        public init(folder: URL) { self.folder = folder }
    }
    /// The four things on the user's OpenAI account that outlive the Mac's copy, each under the connection's name.
    /// Mail Dot cannot delete them, so it names them and opens their pages.
    public enum Remaining: String, CaseIterable, Sendable {
        case tunnel, key, plugin, task
        public var page: URL {
            switch self {
            case .tunnel: URL(string: "https://platform.openai.com/settings/organization/tunnels")!
            case .key: URL(string: "https://platform.openai.com/settings/organization/api-keys")!
            case .plugin: URL(string: "https://chatgpt.com/plugins")!
            case .task: URL(string: "https://chatgpt.com/scheduled")!
            }
        }
    }

    /// What Mail Dot keeps in a home folder, apart from the app: each item and the name it gets in the Trash folder.
    public static func stored(home: URL, fileManager: FileManager = .default) -> [(item: URL, name: String)] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        var found: [(URL, String)] = [
            (library.appendingPathComponent("Application Support/Mail Dot"), "Application Support - Mail Dot"),
            (library.appendingPathComponent("Application Support/tunnel-client/health/mail-dot.url"), "mail-dot.url"),
            (library.appendingPathComponent("Application Support/tunnel-client/logs/mail-dot.log"), "mail-dot.log"),
        ]
        func names(in folder: String) -> [String] { ((try? fileManager.contentsOfDirectory(atPath: library.appendingPathComponent(folder).path)) ?? []).sorted() }
        // The team's prefix differs from one signer to another; the identifier after it is Mail Dot's.
        for name in names(in: "Group Containers") where name.hasSuffix("." + identifier) {
            found.append((library.appendingPathComponent("Group Containers/" + name), "Group Container - " + name))
        }
        for name in names(in: "Containers") where name == identifier || name.hasPrefix(identifier + ".") {
            found.append((library.appendingPathComponent("Containers/" + name), "Container - " + name))
        }
        for name in names(in: "Preferences") where name.hasSuffix(".plist") && (name == identifier + ".plist" || name.hasPrefix(identifier + ".")) {
            found.append((library.appendingPathComponent("Preferences/" + name), name))
        }
        return found.filter { fileManager.fileExists(atPath: $0.0.path) }
    }

    /// Moves the app and everything it stored into a new folder in the Trash, and takes Mail Dot's entry out of
    /// ChatGPT's local-tools settings, keeping the file as it was beside the rest. The app goes last: the process
    /// doing this runs from it.
    /// The other accounts on this Mac, by their home folders. The installer puts one copy of Mail Dot in the shared
    /// Applications folder, so where there are any the app is theirs as well, and removal leaves it in place
    /// (independent review of build 170, H3).
    public static func otherAccounts(users: URL = URL(fileURLWithPath: "/Users"), home: URL, fileManager: FileManager = .default) -> [String] {
        let own = home.standardizedFileURL.lastPathComponent
        return ((try? fileManager.contentsOfDirectory(atPath: users.path)) ?? []).filter { name in
            var isDirectory: ObjCBool = false
            return !name.hasPrefix(".") && !["Shared", "Guest", own].contains(name) && fileManager.fileExists(atPath: users.appendingPathComponent(name).path, isDirectory: &isDirectory) && isDirectory.boolValue
        }.sorted()
    }
    /// Mail Dot's search index holds text of the owner's mail and can be made again from Mail, so it is deleted and
    /// not left in the Trash (review of build 170, M8). Only folders named Search inside Mail Dot's own containers go.
    public static func deleteIndex(home: URL, fileManager: FileManager = .default) {
        let groups = home.appendingPathComponent("Library/Group Containers", isDirectory: true)
        for name in (try? fileManager.contentsOfDirectory(atPath: groups.path)) ?? [] where name.hasSuffix("." + identifier) {
            try? fileManager.removeItem(at: groups.appendingPathComponent(name).appendingPathComponent("BridgeState/Search", isDirectory: true))
        }
    }
    public static func moveToTrash(home: URL, app: URL?, now: Date = .now, fileManager: FileManager = .default) throws -> Outcome {
        deleteIndex(home: home, fileManager: fileManager)
        let stamp = now.formatted(Date.VerbatimFormatStyle(format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)", timeZone: .current, calendar: Calendar(identifier: .gregorian)))
        var outcome = Outcome(folder: home.appendingPathComponent(".Trash/Mail Dot removed \(stamp)", isDirectory: true))
        try fileManager.createDirectory(at: outcome.folder, withIntermediateDirectories: true)
        func move(_ item: URL, as name: String) {
            guard fileManager.fileExists(atPath: item.path) else { return }
            do { try fileManager.moveItem(at: item, to: outcome.folder.appendingPathComponent(name)); outcome.moved.append(item.path) }
            catch { outcome.left.append(item.path) }
        }
        let settings = home.appendingPathComponent(".codex/config.toml")
        if let contents = try? String(contentsOf: settings, encoding: .utf8), SetupThroughDot.isRegistered(in: contents) {
            try? Data(contents.utf8).write(to: outcome.folder.appendingPathComponent("codex-config-before-removal.toml"))
            try? Data((SetupThroughDot.removing(in: contents) + "\n").utf8).write(to: settings, options: .atomic)
        }
        for (item, name) in stored(home: home, fileManager: fileManager) { move(item, as: name) }
        if let app { move(app, as: app.lastPathComponent) }
        return outcome
    }
}
