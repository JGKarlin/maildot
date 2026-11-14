import Foundation
import BridgeCore

public struct MailUIReplyBinding:Sendable {
    public let token:String
    public let snapshot:MailDraft
    public init(token:String,snapshot:MailDraft) { self.token=token; self.snapshot=snapshot }
}
protocol MailUIEditingDriver:Sendable {
    func bind(contextID:String,matching envelope:MailDraft) async throws -> MailUIReplyBinding
    func selectBody(contextID:String,token:String,expected:MailDraft) async throws
    /// Places the caret at the very top of the message, or selects `previous` there, which must be what the
    /// message begins with. What is inserted next goes there and nothing below it is touched.
    func selectTop(contextID:String,token:String,expected:MailDraft,replacing previous:String) async throws
    func insert(_ text:String,contextID:String,token:String,authorize:@Sendable () throws -> Void) async throws
    func readback(contextID:String,token:String,matching envelope:MailDraft) async throws -> MailDraft
    func reviewSnapshot(contextID:String,token:String,expected:MailDraft) async throws -> MailDraft
    func send(contextID:String,token:String,expected:MailDraft,review:SendReview,consume:@Sendable (MailDraft) throws -> Void) async throws
    /// Types Dot's subject line into a new message's empty Subject field and checks Mail shows exactly it.
    func setSubject(_ subject:String,contextID:String,token:String) async throws
    /// Attaches files at the caret, after the reply just typed, and returns the message as it then reads.
    func attachFiles(_ urls:[URL],contextID:String,token:String,expected:MailDraft) async throws -> MailDraft
    /// Ask Mail to save the open draft to Drafts. True if the request could be made; Mail does not confirm it.
    func requestSave(contextID:String,token:String) async -> Bool
    /// After a failed insertion: put the reply's original body back. True only if the body is verified to match it.
    func restoreOriginal(contextID:String,token:String) async -> Bool
}
enum MailUIKeyDispatch {
    static func perform(isolation:isolated (any Actor)? = #isolation,identity:() throws -> Void,selection:() throws -> Void,focus:() async throws -> Void,authorization:() throws -> Void = {},post:() throws -> Void) async throws {
        try identity()
        try selection()
        try await focus()
        try authorization()
        try post()
    }
}
enum MailUIEditPolicy {
    static func completeSelection(_ selected:String,source:String) -> Bool {
        if Data(selected.utf8) == Data(source.utf8) { return true }
        // Observed Mail Select All excludes one final structural paragraph LF.
        // No other omission, whitespace trimming or Unicode normalization is allowed.
        guard source.hasSuffix("\n") else { return false }
        return Data(selected.utf8) == Data(source.dropLast().utf8)
    }
    static func segments(_ text:String) throws -> [String] {
        if let refusal=ApplyLimits.refusal(for:text) { throw BridgeFailure(refusal) }
        var result:[String]=[],chunk=""
        for scalar in text.unicodeScalars {
            if scalar.value == 10 {
                if !chunk.isEmpty { result.append(chunk); chunk="" }
                result.append("\n")
            } else {
                let next=String(scalar)
                if chunk.utf16.count+next.utf16.count > 16 { result.append(chunk); chunk="" }
                chunk += next
            }
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
    static func verify(_ result:MailDraft,text:String,expected:MailDraft) throws {
        var exact=expected; exact.id = -1; exact.attachmentCount = -1; exact.body=text
        if result.fingerprint == exact.fingerprint { return }
        // WebKit can represent the final editable paragraph with one extra LF.
        exact.body += "\n"
        guard result.fingerprint == exact.fingerprint else { throw BridgeFailure("The complete visible result differs from the reviewed text. Inspect Mail before continuing.") }
    }
}

/// Bound native reply actions. Sending requires a fresh review and durable consumption.
public actor MailUIReplyEditor {
    private let driver:any MailUIEditingDriver
    private var busy=false
    public init() { driver=MacMailUIEditingDriver() }
    init(driver:any MailUIEditingDriver) { self.driver=driver }
    public func send(contextID:String,token:String,expected:MailDraft,review:SendReview,consume:@escaping @Sendable (MailDraft) throws -> Void) async throws {
        guard !busy,expected.id < 0 else { throw BridgeFailure("A current native message binding is required for sending.") }
        busy=true; defer { busy=false }
        try Task.checkCancellation()
        try review.validate(draft:expected,editorToken:token)
        try await driver.send(contextID:contextID,token:token,expected:expected,review:review,consume:consume)
    }
    public func prepareReview(contextID:String,token:String,expected:MailDraft) async throws -> MailDraft {
        guard !busy,expected.id < 0 else { throw BridgeFailure("A current native message is required for this review.") }
        busy=true; defer { busy=false }
        try Task.checkCancellation()
        let live=try await driver.reviewSnapshot(contextID:contextID,token:token,expected:expected)
        try Task.checkCancellation()
        // The live count of pictures and files becomes part of what was reviewed.
        var reviewed=expected; reviewed.attachmentCount=live.attachmentCount
        guard live.id < 0,live.attachmentCount >= 0,live.fingerprint == reviewed.fingerprint else {
            throw BridgeFailure("The message changed or its attachments could not be verified. Refresh and review it again.")
        }
        return live
    }
    /// "Draft and save" means the draft is saved, not merely left open: ask Mail to save it.
    #if DEBUG
    public func probeStructure() async -> [String] {
        guard let mac=driver as? MacMailUIEditingDriver else { return ["probe: unavailable"] }
        return await mac.probeStructure()
    }
    #endif
    /// Dot's finished files, attached in the message just after the reply Mail Dot typed.
    public func attachFiles(_ urls:[URL],contextID:String,token:String,expected:MailDraft) async throws -> MailDraft {
        guard !busy else { throw BridgeFailure("Another native message edit is in progress.") }
        busy=true; defer { busy=false }
        return try await driver.attachFiles(urls,contextID:contextID,token:token,expected:expected)
    }
    /// A new message's subject line, typed into its empty Subject field after Dot's message is in place.
    public func setSubject(_ subject:String,contextID:String,token:String) async throws {
        guard !busy else { throw BridgeFailure("Another native message edit is in progress.") }
        busy=true; defer { busy=false }
        try await driver.setSubject(subject,contextID:contextID,token:token)
    }
    public func save(contextID:String,token:String) async -> Bool {
        guard !busy else { return false }
        busy=true; defer { busy=false }
        return await driver.requestSave(contextID:contextID,token:token)
    }
    public func verifyUnchanged(contextID:String,token:String,expected:MailDraft) async throws {
        guard !busy else { throw BridgeFailure("Another native message edit is in progress.") }
        busy=true; defer { busy=false }
        try Task.checkCancellation()
        let live=try await driver.readback(contextID:contextID,token:token,matching:expected)
        guard live.fingerprint == expected.fingerprint else {
            throw BridgeFailure("The message changed in Mail after application. Refresh its context and review again.")
        }
    }
    public func bind(contextID:String,matching envelope:MailDraft,native:MailDraft?=nil) async throws -> MailUIReplyBinding {
        guard !busy else { throw BridgeFailure("Another native message edit is in progress.") }
        busy=true; defer { busy=false }
        let binding=try await driver.bind(contextID:contextID,matching:envelope)
        let snapshot=try native.map { try ReplyCapturePolicy.reconcile(native:$0,visible:binding.snapshot) } ?? binding.snapshot
        return MailUIReplyBinding(token:binding.token,snapshot:snapshot)
    }
    /// Inserts Dot's reply at the top of the message, above the quoted mail, and leaves everything else in
    /// the message exactly as it is: nothing below the reply is selected or typed. `previous` is what Mail
    /// Dot typed there before, if anything, and is replaced. Returns the message as it now reads and what
    /// was typed.
    public func insertAtTop(_ reply:String,replacing previous:String,contextID:String,token:String,expected:MailDraft,authorize:@escaping @Sendable () throws -> Void = {}) async throws -> (draft:MailDraft,typed:String) {
        guard !busy else { throw BridgeFailure("Another native message edit is in progress.") }
        busy=true; defer { busy=false }
        guard expected.body.hasPrefix(previous) else { throw BridgeFailure("Dot’s earlier reply is no longer at the top of this message, so Mail Dot will not replace it. Nothing was typed.") }
        let remainder=String(expected.body.dropFirst(previous.count))
        let typed=ReplyInsertion.typed(reply:reply,above:remainder)
        let segments=try MailUIEditPolicy.segments(typed)
        try Task.checkCancellation()
        try authorize()
        try await driver.selectTop(contextID:contextID,token:token,expected:expected,replacing:previous)
        try authorize()
        do {
            for segment in segments {
                try Task.checkCancellation()
                try await driver.insert(segment,contextID:contextID,token:token,authorize:authorize)
            }
            let result=try await driver.readback(contextID:contextID,token:token,matching:expected)
            try MailUIEditPolicy.verify(result,text:typed+remainder,expected:expected)
            return (result,typed)
        } catch {
            let restored=await driver.restoreOriginal(contextID:contextID,token:token)
            throw BridgeFailure(restored
                ? "Mail Dot could not finish placing Dot’s reply, so it took out what it had typed. Your message is as it was. \(error.localizedDescription)"
                : "Mail Dot could not finish placing Dot’s reply and could not take out what it had typed. Look at the top of the message in Mail before continuing; the quoted mail was not touched. \(error.localizedDescription)")
        }
    }
    public func apply(_ text:String,contextID:String,token:String,expected:MailDraft,authorize:@escaping @Sendable () throws -> Void = {}) async throws -> MailDraft {
        guard !busy else { throw BridgeFailure("Another native message edit is in progress.") }
        busy=true; defer { busy=false }
        let segments=try MailUIEditPolicy.segments(text)
        try Task.checkCancellation()
        try authorize()
        try await driver.selectBody(contextID:contextID,token:token,expected:expected)
        try authorize()
        do {
            for segment in segments {
                try Task.checkCancellation()
                try await driver.insert(segment,contextID:contextID,token:token,authorize:authorize)
            }
            let result=try await driver.readback(contextID:contextID,token:token,matching:expected)
            try MailUIEditPolicy.verify(result,text:text,expected:expected)
            return result
        } catch {
            // Typing replaces the whole body, so a failure part-way would otherwise leave the reply damaged.
            let restored=await driver.restoreOriginal(contextID:contextID,token:token)
            throw BridgeFailure(restored
                ? "Mail Dot could not finish placing the text, so it put your original message back. Nothing was lost. \(error.localizedDescription)"
                : "Mail Dot could not finish placing the text and could not put your original message back. Inspect Mail before continuing. Your original text is kept under This message in the Mail Dot panel. \(error.localizedDescription)")
        }
    }
}
