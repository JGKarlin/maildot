import Foundation

/// One short question Dot needs the owner to answer when no call is open: how to revise, whether to
/// draft and save or draft and send, or anything else only the owner can settle. Mail Dot shows it on
/// the Mac with a Call Dot command. A question grants nothing and answers nothing by itself.
public struct OwnerQuestion:Codable,Sendable,Identifiable,Equatable {
    public static let limit=5
    public static let textLimit=600
    public static let lifetime:TimeInterval=86_400

    public let id:String
    public let text:String
    /// The shared message the question concerns, when Dot named one. An association, never authority.
    public let contextID:String?
    public let askedAt:Date
    /// Set once the Mac has shown the question, so it is announced a single time.
    public var notifiedAt:Date?
    /// The owner's own answer, given on the Mac, and when. Dot reads it; it stays until Dot has acted on it.
    public var answer:String?
    public var answeredAt:Date?

    /// One paragraph of plain text: surrounding space removed and inner runs of space or line breaks
    /// reduced to single spaces. Nil when nothing is left, it is too long, or it holds control characters.
    public static func normalized(_ text:String) -> String? {
        let plain=text.split(whereSeparator:{$0 == " " || $0.isNewline || $0 == "\t"}).joined(separator:" ")
        guard !plain.isEmpty,plain.utf8.count <= textLimit,
              !plain.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { return nil }
        return plain
    }
}

extension MailWorkflowState {
    /// Records Dot's question, or returns the open question with the same words.
    public mutating func ask(_ text:String,contextID:String?,now:Date=Date()) throws -> OwnerQuestion {
        expireQuestions(now:now)
        guard let plain=OwnerQuestion.normalized(text) else {
            throw BridgeFailure("Ask one plain question of at most \(OwnerQuestion.textLimit) characters.")
        }
        guard contextID.map({UUID(uuidString:$0) != nil}) ?? true else {
            throw BridgeFailure("context_id must be the identifier of a shared message, or be omitted.")
        }
        if let open=questions.first(where:{$0.text == plain}) { return open }
        guard questions.count < OwnerQuestion.limit else {
            throw BridgeFailure("The owner already has \(OwnerQuestion.limit) unanswered questions from you. Wait for an answer, or close a question that no longer matters.")
        }
        let question=OwnerQuestion(id:UUID().uuidString,text:plain,contextID:contextID,askedAt:now,notifiedAt:nil,answer:nil,answeredAt:nil)
        questions.append(question)
        return question
    }
    /// The owner answered on the Mac. The answer is kept with the question and sent to Dot at once as a
    /// request of its own; a changed answer replaces the earlier one.
    public mutating func answerQuestion(_ id:String,with text:String,accountIDs:[String],allowedAccountIDs:Set<String>,now:Date=Date()) throws -> MailWorkflowRequest {
        guard let index=questions.firstIndex(where:{$0.id == id}) else { throw BridgeFailure("That question is no longer open.") }
        guard let plain=OwnerQuestion.normalized(text) else {
            throw BridgeFailure("Give a plain answer of at most \(OwnerQuestion.textLimit) characters.")
        }
        var request=try MailWorkflowRequest(action:.answer,accountIDs:accountIDs,questionID:id,createdAt:now)
        request.event.nextAttemptAt=now
        for earlier in requests where earlier.action == .answer && earlier.questionID == id { try dismiss(earlier.id) }
        try enqueue(request,allowedAccountIDs:allowedAccountIDs)
        questions[index].answer=plain; questions[index].answeredAt=now
        return request
    }
    @discardableResult public mutating func closeQuestion(_ id:String) -> Bool {
        let before=questions.count
        questions.removeAll{$0.id == id}
        return questions.count != before
    }
    public mutating func expireQuestions(now:Date=Date()) {
        questions.removeAll{now.timeIntervalSince($0.askedAt) > OwnerQuestion.lifetime}
    }
}

extension MailWorkflowState {
    /// The owner pressed Call Dot. One call request stands at a time: a second press replaces the first,
    /// and the ChatGPT app shows the call already open rather than starting another.
    public mutating func requestCall(accountIDs:[String],allowedAccountIDs:Set<String>,contextID:String?=nil,questionID:String?=nil,now:Date=Date()) throws -> MailWorkflowRequest {
        if let questionID,!questions.contains(where:{$0.id == questionID}) { throw BridgeFailure("That question is no longer open.") }
        return try enqueueOpeningCall(MailWorkflowRequest(action:.call,accountIDs:accountIDs,contextID:contextID,questionID:questionID,createdAt:now),allowedAccountIDs:allowedAccountIDs,now:now)
    }
    /// The owner's request on the Mail Dot panel of a reply, sent to Dot as a request because that is the
    /// channel Dot acts on; the bare event for a shared message only draws an acknowledgment. A newer
    /// request for the same reply replaces one Dot has not finished.
    /// Dot has read this request: the moment it started on it, for the panel's progress line.
    public mutating func markRead(_ id:String,now:Date=Date()) {
        guard let index=requests.firstIndex(where:{$0.id == id}),requests[index].event.reviewedAt == nil else { return }
        requests[index].event.reviewedAt=now
    }
    /// Where the panel's newest request for a message stands, in Mail Dot's own records: when it was made,
    /// when ChatGPT accepted it, and when Dot first read it.
    public func replyProgress(contextID:String) -> (askedAt:Date,deliveredAt:Date?,readAt:Date?)? {
        guard let request=requests.last(where:{$0.action == .reply && $0.contextID == contextID}) else { return nil }
        return (request.createdAt,request.event.receiptAt,request.event.reviewedAt)
    }
    public mutating func requestReply(accountIDs:[String],allowedAccountIDs:Set<String>,contextID:String,now:Date=Date()) throws -> MailWorkflowRequest {
        requests.removeAll{$0.action == .reply && ($0.contextID == contextID || [.ready,.failed].contains($0.stage))}
        let request=try MailWorkflowRequest(action:.reply,accountIDs:accountIDs,contextID:contextID,createdAt:now)
        try enqueue(request,allowedAccountIDs:allowedAccountIDs)
        return request
    }
    /// The owner asked to hear the state of their mail. The request is first spoken to Dot in a call; the
    /// written route is held meanwhile and takes over if that cannot be done. A second press replaces the first.
    public mutating func requestSpokenReport(accountIDs:[String],allowedAccountIDs:Set<String>,now:Date=Date()) throws -> MailWorkflowRequest {
        try enqueueOpeningCall(MailWorkflowRequest(action:.status,accountIDs:accountIDs,spoken:true,createdAt:now),allowedAccountIDs:allowedAccountIDs,now:now)
    }
    /// The request was spoken to Dot in the call and Dot answers there, so nothing is left to wait for.
    public mutating func finishSpokenInCall(requestID:String) throws { try dismiss(requestID) }
    /// Spoken reports Dot has answered, ready or failed, that have not yet been read aloud and are recent
    /// enough that reading them will not surprise the owner.
    public func reportsToSpeak(now:Date=Date()) -> [MailWorkflowRequest] {
        requests.filter { $0.spoken == true && $0.spokenAloudAt == nil && [.ready,.failed].contains($0.stage) && $0.report != nil
            && now.timeIntervalSince($0.createdAt) <= MailWorkflowRequest.speakWindow }
    }
    public mutating func markSpoken(requestID:String,now:Date=Date()) {
        guard let index=requests.firstIndex(where:{$0.id == requestID}) else { return }
        requests[index].markSpoken(now:now)
    }
    private mutating func enqueueOpeningCall(_ request:MailWorkflowRequest,allowedAccountIDs:Set<String>,now:Date) throws -> MailWorkflowRequest {
        // Earlier requests of the same kind are superseded, finished or not, so the list does not fill with calls.
        for earlier in requests where earlier.opensCall && earlier.action == request.action { try dismiss(earlier.id) }
        var held=request
        held.event.nextAttemptAt=now.addingTimeInterval(MailWorkflowRequest.callHold)
        try enqueue(held,allowedAccountIDs:allowedAccountIDs)
        return held
    }
    /// Requests whose call the companion has still to open.
    public func callsAwaitingLaunch(now:Date=Date()) -> [MailWorkflowRequest] {
        requests.filter { $0.opensCall && $0.callLaunch == nil && $0.stage == .pending && now.timeIntervalSince($0.createdAt) <= MailWorkflowRequest.callLaunchWindow }
    }
    /// Requests that waited too long for the companion; they are marked, never launched.
    public func callsTooOldToLaunch(now:Date=Date()) -> [MailWorkflowRequest] {
        requests.filter { $0.opensCall && $0.callLaunch == nil && $0.stage == .pending && now.timeIntervalSince($0.createdAt) > MailWorkflowRequest.callLaunchWindow }
    }
    public mutating func recordCallLaunch(requestID:String,started:Bool,note:String?,prompted:Bool=false,now:Date=Date()) {
        guard let index=requests.firstIndex(where:{$0.id == requestID}) else { return }
        requests[index].recordCallLaunch(started:started,note:note,prompted:prompted,now:now)
    }
}
