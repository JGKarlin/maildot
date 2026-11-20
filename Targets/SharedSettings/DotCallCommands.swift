import AppKit
import BridgeCore

/// The owner's two voice commands, written the same way from every panel in Mail. Each only records the
/// request; the background Mail Dot app opens the call in
/// ChatGPT, and Dot is told of the request once the call is open.
@MainActor enum DotCallCommands {
    static let selectionKey="workWithDotSelectedAccounts"

    /// The accounts the owner last chose under Work with Dot, or every linked account if none was chosen.
    static func scope(_ available:[MailWorkflowAccount]) -> [String] {
        let allowed=Set(available.map(\.id))
        let remembered=UserDefaults.standard.stringArray(forKey:selectionKey).map{Set($0).intersection(allowed)}
        return (remembered.flatMap{$0.isEmpty ? nil : $0} ?? allowed).sorted()
    }
    /// Returns what to tell the owner if the request could not be recorded.
    @discardableResult static func call(contextID:String?=nil,questionID:String?=nil) -> String? {
        record { state,scope,allowed in _ = try state.requestCall(accountIDs:scope,allowedAccountIDs:allowed,contextID:contextID,questionID:questionID) }
    }
    /// Speaking the request to Dot inside a call needs ChatGPT's microphone set to Mail Dot Voice, and has
    /// not yet been seen working end to end. Until it has, it stays off and requests take the written route.
    static let voiceLineKey="voiceLineEnabled"
    static var voiceLineEnabled:Bool { UserDefaults.standard.bool(forKey:voiceLineKey) }
    @discardableResult static func spokenReport() -> String? {
        record { state,scope,allowed in
            let request=try state.requestSpokenReport(accountIDs:scope,allowedAccountIDs:allowed)
            // Without the voice line the request goes to Dot in writing at once, and no call is opened.
            if !voiceLineEnabled { state.recordCallLaunch(requestID:request.id,started:false,note:nil,prompted:false) }
        }
    }
    /// Sends Dot the owner's request on a reply as it now stands, once the message has been read from Mail
    /// and only if Dot has not been sent it already. Returns what to tell the owner if it could not be sent.
    @discardableResult static func tellDotAboutReply(contextID:String) -> String? {
        do {
            let bridge=try BridgeStore.shared()
            guard let context=try bridge.read().contexts[contextID],BridgeCoordinator.dotIsOwedWord(context) else { return nil }
            // A draft or question Dot already wrote for this message is shown instead, and Dot is not asked
            // again. This is the one place every reply request passes through: the companion sends one the
            // moment it has read the message, before the panel could look for a stored draft (owner request, 13
            // November 2026: a message whose banner said Draft ready was drafted again on every reply).
            if StoredDraft.adopt(contextID:contextID) { return nil }
            // A reply to a message marked No reply needed waits here, in the one place every reply request passes, for
            // the owner's words on what to say (owner request, 20 November 2026).
            if !context.originalMessageID.isEmpty,
               BridgeCoordinator.waitsForOwnerWords(context,markedNoReplyNeeded:(try? MailTriageStore.shared().read())?.markedNoReplyNeeded(messageID:context.originalMessageID) ?? false) {
                return nil
            }
            // Dot is already drafting this message (it was offered to Dot when the owner opened it, or asked for in the
            // Mail Dot window): the reply waits for that draft or question, and Dot is not asked again. But the owner's own
            // words on the reply (Tell Dot, or an answer) take priority: the draft in progress is superseded, its answer is
            // not taken, and Dot is asked at once with those words (owner decision, 15 November 2026).
            if !context.originalMessageID.isEmpty,let triage=try? MailTriageStore.shared(),
               (try? triage.read())?.dotIsDrafting(messageID:context.originalMessageID) == true {
                let ownerSpoke=context.ownerRequest.map{ $0.direction != nil || !$0.answers.isEmpty } ?? false
                guard ownerSpoke else { return nil }
                if let superseded=(try? triage.transaction({ $0.supersedeDrafting(messageID:context.originalMessageID) })) ?? nil {
                    _ = record { state,_,_ in try state.dismiss(superseded) }
                }
            }
            // An answer the owner already gave Dot about this message, in the Mail Dot window, goes with this request, so
            // Dot does not ask the same question again (owner report, 17 November 2026). Placed after the check above:
            // while Dot is still drafting from that answer, the reply waits for that draft instead.
            if !context.originalMessageID.isEmpty,let entry=(try? MailTriageStore.shared().read())?.entry(forMessageID:context.originalMessageID),entry.ownerAnswer != nil {
                try bridge.transaction { state in
                    guard var value=state.contexts[contextID] else { return }
                    if BridgeCoordinator.carryOwnerAnswer(question:entry.dotNote,answer:entry.ownerAnswer,into:&value) { state.contexts[contextID]=value }
                }
            }
            if let refusal=record({ state,scope,allowed in _ = try state.requestReply(accountIDs:scope,allowedAccountIDs:allowed,contextID:contextID) }) { return refusal }
            // The message's banner and the Mail Dot window show Drafting until the draft arrives, panel open or not.
            if !context.originalMessageID.isEmpty { try? MailTriageStore.shared().transaction { $0.noteReplyPanelDrafting(messageID:context.originalMessageID) } }
            try bridge.transaction { $0.contexts[contextID]?.ownerRequest?.toldDotAt = .now }
            return nil
        } catch { return error.localizedDescription }
    }
    /// Asks Dot to tidy the wording of a drafting rule the owner just entered. Returns a refusal, or nil.
    @discardableResult static func tidyRule(_ ruleID:String) -> String? {
        record { state,scope,allowed in
            state.requests.removeAll{$0.action == .ruleCleanup && $0.ruleID == ruleID && ![.ready,.failed].contains($0.stage)}
            try state.enqueue(MailWorkflowRequest(action:.ruleCleanup,accountIDs:scope,ruleID:ruleID),allowedAccountIDs:allowed)
        }
    }
    /// Sends one correspondent's drafting notes that wait for polish to Dot, in one request (owner decision, 14 November
    /// 2026). If it cannot be sent, the notes stop waiting and the owner's words stand. Returns a refusal, or nil.
    @discardableResult static func polishNotes(for address:String) -> String? {
        let key=SenderNotes.key(address)
        guard let settings=try? MailSettingsStore.shared(),let note=try? settings.read().senderNote(for:key),!note.waitingForPolish.isEmpty else { return nil }
        let refusal=record { state,scope,allowed in
            state.requests.removeAll{$0.action == .noteCleanup && $0.noteAddress == key && ![.ready,.failed].contains($0.stage)}
            try state.enqueue(MailWorkflowRequest(action:.noteCleanup,accountIDs:scope,noteAddress:key),allowedAccountIDs:allowed)
        }
        _ = try? settings.transaction { if refusal == nil { $0.markNotesPolishAsked(for:key) } else { $0.applyPolishedNotes(for:key,answer:nil) } }
        return refusal
    }
    /// The owner's answer to one of Dot's questions, given on the Mac. It is kept with the question and
    /// sent to Dot at once.
    @discardableResult static func answer(questionID:String,text:String) -> String? {
        record { state,scope,allowed in _ = try state.answerQuestion(questionID,with:text,accountIDs:scope,allowedAccountIDs:allowed) }
    }
    /// Dot is told to ask in these words, so a question holding both can be answered with one press.
    static func offersDeliveryChoice(_ question:OwnerQuestion) -> Bool {
        let text=question.text.lowercased()
        return text.contains("draft and save") && text.contains("draft and send")
    }
    private static func record(_ body:(inout MailWorkflowState,[String],Set<String>) throws -> Void) -> String? {
        do {
            let bridge=try BridgeStore.shared()
            let available=try MailWorkflowAccount.available(settings:MailSettingsStore(bridgeDirectory:bridge.directory).read(),native:NativeMailStore(bridgeDirectory:bridge.directory).read())
            guard !available.isEmpty else { throw BridgeFailure("Link an account under Accounts first, so Dot knows which mail you mean.") }
            try MailWorkflowStore(bridgeDirectory:bridge.directory).transaction { try body(&$0,scope(available),Set(available.map(\.id))) }
            wakeCompanion()
            return nil
        } catch { return error.localizedDescription }
    }
    static func wakeCompanion() {
        guard let url=URL(string:"mailbridge://operations") else { return }
        let configuration=NSWorkspace.OpenConfiguration()
        configuration.activates=false
        NSWorkspace.shared.open(url,configuration:configuration) { _,_ in }
    }
    /// One line on where a call or spoken report stands, in the owner's terms.
    static func progress(of request:MailWorkflowRequest) -> String? {
        guard request.report == nil else { return nil }
        if request.spoken == true {
            guard let launch=request.callLaunch else { return "Opening a call and asking Dot aloud for your mail report…" }
            return launch.note ?? (request.event.receiptAt != nil ? "Dot has your request. Mail Dot will read its report aloud when it arrives, usually within a minute or two." : "Asking Dot for the report. Mail Dot will read it aloud when it arrives.")
        }
        if request.action == .answer {
            return request.event.receiptAt != nil ? "Dot has your answer and is acting on it." : request.event.attempts >= 8 ? nil : "Sending your answer to Dot…"
        }
        guard request.opensCall else { return nil }
        guard let launch=request.callLaunch else { return "Telling Dot why you are calling, then opening the call in ChatGPT…" }
        if !launch.started { return launch.note ?? "The call was not opened. Press Start call on Dot’s page in ChatGPT." }
        if let doubt=launch.note { return doubt }
        if request.stage == .working { return "Dot is on the call." }
        return "The call is open in ChatGPT, and Mail Dot has told Dot why you are calling."
    }
}

/// A draft or question Dot wrote for a message before the owner replied to it: when it reviewed arriving
/// mail, when the owner opened the message, or in one of its reports.
enum StoredDraft {
    /// Puts it in the reply with this context, if there is one and the owner has not yet asked anything of
    /// their own. Returns whether it did.
    @discardableResult static func adopt(contextID:String) -> Bool {
        guard let bridge=try? BridgeStore.shared(),let current=try? bridge.read().contexts[contextID],current.proposal == nil,
              !current.originalMessageID.isEmpty,current.snapshot != nil else { return false }
        let triage=try? MailTriageStore.shared().read()
        if let asked=triage?.entry(forMessageID:current.originalMessageID),asked.outcome == .needsGuidance,let question=asked.dotNote {
            var adopted=false
            try? bridge.transaction { state in
                guard var value=state.contexts[contextID] else { return }
                if BridgeCoordinator.usePendingQuestion(question,context:&value) { state.contexts[contextID]=value; adopted=true }
            }
            return adopted
        }
        let entry=triage?.draft(forMessageID:current.originalMessageID)
        let reports=(try? ScheduledMailUpdateStore(bridgeDirectory:bridge.directory).read())?.preparedReply(forReplyTo:current)
        guard let found=entry.flatMap({ value in value.draft.map{($0,value.seenAt)} }) ?? reports.map({($0.text,$0.writtenAt)}) else { return false }
        let files=entry?.files ?? []
        var adopted=false
        try? bridge.transaction { state in
            guard var value=state.contexts[contextID] else { return }
            if BridgeCoordinator.usePreparedReply(found.0,writtenAt:found.1,tasksDone:entry?.tasksDone,files:files,context:&value) { state.contexts[contextID]=value; adopted=true }
        }
        // Files Dot finished with its automatic draft move to this reply.
        if adopted,let entry,!files.isEmpty { ReplyFiles.move(files,from:"triage-"+entry.id,to:contextID,bridgeDirectory:bridge.directory) }
        return adopted
    }
}
