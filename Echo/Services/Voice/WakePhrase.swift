import Foundation

/// One agent's wake phrase as set (`Settings.wakePhrases`): whether it wakes Redde, and its words
/// where they aren't "Hey <name>". Nothing set: the main agent's is on, a bot's off.
nonisolated struct WakePhrase: Codable, Equatable, Sendable {
    var on: Bool
    /// Nil or blank: "Hey <name>".
    var phrase: String?
}

/// Who a wake phrase wakes: the main agent (`profile` nil) or a bot (its profile), and the words.
nonisolated struct WakeTarget: Equatable, Sendable {
    var phrase: String
    var profile: String?
    var name: String
}

/// Finding a wake phrase in what the recogniser made of someone talking: at the start of it (a
/// word or two of something else allowed before it, the second of audio from before the voice was
/// noticed), each word as written or sounding like it ("Saul" for Sol, "hi" for hey: Soundex, the
/// first letter kept), so the recogniser's spelling of a name doesn't decide.
nonisolated enum WakeMatch {
    /// Words heard before the phrase that still let it count.
    static let lead = 2

    /// The phrase heard (the earliest, the longest where two start together), and what was said
    /// after it, as said ("turn the lights off"), "" for nothing.
    static func match(_ text: String, targets: [WakeTarget]) -> (target: WakeTarget, rest: String)? {
        let heard = words(text)
        var best: (target: WakeTarget, start: Int, count: Int)?
        for target in targets {
            let phrase = words(target.phrase).map(\.word)
            guard !phrase.isEmpty, heard.count >= phrase.count else { continue }
            for start in 0 ... min(lead, heard.count - phrase.count) {
                let said = heard[start ..< start + phrase.count].map(\.word)
                guard zip(said, phrase).allSatisfy({ sounds($0, like: $1) }) else { continue }
                if best.map({ start < $0.start || (start == $0.start && phrase.count > $0.count) }) ?? true {
                    best = (target, start, phrase.count)
                }
                break
            }
        }
        guard let best else { return nil }
        let end = heard[best.start + best.count - 1].range.upperBound
        let rest = text[end...].drop { $0.isWhitespace || $0.isPunctuation }
        return (best.target, String(rest).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The words of `text`, as compared (lower case, accents and widths folded), each with where
    /// it is.
    static func words(_ text: String) -> [(word: String, range: Range<String.Index>)] {
        var found: [(word: String, range: Range<String.Index>)] = []
        var start: String.Index?
        var index = text.startIndex
        func close(at end: String.Index) {
            guard let begun = start else { return }
            found.append((fold(text[begun ..< end]), begun ..< end))
            start = nil
        }
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber || character == "'" || character == "’" {
                if start == nil { start = index }
            } else {
                close(at: index)
            }
            index = text.index(after: index)
        }
        close(at: text.endIndex)
        return found
    }

    /// The same word, or one the recogniser could have written for it: the same Soundex code and
    /// near the same length. "Sol" is heard as Saul, Soul or Sole; "so" is not it.
    static func sounds(_ heard: String, like word: String) -> Bool {
        if heard == word { return true }
        guard heard.count >= 2, word.count >= 2, abs(heard.count - word.count) <= 2 else { return false }
        let code = soundex(word)
        return !code.isEmpty && soundex(heard) == code
    }

    /// American Soundex: the first letter, then up to three digits for the consonants that follow.
    /// Empty for a word with no Latin letter in it, which then has to be heard as written.
    static func soundex(_ word: String) -> String {
        let letters = word.lowercased().filter { $0.isASCII && $0.isLetter }
        guard let first = letters.first else { return "" }
        var code = first.uppercased()
        var previous = digit(first)
        for letter in letters.dropFirst() {
            let current = digit(letter)
            if let current, current != previous { code.append(current) }
            // H and W don't part two letters of one sound; a vowel does.
            if letter != "h", letter != "w" { previous = current }
            if code.count == 4 { break }
        }
        return code.padding(toLength: 4, withPad: "0", startingAt: 0)
    }

    private static func digit(_ letter: Character) -> Character? {
        switch letter {
        case "b", "f", "p", "v": "1"
        case "c", "g", "j", "k", "q", "s", "x", "z": "2"
        case "d", "t": "3"
        case "l": "4"
        case "m", "n": "5"
        case "r": "6"
        default: nil
        }
    }

    private static func fold(_ word: Substring) -> String {
        word.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
    }
}

extension Settings {
    /// The phrase `name` is woken with unless another is set.
    static func defaultWakePhrase(for name: String) -> String {
        String(localized: "Hey \(name)", comment: "The wake phrase an agent has unless one is set (Settings → Voice → Wake Phrase)")
    }

    /// The agents of the server in use, as Wake Phrase lists them: the main agent (key "default")
    /// first, then each bot not hidden, as the bot list has them. Bots only where the phone has
    /// this connection's roster (`BotDirectory`).
    var wakeAgents: [(key: String, profile: String?, name: String)] {
        var agents: [(key: String, profile: String?, name: String)] = [("default", nil, headerTitle)]
        if BotDirectory.available(self), BotDirectory.shared.key == connectionKey, let roster = BotDirectory.shared.roster {
            for bot in roster.listed(in: botOrderHere) where !bot.isDefault && !bot.isHidden {
                agents.append((bot.name, bot.name, bot.label(mainName: headerTitle)))
            }
        }
        return agents
    }

    /// `key`'s phrase as set, or as it is when nothing is.
    func wakePhrase(for key: String) -> WakePhrase {
        wakePhrasesHere[key] ?? WakePhrase(on: key == "default")
    }

    /// The words that wake `name` (`key`'s phrase, or the default).
    func wakeWords(for key: String, name: String) -> String {
        let set = wakePhrase(for: key).phrase?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return set.isEmpty ? Self.defaultWakePhrase(for: name) : set
    }

    /// The phrases that are on, for the listener.
    var wakeTargets: [WakeTarget] {
        wakeAgents.filter { wakePhrase(for: $0.key).on }
            .map { WakeTarget(phrase: wakeWords(for: $0.key, name: $0.name), profile: $0.profile, name: $0.name) }
    }
}
