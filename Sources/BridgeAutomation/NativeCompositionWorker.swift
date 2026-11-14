import Foundation
import BridgeCore

public actor NativeCompositionWorker {
    typealias Create = @Sendable (NativeCompositionPlan,Date,@Sendable ([NativeMailAccount])throws->Void) async throws -> MailDraft
    private let directory:URL
    private let create:Create
    private var processing=false
    public init(bridgeDirectory:URL) {
        directory=bridgeDirectory
        let automation=MailAutomation()
        create={plan,deadline,consume in try await automation.createDraft(plan,deadline:deadline,consume:consume)}
    }
    init(bridgeDirectory:URL,create:@escaping Create) { directory=bridgeDirectory; self.create=create }

    public func processNext() async {
        guard !processing else {return}
        processing=true; defer {processing=false}
        let queue=NativeCompositionStore(bridgeDirectory:directory)
        do {
            guard let operation=try queue.transaction({$0.claimNext()}) else {return}
            do {
                let directory=directory
                let draft=try await create(operation.plan,operation.createdAt.addingTimeInterval(300)) { liveAccounts in
                    try queue.transaction { state in
                        let request=try MailWorkflowStore(bridgeDirectory:directory).read().requests.first{$0.id == operation.plan.requestID}
                        let accounts=try MailWorkflowAccount.available(settings:MailSettingsStore(bridgeDirectory:directory).read(),native:NativeMailStore(bridgeDirectory:directory).read())
                        try state.consume(operation.id,request:request,accounts:accounts,nativeAccounts:liveAccounts)
                    }
                }
                try queue.transaction {try $0.complete(operation.id,draft:draft)}
            } catch {
                try queue.transaction {$0.fail(operation.id,error:error.localizedDescription)}
            }
        } catch { /* Retained claims display an unconfirmed outcome and cannot be replayed. */ }
    }
}
