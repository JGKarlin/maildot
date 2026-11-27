import SwiftUI
import AppKit
import ApplicationServices
import BridgeCore
import BridgeAutomation

/// Mail Dot's setup, shown once after installation when someone opens the app and Mail Dot has no connection yet
/// (owner request, 14 November 2026; reworked to the installer design review of 15 November 2026, all twelve of
/// whose recommendations the owner approved). Each step checks itself against the Mac; only the step that needs
/// the person shows its sentence and its button.
@MainActor final class MailDotSetupWindow:NSObject,NSWindowDelegate {
    static let shared=MailDotSetupWindow()
    private var window:NSWindow?
    private var waitingForInstaller:Task<Void,Never>?
    /// Whether Mail Dot already has a connection on this Mac; setup is then not shown.
    nonisolated static var needed:Bool { !RuntimeSetup.isConfigured(paths:RuntimeSetup.Paths(home:FileManager.default.homeDirectoryForCurrentUser)) }
    /// Setup was asked for and Dot has not yet answered both of Mail Dot's tests (installer review, 18 November
    /// 2026): the connection may exist by now, but setup has not proved itself, so opening the app shows setup again
    /// and not the About window.
    nonisolated static var unfinished:Bool { (try? BridgeStore.shared()).map{ SetupThroughDot.askedAt(in:$0.directory) != nil } ?? false }
    /// What opening the app shows: setup, until Mail Dot is connected and verified.
    nonisolated static var shown:Bool { needed || unfinished }
    private static let installerID="com.apple.installer"

    func show() {
        if window == nil {
            let host=NSHostingController(rootView:MailDotSetupView())
            // The window is as tall as what it shows: one step's text at a time, in any language.
            host.sizingOptions=[.preferredContentSize]
            let made=NSWindow(contentViewController:host)
            made.styleMask=[.titled,.closable,.fullSizeContentView]
            // The title is not drawn, and names the window in Mission Control and to VoiceOver.
            made.title=String(localized:"Set Up Mail Dot")
            made.titlebarAppearsTransparent=true; made.titleVisibility = .hidden
            made.isReleasedWhenClosed=false; made.delegate=self; made.center()
            window=made
        }
        // Setup sends the person to Mail, System Settings and ChatGPT; while it is open Mail Dot is in the Dock,
        // so the window can be found again. At no other time has Mail Dot a Dock icon.
        NSApplication.shared.setActivationPolicy(.regular)
        // Opened by the installer: the window waits behind the Installer's last pane and comes forward when it closes.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.installerID {
            window?.orderFront(nil)
            waitingForInstaller?.cancel()
            waitingForInstaller=Task { [weak self] in
                for _ in 0..<1_800 {
                    try? await Task.sleep(for:.seconds(1))
                    if Task.isCancelled { return }
                    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Self.installerID { break }
                }
                self?.present()
            }
            return
        }
        present()
    }
    /// Brings the open window back in front of whatever covered it, each time a step turns complete: the moment
    /// after the person's own action in Mail, System Settings or ChatGPT.
    func bringForward() {
        guard window?.isVisible == true,waitingForInstaller == nil else { return }
        present()
    }
    private func present() {
        guard let window else { return }
        waitingForInstaller?.cancel(); waitingForInstaller=nil
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate()
    }
    var isOpen:Bool { window?.isVisible == true }
    func close() { window?.close() }
    func windowWillClose(_ notification:Notification) {
        waitingForInstaller?.cancel(); waitingForInstaller=nil
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

/// What setup found on this Mac, looked at every two seconds.
struct SetupFindings:Equatable {
    var facts=SetupFlow.Facts()
    var mailRunning=false
    var askedAt:Date?
    var reports:[SetupThroughDot.Report]=[]
    var now=Date()
    var connection:SetupFlow.Connection { SetupFlow.connection(facts,askedAt:askedAt,reports:reports,now:now) }
    var current:SetupFlow.Step? { SetupFlow.current(facts,reports:reports) }
    func done(_ step:SetupFlow.Step) -> Bool { SetupFlow.done(step,facts,reports:reports) }

    @MainActor static func look() async -> SetupFindings {
        var found=SetupFindings()
        found.facts.extensionOn=await MailExtensionStatus.isOn()
        found.mailRunning=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").contains(where:{ !$0.isTerminated })
        // macOS answers about Mail only while Mail is open.
        if found.mailRunning { found.facts.mailAllowed=await MailAutomation().permissionStatus() == 0 }
        found.facts.accessibility=AXIsProcessTrusted()
        found.facts.chatGPTInstalled=NSWorkspace.shared.urlForApplication(withBundleIdentifier:DotCallLauncher.chatGPTBundleID) != nil
        if let bridge=try? BridgeStore.shared() {
            // The setup step is taken only while this window says it is open.
            SetupThroughDot.noteWindowOpen(in:bridge.directory)
            found.reports=SetupThroughDot.reports(in:bridge.directory)
            found.askedAt=SetupThroughDot.askedAt(in:bridge.directory)
            found.facts.connected = !MailDotSetupWindow.needed && ConnectionWatch.listening(bridge)
            if found.facts.connected,let state=try? bridge.read() {
                found.facts.settingsSubscribed = !state.subscriptions.deliverable(for:"mail.settings_requested").isEmpty
                found.facts.keepConnectedRan = state.keepConnectedRanAt.map{ $0 >= (found.askedAt ?? .distantPast) } ?? false
            }
            // With both subscriptions live, a test request goes through each, and setup ends on Dot's answers.
            let settingsStore=MailSettingsStore(bridgeDirectory:bridge.directory)
            if found.facts.subscribed,var settings=try? settingsStore.read() {
                if (try? SetupVerification.requestTests(settings:&settings,since:found.askedAt)) == true,
                   let updated=try? settingsStore.transaction({ value -> MailSettings in try SetupVerification.requestTests(settings:&value,since:found.askedAt); return value }) { settings=updated }
                found.facts.draftingAnswered=SetupVerification.draftingAnswered(settings,since:found.askedAt)
                found.facts.settingsAnswered=SetupVerification.settingsAnswered(settings,since:found.askedAt)
            }
        }
        return found
    }
}

struct MailDotSetupView:View {
    static let width:CGFloat=560
    /// For rendering previews: findings given instead of looked up.
    var fixed:SetupFindings?
    @State private var found:SetupFindings
    @State private var note:String?
    /// Dot's page could not be used at the last press: Show ChatGPT is offered beside the button.
    @State private var unreachable=false
    /// Whether this window has already asked Dot by itself: once each time it opens, and never again after a failure,
    /// which then shows its reason and the button (owner's direction, 18 November 2026).
    @State private var askedOnItsOwn=false
    @State private var busy=false
    /// The last step, Connect your accounts (owner approval, 26 November 2026): the accounts found in Mail and their
    /// calendars, with the folder choice open for an account read through Mail.
    @StateObject private var accountModel=MailSettingsModel()
    @State private var accounts:[MailDotAccountRow]=[]
    @State private var calendars:[MailDotCalendarRow]=[]
    @State private var accountsReadAt=Date.distantPast
    @State private var choosingFolders:NativeMailAccount?
    /// Later puts the step aside; the accounts stay to connect in Settings, Accounts.
    @AppStorage("SetupAccountsLater") private var accountsLater=false
    /// For rendering previews: the accounts step's rows given instead of read from Mail.
    var fixedAccounts:(accounts:[MailDotAccountRow],calendars:[MailDotCalendarRow])?
    init(fixed:SetupFindings?=nil,fixedAccounts:(accounts:[MailDotAccountRow],calendars:[MailDotCalendarRow])?=nil) {
        self.fixed=fixed; self.fixedAccounts=fixedAccounts; _found=State(initialValue:fixed ?? SetupFindings())
        if let fixedAccounts { _accounts=State(initialValue:fixedAccounts.accounts); _calendars=State(initialValue:fixedAccounts.calendars) }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:12) {
                Image(nsImage:NSApplication.shared.applicationIconImage).resizable().frame(width:48,height:48).accessibilityHidden(true)
                Text("Set Up Mail Dot").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            }
            ForEach(SetupFlow.Step.allCases,id:\.rawValue) { step in row(step) }
            // Open once Mail Dot is on in Mail, while Dot may still be building its connection, so that the sign-ins
            // fill that wait (owner approval, 26 November 2026).
            if accountsStepShown { accountsStep }
            if found.current == nil {
                // Dot runs the task once at the end of setup; the line is shown, never waited for.
                HStack(spacing:8) {
                    Image(systemName:found.facts.keepConnectedRan ? "checkmark.circle.fill" : "clock").foregroundStyle(found.facts.keepConnectedRan ? AnyShapeStyle(Color.green) : AnyShapeStyle(MailDotStyle.supporting))
                    Text(found.facts.keepConnectedRan ? "Keep connected has run." : "Waiting for the first run of Keep connected.")
                        .foregroundStyle(found.facts.keepConnectedRan ? Color.primary : MailDotStyle.supporting).fixedSize(horizontal:false,vertical:true)
                }
                .accessibilityElement(children:.combine)
                HStack(spacing:12) {
                    Spacer()
                    Text("Mail Dot is connected to Dot.").fontWeight(.semibold)
                    // Setup is over: its last press opens Mail and closes this window.
                    Button("Open Mail") { MailExtensionStatus.openMail(); MailDotSetupWindow.shared.close() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        // Someone who gives up halfway can remove Mail Dot here too (owner's approval, 15 November 2026): the same
        // button as in the app's window, small, at the bottom left.
        .safeAreaInset(edge:.bottom,spacing:0) {
            HStack {
                Button("Remove Mail Dot…") { MailDotRemover.start() }.controlSize(.small)
                Spacer()
            }.padding(.horizontal,24).padding(.bottom,16)
        }
        .frame(width:Self.width,alignment:.topLeading)
        .fixedSize(horizontal:false,vertical:true)
        .background(Color(nsColor:.windowBackgroundColor))
        .tint(MailDotStyle.tint)
        .task {
            guard fixed == nil else { return }
            var completed = -1
            while !Task.isCancelled {
                let fresh=await SetupFindings.look()
                let count=SetupFlow.Step.allCases.filter(fresh.done).count
                // A step turned complete while the person was in Mail, System Settings or ChatGPT: back to the window.
                if completed >= 0,count > completed { MailDotSetupWindow.shared.bringForward() }
                completed=count
                found=fresh
                if accountsStepShown { await readAccounts() }
                // The connection step starts by itself once the steps before it are done: no press is needed. A
                // press of the button still works, and after a failure the button is what tries again.
                if !askedOnItsOwn,!busy,fresh.current == .connect,fresh.connection == .ready {
                    askedOnItsOwn=true
                    ask(fresh:true)
                }
                try? await Task.sleep(for:.seconds(2))
            }
        }
    }

    // MARK: The accounts step

    private var accountsStepShown:Bool { (fixed == nil || fixedAccounts != nil) && [.accessibility,.mail,.extensionOn].allSatisfy(found.done) }
    private var accountsDone:Bool { !accounts.isEmpty && accounts.allSatisfy(\.connected) && calendars.allSatisfy{ $0.state == .connected } }
    /// Mail's accounts, read again at most every ten seconds until there are some, and the rows' states every pass.
    private func readAccounts() async {
        if accounts.isEmpty,found.mailRunning,Date().timeIntervalSince(accountsReadAt) > 10 {
            accountsReadAt=Date()
            await accountModel.refreshAccounts()
        }
        let fresh=await MailDotAccountRow.load()
        // Gmail, iCloud and Outlook first, as Dot reads them through ChatGPT; then the accounts read through Mail.
        let ordered=fresh.filter{ $0.gmailAccount }+fresh.filter{ $0.iCloudAccount }+fresh.filter{ $0.outlookAccount }+fresh.filter{ !$0.gmailAccount && !$0.iCloudAccount && !$0.outlookAccount }
        if ordered != accounts { accounts=ordered }
        let freshCalendars=await MailDotCalendarRow.load(for:ordered)
        if freshCalendars != calendars { calendars=freshCalendars }
    }
    @ViewBuilder private var accountsStep:some View {
        let open = !accountsLater
        VStack(alignment:.leading,spacing:8) {
            HStack(alignment:.center,spacing:12) {
                ZStack {
                    Circle().fill(accountsDone ? Color.green : Color.primary.opacity(0.08)).frame(width:28,height:28)
                    if accountsDone { Image(systemName:"checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) }
                    else { Text(verbatim:"\(SetupFlow.Step.allCases.count+1)").font(.callout.weight(.semibold)) }
                }
                Text("Connect your accounts").fontWeight(.semibold).foregroundStyle(open || accountsDone ? Color.primary : MailDotStyle.supporting)
                Spacer(minLength:0)
            }
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(Text("Connect your accounts"))
            .accessibilityValue(accountsDone ? Text("Done") : Text("Not Done"))
            if open {
                VStack(alignment:.leading,spacing:10) {
                    if accounts.isEmpty {
                        HStack(spacing:8) { ProgressView().controlSize(.small); Text("Reading accounts from Mail…").foregroundStyle(MailDotStyle.supporting) }
                    } else {
                        VStack(spacing:0) {
                            ForEach(Array(accountRows.enumerated()),id:\.element.id) { index,item in
                                if index > 0 { Divider() }
                                item.view
                            }
                        }
                        .background(RoundedRectangle(cornerRadius:8).fill(Color.primary.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.primary.opacity(0.10)))
                    }
                    if found.current != nil { HStack { Spacer(); Button("Later") { if fixed == nil { accountsLater=true } } } }
                }.padding(.leading,40)
            }
        }
        .sheet(item:$choosingFolders) { account in
            NativeMailSetupView(account:account,settings:accountModel) { choosingFolders=nil; Task { await readAccounts() } }
                .frame(minWidth:460,minHeight:420)
        }
    }
    /// Each mail account in the order shown, with its calendar under it.
    private var accountRows:[(id:String,view:AnyView)] {
        var rows:[(id:String,view:AnyView)]=[]
        var shownCalendars=Set<String>()
        for account in accounts {
            rows.append((account.id,AnyView(accountRow(account))))
            if let address=account.addresses.first {
                for calendar in calendars where !shownCalendars.contains(calendar.id) && MailDraft.address(calendar.email) == MailDraft.address(address) {
                    shownCalendars.insert(calendar.id)
                    rows.append((calendar.id,AnyView(calendarRow(calendar))))
                }
            }
        }
        for calendar in calendars where !shownCalendars.contains(calendar.id) { rows.append((calendar.id,AnyView(calendarRow(calendar)))) }
        return rows
    }
    private func accountRow(_ account:MailDotAccountRow) -> some View {
        let address=account.addresses.first ?? account.name
        let kind=account.gmailAccount ? "Gmail" : account.iCloudAccount ? "iCloud Mail" : account.outlookAccount ? "Outlook" : account.name
        let state:ConnectorState=account.connected ? .connected : account.checking ? .checking : .connect(failure:nil)
        return listRow(symbol:account.native == nil || account.gmailAccount || account.iCloudAccount || account.outlookAccount ? "envelope" : "tray",title:address,detail:kind,state:state) {
            if account.gmailAccount { accountModel.activate(address,provider:"gmail") }
            else if account.iCloudAccount { accountModel.activate(address,provider:"icloud") }
            else if account.outlookAccount { accountModel.activate(address,provider:"outlook") }
            else if let native=account.native { accountModel.reload(); choosingFolders=native }
            Task { await readAccounts() }
        }
    }
    private func calendarRow(_ calendar:MailDotCalendarRow) -> some View {
        listRow(symbol:"calendar",title:calendar.name,detail:calendar.account,state:calendar.state) {
            accountModel.activateCalendar(calendar.provider,email:calendar.email)
            Task { await readAccounts() }
        }
    }
    private func listRow(symbol:String,title:String,detail:String,state:ConnectorState,connect:@escaping () -> Void) -> some View {
        HStack(spacing:10) {
            Image(systemName:symbol).frame(width:20).foregroundStyle(MailDotStyle.supporting).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:1) {
                Text(verbatim:title).lineLimit(1).truncationMode(.middle)
                Text(verbatim:detail).font(.caption).foregroundStyle(MailDotStyle.supporting).lineLimit(1)
            }
            Spacer(minLength:8)
            switch state {
            case .connected:
                Label("Connected",systemImage:"checkmark.circle.fill").font(.callout).foregroundStyle(MailDotStyle.successText)
            case .checking:
                HStack(spacing:6) { ProgressView().controlSize(.mini); Text("Checking").font(.callout).foregroundStyle(MailDotStyle.supporting) }
            case .connect:
                Button("Connect…",action:connect).controlSize(.small)
            }
        }
        .padding(.horizontal,12).padding(.vertical,8)
        .accessibilityElement(children:.contain)
    }

    // MARK: Rows

    private func title(_ step:SetupFlow.Step) -> LocalizedStringKey {
        switch step {
        case .accessibility: "Turn on Accessibility for Mail Dot"
        case .mail: "Allow Mail Dot to work with Mail"
        case .extensionOn: "Turn on Mail Dot in Mail"
        case .connect: "Connect Mail Dot to Dot"
        }
    }
    @ViewBuilder private func row(_ step:SetupFlow.Step) -> some View {
        let done=found.done(step),current=found.current == step
        VStack(alignment:.leading,spacing:8) {
            // One element for VoiceOver: the step and whether it is done.
            HStack(alignment:.center,spacing:12) {
                ZStack {
                    Circle().fill(done ? Color.green : Color.primary.opacity(0.08)).frame(width:28,height:28)
                    if done { Image(systemName:"checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) }
                    else { Text(verbatim:"\(step.rawValue+1)").font(.callout.weight(.semibold)) }
                }
                Text(title(step)).fontWeight(.semibold).foregroundStyle(done || current ? Color.primary : MailDotStyle.supporting)
                Spacer(minLength:0)
            }
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(Text(title(step)))
            .accessibilityValue(done ? Text("Done") : Text("Not Done"))
            if current {
                VStack(alignment:.leading,spacing:10) { detail(step) }.padding(.leading,40)
            }
        }
    }
    @ViewBuilder private func detail(_ step:SetupFlow.Step) -> some View {
        switch step {
        case .accessibility:
            sentence("Mail Dot writes to Dot in ChatGPT and starts calls with Dot.")
            Button("Open System Settings") { openAccessibility() }.buttonStyle(.borderedProminent)
        case .mail:
            sentence("Mail Dot reads the messages you choose and places Dot’s drafts.")
            Button("Continue") { allowMail() }.buttonStyle(.borderedProminent).disabled(busy)
        case .extensionOn:
            sentence("In Mail, choose Mail > Settings, click Extensions, and select the Mail Dot checkbox.")
            Button("Open Mail") { Task { await MailExtensionsPane.open() } }.buttonStyle(.borderedProminent)
        case .connect:
            connection
        }
        if let note,found.current == step { warning(note) }
    }
    private func sentence(_ text:LocalizedStringKey) -> some View {
        Text(text).foregroundStyle(MailDotStyle.supporting).fixedSize(horizontal:false,vertical:true)
    }
    /// A line that tells of trouble carries a symbol as well as its colour.
    private func warning(_ text:String) -> some View {
        Label { Text(verbatim:text).fixedSize(horizontal:false,vertical:true) } icon: { Image(systemName:"exclamationmark.triangle.fill") }
            .foregroundStyle(MailDotStyle.warningText)
    }

    // MARK: The connection step

    static func stageName(_ stage:String) -> String {
        switch stage {
        case "started": String(localized:"Dot started")
        case "tunnel_created": String(localized:"Connection created")
        case "key_created": String(localized:"Key created")
        case "connection_saved": String(localized:"Key handed to Mail Dot")
        case "plugin_added": String(localized:"Mail Dot added to ChatGPT")
        case "done": String(localized:"Dot finished setting up")
        case "subscribed": String(localized:"Mail Dot sees both subscriptions")
        case "drafting_answered": String(localized:"Dot answered a drafting test")
        case "settings_answered": String(localized:"Dot answered a settings test")
        default: String(localized:"Done")
        }
    }
    @ViewBuilder private var connection:some View {
        switch found.connection {
        case .noChatGPT:
            sentence("ChatGPT is not installed.")
            Button("Get ChatGPT") { NSWorkspace.shared.open(Self.chatGPTDownload) }.buttonStyle(.borderedProminent)
        case .ready:
            sentence("Dot creates a private connection on your OpenAI account and a key that runs only that connection. Mail Dot keeps the key in your Keychain. Dot reads none of your mail during setup.")
            HStack(spacing:10) {
                if unreachable { Button("Show ChatGPT") { showChatGPT() } }
                Button("Ask Dot to Connect") { ask(fresh:true) }.buttonStyle(.borderedProminent).disabled(busy)
            }
        case .working(let reached):
            stages(reached:reached,pending:true)
        case .stalled(let last):
            stages(reached:last.flatMap(SetupFlow.stages.firstIndex).map{ $0+1 } ?? 0,pending:false)
            if let last,SetupFlow.checks.contains(last) { Text("Dot has not answered Mail Dot’s test requests.").fixedSize(horizontal:false,vertical:true) }
            else if let last { Text("Dot has not answered since “\(Self.stageName(last)).”").fixedSize(horizontal:false,vertical:true) }
            else { Text("Dot has not answered.") }
            // Why is nearly always in ChatGPT: an approval Dot waits for, a sign-in page, or Dot unable to work on this Mac.
            Text("Look at what Dot wrote in ChatGPT.").fixedSize(horizontal:false,vertical:true)
            continueButtons
        case .blocked(let stopped,let last):
            stages(reached:last.flatMap(SetupFlow.stages.firstIndex).map{ $0+1 } ?? 0,pending:false)
            // Dot's own words, as one short line: what a task wrote is shown, not obeyed, and never at length.
            warning(String(localized:"Dot stopped: \(String(stopped.split(whereSeparator:\.isNewline).joined(separator:" ").filter{ !$0.unicodeScalars.contains(where:{ $0.properties.generalCategory == .control }) }.prefix(160)))"))
            continueButtons
        case .complete:
            EmptyView()
        }
    }
    private var continueButtons:some View {
        HStack(spacing:10) {
            Button("Show ChatGPT") { showChatGPT() }
            Button("Ask Dot to Continue") { ask(fresh:false) }.buttonStyle(.borderedProminent).disabled(busy)
        }
    }
    /// The six stages Dot reports: a check mark on each one reached, a spinner on the one pending.
    /// Then Mail Dot's own three checks: both subscriptions seen, and Dot's answer to a test through each handler.
    /// The two tests run together, so each has its own mark.
    private func stages(reached:Int,pending:Bool) -> some View {
        let dot=SetupFlow.stages.count,checked=SetupFlow.checked(found.facts)
        let lines:[(name:String,done:Bool,active:Bool)]=SetupFlow.stages.indices.map{ (SetupFlow.stages[$0],$0 < reached,$0 == reached) }
            + SetupFlow.checks.indices.map{ index in (SetupFlow.checks[index],checked[index],index == 0 ? reached == dot : checked[0] && !checked[index]) }
        return VStack(alignment:.leading,spacing:6) {
            ForEach(Array(lines.enumerated()),id:\.offset) { _,line in
                HStack(spacing:8) {
                    ZStack {
                        if line.done { Image(systemName:"checkmark.circle.fill").foregroundStyle(.green) }
                        else if line.active,pending { ProgressView().controlSize(.small) }
                        else { Image(systemName:"circle").foregroundStyle(.tertiary) }
                    }.frame(width:18,height:18)
                    Text(verbatim:Self.stageName(line.name)).foregroundStyle(line.done || line.active ? Color.primary : MailDotStyle.supporting)
                }
                .accessibilityElement(children:.ignore)
                .accessibilityLabel(Text(verbatim:Self.stageName(line.name)))
                .accessibilityValue(line.done ? Text("Done") : Text("Not Done"))
            }
        }
    }

    // MARK: Actions

    static let chatGPTDownload=URL(string:"https://chatgpt.com/download")!
    /// macOS can ask about Mail only while Mail is open, so Mail is opened first. After an earlier "no" macOS does
    /// not ask again, and its Automation settings are opened instead.
    private func allowMail() {
        note=nil; busy=true
        Task {
            defer { busy=false }
            if !found.mailRunning {
                MailExtensionStatus.openMail()
                for _ in 0..<40 where !NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").contains(where:{ $0.isFinishedLaunching }) { try? await Task.sleep(for:.milliseconds(500)) }
            }
            let status=await MailAutomation().permissionStatus(requestConsent:true)
            if status == -1743 {
                note=String(localized:"macOS is not letting Mail Dot work with Mail. In System Settings, under Automation, turn on Mail for Mail Dot.")
                Self.open(pane:"Privacy_Automation")
            }
        }
    }
    /// The prompt adds Mail Dot to the Accessibility list; the switch is on that page of System Settings.
    private func openAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt":true] as CFDictionary)
        Self.open(pane:"Privacy_Accessibility")
    }
    private func showChatGPT() {
        guard let app=NSWorkspace.shared.urlForApplication(withBundleIdentifier:DotCallLauncher.chatGPTBundleID) else { return }
        NSWorkspace.shared.openApplication(at:app,configuration:NSWorkspace.OpenConfiguration(),completionHandler:nil)
    }
    static func open(pane:String) {
        if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
    /// Starts Mail Dot's connection helper, lists Mail Dot's helper in ChatGPT's settings for setup, opens ChatGPT
    /// if it is closed, and writes Dot the request: the whole of it the first time, and afterwards only what is
    /// left, so Dot does not make a second tunnel and key.
    private func ask(fresh:Bool) {
        note=nil; unreachable=false; busy=true
        Task {
            defer { busy=false }
            do { try await BackgroundConnection.setEnabled(true) }
            catch { note=String(localized:"macOS did not allow Mail Dot’s background item. Allow it in System Settings, General, Login Items."); Self.openLoginItems(); return }
            guard SetupCodexEntry.add(),let bridge=try? BridgeStore.shared().directory else { note=String(localized:"Mail Dot could not add itself to ChatGPT’s settings."); return }
            let name=SetupThroughDot.connectionName()
            let reached=SetupFlow.stages.filter{ stage in found.reports.contains{ $0.step == stage } }
            let text=fresh ? SetupThroughDot.request(name:name) : SetupThroughDot.continuation(name:name,completed:reached)
            if let refusal=await DotCallLauncher.say(text) {
                // No Message field on Dot's page: ChatGPT is signed out, has no account, or its plan has no Dot. Mail
                // Dot cannot tell which, so the sentence names what to check (installer review, 18 November 2026).
                if refusal == .noField {
                    unreachable=true
                    let button=fresh ? String(localized:"Ask Dot to Connect") : String(localized:"Ask Dot to Continue")
                    note=String(localized:"Mail Dot could not reach Dot in ChatGPT. Sign in to ChatGPT with an account whose plan includes Dot, then press \(button) again.")
                } else { note=String(localized:String.LocalizationValue(refusal.rawValue)) }
                // The text is in ChatGPT's field and needs only Return: Dot is as good as asked.
                guard refusal == .notSent else { return }
            }
            try? SetupThroughDot.noteAsked(in:bridge,fresh:fresh)
            found=await SetupFindings.look()
        }
    }
    static func openLoginItems() {
        if let url=URL(string:"x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}

/// Mail Dot's entry in ChatGPT's local-tools settings during setup.
enum SetupCodexEntry {
    static var file:URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml") }
    static var agent:String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MailDotAgent").path }
    @discardableResult static func add() -> Bool {
        let folder=file.deletingLastPathComponent()
        let contents=try? String(contentsOf:file,encoding:.utf8)
        if contents == nil,FileManager.default.fileExists(atPath:file.path) { return false }
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            // Written into the file as it stands, so a file that is a link, or has permissions of its own, stays as it is.
            try Data(SetupThroughDot.registering(agentPath:agent,in:contents).utf8).write(to:file)
            return true
        } catch { return false }
    }
    /// Takes the entry out again. Only an entry written for setup is touched.
    static func remove() {
        guard let contents=try? String(contentsOf:file,encoding:.utf8),SetupThroughDot.isRegisteredForSetup(in:contents) else { return }
        try? Data((SetupThroughDot.removing(in:contents)+"\n").utf8).write(to:file)
    }
    /// The entry lets a task on this Mac replace Mail Dot's tunnel and key, so it does not outlive the setup it was
    /// written for (installer design review, 15 November 2026): it goes when setup is complete, when Dot has
    /// reported nothing for thirty minutes, when it is found with no setup in progress, and when Mail Dot quits.
    @MainActor static func tick() {
        guard let contents=try? String(contentsOf:file,encoding:.utf8),SetupThroughDot.isRegisteredForSetup(in:contents),
              let bridge=try? BridgeStore.shared() else { return }
        let reports=SetupThroughDot.reports(in:bridge.directory)
        let complete=reports.contains{ $0.step == "done" } || (!MailDotSetupWindow.needed && ConnectionWatch.listening(bridge))
        guard SetupThroughDot.shouldWithdraw(complete:complete,askedAt:SetupThroughDot.askedAt(in:bridge.directory),reports:reports) else { return }
        remove()
    }
    /// The owner's press is forgotten once Mail Dot has seen Dot answer both test requests, and not before: until
    /// then the setup window shows its progress from it. An abandoned setup keeps what Dot reported and when it was
    /// asked, so that opening setup again offers to continue it and not to start a second tunnel and key.
    @MainActor static func forgetWhenVerified() {
        guard let bridge=try? BridgeStore.shared(),let asked=SetupThroughDot.askedAt(in:bridge.directory),
              !MailDotSetupWindow.needed,ConnectionWatch.listening(bridge),
              let settings=try? MailSettingsStore(bridgeDirectory:bridge.directory).read(),
              SetupVerification.verified(settings,since:asked) else { return }
        SetupThroughDot.forgetAsked(in:bridge.directory)
    }
}
