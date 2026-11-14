import AudioToolbox
import AVFoundation
import Foundation
import Observation
import os
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Plays the bundled listening tones through the app's audio session: on the active
/// `.playAndRecord` voice session they ignore the ring/silent switch, like Siri's cues —
/// the user just asked to talk, so the cues are wanted. Bundled files, not the
/// `/System/Library/Audio/UISounds` ones: the device sandbox can refuse those, which
/// silently degraded to a ringer-muted system sound.
@MainActor
final class EarconPlayer {
    static let shared = EarconPlayer()
    private var players: [VoiceSession.Earcon: AVAudioPlayer] = [:]
    private var waiting: [VoiceSession.Earcon: Task<Void, Never>] = [:]
    /// A cue starts this long after it is asked for, so that what changed in the audio just before
    /// it has settled: the route forced as the mic opens, the voice-processing unit going off as it
    /// closes (the recogniser's teardown runs a moment after a tap's stop cue is asked for), the
    /// reply voice's engine warming up as the question goes. Started at once, its first part was
    /// lost under the change, and it came out as a chirp. Timed on the clock, not the output
    /// device's (`play(atTime:)`): those changes restart the device, and its clock with it, and
    /// a stop cue timed on it was never heard.
    static let lead: Duration = .milliseconds(100)
    /// In the car, longer: a cue that began as the car opened its voice channel for the mic
    /// crackled there, and only there (heard 2026-10-22). The car's channel takes longer to
    /// settle than the phone's own audio does.
    static let carLead: Duration = .milliseconds(350)

    /// Made as voice mode plays its first cue, inside its session, so preparing the players is
    /// safe here. Prepared as the app launched, they would stop another app's music (GitHub issue 30).
    private init() {
        for (cue, name) in [(VoiceSession.Earcon.listening, "listen-start"), (.stopped, "listen-stop")] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { continue }
            players[cue] = try? AVAudioPlayer(contentsOf: url)
            players[cue]?.prepareToPlay()
        }
    }

    func play(_ cue: VoiceSession.Earcon) {
        guard let player = players[cue] else { return }
        waiting[cue]?.cancel()
        player.stop()
        player.currentTime = 0
        let inCar = CarPlaySceneDelegate.isConnected || AudioSessionController.shared.route == .car
        waiting[cue] = Task { [weak self] in
            try? await Task.sleep(for: inCar ? Self.carLead : Self.lead)
            guard !Task.isCancelled else { return }
            self?.waiting[cue] = nil
            #if DEBUG && os(iOS)
            // What the cue went out through, for a crackle heard in the car.
            let session = AVAudioSession.sharedInstance()
            Logger(subsystem: "com.goosehouse.echo", category: "voice").info("cue \(cue == .listening ? "start" : "stop", privacy: .public): \(session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ","), privacy: .public) at \(Int(session.sampleRate)) Hz, mode \(session.mode.rawValue, privacy: .public), buffer \(Int(session.ioBufferDuration * 1000)) ms")
            #endif
            if !player.play() {
                Logger(subsystem: "com.goosehouse.echo", category: "voice").error("the \(cue == .listening ? "start" : "stop", privacy: .public) cue didn't play")
            }
        }
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

    /// When the reply being spoken was first heard: `.speaking` begins with the reply's first
    /// word of text, and its sound only once that has been made into speech, a second or more
    /// later. The car's face moves its mouth from here (`CarPlaySceneDelegate.card`).
    var soundStartedAt: Date?

    var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            // A reply held while it was being thought about is still held at its first word.
            if !(oldValue == .thinking && phase == .speaking) { isPaused = false }
            if phase != .speaking { soundStartedAt = nil; replyQuietSince = nil; quietInReply = false }
            // A GPT-Live call has its own audio, open both ways all the while: no cues between its
            // phases, no change of mode or route, no thinking sound, no microphone behind a reply.
            if live != nil {
                if headsetControlsOn { publishNowPlaying() }
                updateScreenAwake()
                return
            }
            // Every path OUT of listening funnels through here: utterance end, tap,
            // interruption, AirPods coming out. The start cue plays in startRecognizer
            // instead — at phase-set time the audio session isn't active or routed yet,
            // which made the tone land on the earpiece or the silent-switch session.
            if oldValue == .listening { earcon(.stopped) }
            // The session's mode and route follow the phase, but not under the stop cue: switching
            // out of voice-chat mode, or the output, restarts the audio under a sound just begun,
            // which clipped the cue to a chirp. They wait until it has been heard (and a change
            // meanwhile waits with them), except for listening again, which needs them now.
            if oldValue == .listening, cueSettle > .zero {
                settling?.cancel()
                settling = Task { [weak self, cueSettle] in
                    try? await Task.sleep(for: cueSettle)
                    guard !Task.isCancelled, let self else { return }
                    settling = nil
                    audioForPhase()
                }
            } else if settling == nil || phase == .listening {
                settling?.cancel(); settling = nil
                audioForPhase()
            }
            if headsetControlsOn { publishNowPlaying() }
            updateScreenAwake()
            watchIfSpeaking()
            watchForQuiet()
            if phase == .idle || isErrored { stopMonitor() }
        }
    }
    private var headsetControlsOn = false
    /// The session's mode and route waiting on the stop cue (`cueSettle`).
    private var settling: Task<Void, Never>?
    var liveTranscript = ""
    var activeTool: String?
    var lastMetrics: VoiceMetrics?
    /// When true, the mic reopens automatically after each reply (hands-free mode, M2).
    var continuous = false
    /// A group chat's voice (`GroupVoice`): what is said goes there instead of the conversation,
    /// and the group chat reads its bots' replies and opens the mic again.
    var sendsTo: ((String) -> Void)?
    /// A group chat's voice as a live call (`GroupVoice`, Settings → Voice → Voice mode → Group
    /// Chats as Calls): the mic opens a call that speaks for the room (`LiveRoom`), in the engine given.
    var roomCall: (() -> (room: LiveRoom, engine: LiveEngine))?
    /// On a group chat's call: the member whose reply is being said (its profile).
    var liveRoomSpeaker: String? { live?.roomSpeaker }

    /// A member's reply, whole, for the group chat's call to say in its voice.
    func roomReplied(profile: String, text: String) { live?.roomReplied(profile: profile, text: text) }
    /// An agent's call this conversation answers (`AgentCalls`): told once, when voice mode ends
    /// (closed, hung up, a stop phrase, a live call that ended), so the phone call ends with it.
    var callEnded: (() -> Void)?
    /// The mic is held shut in the middle of a conversation (the car screen's Pause while Redde
    /// listens): the session is idle but not over. `unmute()`, or the mic by any other route,
    /// listens again.
    var isMuted = false

    /// A GPT-Live call (Settings → Voice → Voice mode), while there is one: it holds the
    /// conversation in place of the recogniser and the voice, and the phase is the call's.
    var live: LiveVoice?
    /// What GPT-Live's voice is saying, for the screen while it speaks.
    var liveSaid = ""
    var isLive: Bool { live != nil }
    /// Who holds the call, while there is one.
    var liveEngine: LiveEngine? { live?.engine }
    /// A GPT-Live call being set up.
    var liveConnecting: Bool { live.map { !$0.connected } ?? false }
    /// When the call was made, for how long it has been going (`CallBar`).
    var liveBegan: Date?
    /// The call goes on with the voice screen put away, as a bar over the chat (`CallBar`; asked
    /// 2026-11-09, "build the call bar"): the screen closing doesn't hang up (`VoiceView`), and
    /// the bar opens it again. Only ever true on a call; it ends with the call.
    var inBar = false

    /// The voice screen is being put away with the call left going. Nothing happens off a call.
    func moveToBar() {
        guard live != nil else { return }
        inBar = true
        setLooking(false)   // the camera is the voice screen's
    }

    /// The voice screen is back: closing it ends the call again, as it always did.
    func leaveBar() {
        inBar = false
        #if DEBUG
        if barPosed { barPosed = false; liveBegan = nil; isMuted = false }
        #endif
    }

    #if DEBUG
    /// `-echo.demoCallBar`: the bar with no call under it, a minute and some in, for pictures and
    /// the UI test. Its buttons do what they say to the bar alone.
    private(set) var barPosed = false
    func poseBar() {
        barPosed = true
        inBar = true
        liveBegan = .now - 83
    }
    #endif
    /// The call's start cue has played: its end gets the stop cue.
    var liveCued = false
    /// Settings → Voice → Voice mode is GPT-Live, and what makes a call. Injectable so tests choose.
    let liveWanted: (_ profile: String?) -> Bool
    let makeLive: (Conversation) -> LiveVoice
    /// Live calls go on with the phone locked (`Settings.liveWhenLocked`).
    let liveWhenLocked: () -> Bool
    /// The microphone allowed (a call needs no speech recognition). Injectable like `requestPermissions`.
    let micAllowed: () async -> Bool

    /// How loud the person is, 0…1, for the screen: the call's on GPT-Live, else the recogniser's.
    var micLevel: Float { live.map { Self.metered($0.inputLevel) } ?? recognizer.meterLevel }
    var micSmoothedLevel: Float { live.map { Self.metered($0.inputLevel) } ?? recognizer.level }
    /// How loud the reply is, 0…1: GPT-Live's voice, else Redde's.
    var replyLevel: Float { live.map { Self.metered($0.outputLevel) } ?? output.meterLevel }
    /// A call's level (RMS) on the meters' scale, -50…0 dB as 0…1, as the face and the waveform
    /// take Redde's own voice and microphone.
    static func metered(_ rms: Float) -> Float { min(max((20 * log10(max(rms, 1e-6)) + 50) / 50, 0), 1) }

    let recognizer: any VoiceRecognizing
    let output: any VoiceSpeaking
    let conversation: Conversation
    let audio: any VoiceAudioControlling
    /// Injectable so tests never touch the Speech authorization prompt.
    let requestPermissions: () async -> Bool
    /// Injectable so tests observe the cues instead of playing sounds.
    let earcon: (Earcon) -> Void
    /// How long the stop cue takes to be heard out once asked for (`EarconPlayer.lead` and the
    /// tone): the mode and route changes leaving listening wait this long. Zero in tests.
    let cueSettle: Duration
    /// Holds auto-lock off (true) or lets it be (false). Injectable so tests see it asked for.
    let keepAwake: (Bool) -> Void
    /// Settings → Voice → Talk over replies, and what it takes. Injectable so tests choose.
    let talkOver: () -> Settings.TalkOver
    /// Settings → Voice → Stop and Skip in the car.
    let commandsInCar: () -> Bool
    let interruption: () -> Settings.Interruption
    /// Settings → Voice → Stop phrases: the person's own, heard beside the built-in ones.
    let stopPhrases: () -> [String]
    /// Settings → Voice → Answer requests by voice. Injectable so tests choose.
    let answersAloud: () -> Bool
    /// Settings → Voice → Short answers in the car, and whether the phone is with a car right
    /// now (CarPlay, connected or not on its screen). Injectable so tests choose.
    let shortInCar: () -> Bool
    let carConnected: () -> Bool
    /// Where a note taken by voice goes (quick capture). Injectable so tests see it.
    let takeNote: (String) -> Void
    /// Settings → Voice → Thinking sound, and what plays it. Injectable so tests choose and listen.
    let thinkingSoundWanted: () -> Settings.ThinkingSound
    let thinkingSound: any ThinkingSounding
    /// Settings → Voice → Nod or shake to answer, and the AirPods' movement it reads.
    let answersByNod: () -> Bool
    let head: any HeadGestureSensing
    /// The camera the voice screen can open. Injectable so tests show it what they like.
    let eye: any VoiceLooking
    /// How an answer given aloud reaches the agent: the conversation's own way, unless a test listens.
    let respond: (SpokenRequest.Answer) -> Void
    var screenAwake = false
    var awakeTimeout: Task<Void, Never>?
    /// How long a wait for the reply holds the screen on. Past it the phone may lock: the reply
    /// carries on regardless, and a screen held on through a ten-minute task is a flat battery.
    var awakeWhileThinking: Duration = .seconds(120)
    /// On a call that goes on locked: how long the screen stays on after the voice last started
    /// or stopped talking.
    var awakeInCall: Duration = .seconds(60)
    let log = Logger(subsystem: "com.goosehouse.echo", category: "voice")
    var metrics = VoiceMetrics()
    var replyTask: Task<Void, Never>?
    var replySerial = 0
    /// What is said when a stop phrase is heard, in the listening language.
    static var okay: String {
        String(localized: "Okay.", bundle: VoiceWords.current.bundle, comment: "Said aloud in voice mode: an answer taken, or a stop phrase heard")
    }

    /// True while speaking the "Okay." that confirms a stop phrase; not a real turn.
    var acknowledging = false
    var replaying = false
    /// The reply is held by Pause: where it had got to while `.speaking`, or from its first word
    /// while it is still being thought about (`.thinking`, from the car's card).
    var isPaused = false {
        didSet { if isPaused != oldValue { updateScreenAwake(); watchIfSpeaking() } }
    }
    var replayResumesHandsFree = true

    /// The last thing Hermes said, if any; what Replay speaks.
    var lastReplyText: String? {
        conversation.messages.last { $0.role == .assistant && !$0.text.isEmpty }?.text
    }

    /// Speak the last reply again. Works from idle; tapping the mic while it plays interrupts.
    func replayLastReply() {
        guard let text = lastReplyText else { return }
        readAloud(text, resumeHandsFree: true, speaker: conversation.bot?.profile)
    }

    /// Speak any reply: the transcript's "Read aloud", and Replay. Works from idle; `stopSpeaking`
    /// or tapping the mic ends it. Only the voice screen's Replay reopens the mic afterwards in
    /// hands-free; reading from the transcript never starts listening.
    /// `speaker`: whose words they are, a bot's profile, read in that bot's voice (`BotVoices`).
    func readAloud(_ text: String, resumeHandsFree: Bool = false, speaker: String? = nil) {
        guard !text.isEmpty, beginReading(resumeHandsFree: resumeHandsFree, speaker: speaker) else { return }
        output.append(text)
        output.endReply()
    }

    /// Reads words still being written (a group chat's bot, as it writes): `readAloud` with the
    /// text to come, given by `continueReading` and ended by `endReading`. Speaking until then,
    /// and until the last of it has been heard. False when something else is going on.
    @discardableResult
    func beginReading(resumeHandsFree: Bool = false, speaker: String? = nil) -> Bool {
        guard phase == .idle || isErrored else { return false }
        output.speaker = speaker
        do { try audio.activateForPlayback() } catch {
            phase = .error(error.localizedDescription); return false
        }
        replaying = true
        replayResumesHandsFree = resumeHandsFree
        phase = .speaking
        output.beginReply()
        return true
    }

    /// More of what `beginReading` reads; nothing once that has been stopped.
    func continueReading(_ text: String) {
        guard replaying, phase == .speaking, !text.isEmpty else { return }
        output.append(text)
    }

    /// No more of it is coming.
    func endReading() {
        guard replaying, phase == .speaking else { return }
        output.endReply()
    }

    /// The first sentence of what will be read next, fetched now (`VoiceSpeaking.prefetch`).
    func prefetch(_ text: String?, whole: Bool = false, speaker: String? = nil) {
        output.prefetch(text, whole: whole, speaker: speaker)
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
         cueSettle: Duration = .milliseconds(450),
         keepAwake: @escaping (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 },
         talkOver: @escaping () -> Settings.TalkOver = { Settings.shared.talkOver },
         interruption: @escaping () -> Settings.Interruption = { Settings.shared.interruption },
         commandsInCar: @escaping () -> Bool = { Settings.shared.stopAndSkipInCar },
         stopPhrases: @escaping () -> [String] = { Settings.shared.stopPhrases },
         answersAloud: @escaping () -> Bool = { Settings.shared.answerRequestsByVoice },
         answersByNod: @escaping () -> Bool = { Settings.shared.answerRequestsByNod },
         shortInCar: @escaping () -> Bool = { Settings.shared.shortAnswersInCar },
         carConnected: @escaping () -> Bool = { CarPlaySceneDelegate.isConnected },
         takeNote: @escaping (String) -> Void = { CaptureInbox.shared.add($0) },
         thinkingSoundWanted: @escaping () -> Settings.ThinkingSound = { Settings.shared.thinkingSound },
         thinkingSound: any ThinkingSounding = ThinkingSoundPlayer.shared,
         respond: ((SpokenRequest.Answer) -> Void)? = nil,
         liveWanted: @escaping (_ profile: String?) -> Bool = { Settings.shared.usesLiveCall(for: $0) },
         makeLive: @escaping (Conversation) -> LiveVoice = { LiveVoice(conversation: $0) },
         liveWhenLocked: @escaping () -> Bool = { Settings.shared.liveWhenLocked },
         micAllowed: @escaping () async -> Bool = { await AVAudioApplication.requestRecordPermission() }) {
        self.liveWanted = liveWanted
        self.makeLive = makeLive
        self.liveWhenLocked = liveWhenLocked
        self.micAllowed = micAllowed
        self.talkOver = talkOver
        self.commandsInCar = commandsInCar
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
        self.cueSettle = cueSettle
        self.keepAwake = keepAwake
        output.onFirstSpeech = { [weak self] in
            self?.metrics.firstSpokenAt = .now
            if self?.phase == .speaking, self?.soundStartedAt == nil { self?.soundStartedAt = .now }
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
            resumeAfterInterruption = phase == .listening || phase == .thinking || phase == .speaking || live != nil
            // On an agent's call: paused, not hung up. The call goes on, and so does voice mode
            // when the interruption is over.
            if let call = callEnded {
                callEnded = nil
                cancel()
                callEnded = call
            } else {
                cancel()
            }
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
        // On a GPT-Live call the orb hangs up, whatever the call is doing.
        if live != nil { cancel(); return }
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
        case .idle: String(localized: "Ready", comment: "Voice mode's state, on the Lock Screen's player")
        case .listening: String(localized: "Listening", comment: "Voice mode's state, on the Lock Screen's player")
        case .thinking: ""   // stepped aside above
        case .speaking: String(localized: "Speaking", comment: "Voice mode's state, on the Lock Screen's player")
        case .error: String(localized: "Tap to try again", comment: "Voice mode's state, on the Lock Screen's player")
        }
        HeadsetControls.shared.setNowPlaying(status: status, active: phase == .listening || phase == .speaking)
    }

    /// A GPT-Live call with its microphone shut is idle, and still open (and billed).
    var mightBeBusy: Bool { phase != .idle || live != nil }

    // Stored here for VoiceSession+Actions.swift: an extension can't hold stored properties.

    /// What is being listened for is a note to file, not a question (quick capture): nothing is
    /// sent to the conversation and nothing comes back but "Noted."
    var isCapturing = false

    /// The camera is open on the voice screen: each question asked goes with a picture of what
    /// it sees as the question ends.
    var isLooking = false
    /// Why the camera couldn't be opened, for the voice screen to say.
    var lookProblem: String?
    /// Whether there is a camera to offer at all.
    var canLook: Bool { eye.isAvailable }

    /// An agent's line said on a call answered while locked (`answerCall`), for a live call that
    /// opens once unlocked to know of.
    var callLineSaid: String?

    /// Following a typed reply (`joinReply`).
    var joinTask: Task<Void, Never>?

    // Stored here for VoiceSession+Turns.swift.

    /// Which watch of the recogniser's words is the live one: each start of one retires the last.
    /// A watch ends only when the words change outside a listen, and a hands-free turn starts
    /// the next listen (and a new watch) with the last one still waiting, so one more was left
    /// running per turn, each writing `liveTranscript` on every word heard.
    @ObservationIgnored var transcriptWatch = 0

    /// How long there has to be nothing to hear, while the agent works, before the sound starts:
    /// an answer that comes at once has no need of it. And how often that is looked at.
    var thinkingSoundAfter: Duration = .seconds(2.5)
    var quietCheck: Duration = .milliseconds(200)
    /// In the middle of a reply, nothing to hear for `quietInReplyAfter` while the agent works on
    /// ("Let me check", then its tools): the car's face thinks again instead of moving its mouth
    /// over the quiet (asked 2026-10-31, "the onscreen bot looks like he's talking… change it to
    /// thinking when he's thinking"). Whatever the thinking sound's setting.
    var quietInReply = false
    var replyQuietSince: ContinuousClock.Instant?
    var quietInReplyAfter: Duration = .seconds(1.5)
    /// The reply's stream is still open: more may come, however long nothing has.
    var turnOpen = false
    var quietTask: Task<Void, Never>?
    var thinkingSoundOn = false

    /// When the thinking sound last stopped: a voice heard just after may still be its tail.
    var thinkingSoundStopped: ContinuousClock.Instant?

    #if DEBUG
    var quietBlockNoted = false
    #endif

    // Stored here for VoiceSession+Interruptions.swift.

    /// The request being put to the person aloud, from its being read out until it is answered,
    /// answered elsewhere or left for the screen. The voice screen shows its hint.
    var asking: SpokenRequest? {
        didSet { if asking?.id != oldValue?.id { watchHead() } }
    }
    /// How many answers so far weren't one. The second is the last.
    var unclearAnswers = 0
    /// Speaking the line that hands a request over to the screen.
    var leftForScreen = false
    var answerTimeout: Task<Void, Never>?
    /// How long silence may last before it counts as no answer.
    var answerWindow: Duration = .seconds(12)

    /// This turn's reply can be talked over: the mic stays open behind it, in the listening
    /// configuration (on the speaker that means voice-chat mode, at call volume).
    var micStaysOpen = false
    /// The mic is open behind the reply (`recognizer.startHeld`).
    var monitoring = false
    var monitorTask: Task<Void, Never>?
    var monitorSerial = 0
    /// A voice was heard and the reply is held while the recogniser finds out whether it was words.
    var confirmTask: Task<Void, Never>?
    /// How long the recogniser has to come up with words before the reply carries on. It starts
    /// a second back, so this is time to recognise what was said, not time to say it.
    var confirmWindow: Duration = .seconds(1.5)

    /// How long nothing new has to be heard before the wait for "stop" goes back to a level watch.
    var stopWordQuiet: Duration = .seconds(2.5)

    var isErrored: Bool {
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
        func f(_ label: String, _ v: TimeInterval?) -> String? {
            v.map { "\(label) " + Measurement(value: $0, unit: UnitDuration.seconds)
                .formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(2)))) }
        }
        var parts = [f("end→word", endToFirstWord), f("finalize", finalize), f("TTFT", timeToFirstToken),
                     f("TTS start", ttsStartup), f("model", modelTotal)].compactMap { $0 }
        if let pct = contextPercent {
            parts.append("ctx " + (pct / 100).formatted(.percent.precision(.fractionLength(1))))
        } else if let usage {
            parts.append("\(usage.total) tok")
        }
        if let tps = tokensPerSecond { parts.append(tps.formatted(.number.precision(.fractionLength(0))) + " tok/s") }
        return parts.joined(separator: " · ")
    }
}
