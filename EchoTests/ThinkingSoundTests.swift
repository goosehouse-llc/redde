import Foundation
import Testing
@testable import Echo

/// Settings → Voice → Thinking sound: while the agent works and nothing is being said, voice
/// mode plays a quiet sound, so silence isn't taken for a failure. When it starts and stops is
/// tried here; what it sounds like, and how it carries in a car, is for ears.
@MainActor
struct ThinkingSoundTests {
    /// Stands in for the player: on or off, and how often.
    final class FakeSound: ThinkingSounding {
        private(set) var isOn = false
        private(set) var starts = 0
        private(set) var stops = 0
        func start() { isOn = true; starts += 1 }
        func stop() { isOn = false; stops += 1 }
    }

    struct Harness {
        let session: VoiceSession
        let conversation: Conversation
        let recognizer = VoiceSessionTests.FakeRecognizer()
        let speaker = VoiceSessionTests.FakeSpeaker()
        let audio = VoiceSessionTests.FakeAudio()
        let sound = FakeSound()

        init(_ transport: any HermesTransport, _ choice: Settings.ThinkingSound = .always, carPlay: Bool = false,
             route: VoiceRoute = .speaker, talkOver: Settings.TalkOver = .off) {
            audio.route = route
            let settings = Settings(defaults: UserDefaults(suiteName: "thinking-\(UUID().uuidString)")!)
            settings.transport = .chatCompletions
            settings.fastLaneURL = "http://example.invalid:11500"
            settings.fastLaneModel = "test"
            let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "thinking-\(UUID().uuidString)"))
            conversation = Conversation(settings: settings, store: store, transportOverride: transport)
            session = VoiceSession(conversation: conversation, recognizer: recognizer, output: speaker, audio: audio,
                                   requestPermissions: { true }, earcon: { _ in }, keepAwake: { _ in }, talkOver: { talkOver },
                                   interruption: { .speech }, stopPhrases: { [] }, answersAloud: { false }, shortInCar: { false },
                                   carConnected: { carPlay }, takeNote: { _ in }, thinkingSoundWanted: { choice }, thinkingSound: sound)
            session.thinkingSoundAfter = .milliseconds(150)
            session.quietCheck = .milliseconds(15)
        }

        func ask(_ text: String = "Is the backup done?") async throws {
            session.beginListening()
            try await SpokenRequestTests.waitUntil("the mic") { recognizer.starts == 1 }
            recognizer.deliver(text)
            try await SpokenRequestTests.waitUntil("the question to go") { session.phase == .thinking || session.phase == .speaking }
        }

        /// Long enough for the sound to have started, had it been going to.
        func wait() async throws { try await Task.sleep(for: .milliseconds(450)) }
    }

    private typealias Held = PhoneToolsTests.HeldTransport

    @Test func silenceWhileTheAgentWorksIsFilledUntilItSpeaks() async throws {
        let transport = Held([], then: [.textDelta("It finished at nine."), .done])
        let h = Harness(transport)
        try await h.ask()
        #expect(!h.sound.isOn, "not at once: an answer that comes straight away needs no sound")
        try await SpokenRequestTests.waitUntil("the sound") { h.sound.isOn }
        #expect(h.session.phase == .thinking)

        transport.letGo()
        try await SpokenRequestTests.waitUntil("the reply") { !h.speaker.spoken.isEmpty }
        #expect(!h.sound.isOn, "gone with the reply's first sound")
        #expect(h.sound.starts == 1 && h.sound.stops == 1)
        h.session.cancel()
    }

    @Test func anAnswerThatComesAtOnceHasNoSound() async throws {
        let h = Harness(Held([.textDelta("Yes."), .done], then: []))
        try await h.ask()
        h.speaker.meterLevel = 0.5
        try await h.wait()
        #expect(h.sound.starts == 0)
        h.session.cancel()
    }

    /// "Let me check", and then a minute of tools: the reply has begun, and it is quiet again.
    @Test func theQuietInTheMiddleOfAReplyIsFilledToo() async throws {
        let transport = Held([.textDelta("Let me check. ")], then: [.textDelta("It finished at nine."), .done])
        let h = Harness(transport)
        h.speaker.meterLevel = 0.5   // being said
        try await h.ask()
        try await SpokenRequestTests.waitUntil("the first words") { h.session.phase == .speaking }
        try await h.wait()
        #expect(h.sound.starts == 0, "not over the words")
        h.speaker.meterLevel = 0     // said; the agent is at its tools
        try await SpokenRequestTests.waitUntil("the sound") { h.sound.isOn }

        h.speaker.meterLevel = 0.5   // the rest arrives and is said
        transport.letGo()
        try await SpokenRequestTests.waitUntil("the sound to stop") { !h.sound.isOn }
        // The reply is complete and its last words have been said: quiet, and nothing is at work.
        try await SpokenRequestTests.waitUntil("the reply's end") { h.speaker.ends > 0 }
        h.speaker.meterLevel = 0
        try await h.wait()
        #expect(h.sound.starts == 1, "the quiet after the last word is not work")
        h.session.cancel()
    }

    @Test func offMeansOffAndInTheCarMeansWithACar() async throws {
        let never = Harness(Held([], then: []), .off, carPlay: true, route: .car)
        try await never.ask()
        try await never.wait()
        #expect(never.sound.starts == 0)
        never.session.cancel()

        let atHome = Harness(Held([], then: []), .car)
        try await atHome.ask()
        try await atHome.wait()
        #expect(atHome.sound.starts == 0)
        atHome.session.cancel()

        let carPlay = Harness(Held([], then: []), .car, carPlay: true)
        try await carPlay.ask()
        try await SpokenRequestTests.waitUntil("the sound with CarPlay") { carPlay.sound.isOn }
        carPlay.session.cancel()

        let bluetooth = Harness(Held([], then: []), .car, route: .car)
        try await bluetooth.ask()
        try await SpokenRequestTests.waitUntil("the sound on the car's Bluetooth") { bluetooth.sound.isOn }
        bluetooth.session.cancel()
    }

    /// A turn that waits for an approval is not at work: the sound would say it was.
    @Test func notWhileTheTurnWaitsForThePerson() async throws {
        let waiting = SpokenRequestTests.GatedTransport([.interrupt(.approval(ApprovalRequest(id: "a1", command: "rm -rf ~/builds/2025-*", description: "Clear out the old builds",
                                                                                              choices: ["once", "deny"])), runtimeSession: "r1")])
        let h = Harness(waiting)
        try await h.ask()
        try await SpokenRequestTests.waitUntil("the request") { h.session.activeTool == "waiting for you" }
        try await h.wait()
        #expect(!h.sound.isOn)
        h.session.cancel()
    }

    @Test func itStopsWhenTheTurnIsEnded() async throws {
        let h = Harness(Held([], then: []))
        try await h.ask()
        try await SpokenRequestTests.waitUntil("the sound") { h.sound.isOn }
        h.session.cancel()
        #expect(!h.sound.isOn && h.session.phase == .idle, "at once, not at the next look")
        try await h.wait()
        #expect(h.sound.starts == 1)
    }

    /// A microphone left open on the phone's own speaker would hear the sound start, and a
    /// sound that starts can pass for a voice. On headphones the microphone hears none of it.
    @Test func notIntoAMicrophoneOpenOnTheSpeaker() async throws {
        let speaker = Harness(Held([], then: []), talkOver: .everywhere)
        try await speaker.ask()
        try await speaker.wait()
        #expect(speaker.sound.starts == 0)
        speaker.session.cancel()

        let headphones = Harness(Held([], then: []), route: .headphones, talkOver: .headphones)
        try await headphones.ask()
        try await SpokenRequestTests.waitUntil("the sound on headphones") { headphones.sound.isOn }
        headphones.session.cancel()
    }

    @Test func itIsOffUntilChosenAndTheChoiceIsKept() {
        let defaults = UserDefaults(suiteName: "thinking-\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        #expect(settings.thinkingSound == .off)
        settings.thinkingSound = .car
        #expect(Settings(defaults: defaults).thinkingSound == .car)
    }

    /// The loop is in the app, and short enough to come round often.
    @Test func theSoundIsBundled() throws {
        let url = try #require(Bundle.main.url(forResource: "thinking", withExtension: "wav"))
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size > 50_000 && size < 400_000)
    }
}
