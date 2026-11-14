import Foundation
import BridgeCore

public protocol MailSetupReading:Sendable {
    func accounts() async throws -> [NativeMailAccount]
    func mailboxes(accountID:String) async throws -> [NativeMailbox]
}

private struct SystemMailSetupReader:MailSetupReading {
    let deadline:Date
    let authorize:@Sendable () throws -> Void
    func accounts() async throws -> [NativeMailAccount] {
        try authorize()
        return try await MailAutomation().accounts(operationDeadline:deadline,authorize:authorize)
    }
    func mailboxes(accountID:String) async throws -> [NativeMailbox] {
        try await NativeMailReader(operationDeadline:deadline,authorize:authorize).mailboxes(accountID:accountID)
    }
}

/// Native settings metadata only, separate from Dot's explicitly granted message reads.
public actor MailSetupWorker {
    private let store:NativeMailStore
    private let readerFactory:@Sendable (MailSetupOperation)->any MailSetupReading
    private var busy=false
    public init(store:NativeMailStore,readerFactory:(@Sendable (MailSetupOperation)->any MailSetupReading)?=nil) {
        self.store=store
        self.readerFactory=readerFactory ?? { operation in
            SystemMailSetupReader(deadline:operation.deadline,authorize:{ _ = try MailSetupCoordinator.current(operation.id,state:store.read()) })
        }
    }
    public func processNext() async {
        guard !busy else { return }
        busy=true; defer { busy=false }
        do {
            try store.transaction { $0.setupOperations.removeAll { $0.deadline <= .now } }
            guard let pending=try store.read().setupOperations.first(where:{$0.claimedAt == nil && $0.result == nil && $0.error == nil}) else { return }
            do {
                let operation=try store.transaction { try MailSetupCoordinator.claim(pending.id,state:&$0) }
                let reader=readerFactory(operation)
                let accounts=try await reader.accounts()
                _ = try MailSetupCoordinator.current(operation.id,state:store.read())
                let result:MailSetupResult
                if let accountID=operation.accountID {
                    guard accounts.filter({$0.id == accountID}).count == 1 else { throw BridgeFailure("This account is no longer uniquely available in Mail. Refresh the account list.") }
                    result=MailSetupResult(mailboxes:try await reader.mailboxes(accountID:accountID))
                } else { result=MailSetupResult(accounts:accounts) }
                try store.transaction { try MailSetupCoordinator.complete(operation.id,result:result,state:&$0) }
            } catch {
                try? store.transaction { MailSetupCoordinator.fail(pending.id,error:error.localizedDescription,state:&$0) }
            }
        } catch { /* Client displays timeout or storage failure; never infer a successful discovery. */ }
    }
}
