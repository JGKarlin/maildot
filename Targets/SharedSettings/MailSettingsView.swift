import SwiftUI
import AppKit
import BridgeCore

@MainActor final class MailSettingsModel:ObservableObject {
    @Published var settings=MailSettings()
    @Published var error:String?
    @Published var inventoryStatus="Open Mail and refresh to see configured accounts."
    @Published var refreshing=false
    @Published var nativeGrants:[NativeMailGrant]=[]
    static let gmailURL=URL(string:"https://chatgpt.com/settings/plugins-settings/plugin_connector_1p_95d39881713c8191931482a62d6edff9")!
    static func setupClient() throws -> MailSetupClient {
        try MailSetupClient(store:NativeMailStore.shared(),wake:{ await wakeHelper() })
    }
    private static func wakeHelper() async {
        guard let url=URL(string:"mailbridge://operations") else { return }
        let configuration=NSWorkspace.OpenConfiguration(); configuration.activates=false
        do { _ = try await NSWorkspace.shared.open(url,configuration:configuration) }
        catch { /* The bounded client reports failure without opening a companion window. */ }
    }
    func reload() {
        do {
            settings=try MailSettingsStore.shared().read()
            nativeGrants=try NativeMailStore.shared().read().grants
        }
        catch { self.error=error.localizedDescription }
    }
    func refreshAccounts() async {
        guard !refreshing else { return }
        refreshing=true; defer { refreshing=false }
        do {
            let accounts=try await Self.setupClient().accounts()
            try Task.checkCancellation()
            try MailSettingsStore.shared().transaction {
                if $0.nativeAccounts != accounts { $0.nativeAccounts=accounts; $0.revision += 1 }
            }
            inventoryStatus="\(accounts.count) accounts read from Mail. No messages were read."
            error=nil; reload()
        } catch is CancellationError { }
        catch { inventoryStatus=error.localizedDescription }
    }
    func request(_ kind:MailSettingsRequestKind,email:String?=nil,scheduleID:String?=nil,instruction:String,input:MailSettingsInput?=nil,expectedRevision:Int?=nil) {
        do {
            try MailSettingsStore.shared().transaction { value in
                if let expectedRevision, value.revision != expectedRevision { throw BridgeFailure("Settings changed while you were reviewing. Your edits are preserved; reopen the latest schedule before submitting.") }
                try MailSettingsCoordinator.request(kind,email:email,scheduleID:scheduleID,instruction:instruction,input:input,settings:&value)
            }
            error=nil; reload()
        } catch { self.error=error.localizedDescription }
    }
    func activate(_ email:String) {
        request(.activate,email:email,instruction:"Connect the Gmail account \(email) through ChatGPT's Gmail connector. The owner will complete Google sign-in and consent. Verify the authenticated profile for this exact email and report its stable profile ID and current connection ID. Do not change schedules or email.")
        guard error == nil else { return }
        NSWorkspace.shared.open(Self.gmailURL)
    }
    func verifyNative(_ account:NativeMailAccount,grant:NativeMailGrant) {
        var input=MailSettingsInput(); input.nativeAccountID=account.id; input.nativeGrantVersion=grant.version
        request(.nativeLink,email:account.addresses.first,instruction:"The owner authorized the native account and selected folders identified by the typed nativeAccountID/nativeGrantVersion. Verify this exact scope with native_mail_list_mailboxes, then report confirmed with empty connections/schedules. Do not read messages, create monitoring, change schedules or send email for setup. Return structured native form fields or a capability error if necessary; do not send the owner to Dot/chat.",input:input)
    }
    func revokeNative(_ accountID:String) {
        do {
            try NativeMailStore.shared().transaction { NativeMailCoordinator.revoke(accountID:accountID,state:&$0) }
            error=nil; reload()
        } catch { self.error=error.localizedDescription }
    }
    func answer(_ request:MailSettingsRequest,answers:[String:String]) {
        do {
            try MailSettingsStore.shared().transaction { value in
                try MailSettingsCoordinator.answer(requestID:request.id,form:request.form ?? [],answers:answers,settings:&value)
            }
            error=nil; reload()
        } catch { self.error=error.localizedDescription }
    }
    func verify(_ request:MailSettingsRequest) {
        do {
            try MailSettingsStore.shared().transaction { value in
                guard let index=value.requests.firstIndex(where:{ $0.id == request.id }),value.requests[index].status != .confirmed else { throw BridgeFailure("This setup is already complete.") }
                if value.requests[index].input == nil { value.requests[index].input=MailSettingsInput() }
                value.requests[index].input?.verificationRequestedAt = .now
                value.requests[index].status = .pending; value.requests[index].resultCode=nil
                value.requests[index].outcome=nil; value.requests[index].form=nil
                value.requests[index].event=BridgeEvent(); value.revision += 1
            }
            error=nil; reload()
        } catch { self.error=error.localizedDescription }
    }
}
