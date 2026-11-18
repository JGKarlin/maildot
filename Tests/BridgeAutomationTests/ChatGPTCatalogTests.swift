import XCTest
import BridgeCore
@testable import BridgeAutomation

final class ChatGPTCatalogTests: XCTestCase {
    /// Against the ChatGPT app on this Mac, when asked for (MAILDOT_LIVE_CHATGPT=1): its translation tables are found
    /// and give the names in many languages. Only ChatGPT's own program files are read.
    func testTheInstalledChatGPTGivesItsNamesInManyLanguages() throws {
        let app = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAILDOT_LIVE_CHATGPT"] == "1" && FileManager.default.fileExists(atPath: app.path))
        let started = Date()
        let labels = ChatGPTCatalog.labels(app: app, cache: nil)
        print("CHATGPT_LABELS start=\(labels.start.count) hangUp=\(labels.hangUp.count) during=\(labels.otherDuringCall.count) send=\(labels.send.count) seconds=\(String(format: "%.2f", Date().timeIntervalSince(started)))")
        XCTAssertGreaterThan(labels.start.count, 20)
        XCTAssertTrue(labels.start.contains("通話を開始"))
        XCTAssertTrue(labels.hangUp.contains("通話を終了"))
        XCTAssertTrue(labels.send.contains("送信"))
        XCTAssertTrue(labels.start.isDisjoint(with: labels.duringCall))
    }

    func testAMissingAppGivesTheEnglishNames() {
        XCTAssertEqual(ChatGPTCatalog.labels(app: URL(fileURLWithPath: "/nonexistent/ChatGPT.app"), cache: nil), .english)
    }
}
