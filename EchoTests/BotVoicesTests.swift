import Foundation
import Testing
@testable import Echo

/// A voice for each bot: picked, or one of its own in the language of Redde's voice, never Redde's
/// and no two alike while there are voices enough; the main agent reads in Redde's own.
struct BotVoicesTests {
    private let kokoro = ["af_heart", "af_bella", "am_adam", "am_michael", "bf_emma", "ef_dora"]
    private let names = ["default", "scout", "writer", "fixit"]

    @Test func eachBotGetsAKokoroVoiceOfItsOwnInRedde_sLanguage() {
        let voices = names.map { BotVoices.kokoro(for: $0, picked: [:], main: "af_heart", available: kokoro, names: names) }
        #expect(voices[0] == nil, "the main agent reads in Redde's own")
        let bots = voices.dropFirst().compactMap(\.self)
        #expect(bots.count == 3 && Set(bots).count == 3, "no two alike: \(bots)")
        #expect(bots.allSatisfy { ($0.hasPrefix("a") || $0.hasPrefix("b")) && $0 != "af_heart" }, "English (American or British), not Redde's: \(bots)")
        #expect(BotVoices.kokoro(for: "scout", picked: [:], main: "af_heart", available: kokoro, names: names)
                == BotVoices.kokoro(for: "scout", picked: [:], main: "af_heart", available: kokoro.reversed(), names: names.reversed()),
                "the same voice whatever order the server lists them in")
    }

    @Test func aPickedVoiceIsKeptAndTheOthersGoRoundIt() {
        let picked = ["scout": BotVoice(kokoro: "am_adam"), "fixit": BotVoice(sameAsMain: true)]
        #expect(BotVoices.kokoro(for: "scout", picked: picked, main: "af_heart", available: kokoro, names: names) == "am_adam")
        #expect(BotVoices.kokoro(for: "fixit", picked: picked, main: "af_heart", available: kokoro, names: names) == nil)
        let writer = BotVoices.kokoro(for: "writer", picked: picked, main: "af_heart", available: kokoro, names: names)
        #expect(writer != nil && writer != "am_adam", "not the picked one: \(writer ?? "none")")
        // Too few voices: they are shared rather than none given.
        #expect(BotVoices.kokoro(for: "writer", picked: [:], main: "af_heart", available: ["af_heart", "am_adam"], names: names) == "am_adam")
        #expect(BotVoices.kokoro(for: "writer", picked: [:], main: "af_heart", available: ["af_heart"], names: names) == nil, "no other: Redde's")
    }

    /// Its own speed, whatever its voice, or Redde's (asked 2026-10-23, "control voice speed for
    /// each bot"); a speed alone leaves its voice Automatic, and a record saved before speeds reads as before.
    @Test func eachBotReadsAtItsOwnSpeedOrRedde_s() throws {
        let picked = ["scout": BotVoice(speed: 1.4), "writer": BotVoice(kokoro: "am_adam", speed: 0.8), "fixit": BotVoice(sameAsMain: true)]
        #expect(BotVoices.speed(for: "scout", picked: picked, main: 1.1) == 1.4)
        #expect(BotVoices.speed(for: "writer", picked: picked, main: 1.1) == 0.8)
        #expect(BotVoices.speed(for: "fixit", picked: picked, main: 1.1) == 1.1, "none set: Redde's")
        #expect(BotVoices.speed(for: "default", picked: ["default": BotVoice(speed: 2)], main: 1.1) == 1.1, "the main agent's is Redde's")
        #expect(BotVoices.speed(for: nil, picked: picked, main: 1.1) == 1.1)
        #expect(picked["scout"]?.isAutomatic == true && picked["scout"]?.isEmpty == false)
        #expect(BotVoices.kokoro(for: "scout", picked: picked, main: "af_heart", available: kokoro, names: names) != nil, "its voice still its own")
        let old = try JSONDecoder().decode(BotVoice.self, from: Data(#"{"kokoro":"am_adam"}"#.utf8))
        #expect(old.speed == nil && old.kokoro == "am_adam")
    }

    @Test func builtInVoicesGoRoundTheBetterOnesFirst() {
        let installed = [
            SpokenLanguage.AppleVoice(identifier: "main", language: "en-US", quality: 3),
            SpokenLanguage.AppleVoice(identifier: "zoe", language: "en-US", quality: 2),
            SpokenLanguage.AppleVoice(identifier: "evan", language: "en-GB", quality: 2),
            SpokenLanguage.AppleVoice(identifier: "compact", language: "en-US", quality: 1),
            SpokenLanguage.AppleVoice(identifier: "bells", language: "en-US", quality: 1, novelty: true),
            SpokenLanguage.AppleVoice(identifier: "monica", language: "es-ES", quality: 2),
        ]
        let scout = BotVoices.onDevice(for: "scout", picked: [:], language: "en", main: "main", installed: installed, names: names)
        let writer = BotVoices.onDevice(for: "writer", picked: [:], language: "en", main: "main", installed: installed, names: names)
        let fixit = BotVoices.onDevice(for: "fixit", picked: [:], language: "en", main: "main", installed: installed, names: names)
        let given = [fixit, scout, writer].compactMap(\.self)
        #expect(Set(given).count == 3 && !given.contains("bells") && !given.contains("main") && !given.contains("monica"),
                "three bots, three English voices, none Redde's or a novelty: \(given)")
        #expect(Set([fixit, scout].compactMap(\.self)) == ["zoe", "evan"], "the better two go first, in name order: \(given)")
        #expect(BotVoices.onDevice(for: "default", picked: [:], language: "en", main: "main", installed: installed, names: names) == nil)
        #expect(BotVoices.onDevice(for: "scout", picked: ["scout": BotVoice(onDevice: "monica")], language: "es", main: nil, installed: installed, names: names) == "monica")
        #expect(BotVoices.onDevice(for: "scout", picked: ["scout": BotVoice(onDevice: "monica")], language: "en", main: "main", installed: installed, names: names) != "monica",
                "a voice picked for another language isn't the one this reply is read in")
    }
}
