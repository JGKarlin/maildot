import Foundation

/// Exact native creation intent. This is neither a send approval nor proof that
/// Mail created a draft. The worker must consume a durable attempt before creation.
public struct NativeCompositionPlan:Codable,Sendable {
    public let requestID:String
    public let requestRevision:Int
    public let composition:MailWorkflowComposition
    public let nativeAccountID:String

    public init(request:MailWorkflowRequest,displayedRevision:Int,displayed:MailWorkflowComposition,
                accounts:[MailWorkflowAccount],nativeAccounts:[NativeMailAccount]) throws {
        try request.validate(); try displayed.validate()
        guard request.action == .compose,request.stage == .ready,request.revision == displayedRevision,
              let current=request.report?.composition,try Self.identical(current,displayed) else {
            throw BridgeFailure("Refresh the new-email proposal before creating its Mail draft.")
        }
        requestID=request.id; requestRevision=displayedRevision; composition=displayed
        nativeAccountID=try Self.resolve(displayed,accounts:accounts,nativeAccounts:nativeAccounts)
    }

    public func validate(request:MailWorkflowRequest,accounts:[MailWorkflowAccount],nativeAccounts:[NativeMailAccount]) throws {
        guard request.id == requestID else { throw BridgeFailure("The new-email request is no longer available.") }
        let live=try Self(request:request,displayedRevision:requestRevision,displayed:composition,accounts:accounts,nativeAccounts:nativeAccounts)
        guard live.nativeAccountID == nativeAccountID else {
            throw BridgeFailure("The Mail account changed. Review the proposal again before creating a draft.")
        }
    }

    public func validateCreated(_ draft:MailDraft) throws {
        guard draft.id >= 0,draft.attachmentCount == 0,
              MailDraft.address(draft.sender) == MailDraft.address(composition.sender),
              MailDraft.addresses(draft.to) == MailDraft.addresses(composition.to),
              MailDraft.addresses(draft.cc) == MailDraft.addresses(composition.cc),
              MailDraft.addresses(draft.bcc) == MailDraft.addresses(composition.bcc),
              draft.subject.utf8.elementsEqual(composition.subject.utf8),
              draft.body.utf8.elementsEqual(composition.body.utf8) else {
            throw BridgeFailure("Mail's created draft does not exactly match the proposal. Inspect Mail; do not retry creation automatically. Nothing was sent by this action.")
        }
    }

    private static func identical(_ lhs:MailWorkflowComposition,_ rhs:MailWorkflowComposition) throws -> Bool {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        return try encoder.encode(lhs) == encoder.encode(rhs)
    }

    private static func resolve(_ proposal:MailWorkflowComposition,accounts:[MailWorkflowAccount],nativeAccounts:[NativeMailAccount]) throws -> String {
        let selected=accounts.filter{$0.id == proposal.accountID}
        let sender=MailDraft.address(proposal.sender)
        guard selected.count == 1,let account=selected.first,
              account.senderAddresses.contains(where:{MailDraft.address($0) == sender}),
              ["gmail","mail"].contains(account.route) else {
            throw BridgeFailure("The proposed sender is no longer linked to this Mail Dot account.")
        }
        // Mail selects an outgoing account by sender address, so even a native
        // account ID cannot disambiguate two configured accounts sharing it.
        let matches=nativeAccounts.filter { $0.addresses.contains{MailDraft.address($0) == sender} }
        guard matches.count == 1,let match=matches.first,!match.id.isEmpty,
              account.route != "mail" || match.id == account.sourceID else {
            throw BridgeFailure("Link this sender to one unambiguous account in Mail before creating a draft.")
        }
        return match.id
    }
}
