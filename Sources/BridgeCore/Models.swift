import Foundation
import CryptoKit

public struct BridgeFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct MailDraft: Codable, Equatable, Sendable {
    public var id: Int
    public var subject: String
    public var sender: String
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var body: String
    public var attachmentCount: Int

    public init(id: Int, subject: String, sender: String, to: [String], cc: [String], bcc: [String], body: String, attachmentCount: Int) {
        self.id = id; self.subject = subject; self.sender = sender
        self.to = to; self.cc = cc; self.bcc = bcc; self.body = body; self.attachmentCount = attachmentCount
    }

    public var fingerprint: String {
        // Native review binds literal values and array structure. Envelope matching is separate.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public static func address(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    public static func addresses(_ values: [String]) -> [String] { values.map(address).sorted() }

    public func hasSameEnvelope(as other: MailDraft) -> Bool {
        subject == other.subject && Self.address(sender) == Self.address(other.sender)
            && Self.addresses(to) == Self.addresses(other.to)
            && Self.addresses(cc) == Self.addresses(other.cc)
            && Self.addresses(bcc) == Self.addresses(other.bcc)
    }
}

public enum DraftMatcher {
    public static func unique(_ candidates: [MailDraft], matching expected: MailDraft) throws -> MailDraft {
        let matches = candidates.filter { $0.hasSameEnvelope(as: expected) }
        guard matches.count == 1, let match = matches.first else {
            throw BridgeFailure(matches.isEmpty ? "No matching open message. Keep this message open in Mail." :
                                "More than one message has the same subject and recipients. Close the other matching window first.")
        }
        return match
    }
}

public struct SendReview: Codable, Sendable {
    public let id: String
    public let fingerprint: String
    public let expiresAt: Date
    public var consumed: Bool
    public let editorToken: String?
    public init(draft: MailDraft, now: Date = .now, editorToken: String? = nil) {
        id = UUID().uuidString; fingerprint = draft.fingerprint
        expiresAt = now.addingTimeInterval(600); consumed = false
        self.editorToken = editorToken
    }
    public func validate(draft: MailDraft, now: Date = .now, editorToken currentEditorToken: String? = nil) throws {
        guard !consumed else { throw BridgeFailure("This review has already been used. Check Mail before any further send attempt.") }
        guard now < expiresAt else { throw BridgeFailure("Review expired. Review this draft again in Mail.") }
        if draft.id < 0 {
            guard let editorToken, UUID(uuidString:editorToken) != nil, editorToken == currentEditorToken else {
                throw BridgeFailure("The reviewed Mail window binding expired or changed. Review the current message again.")
            }
        } else if editorToken != nil {
            throw BridgeFailure("The reviewed message's action binding changed. Review it again in Mail.")
        }
        // A known count of pictures and files, bound by the fingerprint below; an unknown count is refused.
        // The scripted path (a draft Mail Dot made itself) still sends only messages without attachments.
        guard draft.id < 0 ? draft.attachmentCount >= 0 : draft.attachmentCount == 0 else { throw BridgeFailure("Mail Dot could not count this message's pictures and attachments, so it cannot send it. Review it again.") }
        guard !draft.to.isEmpty, !draft.sender.isEmpty else { throw BridgeFailure("A sender and recipient are required.") }
        guard !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BridgeFailure("An empty message cannot be sent.") }
        guard draft.fingerprint == fingerprint else { throw BridgeFailure("The draft changed after review. Nothing was sent. Review it again in Mail.") }
    }
}
