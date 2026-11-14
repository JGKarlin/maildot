import Foundation
import BridgeCore

/// Caller must persist consumption before this single native creation attempt.
/// Authorization and consumption run back to back. The native call follows on the main thread, where
/// AppleScript must run; it is attempted once and never retried, whatever happens in between.
enum MailCompositionDispatch {
    static func perform(isolation:isolated (any Actor)? = #isolation,plan:NativeCompositionPlan,check:()throws->Void,
                        consume:()throws->Void,create:() async throws->MailDraft) async throws -> MailDraft {
        try Task.checkCancellation()
        try check()
        try Task.checkCancellation()
        try consume()
        do {
            let draft=try await create()
            try plan.validateCreated(draft)
            return draft
        } catch {
            throw BridgeFailure("Draft creation could not be confirmed. Inspect Mail before trying again; Mail Dot will not retry this attempt. Nothing was sent by this action. \(error.localizedDescription)")
        }
    }
}
