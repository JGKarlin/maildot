import Foundation
import AppKit
import BridgeCore

/// A value handed to the main thread together with one script call. Apple-event descriptors are not
/// Sendable, but each one built for a call is used by that call alone.
struct ScriptValue<T>: @unchecked Sendable { let value: T }

/// NSAppleScript is documented as safe on the main thread only, and compiling a script is slow. Every Mail
/// script therefore runs here, on the main actor, from a copy compiled once.
@MainActor final class MailScriptHost {
    static let shared = MailScriptHost()
    private var compiled: [String: NSAppleScript] = [:]

    func call(source: String, event: NSAppleEventDescriptor, failure: String) throws -> NSAppleEventDescriptor {
        // A script addressed to Mail starts Mail if it is not running. Mail Dot never starts Mail by itself:
        // seen on 12 November 2026, a background check reopened Mail seconds after the owner quit it.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty else {
            throw BridgeFailure("Mail is not open. Open Mail, then try again.")
        }
        let script: NSAppleScript
        if let cached = compiled[source] { script = cached }
        else {
            guard let fresh = NSAppleScript(source: source) else { throw BridgeFailure(failure) }
            var error: NSDictionary?
            guard fresh.compileAndReturnError(&error) else { throw BridgeFailure(error?[NSAppleScript.errorMessage] as? String ?? failure) }
            compiled[source] = fresh; script = fresh
        }
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error { throw BridgeFailure(error[NSAppleScript.errorMessage] as? String ?? failure) }
        return result
    }
}
