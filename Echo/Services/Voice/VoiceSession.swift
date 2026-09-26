import AudioToolbox
import AVFoundation
import Foundation
import Observation
import os

/// Plays the bundled listening tones through the app's audio session: on the active
/// `.playAndRecord` voice session they ignore the ring/silent switch, like Siri's cues —
/// the user just asked to talk, so the cues are wanted. Bundled files, not the
/// `/System/Library/Audio/UISounds` ones: the device sandbox can refuse those, which
/// silently degraded to a ringer-muted system sound.
@MainActor
final class EarconPlayer {
    static let shared = EarconPlayer()
    private var players: [VoiceSession.Earcon: AVAudioPlayer] = [:]

    private init() {
        for (cue, name) in [(VoiceSession.Earcon.listening, "listen-start"), (.stopped, "listen-stop")] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { continue }
            players[cue] = try? AVAudioPlayer(contentsOf: url)
            players[cue]?.prepareToPlay()
        }
    }

    func play(_ cue: VoiceSession.Earcon) {
        guard let player = players[cue] else { return }
        player.currentTime = 0
        player.play()
    }
}

/// One voice turn: listen → transcribe → send → stream reply → speak.
/// Drives the recognizer, the conversation store, and the synthesizer, and records where the
/// time goes. This is the object the Siri intent will hand off to in M2.
@Observable
final class VoiceSession {
    /// The app's one voice session, for scenes that can't take SwiftUI environment (CarPlay).
    static weak var current: VoiceSession?   // MainActor-isolated like everything here; reader (CarPlay) is too

    enum Phase: Equatable {
        case idle, listening, thinking, speaking
        case error(String)
    }

    /// Audible cues at the listening boundaries, so ears alone can tell the mic is open.
    nonisolated enum Earcon { case listening, stopped }

    private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            if phase != .speaking { isPaused = false }
            // The at-ear sensor only while speaking: it blanks the screen whenever it's covered.
            audio.setEarRouting(phase == .speaking)
            if headsetControlsOn { publishNowPlaying() }
            // Every path OUT of listening funnels through here: utterance end, tap,
            // interruption, AirPods coming out. The start cue plays in startRecognizer
            // instead — at phase-set time the audio session isn't active or routed yet,
            // which made the tone land on the earpiece or the silent-switch session.
            if oldValue == .listening { earcon(.stopped) }
        }
    }
    private var headsetControlsOn = false
    private(set) var liveTranscript = ""
    private(set) var activeTool: String?
    private(set) var lastMetrics: VoiceMetrics?
    /// When true, the mic reopens automatically after each reply (hands-free mode, M2).
    var continuous = false

    let recognizer: any VoiceRecognizing
    let output: any VoiceSpeaking
    private let conversation: Conversation
    private let audio: any VoiceAudioControlling
    /// Injectable so tests never touch the Speech authorization prompt.
    private let requestPermissions: () async -> Bool
    /// Injectable so tests observe the cues instead of playing sounds.
    private let earcon: (Earcon) -> Void
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "voice")
    private var metrics = VoiceMetrics()
    private var replyTask: Task<Void, Never>?
    private var replySerial = 0
    /// True while speaking the "Okay." that confirms a stop phrase; not a real turn.
    private var acknowledging = false
    private var replaying = false
    /// The reply is held by the voice screen's Pause button; still `.speaking`.
    private(set) var isPaused = false
    private var replayResumesHandsFree = true

    /// The last thing Hermes said, if any; what Replay speaks.
    var lastReplyText: String? {
        conversation.messages.last { $0.role == .assistant && !$0.text.isEmpty }?.text
    }

    /// Speak the last reply again. Works from idle; tapping the mic while it plays interrupts.
    func replayLastReply() {
        guard let text = lastReplyText else { return }
        readAloud(text, resumeHandsFree: true)
    }

    /// Speak any reply: the transcript's "Read aloud", and Replay. Works from idle; `stopSpeaking`
    /// or tapping the mic ends it. Only the voice screen's Replay reopens the mic afterwards in
    /// hands-free; reading from the transcript never starts listening.
    func readAloud(_ text: String, resumeHandsFree: Bool = false) {
        guard phase == .idle || isErrored, !text.isEmpty else { return }
        do { try audio.activateForPlayback() } catch {
            phase = .error(error.localizedDescription); return
        }
        replaying = true
        replayResumesHandsFree = resumeHandsFree
        phase = .speaking
        output.beginReply()
        output.append(text)
        output.endReply()
    }
    /// Set when an interruption cut a live turn short; listening restarts when it ends.
    private var resumeAfterInterruption = false

    init(conversation: Conversation,
         recognizer: any VoiceRecognizing = SpeechRecognizer(),
         output: any VoiceSpeaking = SpeechOutput(),
         audio: any VoiceAudioControlling = AudioSessionController.shared,
         requestPermissions: @escaping () async -> Bool = { await SpeechRecognizer.requestPermissions() },
         earcon: @escaping (Earcon) -> Void = { EarconPlayer.shared.play($0) }) {
        self.conversation = conversation
        self.recognizer = recognizer
        self.output = output
        self.audio = audio
        self.requestPermissions = requestPermissions
        self.earcon = earcon
        output.onFirstSpeech = { [weak self] in
            self?.metrics.firstSpokenAt = .now
            // Starting playback (Kokoro's engine, or the synthesizer) can put the output back on
            // the earpiece, and that route change isn't one we re-route on. Re-assert speaker vs.
            // earpiece the moment sound starts; Replay, which speaks right after activating, went
            // to the earpiece every time without this.
            self?.audio.refreshRoute()
        }
        output.onFinished = { [weak self] in
            self?.replyFinishedSpeaking()
        }
        // Siri (or a call) taking the mic mid-listen: stop cleanly, then pick up again the
        // moment the system gives the session back. This is what makes "Hey Siri, open Redde"
        // flow into listening without a tap once Siri's follow-up window closes.
        audio.onInterruption = { [weak self] in
            guard let self else { return }
            resumeAfterInterruption = phase == .listening || phase == .thinking || phase == .speaking
            cancel()
        }
        audio.onInterruptionEnded = { [weak self] shouldResume in
            guard let self, resumeAfterInterruption else { return }
            resumeAfterInterruption = false
            // The system says not to resume (Siri still up, an alarm): stay quiet instead of
            // fighting for the mic.
            guard shouldResume else { log.info("interruption ended without resume"); return }
            log.info("resuming listening after interruption")
            beginListening()
        }
        audio.onOutputDeviceLost = { [weak self] in
            guard let self else { return }
            switch phase {
            case .speaking:
                // Stop mirroring the stream too: the next delta would otherwise restart the
                // player on the loudspeaker. The transcript still completes on its own.
                replyTask?.cancel(); replyTask = nil
                output.stop()
                phase = .idle
                output.releaseAudio(); audio.deactivate()
            case .listening:
                // AirPods came out mid-question: stop, rather than carry on through the phone's mic.
                continuous = false
                cancel()
            default:
                break
            }
        }
    }

    /// What tapping the mic does in each phase; AirPods and Lock Screen presses do the same.
    func primaryAction() {
        switch phase {
        case .idle, .error: beginListening()
        case .listening: endListening()
        case .thinking: cancel()
        case .speaking: beginListening()
        }
    }

    /// While the voice screen is open, headset presses drive the mic.
    func attachHeadsetControls() {
        headsetControlsOn = true
        HeadsetControls.shared.enable { [weak self] in self?.primaryAction() }
        publishNowPlaying()
    }

    func detachHeadsetControls() {
        headsetControlsOn = false
        HeadsetControls.shared.disable()
    }

    private func publishNowPlaying() {
        let status = switch phase {
        case .idle: "Ready"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .error: "Tap to try again"
        }
        HeadsetControls.shared.setNowPlaying(status: status, active: phase == .listening || phase == .speaking)
    }

    var isListening: Bool { phase == .listening }
    var mightBeBusy: Bool { phase != .idle }

    // MARK: - Public actions

    /// Tap the mic: start listening. If a reply is being spoken, this barges in.
    func beginListening() {
        replaying = false
        guard phase == .idle || phase == .speaking || isErrored else { return }
        output.stop()
        replyTask?.cancel()
        // Barge-in: stop the server turn too, or it keeps streaming (and billing) unheard.
        if conversation.isStreaming { conversation.cancel() }
        metrics = VoiceMetrics()
        phase = .listening
        liveTranscript = ""
        Task { await startRecognizer() }
    }

    /// Tap again while listening: end the utterance now.
    func endListening() {
        guard phase == .listening else { return }
        Task {
            let text = await recognizer.stop()
            await handleUtterance(text)
        }
    }

    /// The voice screen's Pause / Play while a reply is being read.
    func pauseSpeaking() {
        guard phase == .speaking, !isPaused else { return }
        output.pause()
        isPaused = true
    }

    func resumeSpeaking() {
        guard phase == .speaking, isPaused else { return }
        output.resume()
        isPaused = false
    }

    /// The Stop button while speaking: silence the reply and go idle. Hands-free stays
    /// switched on for the next tap; the server turn is cancelled if it is still streaming.
    func stopSpeaking() {
        guard phase == .speaking else { return }
        cancel()
    }

    func cancel() {
        replaying = false
        // Only a turn this session started is ours to cancel: leaving the voice screen while a
        // typed reply streams must not kill it.
        let ownsTurn = replyTask != nil
        replyTask?.cancel()
        replyTask = nil
        output.stop()
        recognizer.cancel()
        if ownsTurn { conversation.cancel() }
        let wasListening = phase == .listening
        phase = .idle
        if wasListening { releaseAudioAfterCue() } else { output.releaseAudio(); audio.deactivate() }
    }

    /// Deactivating in the same beat as the stop cue clips it; give the tone a moment to
    /// finish before handing the session back (other audio resumes ~half a second later).
    private func releaseAudioAfterCue() {
        output.releaseAudio()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, phase == .idle || isErrored else { return }
            audio.deactivate()
        }
    }

    // MARK: - Pipeline

    private func startRecognizer() async {
        do {
            guard await requestPermissions() else {
                throw SpeechRecognizer.Failure.permissionDenied
            }
            do {
                try audio.activateForVoice()
            } catch {
                // Siri usually still owns the session right after launching us. Retry for a while.
                log.info("audio activation failed (\(error.localizedDescription)); retrying")
                var attempts = 0
                while attempts < 25 {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard phase == .listening else { return }
                    if (try? audio.activateForVoice()) != nil { break }
                    attempts += 1
                }
                if attempts >= 25 { throw error }
                log.info("audio activated after \(attempts + 1) retries")
            }
            try await recognizer.start { [weak self] text in
                Task { await self?.handleUtterance(text) }
            }
            audio.refreshRoute()   // the engine's voice-processing unit just reset the output
            earcon(.listening)     // audible now: the session is active and routed
            metrics.listenStartedAt = .now
            observeTranscript()
        } catch {
            // Cancelled meanwhile (a tap, an interruption, AirPods out): that path already went idle.
            guard phase == .listening, !(error is CancellationError) else { return }
            log.error("listen failed: \(error.localizedDescription)")
            phase = .error(error.localizedDescription)
            // The session was activated for a listen that never happened; don't keep other
            // apps' audio paused behind it.
            output.releaseAudio(); audio.deactivate()
        }
    }

    private func observeTranscript() {
        withObservationTracking {
            liveTranscript = recognizer.transcript
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.phase == .listening else { return }
                self.observeTranscript()
            }
        }
    }

    private func handleUtterance(_ text: String) async {
        guard phase == .listening else { return }
        metrics.speechEndedAt = .now
        liveTranscript = text
        guard !text.isEmpty else {
            log.info("empty utterance")
            phase = .idle
            releaseAudioAfterCue()
            return
        }
        if StopPhrase.matches(text) {
            log.info("stop phrase heard: \(text, privacy: .public)")
            continuous = false
            acknowledging = true
            phase = .speaking
            output.beginReply()
            output.append("Okay.")
            output.endReply()
            return
        }
        await conversation.initialLoad?.value   // cold launch: the latest transcript may still be decoding
        guard phase == .listening else { return }
        phase = .thinking
        activeTool = nil
        metrics.requestSentAt = .now
        output.beginReply()
        let events = conversation.send(text)
        SiriHooks.donateSend(text)
        replySerial += 1
        let serial = replySerial
        replyTask = Task { [weak self] in
            // A finished task must not keep counting as "our turn": cancel() would then kill a
            // typed reply that started later.
            defer { if let self, self.replySerial == serial { self.replyTask = nil } }
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case let .textDelta(delta):
                    if metrics.firstTokenAt == nil { metrics.firstTokenAt = .now }
                    if phase == .thinking { phase = .speaking }
                    output.append(delta)
                case .textFinal:
                    // The deltas have already been spoken; re-reading the finished text would
                    // say the whole reply twice. The transcript still gets the corrected copy.
                    break
                case let .usage(usage):
                    metrics.usage = usage
                case .reasoningDelta:
                    if metrics.firstTokenAt == nil { metrics.firstTokenAt = .now }
                case let .toolStarted(name, _):
                    activeTool = name
                case .toolFinished:
                    activeTool = nil
                case .done:
                    metrics.replyDoneAt = .now
                    output.endReply()
                case .interrupt:
                    // Conversation holds the request; the voice screen shows the card.
                    activeTool = "waiting for you"
                case .interruptExpired:
                    activeTool = nil
                case .status, .sessionID, .runID, .subagent, .prefill:
                    break
                }
            }
            guard let self else { return }
            if conversation.lastSendWasHeld {
                // Nothing went out: say so, rather than waiting on a reply that isn't coming.
                continuous = false
                acknowledging = true
                phase = .speaking
                output.append(conversation.outbox.first?.state == .waitingForConnection
                    ? "I can't reach your server right now. I'll send that as soon as I can."
                    : "I'll send that after the current reply.")
                output.endReply()
                return
            }
            metrics.contextWindow = conversation.messages.last?.metrics?.contextWindow
            // The stream may end without .done (transport error, cancel); make sure the reply is
            // wound down either way so the session can't hang in .speaking.
            if conversation.lastError == nil { output.endReply() }
            if let error = conversation.lastError {
                output.stop()
                phase = .error(error)
                output.releaseAudio(); audio.deactivate()
            }
        }
    }

    private func replyFinishedSpeaking() {
        if acknowledging {
            acknowledging = false
            phase = .idle
            output.releaseAudio(); audio.deactivate()
            return
        }
        if replaying {
            // A replay isn't a new turn: keep the metrics, then resume hands-free or go quiet.
            replaying = false
            phase = .idle
            if continuous, replayResumesHandsFree { beginListening() } else { output.releaseAudio(); audio.deactivate() }
            return
        }
        metrics.speechDoneAt = .now
        lastMetrics = metrics
        log.info("turn: \(self.metrics.summary)")
        phase = .idle
        if continuous {
            beginListening()
        } else {
            output.releaseAudio(); audio.deactivate()
        }
    }

    private var isErrored: Bool {
        if case .error = phase { return true }
        return false
    }
}

/// Where the latency budget goes, measured on the phone. Target: < 2.5 s from end of speech to
/// first spoken word on warm turns.
nonisolated struct VoiceMetrics: Equatable, Sendable {
    var listenStartedAt: Date?
    var speechEndedAt: Date?
    var requestSentAt: Date?
    var firstTokenAt: Date?
    var replyDoneAt: Date?
    var firstSpokenAt: Date?
    var speechDoneAt: Date?
    var usage: TokenUsage?
    var contextWindow: Int?

    var contextPercent: Double? {
        guard let usage, let contextWindow, contextWindow > 0 else { return nil }
        return Double(usage.total) / Double(contextWindow) * 100
    }

    var tokensPerSecond: Double? {
        TokenUsage.decodeRate(output: usage?.output, firstTokenAt: firstTokenAt, doneAt: replyDoneAt, sentAt: requestSentAt)
    }

    private func gap(_ a: Date?, _ b: Date?) -> TimeInterval? {
        guard let a, let b else { return nil }
        return b.timeIntervalSince(a)
    }

    /// STT finalization cost.
    var finalize: TimeInterval? { gap(speechEndedAt, requestSentAt) }
    var timeToFirstToken: TimeInterval? { gap(requestSentAt, firstTokenAt) }
    var modelTotal: TimeInterval? { gap(requestSentAt, replyDoneAt) }
    /// The number that matters: silence → voice.
    var endToFirstWord: TimeInterval? { gap(speechEndedAt, firstSpokenAt) }
    var ttsStartup: TimeInterval? { gap(firstTokenAt, firstSpokenAt) }

    var summary: String {
        func f(_ label: String, _ v: TimeInterval?) -> String? { v.map { String(format: "%@ %.2fs", label, $0) } }
        var parts = [f("end→word", endToFirstWord), f("finalize", finalize), f("TTFT", timeToFirstToken),
                     f("TTS start", ttsStartup), f("model", modelTotal)].compactMap { $0 }
        if let pct = contextPercent {
            parts.append(String(format: "ctx %.1f%%", pct))
        } else if let usage {
            parts.append("\(usage.total) tok")
        }
        if let tps = tokensPerSecond { parts.append(String(format: "%.0f tok/s", tps)) }
        return parts.joined(separator: " · ")
    }
}
