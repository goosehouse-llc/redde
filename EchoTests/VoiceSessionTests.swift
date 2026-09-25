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
        }
        func stop() async -> String { pendingUtterance }
        func cancel() { cancels += 1 }
        /// Speech ended on its own.
        func deliver(_ text: String) { onEnd?(text) }
    }

    final class FakeSpeaker: VoiceSpeaking {
        var onFirstSpeech: (() -> Void)?
        var onFinished: (() -> Void)?
        private(set) var spoken: [String] = []
        private(set) var begins = 0
        private(set) var ends = 0
        private(set) var stops = 0
        private(set) var released = 0

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

        func activateForVoice() throws {
            if let activationError { throw activationError }
            activations += 1
        }
        func deactivate() { deactivations += 1 }
        func refreshRoute() {}
    }

    // MARK: Harness

    /// Earcons the session played, in order.
    @MainActor final class CueLog {
        private(set) var cues: [VoiceSession.Earcon] = []
        func record(_ cue: VoiceSession.Earcon) { cues.append(cue) }
    }

    struct Harness {
        let session: VoiceSession
        let conversation: Conversation
        let recognizer = FakeRecognizer()
        let speaker = FakeSpeaker()
        let audio = FakeAudio()
        let cues = CueLog()

        init(transport: any HermesTransport) {
            let suite = UserDefaults(suiteName: "voice-\(UUID().uuidString)")!
            let settings = Settings(defaults: suite)
            settings.transport = .chatCompletions
            settings.fastLaneURL = "http://example.invalid:11500"
            settings.fastLaneModel = "test"
            let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString)"))
            conversation = Conversation(settings: settings, store: store, transportOverride: transport)
            conversation.retryDelays = [30]
            let cues = cues
            session = VoiceSession(conversation: conversation, recognizer: recognizer, output: speaker,
                                   audio: audio, requestPermissions: { true }, earcon: { cues.record($0) })
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

    @Test func interruptionWhileListeningSoundsTheClose() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport([]))
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.audio.onInterruption?()
        #expect(h.cues.cues == [.listening, .stopped])
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
        h.recognizer.deliver("q")
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
        h.recognizer.deliver("q")
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

    @Test func replaySpeaksTheLastReplyWithoutANewTurn() async throws {
        let h = Harness(transport: ConversationLifecycleTests.ScriptedTransport(reply(["The answer."])))
        h.session.beginListening()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("q")
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
}
