import Foundation

/// The voice a bot reads its replies in, as picked for it (`Settings.botVoices`). Nothing picked
/// is Automatic: a voice of its own among those Redde reads with, as a bot has a face of its own.
nonisolated struct BotVoice: Codable, Equatable, Sendable {
    /// A built-in voice, by its identifier.
    var onDevice: String?
    /// One of the Kokoro server's voices, by its id ("am_adam").
    var kokoro: String?
    /// One of the person's ElevenLabs voices, by its id.
    var elevenLabs: String?
    /// Read in Redde's own voice, as before bots had voices.
    var sameAsMain: Bool?
    /// Which voice reads its replies (Kokoro for one bot, ElevenLabs for another); nil, the one
    /// Settings → Voice reads with. Asked 2026-10-26: Home's settings didn't have the same choices.
    var reader: Settings.ReplyVoice?
    /// How fast it reads (1 is the voice's own pace), whatever its voice; nil reads at Redde's
    /// speed (Settings → Voice → Voice speed). Asked 2026-10-23, "control voice speed for each bot".
    var speed: Double?
    /// Who holds its voice conversations, Redde or a live engine; nil as Settings → Voice →
    /// Conversation has it. Asked 2026-10-25: one bot on GPT-Live, the others as they are.
    var conversation: BotConversation?
    /// Its voice in each live engine's calls, by `LiveEngine` raw value; none for an engine, the
    /// one in Settings → Voice → Voice mode.
    var liveVoices: [String: String]?

    /// No voice picked for it: it gets one of its own (`BotVoices`).
    var isAutomatic: Bool { onDevice == nil && kokoro == nil && elevenLabs == nil && sameAsMain != true }
    /// Nothing picked at all, voice, speed or conversation: as good as no record.
    var isEmpty: Bool { isAutomatic && speed == nil && conversation == nil && (liveVoices ?? [:]).isEmpty && reader == nil }
}

/// Who holds a bot's voice conversations (`BotVoice.conversation`), as Settings → Voice →
/// Conversation does for the main agent and every bot without a choice of its own.
nonisolated enum BotConversation: String, Codable, Sendable, CaseIterable {
    case redde, gptLive, gemini, grok, elevenLabs
    var live: LiveEngine? { LiveEngine(rawValue: rawValue) }
}

/// Which voice reads a bot's words: what was picked for it, else one of its own, in the language
/// of Redde's voice and never Redde's, no two bots alike while there are voices to go round. The
/// main agent reads in Redde's own. Hermes's voice (Settings → Voice) is the server's, one for all.
nonisolated enum BotVoices {
    /// The Kokoro voice for `profile`'s words, or nil for Redde's own (`main`).
    static func kokoro(for profile: String?, picked: [String: BotVoice], main: String, available: [String], names: [String]) -> String? {
        guard let profile, profile != "default", picked[profile]?.sameAsMain != true else { return nil }
        if let id = picked[profile]?.kokoro, available.isEmpty || KokoroBlend.voices(in: id).allSatisfy(available.contains) { return id }
        guard let language = SpokenLanguage.kokoroLanguage(of: main) else { return nil }
        let pool = available.filter { $0 != main && SpokenLanguage.kokoroLanguage(of: $0) == language }
        let unpicked = names.filter { picked[$0]?.kokoro == nil && picked[$0]?.sameAsMain != true }
        return assign(profile, names: unpicked, tiers: [pool], taken: picked.values.compactMap(\.kokoro))
    }

    /// The ElevenLabs voice for `profile`'s words, or nil for Redde's own (`main`): what was picked
    /// for it, else one of the account's other voices of its own. ElevenLabs' voices speak every
    /// language, so there is one pool.
    static func elevenLabs(for profile: String?, picked: [String: BotVoice], main: String, available: [String], names: [String]) -> String? {
        guard let profile, profile != "default", picked[profile]?.sameAsMain != true else { return nil }
        if let id = picked[profile]?.elevenLabs, available.isEmpty || available.contains(id) { return id }
        let unpicked = names.filter { picked[$0]?.elevenLabs == nil && picked[$0]?.sameAsMain != true }
        return assign(profile, names: unpicked, tiers: [available.filter { $0 != main }], taken: picked.values.compactMap(\.elevenLabs))
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

/// A Kokoro voice written as a blend of the server's own: "bf_emma(1)+af_heart(4)+af_bella(2)", each
/// voice's weight in brackets (one where there are none), as Kokoro-FastAPI takes it; the first
/// voice's letter says how it is pronounced (b: British). Redde's own voice is one (`am_onyx(2)+bm_george(1)`);
/// a bot's may be one too (asked 2026-10-26, Home's: "With a little Emma").
nonisolated enum KokoroBlend {
    /// The voices it is made of, in order: one for a plain voice.
    static func voices(in id: String) -> [String] {
        id.split(separator: "+").map { part in
            String(part.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    /// Whether `id` is a blend Kokoro can make of `available`: two voices or more, each of them
    /// there, each weight a number.
    static func isBlend(_ id: String, of available: [String]) -> Bool {
        let parts = id.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            let name = String(part.prefix { $0 != "(" })
            guard available.contains(name) else { return false }
            let rest = part.dropFirst(name.count)
            guard !rest.isEmpty else { return true }
            guard rest.hasPrefix("("), rest.hasSuffix(")"), let weight = Double(rest.dropFirst().dropLast()) else { return false }
            return weight > 0
        }
    }
}
