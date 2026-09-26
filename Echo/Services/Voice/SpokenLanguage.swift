import Foundation
import NaturalLanguage

/// Which language a reply is in, and which voice should read it. Pure, so it's testable; the
/// synthesizer's and Kokoro's voice lists come in as plain values.
nonisolated enum SpokenLanguage {
    /// "es" from "es-MX", "zh" from "zh-Hans".
    static func base(_ code: String) -> String {
        String(code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
    }

    /// The base language of `text` ("es"), or nil while it's too short or too mixed to tell.
    /// Leaving `hint` (the language Redde listens in) takes more certainty, so a short English
    /// reply isn't read by a Dutch voice. (NLLanguageRecognizer's own hints are priors strong
    /// enough to call French English, so the bias lives here.)
    static func detect(_ text: String, hint: String) -> String? {
        guard text.count >= 12 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first else { return nil }
        let detected = base(language.rawValue)
        return confidence >= (detected == base(hint) ? 0.5 : 0.8) ? detected : nil
    }

    // MARK: - Apple voices

    struct AppleVoice: Equatable, Sendable {
        var identifier: String
        var language: String   // "en-US"
        var quality: Int       // AVSpeechSynthesisVoiceQuality: 1 default, 2 enhanced, 3 premium
        var novelty = false
    }

    /// The voice for `base`: prefer the `preferred` dialect ("es-MX"), then the language's home
    /// dialect ("es-ES"), then any. Within those, a premium or enhanced voice if one is installed;
    /// otherwise no identifier, and the caller asks for the system's default voice for `language`.
    /// Nil when nothing installed speaks the language.
    static func appleVoice(for base: String, preferred: String, among voices: [AppleVoice]) -> (identifier: String?, language: String)? {
        let same = voices.filter { Self.base($0.language) == base && !$0.novelty }
        guard !same.isEmpty else { return nil }
        let home = "\(base)-\(base.uppercased())"
        let dialect = [preferred, home].first { code in same.contains { $0.language == code } }
            ?? same.map(\.language).sorted()[0]
        let pool = same.filter { $0.language == dialect }
        if let best = pool.filter({ $0.quality >= 2 }).max(by: { $0.quality < $1.quality }) {
            return (best.identifier, dialect)
        }
        return (nil, dialect)
    }

    // MARK: - Kokoro voices

    /// Kokoro voice ids start with a language letter, then f/m: `ef_dora` is Spanish, female.
    static let kokoroLetters: [String: [Character]] = [
        "en": ["a", "b"], "es": ["e"], "fr": ["f"], "hi": ["h"], "it": ["i"], "ja": ["j"], "pt": ["p"], "zh": ["z"],
    ]

    /// The base language a Kokoro voice (or the first voice of a blend) speaks.
    static func kokoroLanguage(of voice: String) -> String? {
        guard let letter = voice.trimmingCharacters(in: .whitespaces).first else { return nil }
        return kokoroLetters.first { $0.value.contains(letter) }?.key
    }

    /// The Kokoro voice for `base`: the chosen one when it already speaks it, else the first
    /// available voice in that language, the same gender as the chosen one if there is one.
    /// Nil when Kokoro has no voice for the language.
    static func kokoroVoice(for base: String, current: String, available: [String]) -> String? {
        if kokoroLanguage(of: current) == base { return current }
        guard let letters = kokoroLetters[base] else { return nil }
        let matching = available.sorted().filter { voice in
            guard let letter = voice.first else { return false }
            return letters.contains(letter)
        }
        let gender = current.dropFirst().first
        return matching.first { $0.dropFirst().first == gender } ?? matching.first
    }
}
