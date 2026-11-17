import SwiftUI
import AppKit
import Carbon.HIToolbox
import notify
import OSLog
import BridgeCore

/// Ask Dot's floating bar (owner request, 14 November 2026). MailKit gives an extension no place in Mail's search
/// field or main toolbar, so the bar is a small panel of the background app, shown over Mail by the Mail Dot
/// window's Ask Dot button or by Shift-Option-Command-F while Mail is in front. The question goes to Dot, which
/// does the searching; the answer comes back with a citation for every statement.
@MainActor final class AskDotController {
    static let shared=AskDotController()
    /// The name the Mail Dot window posts to have the bar shown at once.
    nonisolated static let showNotification="org.jgkarlin.MailBridge.askbar.show"
    private static let log=Logger(subsystem:"org.jgkarlin.MailBridge",category:"AskDot")
    private var panel:AskDotPanel?
    private var hotKey:EventHotKeyRef?
    private var handlerInstalled=false
    private var notifyToken:Int32=0
    private var handledRequest=Date()
    private var started=false
    let session=AskDotSession()

    func start() {
        guard !started else { return }
        started=true
        var token:Int32=0
        notify_register_dispatch(Self.showNotification,&token,DispatchQueue.main) { _ in
            Task { @MainActor in AskDotController.shared.show() }
        }
        notifyToken=token
        let center=NSWorkspace.shared.notificationCenter
        center.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { _ in
            Task { @MainActor in AskDotController.shared.updateHotKey() }
        }
        updateHotKey()
    }

    // MARK: The shortcut

    /// Shift-Option-Command-F belongs to Mail Dot only while Mail, or the bar itself, is in front: other apps keep the
    /// keys. Control-Option-F, the first choice, is taken by macOS's window tiling (owner report, 14 November 2026).
    private func updateHotKey() {
        let front=NSWorkspace.shared.frontmostApplication
        let wanted=front?.bundleIdentifier == "com.apple.mail" || front?.processIdentifier == ProcessInfo.processInfo.processIdentifier || panel?.isVisible == true
        if wanted,hotKey == nil {
            if !handlerInstalled {
                var kind=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
                InstallEventHandler(GetApplicationEventTarget(),{ _,_,_ in
                    Task { @MainActor in AskDotController.shared.toggle() }
                    return noErr
                },1,&kind,nil,nil)
                handlerInstalled=true
            }
            var reference:EventHotKeyRef?
            let id=EventHotKeyID(signature:OSType(0x4D444F54),id:1) // 'MDOT'
            let status=RegisterEventHotKey(UInt32(kVK_ANSI_F),UInt32(shiftKey|optionKey|cmdKey),id,GetApplicationEventTarget(),0,&reference)
            if status == noErr { hotKey=reference } else { Self.log.error("could not register Shift-Option-Command-F: \(status,privacy:.public)") }
        } else if !wanted,let registered=hotKey {
            UnregisterEventHotKey(registered); hotKey=nil
        }
    }

    // MARK: The panel

    /// The bar is on screen: the background pass over mail waits, so typing in it never stutters.
    var showing:Bool { panel?.isVisible == true }
    func toggle() { if panel?.isVisible == true { hide() } else { show() } }
    func show() {
        let panel=self.panel ?? makePanel()
        self.panel=panel
        // Each showing starts clean (owner request, 14 November 2026): earlier questions are in History.
        if !panel.isVisible {
            session.begin()
            // Where the owner last put it, if that is still on a screen; otherwise over Mail (owner request, 14
            // November 2026: the bar could not be moved, and every showing put it back).
            if !restorePosition(panel) { place(panel) }
        }
        panel.makeKeyAndOrderFront(nil)
        updateHotKey()
    }
    func hide() { panel?.orderOut(nil); session.visible=false; updateHotKey() }
    private func makePanel() -> AskDotPanel {
        // Borderless, with its own rounded corners and shadow: a title bar added a band of empty space (owner review).
        let panel=AskDotPanel(contentRect:NSRect(x:0,y:0,width:AskDotView.width+2*AskDotView.shadowMargin,height:140),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        // The card draws its own deeper shadow inside a clear margin, so the window's own is off.
        panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=false; panel.isMovableByWindowBackground=true
        // Above every ordinary and floating window, and on every Space, so that it cannot get lost behind another
        // window (owner request, 14 November 2026: "The Ask Dot window keeps getting lost").
        panel.isFloatingPanel=true; panel.level = .statusBar; panel.hidesOnDeactivate=false; panel.isReleasedWhenClosed=false
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.title=String(localized:"Ask Dot")
        panel.onCancel={ [weak self] in self?.hide() }
        // The window takes the size of its content: compact when empty, growing with the conversation (owner
        // review, 14 November 2026: it stayed full height and clipped its edges).
        let controller=NSHostingController(rootView:AskDotView(close:{ [weak self] in self?.hide() },session:session))
        controller.sizingOptions=[.preferredContentSize]
        panel.contentViewController=controller
        return panel
    }
    static let positionKey="AskDotTopLeft"
    /// The owner moved the bar: its top left corner is kept for the next showing.
    static func rememberPosition(of window:NSWindow?) {
        guard let window else { return }
        UserDefaults.standard.set([Double(window.frame.minX),Double(window.frame.maxY)],forKey:positionKey)
    }
    /// Puts the bar where the owner left it. False when it was never moved, or that place is no longer on a screen.
    private func restorePosition(_ panel:NSPanel) -> Bool {
        guard let saved=UserDefaults.standard.array(forKey:Self.positionKey) as? [Double],saved.count == 2 else { return false }
        let margin=AskDotView.shadowMargin
        // The card itself, inside the clear margin its shadow is drawn in; its top strip must be reachable.
        let grip=NSRect(x:saved[0]+margin,y:saved[1]-margin-60,width:max(panel.frame.width-2*margin,200),height:60)
        guard NSScreen.screens.contains(where:{ $0.visibleFrame.contains(grip) }) else { return false }
        panel.setFrameTopLeftPoint(NSPoint(x:saved[0],y:saved[1]))
        return true
    }
    /// Over Mail's front window, a little above its middle, as Spotlight sits; else on the main screen.
    private func place(_ panel:NSPanel) {
        var area=NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1280,height:800)
        if let mail=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first,
           let list=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]],
           let window=list.first(where:{ ($0[kCGWindowOwnerPID as String] as? Int32) == mail.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }),
           let bounds=window[kCGWindowBounds as String] as? [String:CGFloat],let x=bounds["X"],let y=bounds["Y"],let w=bounds["Width"],let h=bounds["Height"],
           let primary=NSScreen.screens.first,w > 300,h > 200 {
            // Quartz measures from the top of the primary screen; AppKit from its bottom.
            area=NSRect(x:x,y:primary.frame.height-y-h,width:w,height:h)
        }
        let size=panel.frame.size
        panel.setFrameOrigin(NSPoint(x:area.midX-size.width/2,y:area.midY-size.height/2+min(60,area.height*0.08)))
    }

    // MARK: Sending questions to Dot

    /// Sends waiting questions to Dot, gives up those Dot left unanswered, and shows the bar when the Mail Dot
    /// window asked for it and its notification did not arrive.
    func tick() async {
        guard let store=try? MailTriageStore.shared(),let bridge=try? BridgeStore.shared() else { return }
        _ = try? store.transaction { $0.expireAsks() }
        guard let state=try? store.read() else { return }
        if let asked=state.askBarRequestedAt,asked > handledRequest { handledRequest=asked; show() }
        for question in state.asksDue() {
            do {
                let settings=try MailSettingsStore(bridgeDirectory:bridge.directory).read()
                let available=try MailWorkflowAccount.available(settings:settings,native:NativeMailStore(bridgeDirectory:bridge.directory).read())
                let allowed=Set(available.map(\.id))
                guard !allowed.isEmpty else { throw BridgeFailure("No mail account is connected to Dot yet.") }
                let chosen=question.filters?.accountIDs.map{ $0.filter(allowed.contains) }
                if let chosen,chosen.isEmpty { throw BridgeFailure("That account is not connected to Dot.") }
                let request=try MailWorkflowRequest(action:.ask,accountIDs:chosen ?? allowed.sorted())
                try store.transaction { $0.markAskSent(question.id,requestID:request.id) }
                try MailWorkflowStore(bridgeDirectory:bridge.directory).transaction { try $0.enqueue(request,allowedAccountIDs:allowed) }
            } catch {
                try? store.transaction { $0.failAsk(question.id,error.localizedDescription) }
                Self.log.error("could not send a question to Dot: \(error.localizedDescription,privacy:.public)")
            }
        }
    }
}

/// A panel that takes the keyboard without bringing Mail Dot's app forward, and closes on Escape.
final class AskDotPanel:NSPanel {
    var onCancel:(() -> Void)?
    override var canBecomeKey:Bool { true }
    override func cancelOperation(_ sender:Any?) { onCancel?() }
    /// A press on the bar while another window has the keyboard takes the keyboard first, so that the same press can
    /// move the bar: without this the first drag by the bar's top did nothing (tested 14 November 2026).
    override func sendEvent(_ event:NSEvent) {
        if event.type == .leftMouseDown,!isKeyWindow { makeKey() }
        super.sendEvent(event)
    }
    /// The bar grows downward from its top as answers arrive. Where that would run off the bottom of the screen, it
    /// moves up instead, so all of it stays in view.
    override func setFrame(_ frameRect:NSRect,display flag:Bool) {
        var rect=frameRect
        if rect.size != frame.size,let visible=(screen ?? NSScreen.main)?.visibleFrame {
            let floor=visible.minY-AskDotView.shadowMargin+8
            if rect.minY < floor { rect.origin.y=floor }
        }
        super.setFrame(rect,display:flag)
    }
}

/// When the bar was last shown: only questions asked since then are in the Ask tab.
@MainActor final class AskDotSession:ObservableObject {
    @Published var startedAt=Date()
    @Published var showings=0
    /// Whether the bar is on screen: an answer arriving then has been seen.
    @Published var visible=false
    func begin() { startedAt=Date(); showings += 1; visible=true; answerHeight=nil }
    /// The bar's size as the owner set it (owner requests, 14 November 2026). Its width is kept, no narrower than
    /// the row of filters needs. The answers take the room they need, up to what the screen allows; a height the
    /// owner drags them to holds until the next answer arrives or the bar is shown again. The question box grows
    /// with what is typed, and is never shorter than the height the owner dragged it to.
    static let widths:ClosedRange<CGFloat>=760...1400
    static let heights:ClosedRange<CGFloat>=120...1400
    static let questionHeights:ClosedRange<CGFloat>=22...500
    @Published var width:CGFloat=AskDotView.width
    @Published var answerHeight:CGFloat?
    @Published var questionHeight:CGFloat?
    /// `remembered`: false for rendering previews, which take the standard size.
    init(remembered:Bool=true) {
        guard remembered else { return }
        let defaults=UserDefaults.standard
        if let saved=defaults.object(forKey:"AskDotWidth") as? Double { width=min(max(CGFloat(saved),Self.widths.lowerBound),Self.widths.upperBound) }
        if let saved=defaults.object(forKey:"AskDotQuestionHeight") as? Double { questionHeight=min(max(CGFloat(saved),Self.questionHeights.lowerBound),Self.questionHeights.upperBound) }
    }
    func saveSize() {
        UserDefaults.standard.set(Double(width),forKey:"AskDotWidth")
        if let questionHeight { UserDefaults.standard.set(Double(questionHeight),forKey:"AskDotQuestionHeight") }
    }
}

/// The bar's background: the system's popover material, always active, cut to the card's rounded shape.
private struct AskDotMaterial:NSViewRepresentable {
    let radius:CGFloat
    func makeNSView(context:Context) -> NSVisualEffectView {
        let view=NSVisualEffectView()
        view.material = .popover; view.blendingMode = .behindWindow; view.state = .active
        let side=radius*2+1
        let mask=NSImage(size:NSSize(width:side,height:side),flipped:false) { rect in
            NSColor.black.setFill(); NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius).fill(); return true
        }
        mask.capInsets=NSEdgeInsets(top:radius,left:radius,bottom:radius,right:radius); mask.resizingMode = .stretch
        view.maskImage=mask
        return view
    }
    func updateNSView(_ view:NSVisualEffectView,context:Context) {}
}

/// The bar itself (owner reviews, 14 November 2026): Ask and History tabs with the shortcut and the close button at
/// the right, a row of matching filter pills, the conversation, and the question box at the bottom. It opens clean;
/// earlier questions are under History. A card of the system's popover material with a border and a deep shadow,
/// so it stands out from what is behind it. Even 20-point margins; the window fits its content.
struct AskDotView:View {
    static let width:CGFloat=760
    /// The clear margin around the card, in which its shadow is drawn.
    static let shadowMargin:CGFloat=34
    enum Tab:Hashable { case ask,history }
    /// The answers' tallest before they scroll: what the screen leaves once the rest of the bar is counted, so that
    /// an answer shows whole wherever it can (owner request, 14 November 2026: "When results come in, it needs to be
    /// taller to display them").
    static var conversationLimit:CGFloat { max(300,(NSScreen.main?.visibleFrame.height ?? 900)-330) }
    let close:() -> Void
    @ObservedObject var session:AskDotSession
    /// For rendering previews: questions, tab and accounts given instead of read from the stores.
    var fixedQuestions:[AskDot.Question]?
    var fixedTab:Tab?
    @State private var tab=Tab.ask
    @State private var expanded:Set<String>=[]
    @State private var confirmingClear=false
    @State private var historyHeight:CGFloat=0
    @State private var text=""
    @State private var accounts:[MailDotAccountRow]=[]
    /// The accounts searched; empty means all of them.
    @State private var selectedAccounts:Set<String>=[]
    @State private var period=AskDot.Period.anyTime
    @State private var customFrom=Calendar.current.date(byAdding:.month,value:-1,to:.now) ?? .now
    @State private var customTo=Date()
    @State private var direction=AskDot.Direction.both
    @State private var person=""
    @State private var suggestions:[(name:String?,address:String)]=[]
    @State private var picked:String?
    @State private var attachmentsOnly=false
    @State private var questions:[AskDot.Question]=[]
    @State private var note:String?
    @State private var conversationHeight:CGFloat=0
    @State private var hovered:String?
    @FocusState private var typing:Bool
    /// While the bar is being moved or sized: where the pointer and the bar were when it began.
    @State private var moveStart:(mouse:NSPoint,origin:NSPoint)?
    @State private var sizeStart:(mouse:NSPoint,width:CGFloat,height:CGFloat)?

    private var canSend:Bool { !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && text.count <= AskDot.textLimit }
    private var filtered:Bool { !selectedAccounts.isEmpty || period != .anyTime || direction != .both || !person.trimmingCharacters(in:.whitespaces).isEmpty || attachmentsOnly }
    private var accountName:String {
        let chosen=accounts.filter{ selectedAccounts.contains($0.id) }
        if chosen.isEmpty { return String(localized:"All accounts") }
        return chosen.count == 1 ? chosen[0].name : String(localized:"\(chosen.count) accounts")
    }
    /// With all accounts searched, choosing one searches it alone; after that each choice adds or removes one.
    private func toggleAccount(_ id:String) {
        if selectedAccounts.isEmpty { selectedAccounts=[id]; return }
        if selectedAccounts.contains(id) { selectedAccounts.remove(id) } else { selectedAccounts.insert(id) }
        if selectedAccounts.count == accounts.count { selectedAccounts=[] }
    }
    /// Whether History holds an answer the owner has not seen: one that arrived while the bar was closed.
    private var unseen:Bool { let shown=Set(current.map(\.id)); return questions.contains{ $0.unread == true && !shown.contains($0.id) } }
    /// Answers on screen are read: those of this showing in the Ask tab, and those opened in History.
    private func markRead(_ fresh:[AskDot.Question]) {
        guard fixedQuestions == nil,session.visible else { return }
        let onScreen=tab == .ask ? Set(fresh.filter{ $0.askedAt >= session.startedAt }.map(\.id)) : expanded
        let ids=Set(fresh.filter{ $0.unread == true && onScreen.contains($0.id) }.map(\.id))
        guard !ids.isEmpty else { return }
        Task.detached { try? MailTriageStore.shared().transaction { $0.markAsksRead(ids) } }
    }
    /// The questions of this showing of the bar; History has them all.
    private var current:[AskDot.Question] { fixedQuestions != nil ? questions : questions.filter{ $0.askedAt >= session.startedAt } }

    var body:some View {
        VStack(spacing:0) {
            // The bar is moved by its upper part and by the margins of the question box, wherever there is no
            // control (owner request, 14 November 2026); the answers are left alone, so their text can be selected.
            header.padding(.horizontal,20).padding(.top,14).padding(.bottom,10).contentShape(Rectangle()).gesture(move)
            if tab == .ask {
                top.padding(.horizontal,20).padding(.bottom,12).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()).gesture(move)
                if !current.isEmpty {
                    Divider()
                    conversation
                }
                Divider()
                input.padding(20).contentShape(Rectangle()).gesture(move)
            } else {
                Divider()
                history
            }
        }
        .frame(width:session.width)
        .fixedSize(horizontal:false,vertical:true)
        .background(AskDotMaterial(radius:14))
        .clipShape(RoundedRectangle(cornerRadius:14,style:.continuous))
        .overlay(RoundedRectangle(cornerRadius:14,style:.continuous).strokeBorder(Color.primary.opacity(0.22),lineWidth:1))
        // Sized like a window, from its right edge, its bottom edge and the corner between them.
        .overlay(alignment:.trailing) { sizer(width:true,height:false).frame(width:7).padding(.vertical,14) }
        .overlay(alignment:.bottom) { if tab == .ask || showsAnswers { sizer(width:false,height:true).frame(height:7).padding(.horizontal,14) } }
        .overlay(alignment:.bottomTrailing) { sizer(width:true,height:tab == .ask || showsAnswers).frame(width:14,height:14) }
        .shadow(color:.black.opacity(0.34),radius:22,x:0,y:12)
        .padding(Self.shadowMargin)
        .tint(MailDotStyle.tint)
        .confirmationDialog("Clear all past questions?",isPresented:$confirmingClear) {
            Button("Clear History",role:.destructive) { clearHistory() }
        }
        .onChange(of:session.showings) { _,_ in tab = .ask; text=""; note=nil; expanded=[]; typing=true }
        .task {
            if let fixedTab { tab=fixedTab }
            typing=true
            if fixedQuestions == nil { accounts=await MailDotAccountRow.load().filter{$0.mailDot && $0.connected} }
            while !Task.isCancelled { await reload(); try? await Task.sleep(for:.seconds(1.5)) }
        }
    }

    // MARK: Moving and sizing

    /// Whether the bar is showing answers now: only then does it have a height to change.
    private var showsAnswers:Bool { tab == .ask ? !current.isEmpty : !questions.isEmpty }
    /// The height of the answers: what the owner dragged them to, or else what they need up to what the screen allows.
    private func answersHeight(_ content:CGFloat) -> CGFloat { session.answerHeight ?? min(max(content,60),Self.conversationLimit) }
    private var barWindow:NSWindow? { NSApp.windows.first{ $0 is AskDotPanel } }
    /// Moves the bar with the pointer. Measured on the screen, since the bar itself is what moves.
    private var move:some Gesture {
        DragGesture(minimumDistance:3,coordinateSpace:.global)
            .onChanged { _ in
                guard let window=barWindow else { return }
                let mouse=NSEvent.mouseLocation
                let start=moveStart ?? (mouse,window.frame.origin)
                if moveStart == nil { moveStart=start }
                window.setFrameOrigin(NSPoint(x:start.origin.x+mouse.x-start.mouse.x,y:start.origin.y+mouse.y-start.mouse.y))
            }
            .onEnded { _ in moveStart=nil; AskDotController.rememberPosition(of:barWindow) }
    }
    /// An edge or corner the bar is sized by: nothing is drawn; the pointer shows what it does.
    private func sizer(width:Bool,height:Bool) -> some View {
        Color.clear.contentShape(Rectangle())
            .onHover { inside in
                guard sizeStart == nil else { return }
                if inside { (width && height ? Self.cornerCursor : width ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set() } else { NSCursor.arrow.set() }
            }
            .gesture(DragGesture(minimumDistance:1,coordinateSpace:.global)
                .onChanged { _ in
                    let mouse=NSEvent.mouseLocation
                    // The bottom edge makes the answers taller while there are any; before that, the question box.
                    let start=sizeStart ?? (mouse,session.width,showsAnswers ? answersHeight(tab == .ask ? conversationHeight : historyHeight) : (session.questionHeight ?? 22))
                    if sizeStart == nil { sizeStart=start }
                    if width { session.width=min(max(start.width+mouse.x-start.mouse.x,AskDotSession.widths.lowerBound),AskDotSession.widths.upperBound) }
                    // The screen is measured upward, so a pointer moving down the screen makes the bar taller.
                    let tall=start.height+start.mouse.y-mouse.y
                    if height,showsAnswers { session.answerHeight=min(max(tall,AskDotSession.heights.lowerBound),min(AskDotSession.heights.upperBound,Self.conversationLimit)) }
                    else if height { session.questionHeight=min(max(tall,AskDotSession.questionHeights.lowerBound),AskDotSession.questionHeights.upperBound) }
                }
                .onEnded { _ in sizeStart=nil; NSCursor.arrow.set(); session.saveSize(); AskDotController.rememberPosition(of:barWindow) })
            .accessibilityHidden(true)
    }
    private static var cornerCursor:NSCursor {
        if #available(macOS 15.0,*) { return NSCursor.frameResize(position:.bottomRight,directions:.all) }
        return NSCursor.crosshair
    }

    // MARK: Filters

    /// The tabs, with the shortcut and the close button at the right.
    private var header:some View {
        HStack(spacing:8) {
            Picker("",selection:$tab) {
                Text("Ask").tag(Tab.ask)
                // A dot after History while it holds an answer not yet seen (release review, 14 November 2026: an answer
                // that arrived after the bar was closed sat in History with no sign).
                (unseen ? Text("History")+Text(verbatim:"  ●").foregroundStyle(MailDotStyle.linkText) : Text("History")).tag(Tab.history)
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer(minLength:8)
            Text(verbatim:"⇧⌥⌘F").font(.caption).foregroundStyle(MailDotStyle.supporting).fixedSize().help("Shows or hides this bar while Mail is in front")
            Button { close() } label: { Image(systemName:"xmark.circle.fill").font(.title3).foregroundStyle(MailDotStyle.tint) }
                .buttonStyle(.plain).help("Close").accessibilityLabel("Close").keyboardShortcut(.cancelAction)
        }
    }
    private var top:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:8) {
                Menu {
                    // With all accounts searched, each account is checked too (owner request, 14 November 2026).
                    choice(String(localized:"All accounts"),selectedAccounts.isEmpty) { selectedAccounts=[] }
                    if !accounts.isEmpty { Divider() }
                    ForEach(accounts) { account in choice(account.name,selectedAccounts.isEmpty || selectedAccounts.contains(account.id)) { toggleAccount(account.id) } }
                } label: { pillLabel(accountName,symbol:"tray",active:!selectedAccounts.isEmpty) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusable(false)
                Menu {
                    ForEach(AskDot.Period.allCases,id:\.self) { value in choice(periodName(value),period == value) { period=value } }
                } label: { pillLabel(periodName(period),symbol:"calendar",active:period != .anyTime) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusable(false)
                Menu {
                    choice(String(localized:"Sent and received"),direction == .both) { direction = .both }
                    choice(String(localized:"Received only"),direction == .received) { direction = .received }
                    choice(String(localized:"Sent only"),direction == .sent) { direction = .sent }
                } label: { pillLabel(directionName,symbol:"arrow.left.arrow.right",active:direction != .both) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusable(false)
                HStack(spacing:5) {
                    Image(systemName:"person").font(.caption).foregroundStyle(person.isEmpty ? MailDotStyle.supporting : MailDotStyle.tint)
                    TextField("From or to",text:$person).textFieldStyle(.plain).font(.callout).frame(minWidth:70,maxWidth:130)
                        .onChange(of:person) { _,value in Task { await suggest(value) } }
                }
                .padding(.horizontal,10).frame(height:26)
                .background(Capsule().fill(person.isEmpty ? Color.primary.opacity(0.06) : MailDotStyle.tint.opacity(0.14)))
                .popover(isPresented:Binding(get:{ !suggestions.isEmpty },set:{ if !$0 { suggestions=[] } }),arrowEdge:.bottom) { suggestionList }
                Button { attachmentsOnly.toggle() } label: { pillLabel(String(localized:"Attachments"),symbol:"paperclip",active:attachmentsOnly,showsChevron:false) }
                    .buttonStyle(.plain).fixedSize().focusable(false).accessibilityAddTraits(attachmentsOnly ? .isSelected : [])
                if filtered { Button("Reset") { resetFilters() }.buttonStyle(.link).font(.callout).fixedSize() }
                Spacer(minLength:0)
            }
            if period == .custom {
                HStack(spacing:12) {
                    DatePicker("From",selection:$customFrom,in:...customTo,displayedComponents:.date)
                    DatePicker("To",selection:$customTo,in:customFrom...Date(),displayedComponents:.date)
                }.controlSize(.small).fixedSize()
            }
        }
    }
    private var directionName:String {
        switch direction {
        case .both: String(localized:"Sent and received")
        case .received: String(localized:"Received only")
        case .sent: String(localized:"Sent only")
        }
    }
    /// One filter as a rounded pill: the same height, type and padding for all; tinted when it narrows the search.
    private func pillLabel(_ title:String,symbol:String,active:Bool,showsChevron:Bool=true) -> some View {
        HStack(spacing:5) {
            Image(systemName:symbol).font(.caption)
            Text(title).font(.callout).lineLimit(1)
            if showsChevron { Image(systemName:"chevron.down").font(.system(size:8,weight:.semibold)).foregroundStyle(MailDotStyle.supporting) }
        }
        .foregroundStyle(active ? AnyShapeStyle(MailDotStyle.linkText) : AnyShapeStyle(.primary))
        .padding(.horizontal,10).frame(height:26)
        .background(Capsule().fill(active ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(Color.primary.opacity(0.06))))
        .contentShape(Capsule())
    }
    /// A menu item carrying the menu's own checkmark when chosen: an icon in its label does not show in these menus
    /// (owner report, 14 November 2026: nothing looked selected).
    private func choice(_ title:String,_ chosen:Bool,_ action:@escaping () -> Void) -> some View {
        Toggle(title,isOn:Binding(get:{ chosen },set:{ _ in action() }))
    }
    private var suggestionList:some View {
        VStack(alignment:.leading,spacing:0) {
            ForEach(suggestions,id:\.address) { item in
                Button {
                    picked=item.name.map{"\($0) <\(item.address)>"} ?? item.address
                    person=picked ?? item.address; suggestions=[]
                } label: {
                    HStack(spacing:6) {
                        Text(item.name ?? item.address).lineLimit(1)
                        if item.name != nil { Text(item.address).font(.caption).foregroundStyle(MailDotStyle.supporting).lineLimit(1) }
                        Spacer(minLength:0)
                    }.padding(.horizontal,10).padding(.vertical,5).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.frame(width:280).padding(.vertical,4)
    }
    private func resetFilters() { selectedAccounts=[]; period = .anyTime; direction = .both; person=""; attachmentsOnly=false; suggestions=[] }
    private func periodName(_ period:AskDot.Period) -> String {
        switch period {
        case .anyTime: String(localized:"Any time")
        case .today: String(localized:"Today")
        case .yesterday: String(localized:"Yesterday")
        case .last7Days: String(localized:"Last 7 days")
        case .last30Days: String(localized:"Last 30 days")
        case .last3Months: String(localized:"Last 3 months")
        case .last12Months: String(localized:"Last 12 months")
        case .thisYear: String(localized:"This year")
        case .lastYear: String(localized:"Last year")
        case .custom: String(localized:"Custom range…")
        }
    }
    /// What narrowed a question, under it; the account is left out, as it is plain from the answer's sources.
    private func filterWords(_ filters:AskDot.Filters) -> String? {
        var words:[String]=[]
        if let person=filters.person,!person.isEmpty { words.append(String(localized:"From or to \(person)")) }
        if filters.hasAttachments == true { words.append(String(localized:"Has attachments")) }
        if filters.period != .anyTime {
            if filters.period == .custom,let range=filters.range() {
                words.append(String(localized:"\(range.from.formatted(date:.abbreviated,time:.omitted)) to \((filters.customTo ?? range.to).formatted(date:.abbreviated,time:.omitted))"))
            } else { words.append(periodName(filters.period)) }
        }
        if filters.direction == .received { words.append(String(localized:"Received only")) }
        if filters.direction == .sent { words.append(String(localized:"Sent only")) }
        return words.isEmpty ? nil : words.joined(separator:" · ")
    }

    // MARK: The conversation

    private var conversation:some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    ForEach(current) { question in exchange(question).id(question.id) }
                }
                .padding(.horizontal,20).padding(.vertical,16).frame(maxWidth:.infinity,alignment:.leading)
                .background(GeometryReader { geometry in Color.clear.preference(key:ConversationHeight.self,value:geometry.size.height) })
            }
            .frame(height:answersHeight(conversationHeight))
            .onPreferenceChange(ConversationHeight.self) { conversationHeight=$0 }
            .onChange(of:current.last?.id) { _,id in if let id { withAnimation { proxy.scrollTo(id,anchor:.bottom) } } }
            .onAppear { if let id=current.last?.id { proxy.scrollTo(id,anchor:.bottom) } }
        }
    }
    @ViewBuilder private func exchange(_ question:AskDot.Question) -> some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(alignment:.firstTextBaseline,spacing:6) {
                Text(question.text).font(.headline).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:6)
                // Removing a question is offered only under the pointer, so it does not compete with Close.
                Button { removeQuestion(question) } label: { Image(systemName:"trash").font(.caption) }
                    .buttonStyle(.borderless).foregroundStyle(MailDotStyle.supporting).help("Remove this question").accessibilityLabel("Remove this question")
                    .opacity(hovered == question.id ? 1 : 0)
            }
            if let words=question.filters.flatMap(filterWords) { Text(words).font(.caption).foregroundStyle(MailDotStyle.supporting) }
            answerBody(question)
        }
        .contentShape(Rectangle())
        .onHover { inside in hovered=inside ? question.id : (hovered == question.id ? nil : hovered) }
    }
    /// Dot's answer to one question, or where it stands.
    @ViewBuilder private func answerBody(_ question:AskDot.Question) -> some View {
        switch question.state {
            case .waiting,.asked:
                HStack(spacing:8) { ProgressView().controlSize(.small); Text("Dot is searching your mail…").foregroundStyle(MailDotStyle.supporting) }
            case .failed:
                Label(String(localized:"Dot could not answer: \(question.failure ?? "")"),systemImage:"exclamationmark.triangle").foregroundStyle(MailDotStyle.warningText).fixedSize(horizontal:false,vertical:true)
                Button("Ask Again") { text=question.text; send() }.controlSize(.small)
            case .answered:
                Text(cited(question)).textSelection(.enabled).lineSpacing(2).fixedSize(horizontal:false,vertical:true)
                    .environment(\.openURL,OpenURLAction { url in
                        if url.scheme == "maildot-cite",let n=Int(url.host ?? ""),let source=question.sources?.first(where:{$0.n == n}) { open(source); return .handled }
                        return .systemAction
                    })
                sources(question)
                searched(question)
        }
    }

    // MARK: History

    /// Every question kept, newest first; each opens to its answer. Clear removes them all.
    private var history:some View {
        let past=Array(questions.reversed())
        return VStack(spacing:0) {
            if past.isEmpty {
                Text("No past questions").foregroundStyle(MailDotStyle.supporting).frame(maxWidth:.infinity).padding(.vertical,34)
            } else {
                HStack {
                    Spacer()
                    Button("Clear") { confirmingClear=true }.controlSize(.small)
                }.padding(.horizontal,20).padding(.top,12)
                ScrollView {
                    VStack(alignment:.leading,spacing:8) {
                        ForEach(past) { question in historyRow(question) }
                    }
                    .padding(.horizontal,20).padding(.vertical,12).frame(maxWidth:.infinity,alignment:.leading)
                    .background(GeometryReader { geometry in Color.clear.preference(key:HistoryHeight.self,value:geometry.size.height) })
                }
                .frame(height:answersHeight(historyHeight))
                .onPreferenceChange(HistoryHeight.self) { historyHeight=$0 }
            }
        }
    }
    private func historyRow(_ question:AskDot.Question) -> some View {
        let open=expanded.contains(question.id)
        return VStack(alignment:.leading,spacing:8) {
            Button { if open { expanded.remove(question.id) } else { expanded.insert(question.id) } } label: {
                HStack(alignment:.firstTextBaseline,spacing:8) {
                    Image(systemName:open ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(MailDotStyle.supporting).frame(width:10)
                    VStack(alignment:.leading,spacing:2) {
                        Text(question.text).fontWeight(.medium).lineLimit(open ? nil : 1).multilineTextAlignment(.leading)
                        Text([question.askedAt.formatted(date:.abbreviated,time:.shortened),question.filters.flatMap(filterWords)].compactMap{$0}.joined(separator:" · "))
                            .font(.caption).foregroundStyle(MailDotStyle.supporting).lineLimit(1)
                    }
                    Spacer(minLength:6)
                    if question.unread == true { Circle().fill(MailDotStyle.tint).frame(width:7,height:7).accessibilityLabel("Not yet read") }
                    if question.state == .failed { Image(systemName:"exclamationmark.triangle").font(.caption).foregroundStyle(MailDotStyle.warningText) }
                    else if question.state != .answered { ProgressView().controlSize(.mini) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open { answerBody(question).padding(.leading,18) }
        }
        .padding(.horizontal,12).padding(.vertical,9)
        .frame(maxWidth:.infinity,alignment:.leading)
        .background(RoundedRectangle(cornerRadius:9).fill(Color.primary.opacity(0.05)))
    }
    private func clearHistory() {
        try? MailTriageStore.shared().transaction { $0.clearAsks() }
        expanded=[]
        Task { await reload() }
    }
    /// The answer with each [n] a small raised number linking to its message, and Dot's "(no source found)" as
    /// a muted phrase.
    private func cited(_ question:AskDot.Question) -> AttributedString {
        let text=question.answer ?? ""
        var result=AttributedString()
        guard let pattern=try? NSRegularExpression(pattern:"\\s?\\[(\\d{1,2})\\]|\\s?\\(no source found\\)",options:.caseInsensitive) else { return AttributedString(text) }
        let whole=text as NSString
        var cursor=0
        for match in pattern.matches(in:text,range:NSRange(location:0,length:whole.length)) {
            result += AttributedString(whole.substring(with:NSRange(location:cursor,length:match.range.location-cursor)))
            if match.range(at:1).location != NSNotFound {
                let number=whole.substring(with:match.range(at:1))
                var marker=AttributedString("\u{2009}\(number)")
                marker.font = .caption2.weight(.semibold)
                marker.baselineOffset=5
                if question.sources?.contains(where:{String($0.n) == number}) == true { marker.link=URL(string:"maildot-cite://\(number)") }
                result += marker
            } else {
                var missing=AttributedString(" "+String(localized:"(not found in your mail)"))
                missing.foregroundColor = .secondary
                missing.font = .callout.italic()
                result += missing
            }
            cursor=match.range.location+match.range.length
        }
        result += AttributedString(whole.substring(from:cursor))
        return result
    }
    /// What Dot searched in each account asked about (Ask Dot review, 15 November 2026): an account it did not
    /// search is shown as such, so "nothing found" is never mistaken for "nothing searched".
    @ViewBuilder private func searched(_ question:AskDot.Question) -> some View {
        if let coverage=question.coverage,!coverage.isEmpty {
            VStack(alignment:.leading,spacing:3) {
                Text("Searched").textCase(.uppercase).font(.caption2.weight(.semibold)).foregroundStyle(MailDotStyle.supporting).kerning(0.5).padding(.top,2)
                ForEach(Array(coverage.enumerated()),id:\.offset) { _,entry in
                    HStack(alignment:.firstTextBaseline,spacing:6) {
                        // A check mark only where Mail Dot saw the search itself or, for an account reached through a
                        // connector, has Dot's word; a claimed search of Mail that Mail Dot did not see is shown as none.
                        let seen=entry.shownAsSearched
                        Image(systemName:seen ? (entry.observed == true ? "checkmark.circle.fill" : "checkmark.circle") : "exclamationmark.circle").font(.caption)
                            .foregroundStyle(seen ? MailDotStyle.supporting : MailDotStyle.warningText).accessibilityHidden(true)
                        Text(verbatim:"\(entry.name ?? entry.account): \(seen ? (entry.detail ?? "") : (entry.searched ? String(localized:"Not searched") : (entry.detail ?? String(localized:"Not searched"))))".trimmingCharacters(in:CharacterSet(charactersIn:": ")))
                            .font(.caption).foregroundStyle(seen ? MailDotStyle.supporting : MailDotStyle.warningText).fixedSize(horizontal:false,vertical:true)
                    }
                }
            }
        }
    }
    @ViewBuilder private func sources(_ question:AskDot.Question) -> some View {
        let list=question.sources ?? []
        if list.isEmpty {
            Text("Dot gave no sources for this answer.").font(.caption).foregroundStyle(MailDotStyle.warningText)
        } else {
            VStack(alignment:.leading,spacing:4) {
                Text("Sources").textCase(.uppercase).font(.caption2.weight(.semibold)).foregroundStyle(MailDotStyle.supporting).kerning(0.5).padding(.top,2)
                ForEach(list) { source in
                    // The whole row opens the message in Mail; Gmail is offered only when Mail on this Mac cannot.
                    Button { open(source) } label: {
                        HStack(alignment:.firstTextBaseline,spacing:8) {
                            Text("\(source.n)").font(.caption.weight(.semibold)).foregroundStyle(MailDotStyle.linkText).frame(minWidth:14,alignment:.trailing)
                            VStack(alignment:.leading,spacing:1) {
                                Text(source.subject ?? String(localized:"(no subject)")).lineLimit(1)
                                Text([source.sender,source.date.flatMap(ThreadDates.short)].compactMap{$0}.joined(separator:" · ")).font(.caption).foregroundStyle(MailDotStyle.supporting).lineLimit(1)
                                // Dot named a message that is not in this account's mail on this Mac.
                                if source.checked == false { Text("Not found in Mail").font(.caption).foregroundStyle(MailDotStyle.warningText).lineLimit(1) }
                            }
                            Spacer(minLength:6)
                            if source.mailURL == nil,let web=source.webAddress {
                                Button("Open in Gmail") { NSWorkspace.shared.open(web) }.buttonStyle(.link).font(.caption)
                            } else if source.mailURL != nil {
                                Image(systemName:"arrow.up.forward.square").font(.caption).foregroundStyle(MailDotStyle.supporting)
                            }
                        }
                        .padding(.horizontal,8).padding(.vertical,6)
                        .background(RoundedRectangle(cornerRadius:7).fill(Color.primary.opacity(0.04)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(source.mailURL == nil && source.webAddress == nil)
                    .help(source.mailURL != nil ? "Open this message in Mail" : "Mail cannot open this one: Dot gave no Message-ID.")
                }
            }
        }
    }
    private func open(_ source:AskDot.Source) {
        if let url=source.mailURL,NSWorkspace.shared.open(url) { note=nil; return }
        if let web=source.webAddress { NSWorkspace.shared.open(web); return }
        note=String(localized:"Mail could not open that message.")
    }
    private func removeQuestion(_ question:AskDot.Question) {
        try? MailTriageStore.shared().transaction { $0.removeAsk(question.id) }
        Task { await reload() }
    }

    // MARK: The question box

    private var input:some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(alignment:.bottom,spacing:10) {
                // Grows with what is typed (owner request, 14 November 2026: "if the user needs to write a long ask, it
                // needs to be taller"), and is at least as tall as the owner dragged it.
                TextField("Ask Dot about your mail",text:$text,axis:.vertical).lineLimit(1...14).textFieldStyle(.plain).font(.body).focused($typing)
                    .onSubmit { send() }
                    .frame(minHeight:session.questionHeight,alignment:.topLeading)
                Button { dictate() } label: { Image(systemName:"mic").font(.body) }
                    .buttonStyle(.plain).foregroundStyle(MailDotStyle.supporting).help("Dictate your question").accessibilityLabel("Dictate")
                Button { send() } label: { Image(systemName:"arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .disabled(!canSend).keyboardShortcut(.defaultAction).help("Ask Dot").accessibilityLabel("Ask Dot")
            }
            .padding(.leading,12).padding(.trailing,8).padding(.vertical,7)
            .background(RoundedRectangle(cornerRadius:10).fill(Color(nsColor:.textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius:10).stroke(Color.primary.opacity(0.14)))
            if let note { Text(note).font(.caption).foregroundStyle(MailDotStyle.supporting) }
        }
    }

    private func send() {
        guard canSend else { return }
        var chosen:AskDot.Filters?
        if filtered {
            var value=AskDot.Filters()
            let chosenAccounts=accounts.filter{ selectedAccounts.contains($0.id) }
            if !chosenAccounts.isEmpty { value.accountIDs=chosenAccounts.flatMap(\.accountIDs); value.accountName=chosenAccounts.map(\.name).joined(separator:", ") }
            value.period=period; value.direction=direction
            let who=person.trimmingCharacters(in:.whitespacesAndNewlines)
            value.person=who.isEmpty ? nil : String(who.prefix(200)); value.hasAttachments=attachmentsOnly ? true : nil
            if period == .custom { value.customFrom=customFrom; value.customTo=customTo }
            chosen=value
        }
        do {
            _ = try MailTriageStore.shared().transaction { try $0.ask(text,filters:chosen) }
            text=""; note=nil
            Task { await AskDotController.shared.tick(); await reload() }
        } catch { note=error.localizedDescription }
    }
    private func suggest(_ text:String) async {
        guard text != picked else { suggestions=[]; return }
        suggestions=await Task.detached { (try? MailTriageStore.shared().read())?.peopleMatching(text) ?? [] }.value
    }
    private func reload() async {
        if let fixedQuestions { if fixedQuestions != questions { questions=fixedQuestions }; return }
        let fresh=await Task.detached { (try? MailTriageStore.shared().read())?.askList ?? [] }.value
        if fresh.map(\.state) != questions.map(\.state) || fresh.map(\.id) != questions.map(\.id) { session.answerHeight=nil }
        if fresh != questions { questions=fresh }
        markRead(fresh)
    }
    /// macOS's own dictation into the box; Mail Dot does not hear the microphone itself.
    private func dictate() {
        typing=true
        NSApp.activate(ignoringOtherApps:true)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.25) {
            if !NSApp.sendAction(Selector(("startDictation:")),to:nil,from:nil) {
                note=String(localized:"Dictation is not available. Turn it on in System Settings, Keyboard, Dictation.")
            }
        }
    }
}

private struct HistoryHeight:PreferenceKey {
    static let defaultValue:CGFloat=0
    static func reduce(value:inout CGFloat,nextValue:() -> CGFloat) { value=max(value,nextValue()) }
}
private struct ConversationHeight:PreferenceKey {
    static let defaultValue:CGFloat=0
    static func reduce(value:inout CGFloat,nextValue:() -> CGFloat) { value=max(value,nextValue()) }
}
