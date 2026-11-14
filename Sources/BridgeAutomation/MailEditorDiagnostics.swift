import Foundation
import BridgeCore

/// Lines about what Mail's interface presented when Mail Dot could not find the message editor. They hold
/// counts and flags only, never titles, addresses or text, and go to the same readable log as Dot's calls,
/// so that a failure at the owner's Mac can be diagnosed afterwards.
enum MailEditorDiagnostics {
    static func note(_ text: String) {
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mail Dot/Logs/tool-calls.log")
        ToolCallLogStore.appendLine("\(Date().ISO8601Format()) mail \(text)", to: log)
    }
}
