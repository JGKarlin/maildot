import Foundation

public struct MailWorkflowAccount:Codable,Sendable,Identifiable {
    public let id:String
    public let label:String
    public let route:String
    public let sourceID:String
    public let connectionID:String?
    public let senderAddresses:[String]

    /// Last verified connector metadata or an existing native folder grant.
    /// This inventory grants nothing; Dot and native readers still enforce the
    /// selected source's current authentication and folder permissions.
    public static func available(settings:MailSettings,native:NativeMailState) throws -> [Self] {
        try settings.validate(); try native.validate()
        var accounts=settings.connections.filter {
            $0.available && $0.observedAt != nil && $0.provider == "gmail"
        }.map {
            Self(id:"gmail:"+$0.id,label:$0.email,route:"gmail",sourceID:$0.id,connectionID:$0.connectionID,senderAddresses:[$0.email])
        }
        for grant in native.grants where grant.revokedAt == nil && grant.verifiedAt != nil && !grant.mailboxes.isEmpty {
            guard let account=settings.nativeAccounts.first(where:{$0.id == grant.accountID}) else { continue }
            accounts.append(Self(id:"mail:"+account.id,label:account.name,route:"mail",sourceID:account.id,connectionID:nil,senderAddresses:account.addresses))
        }
        // An account the owner switched Mail Dot off for is not given to Dot at all.
        return accounts.filter{settings.mailDot(account:$0.id)}.sorted { $0.id < $1.id }
    }
}
