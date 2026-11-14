// Development probe for Mail Dot in Mail, run from the shell so that no second copy of the app or its
// extension is ever registered. It acts only on Mail windows whose title contains "synthetic", and sends a
// click or key only while Mail is in front with such a window as its main window.
import AppKit
import ApplicationServices

func attribute(_ element:AXUIElement,_ name:String) -> AnyObject? {
    var value:AnyObject?
    return AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success ? value : nil
}
func walk(_ element:AXUIElement,_ depth:Int=0,_ visit:(AXUIElement,String,Int)->Void) {
    guard depth <= 60 else { return }
    visit(element,attribute(element,kAXRoleAttribute) as? String ?? "?",depth)
    for child in attribute(element,kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child,depth+1,visit) }
}
let mail=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first
func mailApp() -> AXUIElement? {
    guard let mail else { return nil }
    let app=AXUIElementCreateApplication(mail.processIdentifier)
    AXUIElementSetMessagingTimeout(app,3)
    return app
}
func title(_ window:AXUIElement) -> String { (attribute(window,kAXTitleAttribute) as? String) ?? "" }
func testWindows() -> [AXUIElement] {
    guard let app=mailApp() else { return [] }
    return (attribute(app,kAXWindowsAttribute) as? [AXUIElement] ?? []).filter{title($0).lowercased().contains("synthetic")}
}
func frame(_ window:AXUIElement) -> CGRect? {
    var point=CGPoint.zero,size=CGSize.zero
    guard let position=attribute(window,kAXPositionAttribute),let extent=attribute(window,kAXSizeAttribute),
          AXValueGetValue(position as! AXValue,.cgPoint,&point),AXValueGetValue(extent as! AXValue,.cgSize,&size) else { return nil }
    return CGRect(origin:point,size:size)
}
/// The synthetic window, only while it is Mail's main window and Mail is in front.
func syntheticMain() -> (AXUIElement,CGRect)? {
    guard let mail,let app=mailApp(),NSWorkspace.shared.frontmostApplication?.processIdentifier == mail.processIdentifier,
          let main=attribute(app,kAXMainWindowAttribute).map({$0 as! AXUIElement}),title(main).lowercased().contains("synthetic"),let rect=frame(main) else { return nil }
    return (main,rect)
}
func raise(compose:Bool) -> String {
    guard let mail else { return "Mail is not running" }
    // A reply window has a Send button; the message it answers does not.
    let wanted=testWindows().first { window in
        var send=false
        walk(window) { element,role,_ in if role == "AXButton",(attribute(element,kAXDescriptionAttribute) as? String ?? attribute(element,kAXTitleAttribute) as? String) == "Send" { send=true } }
        return send == compose
    }
    guard let window=wanted else { return "no synthetic \(compose ? "reply" : "message") window" }
    if let (main,_)=syntheticMain(),CFEqual(main,window) { return "already in front" }
    mail.activate()
    AXUIElementPerformAction(window,kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(window,kAXMainAttribute as CFString,kCFBooleanTrue)
    usleep(600_000)
    return syntheticMain() == nil ? "the synthetic window did not come to the front" : "raised"
}
func label(_ element:AXUIElement) -> String {
    [kAXTitleAttribute,kAXDescriptionAttribute].compactMap{attribute(element,$0) as? String}.first{!$0.isEmpty} ?? ""
}
func press(_ wanted:String) -> String {
    var found:AXUIElement?
    for window in testWindows() where found == nil {
        walk(window) { element,role,_ in
            guard found == nil,role == "AXButton" else { return }
            if label(element) == wanted || (wanted.hasSuffix("*") && label(element).hasPrefix(String(wanted.dropLast()))) { found=element }
        }
    }
    guard let found else { return "no button \(wanted)" }
    return "press \(wanted)=\(AXUIElementPerformAction(found,kAXPressAction as CFString).rawValue)"
}
func click(_ x:Double,_ y:Double) -> String {
    guard let (_,rect)=syntheticMain() else { return "not clicked: the synthetic window is not Mail's main window in front" }
    let point=CGPoint(x:rect.minX+x,y:rect.minY+y),before=CGEvent(source:nil)?.location
    for type in [CGEventType.mouseMoved,.leftMouseDown,.leftMouseUp] {
        let event=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:point,mouseButton:.left)
        if type != .mouseMoved { event?.setIntegerValueField(.mouseEventClickState,value:1) }
        event?.post(tap:.cghidEventTap)
        usleep(90_000)
    }
    if let before { CGWarpMouseCursorPosition(before) }
    return "clicked at \(Int(x)),\(Int(y))"
}
func type(_ text:String) -> String {
    guard syntheticMain() != nil else { return "not typed: the synthetic window is not Mail's main window in front" }
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
/// Named keys. Return is never sent: in a reply window it could send mail.
func key(_ name:String) -> String {
    guard syntheticMain() != nil else { return "not sent: the synthetic window is not Mail's main window in front" }
    let codes:[String:CGKeyCode]=["1":18,"2":19,"3":20,"4":21,"escape":53,"tab":48,"x":7]
    guard let code=codes[name] else { return "unknown key \(name)" }
    for down in [true,false] { CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)?.post(tap:.cghidEventTap); usleep(40_000) }
    return "key \(name) sent"
}
func shot(_ path:String) -> String {
    guard let (_,rect)=syntheticMain() else { return "not captured: the synthetic window is not Mail's main window in front" }
    let capture=Process()
    capture.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
    capture.arguments=["-x","-R","\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))",path]
    try? capture.run(); capture.waitUntilExit()
    return "shot \((path as NSString).lastPathComponent) status=\(capture.terminationStatus)"
}
func popovers() -> String {
    var count=0
    for window in testWindows() { walk(window) { _,role,_ in if role == "AXPopover" { count += 1 } } }
    return "popovers=\(count)"
}
/// The controls inside the Mail Dot popover of the synthetic reply, if Mail exposes them.
func popoverControls() -> String {
    var lines:[String]=[]
    for window in testWindows() {
        walk(window) { element,role,_ in
            guard role == "AXPopover" else { return }
            walk(element) { inner,innerRole,depth in
                guard ["AXButton","AXRadioButton","AXTextField","AXTextArea","AXMenuButton"].contains(innerRole) else { return }
                let text=[kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute].compactMap{attribute(inner,$0) as? String}.first{!$0.isEmpty} ?? ""
                let typed=["AXTextField","AXTextArea"].contains(innerRole) ? " value=[\(((attribute(inner,kAXValueAttribute) as? String) ?? "").prefix(60).replacingOccurrences(of:"\n",with:" "))] focused=\((attribute(inner,kAXFocusedAttribute) as? Bool) == true)" : ""
                lines.append("\(innerRole.dropFirst(2)): \(text.prefix(70).replacingOccurrences(of:"\n",with:" "))\(typed)")
            }
        }
    }
    return lines.isEmpty ? "the popover shows no controls to accessibility" : lines.joined(separator:"\n")
}
func inPopover(_ wanted:String,set value:String?) -> String {
    var found:AXUIElement?
    for window in testWindows() {
        walk(window) { element,role,_ in
            guard role == "AXPopover",found == nil else { return }
            walk(element) { inner,innerRole,_ in
                guard found == nil else { return }
                let text=[kAXTitleAttribute,kAXDescriptionAttribute,kAXPlaceholderValueAttribute].compactMap{attribute(inner,$0) as? String}.first{!$0.isEmpty} ?? ""
                if value == nil,["AXButton","AXRadioButton"].contains(innerRole),text == wanted || text.hasPrefix(wanted) { found=inner }
                if value != nil,["AXTextField","AXTextArea"].contains(innerRole),text.hasPrefix(wanted) || wanted == "*" { found=inner }
            }
        }
    }
    guard let found else { return "nothing in the popover matches \(wanted)" }
    if value == "" { return "focus \(wanted)=\(AXUIElementSetAttributeValue(found,kAXFocusedAttribute as CFString,kCFBooleanTrue).rawValue)" }
    if let value {
        AXUIElementSetAttributeValue(found,kAXFocusedAttribute as CFString,kCFBooleanTrue)
        return "set \(wanted)=\(AXUIElementSetAttributeValue(found,kAXValueAttribute as CFString,value as CFString).rawValue)"
    }
    return "press \(wanted)=\(AXUIElementPerformAction(found,kAXPressAction as CFString).rawValue)"
}
/// The Mail Dot panel a message's header icon opens: a small window of Mail's titled "Mail Dot".
func panelWindow() -> (AXUIElement,CGRect)? {
    guard let app=mailApp() else { return nil }
    for window in attribute(app,kAXWindowsAttribute) as? [AXUIElement] ?? [] where title(window) == "Mail Dot" { if let rect=frame(window) { return (window,rect) } }
    return nil
}
func panelClick(_ x:Double,_ y:Double) -> String {
    guard let mail,NSWorkspace.shared.frontmostApplication?.processIdentifier == mail.processIdentifier,let (_,rect)=panelWindow() else { return "not clicked: no Mail Dot panel in front" }
    let point=CGPoint(x:rect.minX+x,y:rect.minY+y),before=CGEvent(source:nil)?.location
    for type in [CGEventType.mouseMoved,.leftMouseDown,.leftMouseUp] {
        let event=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:point,mouseButton:.left)
        if type != .mouseMoved { event?.setIntegerValueField(.mouseEventClickState,value:1) }
        event?.post(tap:.cghidEventTap); usleep(90_000)
    }
    if let before { CGWarpMouseCursorPosition(before) }
    return "clicked panel at \(Int(x)),\(Int(y))"
}
func panelShot(_ path:String) -> String {
    let list=CGWindowListCopyWindowInfo([.optionOnScreenOnly],kCGNullWindowID) as? [[String:Any]] ?? []
    guard let number=list.first(where:{($0[kCGWindowOwnerName as String] as? String) == "Mail" && ($0[kCGWindowName as String] as? String) == "Mail Dot"})?[kCGWindowNumber as String] as? Int else { return "no Mail Dot panel on screen" }
    let capture=Process(); capture.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture"); capture.arguments=["-x","-o","-l","\(number)",path]
    try? capture.run(); capture.waitUntilExit(); return "panel shot status=\(capture.terminationStatus)"
}
/// The text of the synthetic reply's body, written to a file, for comparing before and after Insert.
func body(_ path:String) -> String {
    for window in testWindows() {
        var send=false; var webs:[AXUIElement]=[]
        walk(window) { e,r,_ in if r == "AXWebArea" { webs.append(e) }; if r == "AXButton",label(e) == "Send" { send=true } }
        guard send,let web=webs.last else { continue }
        var range:CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(web,"AXTextMarkerRangeForUIElement" as CFString,web,&range) == .success,let range else { return "no body range" }
        var text:CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(web,"AXStringForTextMarkerRange" as CFString,range,&text) == .success,let string=text as? String else { return "no body text" }
        try? string.write(toFile:path,atomically:true,encoding:.utf8)
        return "body \(string.count) characters written"
    }
    return "no synthetic reply window"
}
func closeAll() -> String {
    guard let mail,let app=mailApp() else { return "Mail is not running" }
    var closed=0
    for _ in 0..<8 {
        guard let window=testWindows().first else { break }
        let before=testWindows().count
        mail.activate()
        AXUIElementPerformAction(window,kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window,kAXMainAttribute as CFString,kCFBooleanTrue)
        usleep(600_000)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == mail.processIdentifier,
              let focused=attribute(app,kAXFocusedWindowAttribute),title(focused as! AXUIElement).lowercased().contains("synthetic") else { break }
        for down in [true,false] {
            let event=CGEvent(keyboardEventSource:nil,virtualKey:13,keyDown:down)
            event?.flags = .maskCommand
            event?.post(tap:.cghidEventTap)
            usleep(40_000)
        }
        // A key sent with the Command flag leaves the system believing Command is held, which makes Mail Dot
        // refuse to type into a reply (and would turn the owner's next key into a shortcut). Say it was released.
        let released=CGEvent(keyboardEventSource:nil,virtualKey:55,keyDown:false)
        released?.type = .flagsChanged; released?.flags=[]
        released?.post(tap:.cghidEventTap)
        usleep(800_000)
        // Mail may ask whether to keep a reply as a draft: it is a test, so it is not kept.
        if let sheetOwner=testWindows().first {
            walk(sheetOwner) { element,role,_ in
                if role == "AXButton",["Don’t Save","Don't Save","Delete","Discard"].contains(label(element)) { AXUIElementPerformAction(element,kAXPressAction as CFString) }
            }
            usleep(500_000)
        }
        guard testWindows().count < before else { break }
        closed += 1
    }
    return "closed \(closed), left \(testWindows().count)"
}
func shapes() -> String {
    guard let app=mailApp() else { return "Mail is not running" }
    let main=attribute(app,kAXMainWindowAttribute)
    return "frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")\n"+(attribute(app,kAXWindowsAttribute) as? [AXUIElement] ?? []).map { window in
        let rect=frame(window) ?? .zero
        return "at \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)) main=\(main.map{CFEqual($0,window)} ?? false) synthetic=\(title(window).lowercased().contains("synthetic"))"
    }.joined(separator:"\n")
}

guard AXIsProcessTrusted() else { print("no Accessibility access"); exit(1) }
for step in CommandLine.arguments.dropFirst() {
    let parts=step.split(separator:":",maxSplits:1).map(String.init)
    let value=parts.count > 1 ? parts[1] : ""
    switch parts[0] {
    case "raise": print(raise(compose:value != "message"))
    case "press": print(press(value)); usleep(800_000)
    case "click":
        let numbers=value.split(separator:",").compactMap{Double($0)}
        if numbers.count == 2 { print(click(numbers[0],numbers[1])); usleep(900_000) }
    case "type": print(type(value)); usleep(500_000)
    case "key": print(key(value)); usleep(900_000)
    case "shot": print(shot(value))
    case "popovers": print(popovers())
    case "controls": print(popoverControls())
    case "find":
        // Whether the text typed by the test ended up in one of the popover's text boxes, or in the reply itself.
        var report:[String]=[]
        for window in testWindows() {
            walk(window) { element,role,_ in
                guard ["AXTextField","AXTextArea","AXWebArea","AXStaticText"].contains(role),let text=attribute(element,kAXValueAttribute) as? String,text.contains(value) else { return }
                var inside=false,parent=attribute(element,kAXParentAttribute)
                for _ in 0..<40 { guard let p=parent else { break }; if (attribute(p as! AXUIElement,kAXRoleAttribute) as? String) == "AXPopover" { inside=true; break }; parent=attribute(p as! AXUIElement,kAXParentAttribute) }
                report.append("\(role) \(inside ? "in the popover" : "in the reply window") holds it")
            }
        }
        print(report.isEmpty ? "\(value) is nowhere in the window" : report.joined(separator:"; "))
    case "ppress": print(inPopover(value,set:nil)); usleep(900_000)
    case "pset":
        let pair=value.split(separator:"=",maxSplits:1).map(String.init)
        if pair.count == 2 { print(inPopover(pair[0],set:pair[1])); usleep(700_000) }
    case "pfocus": print(inPopover(value,set:"")); usleep(500_000)
    case "wait": usleep(UInt32((Double(value) ?? 1)*1_000_000))
    case "close": print(closeAll())
    case "shapes": print(shapes())
    case "body": print(body(value))
    case "pclick":
        let numbers=value.split(separator:",").compactMap{Double($0)}
        if numbers.count == 2 { print(panelClick(numbers[0],numbers[1])); usleep(1_000_000) }
    case "pshot": print(panelShot(value))
    case "pclose":
        if let (window,_)=panelWindow(),let button=attribute(window,kAXCloseButtonAttribute) { print("panel close=\(AXUIElementPerformAction(button as! AXUIElement,kAXPressAction as CFString).rawValue)") } else { print("no panel") }
        usleep(600_000)
    case "who":
        for w in testWindows() { var send=false; walk(w) { e,r,_ in if r == "AXButton",label(e) == "Send" { send=true } }; print("synthetic window:",send ? "reply" : "message") }
    default: print("unknown step \(step)")
    }
}
