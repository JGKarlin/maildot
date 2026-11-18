import SwiftUI
import BridgeCore

/// What the Connection tab and the Mail Dot window's line show: the background app's findings, Dot's own record of
/// answering, and whether a worker on this Mac is taking requests.
struct ConnectionSnapshot:Equatable {
    var connection:ConnectionState?
    var access=DotAccess()
    var listening=false
    var availability:DotAvailability { DotAvailability(access:access,connection:connection,listening:listening) }
    static func load() async -> ConnectionSnapshot {
        await Task.detached {
            var snapshot=ConnectionSnapshot()
            guard let bridge=try? BridgeStore.shared().directory else { return snapshot }
            snapshot.connection=(try? MailTriageStore(bridgeDirectory:bridge).read())?.connection
            snapshot.access=(try? MailSettingsStore(bridgeDirectory:bridge).read())?.effectiveDotAccess ?? DotAccess()
            snapshot.listening=(try? MailWorkflowStore(bridgeDirectory:bridge).read())?.workerListening() ?? false
            return snapshot
        }.value
    }
}

@MainActor enum ConnectionCommands {
    /// A button pressed in Settings or the window: the background app acts on it.
    static func press(_ request:ConnectionState.Request) throws {
        try MailTriageStore.shared().transaction { state in
            var connection=state.connection ?? ConnectionState()
            connection.request=request
            state.connection=connection
        }
        DotCallCommands.wakeCompanion()
    }
}

/// One line of the Connection list: a mark, what it is, its state, and a button only while something is missing.
struct ConnectionLine:Identifiable {
    enum Mark { case ok,attention,idle }
    enum Action:Equatable { case press(ConnectionState.Request),checkDot }
    let id:String
    let title:String
    let state:String
    let mark:Mark
    var button:(title:String,action:Action)?

    static func lines(_ snapshot:ConnectionSnapshot) -> [ConnectionLine] {
        let accessibility=String(localized:"Accessibility")
        guard let found=snapshot.connection else {
            // The background app has not looked yet.
            return [("mail","Mail"),("accessibility",accessibility),("chatgpt","ChatGPT"),("dot","Dot")].map{ ConnectionLine(id:$0.0,title:$0.1,state:"…",mark:.idle) }
        }
        var lines:[ConnectionLine]=[]
        switch found.mail {
        case .unknown: lines.append(.init(id:"mail",title:"Mail",state:"…",mark:.idle))
        case .allowed: lines.append(.init(id:"mail",title:"Mail",state:String(localized:"Allowed"),mark:.ok))
        case .notAllowed: lines.append(.init(id:"mail",title:"Mail",state:String(localized:"Not allowed"),mark:.attention,button:(String(localized:"Allow…"),.press(.allowMail))))
        }
        lines.append(found.accessibility
            ? .init(id:"accessibility",title:accessibility,state:String(localized:"On"),mark:.ok)
            : .init(id:"accessibility",title:accessibility,state:String(localized:"Off"),mark:.attention,button:(String(localized:"Open Settings…"),.press(.openAccessibility))))
        switch found.chatGPT {
        case .open: lines.append(.init(id:"chatgpt",title:"ChatGPT",state:String(localized:"Open (running)"),mark:.ok))
        // Closed is no fault: Dot works in the cloud. ChatGPT is needed open only for a call with Dot.
        case .closed: lines.append(.init(id:"chatgpt",title:"ChatGPT",state:String(localized:"Closed"),mark:.idle,button:(String(localized:"Open ChatGPT"),.press(.openChatGPT))))
        case .notInstalled: lines.append(.init(id:"chatgpt",title:"ChatGPT",state:String(localized:"Not installed"),mark:.attention))
        }
        lines.append(dot(snapshot,found))
        return lines
    }
    /// What each item is, in one line.
    static func about(_ id:String) -> LocalizedStringKey {
        switch id {
        case "mail": "Lets Mail Dot read the messages you choose and place Dot’s drafts."
        case "accessibility": "Lets Mail Dot write to Dot in ChatGPT and start calls with Dot."
        case "chatgpt": "The app Dot lives in. It needs to be open only for a call with Dot."
        default: "Your ChatGPT assistant, reached through Mail Dot’s private connection."
        }
    }
    private static func dot(_ snapshot:ConnectionSnapshot,_ found:ConnectionState) -> ConnectionLine {
        // Before setup is complete nothing can reach Dot: the line says so and opens setup, rather than showing a
        // check that cannot arrive (second-account test, 18 November 2026).
        if found.setUp == false {
            switch found.setupProgress {
            case .working?: return .init(id:"dot",title:"Dot",state:String(localized:"Setting up…"),mark:.idle,button:(String(localized:"Show Setup"),.press(.openSetup)))
            case .stopped?: return .init(id:"dot",title:"Dot",state:String(localized:"Setup stopped"),mark:.attention,button:(String(localized:"Show Setup"),.press(.openSetup)))
            case nil: return .init(id:"dot",title:"Dot",state:String(localized:"Not set up"),mark:.attention,button:(String(localized:"Set Up…"),.press(.openSetup)))
            }
        }
        if snapshot.availability.isAvailable { return .init(id:"dot",title:"Dot",state:String(localized:"Connected"),mark:.ok) }
        if snapshot.access.checking { return .init(id:"dot",title:"Dot",state:String(localized:"Asking Dot…"),mark:.idle) }
        return .init(id:"dot",title:"Dot",state:String(localized:"Not answering"),mark:.attention,button:(String(localized:"Check Again"),.checkDot))
    }
}

/// The Connection tab of Settings (owner approval of the mock-ups, 14 November 2026): four lines that check
/// themselves, each a state, at most one button, and one faint line saying what the item is.
struct ConnectionList:View {
    /// For rendering previews: findings given instead of read from the stores.
    var fixed:ConnectionSnapshot?
    @State private var snapshot=ConnectionSnapshot()
    @State private var failure:String?
    /// A downloaded update waiting for Mail to quit (owner's OK of the wording, 18 November 2026); shown only then.
    @State private var updateReady:String?
    var body:some View {
        let lines=ConnectionLine.lines(fixed ?? snapshot)
        VStack(alignment:.leading,spacing:12) {
            if updateReady != nil {
                HStack(spacing:8) {
                    Image(systemName:"arrow.down.circle").foregroundStyle(MailDotStyle.tint).accessibilityHidden(true)
                    Text("A Mail Dot update is ready. It installs the next time you quit Mail.").font(.callout).foregroundStyle(MailDotStyle.supporting)
                        .fixedSize(horizontal:false,vertical:true)
                }.padding(.horizontal,10)
            }
            Text("CONNECTION").font(.caption.weight(.semibold)).foregroundStyle(MailDotStyle.supporting).kerning(0.5).padding(.horizontal,10)
            VStack(spacing:0) {
                ForEach(Array(lines.enumerated()),id:\.element.id) { index,line in
                    HStack(spacing:10) {
                        Image(systemName:line.mark == .ok ? "checkmark.circle.fill" : line.mark == .attention ? "exclamationmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(line.mark == .ok ? Color.green : line.mark == .attention ? MailDotStyle.warningText : MailDotStyle.supporting).frame(width:20)
                            .accessibilityHidden(true)
                        // Under each item, one faint line saying what it is (owner's request, 15 November 2026: an
                        // exception he asked for to the rule of labels without captions).
                        VStack(alignment:.leading,spacing:2) {
                            HStack(spacing:10) {
                                Text(verbatim:line.title).fontWeight(.semibold).lineLimit(1)
                                Text(verbatim:line.state).foregroundStyle(MailDotStyle.supporting).lineLimit(1)
                            }
                            Text(ConnectionLine.about(line.id)).font(.caption).foregroundStyle(MailDotStyle.supporting).fixedSize(horizontal:false,vertical:true)
                        }
                        Spacer(minLength:8)
                        if let button=line.button { Button(button.title) { run(button.action) }.controlSize(.small).fixedSize() }
                    }
                    .padding(.horizontal,12).padding(.vertical,8).frame(minHeight:40)
                    .accessibilityElement(children:.combine)
                    if index < lines.count-1 { Divider().padding(.leading,42) }
                }
            }
            .background(RoundedRectangle(cornerRadius:10).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius:10).stroke(Color.primary.opacity(0.08)))
            if let failure { Text(failure).font(.caption).foregroundStyle(MailDotStyle.dangerText) }
        }
        .task {
            guard fixed == nil else { return }
            while !Task.isCancelled {
                let fresh=await ConnectionSnapshot.load()
                if fresh != snapshot { snapshot=fresh }
                let running=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? ""
                let ready=(try? BridgeStore.shared()).flatMap { UpdateStatus.read(bridgeDirectory:$0.directory).waiting(runningVersion:running) }
                if ready != updateReady { updateReady=ready }
                try? await Task.sleep(for:.seconds(2))
            }
        }
    }
    private func run(_ action:ConnectionLine.Action) {
        do {
            switch action {
            case .press(let request): try ConnectionCommands.press(request)
            case .checkDot: try TriageCommands.checkDot()
            }
            failure=nil
        } catch { failure=error.localizedDescription }
        Task { snapshot=await ConnectionSnapshot.load() }
    }
}

/// The one line at the top of the Mail Dot window while Dot cannot take requests (owner approval, 14 November
/// 2026): the reason, and one button where pressing it helps.
struct DotUnavailableLine:View {
    let snapshot:ConnectionSnapshot
    let act:ThreadAct
    static func words(_ snapshot:ConnectionSnapshot,now:Date=Date()) -> String? {
        // Before setup is complete the window says so, with the button that opens setup (second-account test,
        // 18 November 2026): this window is where a new user is, and nothing else in Mail led to setup.
        if snapshot.connection?.setUp == false {
            switch snapshot.connection?.setupProgress {
            case .working?: return String(localized:"Dot is setting up Mail Dot")
            case .stopped?: return String(localized:"Mail Dot’s setup has stopped")
            case nil: return String(localized:"Mail Dot is not set up yet")
            }
        }
        switch snapshot.availability {
        case .available: return nil
        case .notConnected: return String(localized:"Dot is not connected")
        case .notYetAnswered,.silent(since:nil): return String(localized:"Dot has not answered yet")
        case .silent(since:let since?):
            let time=Calendar.current.isDate(since,inSameDayAs:now) ? since.formatted(date:.omitted,time:.shortened) : since.formatted(date:.abbreviated,time:.shortened)
            return String(localized:"Dot has not answered since \(time)")
        }
    }
    private var button:(title:String,action:ConnectionLine.Action)? {
        if snapshot.connection?.setUp == false {
            return (snapshot.connection?.setupProgress == nil ? String(localized:"Set Up…") : String(localized:"Show Setup"),.press(.openSetup))
        }
        return snapshot.availability.isAvailable || snapshot.access.checking ? nil : (String(localized:"Check Again"),.checkDot)
    }
    var body:some View {
        if let words=Self.words(snapshot) {
            HStack(spacing:8) {
                Image(systemName:"exclamationmark.circle").foregroundStyle(MailDotStyle.warningText).accessibilityHidden(true)
                Text(verbatim:words).font(.callout).fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:4)
                if let button {
                    Button(button.title) {
                        act(nil) {
                            switch button.action {
                            case .press(let request): try ConnectionCommands.press(request)
                            case .checkDot: try TriageCommands.checkDot()
                            }
                        }
                    }.controlSize(.small).fixedSize()
                }
            }
            .padding(.horizontal,16).padding(.vertical,8).background(MailDotStyle.warningText.opacity(0.10))
        }
    }
}
