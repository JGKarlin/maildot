import Foundation

/// Mail opens the Mail Dot window as a modal dialog, and macOS refuses a quit sent to Mail from outside (the Dock's
/// Quit, Restart, Shut Down, Log Out) while one is open; Command-Q is not affected (seen 15 November 2026). When Mail
/// refuses such a quit, the companion posts this notice, and every Mail Dot window open in Mail closes itself so
/// that the quit can go through (owner's OK, 15 November 2026). A system-wide notice carries no data.
public enum MailQuitNotice {
    public static let name="org.jgkarlin.MailBridge.close-for-quit"
    /// The line Mail writes to the system log each time it turns a quit down for this reason.
    public static let refusalLine="Canceling termination"
    public static func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),CFNotificationName(name as CFString),nil,nil,true)
    }
    /// Whether a line of `log stream` output reports Mail turning a quit down.
    public static func isRefusal(_ text:String) -> Bool { text.contains(" Mail[") && text.contains(refusalLine) }
}
