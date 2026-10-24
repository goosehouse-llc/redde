import AVFoundation
import Foundation
import Testing
@testable import Echo

/// GPT-Live (`LiveVoice`): the call set up, what the service says turned into turns for the agent,
/// the agent's answer sent back a sentence at a time, and the voice session showing the call.
/// A fake call stands in for WebRTC and OpenAI; what a real call does on a phone is measured
/// there, not here.
@MainActor
struct LiveVoiceTests {
    // MARK: Fakes

    /// The call: what was sent on its channel, as JSON, and what the app asked of it.
    final class FakeCall: NSObject, LiveCalling {
        weak var listener: LiveCallListening?
        private(set) var sent: [JSONValue] = []
        private(set) var muted = false
        private(set) var closed = false
        private(set) var answer: String?
        var inputLevel: Float = 0
        var outputLevel: Float = 0

        func makeOffer(_ done: @escaping (String?, String?) -> Void) { done("offer-sdp\r\n", nil) }
        func accept(_ answer: String, done: @escaping (String?) -> Void) { self.answer = answer; done(nil) }
        func send(_ event: String) -> Bool {
            guard !closed, let parsed = try? JSONValue.parse(Data(event.utf8)) else { return false }
            sent.append(parsed)
            return true
        }
        func setMuted(_ muted: Bool) { self.muted = muted }
        func close() { closed = true }

        /// The service says something.
        func receive(_ event: String) { listener?.liveCallReceived(event) }
        func state(_ state: LiveCallState) { listener?.liveCallChanged(state.rawValue) }
        func sent(_ type: String) -> [JSONValue] { sent.filter { $0["type"]?.string == type } }
    }

    /// Keeps each turn it was sent and answers with `reply`, tool and all.
    final class RecordingTransport: HermesTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [TurnRequest] = []
        var requests: [TurnRequest] { lock.withLock { kept } }
        let reply: [TurnEvent]
        init(reply: [TurnEvent]) { self.reply = reply }
        nonisolated func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
            lock.withLock { kept.append(request) }
            let reply = reply
            return AsyncThrowingStream { continuation in
                for event in reply { continuation.yield(event) }
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }

    struct Harness {
        let call = FakeCall()
        let transport: RecordingTransport
        let conversation: Conversation
        let settings: Settings
        let live: LiveVoice
        /// What the setup was given: the offer, and the conversation so far.
        let opened = Box<(String, [JSONValue])?>(nil)

        init(reply: [TurnEvent] = [.textDelta("Your meeting is at 4 pm. "), .textDelta("It's with Ana.")], hangUp: Int = 2) {
            settings = Settings(defaults: UserDefaults(suiteName: "live-\(UUID().uuidString)")!)
            settings.transport = .chatCompletions
            settings.fastLaneURL = "http://example.invalid:11500"
            settings.fastLaneModel = "test"
            settings.liveHangUp = hangUp
            transport = RecordingTransport(reply: reply)
            let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "live-\(UUID().uuidString)"))
            conversation = Conversation(settings: settings, store: store, transportOverride: transport)
            let call = call, opened = opened
            live = LiveVoice(conversation: conversation, settings: settings,
                             makeCall: { listener in call.listener = listener; return call },
                             setUp: { _, _ in
                                 LiveSetup(label: "test", hermesKnowsLiveTurns: true) { offer, history in
                                     opened.value = (offer, history)
                                     return "answer-sdp"
                                 }
                             })
        }

        /// Set up and connected, as a call is once the service has started it.
        func connect() async {
            await live.start()
            call.receive(#"{"type":"session.started","session":{"id":"s1"}}"#)
        }

        func person(_ words: String, at ms: Int = 0) {
            call.receive(#"{"type":"session.input_transcript.delta","delta":"\#(words)","start_ms":\#(ms),"end_ms":\#(ms + 900)}"#)
        }

        func voice(_ words: String, at ms: Int = 0) {
            call.receive(#"{"type":"session.output_transcript.delta","delta":"\#(words)","start_ms":\#(ms),"end_ms":\#(ms + 900)}"#)
        }

        func handOver(_ id: String = "d1") { call.receive(#"{"type":"session.delegation.created","delegation":{"id":"\#(id)","type":"client"}}"#) }
    }

    @MainActor final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    static func until(_ done: @escaping () -> Bool, seconds: Double = 3) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(done())
    }

    // MARK: Setting the call up

    @Test func theCallIsSetUpWithTheOfferAndTheConversationSoFar() async throws {
        let harness = Harness()
        harness.conversation.replaceForDemo(messages: [Message(role: .user, text: "Hi"), Message(role: .assistant, text: "Hello!")], bot: nil)
        await harness.live.start()
        let (offer, history) = try #require(harness.opened.value)
        #expect(offer == "offer-sdp\r\n", "the offer exactly as made: OpenAI's parser wants its last line break")
        #expect(history.count == 2 && history[0]["role"]?.string == "user" && history[1]["content"]?.array?.first?["type"]?.string == "output_text")
        #expect(harness.call.answer == "answer-sdp")
        #expect(harness.live.state == .connecting, "not connected until the service says it has started")
        harness.call.receive(#"{"type":"session.started","session":{"id":"s1"}}"#)
        #expect(harness.live.state == .listening && harness.live.connected)
    }

    @Test func aCallThatCantBeSetUpSaysWhy() async {
        let settings = Settings(defaults: UserDefaults(suiteName: "live-\(UUID().uuidString)")!)
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "live-\(UUID().uuidString)"))
        let conversation = Conversation(settings: settings, store: store, transportOverride: RecordingTransport(reply: []))
        let call = FakeCall()
        let live = LiveVoice(conversation: conversation, settings: settings, makeCall: { _ in call },
                             setUp: { _, _ in throw LiveFailure("GPT-Live needs an OpenAI key.") })
        await live.start()
        #expect(live.state == .ended && live.problem == "GPT-Live needs an OpenAI key." && call.closed)
    }

    // MARK: Handing requests to the agent

    @Test func aHandedOverRequestBecomesATurnAndItsAnswerIsSaidBackASentenceAtATime() async throws {
        let harness = Harness()
        await harness.connect()
        harness.person("What's next on ")
        harness.person("my calendar?", at: 900)
        harness.voice("Let me check.", at: 2_000)
        harness.handOver()
        #expect(harness.live.state == .thinking)
        try await Self.until { harness.live.state == .listening }
        let request = try #require(harness.transport.requests.last)
        #expect(request.userText == "What's next on my calendar?", "the person's own words are the message")
        let live = try #require(request.live)
        #expect(live.surface && live.context == "User: What's next on my calendar?\nVoice assistant: Let me check.")
        let said = harness.call.sent("session.commentary.append")
        #expect(said.compactMap { $0["content"]?.string } == ["Your meeting is at 4 pm.", "It's with Ana."])
        #expect(said.allSatisfy { $0["delegation_id"]?.string == "d1" })
        #expect(Set(said.compactMap { $0["event_id"]?.string }).count == 2, "each append its own id")
    }

    @Test func whatTheAgentDoesIsMentionedQuietly() async throws {
        let harness = Harness(reply: [.toolStarted(name: "calendar", preview: nil), .toolFinished(name: "calendar", failed: false), .textDelta("Done.")])
        await harness.connect()
        harness.person("Move my 4 pm to 5.")
        harness.handOver()
        try await Self.until { harness.live.state == .listening }
        let thought = harness.call.sent("session.thinking.append").compactMap { $0["content"]?.string }
        #expect(thought.contains { $0.contains("working: calendar") })
        #expect(harness.call.sent("session.commentary.append").compactMap { $0["content"]?.string } == ["Done."])
    }

    @Test func anAnswerWithNothingToSaySaysSoQuietly() async throws {
        let harness = Harness(reply: [])
        await harness.connect()
        harness.person("Turn the lights off.")
        harness.handOver()
        try await Self.until { harness.live.state == .listening }
        #expect(harness.call.sent("session.commentary.append").isEmpty)
        #expect(harness.call.sent("session.thinking.append").contains { $0["content"]?.string?.contains("without anything to say") == true })
    }

    @Test func theRequestIsWhatWasSaidLastWithTheExchangeBeforeIt() {
        let fragments = [
            LiveFragment(speaker: .person, text: "Book a table ", startMs: 0, endMs: 900),
            LiveFragment(speaker: .person, text: "for Friday.", startMs: 900, endMs: 1_500),
            LiveFragment(speaker: .voice, text: "For how many?", startMs: 2_000, endMs: 2_800),
            LiveFragment(speaker: .person, text: "  Four,  thanks. ", startMs: 3_000, endMs: 3_900),
        ]
        let (prompt, context) = LiveFragment.delegation(from: fragments)
        #expect(prompt == "Four, thanks.")
        #expect(context == "User: Book a table for Friday.\nVoice assistant: For how many?\nUser: Four, thanks.")
        // Nothing the person said: the end of the exchange stands in.
        #expect(LiveFragment.delegation(from: [LiveFragment(speaker: .voice, text: "Hello.", startMs: 0, endMs: 1)]).prompt == "Voice assistant: Hello.")
    }

    @Test func longAnswersGoInPiecesTheServiceTakes() {
        #expect(LiveFragment.appendable("  Short   one. ") == ["Short one."])
        let sentence = String(repeating: "word ", count: 50).trimmingCharacters(in: .whitespaces) + "."
        let text = Array(repeating: sentence, count: 10).joined(separator: " ")
        let parts = LiveFragment.appendable(text)
        #expect(parts.allSatisfy { $0.count <= LiveFragment.appendLimit } && parts.count > 1)
        #expect(parts.allSatisfy { $0.hasSuffix(".") }, "cut between sentences")
        #expect(parts.joined(separator: " ") == text)
        // One sentence longer than the limit is cut where it must be.
        let long = String(repeating: "a", count: 3_000)
        #expect(LiveFragment.appendable(long).map(\.count) == [1_400, 1_400, 200])
    }

    // MARK: Ending

    @Test func aStopPhraseHangsUp() async throws {
        let harness = Harness()
        await harness.connect()
        harness.person("Goodbye.")
        try await Self.until({ harness.live.state == .ended }, seconds: 4)
        #expect(!harness.call.sent("session.close").isEmpty, "OpenAI is told, so its bill stops")
        #expect(harness.live.problem == nil)
        #expect(harness.transport.requests.isEmpty)
    }

    @Test func aStopPhraseHandedOverIsNotATurn() async throws {
        let harness = Harness()
        await harness.connect()
        harness.person("That's all.")
        harness.handOver()
        #expect(harness.live.state == .ended && harness.transport.requests.isEmpty)
    }

    @Test func theServiceEndingTheCallSaysWhyUnlessItWasAsked() async {
        let harness = Harness()
        await harness.connect()
        harness.call.receive(#"{"type":"session.closed","reason":"max_duration","usage":{"seconds":1800}}"#)
        #expect(harness.live.state == .ended && harness.live.problem == "The GPT-Live call reached its time limit.")
        let other = Harness()
        await other.connect()
        other.call.receive(#"{"type":"session.closed","reason":"close_requested"}"#)
        #expect(other.live.state == .ended && other.live.problem == nil)
    }

    @Test func aLostConnectionEndsTheCall() async {
        let harness = Harness()
        await harness.connect()
        harness.call.state(.lost)
        #expect(harness.live.state == .ended && harness.live.problem == "The connection to GPT-Live dropped." && harness.call.closed)
    }

    @Test func lateErrorsAboutAppendsAreIgnored() async {
        let harness = Harness()
        await harness.connect()
        harness.call.receive(#"{"type":"error","error":{"code":"context_injection_incomplete","message":"late"}}"#)
        harness.call.receive(#"{"type":"error","error":{"code":"other","message":"something"}}"#)
        #expect(harness.live.state == .listening)
    }

    // MARK: Muting and speaking

    @Test func mutingShutsTheMicrophoneAndTellsTheService() async {
        let harness = Harness()
        await harness.connect()
        harness.live.setMuted(true)
        #expect(harness.call.muted && harness.live.isMuted && harness.call.sent("session.input_audio.mute").count == 1)
        harness.live.setMuted(false)
        #expect(!harness.call.muted && harness.call.sent("session.input_audio.unmute").count == 1)
    }

    @Test func theVoiceSpeakingIsSpeakingAndItsWordsAreKept() async {
        let harness = Harness()
        await harness.connect()
        harness.voice("Hi! ")
        harness.voice("How can I help?", at: 400)
        harness.call.state(.speaking)
        #expect(harness.live.state == .speaking && harness.live.said == "Hi! How can I help?")
        harness.person("What time is it?", at: 2_000)
        harness.call.state(.quiet)
        #expect(harness.live.state == .listening && harness.live.heard == "What time is it?")
        harness.voice("It's ten.", at: 3_000)
        #expect(harness.live.said == "It's ten.", "what it says now, not all it has said")
    }

    // MARK: The voice session on a call

    struct SessionHarness {
        let base = Harness()
        let audio = VoiceSessionTests.FakeAudio()
        let cues = VoiceSessionTests.CueLog()
        let session: VoiceSession

        init() {
            let base = base, cues = cues
            session = VoiceSession(conversation: base.conversation, recognizer: VoiceSessionTests.FakeRecognizer(),
                                   output: VoiceSessionTests.FakeSpeaker(), audio: audio, requestPermissions: { true },
                                   earcon: { cues.record($0) }, cueSettle: .zero, keepAwake: { _ in },
                                   liveWanted: { true }, makeLive: { _ in base.live }, micAllowed: { true })
        }
    }

    @Test func theVoiceSessionShowsTheCallAsItsPhases() async throws {
        let harness = SessionHarness()
        let session = harness.session
        session.beginListening()
        #expect(session.isLive && session.phase == .thinking, "calling")
        try await Self.until { harness.base.call.answer != nil }
        harness.base.call.receive(#"{"type":"session.started"}"#)
        #expect(session.phase == .listening && harness.audio.activations == 1)
        #expect(harness.cues.cues == [.listening], "one cue as the call starts, none between its phases")
        harness.base.call.state(.speaking)
        #expect(session.phase == .speaking && session.soundStartedAt != nil)
        harness.base.call.state(.quiet)
        #expect(session.phase == .listening && harness.cues.cues == [.listening])
        #expect(harness.audio.replying.isEmpty && harness.audio.earRouting.isEmpty, "the call's audio is left alone")
        // Pause in the car, or muting: the microphone shut, the call open.
        session.mute()
        #expect(session.phase == .idle && session.isMuted && session.mightBeBusy && harness.base.call.muted)
        session.beginListening()
        #expect(session.phase == .listening && !session.isMuted)
        // The orb hangs up.
        session.primaryAction()
        #expect(!session.isLive && session.phase == .idle)
        #expect(harness.base.live.state == .ended && harness.cues.cues == [.listening, .stopped])
        #expect(!harness.base.call.sent("session.close").isEmpty)
    }

    @Test func aCallThatFailsShowsWhy() async throws {
        let harness = SessionHarness()
        harness.session.beginListening()
        try await Self.until { harness.base.call.answer != nil }
        harness.base.call.state(.lost)
        #expect(harness.session.phase == .error("The connection to GPT-Live dropped.") && !harness.session.isLive)
    }

    @Test func aNoteAndAGroupChatStayRedde_s() async {
        let harness = SessionHarness()
        harness.session.beginListening(capturing: true)
        #expect(!harness.session.isLive)
        harness.session.cancel()
        harness.session.sendsTo = { _ in }
        harness.session.beginListening()
        #expect(!harness.session.isLive)
        harness.session.cancel()
    }

    // MARK: The request for a session, and the turn's note

    @Test func theSessionRequestIsHermes_s() throws {
        let history = LiveSetup.history([Message(role: .user, text: "One  two"), Message(role: .assistant, text: "")])
        #expect(history.count == 1 && history[0]["content"]?.array?.first?["text"]?.string == "One two", "empty replies left out")
        let body = LiveSetup.body(offer: "v=0\r\n", history: history, voice: "cedar", instructions: LiveSetup.persona(name: "Sol"))
        let session = try #require(body["session"])
        #expect(session["model"]?.string == "gpt-live-1" && session["delegation"]?["type"]?.string == "client")
        #expect(session["audio"]?["output"]?["voice"]?.string == "cedar" && session["input"]?.array?.count == 1)
        #expect(session["instructions"]?.string?.hasPrefix("You are Sol,") == true)
        #expect(body["transport"]?["type"]?.string == "webrtc" && body["transport"]?["sdp"]?.string == "v=0\r\n")
        #expect(LiveSetup.body(offer: "o", history: [], voice: "marin", instructions: "")["session"]?["input"] == nil)
    }

    @Test func theConversationSoFarIsKeptShort() {
        let long = (0..<40).map { Message(role: $0.isMultiple(of: 2) ? .user : .assistant, text: "message \($0) " + String(repeating: "x", count: 400)) }
        let history = LiveSetup.history(long)
        #expect(history.count <= 24)
        #expect(history.compactMap { $0["content"]?.array?.first?["text"]?.string }.reduce(0) { $0 + $1.count } <= 6_000)
        #expect(history.last?["content"]?.array?.first?["text"]?.string?.hasPrefix("message 39") == true, "newest kept")
    }

    @Test func theAgentIsToldOnEveryConnection() {
        var request = TurnRequest(userText: "What's next?", history: [], sessionID: nil, model: nil, provider: nil, reasoningEffort: nil, instructions: nil)
        #expect(!HermesSessionsTransport.instructions(for: request).contains("live spoken conversation"))
        request.live = LiveTurn(context: "User: What's next?", surface: false)
        let instructions = HermesSessionsTransport.instructions(for: request)
        #expect(instructions.contains("live spoken conversation") && instructions.hasSuffix("newest last:\nUser: What's next?"))
        // On a Dashboard that doesn't know live turns the note rides on the message, and comes off again.
        let message = "What's next?" + LiveVoiceNote.note(context: "User: What's next?")
        #expect(ReplyLanguage.stripNote(message) == "What's next?")
        #expect(ReplyLanguage.stripNote("What's next?" + CarBrevity.note + LiveVoiceNote.note(context: "")) == "What's next?")
        #expect(LiveVoiceNote.instruction(context: String(repeating: "y", count: 9_000)).count < LiveVoiceNote.instruction.count + 6_100)
    }

    // MARK: Loading

    /// The framework with WebRTC in it is in the app and loads when asked, not before; the
    /// call it makes answers to the app's protocol.
    @Test func theCallsFrameworkLoadsOnlyWhenACallIsMade() throws {
        final class Listener: NSObject, LiveCallListening {
            func liveCallReceived(_ event: String) {}
            func liveCallChanged(_ state: String) {}
        }
        #expect(!LiveEngine.isLoaded, "nothing at launch has loaded it")
        let listener = Listener()
        let call = try LiveEngine.makeCall(listener: listener)
        #expect(LiveEngine.isLoaded)
        #expect(call.inputLevel == 0 && call.outputLevel == 0 && !call.send("{}"), "nothing to send on before a call")
        call.close()
    }
}
