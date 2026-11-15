import XCTest
@testable import BridgeCore

/// Removal is tried only against a made-up home folder: it is never run against the real one.
final class MailDotRemovalTests: XCTestCase {
    private func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("removal-\(UUID().uuidString)", isDirectory: true)
        for folder in ["Applications/Mail Dot.app/Contents", "Library/Application Support/Mail Dot/Runtime", "Library/Application Support/tunnel-client/health",
                       "Library/Application Support/tunnel-client/logs", "Library/Application Support/Other App", "Library/Group Containers/ABCDE12345.org.jgkarlin.MailBridge/BridgeState/Search", "Library/Group Containers/ABCDE12345.org.jgkarlin.MailBridge/BridgeState/Triage",
                       "Library/Group Containers/ABCDE12345.org.example.other", "Library/Containers/org.jgkarlin.MailBridge.MailExtension/Data", "Library/Containers/org.jgkarlin.MailBridgeX",
                       "Library/Preferences", ".codex"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["Library/Application Support/tunnel-client/health/mail-dot.url", "Library/Application Support/tunnel-client/health/other.url", "Library/Application Support/tunnel-client/logs/mail-dot.log",
                     "Library/Preferences/org.jgkarlin.MailBridge.plist", "Library/Preferences/org.jgkarlin.MailBridge.MailExtension.plist", "Library/Preferences/org.example.other.plist",
                     "Library/Preferences/org.jgkarlin.MailBridgeX.plist"] {
            try Data("x".utf8).write(to: home.appendingPathComponent(file))
        }
        try Data(SetupThroughDot.registering(agentPath: "/Applications/Mail Dot.app/Contents/Helpers/MailDotAgent", in: "model = \"x\"\n\n[mcp_servers.other]\ncommand = \"/o\"\n").utf8)
            .write(to: home.appendingPathComponent(".codex/config.toml"))
        return home
    }
    func testEverythingOfMailDotsGoesToOneFolderInTheTrashAndNothingElseIsTouched() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        let outcome = try MailDotRemoval.moveToTrash(home: home, app: home.appendingPathComponent("Applications/Mail Dot.app"), now: Date(timeIntervalSince1970: 1_794_700_000))
        XCTAssertTrue(outcome.left.isEmpty)
        XCTAssertTrue(outcome.folder.path.hasPrefix(home.appendingPathComponent(".Trash/Mail Dot removed 2026-11-").path))
        let trashed = Set(try FileManager.default.contentsOfDirectory(atPath: outcome.folder.path))
        XCTAssertEqual(trashed, ["Mail Dot.app", "Application Support - Mail Dot", "mail-dot.url", "mail-dot.log", "Group Container - ABCDE12345.org.jgkarlin.MailBridge",
                                 "Container - org.jgkarlin.MailBridge.MailExtension", "org.jgkarlin.MailBridge.plist", "org.jgkarlin.MailBridge.MailExtension.plist", "codex-config-before-removal.toml"])
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path) }
        XCTAssertFalse(exists("Applications/Mail Dot.app"))
        XCTAssertFalse(exists("Library/Application Support/Mail Dot"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outcome.folder.appendingPathComponent("Group Container - ABCDE12345.org.jgkarlin.MailBridge/BridgeState/Search").path), "the index of mail text is deleted, not left in the Trash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.folder.appendingPathComponent("Group Container - ABCDE12345.org.jgkarlin.MailBridge/BridgeState/Triage").path))
        // What belongs to others, or only resembles Mail Dot's names, stays.
        for kept in ["Library/Application Support/Other App", "Library/Application Support/tunnel-client/health/other.url", "Library/Group Containers/ABCDE12345.org.example.other",
                     "Library/Containers/org.jgkarlin.MailBridgeX", "Library/Preferences/org.example.other.plist", "Library/Preferences/org.jgkarlin.MailBridgeX.plist"] {
            XCTAssertTrue(exists(kept), kept)
        }
        let settings = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        XCTAssertFalse(SetupThroughDot.isRegistered(in: settings))
        XCTAssertTrue(settings.contains("[mcp_servers.other]") && settings.contains("model = \"x\""))
        XCTAssertTrue(try String(contentsOf: outcome.folder.appendingPathComponent("codex-config-before-removal.toml"), encoding: .utf8).contains("[mcp_servers.maildot]"))
    }
    func testAHomeWithoutMailDotLosesNothingAndASecondRemovalFindsNothing() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        _ = try MailDotRemoval.moveToTrash(home: home, app: nil, now: Date(timeIntervalSince1970: 1_794_700_000))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Applications/Mail Dot.app").path), "no app was named, so none was moved")
        XCTAssertTrue(MailDotRemoval.stored(home: home).isEmpty)
        let again = try MailDotRemoval.moveToTrash(home: home, app: nil, now: Date(timeIntervalSince1970: 1_794_700_100))
        XCTAssertTrue(again.moved.isEmpty && again.left.isEmpty)
        // Other accounts on the Mac are found by their home folders; the shared folder and this account are not counted.
        let users = home.appendingPathComponent("AllUsers")
        for name in ["alex", "sam", "Shared", "Guest", ".localized"] { try FileManager.default.createDirectory(at: users.appendingPathComponent(name), withIntermediateDirectories: true) }
        XCTAssertEqual(MailDotRemoval.otherAccounts(users: users, home: users.appendingPathComponent("alex")), ["sam"])
        XCTAssertEqual(MailDotRemoval.Remaining.allCases.count, 4)
        XCTAssertTrue(MailDotRemoval.Remaining.allCases.allSatisfy { $0.page.scheme == "https" })
    }
}
