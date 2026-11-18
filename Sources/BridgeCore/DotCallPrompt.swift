import Foundation

/// The message Mail Dot sends to Dot, in the owner's name, as it opens a call, so that Dot's conversation holds
/// the reason for the call. Until 18 November 2026 it was sent before the call, because on 11 November a message
/// sent during one was ignored by the voice; in the owner's trial of 18 November the voice greeted him without the
/// request when the message came first, and acknowledged it at once when the message was sent into the open call,
/// so it now goes into the call (`callOpen`). It says what Dot's next words are (owner's instruction, 18 November
/// 2026): Dot says it has the Mail Dot request and, while it is still reading it, asks the owner to hold on; if it
/// cannot read it, it says so. Only then comes what the call is about. The wording for an open call is the one the
/// owner heard work; the other is kept for the earlier order.
/// The text is fixed wording plus the request's identifier. It never contains anything from an email.
public enum DotCallPrompt {
    /// What Dot's first words in the call are, whatever the call is about.
    public static let opening="When the call opens, first tell me you have my Mail Dot request and, if you are still reading it, ask me to hold on while you look into it. If you cannot read it, say \"I couldn't load the Mail Dot context\"."
    /// The same, for a message sent into a call that is already open (the other order, tried on the owner's Mac).
    public static let openingInCall="Now tell me you have my Mail Dot request and, if you are still reading it, ask me to hold on while you look into it. If you cannot read it, say \"I couldn't load the Mail Dot context\"."
    public static func text(for request:MailWorkflowRequest,callOpen:Bool=false) -> String? {
        guard request.action == .call else { return nil }
        let read="Read Mail Dot request \(request.id) with get_mail_workflow now."
        let calling=callOpen ? "I have just called you" : "I am about to call you"
        let first=callOpen ? openingInCall : opening
        if request.questionID != nil {
            return "Mail Dot: \(calling) to answer the question you left for me. \(read) \(first) Then put that question to me."
        }
        if request.contextID != nil {
            return "Mail Dot: \(calling) from Mail about the message I have shared with you. \(read) \(first) Then ask what I want done with it, including whether to draft and save or draft and send."
        }
        return "Mail Dot: \(calling) from Mail. This call is about my mail. \(read) \(first) Then ask what I need help with in my mail."
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
