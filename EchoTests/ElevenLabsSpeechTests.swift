import Foundation
import Testing
@testable import Echo

/// ElevenLabs reading replies (`ElevenLabsSpeech`, Settings → Voice → ElevenLabs): the request a
/// sentence goes as, and which voice each bot reads in. What it sounds like is heard on the phone.
@MainActor
struct ElevenLabsSpeechTests {
    @Test func aSentenceGoesAsAStreamOfPCMOnThePersonsKey() throws {
        let request = ElevenLabsSpeech.request("Hello there.", voice: "voice/1", speed: 1, previous: nil, key: "xi-key")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/voice%2F1/stream?output_format=pcm_24000")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "xi-key")
        let body = try JSONValue.parse(try #require(request.httpBody))
        #expect(body["text"] == .string("Hello there.") && body["model_id"] == .string(ElevenLabsSpeech.model))
        #expect(body["voice_settings"] == nil && body["previous_text"] == nil, "its own pace, nothing before it")
    }

    @Test func speedIsKeptToWhatElevenLabsTakesAndTheSentenceBeforeGoesAlong() throws {
        let fast = try JSONValue.parse(try #require(ElevenLabsSpeech.request("b", voice: "v", speed: 1.8, previous: "A.", key: "k").httpBody))
        #expect(fast["voice_settings"]?["speed"] == .number(1.2))
        #expect(fast["previous_text"] == .string("A."))
        let slow = try JSONValue.parse(try #require(ElevenLabsSpeech.request("b", voice: "v", speed: 0.5, previous: "", key: "k").httpBody))
        #expect(slow["voice_settings"]?["speed"] == .number(0.7) && slow["previous_text"] == nil)
    }

    @Test func eachBotReadsInAnElevenLabsVoiceOfItsOwn() {
        let voices = ["a", "b", "c", "d"]
        let names = ["home", "scout", "quill"]
        #expect(BotVoices.elevenLabs(for: nil, picked: [:], main: "a", available: voices, names: names) == nil, "the main agent: Redde's own")
        #expect(BotVoices.elevenLabs(for: "default", picked: [:], main: "a", available: voices, names: names) == nil)
        let given = names.compactMap { BotVoices.elevenLabs(for: $0, picked: [:], main: "a", available: voices, names: names) }
        #expect(given.count == 3 && Set(given).count == 3 && !given.contains("a"), "each its own, none Redde's")
        let picked = ["home": BotVoice(elevenLabs: "c"), "scout": BotVoice(sameAsMain: true)]
        #expect(BotVoices.elevenLabs(for: "home", picked: picked, main: "a", available: voices, names: names) == "c")
        #expect(BotVoices.elevenLabs(for: "scout", picked: picked, main: "a", available: voices, names: names) == nil, "same as Redde")
        #expect(BotVoices.elevenLabs(for: "quill", picked: picked, main: "a", available: voices, names: names).map { $0 != "c" && $0 != "a" } == true,
                "not one picked for another")
        #expect(!BotVoice(elevenLabs: "c").isAutomatic)
    }

    /// Home's settings didn't have Settings' choices (2026-10-26): a bot reads with a voice of its
    /// own, or Settings'; the main agent always with Settings'.
    @Test func eachBotCanHaveAReadingVoiceOfItsOwn() throws {
        let settings = Settings(defaults: UserDefaults(suiteName: "reader-\(UUID().uuidString)")!)
        settings.replyVoice = .elevenLabs
        settings.botVoicesHere["ops"] = BotVoice(kokoro: "bf_emma(1)+af_heart(4)+af_bella(2)", reader: .kokoro)
        #expect(settings.readingVoice(for: "ops") == .kokoro)
        #expect(settings.readingVoice(for: "scout") == .elevenLabs && settings.readingVoice(for: nil) == .elevenLabs
                && settings.readingVoice(for: "default") == .elevenLabs)
        let kept = try JSONDecoder().decode(BotVoice.self, from: JSONEncoder().encode(settings.botVoicesHere["ops"]))
        #expect(kept.reader == .kokoro && !BotVoice(reader: .onDevice).isEmpty)
        #expect(VoiceSettings.modeName(nil) == "Listen and read aloud" && VoiceSettings.modeName(.elevenLabs) == "ElevenLabs call")
    }

    @Test func theVoiceAndTheChoiceSyncAndReset() {
        let settings = Settings(defaults: UserDefaults(suiteName: "eleven-\(UUID().uuidString)")!)
        #expect(Settings.syncedKeys.contains("elevenLabsVoice"))
        settings.applySynced("replyVoice", "elevenLabs")
        settings.applySynced("elevenLabsVoice", "v9")
        #expect(settings.replyVoice == .elevenLabs && settings.elevenLabsVoice == "v9")
        settings.applySynced("replyVoice", "somethingNewer")
        #expect(settings.replyVoice == .onDevice, "a voice this version doesn't know: the built-in one")
    }
}
