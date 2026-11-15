import AppKit
import ApplicationServices
import BridgeCore

/// Opens Mail's Settings at Extensions for the step that turns Mail Dot on there (installer design review,
/// recommendation 11, approved by the owner on 15 November 2026). Mail offers no link to that tab, so Mail Dot,
/// at the person's press and with the Accessibility permission the step before it obtained, chooses Settings from
/// Mail's own menu and presses the Extensions tab. The checkbox and Mail's confirmation stay the person's. Wherever
/// a part of the route is not as expected, Mail is simply left open, and the step's sentence gives the way.
@MainActor enum MailExtensionsPane {
    static func open() async {
        MailExtensionStatus.openMail()
        guard AXIsProcessTrusted() else { return }
        var mail:NSRunningApplication?
        for _ in 0..<40 {
            mail=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.mail").first{ !$0.isTerminated && $0.isFinishedLaunching }
            if mail != nil { break }
            try? await Task.sleep(for:.milliseconds(500))
        }
        guard let mail,let tab=tabTitle() else { return }
        mail.activate()
        let app=AXUIElementCreateApplication(mail.processIdentifier)
        AXUIElementSetMessagingTimeout(app,2)
        // Settings may be open already, on another tab.
        if pressTab(tab,in:app) { return }
        guard let settings=settingsItem(in:app) else { return }
        guard AXUIElementPerformAction(settings,kAXPressAction as CFString) == .success else { return }
        for _ in 0..<20 {
            try? await Task.sleep(for:.milliseconds(250))
            if pressTab(tab,in:app) { return }
        }
    }

    /// The Extensions tab's title as Mail shows it, from Mail's own table of its Settings window.
    private static func tabTitle() -> String? {
        guard let mail=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.mail"),
              let data=try? Data(contentsOf:mail.appendingPathComponent("Contents/Resources/PreferencesWindow.loctable")),
              let table=try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any] else { return nil }
        let texts=table.compactMapValues{ $0 as? [String:String] }
        return MailSettingsNames.extensionsTitle(table:texts,languages:Locale.preferredLanguages)
    }
    private static func attribute(_ element:AXUIElement,_ name:String) -> AnyObject? {
        var value:AnyObject?
        return AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success ? value : nil
    }
    private static func children(_ element:AXUIElement) -> [AXUIElement] { attribute(element,kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    /// The item of Mail's own menu that opens Settings: the one with the shortcut Command-Comma, in any language.
    private static func settingsItem(in app:AXUIElement) -> AXUIElement? {
        guard let bar=attribute(app,kAXMenuBarAttribute) else { return nil }
        let menus=children(bar as! AXUIElement)
        guard menus.count > 1 else { return nil }
        for menu in children(menus[1]) {
            for item in children(menu) where (attribute(item,kAXMenuItemCmdCharAttribute) as? String) == ","
                && ((attribute(item,kAXMenuItemCmdModifiersAttribute) as? Int) ?? 0) == 0 { return item }
        }
        return nil
    }
    /// Presses the tab with this title in the toolbar of one of Mail's windows.
    private static func pressTab(_ title:String,in app:AXUIElement) -> Bool {
        for window in attribute(app,kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            for toolbar in children(window) where (attribute(toolbar,kAXRoleAttribute) as? String) == (kAXToolbarRole as String) {
                var stack=children(toolbar),visited=0
                while let element=stack.popLast(),visited < 200 {
                    visited += 1
                    if (attribute(element,kAXRoleAttribute) as? String) == (kAXButtonRole as String),
                       (attribute(element,kAXTitleAttribute) as? String) == title || (attribute(element,kAXDescriptionAttribute) as? String) == title {
                        return AXUIElementPerformAction(element,kAXPressAction as CFString) == .success
                    }
                    stack += children(element)
                }
            }
        }
        return false
    }
}
