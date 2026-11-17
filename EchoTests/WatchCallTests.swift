import Foundation
import Testing
@testable import Echo

/// The live call the phone hands the watch (`WatchLink.watchLive`): a service the watch can call
/// straight over a WebSocket, with the key the phone keeps for it and the voice picked there.
@MainActor
struct WatchCallTests {
    private func settings() -> Settings {
        Settings(defaults: UserDefaults(suiteName: "watch-call-\(UUID().uuidString)")!)
    }

    @Test func theServiceVoiceModeUsesWhenTheWatchCanCallIt() {
        let settings = settings()
        settings.voiceEngine = .grok
        settings.setAppLiveVoice("rex", for: .grok)
        let keys: [LiveEngine: String] = [.gptLive: "sk-openai", .grok: "xai-key"]
        let live = WatchLink.watchLive(settings) { keys[$0] }
        #expect(live == WatchLive(engine: "grok", key: "xai-key", voice: "rex"))
    }

    @Test func elseTheFirstTheWatchCanCallThatHasAKey() {
        let settings = settings()
        // ElevenLabs: its answers are read in the phone's own reading voice, which the watch hasn't.
        settings.voiceEngine = .elevenLabs
        let live = WatchLink.watchLive(settings) { [.elevenLabs: "el", .gemini: "g-key"][$0] }
        #expect(live?.engine == "gemini")
        #expect(live?.key == "g-key")
        #expect(live?.voice == LiveEngine.gemini.defaultVoice)
    }

    @Test func noKeyNoCall() {
        let settings = settings()
        settings.voiceEngine = .gptLive
        #expect(WatchLink.watchLive(settings) { _ in nil } == nil)
        #expect(WatchLink.watchLive(settings) { _ in "" } == nil)
    }

    @Test func theWatchCallsOnlyWhatItCanReachItself() {
        #expect(Set(WatchLive.engines) == ["gptLive", "gemini", "grok"])
        for engine in WatchLive.engines { #expect(LiveEngine(rawValue: engine) != nil) }
    }

    /// The key goes in the connection the phone sends; the watch keeps it in its Keychain, not
    /// in its defaults (`WatchStore.apply`).
    @Test func theKeyTravelsWithTheConnection() throws {
        var connection = WatchConnection(kind: .hermesAPI, url: "https://h", apiKey: "k", model: "", provider: "",
                                         reasoningEffort: "", replyLanguage: "", agentName: "Sol")
        connection.live = WatchLive(engine: "gptLive", key: "sk", voice: "marin")
        let back = try JSONDecoder().decode(WatchConnection.self, from: JSONEncoder().encode(connection))
        #expect(back.live == connection.live)
        // An older copy, from before calls on the watch, still reads.
        let old = #"{"kind":"hermesAPI","url":"https://h","apiKey":"k","model":"","provider":"","reasoningEffort":"","replyLanguage":"","agentName":"Sol"}"#
        #expect(try JSONDecoder().decode(WatchConnection.self, from: Data(old.utf8)).live == nil)
    }
}
