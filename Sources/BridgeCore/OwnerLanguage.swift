import Foundation

/// The language of the owner's Mac, as Mail Dot shows it. Mail Dot's own labels follow the macOS preferred
/// languages; what Dot writes for the owner to read on the Mac (status, summaries, questions and their
/// answers) must follow the same language, while a reply itself is written in the language of the message
/// it answers.
public enum OwnerLanguage {
    /// The languages Mail Dot's interface is translated into. English is the development language.
    /// English, Japanese, and every other language on Apple's App Store localization list (13 November 2026);
    /// all but English and Japanese are machine translations not yet reviewed by native speakers.
    public static let interfaceLanguages = ["en", "ja", "ar", "bn", "ca", "cs", "da", "de", "el", "es", "es-419", "fi", "fr", "fr-CA",
        "gu", "he", "hi", "hr", "hu", "id", "it", "kn", "ko", "ml", "mr", "ms", "nb", "nl", "or", "pa", "pl", "pt-BR", "pt-PT",
        "ro", "ru", "sk", "sl", "sv", "ta", "te", "th", "tr", "uk", "ur", "vi", "zh-Hans", "zh-Hant"]

    /// The language Mail Dot's interface is shown in for these preferences: the first preferred language it
    /// is translated into, as macOS itself chooses, and English when none is.
    public static func code(preferences: [String] = Locale.preferredLanguages) -> String {
        Bundle.preferredLocalizations(from: interfaceLanguages, forPreferences: preferences).first ?? "en"
    }

    /// The language's English name, for instructions to Dot.
    public static func name(code: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: code) ?? "English"
    }

    /// What Dot is told about language with every request the owner makes from the Mac.
    public static func instruction(preferences: [String] = Locale.preferredLanguages) -> String {
        let language = name(code: code(preferences: preferences))
        return "Language: write the reply itself in the language of the message it answers. Write everything else the owner reads on the Mac (status, summary, question and numbered answers) in \(language), the language of the owner's Mac, even when the message is in another language."
    }
}
