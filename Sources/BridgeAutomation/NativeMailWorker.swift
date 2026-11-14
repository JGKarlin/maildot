import Foundation
import BridgeCore

public actor NativeMailWorker {
    private let store:NativeMailStore
    private let readerFactory:@Sendable (NativeMailOperation)->any NativeMailReading
    private var busy=false
    private var lastHeartbeat=Date.distantPast
    public init(store:NativeMailStore,readerFactory:(@Sendable (NativeMailOperation)->any NativeMailReading)?=nil) {
        self.store=store
        self.readerFactory=readerFactory ?? { operation in
            NativeMailReader(operationDeadline:operation.deadline,authorize:{ _ = try NativeMailCoordinator.ensureCurrent(operation.id,state:store.read()) })
        }
    }
    public func processNext() async {
        guard !busy else { return }
        busy=true; defer { busy=false }
        do {
            if Date().timeIntervalSince(lastHeartbeat) > 2 {
                try store.transaction {
                    $0.operations.removeAll { $0.deadline < .now }
                    $0.companionSeenAt = .now
                }; lastHeartbeat = .now
            }
            guard let pending=try store.read().operations.first(where:{ $0.claimedAt == nil && $0.result == nil && $0.error == nil }) else { return }
            do {
                let operation=try store.transaction { try NativeMailCoordinator.claim(pending.id,state:&$0) }
                let grant=try NativeMailCoordinator.grant(accountID:operation.accountID,mailboxID:operation.mailboxID,state:store.read())
                let reader=readerFactory(operation)
                let result:JSONValue
                switch operation.kind {
                case .probeMailboxes:
                    let found=try await reader.mailboxes(accountID:operation.accountID)
                    guard found.count <= 100,grant.mailboxes.allSatisfy({ selected in found.contains(selected) }) else { throw FoldersChanged("A selected mailbox is missing or renamed. Review the account's folder selection.") }
                    result=["status":"complete","account_id":.string(operation.accountID),"mailboxes":try .encode(grant.mailboxes),"server_freshness_verified":false]
                case .listMessages:
                    guard let box=grant.mailboxes.first(where:{$0.id == operation.mailboxID}) else { throw BridgeFailure("Selected mailbox is not authorized.") }
                    let page=try await reader.listMessages(accountID:operation.accountID,mailbox:box,query:operation.query)
                    guard page["account_id"].string == operation.accountID,page["mailbox_id"].string == box.id,
                          let messages=page["messages"].array,messages.count <= operation.query.limit,
                          messages.allSatisfy({ $0["mailboxID"].string == box.id && $0["text"] == .null && $0["body"] == .null }) else { throw BridgeFailure("Mail returned metadata outside the selected mailbox or with unexpected content.") }
                    result=page
                case .readMessage:
                    guard let box=grant.mailboxes.first(where:{$0.id == operation.mailboxID}),let messageID=operation.query.messageID,let fingerprint=operation.query.expectedFingerprint else { throw BridgeFailure("Select an authorized message first.") }
                    let body=try await reader.readMessage(accountID:operation.accountID,mailbox:box,messageID:messageID,expectedFingerprint:fingerprint)
                    guard body.message.mailboxID == box.id,body.message.id == messageID,body.message.fingerprint == fingerprint else { throw BridgeFailure("Mail returned a different message. No content was shared.") }
                    result=try .encode(body)
                }
                try store.transaction { try NativeMailCoordinator.complete(operation.id,result:result,state:&$0) }
            } catch {
                try? store.transaction { NativeMailCoordinator.fail(pending.id,error:error.localizedDescription,unverify:error is FoldersChanged,state:&$0) }
            }
        } catch { /* Native settings reports storage failures; this worker never infers successful coverage. */ }
    }
}

/// A check found that a folder the owner allowed is missing or renamed in Mail.
struct FoldersChanged:LocalizedError {
    let message:String
    init(_ message:String) { self.message=message }
    var errorDescription:String? { message }
}
