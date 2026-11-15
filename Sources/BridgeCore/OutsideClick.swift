import Foundation
import CoreGraphics

/// The Mail Dot window is a dialog Mail keeps in front of its other windows, and Mail ignores a click on them while it
/// is open, though the window looks free-standing. A click on one of Mail's ordinary windows therefore closes the Mail
/// Dot window and is passed on to Mail, so one click on another message closes it and selects that message (owner
/// decision, 15 November 2026). A click in another app, on a menu, or on the Mail Dot window and its own popovers
/// leaves it open.
public enum OutsideClick {
    /// What is known of the window under the pointer, by shape alone.
    public struct Target: Equatable, Sendable {
        /// The process that owns the frontmost window under the click, and that window's layer (0 for ordinary windows).
        public var owner: Int32?
        public var layer: Int
        /// Whether Mail reports the thing clicked as lying in one of its ordinary windows (not a dialog or popover).
        public var onStandardMailWindow: Bool
        public init(owner: Int32?, layer: Int, onStandardMailWindow: Bool) {
            self.owner = owner; self.layer = layer; self.onStandardMailWindow = onStandardMailWindow
        }
    }
    public static func closes(_ target: Target, mail: Int32, mailDotWindowOpen: Bool) -> Bool {
        mailDotWindowOpen && target.owner == mail && target.layer == 0 && target.onStandardMailWindow
    }
    /// A point as AppKit gives the pointer (origin at the bottom left of the main screen) in the coordinates Mail's
    /// windows are measured in (origin at its top left).
    public static func flipped(_ point: CGPoint, mainScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: mainScreenHeight - point.y)
    }
}
