import XCTest
import AppKit
@testable import BridgeAutomation

final class ScriptTests: XCTestCase {
    func testExpiredAccountDiscoveryStopsBeforeAnyMailAccess() async {
        do {
            _ = try await MailAutomation().accounts(operationDeadline:.distantPast)
            XCTFail("Expired metadata discovery must not start.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("setup deadline expired"),error.localizedDescription) }
    }
    func testMailScriptCompilesAgainstInstalledDictionary() throws {
        XCTAssertNoThrow(try MailAutomation.validateScript())
    }
    func testFinalNativeComparisonRejectsCaseOnlyAndUnicodeChanges() async throws {
        // The comparison runs as a script in Mail, and Mail Dot never starts Mail: with Mail closed there is
        // nothing to test against.
        try XCTSkipUnless(!NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").isEmpty,"Mail is not open")
        let automation = MailAutomation()
        let caseChanged = try await automation.recordsEqualForTesting("Message","message")
        let accentChanged = try await automation.recordsEqualForTesting("Résumé","Resume")
        let same = try await automation.recordsEqualForTesting("Same","Same")
        XCTAssertFalse(caseChanged); XCTAssertFalse(accentChanged); XCTAssertTrue(same)
    }
}
