import SwiftUI
import Observation
import BridgeCore

@MainActor @Observable final class NativeMailSetupModel {
    let account:NativeMailAccount
    var mailboxes:[NativeMailbox]=[]
    var selected:Set<String>=[]
    var loading=false
    var error:String?
    init(account:NativeMailAccount) { self.account=account }
    func load() async {
        loading=true; defer { loading=false }
        do {
            mailboxes=try await MailSettingsModel.setupClient().mailboxes(accountID:account.id)
            try Task.checkCancellation()
            let grant=try NativeMailStore.shared().read().grants.first { $0.accountID == account.id && $0.revokedAt == nil }
            selected=Set(grant?.mailboxes.map(\.id) ?? []).intersection(Set(mailboxes.map(\.id)))
            // A first connection starts with the Inbox chosen, which is where replies are needed.
            if grant == nil,selected.isEmpty {
                let inbox=mailboxes.filter{ ["inbox","受信","受信トレイ","受信箱"].contains($0.name.lowercased()) }
                selected=Set(inbox.prefix(1).map(\.id))
            }
            error=mailboxes.isEmpty ? String(localized:"Mail did not expose any folders for this account.") : nil
        } catch is CancellationError { }
        catch { self.error=error.localizedDescription }
    }
    /// Called only by the explicit native permission button; no MCP tool can call this.
    func allow(settings:MailSettingsModel) -> Bool {
        do {
            let folders=mailboxes.filter { selected.contains($0.id) }
            guard !folders.isEmpty,folders.count <= 20,Set(folders.map(\.id)) == selected else { throw BridgeFailure(String(localized:"Select up to 20 folders to allow.")) }
            let grant=try NativeMailStore.shared().transaction { state in
                try NativeMailCoordinator.authorize(accountID:account.id,mailboxes:folders,state:&state)
                guard let grant=state.grants.first(where:{$0.accountID == account.id}) else { throw BridgeFailure(String(localized:"Native permission was not saved.")) }
                return grant
            }
            settings.verifyNative(account,grant:grant)
            error=settings.error
            guard error == nil else { return false }
            // Mail Dot checks the folders itself at once; that check, not Dot's, makes the account connected.
            _ = try NativeMailStore.shared().transaction { try NativeMailCoordinator.check(accountID:account.id,state:&$0) }
            DotCallCommands.wakeCompanion()
            return true
        } catch { self.error=error.localizedDescription; return false }
    }
}

struct NativeMailSetupView:View {
    @ObservedObject var settings:MailSettingsModel
    @State private var setup:NativeMailSetupModel
    let onClose:()->Void
    @State private var reloadID=0
    init(account:NativeMailAccount,settings:MailSettingsModel,onClose:@escaping ()->Void) {
        self.onClose=onClose
        self.settings=settings; _setup=State(initialValue:NativeMailSetupModel(account:account))
    }
    var body:some View {
        ScrollView { VStack(alignment:.leading,spacing:16) {
            Label("Set up \(setup.account.name)",systemImage:"envelope").font(.title2.bold())
            Text(setup.account.addresses.joined(separator:", ")).foregroundStyle(MailDotStyle.supporting).textSelection(.enabled)
            Text("Choose the folders your existing Dot may read through Mail on this Mac.")
            if setup.loading { ProgressView("Reading folders…").frame(maxWidth:.infinity,minHeight:220) }
            else {
                List(setup.mailboxes) { mailbox in
                    Toggle(isOn:Binding(get:{ setup.selected.contains(mailbox.id) },set:{ allowed in
                        if allowed { _ = setup.selected.insert(mailbox.id) } else { _ = setup.selected.remove(mailbox.id) }
                    })) { Label(mailbox.path.joined(separator:" ▸ "),systemImage:"folder") }
                    .disabled(setup.selected.count >= 20 && !setup.selected.contains(mailbox.id))
                }.frame(minHeight:220,maxHeight:320)
            }
            Text("This allows message headers and text in the selected folders to be shared with Dot. Attachment contents are excluded. It does not allow sending, moving, deleting or changing messages. Mail and this Mac must be available.")
                .font(.callout).foregroundStyle(MailDotStyle.supporting)
            Text("You can remove this access at any time in Mail Dot settings.").font(.caption).foregroundStyle(MailDotStyle.supporting)
            if let error=setup.error { Text(error).foregroundStyle(MailDotStyle.dangerText).textSelection(.enabled) }
            HStack {
                Button("Cancel",role:.cancel) { onClose() }
                if settings.nativeGrants.contains(where:{$0.accountID == setup.account.id && $0.revokedAt == nil}) {
                    Button("Remove access",role:.destructive) {
                        settings.revokeNative(setup.account.id)
                        if settings.error == nil { onClose() }
                    }
                }
                Spacer()
                if setup.error != nil { Button("Try again") { reloadID += 1 }.disabled(setup.loading) }
                Button("Allow access") { if setup.allow(settings:settings) { onClose() } }
                    .buttonStyle(.borderedProminent).disabled(setup.loading || setup.selected.isEmpty)
            }
        }.padding(24) }
        .task(id:reloadID) { await setup.load() }
    }
}
