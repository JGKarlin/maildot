import AppKit
import ApplicationServices

/// Closes the Mail Dot window in Mail by pressing that window's own close button, through the Accessibility permission
/// Mail Dot already has (owner decision, 15 November 2026). Mail shows the window as a modal dialog that its extension
/// cannot close, and the dialog keeps a reply waiting and turns down a quit sent from the Dock. Only a window titled
/// "Mail Dot" is touched; no other window's title or content is kept or read further.
@MainActor enum MailDotWindowCloser {
    private static func attribute(_ element:AXUIElement,_ name:String) -> AnyObject? {
        var value:AnyObject?
        return AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success ? value : nil
    }
    /// The number of Mail Dot windows whose close button was pressed.
    @discardableResult static func closeAll() -> Int {
        guard AXIsProcessTrusted(),let mail=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first else { return 0 }
        let app=AXUIElementCreateApplication(mail.processIdentifier)
        AXUIElementSetMessagingTimeout(app,2)
        var pressed=0
        for window in (attribute(app,kAXWindowsAttribute) as? [AXUIElement]) ?? [] where (attribute(window,kAXTitleAttribute) as? String) == "Mail Dot" {
            guard let button=attribute(window,kAXCloseButtonAttribute),CFGetTypeID(button) == AXUIElementGetTypeID() else { continue }
            if AXUIElementPerformAction(button as! AXUIElement,kAXPressAction as CFString) == .success { pressed += 1 }
        }
        return pressed
    }
    /// Closes the Mail Dot windows and waits up to `seconds` for Mail to report them gone. True once none is open.
    static func closeAndWait(seconds:Double=3) async -> Bool {
        guard closeAll() > 0 else { return open() == 0 }
        let until=Date().addingTimeInterval(seconds)
        while Date() < until {
            try? await Task.sleep(for:.milliseconds(200))
            if open() == 0 { return true }
        }
        return open() == 0
    }
    /// How many Mail Dot windows Mail has open.
    static func open() -> Int {
        guard AXIsProcessTrusted(),let mail=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first else { return 0 }
        let app=AXUIElementCreateApplication(mail.processIdentifier)
        AXUIElementSetMessagingTimeout(app,2)
        return ((attribute(app,kAXWindowsAttribute) as? [AXUIElement]) ?? []).filter{ (attribute($0,kAXTitleAttribute) as? String) == "Mail Dot" }.count
    }
}
