import AVFoundation
import Foundation
import Testing
@testable import Echo

/// GPT-Live (`LiveVoice`): the call set up, what the service says turned into turns for the agent,
/// the agent's answer sent back a sentence at a time, and the voice session showing the call.
/// A fake call stands in for the WebSocket and OpenAI; what a real call does on a phone is
/// measured there, not here.
@MainActor
struct LiveVoiceTests {
    // MARK: Fakes

    /// The call: what was sent on its connection, as JSON, and what the app asked of it.
    final class FakeCall: LiveCalling {
        weak var listener: LiveCallListening?
        private(set) var sent: [JSONValue] = []
        private(set) var muted = false
        private(set) var closed = false
        private(set) var opened = false
        private(set) var connection: LiveConnection?
        /// The sessions it went on to (another bot's voice), in order.
        private(set) var reconnections: [LiveConnection] = []
        var inputLevel: Float = 0
        var outputLevel: Float = 0

        func open() throws { opened = true }
        func connect(_ connection: LiveConnection) async throws { self.connection = connection }
        func reconnect(_ connection: LiveConnection) async throws { reconnections.append(connection) }
        func send(_ event: String) -> Bool {
            guard !closed, let parsed = try? JSONValue.parse(Data(event.utf8)) else { return false }
            sent.append(parsed)
            return true
        }
        func setMuted(_ muted: Bool) { self.muted = muted }
        func close() { closed = true }

        /// The service says something.
        func receive(_ event: String) { listener?.liveCallReceived(event) }
        func state(_ state: LiveCallState) { listener?.liveCallChanged(state) }
        func sent(_ type: String) -> [JSONValue] { sent.filter { $0["type"]?.string == type } }
    }

    /// Keeps each turn it was sent and answers with `reply`, tool and all.
    final class RecordingTransport: HermesTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [TurnRequest] = []
        var requests: [TurnRequest] { lock.withLock { kept } }
        let reply: [TurnEvent]
        /// How long the agent takes to start answering.
        let after: Duration
        init(reply: [TurnEvent], after: Duration = .zero) {
            self.reply = reply
            self.after = after
        }
        nonisolated func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
            lock.withLock { kept.append(request) }
            let reply = reply, after = after
            return AsyncThrowingStream { continuation in
                Task {
                    if after > .zero { try? await Task.sleep(for: after) }
                    for event in reply { continuation.yield(event) }
                    continuation.yield(.done)
                    continuation.finish()
                }
            }
        }
    }

    struct Harness {
        let call = FakeCall()
        let transport: RecordingTransport
        let conversation: Conversation
        let settings: Settings
        let live: LiveVoice
        /// What the setup was given: the conversation so far.
        let opened = Box<[LiveLine]?>(nil)
        let engine: LiveEngine

        init(reply: [TurnEvent] = [.textDelta("Your meeting is at 4 pm. "), .textDelta("It's with Ana.")], hangUp: Int = 2,
             answerAfter: Duration = .zero, posting: LiveVoice.Posting = LiveVoice.Posting(), engine: LiveEngine = .gptLive) {
            self.engine = engine
            settings = Settings(defaults: UserDefaults(suiteName: "live-\(UUID().uuidString)")!)
            settings.transport = .chatCompletions
            settings.fastLaneURL = "http://example.invalid:11500"
            settings.fastLaneModel = "test"
            settings.liveHangUp = hangUp
            transport = RecordingTransport(reply: reply, after: answerAfter)
            let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "live-\(UUID().uuidString)"))
            conversation = Conversation(settings: settings, store: store, transportOverride: transport)
            let call = call, opened = opened
            live = LiveVoice(conversation: conversation, settings: settings, engine: engine,
                             makeCall: { listener, _ in call.listener = listener; return call },
                             setUp: { _, _, _ in
                                 LiveSetup(label: "test", hermesKnowsLiveTurns: true) { history in
                                     opened.value = history
                                     return LiveConnection(url: URL(string: "wss://example.invalid/live")!, headers: ["Authorization": "Bearer test"],
                                                           plan: LivePlan(voice: "marin", instructions: "", history: history))
                                 }
                             }, posting: posting,
                             goToBot: { conversation, bot, _ in
                                 conversation.replaceForDemo(messages: conversation.messages, bot: BotRef(profile: bot, name: bot.capitalized))
                             })
        }

        /// Set up and connected, as a call is once the service has started it.
        func connect() async {
            await live.start()
            switch engine {
            case .gptLive: call.receive(#"{"type":"session.started","session":{"id":"s1"}}"#)
            case .gemini: call.receive(#"{"setupComplete":{}}"#)
            case .grok: call.receive(#"{"type":"session.updated","session":{}}"#)
            case .elevenLabs: call.receive(#"{"type":"conversation_initiation_metadata","conversation_initiation_metadata_event":{}}"#)
            }
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

    @Test func theCallIsSetUpWithTheConversationSoFar() async throws {
        let harness = Harness()
        harness.conversation.replaceForDemo(messages: [Message(role: .user, text: "Hi"), Message(role: .assistant, text: "Hello!")], bot: nil)
        await harness.live.start()
        let history = try #require(harness.opened.value)
        #expect(history == [LiveLine(fromPerson: true, text: "Hi"), LiveLine(fromPerson: false, text: "Hello!")])
        #expect(harness.call.opened, "the microphone opens first, so nothing said while it connects is lost")
        let connection = try #require(harness.call.connection)
        #expect(connection.url.scheme == "wss" && connection.headers["Authorization"] == "Bearer test")
        #expect(GPTLiveDialect().opening(connection.plan).first?["session"]?["input"]?.array?.count == 2)
        #expect(harness.live.state == .connecting, "not connected until the service says it has started")
        harness.call.receive(#"{"type":"session.started","session":{"id":"s1"}}"#)
        #expect(harness.live.state == .listening && harness.live.connected)
    }

    @Test func aCallThatCantBeSetUpSaysWhy() async {
        let settings = Settings(defaults: UserDefaults(suiteName: "live-\(UUID().uuidString)")!)
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "live-\(UUID().uuidString)"))
        let conversation = Conversation(settings: settings, store: store, transportOverride: RecordingTransport(reply: []))
        let call = FakeCall()
        let live = LiveVoice(conversation: conversation, settings: settings, makeCall: { _, _ in call },
                             setUp: { _, _, _ in throw LiveFailure("GPT-Live needs an OpenAI key.") })
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

    @Test func aLongWaitIsSaidAloudUntilTheAnswerComes() async throws {
        let harness = Harness(reply: [.textDelta("Done.")], answerAfter: .milliseconds(500),
                              posting: LiveVoice.Posting(first: .milliseconds(100), every: .milliseconds(150)))
        await harness.connect()
        harness.person("Check the build.")
        harness.handOver()
        try await Self.until { harness.live.state == .listening }
        let said = harness.call.sent("session.commentary.append")
        let words = said.compactMap { $0["content"]?.string }
        #expect(words.last == "Done.")
        #expect(words.dropLast().count >= 2 && words.dropLast().allSatisfy { $0.contains("still working on it") && $0.contains("not done yet") },
                "said aloud (commentary), more than once while it waits")
        #expect(said.allSatisfy { $0["delegation_id"]?.string == "d1" })
        try await Task.sleep(for: .milliseconds(400))
        #expect(harness.call.sent("session.commentary.append").count == said.count, "nothing more once the answer has come")
    }

    @Test func hangingUpStopsTheRequestItHandedOver() async throws {
        let harness = Harness(answerAfter: .seconds(5))
        await harness.connect()
        harness.person("Check the build.")
        harness.handOver()
        try await Self.until { harness.conversation.isStreaming }
        harness.live.hangUp()
        #expect(!harness.conversation.isStreaming, "the agent is told to stop, as with Redde's own Stop")
    }

    @Test func aDroppedCallLeavesTheRequestToFinish() async throws {
        let harness = Harness(answerAfter: .milliseconds(300))
        await harness.connect()
        harness.person("Check the build.")
        harness.handOver()
        try await Self.until { harness.conversation.isStreaming }
        harness.call.listener?.liveCallChanged(.lost)
        #expect(harness.live.state == .ended && harness.conversation.isStreaming, "its answer still comes, in the chat")
    }

    @Test func aQuickAnswerHasNoWaitingSaid() async throws {
        let harness = Harness(posting: LiveVoice.Posting(first: .milliseconds(200), every: .milliseconds(200)))
        await harness.connect()
        harness.person("What's next?")
        harness.handOver()
        try await Self.until { harness.live.state == .listening }
        try await Task.sleep(for: .milliseconds(450))
        #expect(!harness.call.sent("session.commentary.append").contains { $0["content"]?.string?.contains("still working") == true })
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
        try await Self.until { harness.live.state == .ended }
        #expect(harness.transport.requests.isEmpty)
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
                                   liveWanted: { _ in true }, makeLive: { _ in base.live }, micAllowed: { true })
        }
    }

    @Test func theVoiceSessionShowsTheCallAsItsPhases() async throws {
        let harness = SessionHarness()
        let session = harness.session
        session.beginListening()
        #expect(session.isLive && session.phase == .thinking, "calling")
        try await Self.until { harness.base.call.connection != nil }
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
        try await Self.until { harness.base.call.connection != nil }
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

    @Test func theSessionIsHermes_sOverAWebSocket() throws {
        let history = LiveSetup.history([Message(role: .user, text: "One  two"), Message(role: .assistant, text: "")])
        #expect(history == [LiveLine(fromPerson: true, text: "One two")], "empty replies left out")
        let dialect = GPTLiveDialect()
        let start = try #require(dialect.opening(LivePlan(voice: "quartz", instructions: LiveSetup.persona(name: "Sol"), history: history)).first)
        #expect(start["type"]?.string == "session.start")
        let session = try #require(start["session"])
        #expect(session["model"]?.string == "gpt-live-1" && session["delegation"]?["type"]?.string == "client")
        #expect(session["audio"]?["output"]?["voice"]?.string == "quartz" && session["input"]?.array?.count == 1)
        #expect(session["audio"]?["format"]?["type"]?.string == "audio/pcm" && session["audio"]?["format"]?["rate"] == .number(16_000),
                "16 kHz both ways: a third less data than OpenAI's 24 kHz default")
        #expect(session["instructions"]?.string?.hasPrefix("You are Sol,") == true)
        #expect(dialect.opening(LivePlan(voice: "marin", instructions: "")).first?["session"]?["input"] == nil)
        #expect(LiveSetup.endpoint.absoluteString == "wss://api.openai.com/v1/live/sessions")
    }

    @Test func theConversationSoFarIsKeptShort() {
        let long = (0..<40).map { Message(role: $0.isMultiple(of: 2) ? .user : .assistant, text: "message \($0) " + String(repeating: "x", count: 400)) }
        let history = LiveSetup.history(long)
        #expect(history.count <= 24)
        #expect(history.map(\.text).reduce(0) { $0 + $1.count } <= 6_000)
        #expect(history.last?.text.hasPrefix("message 39") == true, "newest kept")
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

    // MARK: The call

    /// No WebRTC in the app any more; a call with no connection yet sends nothing and hears nothing.
    @Test func eachBotCanHaveItsOwnConversation() {
        let settings = Settings(defaults: UserDefaults(suiteName: "live-\(UUID().uuidString)")!)
        settings.voiceEngine = .gptLive
        settings.liveVoice = "marin"
        settings.botVoicesHere["scout"] = BotVoice(conversation: .redde)
        settings.botVoicesHere["sol"] = BotVoice(liveVoices: ["gptLive": "quartz", "gemini": "Kore"])
        #expect(settings.liveEngine(for: nil) == .gptLive && settings.liveEngine(for: "default") == .gptLive, "the main agent goes by the app's setting")
        #expect(settings.liveEngine(for: "scout") == nil, "a bot's own choice wins")
        #expect(settings.liveEngine(for: "sol") == .gptLive, "no choice of its own: the app's")
        #expect(settings.liveVoice(for: "sol") == "quartz" && settings.liveVoice(for: "scout") == "marin" && settings.liveVoice(for: nil) == "marin")
        #expect(settings.liveVoice(for: "sol", engine: .gemini) == "Kore" && settings.liveVoice(for: "scout", engine: .gemini) == "Puck",
                "a voice for each engine; none of its own, the app's for that engine")
        settings.liveVoice = "alloy"
        #expect(settings.liveVoice(for: nil) == "marin", "a voice GPT-Live doesn't have is the default")
        settings.voiceEngine = .redde
        settings.botVoicesHere["fixit"] = BotVoice(conversation: .gemini)
        #expect(settings.liveEngine(for: "fixit") == .gemini && !settings.usesLiveCall(for: nil) && !settings.usesLiveCall(for: "sol"))
        #expect(!BotVoice(conversation: .redde).isEmpty && !BotVoice(liveVoices: ["grok": "eve"]).isEmpty, "kept with nothing else picked")
    }

    @Test func aSpokenPrefixIsHeardAcrossTheVoicesReply() async throws {
        let harness = Harness()
        harness.settings.spokenPrefixes = [SpokenPrefix(word: "Home", prefix: "[home] ")]
        await harness.connect()
        harness.person("Home.")
        harness.voice("Yes?", at: 1_000)
        harness.person("Turn the office lights off.", at: 2_000)
        harness.voice("On it.", at: 3_000)
        harness.handOver()
        try await Self.until { harness.live.state == .listening }
        #expect(harness.transport.requests.last?.userText == "[home] Turn the office lights off.",
                "the name said first, the request after the voice answered it: still Home's")
    }

    @Test func aRequestForAnotherBotGoesOnInThatBotsVoice() async throws {
        let harness = Harness()
        harness.settings.spokenPrefixes = [SpokenPrefix(word: "Home", prefix: "", bot: "home")]
        await harness.connect()
        harness.person("Home, turn the office lights off.")
        harness.voice("Let me check.", at: 1_000)
        harness.handOver()
        try await Self.until { harness.live.state == .listening }
        #expect(harness.conversation.bot?.profile == "home", "the request went to Home's chat")
        let session = try #require(harness.call.reconnections.first, "a new session, in Home's voice")
        #expect(session.plan.history.last == LiveLine(fromPerson: true, text: "turn the office lights off."))
        #expect(session.plan.greeting?.line == "Your meeting is at 4 pm. It's with Ana.",
                "Home's session opens saying the answer, as a preview's voice says its line")
        #expect(!session.plan.preview, "and goes on handing requests over")
        #expect(harness.call.sent("session.commentary.append").isEmpty, "Sol's voice doesn't say Home's answer")
        harness.person("And the porch?", at: 6_000)
        harness.voice("Let me check.", at: 7_000)
        harness.handOver("d2")
        try await Self.until { harness.call.sent("session.commentary.append").contains { $0["delegation_id"]?.string == "d2" } }
        #expect(harness.call.reconnections.count == 1, "still Home: no second handoff")
    }

    @Test func theVoiceKnowsWhichBotsCanBeNamed() {
        let settings = Settings(defaults: UserDefaults(suiteName: "live-\(UUID().uuidString)")!)
        settings.spokenPrefixes = [SpokenPrefix(word: "Home", prefix: "", bot: "home"), SpokenPrefix(word: "Sol", prefix: "", bot: "default"),
                                   SpokenPrefix(word: "Note", prefix: "[note] ")]
        #expect(LiveSetup.addressable(settings, besides: "Sol") == ["Home"], "a bot's names, not its own, not a plain prefix")
        #expect(LiveSetup.persona(name: "Sol", others: ["Home"]).contains("may address Home by name"))
        #expect(!LiveSetup.persona(name: "Sol").contains("Other agents"))
    }

    @Test func aSpokenPrefixFromAnEarlierRequestIsNotReused() {
        let rules = [SpokenPrefix(word: "Home", prefix: "[home] ")]
        #expect(LiveVoice.addressed("What's the weather?", asked: ["What's the weather?"], rules: rules) == "What's the weather?")
        #expect(LiveVoice.addressed("lights off", asked: ["Home", "lights off"], rules: rules) == "Home lights off")
        #expect(LiveVoice.addressed("Home, lights off", asked: ["Scout", "Home, lights off"], rules: rules) == "Home, lights off")
    }

    // MARK: Hands-free off: one question, one answer

    static let quickly = LiveVoice.Posting(answered: .milliseconds(100))

    @Test func aCallEndsOnceAnsweredWithHandsFreeOff() async throws {
        let harness = Harness(posting: Self.quickly)
        harness.live.endsAfterAnswer = { true }
        await harness.connect()
        harness.person("Hi there.")
        harness.call.state(.speaking)
        harness.voice("Hello, good to hear from you.", at: 1_000)
        harness.call.state(.quiet)
        try await Self.until { harness.live.state == .ended }
        #expect(!harness.call.sent("session.close").isEmpty && harness.live.problem == nil)
    }

    @Test func thePersonGoingOnTalkingKeepsTheCall() async throws {
        let harness = Harness(posting: LiveVoice.Posting(answered: .milliseconds(300)))
        harness.live.endsAfterAnswer = { true }
        await harness.connect()
        harness.person("Move my meeting.")
        harness.call.state(.speaking)
        harness.voice("Which one, the 4 pm?", at: 1_000)
        harness.call.state(.quiet)
        harness.call.inputLevel = 0.2
        try await Task.sleep(for: .milliseconds(500))
        #expect(harness.live.state != .ended, "heard in the microphone before any transcript of it")
    }

    @Test func theAgentsAnswerIsSaidBeforeTheCallEnds() async throws {
        let harness = Harness(answerAfter: .milliseconds(200), posting: Self.quickly)
        harness.live.endsAfterAnswer = { true }
        await harness.connect()
        harness.person("What's next on my calendar?")
        harness.call.state(.speaking)
        harness.voice("Let me check.", at: 1_000)
        harness.call.state(.quiet)
        harness.handOver()
        try await Self.until { harness.live.state == .listening }
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.live.state != .ended, "not while the agent works, nor before the voice has said its answer")
        harness.call.state(.speaking)
        harness.voice("Your meeting is at 4 pm, with Ana.", at: 5_000)
        harness.call.state(.quiet)
        try await Self.until { harness.live.state == .ended }
    }

    @Test func handsFreeKeepsTheCallOpen() async throws {
        let harness = Harness(posting: Self.quickly)
        harness.live.endsAfterAnswer = { false }
        await harness.connect()
        harness.person("Hi there.")
        harness.call.state(.speaking)
        harness.voice("Hello.", at: 1_000)
        harness.call.state(.quiet)
        try await Task.sleep(for: .milliseconds(400))
        #expect(harness.live.state == .listening)
    }

    // MARK: Gemini Live and Grok Voice

    @Test func geminiSpeaksItsOwnWire() throws {
        let dialect = GeminiLiveDialect()
        let plan = LivePlan(voice: "Kore", instructions: "Be Sol.", history: [LiveLine(fromPerson: true, text: "Hi")],
                            agent: LiveAgentTool(agentName: "Sol"))
        let setup = try #require(dialect.opening(plan).first?["setup"])
        #expect(setup["model"]?.string == "models/gemini-3.8-live")
        #expect(setup["generationConfig"]?["speechConfig"]?["voiceConfig"]?["prebuiltVoiceConfig"]?["voiceName"]?.string == "Kore")
        let tool = try #require(setup["tools"]?.array?.first?["functionDeclarations"]?.array?.first)
        #expect(tool["name"]?.string == "ask_agent" && tool["behavior"]?.string == "NON_BLOCKING", "the voice goes on talking while the agent works")
        #expect(setup["historyConfig"]?["initialHistoryInClientContent"]?.bool == true)
        #expect(dialect.afterStart(plan, eventID: "x").first?["clientContent"]?["turns"]?.array?.first?["role"]?.string == "user")
        #expect(dialect.audio("AAAA").contains(#""mimeType":"audio/pcm;rate=16000""#) && dialect.outputRate == 24_000)
        #expect(dialect.read(#"{"setupComplete":{}}"#) == [.started])
        let pcm = Data([1, 0, 2, 0])
        let content = #"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"\#(pcm.base64EncodedString())"}}]},"outputTranscription":{"text":"Hello"},"interrupted":true}}"#
        #expect(dialect.read(content) == [.audio(pcm), .transcript(.voice, "Hello", startMs: nil, endMs: nil), .interrupted])
        #expect(dialect.read(#"{"toolCall":{"functionCalls":[{"id":"c1","name":"ask_agent","args":{"request":"Check the build"}}]}}"#)
                == [.delegated(id: "c1", request: "Check the build")])
        #expect(dialect.read(#"{"toolCallCancellation":{"ids":["c1"]}}"#) == [.withdrawn(["c1"])])
        let response = try #require(dialect.answer("Done.", to: "c1", final: true, eventID: "x").first?["toolResponse"]?["functionResponses"]?.array?.first)
        #expect(response["id"]?.string == "c1" && response["response"]?["result"]?.string == "Done.")
        #expect(dialect.answer("Part.", to: "c1", final: false, eventID: "x").isEmpty, "a tool's result goes once, whole")
    }

    @Test func grokSpeaksItsOwnWire() throws {
        let dialect = GrokVoiceDialect()
        let plan = LivePlan(voice: "eve", instructions: "Be Sol.", history: [LiveLine(fromPerson: true, text: "Hi there")],
                            agent: LiveAgentTool(agentName: "Sol"))
        let update = try #require(dialect.opening(plan).first)
        #expect(update["type"]?.string == "session.update" && update["session"]?["voice"]?.string == "eve")
        #expect(update["session"]?["instructions"]?.string?.contains("User: Hi there") == true, "the conversation so far in the instructions: items cost extra")
        #expect(update["session"]?["tools"]?.array?.first?["name"]?.string == "ask_agent")
        #expect(update["session"]?["audio"]?["input"]?["format"]?["rate"] == .number(16_000))
        #expect(dialect.read(#"{"type":"session.updated","session":{}}"#) == [.started])
        let pcm = Data([3, 0, 4, 0])
        #expect(dialect.read(#"{"type":"response.output_audio.delta","delta":"\#(pcm.base64EncodedString())"}"#) == [.audio(pcm)])
        #expect(dialect.read(#"{"type":"response.audio.delta","delta":"\#(pcm.base64EncodedString())"}"#) == [.audio(pcm)])
        #expect(dialect.read(#"{"type":"input_audio_buffer.speech_started","item_id":"i1"}"#) == [.interrupted])
        #expect(dialect.read(#"{"type":"response.function_call_arguments.done","call_id":"k1","name":"ask_agent","arguments":"{\"request\":\"Lights off\"}"}"#)
                == [.delegated(id: "k1", request: "Lights off")])
        guard case let .reply(pong)? = dialect.read(#"{"type":"ping","ping_timestamp":7}"#).first else { Issue.record("no pong"); return }
        let answered = try JSONValue.parse(Data(pong.utf8))
        #expect(answered["type"]?.string == "pong" && answered["ping_timestamp"] == .number(7))
        let answer = dialect.answer("Off.", to: "k1", final: true, eventID: "x")
        #expect(answer.first?["item"]?["type"]?.string == "function_call_output" && answer.first?["item"]?["call_id"]?.string == "k1")
        #expect(answer.last?["type"]?.string == "response.create")
        let preview = LivePlan(voice: "eve", instructions: "", greeting: LiveGreeting(line: "Hi, I'm Sol.", language: "English"))
        #expect(dialect.afterStart(preview, eventID: "x").first?["item"]?["type"]?.string == "force_message", "a preview's line word for word")
    }

    @Test func elevenLabsSpeaksItsOwnWire() throws {
        let dialect = ElevenLabsDialect()
        let plan = LivePlan(voice: "voice123", instructions: "Be Sol.", history: [LiveLine(fromPerson: true, text: "Hi")],
                            agent: LiveAgentTool(agentName: "Sol"))
        let opening = try #require(dialect.opening(plan).first)
        #expect(opening["type"]?.string == "conversation_initiation_client_data")
        let override = try #require(opening["conversation_config_override"])
        #expect(override["tts"]?["voice_id"]?.string == "voice123" && override["agent"]?["first_message"]?.string == "")
        #expect(override["agent"]?["prompt"]?["prompt"]?.string?.contains("User: Hi") == true)
        #expect(dialect.opening(LivePlan(voice: "", instructions: "")).first?["conversation_config_override"]?["tts"] == nil,
                "no voice picked: the agent's own")
        #expect(dialect.audio("AAAA") == #"{"user_audio_chunk":"AAAA"}"#)
        #expect(dialect.read(#"{"type":"conversation_initiation_metadata","conversation_initiation_metadata_event":{"conversation_id":"c"}}"#) == [.started])
        let pcm = Data([5, 0, 6, 0]).base64EncodedString()
        #expect(dialect.read(#"{"type":"audio","audio_event":{"audio_base_64":"\#(pcm)","event_id":3}}"#) == [.audio(Data([5, 0, 6, 0]))])
        #expect(dialect.read(#"{"type":"interruption","interruption_event":{"event_id":4}}"#) == [.interrupted])
        #expect(dialect.read(#"{"type":"audio","audio_event":{"audio_base_64":"\#(pcm)","event_id":4}}"#).isEmpty,
                "what was said before the person talked over it goes unplayed")
        #expect(dialect.read(#"{"type":"audio","audio_event":{"audio_base_64":"\#(pcm)","event_id":5}}"#).count == 1)
        #expect(dialect.read(#"{"type":"user_transcript","user_transcription_event":{"user_transcript":"Lights off"}}"#)
                == [.transcript(.person, "Lights off ", startMs: nil, endMs: nil)])
        #expect(dialect.read(#"{"type":"client_tool_call","client_tool_call":{"tool_name":"ask_agent","tool_call_id":"t1","parameters":{"request":"Lights off"}}}"#)
                == [.delegated(id: "t1", request: "Lights off")])
        guard case let .reply(pong)? = dialect.read(#"{"type":"ping","ping_event":{"event_id":9}}"#).first else { Issue.record("no pong"); return }
        let answered = try JSONValue.parse(Data(pong.utf8))
        #expect(answered["type"]?.string == "pong" && answered["event_id"] == .number(9))
        let result = try #require(dialect.answer("Off.", to: "t1", final: true, eventID: "x").first)
        #expect(result["type"]?.string == "client_tool_result" && result["tool_call_id"]?.string == "t1" && result["result"]?.string == "Off.")
    }

    @Test func aToolCallGetsTheWholeAnswerOnce() async throws {
        let harness = Harness(engine: .gemini)
        await harness.connect()
        #expect(harness.live.connected)
        harness.call.receive(#"{"serverContent":{"inputTranscription":{"text":"What's next on my calendar?"}}}"#)
        harness.call.receive(#"{"toolCall":{"functionCalls":[{"id":"c1","name":"ask_agent","args":{"request":"Next calendar event"}}]}}"#)
        try await Self.until { harness.live.state == .listening }
        #expect(harness.transport.requests.last?.userText == "What's next on my calendar?", "the person's own words are the message")
        #expect(harness.transport.requests.last?.live?.context.contains("Next calendar event") == true, "the voice's wording goes along")
        let responses = harness.call.sent.compactMap { $0["toolResponse"]?["functionResponses"]?.array?.first }
        #expect(responses.count == 1 && responses[0]["id"]?.string == "c1")
        #expect(responses[0]["response"]?["result"]?.string == "Your meeting is at 4 pm. It's with Ana.")
    }

    @Test func aBotsNameHeardJustAfterTheToolCallStillRoutes() async throws {
        let harness = Harness(engine: .gemini)
        harness.settings.spokenPrefixes = [SpokenPrefix(word: "Home", prefix: "", bot: "home")]
        await harness.connect()
        harness.call.receive(#"{"toolCall":{"functionCalls":[{"id":"c1","name":"ask_agent","args":{"request":"What's on the user's calendar today?"}}]}}"#)
        harness.call.receive(#"{"serverContent":{"inputTranscription":{"text":"Home, what's on my calendar today?"}}}"#)
        try await Self.until { harness.live.state == .listening }
        #expect(harness.conversation.bot?.profile == "home" && harness.call.reconnections.count == 1,
                "the person's words, written down after Gemini's call, still name Home")
    }

    @Test func aWithdrawnRequestStopsTheAgent() async throws {
        let harness = Harness(answerAfter: .seconds(5), engine: .gemini)
        await harness.connect()
        harness.call.receive(#"{"serverContent":{"inputTranscription":{"text":"Check the build."}}}"#)
        harness.call.receive(#"{"toolCall":{"functionCalls":[{"id":"c1","name":"ask_agent","args":{"request":"Check the build"}}]}}"#)
        try await Self.until { harness.conversation.isStreaming }
        harness.call.receive(#"{"toolCallCancellation":{"ids":["c1"]}}"#)
        #expect(!harness.conversation.isStreaming && harness.live.state == .listening)
    }

    @Test func aCallWithNoConnectionSendsNothing() {
        final class Listener: LiveCallListening {
            func liveCallReceived(_ event: String) {}
            func liveCallChanged(_ state: LiveCallState) {}
        }
        let listener = Listener()
        let call = LiveCall(listener: listener)
        #expect(call.inputLevel == 0 && call.outputLevel == 0 && !call.send("{}"))
        call.close()
        #expect(Bundle.main.path(forResource: "WebRTC", ofType: "framework", inDirectory: "Frameworks") == nil)
    }
}
