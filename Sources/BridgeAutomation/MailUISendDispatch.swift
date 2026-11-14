import Foundation
import BridgeCore

/// A single dispatch attempt. Success confirms only submission of the native action.
enum MailUISendDispatch {
    static func perform(
        isolation: isolated (any Actor)? = #isolation,
        review: SendReview,
        token: String,
        verify: () async throws -> MailDraft,
        checkTarget: () throws -> Void,
        consume: (MailDraft) throws -> Void,
        press: () throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let live = try await verify()
        try Task.checkCancellation()
        guard live.id < 0, review.editorToken == token else {
            throw BridgeFailure("This send action requires the reviewed message’s live editor binding.")
        }
        try review.validate(draft: live, editorToken: token)
        try checkTarget()
        try Task.checkCancellation()
        // No suspension or retry between durable single-use consumption and dispatch.
        try consume(live)
        do {
            try press()
        } catch {
            throw BridgeFailure("The send outcome is uncertain. Inspect Mail before taking further action. Mail Dot will not retry this approval. \(error.localizedDescription)")
        }
    }
}
