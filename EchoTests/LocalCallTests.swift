import Foundation
import Testing
@testable import Echo

/// Local calls (`LiveEngine.local`, `LocalCall`): no voice service, the phone listens and the
/// reading voice speaks. What `LiveVoice` makes of the call's events and what it hands back to be
/// said, the voice it speaks in, and the speech server's sound. Hearing and the turn's end need a
/// microphone, and are tried on a phone.
@MainActor
struct LocalCallTests {
    typealias Harness = LiveVoiceTests.Harness

    final class Listener: LiveCallListening {
        func liveCallReceived(_ event: String) {}
        func liveCallChanged(_ state: LiveCallState) {}
    }

    @Test func aLocalCallNeedsNoKeyAndSpeaksInTheReadingVoice() {
        let engine = LiveEngine.local
        #expect(engine.keyItem == nil && engine.speaksInReadingVoice && engine.voices.isEmpty)
        #expect(!engine.answersReadAloud, "its answer comes a sentence at a time, as said")
        #expect(engine.dialect.streamsAnswers && engine.dialect.engine == .local)
        #expect(Settings.VoiceEngine.local.live == .local && BotConversation.local.live == .local)
        #expect(LiveEngine.gptLive.keyItem != nil && !LiveEngine.gptLive.speaksInReadingVoice)
        #expect(LiveVoice.makeCall(Listener(), LocalDialect()) is LocalCall)
    }

    @Test func theWireReadsAsTheCloudEnginesDo() {
        let dialect = LocalDialect()
        #expect(dialect.read(LocalDialect.started) == [.started])
        #expect(dialect.read(LocalDialect.heard("Turn the lights off")) == [.transcript(.person, "Turn the lights off", startMs: nil, endMs: nil)])
        #expect(dialect.read(LocalDialect.delegated("turn_1")) == [.delegated(id: "turn_1", request: nil)])
        #expect(dialect.read(LocalDialect.interrupted) == [.interrupted])
        #expect(dialect.read("not json").isEmpty)
    }

    /// What `LiveVoice` hands a voice model that isn't for the person is never said.
    @Test func onlyWordsForThePersonAreSaid() {
        let dialect = LocalDialect()
        #expect(dialect.answer("It's 4 pm.", to: "turn_1", final: false, eventID: "say_1")
                == [.object(["type": .string("say"), "text": .string("It's 4 pm."), "id": .string("turn_1")])])
        #expect(dialect.answer("[Not to be read out: Sol used its tools for this answer: calendar.]", to: "turn_1", final: true, eventID: "x").isEmpty)
        #expect(dialect.answer("  ", to: "turn_1", final: true, eventID: "x").isEmpty)
        #expect(dialect.note("Sol is working: terminal. Not done yet.", to: "turn_1", eventID: "x").isEmpty)
        #expect(dialect.update("Sol is still working on it: 15 seconds so far, not done yet.", to: "turn_1", eventID: "x").first?["text"]?.string
                == String(localized: "Still working on it."), "a few words for the person, not the line meant for a model")
        #expect(dialect.mute(true, eventID: "x").isEmpty && dialect.close().isEmpty && dialect.opening(LivePlan(voice: "", instructions: "")).isEmpty)
    }

    /// The person's words go to the agent as they said them, and its answer comes back to be said,
    /// a sentence at a time as it is written, for that request.
    @Test func whatThePersonSaidGoesToTheAgentAndItsAnswerIsSaid() async throws {
        let harness = Harness(engine: .local)
        await harness.connect()
        #expect(harness.live.connected)
        harness.call.receive(LocalDialect.heard("When is my meeting?"))
        harness.call.receive(LocalDialect.delegated("turn_1"))
        try await LiveVoiceTests.until { harness.call.sent("say").count == 2 }
        #expect(harness.transport.requests.last?.userText == "When is my meeting?", "their own words are the message")
        let said = harness.call.sent("say")
        #expect(said.compactMap { $0["text"]?.string } == ["Your meeting is at 4 pm.", "It's with Ana."])
        #expect(said.allSatisfy { $0["id"]?.string == "turn_1" })
    }

    /// The reading voice of the bot the call is with, at its speed: the speech server's, or the
    /// device's where it has none (Hermes's voice is the Dashboard's to play).
    @Test func theCallSpeaksInTheBotsReadingVoice() {
        let settings = Settings(defaults: UserDefaults(suiteName: "local-\(UUID().uuidString)")!)
        settings.replyVoice = .kokoro
        settings.kokoroURL = "http://kokoro.invalid:8880"
        settings.kokoroVoice = "af_heart"
        settings.voiceSpeed = 1.2
        let server = URL(string: "http://kokoro.invalid:8880")
        #expect(settings.kokoroBaseURL == server)
        #expect(LocalSpeech.reading(for: nil, settings: settings) == .server(server!, voice: "af_heart", speed: 1.2))
        settings.botVoicesHere = ["home": BotVoice(kokoro: "am_adam", speed: 0.9)]
        #expect(LocalSpeech.reading(for: "home", settings: settings) == .server(server!, voice: "am_adam", speed: 0.9))
        settings.replyVoice = .hermes
        #expect(LocalSpeech.reading(for: nil, settings: settings).isDevice)
        settings.replyVoice = .kokoro
        settings.kokoroURL = ""
        #expect(LocalSpeech.reading(for: nil, settings: settings).isDevice, "no server: the device's voice")
    }

    /// A speech server's sound, whole, at the call's rate.
    @Test func aSpeechServersSoundComesWhole() async throws {
        let server = try await DroppingSpeechServer.start(drops: 0, seconds: 0.3)
        defer { server.stop() }
        var sound = Data()
        for try await piece in LocalSpeech.server(server.baseURL, voice: "af_heart", speed: 1).pcm("Hello there.") { sound.append(piece) }
        #expect(sound.count == Int(LocalSpeech.rate * 0.3) * 2)
        #expect(server.connections == 1)
    }

    /// A server that never answers: the sentence fails, for the device's voice to say instead.
    @Test func aSpeechServerThatFailsSaysSo() async throws {
        let server = try await DroppingSpeechServer.start(drops: 100)
        defer { server.stop() }
        await #expect(throws: (any Error).self) {
            for try await _ in LocalSpeech.server(server.baseURL, voice: "af_heart", speed: 1).pcm("Hello.") {}
        }
        #expect(LocalSpeech.server(server.baseURL, voice: "af_heart", speed: 1.1).fallback.isDevice)
    }
}
