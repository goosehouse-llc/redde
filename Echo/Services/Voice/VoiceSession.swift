import AudioToolbox
import AVFoundation
import Foundation
import Observation
import os
import UIKit

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
            // Voice-chat mode (and its call-volume buttons) only while the mic is open, which it
            // stays behind a reply that can be talked over.
            audio.setReplying((phase == .thinking || phase == .speaking) && !micStaysOpen)
            // The at-ear sensor only while speaking: it blanks the screen whenever it's covered.
            audio.setEarRouting(phase == .speaking)
            if headsetControlsOn { publishNowPlaying() }
            updateScreenAwake()
            // Every path OUT of listening funnels through here: utterance end, tap,
            // interruption, AirPods coming out. The start cue plays in startRecognizer
            // instead — at phase-set time the audio session isn't active or routed yet,
            // which made the tone land on the earpiece or the silent-switch session.
            if oldValue == .listening { earcon(.stopped) }
            watchIfSpeaking()
            if phase == .idle || isErrored { stopMonitor() }
        }
    }
    private var headsetControlsOn = false
    private(set) var liveTranscript = ""
    private(set) var activeTool: String?
    private(set) var lastMetrics: VoiceMetrics?
    /// When true, the mic reopens automatically after each reply (hands-free mode, M2).
    var continuous = false
    /// The mic is held shut in the middle of a conversation (the car screen's Mute): the session
    /// is idle but not over. `unmute()`, or the mic by any other route, listens again.
    private(set) var isMuted = false

    let recognizer: any VoiceRecognizing
    let output: any VoiceSpeaking
    private let conversation: Conversation
    private let audio: any VoiceAudioControlling
    /// Injectable so tests never touch the Speech authorization prompt.
    private let requestPermissions: () async -> Bool
    /// Injectable so tests observe the cues instead of playing sounds.
    private let earcon: (Earcon) -> Void
    /// Holds auto-lock off (true) or lets it be (false). Injectable so tests see it asked for.
    private let keepAwake: (Bool) -> Void
    /// Settings → Voice → Talk over replies, and what it takes. Injectable so tests choose.
    private let talkOver: () -> Settings.TalkOver
    private let interruption: () -> Settings.Interruption
    private var screenAwake = false
    private var awakeTimeout: Task<Void, Never>?
    /// How long a wait for the reply holds the screen on. Past it the phone may lock: the reply
    /// carries on regardless, and a screen held on through a ten-minute task is a flat battery.
    var awakeWhileThinking: Duration = .seconds(120)
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "voice")
    private var metrics = VoiceMetrics()
    private var replyTask: Task<Void, Never>?
    private var replySerial = 0
    /// True while speaking the "Okay." that confirms a stop phrase; not a real turn.
    private var acknowledging = false
    private var replaying = false
    /// The reply is held by the voice screen's Pause button; still `.speaking`.
    private(set) var isPaused = false {
        didSet { if isPaused != oldValue { updateScreenAwake(); watchIfSpeaking() } }
    }
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
         earcon: @escaping (Earcon) -> Void = { EarconPlayer.shared.play($0) },
         keepAwake: @escaping (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 },
         talkOver: @escaping () -> Settings.TalkOver = { Settings.shared.talkOver },
         interruption: @escaping () -> Settings.Interruption = { Settings.shared.interruption }) {
        self.talkOver = talkOver
        self.interruption = interruption
        self.conversation = conversation
        self.recognizer = recognizer
        self.output = output
        self.audio = audio
        self.requestPermissions = requestPermissions
        self.earcon = earcon
        self.keepAwake = keepAwake
        output.onFirstSpeech = { [weak self] in
            self?.metrics.firstSpokenAt = .now
            // The sound starts now: the watch for a voice over it starts its count from here.
            self?.watchIfSpeaking()
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
            // A mic opened behind the reply was set up for the device that just left.
            stopMonitor()
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
        isMuted = false
        stopMonitor()   // the mic behind a reply closes; listening opens it afresh
        output.stop()
        replyTask?.cancel()
        // Barge-in: stop the server turn too, or it keeps streaming (and billing) unheard.
        if conversation.isStreaming { conversation.cancel() }
        metrics = VoiceMetrics()
        phase = .listening
        liveTranscript = ""
        Task { await startRecognizer() }
    }

    /// The phone locked, or Redde was left for another app, while the mic was open. Listening
    /// now survives the background (the `audio` background mode), so a mic left open on a locked
    /// phone would stay open for good. Unless the person is in a hands-free conversation or on
    /// the car's screen, stop listening and go idle. A reply being thought about or spoken is
    /// left alone: that is what the background modes are for.
    func leftForeground(carPlayConnected: Bool) {
        guard !continuous, !carPlayConnected else { return }
        // The same goes for the mic behind a reply: the reply plays on, and can't be talked over.
        if phase == .thinking || phase == .speaking { stopMonitor() }
        guard phase == .listening else { return }
        log.info("left the foreground while listening: stopping")
        cancel()
    }

    /// Shut the mic without ending the conversation, so nothing said in the car is taken for a
    /// question. Only while listening; hands-free stays as it was for when the mic comes back.
    func mute() {
        guard phase == .listening else { return }
        recognizer.cancel()
        isMuted = true
        phase = .idle
        releaseAudioAfterCue()   // the car's own audio comes back while Redde isn't listening
    }

    func unmute() {
        guard isMuted else { return }
        beginListening()
    }

    /// Tap again while listening: end the utterance now.
    func endListening() {
        guard phase == .listening else { return }
        Task {
            let text = await recognizer.stop()
            await handleUtterance(text)
        }
    }

    /// The screen stays on while the mic is open and while a reply is being spoken, so auto-lock
    /// doesn't cut a conversation off, and through the wait for the reply in between, up to a
    /// point. A paused reply, an error and idle give auto-lock back.
    private func updateScreenAwake() {
        awakeTimeout?.cancel()
        awakeTimeout = nil
        let wanted: Bool
        switch phase {
        case .listening: wanted = true
        case .speaking: wanted = !isPaused
        case .thinking:
            wanted = true
            awakeTimeout = Task { [weak self, awakeWhileThinking] in
                try? await Task.sleep(for: awakeWhileThinking)
                guard let self, !Task.isCancelled, phase == .thinking else { return }
                setScreenAwake(false)
            }
        case .idle, .error: wanted = false
        }
        setScreenAwake(wanted)
    }

    private func setScreenAwake(_ on: Bool) {
        guard on != screenAwake else { return }
        screenAwake = on
        keepAwake(on)
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
        isMuted = false
        stopMonitor()
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
        micStaysOpen = canBeTalkedOver()
        phase = .thinking
        activeTool = nil
        metrics.requestSentAt = .now
        output.beginReply()
        // Spoken prefixes: a leading "Claude, …" becomes its text prefix, and a rule that names a
        // model moves the conversation there first (sticky). Only here, on the final endpointed
        // utterance; the composer's text is the user's own. A failed switch still sends: the
        // message is what the person said, the model is a preference.
        let route = VoiceRouting.route(text, rules: Settings.shared.spokenPrefixes)
        let outgoing = route?.text ?? text
        if let model = route?.model {
            do { try await conversation.switchModel(model, provider: route?.provider) } catch {
                log.error("spoken prefix: model switch to \(model, privacy: .public) failed: \(error.localizedDescription)")
            }
        }
        let events = conversation.send(outgoing)
        SiriHooks.donateSend(outgoing)
        if micStaysOpen { startMonitor() }
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
                case let .toolStarted(name, _, _):
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
        if monitoring, continuous {
            // Hands-free, and the mic is already open behind the reply: listen on it, rather
            // than close it and open it again. Nothing kept from while Redde spoke is used.
            handOverMic()
            metrics = VoiceMetrics()
            phase = .listening
            liveTranscript = ""
            recognizer.holdAgain()   // (it may be transcribing, waiting for "stop": that is over)
            recognizer.beginTranscribing(withHeldAudio: false, endsOnSilence: true)
            earcon(.listening)
            metrics.listenStartedAt = .now
            observeTranscript()
            return
        }
        phase = .idle
        if continuous {
            beginListening()
        } else {
            output.releaseAudio(); audio.deactivate()
        }
    }

    // MARK: - Talking over a reply

    /// This turn's reply can be talked over: the mic stays open behind it, in the listening
    /// configuration (on the speaker that means voice-chat mode, at call volume).
    private var micStaysOpen = false
    /// The mic is open behind the reply (`recognizer.startHeld`).
    private var monitoring = false
    private var monitorTask: Task<Void, Never>?
    private var monitorSerial = 0
    /// A voice was heard and the reply is held while the recogniser finds out whether it was words.
    private var confirmTask: Task<Void, Never>?
    /// How long the recogniser has to come up with words before the reply carries on. It starts
    /// a second back, so this is time to recognise what was said, not time to say it.
    var confirmWindow: Duration = .seconds(1.5)

    /// Whether talking over a reply applies to what this turn plays through (Settings → Voice).
    /// Never in a car: its audio and its own echo handling are untested ground.
    private func canBeTalkedOver() -> Bool {
        switch (talkOver(), audio.route) {
        case (.off, _), (_, .car), (.headphones, .speaker): false
        case (_, .headphones), (.everywhere, .speaker): true
        }
    }

    /// Opens the mic behind the reply that is on its way. The recogniser is given nothing yet: it
    /// must not hear Redde's own voice (see `BargeInDetector`).
    private func startMonitor() {
        monitorSerial += 1
        let serial = monitorSerial
        monitorTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await recognizer.startHeld { [weak self] text in
                    Task { await self?.handleUtterance(text) }
                }
            } catch {
                guard monitorSerial == serial else { return }
                if !(error is CancellationError) { log.error("couldn't keep the mic open behind the reply: \(error.localizedDescription)") }
                // The reply plays as one that can't be talked over.
                monitorTask = nil
                micStaysOpen = false
                audio.setReplying(phase == .thinking || phase == .speaking)
                return
            }
            guard monitorSerial == serial else { return }   // stopped meanwhile; `stopMonitor` closed the mic
            monitorTask = nil
            guard phase == .thinking || phase == .speaking else { recognizer.cancel(); return }
            audio.refreshRoute()   // the engine's voice-processing unit just reset the output
            monitoring = true
            watchIfSpeaking()
        }
    }

    /// Closes the mic behind a reply, however far opening it had got.
    private func stopMonitor() {
        guard micStaysOpen || monitoring || monitorTask != nil else { return }
        handOverMic()
        recognizer.cancel()
    }

    /// The mic behind the reply stops being that: closed by the caller, or kept as the listening mic.
    private func handOverMic() {
        monitorSerial += 1
        monitorTask = nil
        confirmTask?.cancel()
        confirmTask = nil
        monitoring = false
        micStaysOpen = false
        recognizer.watchForVoice(nil, heard: nil)
    }

    /// Watch for a voice exactly while a reply is being spoken: not while it is paused, not over
    /// the "Okay." after a stop phrase, and not while a voice is already being looked into.
    /// `midReply`: the reply never stopped playing, so there is no start of it to wait out.
    private func watchIfSpeaking(midReply: Bool = false) {
        guard monitoring, confirmTask == nil else { return }
        if phase == .speaking, !isPaused, !acknowledging {
            var detector = audio.route == .headphones ? BargeInDetector.headset : .echoCancelled
            if midReply { detector.settle = 0; detector.rearm() }
            recognizer.watchForVoice(detector) { [weak self] in self?.voiceOverReply() }
        } else {
            recognizer.watchForVoice(nil, heard: nil)
        }
    }

    /// Something is being said over the reply. What happens next is Settings → Voice →
    /// Interrupt with.
    private func voiceOverReply() {
        guard monitoring, phase == .speaking, confirmTask == nil else { return }
        if interruption() == .stopWord { listenForStop() } else { holdToHearWords() }
    }

    /// How long nothing new has to be heard before the wait for "stop" goes back to a level watch.
    var stopWordQuiet: Duration = .seconds(2.5)

    /// "Only stop": the reply plays on, whoever is talking, and the recogniser listens for one
    /// word. It hears what the microphone hears while Redde speaks, which is what went wrong
    /// when any word counted; here whatever else it writes down is ignored, and it listens only
    /// while a voice is actually there. "Stop" ends the reply and the conversation, like the stop
    /// phrase between turns.
    private func listenForStop() {
        log.info("a voice over the reply: listening for \"stop\"")
        recognizer.beginTranscribing(withHeldAudio: true, endsOnSilence: false)
        confirmTask = Task { [weak self, stopWordQuiet] in
            let clock = ContinuousClock()
            var heard = ""
            var changedAt = clock.now
            while true {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, !Task.isCancelled else { return }
                let now = recognizer.transcript
                if StopWord.heard(in: now) {
                    confirmTask = nil
                    stoppedByWord()
                    return
                }
                if now != heard { heard = now; changedAt = clock.now }
                if clock.now - changedAt > stopWordQuiet {
                    // The talking is over and the word wasn't in it: back to watching the level.
                    confirmTask = nil
                    recognizer.holdAgain()
                    watchIfSpeaking(midReply: true)
                    return
                }
            }
        }
    }

    /// "Stop" was said over the reply: it ends, the turn with it, and so does hands-free, with
    /// the same "Okay." as a stop phrase between turns.
    private func stoppedByWord() {
        log.info("\"stop\" over the reply")
        stopMonitor()
        replyTask?.cancel()
        replyTask = nil
        if conversation.isStreaming { conversation.cancel() }
        continuous = false
        acknowledging = true
        output.beginReply()   // (drops what was left of the reply)
        output.append("Okay.")
        output.endReply()
    }

    /// "Anything you say": hold the reply and let the recogniser listen, starting a second back,
    /// to a room Redde is no longer talking in. Words within the window make it an interruption;
    /// none, or only a listener's "mm-hm" or "okay", and the reply carries on.
    private func holdToHearWords() {
        log.info("a voice over the reply: holding it to hear whether it is words")
        output.pause()
        recognizer.beginTranscribing(withHeldAudio: true, endsOnSilence: false)
        confirmTask = Task { [weak self, confirmWindow] in
            let clock = ContinuousClock()
            let deadline = clock.now + confirmWindow
            while clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, !Task.isCancelled else { return }
                // ("Okay" may yet become "okay, stop": a listener's noise waits out the window.)
                if !recognizer.transcript.isEmpty, !Backchannel.isOnly(recognizer.transcript) {
                    confirmTask = nil
                    interrupted()
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            confirmTask = nil
            carryOn()
        }
    }

    /// It was words: the reply ends here, as if the mic had been tapped, and what is being said
    /// is the next turn. The recogniser is already listening to it.
    private func interrupted() {
        log.info("talked over: the reply stops")
        handOverMic()
        recognizer.endOnSilence()   // an utterance like any other from here: a pause ends it
        output.stop()
        replyTask?.cancel()
        replyTask = nil
        if conversation.isStreaming { conversation.cancel() }
        metrics = VoiceMetrics()
        metrics.listenStartedAt = .now
        phase = .listening
        liveTranscript = recognizer.transcript
        observeTranscript()
    }

    /// It wasn't words (a cough, a door): the mic goes back to waiting and the reply carries on.
    private func carryOn() {
        guard monitoring, phase == .speaking else { return }
        log.info("no words: the reply carries on")
        recognizer.holdAgain()
        if !isPaused { output.resume() }
        watchIfSpeaking()
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
