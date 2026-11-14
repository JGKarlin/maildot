import Foundation

/// How long a message in Mail may be for Mail Dot to read it and verify its own insertion. A long thread
/// with many quoted replies runs well past 64 K characters (seen 12 November 2026 on a real reply, which
/// Mail Dot then refused to read), so the bound is set for real threads, not for a prototype.
public enum MailBodyLimits {
    /// UTF-16 units, as Mail's Accessibility reports a body's length.
    public static let characters = 262_144
    public static let utf8Bytes = 1_048_576
}
