#if DEBUG
import Foundation
import BridgeCore

protocol NativeBodyProbeScripting:MailReplyScripting {
    func connect(_ envelope:MailDraft) async throws -> MailDraft
}
extension MailAutomation:NativeBodyProbeScripting {}

/// One fixed, local synthetic experiment. Never called by an MCP tool.
public enum NativeBodyRoundtripProbe {
    static let contextID="75B9FCA2-E30C-40A3-A7CD-078392ACF57F"
    static let fixture=MailDraft(id:-1,subject:"Re: Mail Dot native read test - UNSENT",sender:"developer@example.invalid",to:["developer@example.invalid"],cc:[],bcc:[],body:"\n\nOn Nov 9, 2026, at 17:20, Mail Dot Developer <developer@example.invalid> wrote:\n\nFixture identifier: native-mail-read-20261109.\nMeeting: Thursday at 14:00.\nState: synthetic unsent test; no delivery intended.\n\n",attachmentCount:-1)
    static let marker="MAIL DOT SYNTHETIC BODY ROUNDTRIP\nDiagnostic marker only. No email was sent.\n"
    static func validate(context:ReplyContext,native:MailDraft,visible:MailDraft) throws {
        guard context.id == contextID,context.snapshot?.fingerprint == fixture.fingerprint,
              context.envelope.hasSameEnvelope(as:fixture),context.proposal == nil,context.review == nil,
              visible.fingerprint == fixture.fingerprint,native.id == 1,native.attachmentCount == 0,
              native.hasSameEnvelope(as:fixture),native.body.isEmpty else {
            throw BridgeFailure("The fixed synthetic body probe did not match. Nothing was written.")
        }
    }
    static func restoration(native:MailDraft,visible:MailDraft) throws -> String {
        guard native.id == 1,native.attachmentCount == 0,native.hasSameEnvelope(as:fixture),
              Data(native.body.utf8) == Data(marker.utf8),visible.hasSameEnvelope(as:fixture) else {
            throw BridgeFailure("Unexpected synthetic native write result. Inspect Mail; no restoration attempted.")
        }
        if Data(visible.body.utf8) == Data(marker.utf8) { return fixture.body }
        if Data(visible.body.utf8) == Data((marker+fixture.body).utf8) { return "" }
        throw BridgeFailure("Unexpected complete visible body after the synthetic write. Inspect Mail; no restoration attempted.")
    }
    private struct Result:Codable {
        var status="running",stage="preflight"
        var writeAttempted=false,restoreAttempted=false
        var beforeBytes:Int?,afterBytes:Int?,restoredBytes:Int?
        var wholeBodyReplaced:Bool?,nativeReadbackComplete:Bool?
    }
    public static func run() async throws {
        try await run(store:BridgeStore.shared(),scripting:MailAutomation(),reader:MailReplyReader())
    }
    static func run(store:BridgeStore,scripting:any NativeBodyProbeScripting,reader:any MailReplyReading) async throws {
        let directory=store.directory.appendingPathComponent("SyntheticDiagnostics",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let output=directory.appendingPathComponent("body-roundtrip-\(contextID).json")
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        var result=Result()
        // A relaunch never replays a write after an uncertain outcome.
        try encoder.encode(result).write(to:output,options:.withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
        func save() throws { try encoder.encode(result).write(to:output,options:.atomic) }
        func currentContext() throws -> ReplyContext {
            let state=try store.read()
            guard state.activeContextID == contextID,let context=state.contexts[contextID],
                  context.snapshot?.fingerprint == fixture.fingerprint,context.proposal == nil,context.review == nil,
                  !state.operations.contains(where:{$0.result == nil && $0.error == nil}) else {
                throw BridgeFailure("The synthetic context changed or another Mail action is pending.")
            }
            return context
        }
        do {
            let context=try currentContext()
            result.stage="native_connect"; try save()
            let native=try await scripting.connect(fixture)
            result.stage="visible_capture"; try save()
            let visible=try await reader.capture(matching:fixture,native:nil)
            result.stage="fixture_guard"; try save()
            try validate(context:context,native:native,visible:visible)
            _ = try currentContext()
            result.beforeBytes=visible.body.utf8.count
            result.stage="write"; result.writeAttempted=true; try save()
            let applied=try await scripting.apply(marker,to:native)
            result.stage="observe"; try save()
            let after=try await reader.capture(matching:fixture,native:nil)
            result.afterBytes=after.body.utf8.count
            let restore=try restoration(native:applied,visible:after)
            result.wholeBodyReplaced = Data(after.body.utf8) == Data(marker.utf8)
            let finalVisible=try await reader.capture(matching:fixture,native:nil)
            guard finalVisible.fingerprint == after.fingerprint else { throw BridgeFailure("Synthetic reply changed before restoration.") }
            _ = try currentContext()
            result.stage="restore"; result.restoreAttempted=true; try save()
            let restored=try await scripting.apply(restore,to:applied)
            result.stage="verify_restore"; try save()
            let visibleRestored=try await reader.capture(matching:fixture,native:nil)
            result.restoredBytes=visibleRestored.body.utf8.count
            guard visibleRestored.fingerprint == fixture.fingerprint else { throw BridgeFailure("The complete synthetic body was not restored. Inspect Mail.") }
            let reconciled=try ReplyCapturePolicy.reconcile(native:restored,visible:visibleRestored)
            result.nativeReadbackComplete = reconciled.id == 1
            result.status="complete"; result.stage="restored"; try save()
        } catch {
            result.status="failed"; try? save()
            throw BridgeFailure("Synthetic body diagnostic stopped at \(result.stage). Inspect its private status and the unsent fixture; do not retry automatically.")
        }
    }
}
#endif
