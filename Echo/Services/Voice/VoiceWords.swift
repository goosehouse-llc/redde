import Foundation
import os

/// The words Redde listens for in the language it listens in (Settings → Voice → Listening
/// language), heard beside the English ones `StopPhrase`, `SpokenRequest`, `StopWord` and
/// `Backchannel` keep, which work whatever the language: a German speaker's "stopp" and "stop"
/// both stop. One table per language in `VoiceWords.json` (written 2026-10-27); a language
/// without one has the English alone.
///
/// Also where what Redde says aloud is looked up (`bundle`): in the listening language, not the
/// screen's, so the voice reading it speaks it.
nonisolated struct VoiceWords: Equatable, Sendable {
    /// The listening language as Redde has it ("de-DE", "zh-TW").
    let locale: Locale
    /// Whether it has words of its own, beside the English.
    var hasTable = false
    /// Whole utterances that end the conversation, as `StopPhrase` has them, and as written,
    /// in the table's order (for Settings → Voice → Stop phrases).
    var stop: Set<String> = []
    var listedStop: [String] = []
    /// Polite words peeled before and after an answer or a stop phrase, longest first.
    var before: [String] = []
    var after: [String] = []
    /// The answers to an approval: whole utterances only.
    var yes: Set<String> = []
    var no: Set<String> = []
    /// The words the screen and the voice ask for, as written ("genehmigen", "ablehnen").
    var approveWord = "approve"
    var denyWord = "deny"
    /// Every way of saying choice one to ten; `spokenNumbers` are the ones Redde reads out.
    var numbers: [[String]] = []
    var spokenNumbers: [String] = SpokenRequest.numbers
    /// Peeled before and after a number ("nummer zwei", "二番"), longest first.
    var numberBefore: [String] = []
    var numberAfter: [String] = []
    /// Words that stop a reply wherever they are said, and the car's skip, each as its words.
    var interrupt: [[String]] = []
    var skip: [[String]] = []
    /// Said right before one of those, they mean the opposite ("nicht stoppen", "别停").
    var negations: Set<String> = []
    /// The small sounds of someone listening (`Backchannel`).
    var sounds: Set<String> = []

    init(locale: Locale) { self.locale = locale }

    /// The listening language's table: what the matchers use unless they are handed another.
    /// Made the first time something listens, not as Redde starts: launching costs nothing, and
    /// English never reads `VoiceWords.json` at all.
    static var current: VoiceWords {
        state.withLock { state in
            if let words = state.words { return words }
            let words = table(for: state.locale)
            state.words = words
            return words
        }
    }

    /// Settings → Voice → Listening language changed (or Redde started): its table from now on.
    static func listen(in locale: Locale) {
        state.withLock { $0 = (locale, nil) }
    }

    /// `locale`'s table, or English alone where there is none.
    static func table(for locale: Locale) -> VoiceWords {
        guard let code = code(of: locale), code != "en", let file = tables[code] else { return VoiceWords(locale: locale) }
        return VoiceWords(locale: locale, file: file)
    }

    private static let state = OSAllocatedUnfairLock<(locale: Locale, words: VoiceWords?)>(initialState: (Locale(identifier: "en"), nil))

    /// The table a locale reads: its language, Norwegian's two written forms and "no" as one.
    static func code(of locale: Locale) -> String? {
        guard let language = locale.language.languageCode?.identifier.lowercased() else { return nil }
        return ["no", "nn"].contains(language) ? "nb" : language
    }

    // MARK: - What Redde says

    /// The localization what Redde says aloud comes from: the listening language's when Redde has
    /// one ("zh-TW" reads zh-Hant), else English, never the screen's. Found once per language.
    var bundle: Bundle {
        let key = locale.identifier
        if let known = Self.bundles.withLock({ $0[key] }) { return known }
        let found = Self.bundle(for: locale)
        Self.bundles.withLock { $0[key] = found }
        return found
    }

    private static let bundles = OSAllocatedUnfairLock<[String: Bundle]>(initialState: [:])

    private static func bundle(for locale: Locale) -> Bundle {
        let available = Bundle.main.localizations.filter { $0 != "Base" }
        let chosen = Bundle.preferredLocalizations(from: available, forPreferences: [locale.identifier]).first
        let match = chosen.flatMap { chosen in
            SpokenLanguage.base(chosen) == SpokenLanguage.base(locale.identifier) ? chosen : nil
        } ?? "en"
        return Bundle.main.path(forResource: match, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }

    /// Choices said as a list in the listening language: "one, two or three". (Not a
    /// `ListFormatter`'s: it only says "and".)
    func spokenList(_ words: [String]) -> String {
        guard words.count > 1 else { return words.first ?? "" }
        guard hasTable else { return words.dropLast().joined(separator: ", ") + " or " + words[words.count - 1] }
        let comma = ["ja", "zh"].contains(SpokenLanguage.base(locale.identifier)) ? "、" : ", "
        let rest = words.dropLast().joined(separator: comma), last = words[words.count - 1]
        return String(localized: "\(rest) or \(last)", bundle: bundle,
                      comment: "Said aloud in voice mode: the end of a list of choices, “one, two or three” (the first value is the others, already joined)")
    }

    // MARK: - Numbers

    /// The choice `said` names, one to ten, by the table's words ("nummer zwei", "二番目", "2번"),
    /// or nil. (English's are `SpokenRequest.number`'s.)
    func number(_ said: String) -> Int? {
        // Whole forms first ("두 번째" is listed as it is), then with a word around it peeled.
        var text = said
        while true {
            if let index = numbers.firstIndex(where: { $0.contains(text) }) { return index + 1 }
            if let n = Int(text) { return (1 ... 10).contains(n) ? n : nil }
            guard let peeled = Self.peel(text, leading: numberBefore) ?? Self.peel(text, trailing: numberAfter) else { return nil }
            text = peeled
        }
    }

    // MARK: - Peeling

    /// `text` without the first of `words` that starts it, as a word of its own, or straight
    /// against what follows where the word is written without spaces (Japanese, Chinese). Nil
    /// when none does, or when nothing would be left.
    static func peel(_ text: String, leading words: [String]) -> String? {
        for word in words {
            if text.hasPrefix(word + " ") { return String(text.dropFirst(word.count + 1)) }
            if isWide(word), text.hasPrefix(word), text.count > word.count { return String(text.dropFirst(word.count)) }
        }
        return nil
    }

    static func peel(_ text: String, trailing words: [String]) -> String? {
        for word in words {
            if text.hasSuffix(" " + word) { return String(text.dropLast(word.count + 1)) }
            if isWide(word), text.hasSuffix(word), text.count > word.count { return String(text.dropLast(word.count)) }
        }
        return nil
    }

    /// Written without spaces between words: Chinese, Japanese (and Korean's syllables, which a
    /// counter like "번" follows directly).
    static func isWide(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value >= 0x2E80 && $0.properties.isAlphabetic }
    }

    // MARK: - The tables

    /// One language's words as `VoiceWords.json` has them.
    private struct File: Decodable, Sendable {
        var stop, before, after, yes, no: [String]
        var numbers: [[String]]
        var numberBefore, numberAfter, interrupt, skip, negations, sounds: [String]
    }

    private static let tables: [String: File] = {
        guard let url = Bundle.main.url(forResource: "VoiceWords", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let tables = try? JSONDecoder().decode([String: File].self, from: data) else { return [:] }
        return tables
    }()

    /// Every word compared as what's heard is: `StopPhrase.normalize`d (lowercase, accents and
    /// width folded, no punctuation); the peeled ones longest first.
    private init(locale: Locale, file: File) {
        self.locale = locale
        hasTable = true
        let plain = { (words: [String]) in words.map(StopPhrase.normalize).filter { !$0.isEmpty } }
        let longestFirst = { (words: [String]) in plain(words).sorted { $0.count > $1.count } }
        stop = Set(plain(file.stop))
        listedStop = file.stop
        before = longestFirst(file.before)
        after = longestFirst(file.after)
        yes = Set(plain(file.yes))
        no = Set(plain(file.no))
        // Chinese has one table for both scripts, written Simplified first: a Traditional
        // listener is asked for 拒絕, not 拒绝.
        let script = { (word: String) in
            locale.language.script == .hanTraditional ? word.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? word : word
        }
        approveWord = script(file.yes.first ?? approveWord)
        denyWord = script(file.no.first ?? denyWord)
        numbers = file.numbers.map(plain)
        if file.numbers.count == 10, file.numbers.allSatisfy({ !$0.isEmpty }) { spokenNumbers = file.numbers.map { script($0[0]) } }
        numberBefore = longestFirst(file.numberBefore)
        numberAfter = longestFirst(file.numberAfter)
        interrupt = file.interrupt.map(StopWord.words).filter { !$0.isEmpty }
        skip = file.skip.map(StopWord.words).filter { !$0.isEmpty }
        negations = Set(file.negations.flatMap(StopWord.words))
        sounds = Set(file.sounds.flatMap(Backchannel.tokens))
    }
}
