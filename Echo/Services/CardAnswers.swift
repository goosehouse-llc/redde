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

    /// From a transcript read off the main actor.
    nonisolated static func record(_ key: String, said text: String) {
        Task { @MainActor in shared.record(key, said: text) }
    }

    func setTicks(_ key: String, _ done: [Int]) {
        ticks[key] = done
        if ticks.count > Self.most { ticks.removeValue(forKey: ticks.keys.sorted().first ?? "") }
        defaults.set(ticks, forKey: Self.ticksKey)
    }
}
