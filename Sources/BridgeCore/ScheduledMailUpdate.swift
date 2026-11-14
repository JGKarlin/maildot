import Foundation
import CryptoKit

public enum ScheduledMailAction:String,Codable,Sendable {case none,decision,reply,reviewDraft,followUp,resolved}

/// A report from a linked Dot schedule, never an instruction to execute Mail actions.
public struct ScheduledMailUpdate:Codable,Sendable {
    public var id:String
    public var scheduleID:String
    public var runID:String
    public var revision:Int
    public var accountIDs:[String]
    public var sourceIDs:[String]
    public var title:String
    public var summary:String
    public var action:ScheduledMailAction
    public var actionText:String
    public var checkedAt:Date
    public var coverage:String
    // The structured fields the workbench shows (docs/updates-workbench-spec.md, section 2). All optional:
    // an update from before build 71 carries only the fields above.
    public var message:MailUpdateMessage?
    public var gist:String?
    public var summaryPoints:[String]?
    public var unverified:[String]?
    public var status:MailUpdateStatus?
    public var decision:MailUpdateDecision?
    public var work:[MailUpdateWork]?
    public var tags:[MailUpdateTag]?
    public var draft:MailUpdateDraft?
    public var key:String {"\(scheduleID.utf8.count):\(scheduleID)\(id)"}
    public func validate() throws {
        func text(_ value:String,_ limit:Int)->Bool {!value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && value.utf8.count <= limit}
        guard text(id,512),text(scheduleID,512),text(runID,512),revision >= 0,
              !accountIDs.isEmpty,accountIDs.count <= 30,Set(accountIDs).count == accountIDs.count,accountIDs.allSatisfy({text($0,1024)}),
              !sourceIDs.isEmpty,sourceIDs.count <= 30,Set(sourceIDs).count == sourceIDs.count,sourceIDs.allSatisfy({text($0,1024)}),
              text(title,512),text(summary,8192),text(coverage,2048),actionText.utf8.count <= 4096,
              [.none,.resolved].contains(action) || text(actionText,4096),
              checkedAt.timeIntervalSince1970.isFinite,checkedAt <= Date().addingTimeInterval(300) else {
            throw BridgeFailure("Invalid scheduled email update or missing source, coverage or action information.")
        }
        try validateStructure()
    }
    public func authorized(settings:MailSettings,accounts:[MailWorkflowAccount],submission:Bool=false)->Bool {
        guard settings.linkedScheduleIDs.contains(scheduleID),
              let schedule=settings.schedules.first(where:{$0.id == scheduleID && $0.available && $0.observedAt != nil}),
              !submission || schedule.enabled else {return false}
        return accountIDs.allSatisfy { id in
            guard let account=accounts.first(where:{$0.id == id}) else {return false}
            return schedule.sources.contains { source in
                source.kind == account.route && source.id == account.sourceID
                    && (account.route != "gmail" || source.connectionID == account.connectionID)
            }
        }
    }
}

public struct ScheduledMailUpdateRecord:Codable,Sendable,Identifiable {
    public let update:ScheduledMailUpdate
    public let receivedAt:Date
    public let sequence:Int
    public fileprivate(set) var readRevision:Int?
    /// What the owner has done with this revision in the workbench, if anything.
    public fileprivate(set) var owner:MailUpdateOwnerState?
    public var id:String {update.key}
    public var unread:Bool {readRevision != update.revision}
    /// The owner's state, if it concerns the revision now shown.
    public var ownerState:MailUpdateOwnerState? { owner.flatMap{$0.revision == update.revision ? $0 : nil} }
    /// Ignored, deleted or closed by the owner: no longer listed.
    public var dismissedByOwner:Bool { [.ignored,.deleted,.closed].contains(ownerState?.handled) }
}

public struct ScheduledMailUpdateState:Codable,Sendable {
    public let schemaVersion:Int
    public private(set) var sequence:Int
    public private(set) var records:[ScheduledMailUpdateRecord]
    private var receipts:[ScheduledMailReceipt]
    public init() {schemaVersion=1; sequence=0; records=[]; receipts=[]}
    public func validate() throws {
        guard schemaVersion == 1,sequence >= 0,records.count <= 200,Set(records.map(\.id)).count == records.count,
              Set(records.map(\.sequence)).count == records.count,receipts.count <= 5000,
              Set(receipts.map(\.key)).count == receipts.count,
              Set(records.map(\.id)).isDisjoint(with:Set(receipts.map(\.key))) else {throw BridgeFailure("Invalid scheduled update history.")}
        for receipt in receipts {
            guard !receipt.key.isEmpty,receipt.key.utf8.count <= 2048,receipt.revision >= 0,
                  receipt.sequence > 0,receipt.sequence <= sequence,receipt.checkedAt.timeIntervalSince1970.isFinite,
                  receipt.digest.count == 64,receipt.accountsDigest.count == 64 else {throw BridgeFailure("Invalid archived update receipt.")}
        }
        for record in records {
            try record.update.validate()
            guard record.sequence > 0,record.sequence <= sequence,record.receivedAt.timeIntervalSince1970.isFinite,
                  record.readRevision.map({$0 >= 0 && $0 <= record.update.revision}) ?? true else {throw BridgeFailure("Invalid scheduled update receipt.")}
        }
    }
    @discardableResult public mutating func accept(_ update:ScheduledMailUpdate,settings:MailSettings,accounts:[MailWorkflowAccount]) throws -> Bool {
        try update.validate(); try settings.validate()
        let cutoff=Date().addingTimeInterval(-90*86400)
        guard update.checkedAt >= cutoff else {throw BridgeFailure("This report is older than the 90-day delivery window. Ask Dot for a fresh check.")}
        receipts.removeAll{$0.checkedAt < cutoff}
        guard update.authorized(settings:settings,accounts:accounts,submission:true) else {throw BridgeFailure("Link this verified schedule and its email accounts in Mail Dot before reporting updates.")}
        let index=records.firstIndex{$0.id == update.key}
        let previous=try index.map{try ScheduledMailReceipt(records[$0])} ?? receipts.first{$0.key == update.key}
        if let old=previous {
            if update.revision == old.revision {
                guard try ScheduledMailReceipt.hash(update) == old.digest else {throw BridgeFailure("Conflicting content at an already received update revision.")}
                return false
            }
            guard update.revision > old.revision,update.checkedAt >= old.checkedAt,
                  try ScheduledMailReceipt.hash(update.accountIDs.sorted()) == old.accountsDigest else {
                throw BridgeFailure("This update is stale or changed its account identity.")
            }
        }
        guard sequence < Int.max else {throw BridgeFailure("Scheduled update sequence limit reached.")}
        sequence += 1
        // The owner's choices belong to the revision they were made on; a new revision starts afresh.
        let record=ScheduledMailUpdateRecord(update:update,receivedAt:Date(),sequence:sequence,readRevision:index.flatMap{records[$0].readRevision},owner:nil)
        if let index {records[index]=record} else {records.append(record)}
        receipts.removeAll{$0.key == update.key}
        while try (records.count > 200 || JSONEncoder().encode(self).count > 1_800_000) {
            guard let oldest=records.filter({!$0.unread}).min(by:{$0.sequence < $1.sequence}),
                  let archiveIndex=records.firstIndex(where:{$0.id == oldest.id}) else {
                throw BridgeFailure("Unread scheduled updates fill the inbox. Read updates in Mail Dot, then retry the same delivery.")
            }
            if oldest.update.checkedAt >= cutoff {receipts.append(try ScheduledMailReceipt(oldest))}
            records.remove(at:archiveIndex)
            guard receipts.count <= 5000 else {throw BridgeFailure("The 90-day receipt history is full; this delivery was not acknowledged.")}
        }
        return true
    }
    public func receiptSequence(_ key:String)->Int? {records.first{$0.id == key}?.sequence ?? receipts.first{$0.key == key}?.sequence}
    /// Removes one update outright. Used to take away a test report placed by the developer; Dot's own
    /// reports are closed by the owner or archived when read, never removed this way.
    public mutating func discard(_ id:String) { records.removeAll{$0.id == id} }
    public mutating func markUnread(_ id:String) throws {
        guard let index=records.firstIndex(where:{$0.id == id}) else {throw BridgeFailure("This update is no longer listed.")}
        records[index].readRevision=nil
    }
    private func current(_ id:String,revision:Int) throws -> Int {
        guard let index=records.firstIndex(where:{$0.id == id}),records[index].update.revision == revision else {throw BridgeFailure("This update changed. Look at its current version first.")}
        return index
    }
    /// The owner picked one of Dot's options, or, picking the same one again, cleared the choice. Nothing
    /// goes to Dot until it is applied.
    public mutating func choose(_ id:String,revision:Int,option:String,now:Date=Date()) throws {
        let index=try current(id,revision:revision)
        guard let decision=records[index].update.decision,decision.options.contains(where:{$0.id == option}) else {throw BridgeFailure("That option is not offered for this update.")}
        var state=records[index].ownerState ?? MailUpdateOwnerState(revision:revision,chosen:nil,handled:nil,note:nil,at:now,requestID:nil)
        guard state.handled == nil else {throw BridgeFailure("You have already dealt with this update. Undo first to change it.")}
        state.chosen=state.chosen == option ? nil : option; state.at=now
        records[index].owner=state.chosen == nil ? nil : state
    }
    /// Records what the owner did with the update, and which request carries it to Dot.
    public mutating func handle(_ id:String,revision:Int,as handled:MailUpdateOwnerState.Handled,note:String?,requestID:String?,now:Date=Date()) throws {
        let index=try current(id,revision:revision)
        var state=records[index].ownerState ?? MailUpdateOwnerState(revision:revision,chosen:nil,handled:nil,note:nil,at:now,requestID:nil)
        state.handled=handled; state.note=note; state.requestID=requestID; state.at=now
        records[index].owner=state
        records[index].readRevision=revision
    }
    /// Takes back what the owner did, keeping the option they had chosen. Returns the request to withdraw.
    @discardableResult public mutating func undo(_ id:String) throws -> String? {
        guard let index=records.firstIndex(where:{$0.id == id}),var state=records[index].ownerState else {throw BridgeFailure("There is nothing to undo for this update.")}
        let request=state.requestID
        state.handled=nil; state.note=nil; state.requestID=nil
        records[index].owner=state.chosen == nil ? nil : state
        return request
    }
    public mutating func markRead(_ id:String,revision:Int) throws {
        guard let index=records.firstIndex(where:{$0.id == id}),records[index].update.revision == revision else {throw BridgeFailure("This update changed. Read its current version first.")}
        records[index].readRevision=revision
    }
}

private struct ScheduledMailReceipt:Codable,Sendable {
    let key:String
    let revision:Int
    let checkedAt:Date
    let sequence:Int
    let digest:String
    let accountsDigest:String
    init(_ record:ScheduledMailUpdateRecord) throws {
        key=record.id; revision=record.update.revision; checkedAt=record.update.checkedAt; sequence=record.sequence
        digest=try Self.hash(record.update); accountsDigest=try Self.hash(record.update.accountIDs.sorted())
    }
    static func hash<T:Encodable>(_ value:T) throws -> String {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        return SHA256.hash(data:try encoder.encode(value)).map{String(format:"%02x",$0)}.joined()
    }
}
