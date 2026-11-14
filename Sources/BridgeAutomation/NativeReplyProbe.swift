#if DEBUG
import Foundation
import BridgeCore

/// Local synthetic acceptance only. No MCP tool invokes this diagnostic.
public enum NativeReplyProbe {
    private static let title="Mail Dot native read test - UNSENT"
    private static let text="Fixture identifier: native-mail-read-20261109.\nMeeting: Thursday at 14:00.\nState: synthetic unsent test; no delivery intended."
    static func uniqueFixture(in page:JSONValue) throws -> JSONValue {
        guard page["collection_complete"] == true,page["next_offset"] == .null else {
            throw BridgeFailure("The synthetic source inventory is incomplete. Nothing was created.")
        }
        let matches=(page["messages"].array ?? []).filter { $0["subject"].string == title }
        guard matches.count == 1,let row=matches.first else { throw BridgeFailure("Exactly one saved synthetic fixture was not found. Nothing was created.") }
        return row
    }
    static func validate(body:NativeMailBody,account:NativeMailAccount,mailbox:NativeMailbox) throws {
        try mailbox.validate()
        let raw=body.message.sender.trimmingCharacters(in:.whitespacesAndNewlines)
        var sender=raw
        if let left=raw.lastIndex(of:"<"),let right=raw.lastIndex(of:">"),left < right,right == raw.index(before:raw.endIndex),
           !raw[..<left].contains("<"),!raw[..<left].contains(">") {
            sender=String(raw[raw.index(after:left)..<right])
        }
        guard mailbox.accountID == account.id,mailbox.path == ["Drafts"],body.message.mailboxID == mailbox.id,
              body.message.subject == title,body.message.to.isEmpty,body.message.cc.isEmpty,body.message.bcc.isEmpty,
              !raw.contains("\n"),!raw.contains("\r"),body.message.attachmentCount == 0,account.addresses.map(MailDraft.address).contains(MailDraft.address(sender)),
              body.text.replacingOccurrences(of:"\r\n",with:"\n").trimmingCharacters(in:.whitespacesAndNewlines) == text else {
            throw BridgeFailure("This local creation probe accepts only the exact synthetic unsent fixture, owned sender and authorized Drafts folder. Nothing was created.")
        }
    }
    public static func run() async throws -> String {
        let bridge=try BridgeStore.shared(),store=NativeMailStore(bridgeDirectory:bridge.directory)
        let native=try store.read(),settings=try MailSettingsStore(bridgeDirectory:bridge.directory).read()
        let candidates=native.grants.filter { grant in
            grant.revokedAt == nil && grant.mailboxes.contains(where:{$0.path == ["Drafts"]}) &&
                settings.nativeAccounts.contains(where:{$0.id == grant.accountID && $0.addresses.contains(where:{$0.lowercased().hasSuffix("@icloud.com")})})
        }
        guard candidates.count == 1,let grant=candidates.first,
              let account=settings.nativeAccounts.first(where:{$0.id == grant.accountID}),
              let mailbox=grant.mailboxes.first(where:{$0.path == ["Drafts"]}) else {
            throw BridgeFailure("The fixed synthetic probe needs one owner-authorized iCloud Drafts folder.")
        }
        let authorize:@Sendable () throws -> Void = {
            let current=try NativeMailCoordinator.grant(accountID:account.id,mailboxID:mailbox.id,state:store.read())
            guard current.version == grant.version else { throw BridgeFailure("Folder permission changed. No synthetic reply was created.") }
        }
        let reader=NativeMailReader(operationDeadline:Date().addingTimeInterval(20),authorize:authorize)
        var query=NativeMailQuery(); query.since=Date().addingTimeInterval(-86400); query.limit=50
        let page=try await reader.listMessages(accountID:account.id,mailbox:mailbox,query:query)
        let row=try uniqueFixture(in:page)
        guard let id=row["id"].integer,let fingerprint=row["fingerprint"].string else {
            throw BridgeFailure("Exactly one saved synthetic fixture was not found. Nothing was created.")
        }
        let body=try await reader.readMessage(accountID:account.id,mailbox:mailbox,messageID:id,expectedFingerprint:fingerprint)
        try validate(body:body,account:account,mailbox:mailbox)
        try authorize()
        let automation=MailAutomation()
        let outgoingID=try await automation.createSyntheticReply(body:body,account:account,mailbox:mailbox)
        do {
            let snapshot=try await automation.snapshot(id:outgoingID)
            return "SYNTHETIC_REPLY_CREATED id=\(outgoingID) snapshot_available=true body_bytes=\(snapshot.body.utf8.count) attachment_count=\(snapshot.attachmentCount) recipient_count=\(snapshot.to.count+snapshot.cc.count+snapshot.bcc.count). Nothing was sent."
        } catch {
            return "SYNTHETIC_REPLY_CREATED id=\(outgoingID) snapshot_available=false. Preserve the unsent window; no editing or sending capability is proved."
        }
    }
}
#endif
