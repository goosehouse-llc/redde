import Foundation
import Testing
@testable import Echo

/// Settings → Voice → Short answers in the car: a question asked by voice with a car connected
/// asks the agent to keep it short. What each connection then sends has not been checked
/// against a server; the request that reaches it is.
@MainActor
struct CarBrevityTests {
    // MARK: The note the Dashboard connection adds, and takes off again

    @Test func theNoteIsHiddenAgain() {
        #expect(CarBrevity.strip("What's the weather in Lisbon?" + CarBrevity.note) == "What's the weather in Lisbon?")
        #expect(CarBrevity.strip("I'm driving and will hear this read aloud.") == "I'm driving and will hear this read aloud.")
        // Behind a reply-language note, which goes first on the message and comes off second.
        let both = "Hoe is het weer?" + ReplyLanguage.note("nl") + CarBrevity.note
        #expect(ReplyLanguage.stripNote(both) == "Hoe is het weer?")
        #expect(ReplyLanguage.stripNote("Hoe is het weer?" + CarBrevity.note) == "Hoe is het weer?")
    }

    @Test func historyFromTheServerHidesTheNote() {
        let rows: [JSONValue] = [.object(["role": .string("user"), "text": .string("What's the weather?" + CarBrevity.note)])]
        #expect(Conversation.messages(fromServeRows: rows).first?.text == "What's the weather?")
    }

    @Test func theAgentIsToldWhyAndHowToGoOn() {
        #expect(CarBrevity.instruction.contains("driving") && CarBrevity.instruction.contains("two or three short spoken sentences"))
        #expect(CarBrevity.instruction.contains("\"more\""), "it has to know what the person will say for the rest")
        #expect(!CarBrevity.instruction.contains("\n"), "one paragraph of a system prompt")
    }

    // MARK: When it is asked for

    /// Keeps what it was sent.
    final class RecordingTransport: HermesTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [TurnRequest] = []
        var requests: [TurnRequest] { lock.withLock { kept } }
        nonisolated func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
            lock.withLock { kept.append(request) }
            return AsyncThrowingStream { continuation in
                continuation.yield(.textDelta("Sunny, twenty degrees."))
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }

    struct Harness {
        let transport = RecordingTransport()
        let conversation: Conversation
        let session: VoiceSession
        let recognizer = VoiceSessionTests.FakeRecognizer()
        let speaker = VoiceSessionTests.FakeSpeaker()
        let audio = VoiceSessionTests.FakeAudio()

        init(short: Bool, carPlay: Bool, route: VoiceRoute = .speaker) {
            let settings = Settings(defaults: UserDefaults(suiteName: "brevity-\(UUID().uuidString)")!)
            settings.transport = .chatCompletions
            settings.fastLaneURL = "http://example.invalid:11500"
            settings.fastLaneModel = "test"
            let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "brevity-\(UUID().uuidString)"))
            conversation = Conversation(settings: settings, store: store, transportOverride: transport)
            audio.route = route
            session = VoiceSession(conversation: conversation, recognizer: recognizer, output: speaker, audio: audio,
                                   requestPermissions: { true }, earcon: { _ in }, keepAwake: { _ in }, talkOver: { .off },
                                   interruption: { .speech }, shortInCar: { short }, carConnected: { carPlay }, takeNote: { _ in })
        }

        /// Asks by voice and gives back what the transport was sent.
        func ask(_ question: String = "What's the weather in Lisbon?") async throws -> TurnRequest {
            session.beginListening()
            let deadline = Date().addingTimeInterval(3)
            while recognizer.starts == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            recognizer.deliver(question)
            while transport.requests.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            let request = try #require(transport.requests.last)
            session.cancel()
            return request
        }
    }

    @Test func aQuestionAskedInTheCarAsksForAShortAnswer() async throws {
        let request = try await Harness(short: true, carPlay: true).ask()
        #expect(request.brief)
        #expect(request.userText == "What's the weather in Lisbon?", "what was said goes as it was said: each connection adds its own request")
    }

    @Test func aCarOnBluetoothAloneCountsToo() async throws {
        #expect(try await Harness(short: true, carPlay: false, route: .car).ask().brief)
    }

    @Test func notUnlessAskedForAndNotAwayFromACar() async throws {
        #expect(try await !Harness(short: false, carPlay: true, route: .car).ask().brief)
        #expect(try await !Harness(short: true, carPlay: false, route: .speaker).ask().brief)
        #expect(try await !Harness(short: true, carPlay: false, route: .headphones).ask().brief)
    }

    /// Typed on the phone with the car connected (a passenger's hands): nothing is asked for.
    @Test func aTypedMessageIsSentAsItIs() async throws {
        let h = Harness(short: true, carPlay: true)
        for await _ in h.conversation.send("What's the weather in Lisbon?") {}
        #expect(h.transport.requests.last?.brief == false)
    }

    @Test func theSwitchIsOffUntilTurnedOnAndStaysAsSet() {
        let defaults = UserDefaults(suiteName: "brevity-\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        #expect(!settings.shortAnswersInCar)
        settings.shortAnswersInCar = true
        #expect(Settings(defaults: defaults).shortAnswersInCar)
    }
}
