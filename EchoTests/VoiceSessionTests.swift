import AVFoundation
import Foundation
import Testing
@testable import Echo

/// Drives VoiceSession through fake hardware and a scripted transport to pin the voice
/// orchestration: phases, stop phrase, barge-in, hands-free relisten, offline hold, errors.
@MainActor
struct VoiceSessionTests {
    // MARK: Fakes

    final class FakeRecognizer: VoiceRecognizing {
        private(set) var transcript = ""
        let level: Float = 0
        private(set) var starts = 0
        private(set) var cancels = 0
        var onEnd: ((String) -> Void)?
        /// What `stop()` returns when the user taps to end the utterance.
        var pendingUtterance = ""
        /// Thrown by `start()`: the mic could not be opened.
        var startError: Error?

        func start(onEnd: @escaping (String) -> Void) async throws {
            if let startError { throw startError }
            starts += 1
            self.onEnd = onEnd
            mic = .listening
        }
        func stop() async -> String { pendingUtterance }
        func cancel() { cancels += 1; mic = .closed; heard = nil; watching = nil }
        /// Speech ended on its own: the recogniser closes the mic, then says what it heard.
        func deliver(_ text: String) { mic = .closed; onEnd?(text) }

        // The mic behind a reply.
        enum Mic: Equatable { case closed, held, listening }
        private(set) var mic = Mic.closed
        private(set) var heldStarts = 0
        /// Whether what was kept while held went to the recogniser, per `beginTranscribing`.
        private(set) var heldAudioUsed: [Bool] = []
        private(set) var watching: BargeInDetector?
        private var heard: (() -> Void)?

        func startHeld(onEnd: @escaping (String) -> Void) async throws {
            if let startError { throw startError }
            heldStarts += 1
            self.onEnd = onEnd
            mic = .held
        }
        func watchForVoice(_ detector: BargeInDetector?, heard: (() -> Void)?) {
            watching = detector
            self.heard = heard
        }
        /// Whether a pause would end the utterance now (false while only transcribing).
        private(set) var endsOnSilence = false
        func beginTranscribing(withHeldAudio: Bool, endsOnSilence: Bool) {
            guard mic == .held else { return }
            heldAudioUsed.append(withHeldAudio)
            mic = .listening
            watching = nil
            self.endsOnSilence = endsOnSilence
        }
        func endOnSilence() {
            guard mic == .listening else { return }
            endsOnSilence = true
        }
        func holdAgain() {
            guard mic == .listening else { return }
            mic = .held
            transcript = ""
            endsOnSilence = false
        }
        /// The level says someone is talking over the reply.
        func raiseVoice() { heard?() }
        /// The recogniser makes out words.
        func hear(_ words: String) { transcript = words }
    }

    final class FakeSpeaker: VoiceSpeaking {
        var onFirstSpeech: (() -> Void)?
        var onFinished: (() -> Void)?
        var speaker: String?
        private(set) var spoken: [String] = []
        private(set) var begins = 0
        private(set) var ends = 0
        private(set) var stops = 0
        private(set) var released = 0
        private(set) var pauses = 0
        private(set) var resumes = 0
        /// How loud the reply is right now: 0 while nothing is heard.
        var meterLevel: Float = 0
        func pause() { pauses += 1 }
        func resume() { resumes += 1 }

        func beginReply() { begins += 1 }
        func append(_ delta: String) {
            if spoken.isEmpty { onFirstSpeech?() }
            spoken.append(delta)
        }
        func endReply() { ends += 1 }
        func stop() { stops += 1 }
        func releaseAudio() { released += 1 }
        /// The synthesizer finished playing everything.
        func finishSpeaking() { onFinished?() }
    }

    final class FakeAudio: VoiceAudioControlling {
        var onInterruption: (() -> Void)?
        var onInterruptionEnded: ((Bool) -> Void)?
        var onOutputDeviceLost: (() -> Void)?
        private(set) var activations = 0
        private(set) var deactivations = 0
        var activationError: Error?
        var route = VoiceRoute.speaker

        func activateForVoice() throws {
            if let activationError { throw activationError }
            activations += 1
        }
        func deactivate() { deactivations += 1 }
        func refreshRoute() {}
        /// Each change of the at-ear routing, in order.
        private(set) var earRouting: [Bool] = []
        func setEarRouting(_ on: Bool) { earRouting.append(on) }
        /// Each change of the reply (not voice-chat) mode, in order.
        private(set) var replying: [Bool] = []
        func setReplying(_ on: Bool) { replying.append(on) }
    }

    // MARK: Harness

    /// Earcons the session played, in order.
    @MainActor final class CueLog {
        private(set) var cues: [VoiceSession.Earcon] = []
        func record(_ cue: VoiceSession.Earcon) { cues.append(cue) }
    }

    /// Each time the session held auto-lock off (true) or gave it back (false), in order.
    @MainActor final class AwakeLog {
        private(set) var changes: [Bool] = []
        func record(_ on: Bool) { changes.append(on) }
    }

    struct Harness {
        let session: VoiceSession
        let conversation: Conversation
        let recognizer = FakeRecognizer()
        let speaker = FakeSpeaker()
        let audio = FakeAudio()
        let cues = CueLog()
        let awake = AwakeLog()

        init(transport: any HermesTransport, talkOver: Settings.TalkOver = .off, interruption: Settings.Interruption = .speech,
             stopPhrases: [String] = [], commandsInCar: Bool = false, cueSettle: Duration = .zero) {
            let suite = UserDefaults(suiteName: "voice-\(UUID().uuidString)")!
            let settings = Settings(defaults: suite)
            settings.transport = .chatCompletions
            settings.fastLaneURL = "http://example.invalid:11500"
            settings.fastLaneModel = "test"
            let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString)"))
            conversation = Conversation(settings: settings, store: store, transportOverride: transport)
            conversation.retryDelays = [30]
            let (cues, awake) = (cues, awake)
            session = VoiceSession(conversation: conversation, recognizer: recognizer, output: speaker,
                                   audio: audio, requestPermissions: { true }, earcon: { cues.record($0) }, cueSettle: cueSettle,
                                   keepAwake: { awake.record($0) }, talkOver: { talkOver }, interruption: { interruption },
                                   commandsInCar: { commandsInCar }, stopPhrases: { stopPhrases })
        }
    }

    /// Polls a condition instead of sleeping past it; the voice pipeline hops through Tasks.
    private func waitUntil(_ what: String, timeout: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { Issue.record("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func reply(_ deltas: [String]) -> [TurnEvent] { deltas.map { .textDelta($0) } + [.done] }

    // MARK: Listening basics

    @Test func tapWhileIdleStartsListening() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([]))
        h.session.beginListening()
        try await waitUntil("recognizer start") { h.recognizer.starts == 1 }
        #expect(h.session.phase == .listening)
        #expect(h.audio.activations == 1)
    }

    /// A group chat's voice: what is said goes to the group chat, not the conversation, and the
    /// session is quiet again for the group chat to read its bots' replies, each to the end.
    @Test func whatIsSaidToAGroupChatGoesThere() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([]))
        var said: [String] = []
        h.session.sendsTo = { said.append($0) }
        h.session.continuous = true
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("Is Falls Loop open?")
        try await waitUntil("sent") { !said.isEmpty }
        #expect(said == ["Is Falls Loop open?"] && h.conversation.messages.isEmpty, "the room's, not the conversation's")
        #expect(h.session.phase == .idle && h.session.continuous)
        h.session.readAloud("Yes, it's open.")
        #expect(h.session.phase == .speaking && h.speaker.spoken.joined() == "Yes, it's open.")
        h.speaker.finishSpeaking()
        try await waitUntil("quiet again") { h.session.phase == .idle }
        #expect(h.recognizer.starts == 1, "the group chat opens the mic, once the round is over")
    }

    /// A lone letter heard is noise ("Q" from a car's hum, which a bot made a whole turn of): it
    /// isn't sent, and the session goes quiet as for nothing heard. A digit, or a word, is sent.
    @Test func aLoneLetterHeardIsNotSent() async throws {
        #expect(VoiceSession.isLoneLetter("Q") && VoiceSession.isLoneLetter(" q. ") && VoiceSession.isLoneLetter("É"))
        #expect(!VoiceSession.isLoneLetter("5") && !VoiceSession.isLoneLetter("OK") && !VoiceSession.isLoneLetter("") && !VoiceSession.isLoneLetter("I'm"))
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport(reply(["Hello."])))
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("Q")
        try await waitUntil("quiet") { h.session.phase == .idle }
        #expect(h.conversation.messages.isEmpty, "nothing went to the agent")
    }

    /// A reply read as it is written (a group chat's bot): spoken from its first words, quiet only
    /// once it has ended and been heard; once cut short, nothing more of it goes to the voice.
    @Test func wordsStillBeingWrittenAreReadAsTheyCome() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([]))
        #expect(h.session.beginReading(speaker: "scout"))
        #expect(h.session.phase == .speaking && h.speaker.speaker == "scout")
        h.session.continueReading("Falls Loop ")
        h.session.continueReading("is open.")
        #expect(h.speaker.spoken.joined() == "Falls Loop is open." && h.speaker.ends == 0)
        h.session.endReading()
        #expect(h.speaker.ends == 1 && h.session.phase == .speaking)
        h.speaker.finishSpeaking()
        try await waitUntil("quiet") { h.session.phase == .idle }
        #expect(h.recognizer.starts == 0, "a reading never opens the mic itself")
        #expect(h.session.beginReading(speaker: "writer"))
        h.session.cancel()
        h.session.continueReading("Saturday at eight.")
        #expect(h.speaker.spoken.joined() == "Falls Loop is open.")
    }

    /// Stop on a group chat's voice screen stops: the reading and the listening end, and the mic
    /// stays shut (the round over or not) until the person opens it again.
    @Test func stopInAGroupChatsVoiceKeepsTheMicShut() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([]))
        let voice = GroupVoice()
        let feed = GroupFeed(room: .demo)   // the screen's: the voice holds it weakly
        voice.start(feed, session: h.session)
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        voice.halt()
        voice.sessionChanged()
        #expect(h.session.phase == .idle && voice.isHeld)
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.recognizer.starts == 1, "stopped, not listening again")
        // A reply being read: Stop silences it, and still nothing listens.
        h.session.readAloud("Falls Loop is open.", speaker: "scout")
        voice.halt()
        voice.sessionChanged()
        #expect(h.session.phase == .idle && h.speaker.stops > 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.recognizer.starts == 1)
        // The orb opens the mic again, and the loop goes on.
        h.session.primaryAction()
        try await waitUntil("listening again") { h.recognizer.starts == 2 }
        voice.sessionChanged()
        #expect(!voice.isHeld)
        voice.stop()
    }

    /// In a bot's chat, voice mode reads the reply as that bot (its voice, `BotVoices`), and read
    /// aloud reads as whoever is named.
    @Test func aBotsReplyIsReadInItsVoice() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport(reply(["Three trails."])))
        h.conversation.replaceForDemo(messages: [], bot: BotRef(profile: "scout", name: "Scout"))
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("Any trails?")
        try await waitUntil("speaking") { !h.speaker.spoken.isEmpty }
        #expect(h.speaker.speaker == "scout")
        h.speaker.finishSpeaking()
        try await waitUntil("idle") { h.session.phase == VoiceSession.Phase.idle }
        h.session.readAloud("Falls Loop is open.", speaker: "writer")
        #expect(h.speaker.speaker == "writer")
    }

    @Test func deniedPermissionLandsInError() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([]))
        let session = VoiceSession(conversation: h.conversation, recognizer: h.recognizer, output: h.speaker,
                                   audio: h.audio, requestPermissions: { false })
        session.beginListening()
        try await waitUntil("error phase") { if case .error = session.phase { true } else { false } }
        #expect(h.recognizer.starts == 0)
    }

    @Test func emptyUtteranceReturnsToIdleAndReleasesAudio() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([]))
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("")
        try await waitUntil("idle") { h.session.phase == .idle }
        // Deactivation is deferred ~half a second so the stop cue can finish sounding.
        try await waitUntil("deactivated") { h.audio.deactivations >= 1 }
        #expect(h.conversation.messages.isEmpty, "nothing should have been sent")
    }

    // MARK: Earcons

    /// Ears alone must be able to tell the mic opened and closed again.
    @Test func listeningBoundariesPlayTheirEarcons() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport(reply(["ok"])))
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        #expect(h.cues.cues == [.listening])
        h.recognizer.deliver("hi")
        try await waitUntil("stopped cue") { h.cues.cues.count == 2 }
        #expect(h.cues.cues == [.listening, .stopped], "leaving listening must sound the close")
    }

    /// Leaving voice-chat mode restarts the audio, and under the stop cue it clipped the tone to a
    /// chirp: the mode and the route change once the cue has been heard, a change meanwhile with them.
    @Test func theModeChangesOnlyOnceTheStopCueIsHeard() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport(reply(["Hello", " there."])), cueSettle: .milliseconds(600))
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        let modes = h.audio.replying.count
        h.recognizer.deliver("hi")
        try await waitUntil("stopped cue") { h.cues.cues == [.listening, .stopped] }
        try await waitUntil("speaking") { h.session.phase == .speaking }
        #expect(h.audio.replying.count == modes, "nothing changed under the cue, through thinking and into speaking")
        #expect(h.audio.earRouting.last == false)
        try await waitUntil("the reply's mode, after the cue") { h.audio.replying.last == true }
        #expect(h.audio.earRouting.last == true)
    }

    @Test func interruptionWhileListeningSoundsTheClose() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([]))
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.audio.onInterruption?()
        #expect(h.cues.cues == [.listening, .stopped])
    }

    /// Listening survives the background now, so a locked phone must not keep the mic open —
    /// unless the person is hands-free or on the car's screen.
    @Test func lockingThePhoneStopsAnOpenMicUnlessHandsFreeOrInTheCar() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([]))
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.session.leftForeground(carPlayConnected: true)
        #expect(h.session.phase == .listening)
        h.session.continuous = true
        h.session.leftForeground(carPlayConnected: false)
        #expect(h.session.phase == .listening)
        h.session.continuous = false
        h.session.leftForeground(carPlayConnected: false)
        #expect(h.session.phase == .idle)
        #expect(h.recognizer.cancels == 1)
        #expect(h.cues.cues == [.listening, .stopped])
    }

    // MARK: Mute

    @Test func muteHoldsTheMicShutUntilItIsOpenedAgain() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([]))
        h.session.mute()
        #expect(!h.session.isMuted, "nothing to mute while idle")
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.session.mute()
        #expect(h.session.isMuted)
        #expect(h.session.phase == .idle)
        #expect(h.cues.cues == [.listening, .stopped])
        // The mic by any other route (the phone's button, a headset press) is an unmute.
        h.session.primaryAction()
        try await waitUntil("listening again") { h.recognizer.starts == 2 }
        #expect(!h.session.isMuted)
    }

    // MARK: Talking over a reply

    /// A turn asked and being answered, on headphones unless said otherwise. `hang`: the reply
    /// is still coming from the server.
    private func replying(talkOver: Settings.TalkOver = .headphones, route: VoiceRoute = .headphones, handsFree: Bool = false,
                          hang: Bool = true, interruption: Settings.Interruption = .speech, stopPhrases: [String] = [],
                          commandsInCar: Bool = false) async throws -> Harness {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([.textDelta("A long answer. "), .textDelta("It goes on.")], hang: hang),
                        talkOver: talkOver, interruption: interruption, stopPhrases: stopPhrases, commandsInCar: commandsInCar)
        h.audio.route = route
        h.session.continuous = handsFree
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("tell me everything")
        try await waitUntil("speaking") { h.session.phase == .speaking && h.speaker.spoken.count == 2 }
        return h
    }

    @Test func aReplyOnHeadphonesKeepsTheMicOpenButTranscribesNothing() async throws {
        let h = try await replying()
        try await waitUntil("the mic behind the reply") { h.recognizer.mic == .held }
        #expect(h.recognizer.heldStarts == 1)
        try await waitUntil("the watch for a voice") { h.recognizer.watching == .headset }
        #expect(h.recognizer.heldAudioUsed.isEmpty, "nothing reaches the recogniser while Redde speaks")
        #expect(!h.audio.replying.contains(true), "the session stays as it is for listening")
    }

    @Test(arguments: [(Settings.TalkOver.off, VoiceRoute.headphones), (.headphones, .speaker), (.everywhere, .car), (.headphones, .car)])
    func theMicStaysShutWhereTalkingOverIsNotOn(talkOver: Settings.TalkOver, route: VoiceRoute) async throws {
        let h = try await replying(talkOver: talkOver, route: route)
        try await Task.sleep(for: .milliseconds(60))
        #expect(h.recognizer.heldStarts == 0)
        #expect(h.recognizer.mic == .closed)
        #expect(h.audio.replying.last == true, "the reply plays at full volume, as before")
    }

    @Test func theSpeakerTakesTheSettingAndListensThroughEchoCancellation() async throws {
        let h = try await replying(talkOver: .everywhere, route: .speaker)
        try await waitUntil("the watch for a voice") { h.recognizer.watching == .echoCancelled }
        #expect(!h.audio.replying.contains(true), "voice-chat mode stays on: that is what cancels the echo")
    }

    @Test func wordsOverTheReplyStopItAndBecomeTheNextTurn() async throws {
        let h = try await replying()
        try await waitUntil("the watch for a voice") { h.recognizer.watching != nil }
        h.recognizer.raiseVoice()
        #expect(h.speaker.pauses == 1, "the reply is held while the recogniser listens")
        #expect(h.recognizer.heldAudioUsed == [true], "with the second before, so the first word isn't lost")
        #expect(h.session.phase == .speaking, "not an interruption until it is words")
        #expect(!h.recognizer.endsOnSilence, "a pause while that is found out must not end the listening")

        h.recognizer.hear("wait")
        try await waitUntil("the interruption") { h.session.phase == .listening }
        #expect(h.speaker.stops >= 1)
        #expect(!h.conversation.isStreaming, "the turn on the server stops too")
        #expect(h.recognizer.starts == 1, "the mic that heard it is the one listening")
        #expect(h.recognizer.mic == .listening)
        #expect(h.recognizer.endsOnSilence, "now it is an utterance, and a pause ends it")
        #expect(h.session.liveTranscript == "wait")

        h.recognizer.deliver("wait, I meant the other one")
        try await waitUntil("the next turn") { h.conversation.messages.contains { $0.role == .user && $0.text == "wait, I meant the other one" } }
    }

    @Test func aNoiseHoldsTheReplyAndThenItCarriesOn() async throws {
        let h = try await replying()
        h.session.confirmWindow = .milliseconds(150)
        try await waitUntil("the watch for a voice") { h.recognizer.watching != nil }
        let stops = h.speaker.stops
        h.recognizer.raiseVoice()
        #expect(h.speaker.pauses == 1)
        try await waitUntil("the reply carrying on") { h.speaker.resumes == 1 }
        #expect(h.session.phase == .speaking)
        #expect(h.recognizer.mic == .held, "back to waiting, with nothing transcribed")
        #expect(h.recognizer.watching != nil, "and watching again")
        #expect(h.conversation.isStreaming, "the turn was never touched")
        #expect(h.speaker.stops == stops, "and neither was the reply")
    }

    @Test func aListenersOkayDoesNotStopTheReplyButOkayStopDoes() async throws {
        let h = try await replying()
        h.session.confirmWindow = .milliseconds(250)
        try await waitUntil("the watch for a voice") { h.recognizer.watching != nil }
        h.recognizer.raiseVoice()
        h.recognizer.hear("Okay")
        try await waitUntil("the reply carrying on") { h.speaker.resumes == 1 }
        #expect(h.session.phase == .speaking)
        #expect(h.conversation.isStreaming)

        try await waitUntil("watching again") { h.recognizer.watching != nil }
        h.recognizer.raiseVoice()
        h.recognizer.hear("Okay")
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.session.phase == .speaking, "\"okay\" alone waits to see what follows")
        h.recognizer.hear("Okay, stop")
        try await waitUntil("the interruption") { h.session.phase == .listening }
        #expect(!h.conversation.isStreaming)
    }

    @Test func handsFreeListensOnTheOpenMicWhenTheReplyEnds() async throws {
        let h = try await replying(handsFree: true, hang: false)
        try await waitUntil("the mic behind the reply") { h.recognizer.mic == .held }
        try await waitUntil("the reply streamed") { !h.conversation.isStreaming }
        h.speaker.finishSpeaking()
        try await waitUntil("listening again") { h.session.phase == .listening }
        #expect(h.recognizer.starts == 1, "no second opening of the mic")
        #expect(h.recognizer.heldAudioUsed == [false], "nothing from while Redde spoke is transcribed")
        #expect(h.recognizer.endsOnSilence)
        #expect(h.cues.cues.last == .listening)
    }

    // "Only stop"

    @Test func withOnlyStopTheReplyPlaysOnThroughWhateverIsSaid() async throws {
        let h = try await replying(interruption: .stopWord)
        h.session.stopWordQuiet = .milliseconds(200)
        try await waitUntil("the watch for a voice") { h.recognizer.watching != nil }
        let stops = h.speaker.stops
        h.recognizer.raiseVoice()
        #expect(h.speaker.pauses == 0, "the reply is not held")
        #expect(h.recognizer.mic == .listening, "the recogniser listens for the word")
        #expect(!h.recognizer.endsOnSilence)
        h.recognizer.hear("so I told him we should go on Thursday")
        try await Task.sleep(for: .milliseconds(100))
        h.recognizer.hear("so I told him we should go on Thursday, and don't stop for coffee")
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.session.phase == .speaking)
        #expect(h.speaker.stops == stops, "nothing said stopped it, not even \"don't stop\"")
        #expect(h.conversation.isStreaming)
        // The talking ends: back to waiting for a voice, with no start of the reply to sit out.
        try await waitUntil("the level watch again") { h.recognizer.mic == .held && h.recognizer.watching != nil }
        #expect(h.recognizer.watching?.settle == 0)
        #expect(h.session.phase == .speaking)
    }

    @Test func withOnlyStopTheWordEndsTheReplyAndTheConversation() async throws {
        let h = try await replying(handsFree: true, interruption: .stopWord)
        try await waitUntil("the watch for a voice") { h.recognizer.watching != nil }
        h.recognizer.raiseVoice()
        h.recognizer.hear("okay that's enough")
        try await Task.sleep(for: .milliseconds(120))
        #expect(h.session.phase == .speaking)
        h.recognizer.hear("okay that's enough, stop")
        try await waitUntil("the reply ending") { h.speaker.spoken.last == "Okay." }
        #expect(!h.conversation.isStreaming, "the turn on the server stops too")
        #expect(h.recognizer.mic == .closed)
        #expect(!h.session.continuous, "stop means stop: hands-free ends with it")
        #expect(!h.conversation.messages.contains { $0.role == .user && $0.text.contains("enough") }, "what was said is no message")
        h.speaker.finishSpeaking()
        try await waitUntil("idle") { h.session.phase == .idle }
        #expect(h.recognizer.starts == 1, "and nothing listens afterwards")
    }

    @Test func withOnlyStopAPhraseOfThePersonsOwnEndsTheReplyToo() async throws {
        let h = try await replying(handsFree: true, interruption: .stopWord, stopPhrases: ["Das reicht"])
        try await waitUntil("the watch for a voice") { h.recognizer.watching != nil }
        h.recognizer.raiseVoice()
        h.recognizer.hear("das ist ja interessant")
        try await Task.sleep(for: .milliseconds(120))
        #expect(h.session.phase == .speaking, "other talk leaves the reply playing")
        h.recognizer.hear("das ist ja interessant. Okay, das reicht.")
        try await waitUntil("the reply ending") { h.speaker.spoken.last == "Okay." }
        #expect(!h.conversation.isStreaming)
        #expect(!h.session.continuous)
    }

    @Test func withOnlyStopHandsFreeStillListensAfterAReplyThatRanItsCourse() async throws {
        let h = try await replying(handsFree: true, hang: false, interruption: .stopWord)
        try await waitUntil("the watch for a voice") { h.recognizer.watching != nil }
        h.recognizer.raiseVoice()
        h.recognizer.hear("people talking")   // still transcribing when the reply ends
        try await waitUntil("the reply streamed") { !h.conversation.isStreaming }
        h.speaker.finishSpeaking()
        try await waitUntil("listening again") { h.session.phase == .listening }
        #expect(h.recognizer.mic == .listening)
        #expect(h.recognizer.endsOnSilence)
        #expect(h.recognizer.transcript.isEmpty, "the background talk is not the start of the next message")
        #expect(h.session.liveTranscript.isEmpty)
    }

    // Stop and Skip in the car (asked 2026-10-22)

    /// In the car, with the setting on, the mic stays open behind the reply whatever Talk over
    /// replies says, through the echo cancelling, and listens for two words alone.
    @Test func inTheCarTheMicListensBehindTheReplyOnlyForStopAndSkip() async throws {
        let h = try await replying(talkOver: .off, route: .car, interruption: .speech, commandsInCar: true)
        h.session.stopWordQuiet = .milliseconds(200)
        try await waitUntil("the watch for a voice") { h.recognizer.watching == .echoCancelled }
        let stops = h.speaker.stops
        h.recognizer.raiseVoice()
        #expect(h.speaker.pauses == 0, "the reply plays on: anything else said in a car is no interruption")
        h.recognizer.hear("turn left at the lights for the stopover, and don't skip the coffee")
        try await Task.sleep(for: .milliseconds(120))
        #expect(h.session.phase == .speaking && h.speaker.stops == stops, "not \"don't skip\", nor \"stop\" in the middle of a word")
        try await waitUntil("the level watch again") { h.recognizer.mic == .held && h.recognizer.watching != nil }
    }

    @Test func inTheCarStopEndsTheReply() async throws {
        let h = try await replying(route: .car, handsFree: true, commandsInCar: true)
        try await waitUntil("the watch for a voice") { h.recognizer.watching != nil }
        h.recognizer.raiseVoice()
        h.recognizer.hear("stop")
        try await waitUntil("the reply ending") { h.speaker.spoken.last == "Okay." }
        #expect(!h.conversation.isStreaming && !h.session.continuous, "as a stop phrase does: the turn and hands-free end")
    }

    /// "Skip": the rest of the reply isn't read. Hands-free, Redde listens for what's next, on the
    /// mic that was open already, with nothing of "skip" in it.
    @Test func inTheCarSkipJumpsToTheEndAndHandsFreeListens() async throws {
        let h = try await replying(route: .car, handsFree: true, commandsInCar: true)
        try await waitUntil("the watch for a voice") { h.recognizer.watching != nil }
        let stops = h.speaker.stops
        h.recognizer.raiseVoice()
        h.recognizer.hear("skip")
        try await waitUntil("listening") { h.session.phase == .listening }
        #expect(h.speaker.stops == stops + 1, "what was left of the reply is dropped")
        #expect(!h.speaker.spoken.contains("Okay."), "no word said back: a skip is quick")
        #expect(!h.conversation.isStreaming, "a reply still on its way stops there")
        #expect(h.session.continuous, "hands-free goes on")
        #expect(h.recognizer.mic == .listening && h.recognizer.endsOnSilence)
        #expect(h.recognizer.transcript.isEmpty && h.session.liveTranscript.isEmpty, "\"skip\" is not the start of the next message")
        #expect(h.cues.cues.last == .listening)
    }

    @Test func inTheCarSkipWithOneQuestionEndsIt() async throws {
        let h = try await replying(route: .car, commandsInCar: true)
        try await waitUntil("the watch for a voice") { h.recognizer.watching != nil }
        h.recognizer.raiseVoice()
        h.recognizer.hear("okay skip")
        try await waitUntil("idle") { h.session.phase == .idle }
        #expect(h.recognizer.mic == .closed)
        #expect(h.recognizer.starts == 1, "nothing listens afterwards")
    }

    /// Off the car, "skip" is just a word: it neither ends a reply nor stops one.
    @Test func skipCountsOnlyInTheCar() async throws {
        let h = try await replying(interruption: .stopWord, commandsInCar: true)
        h.session.stopWordQuiet = .milliseconds(200)
        try await waitUntil("the watch for a voice") { h.recognizer.watching != nil }
        h.recognizer.raiseVoice()
        h.recognizer.hear("skip")
        try await Task.sleep(for: .milliseconds(120))
        #expect(h.session.phase == .speaking)
    }

    @Test func oneQuestionClosesTheMicWhenTheReplyEnds() async throws {
        let h = try await replying(hang: false)
        try await waitUntil("the mic behind the reply") { h.recognizer.mic == .held }
        try await waitUntil("the reply streamed") { !h.conversation.isStreaming }
        h.speaker.finishSpeaking()
        try await waitUntil("idle") { h.session.phase == .idle }
        #expect(h.recognizer.mic == .closed)
        #expect(h.recognizer.watching == nil)
    }

    @Test func tappingTheMicStillCutsInAndAPausedReplyIsNotWatched() async throws {
        let h = try await replying()
        try await waitUntil("the watch for a voice") { h.recognizer.watching != nil }
        h.session.pauseSpeaking()
        #expect(h.recognizer.watching == nil, "nothing to talk over while it is paused")
        h.session.resumeSpeaking()
        #expect(h.recognizer.watching != nil)

        h.session.beginListening()
        try await waitUntil("listening afresh") { h.recognizer.starts == 2 }
        #expect(h.session.phase == .listening)
        #expect(h.recognizer.mic == .listening)
        #expect(h.recognizer.watching == nil)
    }

    @Test func headphonesComingOutCloseTheMicBehindTheReply() async throws {
        let h = try await replying()
        try await waitUntil("the mic behind the reply") { h.recognizer.mic == .held }
        h.audio.onOutputDeviceLost?()
        #expect(h.session.phase == .idle)
        #expect(h.recognizer.mic == .closed)
    }

    // MARK: Stop phrase

    @Test func stopPhraseAcknowledgesAndEndsHandsFree() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([]))
        h.session.continuous = true
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("that's all")
        try await waitUntil("speaking") { h.session.phase == .speaking }
        #expect(h.speaker.spoken == ["Okay."])
        #expect(h.session.continuous == false)
        #expect(h.conversation.messages.isEmpty, "a stop phrase is not a turn")
        h.speaker.finishSpeaking()
        try await waitUntil("idle") { h.session.phase == .idle }
        #expect(h.recognizer.starts == 1, "hands-free ended; no relisten")
    }

    @Test func aStopPhraseOfThePersonsOwnEndsHandsFreeAndOthersAreQuestions() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport(reply(["Sure."])), stopPhrases: ["basta così", "Feierabend"])
        h.session.continuous = true
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("Okay, basta cosi.")   // heard without the accent
        try await waitUntil("speaking") { h.session.phase == .speaking }
        #expect(h.speaker.spoken == ["Okay."])
        #expect(!h.session.continuous)
        #expect(h.conversation.messages.isEmpty, "a stop phrase is not a turn")

        // Without it in the list, the same words are a message for the agent.
        let plain = Harness(transport: ConversationLifecycleTests.ScriptedTransport(reply(["Sure."])))
        plain.session.beginListening()
        try await waitUntil("listening") { plain.recognizer.starts == 1 }
        plain.recognizer.deliver("Feierabend")
        try await waitUntil("the turn") { plain.conversation.messages.contains { $0.role == .user && $0.text == "Feierabend" } }
    }

    // MARK: A full turn

    @Test func utteranceStreamsSpeaksAndRecordsMetrics() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport(reply(["Hello", " there."])))
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("hi")
        try await waitUntil("reply spoken") { h.speaker.spoken.count == 2 }
        #expect(h.session.phase == .speaking)
        #expect(h.speaker.spoken.joined() == "Hello there.")
        try await waitUntil("reply ended") { h.speaker.ends >= 1 }
        h.speaker.finishSpeaking()
        try await waitUntil("idle") { h.session.phase == .idle }
        #expect(h.session.lastMetrics != nil)
        #expect(h.session.lastMetrics?.endToFirstWord != nil)
    }

    /// When a reply was first heard, for the car's face (its mouth waits for the sound): none
    /// while it is thought about, set by the first sound, gone once the reply is over.
    @Test func whenTheReplyWasFirstHeard() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport(reply(["Hello", " there."])))
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        #expect(h.session.soundStartedAt == nil)
        h.recognizer.deliver("hi")
        try await waitUntil("reply spoken") { h.speaker.spoken.count == 2 }
        let heard = try #require(h.session.soundStartedAt)
        #expect(abs(heard.timeIntervalSinceNow) < 5)
        try await waitUntil("reply ended") { h.speaker.ends >= 1 }
        h.speaker.finishSpeaking()
        try await waitUntil("idle") { h.session.phase == .idle }
        #expect(h.session.soundStartedAt == nil)
    }

    /// The proximity sensor blanks the screen when covered, so it's only on while speaking,
    /// never through listening or a long think.
    /// Voice-chat mode (call-volume buttons) only while the mic is open: thinking and speaking run
    /// in the default mode, where the volume buttons reach the reply.
    @Test func replyModeWhileThinkingAndSpeaking() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport(reply(["Hello", " there."])))
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        #expect(h.audio.replying.last == false)
        h.recognizer.deliver("hi")
        try await waitUntil("speaking") { h.session.phase == .speaking }
        #expect(h.audio.replying.last == true)
        try await waitUntil("reply ended") { h.speaker.ends >= 1 }
        h.speaker.finishSpeaking()
        try await waitUntil("idle") { h.session.phase == .idle }
        #expect(h.audio.replying.last == false)
    }

    @Test func earRoutingOnlyWhileSpeaking() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport(reply(["Hello", " there."])))
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        #expect(h.audio.earRouting.last == false)
        h.recognizer.deliver("hi")
        try await waitUntil("speaking") { h.session.phase == .speaking }
        #expect(h.audio.earRouting.last == true)
        try await waitUntil("reply ended") { h.speaker.ends >= 1 }
        h.speaker.finishSpeaking()
        try await waitUntil("idle") { h.session.phase == .idle }
        #expect(h.audio.earRouting.last == false)
        // One "on", for the one spoken reply: nothing turned it on while listening or thinking.
        #expect(h.audio.earRouting.filter { $0 }.count == 1)
    }

    @Test func handsFreeRelistensAfterTheReply() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport(reply(["ok"])))
        h.session.continuous = true
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("hi")
        try await waitUntil("spoken") { !h.speaker.spoken.isEmpty && h.speaker.ends >= 1 }
        h.speaker.finishSpeaking()
        try await waitUntil("relisten") { h.recognizer.starts == 2 }
        #expect(h.session.phase == .listening)
    }

    // MARK: Barge-in and cancellation

    @Test func bargeInWhileSpeakingStopsOutputAndServerTurn() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([.textDelta("stream")], hang: true))
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("long question")
        try await waitUntil("speaking") { h.session.phase == .speaking }
        #expect(h.conversation.isStreaming)
        h.session.beginListening()   // barge in
        try await waitUntil("listening again") { h.recognizer.starts == 2 }
        #expect(h.speaker.stops >= 1)
        try await waitUntil("server turn cancelled") { !h.conversation.isStreaming }
    }

    @Test func outputDeviceLostWhileSpeakingGoesQuiet() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([.textDelta("stream")], hang: true))
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("what time is it")
        try await waitUntil("speaking") { h.session.phase == .speaking }
        h.audio.onOutputDeviceLost?()
        #expect(h.session.phase == .idle)
        #expect(h.speaker.stops >= 1)
    }

    /// AirPods out mid-reply: the deltas still streaming must not restart the reply on the
    /// loudspeaker, and the turn's end must not reopen the mic.
    @Test func outputDeviceLostStopsMirroringTheRestOfTheReply() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport(
            [.textDelta("first. "), .textDelta("second. "), .textDelta("third. "), .done]))
        h.session.continuous = true
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("what time is it")
        try await waitUntil("speaking") { h.session.phase == .speaking }
        h.audio.onOutputDeviceLost?()
        let heard = h.speaker.spoken.count
        try await waitUntil("transcript completes") { !h.conversation.isStreaming }
        #expect(h.speaker.spoken.count == heard, "later deltas must not be spoken")
        #expect(h.session.phase == .idle)
        #expect(h.recognizer.starts == 1, "hands-free must not relisten after the device went away")
        #expect(h.conversation.messages.last?.text.contains("third") == true, "the transcript still completes")
    }

    /// Leaving the voice screen cancels only a turn the voice session started.
    @Test func cancelLeavesATypedTurnAlone() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([.textDelta("typing")], hang: true))
        _ = h.conversation.send("typed question")
        try await waitUntil("typed turn streaming") { h.conversation.isStreaming }
        h.session.cancel()
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.conversation.isStreaming, "a typed reply is not the voice session's to cancel")
        h.conversation.cancel()
    }

    @Test func listenFailureReleasesTheAudioSession() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([]))
        h.recognizer.startError = SpeechRecognizer.Failure.assetsUnavailable
        h.session.beginListening()
        try await waitUntil("error phase") { if case .error = h.session.phase { true } else { false } }
        #expect(h.audio.activations == 1)
        #expect(h.audio.deactivations == 1, "an activation for a listen that never happened must be undone")
    }

    @Test func cancelDuringListenSetupStaysIdle() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([]))
        h.recognizer.startError = CancellationError()
        h.session.beginListening()
        h.session.cancel()
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.session.phase == .idle, "a cancelled setup must not surface as an error")
    }

    @Test func interruptionStopsAndResumeRestartsListening() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([]))
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.audio.onInterruption?()
        #expect(h.session.phase == .idle)
        h.audio.onInterruptionEnded?(true)
        try await waitUntil("relisten") { h.recognizer.starts == 2 }
        #expect(h.session.phase == .listening)
    }

    @Test func interruptionEndedWithoutResumeStaysQuiet() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([]))
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.audio.onInterruption?()
        h.audio.onInterruptionEnded?(false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.session.phase == .idle)
        #expect(h.recognizer.starts == 1)
    }

    // MARK: Failure paths

    @Test func transportErrorLandsInErrorPhase() async throws {
        let h = Harness(transport: ConversationLifecycleTests.SequencedTransport(
            [.init(events: [], error: URLError(.badServerResponse))]))
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("hi")
        try await waitUntil("error phase") { if case .error = h.session.phase { true } else { false } }
        #expect(h.speaker.stops >= 1)
        #expect(h.audio.deactivations >= 1)
    }

    @Test func offlineHoldSpeaksTheNoticeInsteadOfWaiting() async throws {
        let h = Harness(transport: ConversationLifecycleTests.SequencedTransport(
            [.init(events: [], error: URLError(.notConnectedToInternet))]))
        h.session.continuous = true
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("are you there")
        try await waitUntil("notice spoken") { h.speaker.spoken.contains { $0.contains("can't reach your server") } }
        #expect(h.session.continuous == false, "hands-free must not loop against a dead server")
        h.speaker.finishSpeaking()
        try await waitUntil("idle") { h.session.phase == .idle }
    }

    // MARK: Replay

    // MARK: The screen

    /// Auto-lock is held off from the mic opening until the reply has been spoken, in one
    /// stretch, and given back when the turn is over.
    @Test func theScreenStaysOnThroughAVoiceTurnAndIsGivenBackAfter() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport(reply(["Hello", " there."])))
        #expect(h.awake.changes.isEmpty)
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        #expect(h.awake.changes == [true])
        h.recognizer.deliver("hi")
        try await waitUntil("speaking") { h.session.phase == .speaking }
        #expect(h.awake.changes == [true], "held across listening, thinking and speaking without letting go")
        try await waitUntil("reply ended") { h.speaker.ends >= 1 }
        h.speaker.finishSpeaking()
        try await waitUntil("idle") { h.session.phase == .idle }
        #expect(h.awake.changes == [true, false])
    }

    @Test func aMicThatIsClosedGivesAutoLockBack() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([]))
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.session.cancel()
        #expect(h.session.phase == .idle)
        #expect(h.awake.changes == [true, false])
    }

    /// A reply read from the transcript's speaker button, or replayed, counts as speaking; a
    /// paused one doesn't.
    @Test func readingAloudHoldsTheScreenAndAPauseLetsGo() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([]))
        h.session.readAloud("A long answer, read out.")
        #expect(h.session.phase == .speaking)
        #expect(h.awake.changes == [true])
        h.session.pauseSpeaking()
        #expect(h.awake.changes == [true, false])
        h.session.resumeSpeaking()
        #expect(h.awake.changes == [true, false, true])
        h.speaker.finishSpeaking()
        try await waitUntil("idle") { h.session.phase == .idle }
        #expect(h.awake.changes == [true, false, true, false])
    }

    /// Waiting on a long task doesn't hold the screen on for ever: the reply carries on with the
    /// phone locked.
    @Test func aLongWaitForTheReplyLetsThePhoneLock() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([], hang: true))
        h.session.awakeWhileThinking = .milliseconds(120)
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("do the long thing")
        try await waitUntil("thinking") { h.session.phase == .thinking }
        #expect(h.awake.changes == [true])
        try await waitUntil("let go") { h.awake.changes == [true, false] }
        #expect(h.session.phase == .thinking, "the turn itself is untouched")
        h.session.cancel()
    }

    @Test func aMicThatCouldntOpenGivesAutoLockBack() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([]))
        h.recognizer.startError = SpeechRecognizer.Failure.assetsUnavailable
        h.session.beginListening()
        try await waitUntil("error") { if case .error = h.session.phase { true } else { false } }
        #expect(h.awake.changes == [true, false])
    }

    @Test func replaySpeaksTheLastReplyWithoutANewTurn() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport(reply(["The answer."])))
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("what time is it")
        try await waitUntil("done") { h.speaker.ends >= 1 }
        h.speaker.finishSpeaking()
        try await waitUntil("idle") { h.session.phase == .idle }
        let sentTurns = h.conversation.messages.count

        h.session.replayLastReply()
        #expect(h.session.phase == .speaking)
        try await waitUntil("replayed") { h.speaker.spoken.last == "The answer." }
        h.speaker.finishSpeaking()
        try await waitUntil("idle again") { h.session.phase == .idle }
        #expect(h.conversation.messages.count == sentTurns, "replay is not a turn")
    }

    // MARK: A call that can't open saying a line

    /// A voice session whose chat has a live call that can't open saying a line of Redde's
    /// (Hermes Live / Codex: the plugin on the person's Hermes words its sessions), and how many
    /// calls it made.
    private func lineless(_ transport: any HermesTransport, speaker: FakeSpeaker) -> (VoiceSession, LiveVoiceTests.Box<Int>) {
        let settings = Settings(defaults: UserDefaults(suiteName: "voice-\(UUID().uuidString)")!)
        settings.transport = .chatCompletions
        settings.fastLaneURL = "http://example.invalid:11500"
        settings.fastLaneModel = "test"
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString)"))
        let conversation = Conversation(settings: settings, store: store, transportOverride: transport)
        let calls = LiveVoiceTests.Box<Int>(0)
        let session = VoiceSession(conversation: conversation, recognizer: FakeRecognizer(), output: speaker, audio: FakeAudio(),
                                   requestPermissions: { true }, earcon: { _ in }, cueSettle: .zero, keepAwake: { _ in }, talkOver: { .off },
                                   liveWanted: { _ in true }, liveGreets: { _ in false },
                                   makeLive: { conversation in
                                       calls.value += 1
                                       return LiveVoice(conversation: conversation, settings: settings, engine: .hermesLive,
                                                        makeCall: { _, _ in throw LiveFailure("no call in this test") })
                                   },
                                   micAllowed: { true })
        return (session, calls)
    }

    /// "Hey Home, turn the lights off" where Home's chat is a Hermes Live call: the request is asked
    /// and its answer read here, in Redde's own voice, not dropped by a call that can't say it.
    @Test func aWakeRequestACallCantOpenSayingIsAnsweredHere() async throws {
        let speaker = FakeSpeaker()
        let (session, calls) = lineless(ConversationLifecycleTests.ScriptedTransport(reply(["The lights are off."])), speaker: speaker)
        session.ask("Turn the lights off")
        try await waitUntil("answered") { speaker.spoken.joined() == "The lights are off." }
        #expect(!session.isLive && calls.value == 0, "asked here, in Redde's own voice")
        session.cancel()
    }

    /// An agent's call answered where its chat is a Hermes Live call: its line is said here first,
    /// and the call opens after it.
    @Test func anAgentsLineACallCantOpenSayingIsSaidHere() async throws {
        let speaker = FakeSpeaker()
        let (session, calls) = lineless(ConversationLifecycleTests.ScriptedTransport([]), speaker: speaker)
        var ended = false
        session.answerCall(saying: "Your build failed.", listen: true, ended: { ended = true })
        #expect(speaker.spoken == ["Your build failed."] && session.phase == .speaking, "the line said here first")
        #expect(!session.isLive && calls.value == 0)
        session.cancel()
        #expect(ended)
    }
}

