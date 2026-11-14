import Foundation
import BridgeCore

public protocol MailReplyScripting:Sendable {
    func snapshot(id:Int) async throws -> MailDraft
    func apply(_ text:String,to expected:MailDraft) async throws -> MailDraft
    func send(_ expected:MailDraft) async throws -> Bool
}
public protocol MailReplyReading:Sendable {
    func capture(matching expected:MailDraft,native:MailDraft?) async throws -> MailDraft
}
extension MailAutomation:MailReplyScripting {}
extension MailReplyReader:MailReplyReading {}

/// A scripting ID alone is not a whole-body binding. Check the visible draft
/// at each action boundary, including legacy snapshots that predate this check.
public actor MailReplyActions {
    private let scripting:any MailReplyScripting
    private let reader:any MailReplyReading
    private var busy=false
    public init(scripting:any MailReplyScripting=MailAutomation(),reader:any MailReplyReading=MailReplyReader()) {
        self.scripting=scripting; self.reader=reader
    }
    public func checkedSnapshot(_ expected:MailDraft) async throws -> MailDraft {
        guard !busy else { throw BridgeFailure("Another Mail message action is in progress.") }
        busy=true; defer { busy=false }
        return try await checked(expected)
    }
    public func apply(_ text:String,to expected:MailDraft) async throws -> MailDraft {
        guard !busy else { throw BridgeFailure("Another Mail message action is in progress.") }
        busy=true; defer { busy=false }
        _ = try await checked(expected)
        let applied=try await scripting.apply(text,to:expected)
        do { return try await checked(applied) }
        catch { throw BridgeFailure("Mail text may have changed, but the complete visible result could not be verified. Inspect Mail before continuing. \(error.localizedDescription)") }
    }
    public func send(_ expected:MailDraft) async throws -> Bool {
        guard !busy else { throw BridgeFailure("Another Mail message action is in progress.") }
        busy=true; defer { busy=false }
        _ = try await checked(expected)
        // The scripting adapter performs its own final literal comparison.
        return try await scripting.send(expected)
    }
    private func checked(_ expected:MailDraft) async throws -> MailDraft {
        guard expected.id >= 0 else { throw BridgeFailure("This message has no verified native action binding.") }
        let native=try await scripting.snapshot(id:expected.id)
        guard native.fingerprint == expected.fingerprint else { throw BridgeFailure("The scripted draft changed. Refresh and review the message again.") }
        let visible=try await reader.capture(matching:expected,native:native)
        guard visible.id == expected.id,visible.fingerprint == native.fingerprint else {
            throw BridgeFailure("Mail's complete visible message does not match its scripted record. Nothing was applied or sent by this check. Refresh the message and review again.")
        }
        let final=try await scripting.snapshot(id:expected.id)
        guard final.fingerprint == native.fingerprint else { throw BridgeFailure("The message changed during verification. Refresh and review again.") }
        return final
    }
}
