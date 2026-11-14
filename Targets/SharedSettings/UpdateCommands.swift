import SwiftUI
import AppKit
import BridgeCore

/// One update as the workbench shows it.
struct UpdateEntry:Identifiable,Equatable {
    let record:ScheduledMailUpdateRecord
    let shown:MailUpdatePresentation
    let accountLabel:String
    let unlinked:Bool
    /// The request carrying the owner's instruction to Dot, while there is one.
    let request:MailWorkflowRequest?
    /// Whether Mail Dot holds a pending send confirmation for the draft's shared message: the only state in
    /// which a draft can be sent from here.
    let draftIsBound:Bool
    var id:String { record.id }
    var owner:MailUpdateOwnerState? { record.ownerState }
    var controls:[MailUpdatePrimary] { MailUpdatePrimary.controls(for:shown,owner:owner,draftIsBound:draftIsBound) }
    var chosenOption:MailUpdateOption? { owner?.chosen.flatMap{id in shown.decision?.options.first{$0.id == id}} }
    static func == (a:Self,b:Self) -> Bool {
        a.id == b.id && a.record.update.revision == b.record.update.revision && a.record.unread == b.record.unread && a.owner == b.owner
            && a.request?.revision == b.request?.revision && a.request?.event.receiptAt == b.request?.event.receiptAt && a.request?.event.attempts == b.request?.event.attempts
            && a.draftIsBound == b.draftIsBound && a.shown == b.shown && a.unlinked == b.unlinked
    }
    /// The instruction is with Dot, has failed, or is still leaving: one line, or nil when nothing is pending.
    var pending:(text:String,failed:Bool)? {
        guard owner?.handled == .instructed else { return nil }
        guard let request else { return ("Sent to Dot",false) }
        if request.stage == .failed { return ("Dot could not do this: "+(request.report?.summary ?? "no reason given"),true) }
        if request.event.attempts >= 8 { return ("Could not reach Dot. "+(request.event.lastError ?? ""),true) }
        return (request.event.receiptAt == nil ? "Sending to Dot…" : request.stage == .ready ? "Dot has acted; its report follows" : "Sent to Dot",false)
    }
}

/// The owner's actions on updates, written to the same stores from every place that offers them.
@MainActor enum UpdateCommands {
    /// How long an instruction waits before it leaves for Dot, so that it can be cancelled.
    static let grace:TimeInterval=5

    private static func stores() throws -> (ScheduledMailUpdateStore,MailWorkflowStore,URL) {
        let directory=try BridgeStore.shared().directory
        return (ScheduledMailUpdateStore(bridgeDirectory:directory),MailWorkflowStore(bridgeDirectory:directory),directory)
    }
    static func choose(_ entry:UpdateEntry,option:String) throws {
        try stores().0.transaction { try $0.choose(entry.id,revision:entry.record.update.revision,option:option) }
    }
    static func setRead(_ entry:UpdateEntry,_ read:Bool) throws {
        try stores().0.transaction { read ? try $0.markRead(entry.id,revision:entry.record.update.revision) : try $0.markUnread(entry.id) }
    }
    static func close(_ entry:UpdateEntry,as handled:MailUpdateOwnerState.Handled) throws {
        try stores().0.transaction { try $0.handle(entry.id,revision:entry.record.update.revision,as:handled,note:nil,requestID:nil) }
    }
    /// Carries the owner's choice or words to Dot as a request bound to the update's revision.
    static func instruct(_ entry:UpdateEntry,option:MailUpdateOption?,delivery:ProposalDelivery?,text:String?,closes:Bool) throws {
        let (updates,workflow,directory)=try stores()
        let update=entry.record.update
        let instruction=option.map{MailUpdateInstruction(kind:.option,updateID:update.id,scheduleID:update.scheduleID,revision:update.revision,optionID:$0.id,optionLabel:$0.label,effect:$0.effect,delivery:delivery)}
            ?? MailUpdateInstruction(kind:.discuss,updateID:update.id,scheduleID:update.scheduleID,revision:update.revision,text:text)
        try instruction.validate()
        let available=try MailWorkflowAccount.available(settings:MailSettingsStore(bridgeDirectory:directory).read(),native:NativeMailStore(bridgeDirectory:directory).read())
        var request=try MailWorkflowRequest(action:.instruction,accountIDs:update.accountIDs,instruction:instruction)
        request.event.nextAttemptAt=Date().addingTimeInterval(grace)
        try workflow.transaction { state in
            // An earlier instruction for the same update that never completed is replaced, not doubled.
            for earlier in state.requests where earlier.instruction?.updateID == update.id && earlier.instruction?.scheduleID == update.scheduleID { try state.dismiss(earlier.id) }
            try state.enqueue(request,allowedAccountIDs:Set(available.map(\.id)))
        }
        do {
            try updates.transaction { try $0.handle(entry.id,revision:update.revision,as:closes ? .closed : .instructed,note:instruction.summary,requestID:request.id) }
        } catch {
            try? workflow.transaction { try $0.dismiss(request.id) }
            throw error
        }
        DotCallCommands.wakeCompanion()
    }
    /// Takes back the owner's last act on the update. An instruction Dot has already received cannot be taken back.
    static func undo(_ id:String) throws {
        let (updates,workflow,_)=try stores()
        if let requestID=try updates.read().records.first(where:{$0.id == id})?.ownerState?.requestID,
           let request=try workflow.read().requests.first(where:{$0.id == requestID}),request.event.receiptAt != nil {
            throw BridgeFailure("Dot has already received this instruction, so it cannot be cancelled. Use Discuss with Dot to change it.")
        }
        if let requestID=try updates.transaction({ try $0.undo(id) }) { try workflow.transaction { try $0.dismiss(requestID) } }
    }
    /// Sends the instruction again after a failure, as a fresh request.
    static func retry(_ entry:UpdateEntry) throws {
        guard let instruction=entry.request?.instruction else { throw BridgeFailure("There is nothing to send again.") }
        try undoIgnoringDelivery(entry.id)
        let option=instruction.optionID.flatMap{id in entry.shown.decision?.options.first{$0.id == id}}
        try instruct(entry,option:option,delivery:instruction.delivery,text:instruction.text,closes:false)
    }
    private static func undoIgnoringDelivery(_ id:String) throws {
        let (updates,workflow,_)=try stores()
        if let requestID=try updates.transaction({ try $0.undo(id) }) { try workflow.transaction { try $0.dismiss(requestID) } }
    }
    /// The one confirmation to send, given from this view for a draft Mail Dot is already waiting to send.
    static func confirmSend(reference:String) throws {
        try BridgeStore.shared().transaction { state in
            guard let confirmation=state.contexts[reference]?.sendConfirmation else { throw BridgeFailure("This draft is no longer waiting for your confirmation. Open it in Mail.") }
            try BridgeCoordinator.confirmSend(contextID:reference,confirmationID:confirmation.id,state:&state)
        }
        DotCallCommands.wakeCompanion()
    }
}

/// Dot's reports under one heading of the list, in the order shown.
struct UpdateQueueGroup:Equatable {
    let status:MailUpdateStatus
    let entries:[UpdateEntry]
}

extension UpdateEntry {
    /// The Message-ID of the message this report concerns, when Dot gave one: what lets Mail open that message.
    var messageID:String? { record.update.messageIDs.sorted().first }

    /// Everything read once from the stores, from which any number of entries are made.
    private struct Surroundings {
        let records:[ScheduledMailUpdateRecord]
        let queue:MailUpdateQueue
        let settings:MailSettings
        let accounts:[MailWorkflowAccount]
        let requests:[MailWorkflowRequest]
        let state:BridgeState
        let sent:Set<String>
        init() throws {
            let bridge=try BridgeStore.shared(),directory=bridge.directory
            let updates=try ScheduledMailUpdateStore(bridgeDirectory:directory).read()
            records=updates.records
            settings=try MailSettingsStore(bridgeDirectory:directory).read()
            accounts=try MailWorkflowAccount.available(settings:settings,native:NativeMailStore(bridgeDirectory:directory).read())
            requests=try MailWorkflowStore(bridgeDirectory:directory).read().requests
            state=try bridge.read()
            sent=Set(state.operations.filter{$0.kind == "send" && $0.result != nil && $0.error == nil}.map(\.contextID))
            queue=MailUpdateQueue(updates,sentReferences:sent)
        }
        func entry(_ record:ScheduledMailUpdateRecord) -> UpdateEntry {
            let label=record.update.accountIDs.map{id in accounts.first{$0.id == id}?.label ?? "Unavailable account"}.joined(separator:", ")
            let bound=record.update.draft?.reference.map{state.contexts[$0]?.sendConfirmation != nil} ?? false
            return UpdateEntry(record:record,shown:MailUpdatePresentation(record.update,sentReferences:sent),accountLabel:label,
                               unlinked:!record.update.authorized(settings:settings,accounts:accounts),
                               request:record.ownerState?.requestID.flatMap{id in requests.first{$0.id == id}},draftIsBound:bound)
        }
    }
    /// Reads one update as it stands now, with everything the panel needs, off the main thread.
    static func load(recordID:String) async throws -> UpdateEntry? {
        try await Task.detached { () -> UpdateEntry? in
            let all=try Surroundings()
            return all.records.first{$0.id == recordID}.map(all.entry)
        }.value
    }
    /// Reads every report the owner has not ignored or closed, grouped by where it stands.
    static func loadQueue() async throws -> [UpdateQueueGroup] {
        try await Task.detached { () -> [UpdateQueueGroup] in
            let all=try Surroundings()
            return all.queue.groups.map{UpdateQueueGroup(status:$0.status,entries:$0.records.map(all.entry))}
        }.value
    }
}
