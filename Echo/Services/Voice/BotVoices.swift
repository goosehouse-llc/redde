import Foundation

/// The voice a bot reads its replies in, as picked for it (`Settings.botVoices`). Nothing picked
/// is Automatic: a voice of its own among those Redde reads with, as a bot has a face of its own.
nonisolated struct BotVoice: Codable, Equatable, Sendable {
    /// A built-in voice, by its identifier.
    var onDevice: String?
    /// One of the Kokoro server's voices, by its id ("am_adam").
    var kokoro: String?
    /// Read in Redde's own voice, as before bots had voices.
    var sameAsMain: Bool?
    /// How fast it reads (1 is the voice's own pace), whatever its voice; nil reads at Redde's
    /// speed (Settings → Voice → Voice speed). Asked 2026-10-23, "control voice speed for each bot".
    var speed: Double?

    /// No voice picked for it: it gets one of its own (`BotVoices`).
    var isAutomatic: Bool { onDevice == nil && kokoro == nil && sameAsMain != true }
    /// Nothing picked at all, voice or speed: as good as no record.
    var isEmpty: Bool { isAutomatic && speed == nil }
}

/// Which voice reads a bot's words: what was picked for it, else one of its own, in the language
/// of Redde's voice and never Redde's, no two bots alike while there are voices to go round. The
/// main agent reads in Redde's own. Hermes's voice (Settings → Voice) is the server's, one for all.
nonisolated enum BotVoices {
    /// The Kokoro voice for `profile`'s words, or nil for Redde's own (`main`).
    static func kokoro(for profile: String?, picked: [String: BotVoice], main: String, available: [String], names: [String]) -> String? {
        guard let profile, profile != "default", picked[profile]?.sameAsMain != true else { return nil }
        if let id = picked[profile]?.kokoro, available.isEmpty || available.contains(id) { return id }
        guard let language = SpokenLanguage.kokoroLanguage(of: main) else { return nil }
        let pool = available.filter { $0 != main && SpokenLanguage.kokoroLanguage(of: $0) == language }
        let unpicked = names.filter { picked[$0]?.kokoro == nil && picked[$0]?.sameAsMain != true }
        return assign(profile, names: unpicked, tiers: [pool], taken: picked.values.compactMap(\.kokoro))
    }

    /// The built-in voice for `profile`'s words in `language` ("en"), or nil for Redde's own
    /// (`main`, the voice Redde reads that language in). The better voices installed for it go
    /// round first (enhanced and premium), then the others: a bot heard apart from the rest is
    /// worth more than a finer voice.
    static func onDevice(for profile: String?, picked: [String: BotVoice], language: String, main: String?,
                         installed: [SpokenLanguage.AppleVoice], names: [String]) -> String? {
        guard let profile, profile != "default", picked[profile]?.sameAsMain != true else { return nil }
        let speaking = installed.filter { SpokenLanguage.base($0.language) == language && !$0.novelty }
        if let id = picked[profile]?.onDevice, speaking.contains(where: { $0.identifier == id }) { return id }
        let others = speaking.filter { $0.identifier != main }
        let tiers = [others.filter { $0.quality >= 2 }, others.filter { $0.quality < 2 }].map { $0.map(\.identifier) }
        let unpicked = names.filter { picked[$0]?.onDevice == nil && picked[$0]?.sameAsMain != true }
        return assign(profile, names: unpicked, tiers: tiers, taken: picked.values.compactMap(\.onDevice))
    }

    /// `name`'s voice: the one its name falls on in the first of `tiers` with a voice free, or the
    /// next free one there, going through the roster's names in order so no two share while there
    /// are voices enough; past that, the one its name falls on among them all. `taken` are picked
    /// ones, which none is given.
    static func assign(_ name: String, names: [String], tiers: [[String]], taken: [String]) -> String? {
        let tiers = tiers.map { $0.sorted() }.filter { !$0.isEmpty }
        let all = tiers.flatMap(\.self)
        guard !all.isEmpty else { return nil }
        var used = Set(taken.filter(all.contains))
        for other in Set(names + [name]).subtracting(["default"]).sorted() {
            let given: String
            if let tier = tiers.first(where: { $0.contains { !used.contains($0) } }) {
                var index = Int(hash(other) % UInt64(tier.count))
                while used.contains(tier[index]) { index = (index + 1) % tier.count }
                given = tier[index]
            } else {
                given = all[Int(hash(other) % UInt64(all.count))]
            }
            if other == name { return given }
            used.insert(given)
        }
        return nil
    }

    /// How fast `profile`'s words are read: its own speed where one was set, else Redde's (`main`).
    static func speed(for profile: String?, picked: [String: BotVoice], main: Double) -> Double {
        guard let profile, profile != "default", let own = picked[profile]?.speed, own > 0 else { return main }
        return own
    }

    /// FNV-1a: the same voice for the same name on every device and every launch.
    static func hash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }
}
