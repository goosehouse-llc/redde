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

    /// A message loaded back from the server, without the note, nor the one a question asked
    /// from the car carries after it (`CarBrevity`).
    static func stripNote(_ text: String) -> String {
        let text = CarBrevity.strip(text)
        guard text.hasSuffix(".)"), let range = text.range(of: "\n\n(Reply in ", options: .backwards),
              !text[range.upperBound...].contains("\n") else { return text }
        return String(text[..<range.lowerBound])
    }
}

/// Settings → Voice → Short answers in the car: a question asked by voice while the phone is
/// with a car asks the agent for an answer short enough to follow at the wheel, two or three
/// sentences, and to offer the rest. "More" is then a question like any other, and the agent
/// carries on. Nothing is cut or summed up on the phone: the reply in the conversation is the
/// reply that was heard.
nonisolated enum CarBrevity {
    /// Added to the agent's system prompt for the turn (the Hermes API's instructions, an
    /// OpenAI-compatible system message).
    static let instruction = """
        The user is driving and hears this reply read aloud through the car; they can't look at a \
        screen. Answer in two or three short spoken sentences, without lists, tables, code or links. \
        If there is more worth hearing, end by asking whether they want it, and when they say "more" \
        or "go on", carry on from where you stopped. If they ask for something to be read out in \
        full, read it.
        """

    /// The Hermes Dashboard takes no instructions with a message, so the request rides on the
    /// message itself, after a reply-language note if there is one. Other clients see it; Redde
    /// hides it (`strip`).
    static let note = "\n\n(I'm driving and will hear this read aloud: answer in two or three short spoken sentences, and ask whether I want more.)"

    /// A message loaded back from the server, without the note.
    static func strip(_ text: String) -> String {
        text.hasSuffix(note) ? String(text.dropLast(note.count)) : text
    }
}
