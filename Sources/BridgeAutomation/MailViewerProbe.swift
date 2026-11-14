#if DEBUG
import AppKit
import ApplicationServices

/// Development only: looks at, and operates, the Mail window that shows the synthetic test message, to check
/// Mail Dot's banner and report panel in Mail itself. It refuses any window whose title does not contain
/// "synthetic", so it never reads the owner's mail.
@MainActor public enum MailViewerProbe {
    private static func attribute(_ element:AXUIElement,_ name:String) -> AnyObject? {
        var value:AnyObject?
        return AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success ? value : nil
    }
    private static func testWindows() -> [AXUIElement] {
        guard let mail=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first else { return [] }
        let app=AXUIElementCreateApplication(mail.processIdentifier)
        AXUIElementSetMessagingTimeout(app,3)
        return (attribute(app,kAXWindowsAttribute) as? [AXUIElement] ?? []).filter{(attribute($0,kAXTitleAttribute) as? String)?.lowercased().contains("synthetic") == true}
    }
    private static func walk(_ element:AXUIElement,_ depth:Int=0,_ visit:(AXUIElement,String,Int)->Void) {
        guard depth <= 70 else { return }
        visit(element,attribute(element,kAXRoleAttribute) as? String ?? "?",depth)
        for child in attribute(element,kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child,depth+1,visit) }
    }
    /// For each test window: whether the message body carries text, and the buttons and banner text present.
    public static func describe() -> String {
        guard AXIsProcessTrusted() else { return "no Accessibility access" }
        let windows=testWindows()
        guard !windows.isEmpty else { return "no synthetic test window in Mail" }
        return windows.enumerated().map { index,window in
            var bodyCharacters=0,inWeb=false,webDepth=0,labels:[String]=[]
            walk(window) { element,role,depth in
                if inWeb,depth <= webDepth { inWeb=false }
                if role == "AXWebArea" { inWeb=true; webDepth=depth }
                let text=(attribute(element,kAXValueAttribute) as? String) ?? ""
                if inWeb,role == "AXStaticText" { bodyCharacters += text.count }
                if !inWeb,["AXButton","AXStaticText","AXPopUpButton","AXMenuButton"].contains(role) {
                    let label=[kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute].compactMap{attribute(element,$0) as? String}.first{!$0.isEmpty} ?? ""
                    if !label.isEmpty,label.count <= 90 { labels.append("\(role.dropFirst(2)):\(label)") }
                }
            }
            return "window \(index): bodyCharacters=\(bodyCharacters) controls=[\(labels.joined(separator:"; "))]"
        }.joined(separator:"\n")
    }
    /// Presses the first button whose label contains `label` in the newest test window, or below `root` when given.
    public static func press(_ label:String) -> String {
        guard AXIsProcessTrusted() else { return "no Accessibility access" }
        var found:AXUIElement?
        for window in testWindows() where found == nil {
            walk(window) { element,role,_ in
                guard found == nil,role == "AXButton" else { return }
                let text=[kAXTitleAttribute,kAXDescriptionAttribute].compactMap{attribute(element,$0) as? String}.first{!$0.isEmpty} ?? ""
                if text.localizedCaseInsensitiveContains(label) { found=element }
            }
        }
        guard let found else { return "no button containing \(label)" }
        return "press=\(AXUIElementPerformAction(found,kAXPressAction as CFString).rawValue)"
    }
    /// Mail Dot's own report panel in Mail: a small window titled "Mail Dot".
    private static func panel() -> (AXUIElement,pid_t)? {
        guard let mail=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first else { return nil }
        let app=AXUIElementCreateApplication(mail.processIdentifier)
        AXUIElementSetMessagingTimeout(app,3)
        let found=(attribute(app,kAXWindowsAttribute) as? [AXUIElement] ?? []).first{(attribute($0,kAXTitleAttribute) as? String) == "Mail Dot"}
        return found.map{($0,mail.processIdentifier)}
    }
    /// The panel's buttons with whether each is enabled or selected, and its short texts.
    public static func describePanel() -> String {
        guard AXIsProcessTrusted() else { return "no Accessibility access" }
        guard let (window,_)=panel() else { return "no Mail Dot panel open in Mail" }
        var lines:[String]=[]
        walk(window) { element,role,_ in
            let label=[kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute].compactMap{attribute(element,$0) as? String}.first{!$0.isEmpty} ?? ""
            guard !label.isEmpty,label.count <= 110 else { return }
            if role == "AXButton" {
                let enabled=(attribute(element,kAXEnabledAttribute) as? Bool) ?? true
                let selected=(attribute(element,kAXSelectedAttribute) as? Bool) ?? false
                lines.append("[\(enabled ? "button" : "button, disabled")\(selected ? ", selected" : "")] \(label)")
            } else if role == "AXStaticText" || role == "AXTextField" || role == "AXTextArea" { lines.append("  \(role == "AXStaticText" ? "" : "(field) ")\(label)") }
        }
        return lines.joined(separator:"\n")
    }
    public static func pressInPanel(_ label:String) -> String {
        guard AXIsProcessTrusted(),let (window,_)=panel() else { return "no Mail Dot panel open in Mail" }
        var found:AXUIElement?
        walk(window) { element,role,_ in
            guard found == nil,role == "AXButton" else { return }
            let text=[kAXTitleAttribute,kAXDescriptionAttribute].compactMap{attribute(element,$0) as? String}.first{!$0.isEmpty} ?? ""
            if text.localizedCaseInsensitiveContains(label) { found=element }
        }
        guard let found else { return "no button containing \(label)" }
        return "press \(label)=\(AXUIElementPerformAction(found,kAXPressAction as CFString).rawValue)"
    }
    /// Sends one key to Mail, which passes it to the panel when the panel has the keyboard.
    /// AX does not say whether the panel holds the keyboard, since its content is another process's. With
    /// `trusting`, only that Mail is in front is checked, so use it for a key that is harmless in Mail's
    /// own windows (a digit) to learn where keys go, and for others only once that is known.
    public static func keyToPanel(_ name:String,trusting:Bool) -> String {
        guard trusting else { return keyToPanel(name) }
        guard let (_,pid)=panel(),NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return "key \(name) not sent: no panel, or Mail is not in front" }
        let codes:[String:CGKeyCode]=["1":18,"2":19,"3":20,"4":21,"return":36,"escape":53,"d":2,"e":14,"z":6,"n":45,"a":0,"o":31]
        guard let code=codes[name] else { return "unknown key" }
        for down in [true,false] { CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)?.post(tap:.cghidEventTap); usleep(40_000) }
        return "key \(name) sent"
    }
    public static func keyToPanel(_ name:String) -> String {
        guard let (window,pid)=panel() else { return "no Mail Dot panel open in Mail" }
        var command=false,key=name
        if key.hasPrefix("cmd+") { command=true; key=String(key.dropFirst(4)) }
        let codes:[String:CGKeyCode]=["1":18,"2":19,"3":20,"4":21,"return":36,"escape":53,"d":2,"e":14,"z":6,"n":45,"a":0,"o":31]
        guard let code=codes[key] else { return "unknown key" }
        for down in [true,false] {
            let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)
            if command { event?.flags = .maskCommand }
            // Through the system, as a key the owner presses: a key sent to Mail alone never reaches the
            // extension's view. Mail is in front and the panel has the keyboard after a click in it.
            // Sent only while Mail is in front with the panel holding the keyboard, so that the key cannot
            // land anywhere else.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let focused=attribute(AXUIElementCreateApplication(pid),kAXFocusedWindowAttribute),(attribute(focused as! AXUIElement,kAXTitleAttribute) as? String) == "Mail Dot" else {
                let app=AXUIElementCreateApplication(pid)
                let focused=attribute(app,kAXFocusedWindowAttribute).map{$0 as! AXUIElement}
                let element=attribute(app,kAXFocusedUIElementAttribute).map{$0 as! AXUIElement}
                var owner:pid_t=0
                if let element { AXUIElementGetPid(element,&owner) }
                return "key \(name) not sent: front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") focusedWindowIsPanel=\(focused.map{(attribute($0,kAXTitleAttribute) as? String) == "Mail Dot"} ?? false) panelFocused=\((attribute(window,kAXFocusedAttribute) as? Bool) == true) panelMain=\((attribute(window,kAXMainAttribute) as? Bool) == true) focusedElementRole=\(element.flatMap{attribute($0,kAXRoleAttribute) as? String} ?? "none") focusedElementInMail=\(owner == pid)"
            }
            event?.post(tap:.cghidEventTap)
            usleep(40_000)
        }
        return "key \(name) sent"
    }
    /// The panel's content lives in Mail Dot's own extension process, not in Mail, and Mail's window does not
    /// expose it. Given that process (MAILDOT_EXTENSION_PID), the panel can be read and pressed directly.
    /// The process's application element shows nothing, so the content is reached the way a pointer reaches
    /// it: by asking what lies at the middle of the panel, then climbing to the top of that tree.
    private static var extensionApp:AXUIElement? {
        guard let (window,_)=panel() else { return nil }
        var point=CGPoint.zero,size=CGSize.zero
        guard let position=attribute(window,kAXPositionAttribute),let extent=attribute(window,kAXSizeAttribute),
              AXValueGetValue(position as! AXValue,.cgPoint,&point),AXValueGetValue(extent as! AXValue,.cgSize,&size) else { return nil }
        AXUIElementPerformAction(window,kAXRaiseAction as CFString)
        var hit:AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(point.x+size.width/2),Float(point.y+size.height/2),&hit) == .success,var top=hit else { return nil }
        var pid:pid_t=0
        AXUIElementGetPid(top,&pid)
        guard NSRunningApplication(processIdentifier:pid)?.bundleIdentifier != "com.apple.mail" else { return nil }
        for _ in 0..<40 { guard let parent=attribute(top,kAXParentAttribute) else { break }; top=parent as! AXUIElement }
        return top
    }
    /// A row of the list names one of the owner's matters, so only the developer's test rows are printed in full.
    private static func safe(_ label:String) -> String { label.hasPrefix("Report:") && !label.contains("TEST REPORT") ? "Report: (one of the owner's)" : label }
    /// The buttons of the panel as the extension process exposes them: label, and whether enabled.
    public static func describeExtension() -> String {
        guard AXIsProcessTrusted(),let app=extensionApp else { return "no Accessibility access, or the panel\u{2019}s content could not be reached" }
        var lines:[String]=[]
        walk(app) { element,role,_ in
            guard role == "AXButton" || role == "AXMenuButton" || role == "AXTextField" || role == "AXTextArea" else { return }
            let label=[kAXTitleAttribute,kAXDescriptionAttribute].compactMap{attribute(element,$0) as? String}.first{!$0.isEmpty} ?? ""
            let enabled=(attribute(element,kAXEnabledAttribute) as? Bool) ?? true
            lines.append("[\(role.dropFirst(2))\(enabled ? "" : ", disabled")] \(safe(String(label.prefix(110))))")
        }
        return lines.isEmpty ? "the extension process exposes no controls" : lines.joined(separator:"\n")
    }
    public static func pressInExtension(_ label:String) -> String {
        guard AXIsProcessTrusted(),let app=extensionApp else { return "no Accessibility access, or the panel\u{2019}s content could not be reached" }
        var found:AXUIElement?
        walk(app) { element,role,_ in
            guard found == nil,role == "AXButton" else { return }
            let text=[kAXTitleAttribute,kAXDescriptionAttribute].compactMap{attribute(element,$0) as? String}.first{!$0.isEmpty} ?? ""
            if text.localizedCaseInsensitiveContains(label) { found=element }
        }
        guard let found else { return "no button containing \(label)" }
        return "press \(label)=\(AXUIElementPerformAction(found,kAXPressAction as CFString).rawValue)"
    }
    /// Clicks at a point of the panel, given in points from the panel's top left corner (the title bar
    /// included). The panel's content is drawn by Mail Dot's extension in another process, and only a click
    /// that arrives the way the owner's own does reaches it; the pointer is put back where it was.
    public static func clickInPanel(x:Double,y:Double) -> String {
        guard let (window,pid)=panel() else { return "no Mail Dot panel open in Mail" }
        var origin=CGPoint.zero
        guard let position=attribute(window,kAXPositionAttribute),AXValueGetValue(position as! AXValue,.cgPoint,&origin) else { return "the panel has no position" }
        NSRunningApplication(processIdentifier:pid)?.activate()
        AXUIElementPerformAction(window,kAXRaiseAction as CFString)
        usleep(300_000)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return "not clicked: Mail is not in front" }
        let point=CGPoint(x:origin.x+x,y:origin.y+y),before=CGEvent(source:nil)?.location
        for type in [CGEventType.mouseMoved,.leftMouseDown,.leftMouseUp] {
            let event=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:point,mouseButton:.left)
            if type != .mouseMoved { event?.setIntegerValueField(.mouseEventClickState,value:1) }
            event?.post(tap:.cghidEventTap)
            usleep(80_000)
        }
        if let before { CGWarpMouseCursorPosition(before) }
        return "clicked at \(Int(x)),\(Int(y))"
    }
    /// Closes the one Mail window whose top left corner is exactly here, without reading anything of it:
    /// for a window a test opened by mistake.
    public static func closeWindow(atX x:Double,y:Double) -> String {
        guard let mail=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first else { return "Mail is not running" }
        let app=AXUIElementCreateApplication(mail.processIdentifier)
        func origin(_ window:AXUIElement) -> CGPoint? {
            var point=CGPoint.zero
            guard let position=attribute(window,kAXPositionAttribute),AXValueGetValue(position as! AXValue,.cgPoint,&point) else { return nil }
            return point
        }
        let matches=(attribute(app,kAXWindowsAttribute) as? [AXUIElement] ?? []).filter{origin($0) == CGPoint(x:x,y:y)}
        guard matches.count == 1,let window=matches.first else { return "\(matches.count) windows at that corner; nothing closed" }
        mail.activate()
        AXUIElementPerformAction(window,kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window,kAXMainAttribute as CFString,kCFBooleanTrue)
        usleep(500_000)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == mail.processIdentifier,
              let focused=attribute(app,kAXFocusedWindowAttribute),origin(focused as! AXUIElement) == CGPoint(x:x,y:y) else { return "Mail is not in front with that window holding the keyboard; nothing closed" }
        for down in [true,false] {
            let event=CGEvent(keyboardEventSource:nil,virtualKey:13,keyDown:down)
            event?.flags = .maskCommand
            event?.post(tap:.cghidEventTap)
            usleep(40_000)
        }
        usleep(700_000)
        let left=(attribute(app,kAXWindowsAttribute) as? [AXUIElement] ?? []).filter{origin($0) == CGPoint(x:x,y:y)}.count
        return left == 0 ? "closed the window at \(Int(x)),\(Int(y))" : "Command-W was sent but the window is still there"
    }
    /// Mail's windows by shape alone: corner, kind, whether main or holding the keyboard, and whether a
    /// sheet or dialog is attached. Nothing of their content or titles is read, except "synthetic".
    public static func windowShapes() -> String {
        guard let mail=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first else { return "Mail is not running" }
        let app=AXUIElementCreateApplication(mail.processIdentifier)
        let focused=attribute(app,kAXFocusedWindowAttribute)
        return "frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")\n"+(attribute(app,kAXWindowsAttribute) as? [AXUIElement] ?? []).map { window in
            var point=CGPoint.zero
            if let position=attribute(window,kAXPositionAttribute) { AXValueGetValue(position as! AXValue,.cgPoint,&point) }
            let children=(attribute(window,kAXChildrenAttribute) as? [AXUIElement] ?? []).compactMap{attribute($0,kAXRoleAttribute) as? String}
            let title=(attribute(window,kAXTitleAttribute) as? String) ?? ""
            return "at \(Int(point.x)),\(Int(point.y)) subrole=\((attribute(window,kAXSubroleAttribute) as? String) ?? "?") main=\((attribute(window,kAXMainAttribute) as? Bool) == true) focused=\(focused.map{CFEqual($0,window)} ?? false) modal=\((attribute(window,kAXModalAttribute) as? Bool) == true) sheet=\(children.contains("AXSheet")) synthetic=\(title.lowercased().contains("synthetic")) maildot=\(title == "Mail Dot")"
        }.joined(separator:"\n")
    }
    // MARK: The synthetic reply window and the Mail Dot popover on it

    /// The frame of the synthetic test window that holds the keyboard, and Mail's process, but only while
    /// Mail is in front with that window as its main window. Everything below acts through this, so that no
    /// click or key can reach one of the owner's own messages.
    private static func syntheticMain() -> (CGRect,pid_t)? {
        guard let mail=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == mail.processIdentifier else { return nil }
        let app=AXUIElementCreateApplication(mail.processIdentifier)
        guard let main=attribute(app,kAXMainWindowAttribute).map({$0 as! AXUIElement}),
              (attribute(main,kAXTitleAttribute) as? String)?.lowercased().contains("synthetic") == true else { return nil }
        var point=CGPoint.zero,size=CGSize.zero
        guard let position=attribute(main,kAXPositionAttribute),let extent=attribute(main,kAXSizeAttribute),
              AXValueGetValue(position as! AXValue,.cgPoint,&point),AXValueGetValue(extent as! AXValue,.cgSize,&size) else { return nil }
        return (CGRect(origin:point,size:size),mail.processIdentifier)
    }
    /// Brings the synthetic test window to the front of Mail.
    public static func raiseTestWindow() -> String {
        guard let mail=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first,let window=testWindows().first else { return "no synthetic test window" }
        mail.activate()
        AXUIElementPerformAction(window,kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window,kAXMainAttribute as CFString,kCFBooleanTrue)
        usleep(500_000)
        return syntheticMain() == nil ? "the synthetic window did not come to the front" : "raised"
    }
    /// A click at a point given from the synthetic window's top left corner, as the owner's own click arrives.
    public static func clickInTestWindow(x:Double,y:Double) -> String {
        guard let (frame,_)=syntheticMain() else { return "not clicked: the synthetic window is not Mail's main window in front" }
        let point=CGPoint(x:frame.minX+x,y:frame.minY+y),before=CGEvent(source:nil)?.location
        for type in [CGEventType.mouseMoved,.leftMouseDown,.leftMouseUp] {
            let event=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:point,mouseButton:.left)
            if type != .mouseMoved { event?.setIntegerValueField(.mouseEventClickState,value:1) }
            event?.post(tap:.cghidEventTap)
            usleep(80_000)
        }
        if let before { CGWarpMouseCursorPosition(before) }
        return "clicked at \(Int(x)),\(Int(y))"
    }
    /// Types text, or presses one named key, while the synthetic window is Mail's main window in front.
    public static func typeInTestWindow(_ text:String,key:Bool) -> String {
        guard syntheticMain() != nil else { return "not typed: the synthetic window is not Mail's main window in front" }
        if key {
            let codes:[String:CGKeyCode]=["1":18,"2":19,"3":20,"4":21,"escape":53,"tab":48]
            guard let code=codes[text] else { return "unknown key (Return is never sent here)" }
            for down in [true,false] { CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)?.post(tap:.cghidEventTap); usleep(40_000) }
            return "key \(text) sent"
        }
        for character in text {
            let units=Array(String(character).utf16)
            for down in [true,false] {
                let event=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:down)
                event?.keyboardSetUnicodeString(stringLength:units.count,unicodeString:units)
                event?.post(tap:.cghidEventTap)
                usleep(15_000)
            }
        }
        return "typed \(text.count) characters"
    }
    /// Captures the part of the screen the synthetic window occupies, with whatever Mail shows over it.
    public static func captureTestWindow(to path:String) -> String {
        guard let (frame,_)=syntheticMain() else { return "not captured: the synthetic window is not Mail's main window in front" }
        let capture=Process()
        capture.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
        capture.arguments=["-x","-R","\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))",path]
        try? capture.run(); capture.waitUntilExit()
        return "shot \((path as NSString).lastPathComponent) status=\(capture.terminationStatus)"
    }
    /// The Mail Dot toolbar button of the synthetic reply: what it is, pressed through accessibility, and
    /// whether a popover then belongs to the window.
    public static func pressComposeButton() -> String {
        guard AXIsProcessTrusted(),let window=testWindows().first else { return "no synthetic test window" }
        var found:AXUIElement?
        walk(window) { element,role,_ in
            guard found == nil,role == "AXButton" || role == "AXCheckBox" || role == "AXMenuButton" else { return }
            let text=[kAXTitleAttribute,kAXDescriptionAttribute].compactMap{attribute(element,$0) as? String}.first{!$0.isEmpty} ?? ""
            if text == "Mail Dot" { found=element }
        }
        guard let found else { return "no Mail Dot button" }
        var names:CFArray?
        AXUIElementCopyActionNames(found,&names)
        let before="role=\((attribute(found,kAXRoleAttribute) as? String) ?? "?") subrole=\((attribute(found,kAXSubroleAttribute) as? String) ?? "-") enabled=\((attribute(found,kAXEnabledAttribute) as? Bool) ?? true) actions=\((names as? [String]) ?? [])"
        let result=AXUIElementPerformAction(found,kAXPressAction as CFString).rawValue
        usleep(2_500_000)
        var popovers=0
        walk(window) { _,role,_ in if role == "AXPopover" { popovers += 1 } }
        return "\(before) press=\(result) popoversAfter=\(popovers)"
    }
    /// Captures the panel as the screen shows it.
    public static func capturePanel(to path:String) -> String {
        let all=CGWindowListCopyWindowInfo([.optionOnScreenOnly],kCGNullWindowID) as? [[String:Any]] ?? []
        guard let number=all.first(where:{($0[kCGWindowOwnerName as String] as? String) == "Mail" && ($0[kCGWindowName as String] as? String) == "Mail Dot"})?[kCGWindowNumber as String] as? Int else { return "no Mail Dot panel on screen" }
        let capture=Process()
        capture.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
        capture.arguments=["-x","-o","-l","\(number)",path]
        try? capture.run(); capture.waitUntilExit()
        return "shot \((path as NSString).lastPathComponent) status=\(capture.terminationStatus)"
    }
    /// Closes every Mail Dot panel open in Mail.
    public static func closePanels() -> Int {
        guard let mail=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first else { return 0 }
        let app=AXUIElementCreateApplication(mail.processIdentifier)
        var closed=0
        for window in (attribute(app,kAXWindowsAttribute) as? [AXUIElement] ?? []) where (attribute(window,kAXTitleAttribute) as? String) == "Mail Dot" {
            if let button=attribute(window,kAXCloseButtonAttribute),AXUIElementPerformAction(button as! AXUIElement,kAXPressAction as CFString) == .success { closed += 1 }
        }
        return closed
    }
    /// The number of Mail Dot icons Mail shows in message headers, in every window: a count only, so nothing
    /// of the owner's mail is read.
    public static func countHeaderIcons() -> String {
        guard AXIsProcessTrusted(),let mail=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first else { return "no Accessibility access or Mail not running" }
        let app=AXUIElementCreateApplication(mail.processIdentifier)
        AXUIElementSetMessagingTimeout(app,3)
        return (attribute(app,kAXWindowsAttribute) as? [AXUIElement] ?? []).enumerated().map { index,window in
            var icons=0,banners=0,bodies=0,deepest=0
            walk(window) { element,role,depth in
                deepest=max(deepest,depth)
                if role == "AXWebArea" { bodies += 1 }
                guard role == "AXButton" else { return }
                let label=[kAXTitleAttribute,kAXDescriptionAttribute,kAXIdentifierAttribute].compactMap{attribute(element,$0) as? String}.joined(separator:" ")
                if label.contains("AXExtensionDecoded") { icons += 1 }
                if label.contains("Show Dot") { banners += 1 }
            }
            let kind=(attribute(window,kAXSubroleAttribute) as? String) ?? "?"
            let main=(attribute(window,kAXMainAttribute) as? Bool) == true
            return "window \(index) (\(kind)\(main ? ", main" : "")): message bodies shown=\(bodies) Mail Dot header icons=\(icons) Mail Dot banners=\(banners) depth=\(deepest)"
        }.joined(separator:"\n")
    }
    /// Closes every synthetic test window. Mail ignores a press of the close button from outside, so each
    /// window is brought forward and closed with Command-W, and only after Mail confirms that the window
    /// with the keyboard is a synthetic one.
    public static func closeTestWindows() -> Int {
        guard let mail=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first else { return 0 }
        let app=AXUIElementCreateApplication(mail.processIdentifier)
        var closed=0
        for _ in 0..<12 {
            guard let window=testWindows().first else { break }
            mail.activate()
            AXUIElementPerformAction(window,kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window,kAXMainAttribute as CFString,kCFBooleanTrue)
            usleep(500_000)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == mail.processIdentifier,
                  let focused=attribute(app,kAXFocusedWindowAttribute),(attribute(focused as! AXUIElement,kAXTitleAttribute) as? String)?.lowercased().contains("synthetic") == true else { break }
            let before=testWindows().count
            for down in [true,false] {
                let event=CGEvent(keyboardEventSource:nil,virtualKey:13,keyDown:down)
                event?.flags = .maskCommand
                event?.post(tap:.cghidEventTap)
                usleep(40_000)
            }
            usleep(700_000)
            // Counted only if the window is really gone; if it is not, stop instead of pressing again.
            guard testWindows().count < before else { break }
            closed += 1
        }
        return closed
    }
}
#endif
