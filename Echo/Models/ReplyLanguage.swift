import Foundation

/// Settings → Voice → Reply language: ask the agent to answer in one language, whatever the user
/// writes or speaks in. Empty is Automatic: nothing is sent, and the model answers in whatever
/// language it's addressed in.
nonisolated enum ReplyLanguage {
    /// The languages offered, as ISO codes. Most models write these well.
    static let codes = [
        "ar", "bg", "ca", "cs", "da", "de", "el", "en", "es", "et", "fa", "fi", "fr", "he", "hi", "hr", "hu",
        "id", "it", "ja", "ko", "lt", "lv", "ms", "nb", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sr", "sv",
        "sw", "ta", "th", "tl", "tr", "uk", "ur", "vi", "zh",
    ]

    /// For the model: the name in English, and in the language itself ("Dutch (Nederlands)").
    static func name(_ code: String) -> String {
        let english = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        guard let native = Locale(identifier: code).localizedString(forLanguageCode: code),
              native.lowercased() != english.lowercased() else { return english }
        return "\(english) (\(native))"
    }

    /// For the person: the name in the iPhone's language.
    static func displayName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized(with: .current) ?? code
    }

    /// Added to the agent's system prompt (the Hermes API's instructions, an OpenAI-compatible
    /// system message).
    static func instruction(_ code: String) -> String {
        "Always reply in \(name(code)), whatever language the user writes or speaks in, unless they ask for another language."
    }

    /// The Hermes Dashboard takes no instructions with a message, so the request rides on the
    /// message itself. Other clients see it; Redde hides it (`stripNote`).
    static func note(_ code: String) -> String { "\n\n(Reply in \(name(code)).)" }

    /// A message loaded back from the server, without the note.
    static func stripNote(_ text: String) -> String {
        guard text.hasSuffix(".)"), let range = text.range(of: "\n\n(Reply in ", options: .backwards),
              !text[range.upperBound...].contains("\n") else { return text }
        return String(text[..<range.lowerBound])
    }
}
