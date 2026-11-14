import Foundation

/// Local native UI discovery only. No MCP tool enqueues these operations.
/// The type cannot express reading messages, changing permissions or editing email.
public struct MailSetupResult:Codable,Sendable {
    public var accounts:[NativeMailAccount]
    public var mailboxes:[NativeMailbox]
    public init(accounts:[NativeMailAccount]=[],mailboxes:[NativeMailbox]=[]) {
        self.accounts=accounts; self.mailboxes=mailboxes
    }
    func validate(accountID:String?) throws {
        guard accounts.count <= 100,mailboxes.count <= 100,
              Set(accounts.map(\.id)).count == accounts.count,
              Set(mailboxes.map(\.id)).count == mailboxes.count else { throw BridgeFailure("Mail setup returned too many or duplicate accounts/folders.") }
        if let accountID {
            guard accounts.isEmpty,mailboxes.allSatisfy({$0.accountID == accountID}) else { throw BridgeFailure("Mail setup returned a different account.") }
        } else if !mailboxes.isEmpty { throw BridgeFailure("Account discovery must not return folders.") }
        for account in accounts {
            guard !account.id.isEmpty,account.id.utf8.count <= 512,account.name.utf8.count <= 512,
                  account.server.utf8.count <= 512,account.addresses.count <= 100,
                  account.addresses.allSatisfy({$0.utf8.count <= 512}) else { throw BridgeFailure("Invalid Mail account metadata.") }
        }
        try mailboxes.forEach { try $0.validate() }
    }
}

public struct MailSetupOperation:Codable,Identifiable,Sendable {
    public var id=UUID().uuidString
    public var accountID:String?
    public var deadline=Date().addingTimeInterval(20)
    public var claimedAt:Date?
    public var result:MailSetupResult?
    public var error:String?
    public init(accountID:String?) { self.accountID=accountID }
    func validate() throws {
        guard UUID(uuidString:id) != nil,deadline.timeIntervalSince1970.isFinite,
              accountID == nil || !(accountID?.isEmpty ?? true) && (accountID?.utf8.count ?? 0) <= 512,
              (error?.utf8.count ?? 0) <= 1024 else { throw BridgeFailure("Invalid Mail setup request.") }
        try result?.validate(accountID:accountID)
    }
}

public enum MailSetupCoordinator {
    public static func enqueue(accountID:String?,state:inout NativeMailState) throws -> MailSetupOperation {
        let operation=MailSetupOperation(accountID:accountID)
        try operation.validate()
        var next=state
        next.setupOperations.removeAll { $0.deadline <= .now }
        guard next.setupOperations.count < 20 else { throw BridgeFailure("Mail setup is busy. Try again shortly.") }
        next.setupOperations.append(operation); try next.validate(); state=next
        return operation
    }
    public static func current(_ id:String,state:NativeMailState) throws -> MailSetupOperation {
        guard let operation=state.setupOperations.first(where:{$0.id == id}),operation.deadline > .now else { throw BridgeFailure("Mail setup expired or was canceled. Refresh to try again.") }
        if let error=operation.error { throw BridgeFailure(error) }
        return operation
    }
    public static func claim(_ id:String,state:inout NativeMailState) throws -> MailSetupOperation {
        var operation=try current(id,state:state)
        guard operation.claimedAt == nil,operation.result == nil else { throw BridgeFailure("Mail setup is already claimed.") }
        operation.claimedAt = .now
        state.setupOperations[state.setupOperations.firstIndex(where:{$0.id == id})!]=operation
        return operation
    }
    public static func complete(_ id:String,result:MailSetupResult,state:inout NativeMailState) throws {
        let operation=try current(id,state:state)
        guard operation.claimedAt != nil,operation.result == nil else { throw BridgeFailure("Mail setup was not claimed or is already complete.") }
        try result.validate(accountID:operation.accountID)
        state.setupOperations[state.setupOperations.firstIndex(where:{$0.id == id})!].result=result
    }
    public static func consume(_ id:String,state:inout NativeMailState) throws -> MailSetupResult? {
        let operation=try current(id,state:state)
        guard let result=operation.result else { return nil }
        cancel(id,state:&state); return result
    }
    public static func cancel(_ id:String,state:inout NativeMailState) { state.setupOperations.removeAll {$0.id == id} }
    public static func fail(_ id:String,error:String,state:inout NativeMailState) {
        guard let index=state.setupOperations.firstIndex(where:{$0.id == id}),state.setupOperations[index].result == nil else { return }
        state.setupOperations[index].error=String(decoding:error.utf8.prefix(1000),as:UTF8.self)
    }
}

public struct MailSetupClient:Sendable {
    private let store:NativeMailStore
    private let wake:@Sendable () async -> Void
    public init(store:NativeMailStore,wake:@escaping @Sendable () async -> Void) { self.store=store; self.wake=wake }
    public func accounts() async throws -> [NativeMailAccount] { try await discover(accountID:nil).accounts }
    public func mailboxes(accountID:String) async throws -> [NativeMailbox] { try await discover(accountID:accountID).mailboxes }
    private func discover(accountID:String?) async throws -> MailSetupResult {
        try Task.checkCancellation()
        let operation=try store.transaction { try MailSetupCoordinator.enqueue(accountID:accountID,state:&$0) }
        defer { try? store.transaction { MailSetupCoordinator.cancel(operation.id,state:&$0) } }
        await wake()
        while Date() < operation.deadline {
            try Task.checkCancellation()
            if let result=try store.transaction({ try MailSetupCoordinator.consume(operation.id,state:&$0) }) { return result }
            try await Task.sleep(for:.milliseconds(150))
        }
        throw BridgeFailure("Mail Dot’s background helper did not respond. Check its connection and refresh. No settings were changed.")
    }
}
