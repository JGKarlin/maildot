import SwiftUI
import AppKit
import BridgeCore

@MainActor final class MailSettingsModel:ObservableObject {
    @Published var settings=MailSettings()
    @Published var error:String?
    @Published var inventoryStatus="Open Mail and refresh to see configured accounts."
    @Published var refreshing=false
    @Published var nativeGrants:[NativeMailGrant]=[]
    static let gmailURL=URL(string:"https://chatgpt.com/plugins/plugin_connector_1p_95d39881713c8191931482a62d6edff9")!
    static let iCloudURL=URL(string:"https://chatgpt.com/plugins/plugin_connector_6a99cb6846448190875813bf1e8e5504")!
    /// ChatGPT's own pages for the two calendar connectors (read from ChatGPT's plugin directory, 26 November 2026).
    static let outlookURL=URL(string:"https://chatgpt.com/plugins/plugin_connector_1p_6bcb5879c73c819196abc70016166099")!
    static let outlookCalendarURL=URL(string:"https://chatgpt.com/plugins/plugin_connector_1p_fd0f4f41caa88191a9456514bbffa06d")!
    static let googleCalendarURL=URL(string:"https://chatgpt.com/plugins/plugin_connector_1p_f8509de903288191b14a160c6c5d20b0")!
    static let iCloudCalendarURL=URL(string:"https://chatgpt.com/plugins/plugin_connector_6a99cb684648819088fe4d6a0e373614")!
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
    /// Opens ChatGPT's plugin for the account, and asks Dot to confirm the connection once the owner has added it.
    func activate(_ email:String,provider:String) {
        if provider == "icloud" {
            var input=MailSettingsInput(); input.provider="icloud"
            request(.activate,email:email,instruction:"Confirm that your iCloud Mail connector reaches the iCloud account \(email). The owner adds the connector in ChatGPT with an app-specific password. If the connector is signed in to this exact address, report this request confirmed with result_code verified and no connections: the iCloud connector gives no stable profile or connection ID, and Mail Dot records the connection itself. If it is not connected, or signed in to another address, report failed and say which. Do not change schedules or email.",input:input)
            guard error == nil else { return }
            NSWorkspace.shared.open(Self.iCloudURL)
            return
        }
        if provider == "outlook" {
            var input=MailSettingsInput(); input.provider="outlook"
            request(.activate,email:email,instruction:"Connect the Outlook account \(email) through ChatGPT's Outlook Email connector. The owner will complete Microsoft sign-in and consent. Verify the authenticated profile for this exact email and report it with provider outlook, its stable profile ID and current connection ID. Do not change schedules or email.",input:input)
            guard error == nil else { return }
            NSWorkspace.shared.open(Self.outlookURL)
            return
        }
        activate(email)
    }
    func activate(_ email:String) {
        request(.activate,email:email,instruction:"Connect the Gmail account \(email) through ChatGPT's Gmail connector. The owner will complete Google sign-in and consent. Verify the authenticated profile for this exact email and report its stable profile ID and current connection ID. Do not change schedules or email.")
        guard error == nil else { return }
        NSWorkspace.shared.open(Self.gmailURL)
    }
    /// Opens ChatGPT's page for the calendar connector, and asks Dot to confirm it once the owner has added it (owner
    /// approval, 26 November 2026). Like iCloud Mail, the calendar connectors give no profile id: Dot confirms with none.
    func activateCalendar(_ provider:MailCalendarConnection.Provider,email:String) {
        var input=MailSettingsInput(); input.provider=provider.activation
        let instruction=provider == .outlook
            ? "Confirm that ChatGPT's Outlook Calendar connector is connected for the Microsoft account \(email), so that you can read the owner's schedule as well as add events. The owner completes Microsoft sign-in and consent in ChatGPT. If it is connected to this account, report this request confirmed with result_code verified and no connections or schedules. If it is not connected, or connected to another account, report failed and say which. Do not create, change or delete events, schedules or email."
            : provider == .google
            ? "Confirm that ChatGPT's Google Calendar connector is connected for the Google account \(email), so that you can read the owner's schedule as well as add events. The owner completes Google sign-in and consent in ChatGPT. If it is connected to this account, report this request confirmed with result_code verified and no connections or schedules. If it is not connected, or connected to another account, report failed and say which. Do not create, change or delete events, schedules or email."
            : "Confirm that ChatGPT's iCloud Calendar connector is connected, so that you can read the owner's schedule as well as add events. The owner adds it in ChatGPT with their Apple Account address and an app-specific password; it may differ from the iCloud Mail address \(email). If it is connected, report this request confirmed with result_code verified and no connections or schedules. If it is not, report failed and say so. Do not create, change or delete events, schedules or email."
        request(.activate,email:email,instruction:instruction,input:input)
        guard error == nil else { return }
        NSWorkspace.shared.open(provider == .google ? Self.googleCalendarURL : provider == .outlook ? Self.outlookCalendarURL : Self.iCloudCalendarURL)
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
