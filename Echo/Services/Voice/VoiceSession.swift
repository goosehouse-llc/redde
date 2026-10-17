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
            // A reply held while it was being thought about is still held at its first word.
            if !(oldValue == .thinking && phase == .speaking) { isPaused = false }
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
            watchForQuiet()
            if phase == .idle || isErrored { stopMonitor() }
        }
    }
    private var headsetControlsOn = false
    private(set) var liveTranscript = ""
    private(set) var activeTool: String?
    private(set) var lastMetrics: VoiceMetrics?
    /// When true, the mic reopens automatically after each reply (hands-free mode, M2).
    var continuous = false
    /// The mic is held shut in the middle of a conversation (the car screen's Pause while Redde
    /// listens): the session is idle but not over. `unmute()`, or the mic by any other route,
    /// listens again.
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
    /// Settings → Voice → Stop phrases: the person's own, heard beside the built-in ones.
    private let stopPhrases: () -> [String]
    /// Settings → Voice → Answer requests by voice. Injectable so tests choose.
    private let answersAloud: () -> Bool
    /// Settings → Voice → Short answers in the car, and whether the phone is with a car right
    /// now (CarPlay, connected or not on its screen). Injectable so tests choose.
    private let shortInCar: () -> Bool
    private let carConnected: () -> Bool
    /// Where a note taken by voice goes (quick capture). Injectable so tests see it.
    private let takeNote: (String) -> Void
    /// Settings → Voice → Thinking sound, and what plays it. Injectable so tests choose and listen.
    private let thinkingSoundWanted: () -> Settings.ThinkingSound
    private let thinkingSound: any ThinkingSounding
    /// Settings → Voice → Nod or shake to answer, and the AirPods' movement it reads.
    private let answersByNod: () -> Bool
    private let head: any HeadGestureSensing
    /// The camera the voice screen can open. Injectable so tests show it what they like.
    let eye: any VoiceLooking
    /// How an answer given aloud reaches the agent: the conversation's own way, unless a test listens.
    private let respond: (SpokenRequest.Answer) -> Void
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
    /// The reply is held by Pause: where it had got to while `.speaking`, or from its first word
    /// while it is still being thought about (`.thinking`, from the car's card).
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
         head: any HeadGestureSensing = HeadGestures.shared,
         eye: any VoiceLooking = VoiceCamera.forApp,
         requestPermissions: @escaping () async -> Bool = { await SpeechRecognizer.requestPermissions() },
         earcon: @escaping (Earcon) -> Void = { EarconPlayer.shared.play($0) },
         keepAwake: @escaping (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 },
         talkOver: @escaping () -> Settings.TalkOver = { Settings.shared.talkOver },
         interruption: @escaping () -> Settings.Interruption = { Settings.shared.interruption },
         stopPhrases: @escaping () -> [String] = { Settings.shared.stopPhrases },
         answersAloud: @escaping () -> Bool = { Settings.shared.answerRequestsByVoice },
         answersByNod: @escaping () -> Bool = { Settings.shared.answerRequestsByNod },
         shortInCar: @escaping () -> Bool = { Settings.shared.shortAnswersInCar },
         carConnected: @escaping () -> Bool = { CarPlaySceneDelegate.isConnected },
         takeNote: @escaping (String) -> Void = { CaptureInbox.shared.add($0) },
         thinkingSoundWanted: @escaping () -> Settings.ThinkingSound = { Settings.shared.thinkingSound },
         thinkingSound: any ThinkingSounding = ThinkingSoundPlayer.shared,
         respond: ((SpokenRequest.Answer) -> Void)? = nil) {
        self.talkOver = talkOver
        self.interruption = interruption
        self.stopPhrases = stopPhrases
        self.answersAloud = answersAloud
        self.answersByNod = answersByNod
        self.head = head
        self.eye = eye
        self.takeNote = takeNote
        self.thinkingSoundWanted = thinkingSoundWanted
        self.thinkingSound = thinkingSound
        self.shortInCar = shortInCar
        self.carConnected = carConnected
        self.respond = respond ?? { [weak conversation] answer in
            switch answer {
            case let .approval(choice): conversation?.respond(approval: choice)
            case let .clarify(questionID, text): conversation?.respond(clarify: [questionID: text])
            }
        }
        self.conversation = conversation
        self.recognizer = recognizer
        self.output = output
        self.audio = audio
        self.requestPermissions = requestPermissions
        self.earcon = earcon
        self.keepAwake = keepAwake
        output.onFirstSpeech = { [weak self] in
            self?.metrics.firstSpokenAt = .now
            self?.playThinkingSound(false)   // the reply is out: not a note over its first word
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
            // (A reply held while it is still being thought about goes the same way: the car
            // whose card would have resumed it is gone.)
            case .speaking,
                 .thinking where isPaused:
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
        publishNowPlaying()
    }

    func detachHeadsetControls() {
        headsetControlsOn = false
        HeadsetControls.shared.disable()
    }

    private func publishNowPlaying() {
        // While the agent works on the reply, the Lock Screen already has the turn's Live
        // Activity and iOS's "is working" card; a player saying "Thinking" made three. Headset
        // presses go with it until the reply is spoken (Stop on the screen still stops it).
        if phase == .thinking {
            HeadsetControls.shared.stepAside()
            return
        }
        if !HeadsetControls.shared.hasPlayer {
            HeadsetControls.shared.enable { [weak self] in self?.primaryAction() }
        }
        let status = switch phase {
        case .idle: "Ready"
        case .listening: "Listening"
        case .thinking: ""   // stepped aside above
        case .speaking: "Speaking"
        case .error: "Tap to try again"
        }
        HeadsetControls.shared.setNowPlaying(status: status, active: phase == .listening || phase == .speaking)
    }

    var isListening: Bool { phase == .listening }
    var mightBeBusy: Bool { phase != .idle }

    // MARK: - Public actions

    /// What is being listened for is a note to file, not a question (quick capture): nothing is
    /// sent to the conversation and nothing comes back but "Noted."
    private(set) var isCapturing = false

    /// The camera is open on the voice screen: each question asked goes with a picture of what
    /// it sees as the question ends.
    private(set) var isLooking = false
    /// Why the camera couldn't be opened, for the voice screen to say.
    private(set) var lookProblem: String?
    /// Whether there is a camera to offer at all.
    var canLook: Bool { eye.isAvailable }

    /// The voice screen's camera button. Leaving the voice screen closes the camera; Stop and a
    /// finished reply leave it open, for the next question about the same thing.
    func setLooking(_ on: Bool) {
        lookProblem = nil
        guard on != isLooking else { return }
        isLooking = on   // at once, so the button shows it; taken back if the camera can't be had
        guard on else { eye.close(); return }
        Task {
            let opened = await eye.open()
            if !isLooking {
                eye.close()   // switched off again while it was opening
            } else if !opened {
                isLooking = false
                lookProblem = "Redde can't use the camera. Allow it in Settings → Privacy & Security → Camera."
            }
        }
    }

    /// Tap the mic: start listening. If a reply is being spoken, this barges in. `capturing`:
    /// for a note (`CaptureInbox`), which leaves the conversation and whatever it is doing alone.
    func beginListening(capturing: Bool = false) {
        if asking != nil {
            // Tapped while the request is being read out: hear the answer now. The turn is not
            // one to barge in on; it waits for that answer.
            guard phase == .speaking else { return }
            output.stop()
            listenForAnswer()
            return
        }
        // A note is taken between turns, never over a reply: that would end the reply for it.
        if capturing, phase != .idle, !isErrored { return }
        replaying = false
        guard phase == .idle || phase == .speaking || isErrored else { return }
        isCapturing = capturing
        isMuted = false
        stopMonitor()   // the mic behind a reply closes; listening opens it afresh
        output.stop()
        replyTask?.cancel()
        // Barge-in: stop the server turn too, or it keeps streaming (and billing) unheard. A
        // note has nothing to do with a reply being typed out on the phone meanwhile.
        if conversation.isStreaming, !capturing { conversation.cancel() }
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
        // And for a mic waiting on an answer: the request stays, on the screen and in its notification.
        if asking != nil, phase == .listening { leaveForTheScreen(saying: false); return }
        guard phase == .listening else { return }
        log.info("left the foreground while listening: stopping")
        cancel()
    }

    /// Shut the mic without ending the conversation, so nothing said in the car is taken for a
    /// question. Only while listening; hands-free stays as it was for when the mic comes back.
    func mute() {
        guard phase == .listening else { return }
        // Muted instead of answering: the request waits on the screen, the turn on the request.
        if asking != nil { leaveForTheScreen(saying: false); return }
        recognizer.cancel()
        isMuted = true
        phase = .idle
        releaseAudioAfterCue()   // the car's own audio comes back while Redde isn't listening
    }

    func unmute() {
        guard isMuted else { return }
        beginListening(capturing: isCapturing)   // a note being taken is still a note
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

    /// Pause / Play: the voice screen's while a reply is being read, and the car's also while
    /// it is still being thought about. Then the agent works on and the reply waits, whole,
    /// until Play.
    func pauseSpeaking() {
        guard phase == .speaking || phase == .thinking, !isPaused else { return }
        output.pause()
        isPaused = true
        playThinkingSound(false)   // held is quiet
    }

    func resumeSpeaking() {
        guard phase == .speaking || phase == .thinking, isPaused else { return }
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
        isCapturing = false
        stopAsking()
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
            guard phase == .listening else { return }   // answered or cancelled meanwhile (a nod can be that quick)
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
        if let asking { heardAnswer(text, to: asking); return }
        metrics.speechEndedAt = .now
        liveTranscript = text
        guard !text.isEmpty else {
            log.info("empty utterance")
            isCapturing = false
            phase = .idle
            releaseAudioAfterCue()
            return
        }
        // ("Never mind" instead of a note: no note.)
        if StopPhrase.matches(text, own: stopPhrases()) {
            log.info("stop phrase heard: \(text, privacy: .public)")
            isCapturing = false
            continuous = false
            acknowledging = true
            phase = .speaking
            output.beginReply()
            output.append("Okay.")
            output.endReply()
            return
        }
        if isCapturing {
            // A note: kept, to be filed when the server can be reached, and that is all. No turn,
            // and the mic doesn't reopen, hands-free or not.
            log.info("a note taken")
            isCapturing = false
            takeNote(text)
            acknowledging = true
            phase = .speaking
            output.beginReply()
            output.append("Noted.")
            output.endReply()
            return
        }
        // What the camera sees as the question ends, before anything below takes its time.
        let seen = isLooking ? eye.still() : nil
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
        // In a car (its CarPlay, or its Bluetooth alone), if Settings says so: a short answer.
        let events = conversation.send(outgoing, attachments: seen.map { [$0] } ?? [],
                                       brief: shortInCar() && (carConnected() || audio.route == .car))
        SiriHooks.donateSend(outgoing)
        if micStaysOpen { startMonitor() }
        replySerial += 1
        let serial = replySerial
        turnOpen = true
        replyTask = Task { [weak self] in
            // A finished task must not keep counting as "our turn": cancel() would then kill a
            // typed reply that started later.
            defer { if let self, self.replySerial == serial { self.replyTask = nil; self.turnOpen = false } }
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                // The turn has moved on while a request was being asked about: it was answered on
                // the screen, from a notification, or by the host's own time limit.
                if let asking, conversation.pendingInterrupt?.interrupt.id != asking.id { answeredElsewhere() }
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
                    turnOpen = false
                    output.endReply()
                case let .interrupt(interrupt, _):
                    // Conversation holds the request; the voice screen shows the card. Asked
                    // aloud too if Settings says so and it is one a voice can answer.
                    if !ask(interrupt) { activeTool = "waiting for you" }
                case .interruptExpired:
                    activeTool = nil
                case .status, .sessionID, .runID, .subagent, .prefill, .todos:
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

    // MARK: - The thinking sound

    /// How long there has to be nothing to hear, while the agent works, before the sound starts:
    /// an answer that comes at once has no need of it. And how often that is looked at.
    var thinkingSoundAfter: Duration = .seconds(2.5)
    var quietCheck: Duration = .milliseconds(200)
    /// The reply's stream is still open: more may come, however long nothing has.
    private var turnOpen = false
    private var quietTask: Task<Void, Never>?
    private var thinkingSoundOn = false

    /// The agent is at work and there is nothing to hear: before its first word, and in the
    /// middle of a reply while it uses its tools ("Let me check", and then a minute of nothing).
    private var isQuietlyWorking: Bool {
        switch thinkingSoundWanted() {
        case .off: return false
        case .car: if !carConnected(), audio.route != .car { return false }
        case .always: break
        }
        // Not while the turn waits for the person, which is not work; not over a reply that is
        // held; and not into a microphone left open on the phone's own speaker, where a sound
        // that starts can pass for a voice (`BargeInDetector`).
        guard asking == nil, conversation.pendingInterrupt == nil, !isPaused, !acknowledging, !replaying,
              !(micStaysOpen && audio.route == .speaker) else { return false }
        switch phase {
        case .thinking: return true
        case .speaking: return turnOpen && output.meterLevel < 0.02
        default: return false
        }
    }

    /// While Redde thinks or speaks, the quiet is watched; anywhere else the sound stops at once.
    private func watchForQuiet() {
        guard phase == .thinking || phase == .speaking else {
            quietTask?.cancel()
            quietTask = nil
            playThinkingSound(false)
            return
        }
        guard quietTask == nil else { return }
        quietTask = Task { [weak self, quietCheck] in
            var since: ContinuousClock.Instant?
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    since = heardNothing(since: since)
                }
                try? await Task.sleep(for: quietCheck)
            }
        }
    }

    /// One look at the quiet: since when there has been nothing to hear, the sound started once
    /// that is long enough and stopped as soon as it isn't so.
    private func heardNothing(since: ContinuousClock.Instant?) -> ContinuousClock.Instant? {
        guard isQuietlyWorking else {
            playThinkingSound(false)
            return nil
        }
        let start = since ?? .now
        if ContinuousClock.now - start >= thinkingSoundAfter { playThinkingSound(true) }
        return start
    }

    private func playThinkingSound(_ on: Bool) {
        guard on != thinkingSoundOn else { return }
        thinkingSoundOn = on
        if on {
            thinkingSound.start()
            audio.refreshRoute()   // (starting a sound can put the output back on the earpiece)
        } else {
            thinkingSound.stop()
        }
    }

    private func replyFinishedSpeaking() {
        if asking != nil {
            // The request has been read out, or the reminder said: now the answer.
            listenForAnswer()
            return
        }
        if leftForScreen {
            // "It's waiting on your iPhone" has been said. The turn is still the agent's.
            leftForScreen = false
            phase = .thinking
            return
        }
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

    // MARK: - Answering a request aloud

    /// The request being put to the person aloud, from its being read out until it is answered,
    /// answered elsewhere or left for the screen. The voice screen shows its hint.
    private(set) var asking: SpokenRequest? {
        didSet { if asking?.id != oldValue?.id { watchHead() } }
    }
    /// How many answers so far weren't one. The second is the last.
    private var unclearAnswers = 0
    /// Speaking the line that hands a request over to the screen.
    private var leftForScreen = false
    private var answerTimeout: Task<Void, Never>?
    /// How long silence may last before it counts as no answer.
    var answerWindow: Duration = .seconds(12)

    /// Puts a request the agent waits on to the person aloud, after whatever of the reply is
    /// still being said. False when Settings doesn't allow it or a voice can't answer it: then
    /// it is the screen's, as it always was.
    private func ask(_ interrupt: Interrupt) -> Bool {
        guard answersAloud(), let request = SpokenRequest(interrupt) else { return false }
        // The request is not a reply to talk over: a "yes" said early would end the whole turn.
        stopMonitor()
        asking = request
        unclearAnswers = 0
        activeTool = nil
        phase = .speaking
        output.append("\n\n" + request.prompt)
        output.endReply()
        watchRequest()
        return true
    }

    /// Notices at once when the request is settled some other way: its card on the screen, its
    /// notification, the host's own time limit. The next event of the turn would say so too, but
    /// that can be a long command away, with the mic open all the while.
    private func watchRequest() {
        withObservationTracking {
            _ = conversation.pendingInterrupt?.interrupt.id
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let asking = self.asking else { return }
                if self.conversation.pendingInterrupt?.interrupt.id == asking.id { self.watchRequest() } else { self.answeredElsewhere() }
            }
        }
    }

    /// Opens the mic for the answer. The turn stays as it is, waiting.
    private func listenForAnswer() {
        phase = .listening
        liveTranscript = ""
        Task { await startRecognizer() }
        answerTimeout?.cancel()
        answerTimeout = Task { [weak self, answerWindow] in
            try? await Task.sleep(for: answerWindow)
            guard let self, !Task.isCancelled, asking != nil, phase == .listening, recognizer.transcript.isEmpty else { return }
            endListening()   // nothing was said: that is no answer
        }
    }

    private func heardAnswer(_ text: String, to request: SpokenRequest) {
        answerTimeout?.cancel()
        liveTranscript = text
        guard conversation.pendingInterrupt?.interrupt.id == request.id else { answeredElsewhere(); return }
        if let answer = request.answer(text) {
            log.info("a request answered aloud")
            answered(answer, to: request)
            return
        }
        unclearAnswers += 1
        guard unclearAnswers < 2 else { leaveForTheScreen(saying: true); return }
        phase = .speaking
        output.beginReply()
        output.append(request.reminder)
        output.endReply()
    }

    /// The answer goes to the agent the way the card's buttons send it.
    private func answered(_ answer: SpokenRequest.Answer, to request: SpokenRequest) {
        asking = nil
        respond(answer)
        // Said back, so a mishearing is heard; the reply carries on behind it.
        phase = .speaking
        output.beginReply()
        output.append(request.confirmation(of: answer) + " ")
        if canBeTalkedOver() { micStaysOpen = true; startMonitor() }
    }

    // MARK: A nod or a shake

    /// A nod or a shake of the head would answer right now: the voice screen says so.
    var headAnswers: Bool { asking?.takesNod == true && head.isSensing }

    /// The AirPods' movement is read from when a request starts being read out until it is
    /// settled, and at no other time. From the start, so that by the time the request has been
    /// read the AirPods are answering and a nod begun on its last words is seen whole.
    private func watchHead() {
        guard let asking, asking.takesNod, answersByNod(), audio.route == .headphones else { head.stop(); return }
        head.start { [weak self] gesture in self?.headMoved(gesture) }
    }

    /// A nod approves and a shake denies, but only once the request has been read out and the
    /// mic is open for the answer. A nod along to the reply before it, or to the request while
    /// it is still being read, answers nothing.
    private func headMoved(_ gesture: HeadGesture) {
        guard let asking, phase == .listening, let answer = asking.answer(nod: gesture == .nod) else { return }
        answerTimeout?.cancel()
        guard conversation.pendingInterrupt?.interrupt.id == asking.id else { answeredElsewhere(); return }
        log.info("a request answered by a \(gesture.rawValue, privacy: .public)")
        recognizer.cancel()   // whatever the mic had heard so far is not the answer
        liveTranscript = ""
        answered(answer, to: asking)
    }

    /// No answer came by voice: the request stays where it has been all along, on the screen (the
    /// car's card says "Needs your phone") and in its notification.
    private func leaveForTheScreen(saying: Bool) {
        answerTimeout?.cancel()
        asking = nil
        activeTool = "waiting for you"
        if phase == .listening { recognizer.cancel() }
        guard saying else { phase = .thinking; return }
        leftForScreen = true
        phase = .speaking
        output.beginReply()
        output.append("It's waiting for you on your iPhone.")
        output.endReply()
    }

    /// The request was settled some other way while it was being asked about.
    private func answeredElsewhere() {
        guard asking != nil else { return }
        answerTimeout?.cancel()
        asking = nil
        if phase == .listening { recognizer.cancel() }
        output.stop()
        output.beginReply()
        phase = .thinking
    }

    /// The conversation is over: nothing is being asked any more.
    private func stopAsking() {
        answerTimeout?.cancel()
        asking = nil
        leftForScreen = false
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
        let own = stopPhrases()
        confirmTask = Task { [weak self, stopWordQuiet] in
            let clock = ContinuousClock()
            var heard = ""
            var changedAt = clock.now
            while true {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, !Task.isCancelled else { return }
                let now = recognizer.transcript
                if StopWord.heard(in: now, own: own) {
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
