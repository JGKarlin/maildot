import AppKit
import ApplicationServices
import BridgeCore

/// Opens a voice call with Dot. Mail Dot holds no call of its own: the call is the ChatGPT desktop app's
/// call with the owner's dot, started by that app's own "Start call" control on the dot's page. Mail Dot
/// brings up that page if it is not showing, gives the control keyboard focus through Accessibility and
/// presses Space on it, as the owner would from the keyboard. It reads only the labels of ChatGPT's controls, never conversations.
@MainActor public enum DotCallLauncher {
    public static let chatGPTBundleID="com.openai.codex"
    /// ChatGPT's names for its controls in every language it is shown in, read from the ChatGPT app itself
    /// (see ChatGPTLabels). English alone until the app's files have been read.
    private static var labels=ChatGPTLabels.english
    /// Reads the names for this copy of ChatGPT; quick once read, since the result is kept until ChatGPT changes.
    private static func learnLabels(_ location:URL) async {
        labels=await Task.detached(priority:.userInitiated) { ChatGPTCatalog.labels(app:location) }.value
    }
    /// The ChatGPT app's own address for the dots page.
    static let dotsAddress=URL(string:"codex://dots")!

    public enum Outcome:Equatable,Sendable {
        /// Start call was pressed and ChatGPT then showed a call being placed or open.
        case callStarted
        /// A call was already open; nothing was pressed.
        case alreadyOpen
        /// Start call was pressed, but ChatGPT did not show a call within the wait.
        case pressedUnconfirmed
        /// ChatGPT is open in front, but Mail Dot could not start the call; the owner starts it there.
        case openedOnly(reason:String)
        case notInstalled

        public var started:Bool { [.callStarted,.alreadyOpen,.pressedUnconfirmed].contains(self) }
        /// What the owner is told when the call was not, or may not have been, started for them.
        public var explanation:String? {
            switch self {
            case .callStarted,.alreadyOpen: nil
            case .pressedUnconfirmed: "Mail Dot pressed Start call in ChatGPT, but ChatGPT did not show a call. Look at ChatGPT; your request is waiting for Dot."
            case .openedOnly(let reason): "\(reason) ChatGPT is open: press Start call on Dot’s page there, and Dot will take up your request."
            case .notInstalled: "The ChatGPT app is not installed on this Mac, so Mail Dot cannot open a call. Start a call with Dot wherever you use ChatGPT; your request is waiting for it."
            }
        }
    }

    public static func start() async -> Outcome {
        // Never from a run against a synthetic store: a call opens the owner's microphone.
        guard ProcessInfo.processInfo.environment["MAILDOT_PREVIEW_STORE"] == nil else { return .openedOnly(reason:"This is a development run.") }
        guard let location=NSWorkspace.shared.urlForApplication(withBundleIdentifier:chatGPTBundleID) else {
            note("outcome=missing"); return .notInstalled
        }
        await learnLabels(location)
        var launched=false
        if running() == nil {
            launched=true
            let configuration=NSWorkspace.OpenConfiguration()
            configuration.activates=false; configuration.addsToRecentItems=false
            _ = try? await NSWorkspace.shared.openApplication(at:location,configuration:configuration)
            for _ in 0..<40 where running()?.isFinishedLaunching != true { try? await Task.sleep(for:.milliseconds(500)) }
        }
        guard let app=running() else { note("outcome=notRunning launched=\(launched)"); return opened(nil,"ChatGPT did not finish opening.") }
        guard AXIsProcessTrusted() else {
            note("outcome=noAccessibility launched=\(launched)")
            return opened(app,"Mail Dot needs Accessibility access to start the call for you.")
        }
        // ChatGPT must be on screen and in front for any of this; the caller returns the owner afterwards.
        guard await bringForward(app) else {
            note("outcome=notInFront launched=\(launched)")
            return opened(app,"Mail Dot could not bring ChatGPT’s window forward.")
        }
        // The control is on the dot's page. If that page is not showing, ask ChatGPT for it by its own address.
        var route="shown"
        var seen=await look(in:app,waiting:launched ? 12 : 1.5)
        if seen.state == .absent {
            route="dotsPage"
            let configuration=NSWorkspace.OpenConfiguration()
            configuration.activates=false
            _ = try? await NSWorkspace.shared.open([dotsAddress],withApplicationAt:location,configuration:configuration)
            seen=await look(in:app,waiting:15)
        }
        switch seen.state {
        case .inCall:
            note("outcome=alreadyOpen route=\(route) launched=\(launched)")
            return .alreadyOpen
        case .absent:
            note("outcome=noControl route=\(route) launched=\(launched) elements=\(seen.visited)")
            return opened(app,"Mail Dot could not find Dot’s Start call button in ChatGPT.")
        case .canStart:
            guard let control=seen.start,await operate(control,in:app) else {
                note("outcome=pressRefused route=\(route) launched=\(launched)")
                return opened(app,"ChatGPT did not accept the press on Start call.")
            }
            let after=await look(in:app,waiting:10,until:.inCall)
            note("outcome=\(after.state == .inCall ? "started" : "pressedUnconfirmed") route=\(route) launched=\(launched)")
            return after.state == .inCall ? .callStarted : .pressedUnconfirmed
        }
    }

    /// Why a prompt was not entered, in the owner's terms; nil when it was sent.
    public enum SayRefusal:String,Sendable {
        case noField="Mail Dot could not find the Message field on Dot’s page in ChatGPT."
        case draftPresent="You have unsent text in the Message field on Dot’s page, so Mail Dot did not type over it."
        case notEntered="ChatGPT did not accept the text in its Message field."
        case notSent="Mail Dot entered the text in ChatGPT’s Message field but could not send it. It is still there: press Return in ChatGPT."
    }
    /// Enters one message to Dot in the Message field on the dot's page and sends it. Dot's written side
    /// reads it within seconds; the voice in a call does not, so it is sent before a call, not during one. The field's own Accessibility value is set (no typing, so no
    /// input method can alter it), Send becoming available confirms the text landed, and Return to ChatGPT
    /// alone sends it. Unsent text of the owner's is never overwritten.
    public static func say(_ text:String) async -> SayRefusal? {
        guard let location=NSWorkspace.shared.urlForApplication(withBundleIdentifier:chatGPTBundleID) else { return .noField }
        await learnLabels(location)
        if running() == nil {
            let configuration=NSWorkspace.OpenConfiguration()
            configuration.addsToRecentItems=false
            _ = try? await NSWorkspace.shared.openApplication(at:location,configuration:configuration)
            for _ in 0..<40 where running()?.isFinishedLaunching != true { try? await Task.sleep(for:.milliseconds(500)) }
        }
        guard let app=running(),AXIsProcessTrusted() else { return .noField }
        guard await bringForward(app) else { note("say=notInFront"); return .notEntered }
        // The Message field is on the dot's page; ask ChatGPT for that page if it is not showing.
        var found=composer(in:app)
        if found == nil {
            let configuration=NSWorkspace.OpenConfiguration()
            _ = try? await NSWorkspace.shared.open([dotsAddress],withApplicationAt:location,configuration:configuration)
            for _ in 0..<30 where found == nil { try? await Task.sleep(for:.milliseconds(500)); found=composer(in:app) }
        }
        guard let composer=found else { note("say=noField"); return .noField }
        if composer.sendEnabled { note("say=draftPresent"); return .draftPresent }
        guard AXUIElementSetAttributeValue(composer.field,kAXFocusedAttribute as CFString,kCFBooleanTrue) == .success else { note("say=noFocus"); return .notEntered }
        try? await Task.sleep(for:.milliseconds(250))
        // Observed 11 November 2026: ChatGPT takes a set value, but its Send button follows a few seconds later.
        // The text is not typed as a fallback: typing after a slow set would enter it twice.
        var entered=AXUIElementSetAttributeValue(composer.field,kAXValueAttribute as CFString,text as CFString) == .success
        if entered { entered=await sendAvailable(in:app,is:true,within:8) }
        let method="value"
        guard entered else { note("say=notEntered"); return .notEntered }
        for down in [true,false] { CGEvent(keyboardEventSource:nil,virtualKey:36,keyDown:down)?.postToPid(app.processIdentifier) }
        let sent=await sendAvailable(in:app,is:false,within:4)
        note("say=\(sent ? "sent" : "notSent") method=\(method)")
        return sent ? nil : .notSent
    }
    private static func composer(in app:NSRunningApplication) -> (field:AXUIElement,sendEnabled:Bool)? {
        let root=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root,2)
        var field:AXUIElement?,send:AXUIElement?,visited=0
        func walk(_ element:AXUIElement,_ depth:Int) {
            guard depth <= 60,visited < 12_000 else { return }
            visited += 1
            let role=attribute(element,kAXRoleAttribute) as? String
            let label=(attribute(element,kAXTitleAttribute) as? String).flatMap{$0.isEmpty ? nil : $0} ?? (attribute(element,kAXDescriptionAttribute) as? String)
            // The message field is named in ChatGPT's language; it is the page's one editor, which the web page
            // marks as such whatever the language (seen 18 November 2026 with ChatGPT in Japanese).
            if role == "AXTextArea",label == "Message" || (attribute(element,"AXDOMClassList") as? [String])?.contains("ProseMirror") == true { field=element }
            if role == "AXButton",let label,labels.send.contains(label) { send=element }
            for child in attribute(element,kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child,depth+1) }
        }
        for window in attribute(root,kAXWindowsAttribute) as? [AXUIElement] ?? [] { walk(window,0) }
        guard let field,let send else { return nil }
        return (field,(attribute(send,kAXEnabledAttribute) as? Bool) ?? false)
    }
    private static func sendAvailable(in app:NSRunningApplication,is wanted:Bool,within seconds:Double) async -> Bool {
        let deadline=Date().addingTimeInterval(seconds)
        while true {
            if composer(in:app)?.sendEnabled == wanted { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(for:.milliseconds(250))
        }
    }

    /// Ends the call from Mail Dot's side by pressing ChatGPT's Hang up, if a call is showing.
    @discardableResult public static func hangUp() async -> Bool {
        guard let app=running(),AXIsProcessTrusted() else { return false }
        if let location=app.bundleURL { await learnLabels(location) }
        let found=controls(in:app)
        guard let control=found.elements.first(where:{labels.hangUp.contains($0.label)})?.element else { return false }
        return await operate(control,in:app)
    }

    /// ChatGPT's call controls offer no Accessibility press (observed 11 November 2026: only AXShowMenu and
    /// AXScrollToVisible, and a press reports success while doing nothing). They do answer the keyboard, as
    /// for anyone who tabs to them: Mail Dot gives the control keyboard focus and sends Space to ChatGPT
    /// alone, so the key cannot reach another app.
    private static func operate(_ control:AXUIElement,in app:NSRunningApplication) async -> Bool {
        // ChatGPT must be in front: behind other windows it confirmed the focus and then ignored the key
        // (observed 11 November 2026, 13:56 and 13:59). The caller returns the owner to their app afterwards.
        guard await bringForward(app) else { note("focus step=notInFront"); return false }
        // Space is sent only once the control is seen to hold keyboard focus; otherwise it could act on
        // whatever else in ChatGPT has it.
        let set=AXUIElementSetAttributeValue(control,kAXFocusedAttribute as CFString,kCFBooleanTrue)
        var focused=false
        for _ in 0..<10 where !focused {
            try? await Task.sleep(for:.milliseconds(150))
            focused=(attribute(control,kAXFocusedAttribute) as? Bool) == true
        }
        guard focused,let down=CGEvent(keyboardEventSource:nil,virtualKey:49,keyDown:true),
              let up=CGEvent(keyboardEventSource:nil,virtualKey:49,keyDown:false) else {
            note("focus step=notFocused set=\(set.rawValue)")
            return false
        }
        down.postToPid(app.processIdentifier); up.postToPid(app.processIdentifier)
        return true
    }
    /// Puts ChatGPT's window on screen and in front. A minimized window is restored first: minimized, or
    /// behind other windows, ChatGPT reports the control focused and then ignores the key (observed
    /// 11 November 2026, when the owner had minimized it).
    private static func bringForward(_ app:NSRunningApplication) async -> Bool {
        let root=AXUIElementCreateApplication(app.processIdentifier)
        let windows=attribute(root,kAXWindowsAttribute) as? [AXUIElement] ?? []
        var restored=false
        for window in windows where (attribute(window,kAXMinimizedAttribute) as? Bool) == true {
            restored=AXUIElementSetAttributeValue(window,kAXMinimizedAttribute as CFString,kCFBooleanFalse) == .success || restored
        }
        if app.isHidden { app.unhide() }
        if restored { try? await Task.sleep(for:.milliseconds(700)) }
        if !app.isActive { app.activate() }
        for _ in 0..<30 where !app.isActive { try? await Task.sleep(for:.milliseconds(100)) }
        if let window=windows.first { AXUIElementPerformAction(window,kAXRaiseAction as CFString) }
        // The page wakes a moment after its window returns.
        if app.isActive { try? await Task.sleep(for:.milliseconds(restored ? 1200 : 400)) }
        let stillMinimized=windows.contains{(attribute($0,kAXMinimizedAttribute) as? Bool) == true}
        if restored || stillMinimized || !app.isActive { note("forward restored=\(restored) minimized=\(stillMinimized) active=\(app.isActive)") }
        return app.isActive && !stillMinimized
    }
    private static func running() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier:chatGPTBundleID).first{!$0.isTerminated}
    }
    private static func opened(_ app:NSRunningApplication?,_ reason:String) -> Outcome {
        app?.activate()
        return .openedOnly(reason:reason)
    }

    private struct Sighting { var state:DotCallControl.State; var start:AXUIElement?; var visited:Int }
    /// Looks until the control shows (or, with `until`, until that state shows), or the wait runs out.
    private static func look(in app:NSRunningApplication,waiting seconds:Double,until wanted:DotCallControl.State?=nil) async -> Sighting {
        let deadline=Date().addingTimeInterval(seconds)
        while true {
            let found=controls(in:app)
            let state=DotCallControl.state(labels:found.elements.map(\.label),known:labels)
            let sighting=Sighting(state:state,start:found.elements.first{labels.start.contains($0.label)}?.element,visited:found.visited)
            if wanted.map({$0 == state}) ?? (state != .absent) { return sighting }
            if Date() >= deadline { return sighting }
            try? await Task.sleep(for:.milliseconds(400))
        }
    }
    /// The call controls in ChatGPT's windows, by their labels. Only buttons and checkboxes carrying one of
    /// the known labels are kept; nothing else is read out of the app.
    private static func controls(in app:NSRunningApplication) -> (elements:[(label:String,element:AXUIElement)],visited:Int) {
        let root=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root,2)
        var found:[(label:String,element:AXUIElement)]=[],visited=0
        func walk(_ element:AXUIElement,_ depth:Int) {
            guard depth <= 60,visited < 12_000 else { return }
            visited += 1
            if let role=attribute(element,kAXRoleAttribute) as? String,["AXCheckBox","AXButton","AXMenuButton"].contains(role) {
                for name in [kAXTitleAttribute,kAXDescriptionAttribute] {
                    if let label=attribute(element,name) as? String,labels.all.contains(label) { found.append((label,element)); break }
                }
            }
            for child in attribute(element,kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child,depth+1) }
        }
        for window in attribute(root,kAXWindowsAttribute) as? [AXUIElement] ?? [] { walk(window,0) }
        return (found,visited)
    }
    private static func attribute(_ element:AXUIElement,_ name:String) -> AnyObject? {
        var value:AnyObject?
        return AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success ? value : nil
    }
    /// Which route was taken, with no content, in the same readable log as Dot's calls.
    private static func note(_ text:String) {
        let log=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mail Dot/Logs/tool-calls.log")
        ToolCallLogStore.appendLine("\(Date().ISO8601Format()) call \(text)",to:log)
    }

    #if DEBUG
    /// Development only: where text can be entered in ChatGPT's windows and which buttons send it. Prints
    /// roles, placeholders and sizes, never what has been typed or said.
    public static func probeComposer() -> String {
        guard let app=running(),AXIsProcessTrusted() else { return "not available" }
        let root=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root,2)
        var lines:[String]=[],visited=0
        let pattern=try! NSRegularExpression(pattern:"send|submit|message|ask|type|reply|chat with",options:[.caseInsensitive])
        func walk(_ e:AXUIElement,_ depth:Int) {
            guard depth <= 60,visited < 12_000 else { return }
            visited += 1
            let role=attribute(e,kAXRoleAttribute) as? String ?? "?"
            let names=[kAXTitleAttribute,kAXDescriptionAttribute,kAXPlaceholderValueAttribute,kAXHelpAttribute].map{(attribute(e,$0) as? String) ?? ""}
            var size=CGSize.zero
            if let value=attribute(e,kAXSizeAttribute) { AXValueGetValue(value as! AXValue,.cgSize,&size) }
            if ["AXTextArea","AXTextField","AXComboBox"].contains(role) {
                var settable:DarwinBoolean=false
                AXUIElementIsAttributeSettable(e,kAXValueAttribute as CFString,&settable)
                let length=(attribute(e,kAXValueAttribute) as? String)?.count ?? -1
                lines.append("depth \(depth) \(role) title=\(names[0]) desc=\(names[1]) placeholder=\(names[2]) size=\(Int(size.width))x\(Int(size.height)) valueSettable=\(settable.boolValue) valueLength=\(length) focused=\(String(describing:attribute(e,kAXFocusedAttribute)))")
            } else if ["AXButton","AXMenuButton"].contains(role) {
                let text=names.filter{!$0.isEmpty}.joined(separator:" | ")
                if text.count <= 60,pattern.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) != nil,!text.contains("·") {
                    lines.append("depth \(depth) \(role) enabled=\(String(describing:attribute(e,kAXEnabledAttribute))) size=\(Int(size.width))x\(Int(size.height)): \(text.prefix(40))")
                }
            }
            for child in attribute(e,kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child,depth+1) }
        }
        for window in attribute(root,kAXWindowsAttribute) as? [AXUIElement] ?? [] { walk(window,0) }
        lines.append("visited=\(visited) \(probe())")
        return lines.joined(separator:"\n")
    }
    /// Development only: the Start call control's surroundings as Accessibility describes them: roles,
    /// actions and call labels only.
    public static func probeControlTree() -> String {
        guard let app=running(),AXIsProcessTrusted() else { return "not available" }
        guard let control=controls(in:app).elements.first(where:{labels.start.contains($0.label)})?.element else { return "no Start call control" }
        func describe(_ e:AXUIElement) -> String {
            var names:CFArray?
            AXUIElementCopyActionNames(e,&names)
            let label=[kAXTitleAttribute,kAXDescriptionAttribute].compactMap{attribute(e,$0) as? String}.filter{labels.all.contains($0)}.first ?? ""
            var size=CGSize.zero
            if let value=attribute(e,kAXSizeAttribute) { AXValueGetValue(value as! AXValue,.cgSize,&size) }
            return "\(attribute(e,kAXRoleAttribute) as? String ?? "?")/\(attribute(e,kAXSubroleAttribute) as? String ?? "-") actions=\(names as? [String] ?? []) label=\(label) size=\(Int(size.width))x\(Int(size.height)) enabled=\(String(describing:attribute(e,kAXEnabledAttribute) as? Bool)) focused=\(String(describing:attribute(e,kAXFocusedAttribute) as? Bool)) dom=\((attribute(e,"AXDOMClassList") as? [String])?.count ?? -1) domRole=\(attribute(e,"AXDOMRole") as? String ?? "-")"
        }
        var lines:[String]=[]
        var up:[AXUIElement]=[]
        var current=control
        for _ in 0..<4 { guard let parent=attribute(current,kAXParentAttribute) else { break }; up.append(parent as! AXUIElement); current=parent as! AXUIElement }
        for (index,e) in up.enumerated().reversed() { lines.append("ancestor \(index+1): \(describe(e)) children=\((attribute(e,kAXChildrenAttribute) as? [AXUIElement])?.count ?? 0)") }
        lines.append("CONTROL: \(describe(control)) value=\(String(describing:attribute(control,kAXValueAttribute)))")
        func down(_ e:AXUIElement,_ depth:Int) {
            for child in attribute(e,kAXChildrenAttribute) as? [AXUIElement] ?? [] { lines.append(String(repeating:"  ",count:depth)+"child: \(describe(child))"); if depth < 4 { down(child,depth+1) } }
        }
        down(control,1)
        if let parent=up.first { for sibling in attribute(parent,kAXChildrenAttribute) as? [AXUIElement] ?? [] { lines.append("sibling: \(describe(sibling))") } }
        var attributeNames:CFArray?
        AXUIElementCopyAttributeNames(control,&attributeNames)
        lines.append("attributes=\((attributeNames as? [String] ?? []).joined(separator:","))")
        let window=(attribute(AXUIElementCreateApplication(app.processIdentifier),kAXWindowsAttribute) as? [AXUIElement])?.first
        lines.append("window minimized=\(String(describing:window.flatMap{attribute($0,kAXMinimizedAttribute) as? Bool})) main=\(String(describing:window.flatMap{attribute($0,kAXMainAttribute) as? Bool})) hidden=\(app.isHidden) active=\(app.isActive)")
        return lines.joined(separator:"\n")
    }
    private static func texts(in app:NSRunningApplication) -> [String] {
        let root=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root,2)
        var found:[String]=[],visited=0
        func walk(_ e:AXUIElement,_ depth:Int) {
            guard depth <= 70,visited < 20_000 else { return }
            visited += 1
            if (attribute(e,kAXRoleAttribute) as? String) == "AXStaticText",let value=attribute(e,kAXValueAttribute) as? String,value.count >= 2 { found.append(value) }
            for child in attribute(e,kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child,depth+1) }
        }
        for window in attribute(root,kAXWindowsAttribute) as? [AXUIElement] ?? [] { walk(window,0) }
        return found
    }
    /// Development only, by hand, after announcing it. Optionally sends `prime` to Dot as a message and waits
    /// for the page to settle; then opens a call, watches for `seconds` which new text ChatGPT shows, and
    /// hangs up. It prints, for each new piece of text, only its length and whether it mentions mail or is a
    /// general greeting; never the words.
    public static func observe(prime:String?,settle:Double,seconds:Double) async -> String {
        guard let app=running(),AXIsProcessTrusted() else { return "not available" }
        let front=NSWorkspace.shared.frontmostApplication
        var lines:[String]=[]
        func flags(_ text:String) -> String {
            let lower=text.lowercased()
            let mail=["mail","inbox","message","email","report","draft"].contains{lower.contains($0)}
            let greeting=["what's up","what’s up","whats up","how can i","how's it going","hey","hello","hi there","what can i","what do you need"].contains{lower.contains($0)}
            return "len=\(text.count) mail=\(mail) greeting=\(greeting)\(prime.map{text.contains($0.prefix(30))} == true ? " isMyPrompt" : "")"
        }
        guard await bringForward(app) else { return "could not bring ChatGPT forward" }
        var known=Set(texts(in:app))
        lines.append("texts before=\(known.count) \(probe())")
        if let prime {
            let refusal=await say(prime)
            lines.append("prime sent=\(refusal == nil) \(refusal?.rawValue ?? "")")
            let end=Date().addingTimeInterval(settle)
            let began=Date()
            while Date() < end {
                try? await Task.sleep(for:.seconds(2))
                let fresh=texts(in:app).filter{!known.contains($0)}
                for text in fresh { lines.append(String(format:"  written +%.0fs ",Date().timeIntervalSince(began))+flags(text)); known.insert(text) }
            }
        }
        let outcome=await start()
        let began=Date()
        lines.append("call outcome=\(outcome)")
        let end=Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(for:.milliseconds(700))
            let fresh=texts(in:app).filter{!known.contains($0)}
            for text in fresh { lines.append(String(format:"  in call +%.1fs ",Date().timeIntervalSince(began))+flags(text)); known.insert(text) }
        }
        lines.append("hangUp=\(await hangUp())")
        try? await Task.sleep(for:.seconds(2))
        for text in texts(in:app).filter({!known.contains($0)}) { lines.append("  after call "+flags(text)) }
        lines.append("end: \(probe())")
        if let front,front.processIdentifier != app.processIdentifier { front.activate() }
        return lines.joined(separator:"\n")
    }
    /// Development only: controls on ChatGPT's page whose labels concern a call or its transcript, with
    /// their roles; labels of at most forty characters, so no conversation text.
    public static func probeCallRecords() -> String {
        guard let app=running(),AXIsProcessTrusted() else { return "not available" }
        let root=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root,2)
        var lines:[String]=[],visited=0
        let pattern=try! NSRegularExpression(pattern:"transcript|\\bcall\\b|voice|listen|read aloud|play|audio|caption",options:[.caseInsensitive])
        func walk(_ e:AXUIElement,_ depth:Int) {
            guard depth <= 70,visited < 20_000 else { return }
            visited += 1
            let role=attribute(e,kAXRoleAttribute) as? String ?? "?"
            let label=[kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute].compactMap{attribute(e,$0) as? String}.first{!$0.isEmpty} ?? ""
            if label.count <= 40,pattern.firstMatch(in:label,range:NSRange(label.startIndex...,in:label)) != nil { lines.append("depth \(depth) \(role): \(label)") }
            for child in attribute(e,kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child,depth+1) }
        }
        for window in attribute(root,kAXWindowsAttribute) as? [AXUIElement] ?? [] { walk(window,0) }
        return lines.suffix(40).joined(separator:"\n")+"\nvisited=\(visited)"
    }
    /// Development only: how the newest "Call ended" marker sits in the page: roles, actions and short
    /// labels of its ancestors and their children, to learn whether a transcript can be opened from it.
    public static func probeCallMarker() -> String {
        guard let app=running(),AXIsProcessTrusted() else { return "not available" }
        let root=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root,2)
        var marker:AXUIElement?,visited=0
        func walk(_ e:AXUIElement,_ depth:Int) {
            guard depth <= 70,visited < 20_000 else { return }
            visited += 1
            if (attribute(e,kAXRoleAttribute) as? String) == "AXStaticText",(attribute(e,kAXValueAttribute) as? String)?.hasSuffix("Call ended") == true { marker=e }
            for child in attribute(e,kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child,depth+1) }
        }
        for window in attribute(root,kAXWindowsAttribute) as? [AXUIElement] ?? [] { walk(window,0) }
        guard let marker else { return "no marker" }
        func describe(_ e:AXUIElement) -> String {
            var names:CFArray?
            AXUIElementCopyActionNames(e,&names)
            let label=[kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute].compactMap{attribute(e,$0) as? String}.first{!$0.isEmpty} ?? ""
            return "\(attribute(e,kAXRoleAttribute) as? String ?? "?")/\(attribute(e,kAXSubroleAttribute) as? String ?? "-") actions=\((names as? [String] ?? []).map{$0.replacingOccurrences(of:"AX",with:"")}) label=\(label.count <= 40 ? label : "(\(label.count) chars)")"
        }
        var lines:[String]=[],current=marker
        for level in 1...6 {
            guard let parent=attribute(current,kAXParentAttribute) else { break }
            let p=parent as! AXUIElement
            lines.append("ancestor \(level): \(describe(p))")
            if level <= 4 { for child in attribute(p,kAXChildrenAttribute) as? [AXUIElement] ?? [] { lines.append("    child: \(describe(child))") } }
            current=p
        }
        return lines.joined(separator:"\n")
    }
    /// Development only: opens ChatGPT's Settings from its own menu and lists the controls and headings
    /// that concern the microphone or voice, with their roles. Labels of at most sixty characters.
    public static func probeVoiceSettings() async -> String {
        guard let app=running(),AXIsProcessTrusted() else { return "not available" }
        let root=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root,2)
        var opened="no Settings item"
        func menu(_ e:AXUIElement,_ depth:Int) {
            guard depth <= 4 else { return }
            for child in attribute(e,kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if (attribute(child,kAXTitleAttribute) as? String)?.hasPrefix("Settings") == true,(attribute(child,kAXRoleAttribute) as? String) == "AXMenuItem" {
                    opened="press=\(AXUIElementPerformAction(child,kAXPressAction as CFString).rawValue)"; return
                }
                menu(child,depth+1)
            }
        }
        var voice:AXUIElement?
        var lines:[String]=[],visited=0
        func find(_ e:AXUIElement,_ depth:Int) {
            guard depth <= 40,voice == nil else { return }
            if (attribute(e,kAXRoleAttribute) as? String) == "AXButton",(attribute(e,kAXTitleAttribute) as? String ?? attribute(e,kAXDescriptionAttribute) as? String) == "Voice" { voice=e; return }
            for child in attribute(e,kAXChildrenAttribute) as? [AXUIElement] ?? [] { find(child,depth+1) }
        }
        for window in attribute(root,kAXWindowsAttribute) as? [AXUIElement] ?? [] { find(window,0) }
        if voice == nil {
            // Settings is not showing; open it from the menu, once.
            if let bar=attribute(root,kAXMenuBarAttribute) { menu(bar as! AXUIElement,0) }
            lines.append(opened)
            try? await Task.sleep(for:.seconds(3))
            for window in attribute(root,kAXWindowsAttribute) as? [AXUIElement] ?? [] { find(window,0) }
        }
        if let voice {
            let front=NSWorkspace.shared.frontmostApplication
            lines.append("voice page opened=\(await operate(voice,in:app))")
            try? await Task.sleep(for:.seconds(2))
            front?.activate()
        }
        let pattern=try! NSRegularExpression(pattern:"microphone|voice|dictat|speaker|audio|input|output|general|yeti|mail dot|default",options:[.caseInsensitive])
        func walk(_ e:AXUIElement,_ depth:Int) {
            guard depth <= 70,visited < 20_000 else { return }
            visited += 1
            let role=attribute(e,kAXRoleAttribute) as? String ?? "?"
            let label=[kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute].compactMap{attribute(e,$0) as? String}.first{!$0.isEmpty} ?? ""
            // Controls and headings only: running text on a page can be the owner's conversation.
            if ["AXButton","AXPopUpButton","AXMenuButton","AXCheckBox","AXComboBox","AXHeading","AXRadioButton"].contains(role),
               label.count <= 60,pattern.firstMatch(in:label,range:NSRange(label.startIndex...,in:label)) != nil { lines.append("depth \(depth) \(role): \(label)") }
            for child in attribute(e,kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child,depth+1) }
        }
        for window in attribute(root,kAXWindowsAttribute) as? [AXUIElement] ?? [] { walk(window,0) }
        return lines.joined(separator:"\n")+"\nvisited=\(visited)"
    }
    /// Development only: which call labels ChatGPT is showing now. Presses nothing.
    public static func probe() -> String {
        guard let app=running() else { return "ChatGPT is not running" }
        guard AXIsProcessTrusted() else { return "no Accessibility access" }
        let found=controls(in:app)
        return "labels=\(found.elements.map(\.label)) state=\(DotCallControl.state(labels:found.elements.map(\.label),known:labels)) visited=\(found.visited) frontmost=\(app.isActive)"
    }
    #endif
}
