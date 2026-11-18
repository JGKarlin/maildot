import AppKit
import ApplicationServices
import BridgeCore
import os

/// Closes the Mail Dot window when the owner clicks one of Mail's other windows, and passes that click on to Mail (see
/// OutsideClick). The click is held back from Mail until the window has closed: Mail refuses a click while its dialog is
/// open and plays the alert sound (owner report, 15 November 2026). Only the place of a click and the shape of Mail's
/// windows are looked at: their frames, kinds and owner. Nothing on screen is read. It uses the Accessibility permission
/// Mail Dot already has.
@MainActor final class MailDotOutsideClick {
    static let shared=MailDotOutsideClick()
    private static let log=Logger(subsystem:"org.jgkarlin.MailBridge",category:"window")
    /// Marks the click handed back to Mail, so it is let through.
    nonisolated static let replayMark:Int64=0x4D61696C446F74
    private var tap:CFMachPort?
    private var monitor:Any?
    private var working=false
    /// Kept fresh twice a second while Mail runs, so that the decision on a click takes no time: where the Mail Dot
    /// window is, and where Mail's ordinary windows are, in screen points with the origin at the top left.
    nonisolated(unsafe) static var dialogFrame:CGRect?
    nonisolated(unsafe) static var standardFrames:[CGRect]=[]
    nonisolated(unsafe) static var mailProcess:Int32=0
    nonisolated(unsafe) static var swallowingUp=false

    func start() {
        guard tap == nil,monitor == nil else { return }
        Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { _ in MainActor.assumeIsolated { MailDotOutsideClick.shared.refresh() } }
        if !installTap() {
            // Without the tap the click still closes the window, but Mail sees it first and sounds its alert. The same
            // test decides: only a click on one of Mail's other windows closes it. Until 18 November 2026 this handler
            // closed the window for a click anywhere, the window itself included: it runs when Mail Dot starts without
            // Accessibility, as on a new installation, and from the moment the permission was given no button in the
            // Mail Dot window could be pressed until Mail Dot was started again.
            monitor=NSEvent.addGlobalMonitorForEvents(matching:.leftMouseDown) { event in
                let place=event.cgEvent?.location ?? .zero
                guard MailDotOutsideClick.outside(place) else { return }
                Task { @MainActor in await MailDotOutsideClick.shared.closeAndReplay(at:place,replay:true) }
            }
        }
    }
    /// The tap that holds a click back from Mail. It needs the Accessibility permission, so it is tried again from
    /// `refresh` once the permission is there, and the simpler handler is then taken away.
    @discardableResult private func installTap() -> Bool {
        guard tap == nil else { return true }
        let mask=CGEventMask(1 << CGEventType.leftMouseDown.rawValue) | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        guard let port=CGEvent.tapCreate(tap:.cgSessionEventTap,place:.headInsertEventTap,options:.defaultTap,eventsOfInterest:mask,callback:{ _,type,event,_ in
            MailDotOutsideClick.handle(type,event)
        },userInfo:nil) else { return false }
        tap=port
        let source=CFMachPortCreateRunLoopSource(nil,port,0)
        CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes)
        CGEvent.tapEnable(tap:port,enable:true)
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor=nil }
        return true
    }
    /// Whether a click at this point is on one of Mail's ordinary windows and outside the open Mail Dot window.
    nonisolated static func outside(_ point:CGPoint) -> Bool {
        guard let dialog=dialogFrame,!dialog.contains(point),standardFrames.contains(where:{ $0.contains(point) }) else { return false }
        return frontOwner(at:point) == mailProcess
    }

    /// Decides on one click, at once. A click on one of Mail's ordinary windows while the Mail Dot window is open is held
    /// back, along with its release; the window is closed and the click handed to Mail again.
    nonisolated private static func handle(_ type:CGEventType,_ event:CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor in if let port=MailDotOutsideClick.shared.tap { CGEvent.tapEnable(tap:port,enable:true) } }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == replayMark { return Unmanaged.passUnretained(event) }
        if type == .leftMouseUp {
            if swallowingUp { swallowingUp=false; return nil }
            return Unmanaged.passUnretained(event)
        }
        let point=event.location
        guard outside(point) else { return Unmanaged.passUnretained(event) }
        swallowingUp=true
        Task { @MainActor in await MailDotOutsideClick.shared.closeAndReplay(at:point,replay:true) }
        return nil
    }

    /// The process owning the frontmost ordinary window under a point, by owner and layer alone.
    nonisolated private static func frontOwner(at point:CGPoint) -> Int32? {
        let windows=(CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]]) ?? []
        for window in windows {
            guard let bounds=window[kCGWindowBounds as String] as? NSDictionary,let rect=CGRect(dictionaryRepresentation:bounds as CFDictionary),
                  rect.contains(point),((window[kCGWindowAlpha as String] as? Double) ?? 1) > 0 else { continue }
            guard (window[kCGWindowLayer as String] as? Int) ?? 0 == 0 else { return nil }
            return (window[kCGWindowOwnerPID as String] as? Int).map(Int32.init)
        }
        return nil
    }

    private func attribute(_ element:AXUIElement,_ name:String) -> AnyObject? {
        var value:AnyObject?
        return AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success ? value : nil
    }
    private func frame(_ window:AXUIElement) -> CGRect? {
        var origin=CGPoint.zero,size=CGSize.zero
        guard let position=attribute(window,kAXPositionAttribute as String),let extent=attribute(window,kAXSizeAttribute as String),
              AXValueGetValue(position as! AXValue,.cgPoint,&origin),AXValueGetValue(extent as! AXValue,.cgSize,&size) else { return nil }
        return CGRect(origin:origin,size:size)
    }

    /// Where the Mail Dot window and Mail's ordinary windows are now. No title is kept and no content is read.
    private func refresh() {
        guard AXIsProcessTrusted() else { Self.dialogFrame=nil; Self.standardFrames=[]; return }
        // The permission may have been given since Mail Dot started (setup's first step): the tap is set up now.
        if tap == nil { installTap() }
        guard let mail=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first else {
            Self.dialogFrame=nil; Self.standardFrames=[]; return
        }
        let app=AXUIElementCreateApplication(mail.processIdentifier)
        AXUIElementSetMessagingTimeout(app,0.5)
        var dialog:CGRect?,standard:[CGRect]=[]
        for window in (attribute(app,kAXWindowsAttribute as String) as? [AXUIElement]) ?? [] {
            if (attribute(window,kAXTitleAttribute as String) as? String) == "Mail Dot" { dialog=frame(window); continue }
            if (attribute(window,kAXSubroleAttribute as String) as? String) == (kAXStandardWindowSubrole as String),let rect=frame(window) { standard.append(rect) }
        }
        Self.mailProcess=mail.processIdentifier; Self.dialogFrame=dialog; Self.standardFrames=standard
    }

    private func closeAndReplay(at point:CGPoint,replay:Bool) async {
        guard !working else { return }
        working=true; defer { working=false }
        guard await MailDotWindowCloser.closeAndWait(seconds:2) else {
            Self.log.error("a click elsewhere in Mail: the Mail Dot window did not close when its close button was pressed")
            return
        }
        Self.dialogFrame=nil
        Self.log.info("a click elsewhere in Mail closed the Mail Dot window; passing the click on")
        try? await Task.sleep(for:.milliseconds(120))
        for kind in [CGEventType.leftMouseDown,.leftMouseUp] {
            let event=CGEvent(mouseEventSource:nil,mouseType:kind,mouseCursorPosition:point,mouseButton:.left)
            event?.setIntegerValueField(.eventSourceUserData,value:Self.replayMark)
            event?.post(tap:.cghidEventTap)
            try? await Task.sleep(for:.milliseconds(40))
        }
    }
}
