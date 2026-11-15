import Foundation

public enum BridgeCoordinator {
    /// MailKit's header callback is an observation, never an instruction to Dot or a body read.
    public static func observeEnvelope(_ draft:MailDraft,context:inout ReplyContext) {
        let changed = headers(context.envelope).fingerprint != headers(draft).fingerprint
        context.envelope = headers(draft)
        context.envelopeObservedAt = .now
        guard changed else { return }
        context.snapshot = nil; context.review = nil; context.sendConfirmation = nil; context.event = nil; context.uiEditorToken=nil
        context.snapshotRevision += 1
        context.proposal?.appliedFingerprint = nil
        context.updatedAt = .now
        context.localStatus = "Mail's header fields changed. Share the current message and review it again before applying text or sending."
    }

    private static func headers(_ value:MailDraft) -> MailDraft {
        var result = value
        result.id = -1; result.body = ""; result.attachmentCount = -1
        return result
    }

    public static func completeShare(_ draft:MailDraft,contextID:String,expectedRevision:Int,
                                     expectedEnvelope:MailDraft,state:inout BridgeState) throws {
        guard var context = state.contexts[contextID], context.snapshotRevision == expectedRevision,
              headers(context.envelope).fingerprint == headers(expectedEnvelope).fingerprint else {
            throw BridgeFailure("Mail's headers or shared context changed while reading. Share the current message again.")
        }
        share(draft,with:&context)
        state.contexts[contextID] = context
        state.activeContextID = contextID
    }

    public static func share(_ draft: MailDraft, with context: inout ReplyContext) {
        context.uiEditorToken=nil
        context.sendConfirmation = nil
        if context.snapshot?.fingerprint != draft.fingerprint {
            context.snapshotRevision += 1
            context.review = nil
        }
        // If the top of the message is no longer what Mail Dot typed there, it is the owner's text now.
        if let top = context.insertedTop, !draft.body.hasPrefix(top) { context.insertedTop = nil }
        context.snapshot = draft
        context.envelope = draft
        context.event = BridgeEvent()
        context.updatedAt = .now
        context.localStatus = "Context shared. Speak to Dot to direct the work."
    }

    public static func propose(_ body: String, expectedRevision: Int, expectedProposalRevision: Int = 0,
                               eventID: String?, delivery: ProposalDelivery? = nil, subject: String? = nil, tasksDone: [String]? = nil, context: inout ReplyContext) throws {
        guard context.snapshot != nil, context.snapshotRevision == expectedRevision else {
            throw BridgeFailure("Mail context changed. Read the current message before updating it.")
        }
        guard (context.proposal?.revision ?? 0) == expectedProposalRevision else {
            throw BridgeFailure("The proposed text changed. Read and preserve the current version before revising it.")
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf8.count <= 65_536 else {
            throw BridgeFailure("Reply text must contain 1–65536 UTF-8 bytes.")
        }
        if let eventID, context.event?.id != eventID { throw BridgeFailure("This event does not belong to the current context.") }
        if let refusal = ApplyLimits.refusal(for: body) { throw BridgeFailure(refusal) }
        if context.ownerRequest?.ignored == true { throw BridgeFailure("The owner chose to ignore this message in Mail, so no reply is wanted. Do nothing further on it.") }
        // The owner's latest words came after this run read the reply: they take priority, and this draft is not taken.
        if let request = context.ownerRequest, request.direction != nil || !request.answers.isEmpty,
           let read = context.dotReadAt, read < request.askedAt {
            throw BridgeFailure("The owner gave new instructions for this reply after you read it. Read the reply again and write it as they now ask; this draft was not taken.")
        }
        // On the panel's request the reply is inserted above the quoted mail, so only the reply itself is
        // kept: a thread Dot repeated below it is cut off.
        var body = context.ownerRequest == nil ? body : ReplyInsertion.replyOnly(body, above: context.bodyBelowReply ?? "")
        // A new message carries its subject line, given as subject or as the body's first line.
        var subjectLine = subject?.trimmingCharacters(in: .whitespacesAndNewlines)
        if context.isNewMessage, let split = BridgeCoordinator.subjectLine(in: body) { body = split.body; if subjectLine?.isEmpty ?? true { subjectLine = split.subject } }
        if let line = subjectLine, line.isEmpty || line.count > 200 || line.contains("\n") { subjectLine = nil }
        var proposal = DotProposal(body: body, revision: expectedProposalRevision + 1, snapshotRevision: expectedRevision)
        // A subject the owner typed stays; Dot's is used only for a message that has none.
        if context.isNewMessage, (context.snapshot?.subject ?? "").isEmpty, context.envelope.subject.isEmpty { proposal.subject = subjectLine }
        let done = (tasksDone ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && $0.count <= 200 }.prefix(8)
        proposal.tasksDone = done.isEmpty ? nil : Array(done)
        // What the owner pressed on the Mac outranks what Dot reports of it.
        proposal.delivery = context.ownerRequest?.delivery ?? delivery
        context.proposal = proposal
        context.dotQuestion = nil
        context.answerDrafts = nil
        context.review = nil
        context.sendConfirmation = nil
        context.localStatus = "New wording from Dot is ready for review. Apply it to update the message in Mail."
        context.lastDotUpdate = .now
        context.updatedAt = .now
        if eventID != nil { context.event?.reviewedAt = .now }
    }

    /// After Dot's text is verified in the Mail draft in "draft and send" mode: ask for the owner's
    /// confirming act. This grants nothing, and any earlier readiness is withdrawn.
    public static func requestSendConfirmation(context: inout ReplyContext, now: Date = .now) throws {
        guard let snapshot = context.snapshot, let proposal = context.proposal, proposal.delivery == .send,
              proposal.appliedFingerprint == snapshot.fingerprint else {
            throw BridgeFailure("Only a reply that Dot drafted to send, and that is now in the Mail draft, can be offered for confirmation.")
        }
        context.review = nil
        context.sendConfirmation = SendConfirmation(fingerprint: snapshot.fingerprint, snapshotRevision: context.snapshotRevision, requestedAt: now)
        context.localStatus = "Dot's text is in the Mail draft. Confirm on this Mac before Dot can send it. Nothing has been sent."
        context.updatedAt = now
    }

    /// The owner's press, from the panel or the notification. It queues the ordinary native review of the
    /// exact draft that was offered; a draft that has changed since, or an old request, is refused.
    public static func confirmSend(contextID: String, confirmationID: String, state: inout BridgeState, now: Date = .now) throws {
        guard let context = state.contexts[contextID], let confirmation = context.sendConfirmation,
              confirmation.id == confirmationID, now.timeIntervalSince(confirmation.requestedAt) <= SendConfirmation.lifetime,
              context.snapshot?.fingerprint == confirmation.fingerprint, context.snapshotRevision == confirmation.snapshotRevision else {
            throw BridgeFailure("This confirmation is no longer current, so nothing will be sent. Ask Dot to prepare the reply again.")
        }
        try enqueueReview(contextID: contextID, displayedFingerprint: confirmation.fingerprint,
                          displayedRevision: confirmation.snapshotRevision, editorToken: context.uiEditorToken, state: &state)
        state.contexts[contextID]?.sendConfirmation = nil
    }

    /// The owner changes their mind: nothing stays ready to send.
    public static func withdrawSend(contextID: String, state: inout BridgeState) throws {
        guard state.contexts[contextID] != nil else { throw BridgeFailure("This message is no longer shared.") }
        state.contexts[contextID]?.sendConfirmation = nil
        state.contexts[contextID]?.review = nil
        state.contexts[contextID]?.localStatus = "Sending was withdrawn. Nothing will be sent unless you confirm again."
        state.contexts[contextID]?.updatedAt = .now
    }

    /// Called only after owner review and a fresh native attachment/body check.
    /// The caller must hold the state transaction across this mutation.
    public static func grantUIReview(live:MailDraft,displayedFingerprint:String,expectedRevision:Int,
                                     token:String,context:inout ReplyContext) throws {
        guard let displayed=context.snapshot,displayed.id < 0,live.id < 0,
              displayed.fingerprint == displayedFingerprint,context.snapshotRevision == expectedRevision,
              context.uiEditorToken == token,UUID(uuidString:token) != nil,
              context.snapshotRevision < Int.max else { throw BridgeFailure("The displayed message or editor binding changed. Review it again.") }
        // Pictures and files in the message (a reply's quoted photos, a signature logo) are allowed; their live
        // count is bound into the review, so the send goes only with exactly these (13 November 2026).
        var verified=displayed; verified.attachmentCount=live.attachmentCount
        guard live.attachmentCount >= 0,live.fingerprint == verified.fingerprint else {
            throw BridgeFailure("The message changed or attachments could not be verified. Refresh and review it again.")
        }
        let review=SendReview(draft:live,editorToken:token)
        try review.validate(draft:live,editorToken:token)
        if displayed.fingerprint != live.fingerprint {
            context.snapshotRevision += 1
            if context.proposal?.appliedFingerprint == displayedFingerprint,
               context.proposal?.snapshotRevision == expectedRevision {
                context.proposal?.appliedFingerprint=live.fingerprint
                context.proposal?.snapshotRevision=context.snapshotRevision
            }
        }
        context.snapshot=live; context.review=review; context.updatedAt = .now
        context.localStatus="This exact draft is ready for a direct voice send instruction for 10 minutes."
    }

    /// Must execute inside a durable store transaction immediately before UI dispatch.
    public static func consumeUISend(operationID:String,contextID:String,reviewID:String,
                                     expectedFingerprint:String,expectedRevision:Int,token:String,
                                     live:MailDraft,state:inout BridgeState,now:Date = .now) throws {
        let operations=state.operations.filter{$0.id == operationID}
        guard operations.count == 1,let operation=operations.first,
              operation.contextID == contextID,operation.kind == "send",operation.reviewID == reviewID,
              operation.claimedAt != nil,operation.result == nil,operation.error == nil,
              var context=state.contexts[contextID],context.snapshotRevision == expectedRevision,
              context.snapshot?.fingerprint == expectedFingerprint,context.uiEditorToken == token,
              live.id < 0,live.fingerprint == expectedFingerprint else {
            throw BridgeFailure("The reviewed draft or send operation changed. Nothing was sent.")
        }
        // The age was checked when the action was claimed; the native checks since then take time. Check again
        // at the last moment, so Send cannot be pressed after Dot was told that no result arrived.
        if let refusal=operation.refusalIfTooOld(now:now) { throw BridgeFailure(refusal) }
        try consumeReview(reviewID,live:live,context:&context)
        state.contexts[contextID]=context
    }

    public static func consumeReview(_ reviewID: String, live: MailDraft, context: inout ReplyContext) throws {
        guard var review = context.review, review.id == reviewID else { throw BridgeFailure("No matching native review. Review the draft in Mail first.") }
        try review.validate(draft: live, editorToken: context.uiEditorToken)
        review.consumed = true
        context.review = review
        context.localStatus = "Submission requested for the reviewed draft. Do not retry if the outcome is uncertain."
    }

    public static func enqueueApply(contextID:String, displayedFingerprint:String, displayedProposalRevision:Int,
                                    reviewedBody:String, state:inout BridgeState) throws {
        guard var context = state.contexts[contextID], context.snapshot?.fingerprint == displayedFingerprint,
              var proposal = context.proposal, proposal.revision == displayedProposalRevision,
              proposal.snapshotRevision == context.snapshotRevision else {
            throw BridgeFailure("The displayed message or Dot's wording changed. Read the latest version before applying it.")
        }
        guard !reviewedBody.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, reviewedBody.utf8.count <= 65_536 else {
            throw BridgeFailure("Reply text must contain 1–65536 UTF-8 bytes.")
        }
        if let refusal = ApplyLimits.refusal(for: reviewedBody) { throw BridgeFailure(refusal) }
        if proposal.body != reviewedBody {
            proposal.body = reviewedBody; proposal.revision += 1; proposal.appliedFingerprint = nil
            context.review = nil
        }
        context.proposal = proposal
        var operation = NativeOperation(contextID:contextID,kind:"apply")
        operation.expectedFingerprint = displayedFingerprint; operation.proposalRevision = proposal.revision
        state.contexts[contextID] = context; state.operations.append(operation)
        state.contexts[contextID]?.localStatus = "Waiting for Mail to apply the reviewed text…"
    }

    public static func enqueueReview(contextID:String, displayedFingerprint:String, displayedRevision:Int?=nil,
                                     editorToken:String?=nil,state:inout BridgeState) throws {
        guard let context=state.contexts[contextID],let snapshot=context.snapshot,snapshot.fingerprint == displayedFingerprint else {
            throw BridgeFailure("The displayed draft changed. Read the latest version before marking it ready.")
        }
        if snapshot.id < 0 {
            guard let displayedRevision,displayedRevision == context.snapshotRevision,
                  let editorToken,UUID(uuidString:editorToken) != nil,editorToken == context.uiEditorToken else {
                throw BridgeFailure("The displayed editor or revision changed. Refresh and review the current message.")
            }
        }
        var operation = NativeOperation(contextID:contextID,kind:"review")
        operation.expectedFingerprint = displayedFingerprint
        operation.expectedSnapshotRevision=displayedRevision
        operation.expectedEditorToken=editorToken
        state.operations.append(operation)
        state.contexts[contextID]?.localStatus = "Checking the reviewed draft against Mail…"
    }
}
