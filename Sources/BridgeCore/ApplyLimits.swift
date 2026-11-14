import Foundation

/// What Mail Dot can place in a Mail draft by typing. A proposal is checked against these limits when it is
/// made, so that Dot learns at once that a text cannot be applied, instead of after the draft was touched.
public enum ApplyLimits {
    public static let maximumUTF16 = 8192
    public static let maximumUTF8 = 32768
    public static let description = "Native editing supports plain reply text up to 8,192 UTF-16 units, with line breaks and no tabs, control characters or attachment objects."

    /// The refusal for a text that cannot be typed, or nil if it can.
    public static func refusal(for text: String) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= maximumUTF16,
              text.utf8.count <= maximumUTF8, !text.contains("\u{fffc}"),
              text.unicodeScalars.allSatisfy({ $0.value == 10 || $0.value >= 32 && !(127...159).contains($0.value) }) else {
            return description
        }
        return nil
    }
}
