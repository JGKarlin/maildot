import Foundation
import CryptoKit

public struct NativeMailbox:Codable,Equatable,Identifiable,Sendable {
    public var accountID:String
    public var path:[String]
    public var id:String {
        let data=(try? JSONEncoder().encode([accountID]+path)) ?? Data()
        return "mailbox_" + SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
    public var name:String { path.last ?? "" }
    public init(accountID:String,path:[String]) { self.accountID=accountID; self.path=path }
    public static func ==(lhs:Self,rhs:Self)->Bool { lhs.id == rhs.id }
    private enum CodingKeys:String,CodingKey { case id,accountID,path }
    public init(from decoder:Decoder) throws {
        let value=try decoder.container(keyedBy:CodingKeys.self)
        accountID=try value.decode(String.self,forKey:.accountID); path=try value.decode([String].self,forKey:.path)
        if let storedID=try value.decodeIfPresent(String.self,forKey:.id),storedID != id { throw BridgeFailure("Mailbox identity does not match its account/path.") }
    }
    public func encode(to encoder:Encoder) throws {
        var value=encoder.container(keyedBy:CodingKeys.self)
        try value.encode(id,forKey:.id); try value.encode(accountID,forKey:.accountID); try value.encode(path,forKey:.path)
    }
    public func validate() throws {
        guard !accountID.isEmpty,accountID.utf8.count <= 512,!path.isEmpty,path.count <= 8,
              path.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains("\0") }) else { throw BridgeFailure("Invalid native Mail account or mailbox reference.") }
    }
}

public struct NativeMailGrant:Codable,Sendable {
    public var accountID:String
    public var mailboxes:[NativeMailbox]
    public var version=UUID().uuidString
    public var grantedAt=Date()
    public var revokedAt:Date?
    public var verifiedAt:Date?
    public init(accountID:String,mailboxes:[NativeMailbox]) { self.accountID=accountID; self.mailboxes=mailboxes }
}

public struct NativeMailQuery:Codable,Sendable {
    public var since=Date().addingTimeInterval(-86_400)
    public var until=Date()
    public var limit=20
    public var offset=0
    public var messageID:Int?
    public var expectedFingerprint:String?
    public init() {}
    public func validate(kind:NativeMailReadKind) throws {
        guard since.timeIntervalSince1970.isFinite,until.timeIntervalSince1970.isFinite,
              until >= since,until.timeIntervalSince(since) <= 31*86_400,
              (1...50).contains(limit),(0..<500).contains(offset) else { throw BridgeFailure("Use a bounded Mail query: at most 31 days, 50 rows and 500 candidates.") }
        if kind == .readMessage {
            guard let messageID,messageID >= 0,let expectedFingerprint,!expectedFingerprint.isEmpty,expectedFingerprint.utf8.count <= 128 else { throw BridgeFailure("Select a listed message and its current fingerprint before reading it.") }
        }
    }
}

public enum NativeMailReadKind:String,Codable,Sendable { case probeMailboxes,listMessages,readMessage }
public struct NativeMailOperation:Codable,Identifiable,Sendable {
    public var id=UUID().uuidString
    public var accountID:String
    public var mailboxID:String?
    public var grantVersion:String
    public var kind:NativeMailReadKind
    public var query:NativeMailQuery
    public var createdAt=Date()
    public var deadline=Date().addingTimeInterval(20)
    public var claimedAt:Date?
    public var result:JSONValue?
    public var error:String?
    public init(accountID:String,mailboxID:String?,grantVersion:String,kind:NativeMailReadKind,query:NativeMailQuery) {
        self.accountID=accountID; self.mailboxID=mailboxID; self.grantVersion=grantVersion; self.kind=kind; self.query=query
    }
}

public struct NativeMailState:Codable,Sendable {
    public var schemaVersion=1
    public var grants:[NativeMailGrant]=[]
    public var operations:[NativeMailOperation]=[]
    public var setupOperations:[MailSetupOperation]=[]
    public var companionSeenAt:Date?
    public init() {}
    private enum CodingKeys:String,CodingKey { case schemaVersion,grants,operations,setupOperations,companionSeenAt }
    public init(from decoder:Decoder) throws {
        let value=try decoder.container(keyedBy:CodingKeys.self)
        schemaVersion=try value.decode(Int.self,forKey:.schemaVersion)
        grants=try value.decode([NativeMailGrant].self,forKey:.grants)
        operations=try value.decode([NativeMailOperation].self,forKey:.operations)
        setupOperations=try value.decodeIfPresent([MailSetupOperation].self,forKey:.setupOperations) ?? []
        companionSeenAt=try value.decodeIfPresent(Date.self,forKey:.companionSeenAt)
    }
    public func validate() throws {
        guard schemaVersion == 1,grants.count <= 100,operations.count <= 20,setupOperations.count <= 20,
              Set(setupOperations.map(\.id)).count == setupOperations.count,
              Set(grants.map(\.accountID)).count == grants.count,Set(operations.map(\.id)).count == operations.count else { throw BridgeFailure("Native Mail state exceeds its limits or has duplicate identities.") }
        for grant in grants {
            guard !grant.accountID.isEmpty,grant.accountID.utf8.count <= 512,UUID(uuidString:grant.version) != nil,
                  !grant.mailboxes.isEmpty,grant.mailboxes.count <= 20,Set(grant.mailboxes.map(\.id)).count == grant.mailboxes.count,
                  grant.mailboxes.allSatisfy({ $0.accountID == grant.accountID }) else { throw BridgeFailure("Invalid native account/folder permission.") }
            try grant.mailboxes.forEach { try $0.validate() }
        }
        for operation in operations {
            guard UUID(uuidString:operation.id) != nil,operation.accountID.utf8.count <= 512,
                  UUID(uuidString:operation.grantVersion) != nil,(operation.mailboxID?.utf8.count ?? 0) <= 128,
                  (operation.error?.utf8.count ?? 0) <= 1024 else { throw BridgeFailure("Invalid native Mail operation.") }
            try operation.query.validate(kind:operation.kind)
            if let result=operation.result { guard try result.text().utf8.count <= 131_072 else { throw BridgeFailure("Native Mail response exceeds 128 KiB.") } }
        }
        try setupOperations.forEach { try $0.validate() }
    }
}

public enum NativeMailCoordinator {
    /// Native settings only. No MCP tool exposes this authority.
    public static func authorize(accountID:String,mailboxes:[NativeMailbox],state:inout NativeMailState) throws {
        var next=state
        next.grants.removeAll { $0.accountID == accountID }
        next.grants.append(NativeMailGrant(accountID:accountID,mailboxes:mailboxes))
        try next.validate(); state=next
    }
    public static func revoke(accountID:String,state:inout NativeMailState) {
        for index in state.grants.indices where state.grants[index].accountID == accountID {
            state.grants[index].revokedAt = .now; state.grants[index].version=UUID().uuidString
        }
        for index in state.operations.indices where state.operations[index].accountID == accountID {
            state.operations[index].result=nil; state.operations[index].error="Native account access was revoked."
        }
    }
    public static func grant(accountID:String,mailboxID:String?,state:NativeMailState) throws -> NativeMailGrant {
        guard let grant=state.grants.first(where:{ $0.accountID == accountID && $0.revokedAt == nil }) else { throw BridgeFailure("Authorize this Mail account and folders in native Mail Dot settings first.") }
        if let mailboxID { guard grant.mailboxes.contains(where:{ $0.id == mailboxID && $0.accountID == accountID }) else { throw BridgeFailure("This mailbox is outside the owner's selected scope.") } }
        return grant
    }
    @discardableResult public static func enqueue(accountID:String,mailboxID:String?,kind:NativeMailReadKind,query:NativeMailQuery,state:inout NativeMailState) throws -> NativeMailOperation {
        try query.validate(kind:kind)
        guard kind == .probeMailboxes || mailboxID != nil else { throw BridgeFailure("Select an authorized mailbox.") }
        let grant=try grant(accountID:accountID,mailboxID:mailboxID,state:state)
        var next=state
        // Completed reads remain until their caller consumes them or their deadline expires.
        next.operations.removeAll { $0.deadline < .now }
        let operation=NativeMailOperation(accountID:accountID,mailboxID:mailboxID,grantVersion:grant.version,kind:kind,query:query)
        next.operations.append(operation); try next.validate(); state=next
        return operation
    }
    private static func validate(_ operation:NativeMailOperation,state:NativeMailState) throws {
        let current=try grant(accountID:operation.accountID,mailboxID:operation.mailboxID,state:state)
        guard current.version == operation.grantVersion,operation.deadline > .now,operation.error == nil else { throw BridgeFailure("Mail permission changed or this read expired. Request a fresh read.") }
    }
    public static func ensureCurrent(_ id:String,state:NativeMailState) throws -> NativeMailOperation {
        guard let operation=state.operations.first(where:{ $0.id == id }),operation.claimedAt != nil,operation.result == nil else { throw BridgeFailure("Native Mail read is no longer active.") }
        try validate(operation,state:state); return operation
    }
    /// Ends a read with an error. `unverify` is for a check that found the selected folders missing or
    /// renamed: only then is the account no longer verified. Mail being closed, or Mail Dot restarting during
    /// the check, says nothing about the folders, so the verification stands (seen 12 November 2026: such
    /// failures left iCloud showing "not yet connected" after it had been connected).
    public static func fail(_ id:String,error:String,unverify:Bool=false,state:inout NativeMailState) {
        guard let index=state.operations.firstIndex(where:{ $0.id == id }),state.operations[index].result == nil else { return }
        if state.operations[index].error == nil { state.operations[index].error=String(decoding:error.utf8.prefix(1000),as:UTF8.self) }
        if unverify,state.operations[index].kind == .probeMailboxes,let grant=state.grants.firstIndex(where:{$0.accountID == state.operations[index].accountID}) { state.grants[grant].verifiedAt=nil }
    }
    /// Mail Dot's own check of an account's allowed folders, made on the Mac as soon as the owner allows
    /// them or presses Check Again; its success is what makes the account connected. Dot's confirmation
    /// follows it and needs it, but the account does not wait for Dot.
    @discardableResult public static func check(accountID:String,state:inout NativeMailState) throws -> NativeMailOperation {
        try enqueue(accountID:accountID,mailboxID:nil,kind:.probeMailboxes,query:NativeMailQuery(),state:&state)
    }
    /// Where an account's own check stands: the newest check of its folders, if any is still listed.
    public static func latestCheck(accountID:String,state:NativeMailState) -> NativeMailOperation? {
        state.operations.last { $0.accountID == accountID && $0.kind == .probeMailboxes }
    }
    public static func consume(_ id:String,state:inout NativeMailState) throws -> JSONValue? {
        guard let index=state.operations.firstIndex(where:{ $0.id == id }) else { throw BridgeFailure("Native Mail read is no longer available. Request a fresh read.") }
        if let error=state.operations[index].error { throw BridgeFailure(error) }
        try validate(state.operations[index],state:state)
        guard let result=state.operations[index].result else { return nil }
        state.operations.remove(at:index); return result
    }
    public static func claim(_ id:String,state:inout NativeMailState) throws -> NativeMailOperation {
        guard let index=state.operations.firstIndex(where:{ $0.id == id }),state.operations[index].claimedAt == nil,state.operations[index].result == nil else { throw BridgeFailure("Native Mail read is missing or already claimed.") }
        try validate(state.operations[index],state:state)
        state.operations[index].claimedAt = .now
        return state.operations[index]
    }
    public static func complete(_ id:String,result:JSONValue,state:inout NativeMailState) throws {
        guard let index=state.operations.firstIndex(where:{ $0.id == id }),state.operations[index].claimedAt != nil,state.operations[index].result == nil else { throw BridgeFailure("Native Mail read was not claimed or is already complete.") }
        try validate(state.operations[index],state:state)
        var next=state; next.operations[index].result=result
        if next.operations[index].kind == .probeMailboxes,let grantIndex=next.grants.firstIndex(where:{ $0.accountID == next.operations[index].accountID }) { next.grants[grantIndex].verifiedAt = .now }
        try next.validate(); state=next
    }
}
