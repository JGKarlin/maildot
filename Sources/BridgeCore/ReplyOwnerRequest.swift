import Foundation

/// What the owner asked for on the Mail Dot panel of one reply. Opening the panel asks Dot for a draft; the
/// owner then says there whether the reply is saved, sent or ignored, tells Dot how to draft, and answers
/// Dot's questions. Dot reads all of it with the message, so nothing has to be said by voice.
public struct ReplyOwnerRequest: Codable, Sendable, Equatable {
    public struct Answer: Codable, Sendable, Equatable {
        public var question: String
        public var answer: String
        public var at: Date
    }
    /// How much the owner may write to Dot about one reply (raised from 2000, owner's OK, 16 November 2026).
    public static let textLimit = 5000
    /// The owner set this message aside: no reply is wanted.
    public var ignored = false
    /// Draft and save, or draft and send, as pressed on the panel. Nil until the owner chooses.
    public var delivery: ProposalDelivery?
    /// How the owner wants the reply drafted, in their words.
    public var direction: String?
    /// The owner's answers to Dot's questions, the newest last.
    public var answers: [Answer] = []
    public var revision = 1
    public var updatedAt = Date()
    /// When the owner last asked something of Dot: the draft itself, a direction, or an answer. Until Dot
    /// reports after this, Dot is at work. Choosing save or send does not count; that asks nothing of Dot.
    public var askedAt = Date()
    /// When Dot was last sent a request about this reply. Dot is owed word whenever this is older than `askedAt`.
    public var toldDotAt: Date?
    /// The owner pressed Save Draft: once the reply is in the message, Mail is asked to save it to Drafts.
    /// Insert alone puts the reply in the message without asking Mail to save it.
    public var saveToDrafts: Bool?
    /// The draft in the panel is one Dot wrote ahead, during a scheduled review, and when it reviewed.
    public var preparedAt: Date?
    /// The state last shown to the owner in a notification, so that each is shown once.
    public var announced: String?
    /// When the owner pressed Confirm Send on the panel. Mail Dot then sends the reviewed draft itself, once.
    public var sendConfirmedAt: Date?
    public init() {}
}

extension BridgeCoordinator {
    /// Opening the panel on a reply is the request for a draft. Opening it again changes nothing.
    public static func ownerOpensPanel(context: inout ReplyContext, now: Date = .now) {
        guard context.ownerRequest == nil else { return }
        var request = ReplyOwnerRequest()
        // A reply Dot had already drafted before the panel was opened is not being waited for. A new message
        // asks nothing of Dot until the owner says what it should say.
        request.updatedAt = now; request.askedAt = context.proposal == nil && !context.isNewMessage ? now : .distantPast
        context.ownerRequest = request
    }

    private static func change(_ contextID: String, state: inout BridgeState, now: Date, _ body: (inout ReplyContext, inout ReplyOwnerRequest) throws -> Void) throws {
        guard var context = state.contexts[contextID] else { throw BridgeFailure("This message is no longer open in Mail Dot. Open the Mail Dot panel in it again.") }
        var request = context.ownerRequest ?? ReplyOwnerRequest()
        try body(&context, &request)
        request.revision += 1; request.updatedAt = now
        context.ownerRequest = request
        context.updatedAt = now
        // Dot learns of the change by a new event, once the message itself has been read from Mail.
        if context.snapshot != nil { context.event = BridgeEvent() }
        state.contexts[contextID] = context
    }

    /// Insert or Save Draft (both draft and save), or Send. A draft already written takes the choice at once.
    public static func ownerChooses(_ delivery: ProposalDelivery, saveToDrafts: Bool = false, contextID: String, state: inout BridgeState, now: Date = .now) throws {
        try change(contextID, state: &state, now: now) { context, request in
            request.delivery = delivery; request.ignored = false
            request.saveToDrafts = delivery == .save && saveToDrafts ? true : nil
            context.proposal?.delivery = delivery
            if delivery == .save { context.sendConfirmation = nil; context.review = nil; request.sendConfirmedAt = nil }
            context.localStatus = delivery == .send ? "You chose draft and send. Nothing is sent until you confirm here." : "You chose draft and save. Nothing will be sent."
        }
    }
    /// How to draft, in the owner's words. A later direction replaces an earlier one.
    public static func ownerDirects(_ text: String, contextID: String, state: inout BridgeState, now: Date = .now) throws {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, words.count <= ReplyOwnerRequest.textLimit else { throw BridgeFailure("Write what Dot should do, in at most \(ReplyOwnerRequest.textLimit) characters.") }
        try change(contextID, state: &state, now: now) { context, request in
            request.direction = words; request.ignored = false; request.askedAt = now
            context.localStatus = "Your direction was sent to Dot."
        }
    }
    /// The owner's answer to the question Dot is asking, by one press or in a line of text.
    public static func ownerAnswers(_ text: String, contextID: String, state: inout BridgeState, now: Date = .now) throws {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, words.count <= ReplyOwnerRequest.textLimit else { throw BridgeFailure("Write an answer of at most \(ReplyOwnerRequest.textLimit) characters.") }
        try change(contextID, state: &state, now: now) { context, request in
            guard let question = context.dotQuestion, !question.isEmpty else { throw BridgeFailure("Dot is not asking anything about this message now.") }
            request.answers = Array((request.answers + [ReplyOwnerRequest.Answer(question: question, answer: words, at: now)]).suffix(5))
            context.dotQuestion = nil; request.askedAt = now
            context.localStatus = "Your answer was sent to Dot."
        }
    }
    /// The drafts Dot gave with its question, kept only when there is one for each numbered answer and
    /// each is a usable reply; otherwise none, and an answer goes to Dot as before.
    public static func answerDrafts(_ drafts: [String]?, for context: ReplyContext) -> [String]? {
        guard let drafts, let question = context.dotQuestion else { return nil }
        let numbered = answers(in: question).answers
        let kept = drafts.map { ReplyInsertion.replyOnly($0, above: context.bodyBelowReply ?? "") }
        guard numbered.count >= 2, kept.count == numbered.count,
              kept.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 65_536 && ApplyLimits.refusal(for: $0) == nil }) else { return nil }
        return kept
    }
    /// The owner pressed a numbered answer for which Dot already wrote the reply: that reply becomes Dot's
    /// draft at once, and the answer is kept for any later request. Dot is not asked again. Returns false,
    /// changing nothing, when there is no such draft; the answer then goes to Dot as before.
    @discardableResult public static func ownerAnswersWithDraft(_ index: Int, contextID: String, state: inout BridgeState, now: Date = .now) throws -> Bool {
        guard var context = state.contexts[contextID], let question = context.dotQuestion, let drafts = context.answerDrafts,
              drafts.indices.contains(index), context.snapshot != nil else { return false }
        let parsed = answers(in: question)
        guard parsed.answers.indices.contains(index) else { return false }
        var request = context.ownerRequest ?? ReplyOwnerRequest()
        request.answers = Array((request.answers + [ReplyOwnerRequest.Answer(question: question, answer: parsed.answers[index], at: now)]).suffix(5))
        request.revision += 1; request.updatedAt = now
        var proposal = DotProposal(body: drafts[index], revision: (context.proposal?.revision ?? 0) + 1, snapshotRevision: context.snapshotRevision)
        proposal.delivery = request.delivery
        if context.isNewMessage { proposal.subject = context.proposal?.subject }
        context.proposal = proposal
        context.dotQuestion = nil; context.answerDrafts = nil
        context.ownerRequest = request
        context.lastDotUpdate = now
        context.localStatus = "Dot’s draft for your answer is ready."
        context.updatedAt = now
        state.contexts[contextID] = context
        return true
    }
    /// No reply is wanted. Anything ready to send is withdrawn, and Dot is told to leave the message alone.
    public static func ownerIgnores(contextID: String, state: inout BridgeState, now: Date = .now) throws {
        try change(contextID, state: &state, now: now) { context, request in
            request.ignored = true; request.sendConfirmedAt = nil; request.askedAt = now
            context.sendConfirmation = nil; context.review = nil
            context.localStatus = "You chose to ignore this message. Nothing was sent."
        }
    }
    /// The owner takes back Ignore.
    public static func ownerResumes(contextID: String, state: inout BridgeState, now: Date = .now) throws {
        try change(contextID, state: &state, now: now) { context, request in
            request.ignored = false; request.askedAt = now
            context.localStatus = "Dot was asked to draft this reply again."
        }
    }

    /// Shows, as Dot's draft for this reply, the reply Dot wrote ahead when it reviewed the message. Nothing
    /// is asked of Dot then, and nothing enters the message: the draft waits in the panel like any other.
    /// Returns false, changing nothing, if the reply already has a draft, was set aside, or is not yet read.
    @discardableResult public static func usePreparedReply(_ text: String, writtenAt: Date, tasksDone: [String]? = nil, files: [ReplyFile]? = nil, context: inout ReplyContext, now: Date = .now) -> Bool {
        guard var request = context.ownerRequest, !request.ignored, context.snapshot != nil, context.proposal == nil,
              request.direction == nil, request.answers.isEmpty else { return false }
        let reply = ReplyInsertion.replyOnly(text, above: context.bodyBelowReply ?? "")
        guard !reply.isEmpty, reply.utf8.count <= 65_536, ApplyLimits.refusal(for: reply) == nil else { return false }
        var proposal = DotProposal(body: reply, revision: 1, snapshotRevision: context.snapshotRevision)
        proposal.delivery = request.delivery
        proposal.tasksDone = tasksDone
        context.proposal = proposal
        if let files, !files.isEmpty { context.dotFiles = files }
        context.dotStatus = "Dot wrote this draft when it reviewed your mail."
        context.lastDotUpdate = now
        request.preparedAt = writtenAt; request.toldDotAt = now
        context.ownerRequest = request
        context.localStatus = "Dot’s draft, written when it reviewed your mail, is ready."
        context.updatedAt = now
        return true
    }

    /// Shows, as Dot's question on this reply, the question Dot already asked about the message it answers
    /// (from automatic drafting), so the panel presents it at once instead of starting a new run. Dot is not
    /// asked again until the owner answers. Returns false, changing nothing, unless the reply has no draft,
    /// no question and has not been sent to Dot yet.
    @discardableResult public static func usePendingQuestion(_ question: String, context: inout ReplyContext, now: Date = .now) -> Bool {
        guard var request = context.ownerRequest, !request.ignored, context.snapshot != nil, context.proposal == nil,
              context.dotQuestion == nil, request.toldDotAt == nil, request.direction == nil, request.answers.isEmpty,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        context.dotQuestion = question
        context.dotStatus = "Dot asked this when it read the message."
        context.lastDotUpdate = now
        request.toldDotAt = now
        context.ownerRequest = request
        context.updatedAt = now
        return true
    }

    /// Whether Dot has yet to be sent the owner's request as it now stands. Only once the message has been
    /// read from Mail, since until then there is nothing for Dot to draft from.
    public static func dotIsOwedWord(_ context: ReplyContext) -> Bool {
        guard context.snapshot != nil, let request = context.ownerRequest else { return false }
        // A new message waits for a recipient and for the owner's words on what it should say.
        if context.isNewMessage, request.direction == nil || context.envelope.to.isEmpty { return false }
        return request.toldDotAt.map { $0 < request.askedAt } ?? true
    }

    /// The owner's Confirm Send on the panel: the one confirmation a send needs. It queues the review of the
    /// exact draft, as every confirmation does, and records that Mail Dot is to send once that is granted.
    public static func confirmSendFromPanel(contextID: String, confirmationID: String, state: inout BridgeState, now: Date = .now) throws {
        try confirmSend(contextID: contextID, confirmationID: confirmationID, state: &state, now: now)
        guard state.contexts[contextID]?.ownerRequest?.delivery == .send else { return }
        state.contexts[contextID]?.ownerRequest?.sendConfirmedAt = now
    }

    /// After the review of the exact draft is granted: queues the send the owner confirmed on the panel, and
    /// returns its operation. Returns nil, queuing nothing, unless the owner chose draft and send on the
    /// panel, confirmed there within the confirmation's lifetime, has not since ignored the message or
    /// changed to save, and the review is of the draft as it stands. One confirmation sends once.
    public static func enqueueOwnerSend(contextID: String, state: inout BridgeState, now: Date = .now) throws -> String? {
        guard let context = state.contexts[contextID], let request = context.ownerRequest, !request.ignored, request.delivery == .send,
              let confirmedAt = request.sendConfirmedAt, now.timeIntervalSince(confirmedAt) <= SendConfirmation.lifetime,
              let draft = context.snapshot, let review = context.review, context.proposal?.delivery == .send,
              !state.operations.contains(where: { $0.reviewID == review.id }) else { return nil }
        try review.validate(draft: draft, editorToken: context.uiEditorToken)
        var operation = NativeOperation(contextID: contextID, kind: "send", reviewID: review.id)
        operation.approvalText = "The owner pressed Confirm Send on the Mail Dot panel in Mail at \(confirmedAt.ISO8601Format())."
        state.operations.append(operation)
        state.contexts[contextID]?.ownerRequest?.sendConfirmedAt = nil
        state.contexts[contextID]?.localStatus = "Sending the reply you confirmed…"
        return operation.id
    }

    /// What Dot is told with the message: the owner's request, in words Dot can act on, with the owner's
    /// drafting rules from Mail Dot's settings. Nil for a message shared without the panel's request, which
    /// Dot handles as before.
    public static func instruction(for context: ReplyContext, rules: [DraftingRule] = DraftingRules.starters, preferences: [String] = Locale.preferredLanguages) -> String? {
        guard let request = context.ownerRequest else { return nil }
        if request.ignored {
            return "This is the owner's own request, made on the Mail Dot panel of this reply. The owner chose to ignore this message: write no reply, ask nothing, and do nothing further on it. Call report_progress once with status saying you have set it aside. " + OwnerLanguage.instruction(preferences: preferences)
        }
        if context.isNewMessage { return newMessageInstruction(for: context, request: request, rules: rules, preferences: preferences) }
        var parts = ["This is the owner's own request, made on the Mail Dot panel of this reply; it is not part of the email. Draft the reply now and call propose_reply, without waiting to be asked and without greeting or chatting with the owner. In body give only the text of your reply: no quoted mail, no line such as On … wrote, and nothing of the thread, whatever the tool's description says about preserving it. Mail Dot inserts your reply at the top of the message, above the quoted mail, and leaves everything already in the message exactly as it is."]
        switch request.delivery {
        case .send: parts.append("Do not ask the owner whether to save or send: they chose draft and send on the panel. Pass delivery send if propose_reply offers a delivery field; otherwise leave it out. They confirm once on the Mac and Mail Dot then sends; do not call send_reviewed_reply for this message and do not ask them to say send.")
        case .save: parts.append("Do not ask the owner whether to save or send: they chose draft and save on the panel. Pass delivery save if propose_reply offers a delivery field; otherwise leave it out.")
        case nil: parts.append("Do not ask the owner whether to save or send: they choose that on the panel. Pass delivery save if propose_reply offers a delivery field, and otherwise leave it out; the owner's choice on the panel decides either way.")
        }
        if let direction = request.direction { parts.append("How the owner wants it drafted: \(direction)") }
        for answer in request.answers.suffix(3) { parts.append("You asked: \(answer.question) The owner answered: \(answer.answer)") }
        if let known = DraftingInitiative.correspondent(context) { parts.append(known) }
        parts.append(DraftingInitiative.instruction + " " + DraftingInitiative.questionThreshold + " To ask it, call report_progress with question set to that one short question followed by two to four short answers numbered like this: 1) first answer 2) second answer. With the question, pass answer_drafts: the complete reply you would write for each numbered answer, in the same order, each only the reply text; then one press shows that reply at once, with no further request to you. The owner answers with one press, or in a line of text, and an answer without a draft comes back to you here. Keep status to one short plain sentence the owner will read, such as Drafting your reply.")
        parts.append(ReplyFiles.instruction + " For this reply, attach_reply_file takes context_id.")
        if let owned = DraftingRules.instruction(rules) { parts.append(owned) }
        parts.append(OwnerLanguage.instruction(preferences: preferences))
        return parts.joined(separator: " ")
    }

    /// What Dot is told for a new message: whom it is to, what the owner wants it to say, and that Dot writes
    /// both the message and its subject line.
    private static func newMessageInstruction(for context: ReplyContext, request: ReplyOwnerRequest, rules: [DraftingRule], preferences: [String]) -> String {
        let recipients = (context.envelope.to + context.envelope.cc).joined(separator: ", ")
        var parts = ["This is the owner's own request, made on the Mail Dot panel of a new message they are writing in Mail; it is not a reply. It is addressed to \(recipients.isEmpty ? "the recipients in its To field" : recipients). Write the message now and call propose_reply, without greeting or chatting with the owner. Learn who the recipient is to the owner first: their earlier mail with this person, how they write to them, and anything in your sources about them or the subject. In body give only the text of the message. Also write a short, specific subject line: pass it as subject if propose_reply offers a subject field; otherwise make the first line of body exactly Subject: followed by the subject line, then a blank line, then the message. Mail Dot puts the message at the top of the new message and fills in the subject. Do not ask the owner whether to save or send: they choose that on the panel."]
        if let direction = request.direction { parts.append("What the owner wants this message to say: \(direction)") }
        // A subject the owner typed is theirs: Dot writes to it and does not replace it.
        let given = (context.snapshot?.subject.isEmpty == false ? context.snapshot?.subject : nil) ?? (context.envelope.subject.isEmpty ? nil : context.envelope.subject)
        if let given { parts.append("The owner has already given this message its subject line: \(given). Keep it exactly: write the message to fit that subject and refer to what it names, and do not write or pass a different subject.") }
        for answer in request.answers.suffix(3) { parts.append("You asked: \(answer.question) The owner answered: \(answer.answer)") }
        if let known = DraftingInitiative.correspondent(context) { parts.append(known) }
        parts.append(DraftingInitiative.instruction + " " + DraftingInitiative.questionThreshold + " To ask it, call report_progress with question set to that one short question followed by two to four short answers numbered like this: 1) first answer 2) second answer. Keep status to one short plain sentence the owner will read, such as Drafting your message.")
        parts.append(ReplyFiles.instruction + " For this message, attach_reply_file takes context_id.")
        if let owned = DraftingRules.instruction(rules) { parts.append(owned) }
        parts.append("Language: write the message in the language the owner uses with this recipient in earlier mail, or, if there is none, the language of the owner's request. " + OwnerLanguage.instruction(preferences: preferences).replacingOccurrences(of: "Language: write the reply itself in the language of the message it answers. ", with: ""))
        return parts.joined(separator: " ")
    }

    /// For a new message: Dot's subject line and the message, from a body whose first line is "Subject: …",
    /// as Dot is told to write it when propose_reply has no subject field. Nil when there is no such line.
    public static func subjectLine(in body: String) -> (subject: String, body: String)? {
        let lines = body.components(separatedBy: "\n")
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces) else { return nil }
        let markers = ["Subject:", "件名:", "件名："]
        guard let marker = markers.first(where: { first.hasPrefix($0) }) else { return nil }
        let subject = first.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        guard !subject.isEmpty, subject.count <= 200 else { return nil }
        let rest = lines.dropFirst().drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty }).joined(separator: "\n")
        guard !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (subject, rest)
    }

    /// Dot's question divided into the question and its numbered answers, written "1) … 2) …" or "1. … 2. …".
    /// Fewer than two numbered answers in order means the text is only a question.
    public static func answers(in text: String) -> (question: String, answers: [String]) {
        // Full-width and circled numerals, and the brackets and commas Japanese text uses, read as "1) ".
        var plain = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        for (index, mark) in ["①","②","③","④","⑤","⑥"].enumerated() { plain = plain.replacingOccurrences(of: mark, with: " \(index + 1)) ") }
        guard let pattern = try? NSRegularExpression(pattern: "(?:^|\\s)\\(?([1-6])[\\).、､,:]\\s*(?=\\S)") else { return (text, []) }
        let text = plain
        let whole = text as NSString
        let marks = pattern.matches(in: text, range: NSRange(location: 0, length: whole.length))
        // The answers are the last run of marks numbered 1, 2, 3… in order.
        guard let start = marks.lastIndex(where: { whole.substring(with: $0.range(at: 1)) == "1" }) else { return (text, []) }
        let run = Array(marks[start...])
        guard run.count >= 2, run.enumerated().allSatisfy({ whole.substring(with: $1.range(at: 1)) == String($0 + 1) }) else { return (text, []) }
        var found: [String] = []
        for (index, mark) in run.enumerated() {
            let from = mark.range.location + mark.range.length
            let to = index + 1 < run.count ? run[index + 1].range.location : whole.length
            found.append(whole.substring(with: NSRange(location: from, length: to - from)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let question = whole.substring(to: run[0].range.location).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, found.allSatisfy({ !$0.isEmpty && $0.count <= 120 }) else { return (text, []) }
        return (question, found)
    }
}
