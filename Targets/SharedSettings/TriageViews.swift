import SwiftUI
import AppKit
import notify
import BridgeCore

/// The owner's actions on Mail Dot's list of arriving mail, written to the shared stores.
@MainActor enum TriageCommands {
    static func setAutomaticReplies(_ on:Bool,account id:String) throws {
        try MailSettingsStore.shared().transaction { $0.setAutomaticReplies(on,account:id) }
        DotCallCommands.wakeCompanion()
    }
    static func setMailDot(_ on:Bool,account id:String) throws {
        try MailSettingsStore.shared().transaction { $0.setMailDot(on,account:id) }
        DotCallCommands.wakeCompanion()
    }
    static func setSearchByMeaning(_ on:Bool,account id:String) throws {
        try MailSettingsStore.shared().transaction { $0.setSearchByMeaning(on,account:id) }
        DotCallCommands.wakeCompanion()
    }
    /// `opensReply`: asked in the Mail Dot window, so the draft opens in a Mail reply once Dot has written it.
    static func ask(_ id:String,opensReply:Bool=false) throws {
        try MailTriageStore.shared().transaction { state in
            let drafting=state.entries.first{$0.id == id}?.draftRequested == true
            try state.ask(id)
            if opensReply,drafting { state.openReplyWhenDrafted(id) }
        }
        DotCallCommands.wakeCompanion()
    }
    /// Draft a Reply, with the owner's optional words on what the reply should say.
    static func draftReply(_ id:String,guidance:String,opensReply:Bool=false) throws {
        try MailTriageStore.shared().transaction { state in
            try state.ask(id,draft:true,guidance:guidance)
            if opensReply { state.openReplyWhenDrafted(id) }
        }
        DotCallCommands.wakeCompanion()
    }
    /// Open in Reply: the background app opens a Mail reply with Dot's draft in it once this window has closed, since
    /// Mail keeps the rest of its windows waiting while it is open.
    static func openInReply(_ id:String) throws {
        try MailTriageStore.shared().transaction { try $0.requestOpenReply(id) }
        DotCallCommands.wakeCompanion()
    }
    /// The Ask Dot button: the background app shows its floating ask bar, at once by a notification and, should
    /// that not arrive, within a few seconds by the note left in the shared store.
    static func showAskBar() throws {
        try MailTriageStore.shared().transaction { $0.askBarRequestedAt = .now }
        notify_post("org.jgkarlin.MailBridge.askbar.show")
        DotCallCommands.wakeCompanion()
    }
    /// Ask Dot for a Report: the thread report alone, never a draft.
    static func askForReport(_ id:String) throws { try MailTriageStore.shared().transaction { try $0.requestReport(id) }; DotCallCommands.wakeCompanion() }
    /// The owner's own verdict: closed as No reply needed, without asking Dot.
    static func noReplyNeeded(_ id:String) throws { try MailTriageStore.shared().transaction { try $0.markNoReplyNeeded(id) } }
    static func discardDraft(_ id:String) throws { try MailTriageStore.shared().transaction { try $0.discardDraft(id) } }
    /// Add to Calendar: the background app adds the meeting and records the result on the entry.
    static func addToCalendar(_ id:String) throws { try MailTriageStore.shared().transaction { try $0.requestCalendar(id) }; DotCallCommands.wakeCompanion() }
    /// "Confirm before sending" in Settings; on is the default and is stored as absent.
    static func setConfirmBeforeSending(_ on:Bool) throws { try MailSettingsStore.shared().transaction { $0.confirmBeforeSending=on ? nil : false } }
    static func setLayout(_ layout:MailDotWindowLayout) throws { try MailSettingsStore.shared().transaction { $0.windowLayout=layout == .briefing ? nil : layout } }
    static func layout() async -> MailDotWindowLayout {
        await Task.detached { (try? MailSettingsStore.shared().read())?.windowLayout ?? .briefing }.value
    }
    static func answer(_ id:String,_ text:String,opensReply:Bool=false) throws {
        try MailTriageStore.shared().transaction { state in
            try state.answer(id,with:text)
            if opensReply { state.openReplyWhenDrafted(id) }
        }
        DotCallCommands.wakeCompanion()
    }
    static func rule(_ rule:MailTriage.Rule?,for sender:String) throws { try MailTriageStore.shared().transaction { $0.setRule(rule,for:sender) } }
    /// Check Again: a light request asks Dot to confirm it answers on this Mac.
    static func checkDot() throws { try MailSettingsStore.shared().transaction { $0.requestDotCheck() }; DotCallCommands.wakeCompanion() }
    static func dotAccess() async -> DotAccess { await Task.detached { (try? MailSettingsStore.shared().read())?.effectiveDotAccess ?? DotAccess() }.value }
    static func reportRule(_ rule:MailTriage.Rule?,for sender:String) throws { try MailTriageStore.shared().transaction { $0.setReportRule(rule,for:sender) } }
    /// For one sender: the report rule and whether the owner keeps drafting notes for them.
    static func senderChoices(_ sender:String) async -> (report:MailTriage.Rule?,hasNotes:Bool) {
        await Task.detached {
            ((try? MailTriageStore.shared().read())?.reportRule(for:sender),(try? MailSettingsStore.shared().read())?.senderNote(for:sender)?.items.isEmpty == false)
        }.value
    }
    /// Where one message stands in Dot's queue, read from the queue of arriving mail and the requests Dot has.
    static func queuePlace(_ id:String) async -> DotQueuePlace? {
        await Task.detached {
            guard let triage=try? MailTriageStore.shared().read(),let entry=triage.entries.first(where:{$0.id == id}),
                  [.pending,.asked].contains(entry.outcome),let directory=try? BridgeStore.shared().directory else { return nil }
            let workflow=(try? MailWorkflowStore(bridgeDirectory:directory).read()) ?? MailWorkflowState()
            return DotQueuePlace.of(entry,triage:triage,workflow:workflow)
        }.value
    }
    static func load() async -> (entries:[MailTriageEntry],rules:[String:MailTriage.Rule],automatic:Bool) {
        await Task.detached {
            let state=(try? MailTriageStore.shared().read()) ?? MailTriageState()
            return (state.entries,state.rules,true)
        }.value
    }
}

/// Each state as an icon that reads without a key, with its words on hover.
private func stateIcon(_ entry:MailTriageEntry) -> (symbol:String,color:Color,words:String) {
    switch entry.outcome {
    case .drafted:("square.and.pencil",.green,String(localized:"Dot’s draft is ready"))
    case .needsGuidance:("questionmark.bubble.fill",.orange,String(localized:"Dot needs your guidance"))
    case .pending,.asked:("ellipsis.bubble",.blue,String(localized:"Dot is checking it"))
    case .noDraft:("checkmark.circle",.secondary,String(localized:"No reply needed"))
    case .replied:("arrowshape.turn.up.left.fill",.secondary,String(localized:"You replied"))
    case .failed:("exclamationmark.triangle.fill",.yellow,String(localized:"Dot could not check it"))
    case .held:("pause.circle",.secondary,String(localized:"Not offered: automatic drafting was off"))
    case .skipped:("minus.circle",.secondary,String(localized:"Skipped"))
    }
}

/// One arriving message, its state, and what the owner can do about it.
struct TriageEntryRow:View {
    let entry:MailTriageEntry
    let rule:MailTriage.Rule?
    var compact=true
    let changed:() -> Void
    @State private var failure:String?
    var body:some View {
        VStack(alignment:.leading,spacing:4) {
            HStack(alignment:.firstTextBaseline,spacing:7) {
                let icon=stateIcon(entry)
                Image(systemName:icon.symbol).foregroundStyle(icon.color).frame(width:16).help(icon.words).accessibilityLabel(icon.words)
                VStack(alignment:.leading,spacing:1) {
                    Text(entry.subject.isEmpty ? String(localized:"(no subject)") : entry.subject).fontWeight(.semibold).lineLimit(compact ? 1 : 3)
                    Text(entry.senderName ?? entry.sender).font(.caption).foregroundStyle(MailDotStyle.supporting).lineLimit(1)
                }
                Spacer(minLength:4)
                SenderMenuButton(groups:[.init(title:String(localized:"Automatic drafts for this sender"),symbol:"square.and.pencil",rule:rule) { value in set(value) }])
                    .fixedSize()
            }
            // Dot's question is shown once, in its card below, not also as the state line.
            if !(entry.outcome == .needsGuidance && entry.dotNote != nil) {
                Text(entry.stateLine).font(.callout).foregroundStyle(MailDotStyle.supporting).lineLimit(compact ? 2 : 6).fixedSize(horizontal:false,vertical:true)
            }
            if entry.outcome == .drafted,let draft=entry.draft,!compact {
                Text(draft).textSelection(.enabled).padding(8).frame(maxWidth:.infinity,alignment:.leading)
                    .background(RoundedRectangle(cornerRadius:6).fill(Color(nsColor:.textBackgroundColor)))
                Button("Discard Draft",systemImage:"trash") { act { try MailTriageStore.shared().transaction { try $0.discardDraft(entry.id) } } }.controlSize(.small)
            }
            if entry.outcome == .needsGuidance,let question=entry.dotNote {
                TriageQuestionCard(question:question) { words in act { try TriageCommands.answer(entry.id,words) } }
            }
            if entry.outcome == .failed {
                Button("Try Again") { act { try TriageCommands.ask(entry.id) } }.controlSize(.small)
            } else if [.skipped,.held,.noDraft].contains(entry.outcome) {
                DraftReplyButton { words in act { try TriageCommands.draftReply(entry.id,guidance:words) } }.controlSize(.small)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(MailDotStyle.dangerText) }
        }
        .padding(.vertical,5)
    }
    private func set(_ value:MailTriage.Rule?) { act { try TriageCommands.rule(value,for:entry.sender) } }
    private func act(_ body:() throws -> Void) {
        do { try body(); failure=nil; changed() } catch { failure=error.localizedDescription }
    }
}

/// One mail account as the settings show it: how Mail Dot reaches it, and its automatic replies. An
/// account Dot reaches through its Gmail connector and that is also in Mail on this Mac is one account.
struct MailDotAccountRow:Identifiable,Equatable {
    let id:String
    /// The account in Mail on this Mac, when there is one: what Connect sets up.
    let native:NativeMailAccount?
    /// The owner has allowed folders of this account (through Mail on this Mac).
    let allowed:Bool
    /// Where the connection stands beyond its route, in words: Mail Dot's check of the folders, then Dot's
    /// confirmation. Nil when there is nothing to say.
    let check:String?
    let checkFailed:Bool
    /// Mail Dot's own check of the folders is running.
    let checking:Bool
    /// Mail Dot's account ids that this row stands for; its switch sets all of them.
    let accountIDs:[String]
    let name:String
    let addresses:[String]
    let connection:String
    let connected:Bool
    let automatic:Bool
    /// Mail Dot works on this account; off, Mail Dot leaves it alone.
    let mailDot:Bool
    /// Search by Meaning can be ticked: the account is read through Mail on this Mac, with folders allowed. An
    /// account Dot reaches through a connector has no box, since Dot searches it there.
    var meaningOffered=false
    var meaning=false
    /// How far its embedding has come: messages embedded, and messages in the index.
    var embedded=0
    var total=0
    /// A Gmail or Google Workspace account without Dot's Gmail connector: the row offers the connector, and never AppleScript
    /// (owner decisions, 15 November 2026). One already read through Mail keeps working until the connector is confirmed.
    var offersConnector=false
    /// An iCloud Mail account: the row offers ChatGPT's iCloud Mail plugin, and never AppleScript (owner decision, 15
    /// November 2026). One already set up through AppleScript keeps working until the plugin is confirmed.
    var offersICloudConnector=false

    static func load() async -> [MailDotAccountRow] {
        await Task.detached {
            guard let bridge=try? BridgeStore.shared(),let settings=try? MailSettingsStore(bridgeDirectory:bridge.directory).read() else { return [] }
            let nativeState=(try? NativeMailStore(bridgeDirectory:bridge.directory).read()) ?? NativeMailState()
            let gmail=settings.connections.filter{MailConnection.connectorProviders.contains($0.provider)}
            // Counted by the background app; Settings itself never opens the index of mail.
            let progress=MeaningProgress.read(bridgeDirectory:bridge.directory)
            var used=Set<String>()
            var rows:[MailDotAccountRow]=[]
            func row(name:String,addresses:[String],ids:[String],viaConnector:MailConnection?,native:NativeMailAccount?=nil) -> MailDotAccountRow {
                let connectorUp=viaConnector.map{$0.available && $0.observedAt != nil} ?? false
                let grant=native.flatMap{account in nativeState.grants.first{$0.accountID == account.id && $0.revokedAt == nil && !$0.mailboxes.isEmpty}}
                let verified=grant?.verifiedAt != nil
                let iCloud=viaConnector?.provider == "icloud" || native?.isICloud == true
                let gmail = !iCloud && (viaConnector != nil || native?.isGmail == true)
                // Gmail and iCloud are reached only through their plugins; AppleScript is for accounts that have none
                // (owner decision, 15 November 2026). One already read through Mail keeps working until its plugin is confirmed.
                let connection=connectorUp ? (iCloud ? String(localized:"iCloud, through Dot’s iCloud connector") : String(localized:"Gmail, through Dot’s Gmail connector"))
                    : verified ? String(localized:"Mail on this Mac, through AppleScript")
                    : iCloud ? String(localized:"iCloud connector not connected")
                    : gmail ? String(localized:"Gmail connector not connected")
                    : String(localized:"Mail on this Mac, through AppleScript: not yet connected")
                var check:String?,failed=false,checking=false
                if let account=native,!connectorUp {
                    let probe=NativeMailCoordinator.latestCheck(accountID:account.id,state:nativeState)
                    // Dot's latest confirmation that it can read the account through Mail on this Mac.
                    let link=settings.requests.last{$0.kind == .nativeLink && $0.input?.nativeAccountID == account.id}
                    if grant == nil {
                        check=nil
                    } else if let probe,probe.result == nil,probe.error == nil {
                        check=String(localized:"Mail Dot is checking the folders you allowed…"); checking=true
                    } else if !verified {
                        if let error=probe?.error { check=String(localized:"Mail Dot could not read the folders: \(error)"); failed=true }
                        else { check=String(localized:"Not checked yet. Press Check Again with Mail open.") }
                    } else if let link {
                        switch link.status {
                        case .confirmed: check=String(localized:"Dot confirmed it can read this account.")
                        case .failed: check=String(localized:"Dot could not read it")+(link.outcome.map{": "+$0} ?? "."); failed=true
                        case .question: check=String(localized:"Dot asks: ")+(link.question ?? String(localized:"a question about this account."))
                        case .pending,.awaitingAuthorization: check=String(localized:"Connected. Dot will confirm it can read this account the next time it checks.")
                        }
                    }
                }
                // Use Gmail/iCloud Connector… asks Dot to confirm the connection: the row says so until Dot answers, and gives
                // Dot's reason if it could not confirm (owner request, 15 November 2026).
                if !connectorUp,iCloud || gmail,let address=addresses.first.map(MailDraft.address),
                   let asked=settings.requests.last(where:{ $0.kind == .activate && $0.email.map(MailDraft.address) == address }) {
                    switch asked.status {
                    case .pending,.awaitingAuthorization: check=String(localized:"Asking Dot to confirm the connection…"); checking=true; failed=false
                    case .failed: check=String(localized:"Dot could not confirm the connection")+(asked.outcome.map{": "+$0} ?? "."); failed=true; checking=false
                    case .question: check=String(localized:"Dot asks: ")+(asked.question ?? String(localized:"a question about this account.")); checking=false
                    case .confirmed: break
                    }
                }
                var made=MailDotAccountRow(id:ids.joined(separator:"+"),native:connectorUp ? nil : native,allowed:grant != nil,check:check,checkFailed:failed,checking:checking,accountIDs:ids,name:name,addresses:addresses,connection:connection,
                                         connected:connectorUp || verified,automatic:ids.allSatisfy(settings.automaticReplies(account:)),mailDot:ids.allSatisfy(settings.mailDot(account:)))
                if let account=native,!connectorUp,account.isGmail { made.offersConnector=true }
                if !connectorUp,iCloud { made.offersICloudConnector=true }
                if let account=native,!connectorUp,grant != nil {
                    made.meaningOffered=true
                    made.meaning=settings.searchByMeaning(account:account.id)
                    if made.meaning,let counts=progress[account.id] { made.embedded=counts.embedded; made.total=counts.total }
                }
                return made
            }
            for account in settings.nativeAccounts {
                let lower=Set(account.addresses.map{$0.lowercased()})
                let connector=gmail.first{lower.contains($0.email.lowercased())}
                if let connector { used.insert(connector.id) }
                rows.append(row(name:account.name,addresses:account.addresses,ids:["mail:"+account.id]+(connector.map{[$0.accountID]} ?? []),viaConnector:connector,native:account))
            }
            for connection in gmail where !used.contains(connection.id) {
                rows.append(row(name:connection.email,addresses:[connection.email],ids:[connection.accountID],viaConnector:connection))
            }
            return rows
        }.value
    }
}

/// Mail Dot's settings, inside the Mail Dot panel: MailKit gives an extension no tab in Mail's Settings.
struct MailDotSettingsView:View {
    /// The width of each switch column, so that the headings sit over the switches.
    private static let switchColumn:CGFloat=56
    private static let columnGap:CGFloat=4
    /// The account whose Search by Meaning box was ticked first: the popup about Full Disk Access is showing for it.
    @State private var meaningAsked:String?
    /// Whether macOS lets Mail Dot read the Mail folder, as the background app last found it.
    @State private var diskAccess:Bool?
    @State private var accounts:[MailDotAccountRow]=[]
    @State private var loaded=false
    @State private var failure:String?
    @StateObject private var model=MailSettingsModel()
    /// The account being connected through Mail on this Mac, while its folder choice is shown.
    @State private var connecting:NativeMailAccount?
    @FocusState private var newRuleFocused:Bool
    @State private var tab:Tab = .accounts
    @State private var rules:[DraftingRule]=[]
    @State private var newRule=""
    /// The rule being edited, and its text while it is.
    @State private var editingRule:String?
    @State private var ruleText=""
    @State private var ruleFailure:String?
    @State private var confirmBeforeSending=true
    var body:some View {
        if let account=connecting {
            NativeMailSetupView(account:account,settings:model) { connecting=nil; Task { await reload() } }
        } else { list }
    }
    /// The settings' two tabs.
    enum Tab:Hashable { case accounts,rules,layout,connection }
    /// For rendering previews: the Connection tab's findings given instead of read from the stores.
    private let connectionPreview:ConnectionSnapshot?
    init(startTab:Tab = .accounts,connectionPreview:ConnectionSnapshot?=nil) { _tab=State(initialValue:startTab); self.connectionPreview=connectionPreview }
    private func settingsTab(_ value:Tab,_ title:LocalizedStringKey,symbol:String) -> some View {
        let selected=tab == value
        return Button { tab=value } label: {
            VStack(spacing:3) {
                Image(systemName:symbol).font(.system(size:18,weight:.regular)).frame(height:22)
                Text(title).font(.caption)
            }
            .foregroundStyle(selected ? AnyShapeStyle(MailDotStyle.linkText) : AnyShapeStyle(MailDotStyle.supporting))
            .frame(minWidth:80).padding(.horizontal,8).padding(.vertical,6)
            .background(RoundedRectangle(cornerRadius:7).fill(selected ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.clear)))
            .contentShape(RoundedRectangle(cornerRadius:7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? [.isButton,.isSelected] : .isButton)
    }
    private var list:some View {
        VStack(spacing:0) {
        // Two tabs side by side, each a symbol above its name, as at the top of Mail's own Settings window
        // (owner request, 13 November 2026): the selected one in blue on a light rounded highlight, the other
        // grey but plainly a tab; a thin divider below.
        HStack(spacing:4) {
            settingsTab(.accounts,"Accounts",symbol:"person.crop.circle")
            settingsTab(.rules,"Drafting Rules",symbol:"pencil.and.list.clipboard")
            settingsTab(.layout,"Layout",symbol:"rectangle.split.2x1")
            // Connection: what Mail Dot needs in place to work with Dot (owner approval, 14 November 2026).
            settingsTab(.connection,"Connection",symbol:"link")
        }
        .padding(.top,10).padding(.bottom,6)
        .accessibilityElement(children:.contain).accessibilityLabel("Mail Dot Settings")
        Divider()
        ScrollView {
            VStack(alignment:.leading,spacing:12) {
                if tab == .accounts {
                // The section's heading carries the names of the two switch columns, above the switches.
                HStack(alignment:.lastTextBaseline,spacing:6) {
                    Text("ACCOUNTS").font(.caption.weight(.semibold)).foregroundStyle(MailDotStyle.supporting).kerning(0.5)
                    Button { Task { await model.refreshAccounts(); await reload() } } label: { Image(systemName:"arrow.clockwise") }
                        .buttonStyle(.borderless).controlSize(.small).disabled(model.refreshing)
                        .help("Read Accounts from Mail").accessibilityLabel("Read Accounts from Mail")
                    if model.refreshing { ProgressView().controlSize(.mini) }
                    Spacer()
                    if !accounts.isEmpty {
                        HStack(alignment:.lastTextBaseline,spacing:Self.columnGap) {
                            Text("Mail Dot").font(.caption).foregroundStyle(MailDotStyle.supporting).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8).frame(width:Self.switchColumn)
                            Text("Auto replies").font(.caption).foregroundStyle(MailDotStyle.supporting).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8).frame(width:Self.switchColumn)
                            // The asterisk ties the footnote under the list to this column (owner's request, 15 November 2026).
                            Text(verbatim:String(localized:"Search by Meaning")+"*").font(.caption).foregroundStyle(MailDotStyle.supporting).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8).frame(width:Self.switchColumn)
                                .accessibilityLabel("Search by Meaning")
                        }
                    }
                }.padding(.horizontal,10)

                if accounts.isEmpty {
                    Text(loaded ? "No mail accounts are connected to Mail Dot." : "Loading…").font(.callout).foregroundStyle(MailDotStyle.supporting)
                }
                ForEach(accounts) { account in
                    HStack(alignment:.top,spacing:10) {
                        Image(systemName:account.native == nil ? "globe" : "envelope")
                            .foregroundStyle(account.connected && account.mailDot ? MailDotStyle.tint : MailDotStyle.supporting).frame(width:20).padding(.top,2)
                        VStack(alignment:.leading,spacing:2) {
                            Text(account.name).fontWeight(.semibold)
                            if account.addresses.count > 1 {
                                Text("\(account.addresses[0]) and \(account.addresses.count-1) more").font(.callout).foregroundStyle(MailDotStyle.supporting).lineLimit(1)
                                    .help(account.addresses.joined(separator:", "))
                            } else if let only=account.addresses.first,only != account.name {
                                Text(only).font(.callout).foregroundStyle(MailDotStyle.supporting).lineLimit(1)
                            }
                            if !account.mailDot {
                                Text("Off: Mail Dot leaves this account alone").font(.caption).foregroundStyle(MailDotStyle.supporting)
                            } else {
                                // The icon carries the state in colour; the words stay in a grey that reads (contrast fix, 15 November 2026).
                                Label {
                                    Text(account.connection).foregroundStyle(account.connected ? MailDotStyle.supporting : MailDotStyle.warningText)
                                } icon: {
                                    Image(systemName:account.connected ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(account.connected ? Color.green : Color.orange)
                                }.font(.caption)
                                if let check=account.check {
                                    HStack(alignment:.firstTextBaseline,spacing:5) {
                                        if account.checking { ProgressView().controlSize(.mini) }
                                        Text(check).font(.caption).foregroundStyle(account.checkFailed ? MailDotStyle.dangerText : MailDotStyle.supporting).lineLimit(3).fixedSize(horizontal:false,vertical:true)
                                    }
                                }
                                if account.meaning {
                                    HStack(spacing:8) {
                                        ProgressView(value:account.total > 0 ? Double(account.embedded)/Double(account.total) : 0).frame(width:90)
                                            .accessibilityLabel("Search by Meaning for \(account.name)")
                                        Text("\(account.embedded) of \(account.total)").font(.caption).monospacedDigit().foregroundStyle(MailDotStyle.supporting).lineLimit(1).fixedSize()
                                    }
                                }
                                if account.offersConnector,let address=account.addresses.first {
                                    Button("Use Gmail Connector…") { model.activate(address,provider:"gmail"); Task { await reload() } }.controlSize(.small)
                                        .help("Dot searches Gmail better through its own connector. This account keeps working through Mail until the connector is on.")
                                }
                                if account.offersICloudConnector,let address=account.addresses.first {
                                    Button("Use iCloud Connector…") { model.activate(address,provider:"icloud"); Task { await reload() } }.controlSize(.small)
                                        .help("Dot reaches iCloud Mail through ChatGPT’s iCloud connector. An account already set up through Mail keeps working until the connector is confirmed.")
                                }
                                // A Gmail or iCloud account is never set up through AppleScript; one already set up keeps its folders until
                                // its plugin is confirmed (owner decision, 15 November 2026).
                                if let native=account.native,!((native.isICloud || native.isGmail) && !account.allowed) {
                                    if !account.allowed {
                                        Button("Connect…") { model.reload(); connecting=native }.buttonStyle(.borderedProminent).controlSize(.small)
                                    } else {
                                        HStack(spacing:8) {
                                            Button("Change Folders…") { model.reload(); connecting=native }.controlSize(.small)
                                            if !account.checking,!account.connected || account.checkFailed {
                                                Button("Check Again") { recheck(native) }.controlSize(.small)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .opacity(account.mailDot ? 1 : 0.55)
                        Spacer(minLength:8)
                        // Three columns, so boxes and not switches (owner's request, 15 November 2026).
                        HStack(alignment:.top,spacing:Self.columnGap) {
                        Toggle("Mail Dot",isOn:Binding(get:{account.mailDot},set:{ value in
                            do { for id in account.accountIDs { try TriageCommands.setMailDot(value,account:id) }; failure=nil; Task { await reload() } }
                            catch { failure=error.localizedDescription }
                        })).toggleStyle(.checkbox).labelsHidden().frame(width:Self.switchColumn)
                        .help("Mail Dot for \(account.name)").accessibilityLabel("Mail Dot for \(account.name)")
                        Toggle("Automatic replies",isOn:Binding(get:{account.automatic && account.mailDot},set:{ value in
                            do { for id in account.accountIDs { try TriageCommands.setAutomaticReplies(value,account:id) }; failure=nil; Task { await reload() } }
                            catch { failure=error.localizedDescription }
                        })).toggleStyle(.checkbox).labelsHidden().frame(width:Self.switchColumn).disabled(!account.mailDot)
                        .help("Automatic replies for \(account.name)").accessibilityLabel("Automatic replies for \(account.name)")
                        // An account Dot reaches through a connector has no box: Dot searches it there.
                        Group {
                            if account.meaningOffered,let native=account.native {
                                Toggle("Search by Meaning",isOn:Binding(get:{account.meaning && account.mailDot},set:{ value in
                                    // The first box ticked brings the popup about Full Disk Access; later ones need none.
                                    if value,!accounts.contains(where:{ $0.meaning }) { meaningAsked=native.id } else { setMeaning(value,native.id) }
                                })).toggleStyle(.checkbox).labelsHidden().disabled(!account.mailDot)
                                .help("Search by Meaning for \(account.name)").accessibilityLabel("Search by Meaning for \(account.name)")
                            } else { Color.clear.frame(height:1).accessibilityHidden(true) }
                        }.frame(width:Self.switchColumn)
                        }.padding(.top,2)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius:8).fill(Color.primary.opacity(0.04)))
                }
                // The footnote to the third column's heading, in the owner's wording: why an account with a connector has no box there.
                if !accounts.isEmpty {
                    Text(verbatim:"*"+String(localized:"Not needed for Gmail or iCloud."))
                        .font(.caption).foregroundStyle(MailDotStyle.supporting).fixedSize(horizontal:false,vertical:true).padding(.horizontal,10)
                }
                // With a box ticked and no leave to read the Mail folder, Mail Dot reads through Mail; one line says so.
                if diskAccess == false,accounts.contains(where:{ $0.meaning }) {
                    HStack(spacing:8) {
                        Label("Full Disk Access is off",systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(MailDotStyle.warningText)
                        Spacer(minLength:8)
                        Button("Open System Settings") { try? ConnectionCommands.press(.openFullDiskAccess) }.controlSize(.small)
                    }.padding(.horizontal,10)
                }
                if let failure { Text(failure).font(.caption).foregroundStyle(MailDotStyle.dangerText) }
                } else if tab == .rules {
                    draftingRules
                    // Whether the panel's Send asks for a confirmation first (owner request, 17 November 2026).
                    Text("SENDING").font(.caption.weight(.semibold)).foregroundStyle(MailDotStyle.supporting).kerning(0.5).padding(.top,12)
                    Toggle("Confirm before sending",isOn:Binding(get:{confirmBeforeSending},set:{ value in
                        confirmBeforeSending=value
                        do { try TriageCommands.setConfirmBeforeSending(value) } catch { ruleFailure=error.localizedDescription }
                    }))
                } else if tab == .layout {
                    LayoutChoice()
                } else {
                    ConnectionList(fixed:connectionPreview)
                }
                MailDotCredits()
            }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
        }
        }
        .task { while !Task.isCancelled { await reload(); try? await Task.sleep(for:.seconds(3)) } }
        .alert("Search by Meaning Needs Full Disk Access",isPresented:Binding(get:{ meaningAsked != nil },set:{ if !$0 { meaningAsked=nil } })) {
            Button("Open System Settings") { if let id=meaningAsked { setMeaning(true,id); try? ConnectionCommands.press(.openFullDiskAccess) }; meaningAsked=nil }
            Button("Cancel",role:.cancel) { meaningAsked=nil }
        } message: {
            Text("Mail Dot reads your past mail from the Mail folder on this Mac to generate embeddings of it. This happens entirely on this Mac. Nothing is sent to the cloud or shared outside it. macOS grants this access for the whole disk, not for one folder; Mail Dot reads only the Mail folder.")
        }
    }
    private func setMeaning(_ on:Bool,_ account:String) {
        do { try TriageCommands.setSearchByMeaning(on,account:account); failure=nil; Task { await reload() } }
        catch { failure=error.localizedDescription }
    }
    /// The owner's rules for how Dot drafts: each can be edited or deleted, and a new one added. They are
    /// kept on this Mac and go to Dot with the next request for a draft.
    @ViewBuilder private var draftingRules:some View {
        Text("DRAFTING RULES").font(.caption.weight(.semibold)).foregroundStyle(MailDotStyle.supporting).kerning(0.5).padding(.top,6)
        ForEach(Array(rules.enumerated()),id:\.element.id) { index,rule in
            HStack(alignment:.top,spacing:8) {
                Text("\(index+1)").font(.caption.weight(.semibold)).foregroundStyle(MailDotStyle.supporting).frame(width:16,alignment:.trailing).padding(.top,2)
                if editingRule == rule.id {
                    TextField("Rule",text:$ruleText,axis:.vertical).ruleCounter(ruleText,limit:DraftingRules.textLimit).lineLimit(1...5).textFieldStyle(.roundedBorder).onSubmit { saveRule(rule.id) }
                    Button("Save") { saveRule(rule.id) }.controlSize(.small).disabled(blank(ruleText))
                    Button("Cancel") { editingRule=nil; ruleFailure=nil }.controlSize(.small)
                } else {
                    VStack(alignment:.leading,spacing:2) {
                        Text(rule.text).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                        if rule.tidying == true {
                            HStack(spacing:4) { ProgressView().controlSize(.mini); Text("Dot is tidying this rule").font(.caption).foregroundStyle(MailDotStyle.supporting) }
                        }
                    }
                    Spacer(minLength:6)
                    Button { editingRule=rule.id; ruleText=rule.text } label: { Image(systemName:"pencil") }
                        .buttonStyle(.borderless).help("Edit this rule").accessibilityLabel("Edit rule \(index+1)")
                    Button { changeRules { $0.removeDraftingRule(rule.id) } } label: { Image(systemName:"trash") }
                        .buttonStyle(.borderless).help("Delete this rule").accessibilityLabel("Delete rule \(index+1)")
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius:8).fill(Color.primary.opacity(0.04)))
        }
        HStack(alignment:.bottom,spacing:8) {
            TextField("Add a rule for Dot’s drafts",text:$newRule,axis:.vertical).ruleCounter(newRule,limit:DraftingRules.textLimit).lineLimit(1...4).textFieldStyle(.roundedBorder)
                .focused($newRuleFocused).onSubmit { addRule() }
            // Always a plain, full-size button, never faded: with nothing typed it only puts the cursor in the
            // box; once a rule is typed it turns blue (owner request, 13 November 2026).
            Group {
                if blank(newRule) {
                    Button { newRuleFocused=true } label: { Label("Add",systemImage:"plus") }.buttonStyle(.bordered)
                } else {
                    Button { addRule() } label: { Label("Add",systemImage:"plus") }.buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.regular).disabled(rules.count >= DraftingRules.limit)
        }
        if let ruleFailure { Text(ruleFailure).font(.caption).foregroundStyle(MailDotStyle.dangerText) }
        SenderNotesList()
    }
    private func blank(_ text:String) -> Bool { text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
    private func changeRules(_ body:(inout MailSettings) throws -> Void) {
        do { try MailSettingsStore.shared().transaction { try body(&$0) }; ruleFailure=nil; Task { await reload() } }
        catch { ruleFailure=error.localizedDescription }
    }
    private func addRule() {
        let text=newRule
        guard !blank(text) else { return }
        changeRules { try $0.addDraftingRule(text) }
        if ruleFailure == nil { newRule=""; tidyRules() }
    }
    private func saveRule(_ id:String) {
        let text=ruleText
        guard !blank(text) else { return }
        changeRules { try $0.updateDraftingRule(id,text:text) }
        if ruleFailure == nil { editingRule=nil; tidyRules() }
    }
    /// Sends each rule the owner just entered to Dot to tidy; Dot's wording replaces theirs when it comes.
    private func tidyRules() {
        let waiting=(try? MailSettingsStore.shared().read())?.rulesToTidy ?? []
        for rule in waiting { if let refusal=DotCallCommands.tidyRule(rule.id) { ruleFailure=refusal } }
    }
    private func reload() async {
        let fresh=await MailDotAccountRow.load()
        if fresh != accounts { accounts=fresh }
        let access=await Task.detached { (try? MailTriageStore.shared().read())?.connection?.fullDiskAccess }.value
        if access != diskAccess { diskAccess=access }
        let freshRules=await Task.detached { (try? MailSettingsStore.shared().read())?.effectiveDraftingRules ?? DraftingRules.starters }.value
        if freshRules != rules { rules=freshRules }
        let confirms=await Task.detached { (try? MailSettingsStore.shared().read())?.confirmsPanelSends ?? true }.value
        if confirms != confirmBeforeSending { confirmBeforeSending=confirms }
        loaded=true
    }
    /// Checks the account's allowed folders again on this Mac, and asks Dot again to confirm it can read
    /// them: Dot's open request is renewed rather than a new one added each time.
    private func recheck(_ account:NativeMailAccount) {
        model.reload()
        guard let grant=model.nativeGrants.first(where:{$0.accountID == account.id && $0.revokedAt == nil}) else { connecting=account; return }
        if let open=model.settings.requests.last(where:{$0.kind == .nativeLink && $0.input?.nativeAccountID == account.id && $0.input?.nativeGrantVersion == grant.version && ![.confirmed,.failed].contains($0.status)}) {
            model.verify(open)
        } else {
            model.verifyNative(account,grant:grant)
        }
        failure=model.error
        guard failure == nil else { return }
        do { _ = try NativeMailStore.shared().transaction { try NativeMailCoordinator.check(accountID:account.id,state:&$0) } }
        catch { failure=error.localizedDescription }
        DotCallCommands.wakeCompanion()
        Task { await reload() }
    }
}

/// Mail Dot's panel for a message Mail Dot saw arrive, opened from its banner.
struct TriageMessageView:View {
    static let size=CGSize(width:460,height:600)
    let entryID:String
    @State private var entry:MailTriageEntry?
    @State private var rule:MailTriage.Rule?
    @State private var settings=false
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:7) {
                if settings {
                    MailDotSettingsBar(returnsTo:Text(verbatim:"Mail Dot")) { settings=false }
                } else {
                    Image(systemName:"at.circle.fill").foregroundStyle(MailDotStyle.brand)
                    Text("Mail Dot").font(.headline)
                    Spacer()
                    Button("Settings",systemImage:"gearshape") { settings=true }.buttonStyle(.borderless)
                }
            }.padding(.horizontal,14).padding(.vertical,9)
            Divider()
            if settings { MailDotSettingsView() }
            else if let entry {
                ScrollView { TriageEntryRow(entry:entry,rule:rule,compact:false,changed:{ Task { await reload() } }).padding(16) }
            } else {
                Text("Mail Dot no longer lists this message.").foregroundStyle(MailDotStyle.supporting).frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }
        .frame(width:Self.size.width,height:Self.size.height)
        .background(Color(nsColor:.windowBackgroundColor))
        .tint(MailDotStyle.tint)
        .task { while !Task.isCancelled { await reload(); try? await Task.sleep(for:.seconds(2)) } }
    }
    private func reload() async {
        let fresh=await TriageCommands.load()
        entry=fresh.entries.first{$0.id == entryID}
        rule=entry.flatMap{fresh.rules[$0.sender]}
    }
}

/// Dot's question about a message it saw arrive, answered right here (owner request, 13 November 2026): each of Dot's
/// answers is one press, and "Something else…" opens a box to type or dictate the owner's own answer, or a
/// call with Dot. The answer goes to Dot at once, at the front of its queue, and Dot drafts with it.
struct TriageQuestionCard:View {
    let question:String
    /// From Dot's thread report: a fact bearing on the question, and a short consequence for each answer.
    var context:String?=nil
    var notes:[String]=[]
    /// The Ledger layout lays the answers out in two columns, with the box always open.
    var columns=1
    var boxAlwaysOpen=false
    var showsHeading=true
    /// Inside a tinted row of its own (Ledger): no panel of its own.
    var plain=false
    let send:(String) -> Void
    @State private var otherOpen=false
    @State private var otherText=""
    @State private var note:String?
    @FocusState private var otherFocused:Bool
    private var parsed:(question:String,answers:[String]) {
        let value=BridgeCoordinator.answers(in:question)
        let other=["something else","other","else","その他","ほか","別の"]
        return (value.question,value.answers.filter{answer in !other.contains{answer.lowercased().hasPrefix($0)}})
    }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            if showsHeading { Text("Dot needs to know").font(.caption.weight(.semibold)).foregroundStyle(MailDotStyle.supporting) }
            Text(parsed.question).font(.body.weight(.semibold)).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
            if let context { Text(context).font(.callout).foregroundStyle(MailDotStyle.supporting).fixedSize(horizontal:false,vertical:true) }
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:6,alignment:.top),count:max(1,columns)),alignment:.leading,spacing:6) {
                ForEach(Array(parsed.answers.enumerated()),id:\.offset) { index,answer in
                    option(index+1,answer,note:index < notes.count ? notes[index] : nil) { send(answer); note=String(localized:"Sent to Dot.") }
                }
                // With no answers of Dot's to choose from, a lone "Something else…" is no choice: the box is open.
                if !parsed.answers.isEmpty {
                    option(parsed.answers.count+1,String(localized:"Something else…"),open:boxAlwaysOpen ? nil : otherOpen) {
                        if boxAlwaysOpen { otherFocused=true } else { otherOpen.toggle(); if otherOpen { otherFocused=true } }
                    }
                }
            }
            if otherOpen || boxAlwaysOpen || parsed.answers.isEmpty {
                // The one box for writing to Dot (owner decision, 20 November 2026).
                DotTextBox(placeholder:"Tell Dot your answer, or how to draft the reply",text:$otherText,focus:$otherFocused,
                           canTell:!otherText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && otherText.count <= 2000,
                           call:{ note=DotCallCommands.call() ?? String(localized:"Opening a call with Dot in ChatGPT.") },
                           tell:{ let words=otherText.trimmingCharacters(in:.whitespacesAndNewlines); send(words); otherText=""; otherOpen=false; note=String(localized:"Sent to Dot.") },
                           dictationUnavailable:{ note=$0 })
            }
            if let note { Text(note).font(.caption).foregroundStyle(MailDotStyle.supporting) }
        }
        .padding(plain ? 0 : 12)
        .background(RoundedRectangle(cornerRadius:10).fill(MailDotStyle.warningText.opacity(plain ? 0 : 0.10)))
    }
    private func option(_ number:Int,_ title:String,note:String?=nil,open:Bool?=nil,_ action:@escaping () -> Void) -> some View {
        Button(action:action) {
            HStack(spacing:9) {
                Text("\(number)").font(.system(size:11,weight:.semibold)).foregroundStyle(MailDotStyle.supporting)
                    .frame(width:20,height:19).background(RoundedRectangle(cornerRadius:4).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius:4).stroke(Color.primary.opacity(0.22)))
                if columns > 1 {
                    VStack(alignment:.leading,spacing:1) {
                        Text(title).fontWeight(.medium).multilineTextAlignment(.leading)
                        if let note,!note.isEmpty { Text(note).font(.caption).foregroundStyle(MailDotStyle.supporting) }
                    }
                } else {
                    Text(title).fontWeight(.medium).multilineTextAlignment(.leading)
                }
                Spacer(minLength:0)
                if columns == 1,let note,!note.isEmpty { Text(note).font(.caption).foregroundStyle(MailDotStyle.supporting).lineLimit(1) }
                if let open { Image(systemName:open ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(MailDotStyle.supporting) }
            }
            .padding(.horizontal,10).padding(.vertical,7)
            .background(RoundedRectangle(cornerRadius:8).fill(Color.primary.opacity(open == true ? 0.09 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.primary.opacity(0.14)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(number), \(title)")
    }
}

/// Settings, Layout: which of the three layouts the Mail Dot window uses (owner request, 13 November 2026). One press
/// chooses; the open window changes at once, and so does every later one.
struct LayoutChoice:View {
    @State private var chosen:MailDotWindowLayout = .briefing
    @State private var failure:String?
    var body:some View {
        Text("MAIL DOT WINDOW").font(.caption.weight(.semibold)).foregroundStyle(MailDotStyle.supporting).kerning(0.5).padding(.top,6)
        HStack(alignment:.top,spacing:10) {
            card(.briefing,"Briefing","One column. What needs you comes first.")
            card(.storyline,"Storyline","The thread as a timeline, ending at your next step.")
            card(.ledger,"Ledger","Two panes in a wider window. Each decision is a row.")
        }
        if !MailDotThreadWindow.fits(.ledger) {
            Text("This screen is too small for Ledger, so the window shows Briefing here.").font(.caption).foregroundStyle(MailDotStyle.supporting).fixedSize(horizontal:false,vertical:true)
        }
        if let failure { Text(failure).font(.caption).foregroundStyle(MailDotStyle.dangerText) }
        Color.clear.frame(height:0).task { chosen=await TriageCommands.layout() }
    }
    private func card(_ layout:MailDotWindowLayout,_ name:LocalizedStringKey,_ line:LocalizedStringKey) -> some View {
        let selected=chosen == layout
        return Button {
            do { try TriageCommands.setLayout(layout); chosen=layout; failure=nil } catch { failure=error.localizedDescription }
        } label: {
            VStack(alignment:.leading,spacing:7) {
                LayoutSketch(layout:layout,selected:selected).frame(height:64)
                HStack(spacing:5) {
                    Image(systemName:selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(MailDotStyle.supporting))
                    Text(name).fontWeight(.semibold)
                }
                Text(line).font(.caption).foregroundStyle(MailDotStyle.supporting).multilineTextAlignment(.leading).fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:0)
            }
            .padding(9).frame(maxWidth:.infinity,minHeight:150,alignment:.topLeading)
            .background(RoundedRectangle(cornerRadius:9).fill(selected ? AnyShapeStyle(.tint.opacity(0.10)) : AnyShapeStyle(Color.primary.opacity(0.04))))
            .overlay(RoundedRectangle(cornerRadius:9).stroke(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.12)),lineWidth:selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius:9))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children:.combine)
        .accessibilityAddTraits(selected ? [.isButton,.isSelected] : .isButton)
    }
}

/// A small drawing of each layout, for its card.
private struct LayoutSketch:View {
    let layout:MailDotWindowLayout
    let selected:Bool
    var body:some View {
        let ink=Color.primary.opacity(0.18),accent=MailDotStyle.warningText.opacity(0.45)
        RoundedRectangle(cornerRadius:5).fill(Color(nsColor:.controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius:5).stroke(Color.primary.opacity(0.15)))
            .overlay(alignment:.topLeading) {
                Group {
                    switch layout {
                    case .briefing:
                        VStack(alignment:.leading,spacing:4) {
                            bar(ink,0.7); RoundedRectangle(cornerRadius:2).fill(accent).frame(height:14)
                            HStack(spacing:4) { bar(ink,1); bar(ink,1) }; bar(ink,0.9); bar(ink,0.6)
                        }
                    case .storyline:
                        HStack(alignment:.top,spacing:5) {
                            VStack(spacing:6) { ForEach(0..<4,id:\.self) { i in Circle().fill(i == 3 ? accent : ink).frame(width:6,height:6) } }
                            VStack(alignment:.leading,spacing:6) { bar(ink,0.9); bar(ink,0.7); bar(ink,0.8); RoundedRectangle(cornerRadius:2).fill(accent).frame(height:10) }
                        }
                    case .ledger:
                        HStack(alignment:.top,spacing:5) {
                            VStack(alignment:.leading,spacing:4) { bar(ink,1); bar(ink,0.8); bar(ink,0.9) }.frame(width:22)
                            VStack(alignment:.leading,spacing:3) { bar(ink,1); bar(ink,1); RoundedRectangle(cornerRadius:2).fill(accent).frame(height:14); bar(ink,1) }
                        }
                    }
                }.padding(7)
            }
            .accessibilityHidden(true)
    }
    private func bar(_ color:Color,_ share:CGFloat) -> some View {
        GeometryReader { proxy in RoundedRectangle(cornerRadius:1.5).fill(color).frame(width:proxy.size.width*share,height:5) }.frame(height:5)
    }
}

/// The sender's rules, as groups in the window's menu (owner request, 14 November 2026: "Always Ask Dot About This
/// Sender" did not say what it did). A checkmark shows the choice in force in each group. Always still obeys
/// the account's switches in Settings; Never does not stop the owner's own Draft a Reply or Ask Dot for a Report.
/// The sender menu, built with AppKit (owner request, 14 November 2026): SwiftUI's menu in these windows hid its icons, so
/// the current choice showed no checkmark, and macOS draws section titles grey. Here each choice carries the menu's own
/// checkmark, "Let Mail Dot Decide" when no rule is set, and each group has a dark header with an icon.
struct SenderMenuButton:NSViewRepresentable {
    struct Group {
        let title:String
        let symbol:String
        let rule:MailTriage.Rule?
        let set:(MailTriage.Rule?) -> Void
    }
    struct Note {
        let exists:Bool
        let edit:() -> Void
    }
    /// A command for this message, under the rules: the menu holds the panel's less-used commands (owner decision, 20
    /// November 2026).
    struct Extra {
        let title:String
        let run:() -> Void
    }
    let groups:[Group]
    var note:Note?=nil
    var extras:[Extra]=[]
    /// A line at the foot of the menu, such as Mail Dot's version; not a choice.
    var footer:String?=nil
    /// The checkmark column on the left and the menu's margins on both sides, beyond an item's title.
    static let titleMargins:CGFloat=56
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context:Context) -> NSButton {
        let button=NSButton(image:NSImage(systemSymbolName:"ellipsis.circle",accessibilityDescription:nil) ?? NSImage(),target:context.coordinator,action:#selector(Coordinator.open(_:)))
        button.isBordered=false; button.imagePosition = .imageOnly; button.contentTintColor = .controlAccentColor
        button.setAccessibilityLabel(String(localized:"More Mail Dot commands"))
        button.setContentHuggingPriority(.required,for:.horizontal)
        return button
    }
    func updateNSView(_ button:NSButton,context:Context) { context.coordinator.content=self }
    @MainActor final class Coordinator:NSObject {
        var content:SenderMenuButton?
        private var actions:[() -> Void]=[]
        @objc func open(_ sender:NSButton) {
            guard let content else { return }
            actions=[]
            let menu=NSMenu(); menu.autoenablesItems=false
            for (index,group) in content.groups.enumerated() {
                if index > 0 { menu.addItem(.separator()) }
                menu.addItem(header(group.title,group.symbol))
                for (title,value) in [(String(localized:"Let Mail Dot Decide"),nil),(String(localized:"Always"),MailTriage.Rule.always),(String(localized:"Never"),MailTriage.Rule.never)] {
                    let item=self.item(title) { group.set(value) }
                    item.state = group.rule == value ? .on : .off
                    menu.addItem(item)
                }
            }
            if let note=content.note {
                menu.addItem(.separator())
                let item=self.item(String(localized:"Drafting Notes for This Sender…"),note.edit)
                // Menu item images do not show in this menu (owner report, 14 November 2026), so the icon is part of the title.
                item.attributedTitle=Self.titled(item.title,symbol:note.exists ? "note.text" : "note.text.badge.plus")
                menu.addItem(item)
                // The menu does not count the icon drawn in this title when it sets its width (owner report, 14 November
                // 2026: the item read "Drafting Notes for This"), so it is made wide enough for the whole title, beside
                // the checkmark column and the menu's margins.
                menu.minimumWidth=max(menu.minimumWidth,ceil(item.attributedTitle?.size().width ?? 0)+SenderMenuButton.titleMargins)
            }
            if !content.extras.isEmpty {
                menu.addItem(.separator())
                for extra in content.extras { menu.addItem(self.item(extra.title,extra.run)) }
            }
            if let footer=content.footer {
                menu.addItem(.separator())
                let item=NSMenuItem(title:footer,action:nil,keyEquivalent:""); item.isEnabled=false
                menu.addItem(item)
            }
            menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.height+4),in:sender)
        }
        private func item(_ title:String,_ action:@escaping () -> Void) -> NSMenuItem {
            actions.append(action)
            let item=NSMenuItem(title:title,action:#selector(run(_:)),keyEquivalent:"")
            item.target=self; item.tag=actions.count-1
            return item
        }
        static func titled(_ title:String,symbol:String) -> NSAttributedString {
            let font=NSFont.menuFont(ofSize:0)
            let text=NSMutableAttributedString()
            if let image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:font.pointSize,weight:.regular).applying(.init(paletteColors:[.labelColor]))) {
                let attachment=NSTextAttachment(); attachment.image=image
                attachment.bounds=NSRect(x:0,y:(font.capHeight-image.size.height)/2,width:image.size.width,height:image.size.height)
                text.append(NSAttributedString(attachment:attachment)); text.append(NSAttributedString(string:"  "))
            }
            text.append(NSAttributedString(string:title))
            text.addAttribute(.font,value:font,range:NSRange(location:0,length:text.length))
            return text
        }
        @objc private func run(_ item:NSMenuItem) { if actions.indices.contains(item.tag) { actions[item.tag]() } }
        /// A group's title in the menu's own text colour, semibold, after its icon; not a choice.
        private func header(_ title:String,_ symbol:String) -> NSMenuItem {
            let item=NSMenuItem(title:title,action:nil,keyEquivalent:"")
            let view=NSHostingView(rootView:SenderMenuHeader(title:title,symbol:symbol))
            view.frame=NSRect(origin:.zero,size:view.fittingSize)
            view.autoresizingMask=[.width]
            item.view=view; item.isEnabled=false
            return item
        }
    }
}
struct SenderMenuHeader:View {
    let title:String
    let symbol:String
    var body:some View {
        HStack(spacing:6) {
            Image(systemName:symbol).foregroundStyle(Color.accentColor).frame(width:16)
            Text(title).fontWeight(.semibold).foregroundStyle(.primary)
        }
        .font(.system(size:NSFont.systemFontSize))
        .padding(.leading,SenderMenuHeader.leading).padding(.trailing,14).padding(.top,4).padding(.bottom,2)
        .frame(maxWidth:.infinity,alignment:.leading)
    }
    static let leading:CGFloat=9
}

/// Settings, Drafting Rules: the owner's notes on writing to particular people, set from a message's Mail Dot window
/// and edited, added to or deleted here too (owner request, 14 November 2026).
struct SenderNotesList:View {
    @State private var people:[(address:String,name:String?)]=[]
    var body:some View {
        Group {
            if !people.isEmpty {
                Text("NOTES FOR PARTICULAR PEOPLE").font(.caption.weight(.semibold)).foregroundStyle(MailDotStyle.supporting).kerning(0.5).padding(.top,10)
                ForEach(people,id:\.address) { person in
                    VStack(alignment:.leading,spacing:6) {
                        HStack(spacing:6) {
                            Image(systemName:"person.crop.circle").foregroundStyle(MailDotStyle.supporting)
                            Text(person.name ?? person.address).fontWeight(.semibold).lineLimit(1)
                            if person.name != nil { Text(person.address).font(.caption).foregroundStyle(MailDotStyle.supporting).lineLimit(1) }
                        }
                        SenderNotesEditor(address:person.address,name:person.name,polishOnSave:true)
                    }
                    .padding(.top,4)
                }
            }
        }
        .task { while !Task.isCancelled { await reload(); try? await Task.sleep(for:.seconds(3)) } }
    }
    private func reload() async {
        let fresh=await Task.detached { ((try? MailSettingsStore.shared().read())?.senderNoteList ?? []).map{ ($0.address,$0.note.name) } }.value
        if fresh.map(\.0) != people.map(\.address) || fresh.map(\.1) != people.map(\.name) { people=fresh.map{ (address:$0.0,name:$0.1) } }
    }
}

/// One person's drafting notes: each a row to edit or delete, and a box to add one (owner request, 14 November 2026).
/// A note added or changed waits for Dot's polish, shown by a spinner; the owner's words are used meanwhile. In the
/// Mail Dot window the notes go to Dot when the owner presses Done; in Settings, as each is saved.
struct SenderNotesEditor:View {
    let address:String
    let name:String?
    var polishOnSave=false
    /// For rendering previews: notes given instead of read from the settings.
    var preview:[SenderNote.Item]?=nil
    @State private var items:[SenderNote.Item]=[]
    @State private var editing:String?
    @State private var text=""
    @State private var newText=""
    @State private var failure:String?
    @FocusState private var adding:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            ForEach(items) { item in
                HStack(alignment:.top,spacing:8) {
                    if editing == item.id {
                        TextField("Note",text:$text,axis:.vertical).ruleCounter(text,limit:SenderNote.textLimit).lineLimit(1...5).textFieldStyle(.roundedBorder).onSubmit { save(item.id) }
                        Button("Save") { save(item.id) }.controlSize(.small).disabled(blank(text))
                        Button("Cancel") { editing=nil; failure=nil }.controlSize(.small)
                    } else {
                        Text(item.text).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                        Spacer(minLength:6)
                        if item.polishing == true { ProgressView().controlSize(.mini).help("Dot is polishing this note") }
                        Button { editing=item.id; text=item.text } label: { Image(systemName:"pencil") }
                            .buttonStyle(.borderless).help("Edit this note")
                        Button { change { $0.removeSenderNote(item.id,for:address) } } label: { Image(systemName:"trash") }
                            .buttonStyle(.borderless).help("Delete this note")
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius:8).fill(Color.primary.opacity(0.04)))
            }
            HStack(alignment:.bottom,spacing:8) {
                TextField("Add a note",text:$newText,axis:.vertical).ruleCounter(newText,limit:SenderNote.textLimit).lineLimit(1...4).textFieldStyle(.roundedBorder).focused($adding).onSubmit { add() }
                Group {
                    if blank(newText) { Button { adding=true } label: { Label("Add",systemImage:"plus") }.buttonStyle(.bordered) }
                    else { Button { add() } label: { Label("Add",systemImage:"plus") }.buttonStyle(.borderedProminent) }
                }
                .disabled(items.count >= SenderNote.perPerson)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(MailDotStyle.dangerText) }
        }
        .task {
            if let preview { items=preview; return }
            while !Task.isCancelled { await reload(); try? await Task.sleep(for:.seconds(2)) }
        }
    }
    private func blank(_ value:String) -> Bool { value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
    private func add() {
        let value=newText
        guard !blank(value) else { return }
        change { try $0.addSenderNote(value,for:address,name:name) }
        if failure == nil { newText="" }
    }
    private func save(_ id:String) {
        let value=text
        guard !blank(value) else { return }
        change { try $0.updateSenderNote(id,text:value,for:address) }
        if failure == nil { editing=nil }
    }
    private func change(_ body:(inout MailSettings) throws -> Void) {
        do {
            try MailSettingsStore.shared().transaction { try body(&$0) }
            failure=nil
            if polishOnSave,let refusal=DotCallCommands.polishNotes(for:address) { failure=refusal }
            Task { await reload() }
        } catch { failure=error.localizedDescription }
    }
    private func reload() async {
        let key=address
        let fresh=await Task.detached { (try? MailSettingsStore.shared().read())?.senderNote(for:key)?.items ?? [] }.value
        if fresh != items { items=fresh }
    }
}
