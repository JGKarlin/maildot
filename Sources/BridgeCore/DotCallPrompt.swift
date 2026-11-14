import Foundation

/// The message Mail Dot sends to Dot, in the owner's name, just before it opens a call, so that Dot's
/// conversation holds the reason for the call. It is sent before the call because a message sent during
/// one is handled by Dot's written side and ignored by the voice (the owner's observation, 11 November
/// 2026). The voice still opens with its own greeting; nothing sent from outside changes that.
/// The text is fixed wording plus the request's identifier. It never contains anything from an email.
public enum DotCallPrompt {
    public static func text(for request:MailWorkflowRequest) -> String? {
        guard request.action == .call else { return nil }
        let read="Read Mail Dot request \(request.id) with get_mail_workflow now, so you know why before the call opens."
        if request.questionID != nil {
            return "Mail Dot: I am about to call you to answer the question you left for me. \(read) In the call, ask me that question first."
        }
        if request.contextID != nil {
            return "Mail Dot: I am about to call you from Mail about the message I have shared with you. \(read) In the call, ask first what I want done with it, including whether to draft and save or draft and send."
        }
        return "Mail Dot: I am about to call you from Mail. This call is about my mail. \(read) In the call, ask first what I need."
    }
}

/// What Mail Dot reads aloud when Dot answers a spoken mail report: Dot's own summary, unaltered except
/// that a very long one is cut between sentences.
public enum SpokenReport {
    public static let limit=1_500
    public static func text(for request:MailWorkflowRequest) -> String? {
        guard request.spoken == true,let report=request.report else { return nil }
        let summary=report.summary.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        let said=report.stage == .failed ? "Dot could not give the mail report. "+summary : summary
        guard said.count > limit else { return said }
        let head=String(said.prefix(limit))
        let cut=head.range(of:". ",options:.backwards).map{String(head[..<$0.lowerBound])+"."} ?? head
        return cut+" The rest is in Mail Dot."
    }
}

/// The words Mail Dot speaks into the call, in a synthesized voice the owner does not hear, so that Dot's
/// voice answers them at once. Fixed wording; nothing from an email. The owner's requirement: the request
/// must lead directly to the report, with no greeting and no confirmation of the connection first.
public enum DotVoicePrompt {
    public static func words(for request:MailWorkflowRequest) -> String? {
        if request.spoken == true {
            return "Dot, give me my spoken mail report now. Go straight to the report: no greeting, no check of the connection, and no questions first."
        }
        guard request.action == .call else { return nil }
        if request.questionID != nil { return "Dot, I am calling to answer the question you left for me in Mail Dot. No greeting. Ask me that question now." }
        if request.contextID != nil {
            return "Dot, I am calling about the message I have shared with you in Mail. No greeting. Ask me what I want done with it, including whether to draft and save or draft and send."
        }
        return "Dot, I am calling about my mail. No greeting. Ask me what I need."
    }
}
