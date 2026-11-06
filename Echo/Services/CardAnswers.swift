import Foundation

/// The cards answered on this phone, and in the transcripts read back (`CardNote`), by their key
/// (`ReplyCard.key`): what was said, so a card shows how it was answered, and a checklist's ticks
/// as they are left. Kept in the app's defaults, the newest `most`.
@MainActor
@Observable
final class CardAnswers {
    static let shared = CardAnswers()
    private(set) var said: [String: String]
    private(set) var ticks: [String: [Int]]

    private static let saidKey = "cardAnswers", ticksKey = "cardTicks"
    static let most = 300
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        said = defaults.dictionary(forKey: Self.saidKey) as? [String: String] ?? [:]
        ticks = (defaults.dictionary(forKey: Self.ticksKey) as? [String: [Int]]) ?? [:]
    }

    func record(_ key: String, said text: String) {
        guard !key.isEmpty, said[key] != text else { return }
        said[key] = text
        if said.count > Self.most { said.removeValue(forKey: said.keys.sorted().first ?? "") }
        defaults.set(said, forKey: Self.saidKey)
    }

    /// A card as if never answered: a demo seeded again (`-echo.demoCards purchase`) shows its chips.
    func forget(_ key: String) {
        guard said.removeValue(forKey: key) != nil else { return }
        defaults.set(said, forKey: Self.saidKey)
    }

    /// From a transcript read off the main actor.
    nonisolated static func record(_ key: String, said text: String) {
        Task { @MainActor in shared.record(key, said: text) }
    }

    /// What the card asked, for over its answer when the chat is read back (`AnsweredQuestions`).
    func recordQuestion(_ key: String, _ question: String?) {
        guard !key.isEmpty, let question else { return }
        var asked = defaults.dictionary(forKey: Self.questionsKey) as? [String: String] ?? [:]
        guard asked[key] != question else { return }
        asked[key] = question
        if asked.count > Self.most { asked.removeValue(forKey: asked.keys.sorted().first ?? "") }
        defaults.set(asked, forKey: Self.questionsKey)
    }

    /// From a transcript read off the main actor: UserDefaults is safe from any thread.
    nonisolated static func question(for key: String, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: questionsKey) as? [String: String])?[key]
    }

    nonisolated private static let questionsKey = "cardQuestions"

    func setTicks(_ key: String, _ done: [Int]) {
        ticks[key] = done
        if ticks.count > Self.most { ticks.removeValue(forKey: ticks.keys.sorted().first ?? "") }
        defaults.set(ticks, forKey: Self.ticksKey)
    }
}
