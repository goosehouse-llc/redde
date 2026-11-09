import AVFoundation
import Foundation
import os
#if canImport(WebRTC)
import WebRTC
#endif

/// Where a live call connects (`LiveSetup`): the WebSocket's address and headers, and what the
/// session opens with (worded by the call's `LiveDialect`). A Hermes Live / Codex call has no
/// WebSocket: `url` is the Dashboard's session route, and `hermesLive` sets the session up there.
struct LiveConnection: Sendable {
    var url: URL
    var headers: [String: String] = [:]
    var plan: LivePlan
    /// The session the talk-desktop plugin on the person's Hermes sets up (`HermesLiveCall`).
    var hermesLive: HermesLiveSignal?
}

/// One live call: the microphone, the voice, and the connection to the service (`LiveCall`; a
/// fake in tests).
@MainActor
protocol LiveCalling: AnyObject {
    /// Opens the microphone, ahead of the connection.
    func open() throws
    /// Connects and starts the session: returns once OpenAI says it has started, or throws why not.
    func connect(_ connection: LiveConnection) async throws
    /// The same call on a new session (another bot's voice): the microphone and the speaker go on.
    func reconnect(_ connection: LiveConnection) async throws
    /// One JSON event to OpenAI; false while there's no connection.
    func send(_ event: String) -> Bool
    /// The microphone held shut, or open again.
    func setMuted(_ muted: Bool)
    /// The voice's sound held back (what it sends meanwhile is dropped), or let through again:
    /// while Redde reads the agent's answer to the person itself (`LiveVoice`).
    func setVoiceHeld(_ held: Bool)
    /// An answer's sound (`LiveAnswerReader`): mono 16-bit PCM at the call's output rate, played as
    /// the voice is, held or not: as loud, from the same speaker, its echo cancelled.
    func playAnswer(_ pcm: Data)
    /// How much sound is waiting to be played, in seconds.
    var queuedSeconds: Double { get }
    /// How loud the person and the voice are right now, 0…1.
    var inputLevel: Float { get }
    var outputLevel: Float { get }
    /// Everything closed, the audio given back.
    func close()
    /// The answer to a request the voice handed over went to it: what it plays now is its voice
    /// again, not a sound while it waits (`LiveDialect.soundsWhileWaiting`).
    func answered()
    /// The voice cut off where it is, the call going on, where the service takes such a request
    /// (Hermes Live / Codex's `/codexlive/interrupt`); nothing elsewhere.
    func interrupt()
}

extension LiveCalling {
    func answered() {}
    func setVoiceHeld(_ held: Bool) {}
    func playAnswer(_ pcm: Data) {}
    var queuedSeconds: Double { 0 }
    func interrupt() {}
}

/// What a call tells `LiveVoice`, on the main actor.
@MainActor
protocol LiveCallListening: AnyObject {
    /// An event from OpenAI, as its JSON.
    func liveCallReceived(_ event: String)
    func liveCallChanged(_ state: LiveCallState)
}

/// What a call can tell of itself: the voice audible or quiet, the connection lost; and connected,
/// for a call whose connection is the session, with no event of the service's to say so
/// (`HermesLiveCall`: its audio and its data channel open).
nonisolated enum LiveCallState: String, Sendable {
    case speaking, quiet, lost, connected
}

/// A live call over a WebSocket, to whichever engine its `LiveDialect` speaks for (GPT-Live,
/// Gemini Live, Grok Voice): the connection is Apple's (URLSession, so Apple's TLS, and no
/// cryptography of Redde's own to declare anywhere), and the audio is raw PCM16 both ways at the
/// dialect's rates, recorded and played on one AVAudioEngine with Apple's voice processing, which
/// cancels the voice's own sound out of the microphone. Chosen over WebRTC on 2026-10-24, measured
/// on Marta: lighter on the phone (24 to 31% of a core against 32 to 34) and quicker to connect,
/// at more data (raw audio, 16 kHz to keep it down) and with no French encryption declaration.
/// Hermes Live / Codex alone is WebRTC (`HermesLiveCall`), as the plugin that sets it up has it.
/// docs/ARCHITECTURE.md (GPT-Live) has the rest.
@MainActor
final class LiveCall: LiveCalling {
    private weak var listener: LiveCallListening?
    private let dialect: any LiveDialect
    private let audio: LiveCallAudio
    private var socket: URLSessionWebSocketTask?
    private var started: CheckedContinuation<Void, Error>?
    private var reader: Task<Void, Never>?
    private var closed = false
    #if DEBUG
    private var measuring = false
    #endif
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "live")

    init(listener: LiveCallListening, dialect: any LiveDialect = GPTLiveDialect()) {
        self.listener = listener
        self.dialect = dialect
        #if DEBUG
        let measuring = DevHooks.has("-echo.liveMeasure")
        #else
        let measuring = false
        #endif
        // Talk over replies (Settings → Voice), as Redde's own voice: off, never while it plays.
        // On the phone's speaker, whatever it says, not with any but GPT-Live, which keeps the
        // voice's echo out itself: theirs came back through the echo cancelling as loud as the
        // person, and talking over them there never worked (Marta, 2026-10-25).
        let halfDuplex: LiveCallAudio.HalfDuplex = Settings.shared.talkOver == .off ? .always
            : dialect.engine == .gptLive ? .never : .onSpeaker
        audio = LiveCallAudio(inputRate: dialect.inputRate, outputRate: dialect.outputRate, gain: dialect.outputGain, halfDuplex: halfDuplex,
                              measuring: measuring, message: dialect.audio)
        audio.onSpeaking = Self.speakingRelay(self)
    }

    var inputLevel: Float { audio.levels().input }
    var outputLevel: Float { audio.levels().output }

    func open() throws {
        do { try audio.start() } catch { throw LiveFailure(String(localized: "The microphone couldn't start: \(error.localizedDescription)")) }
    }

    func connect(_ connection: LiveConnection) async throws {
        var request = URLRequest(url: connection.url)
        for (field, value) in connection.headers { request.setValue(value, forHTTPHeaderField: field) }
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.maximumMessageSize = 8 << 20
        self.socket = socket
        socket.resume()
        let opening = dialect.opening(connection.plan).map { type(of: dialect).encode($0) }
        try await withCheckedThrowingContinuation { (started: CheckedContinuation<Void, Error>) in
            self.started = started
            reader = Self.read(socket, dialect: dialect, audio: audio, owner: self)
            Task { for message in opening { try? await socket.send(.string(message)) } }
        }
        for message in dialect.afterStart(connection.plan, eventID: "start_1") { _ = send(type(of: dialect).encode(message)) }
        #if DEBUG
        if !measuring {
            measuring = true
            measure()
        }
        #endif
    }

    /// The same call on a new session: the old connection told to end and closed (what it still
    /// says goes unheard), the voice still queued from it dropped, the new one set up as the first.
    func reconnect(_ connection: LiveConnection) async throws {
        let old = socket
        reader?.cancel()
        reader = nil
        socket = nil
        audio.connect(nil)
        audio.flush()
        audio.newVoice()
        for message in dialect.close() { try? await old?.send(.string(type(of: dialect).encode(message))) }
        old?.cancel(with: .normalClosure, reason: nil)
        try await connect(connection)
    }

    func send(_ event: String) -> Bool {
        guard let socket, !closed else { return false }
        Task { try? await socket.send(.string(event)) }
        return true
    }

    func setMuted(_ muted: Bool) { audio.setMuted(muted) }

    func setVoiceHeld(_ held: Bool) { audio.setVoiceHeld(held) }
    func playAnswer(_ pcm: Data) { audio.playAnswer(pcm) }
    var queuedSeconds: Double { audio.queuedSeconds }

    func answered() { audio.waiting(false) }

    func close() {
        guard !closed else { return }
        closed = true
        reader?.cancel()
        audio.stop()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        finishStarting(LiveFailure(String(localized: "The call was closed.")))
    }

    // MARK: - What comes in

    /// Reads the socket away from the main actor: the voice's audio goes straight to the speaker
    /// (and what is queued of it goes when the person talks over it), everything else to `LiveVoice`.
    nonisolated private static func read(_ socket: URLSessionWebSocketTask, dialect: any LiveDialect, audio: LiveCallAudio,
                                         owner: LiveCall) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) { [weak owner] in
            while !Task.isCancelled {
                let text: String
                do {
                    switch try await socket.receive() {
                    case let .string(string): text = string
                    case let .data(data): text = String(decoding: data, as: UTF8.self)
                    @unknown default: continue
                    }
                } catch {
                    await owner?.lost(error.localizedDescription, from: socket)
                    return
                }
                audio.countReceived(text.utf8.count)
                var forward = false
                for event in dialect.read(text) {
                    switch event {
                    case let .audio(pcm): audio.play(pcm)
                    case .interrupted: audio.flush(); forward = true
                    // From here what it plays is its typing, not its voice, until the answer goes
                    // (`answered`): marked here, in order with the audio around it.
                    case .delegated where dialect.soundsWhileWaiting: audio.waiting(true); forward = true
                    case .withdrawn: audio.waiting(false); forward = true
                    case let .reply(message): try? await socket.send(.string(message))
                    default: forward = true
                    }
                }
                if forward { await owner?.received(text, from: socket) }
            }
        }
    }

    private func received(_ text: String, from socket: URLSessionWebSocketTask) {
        // A connection left for a new session (`reconnect`) is no longer heard.
        guard !closed, socket === self.socket else { return }
        if started != nil {
            for event in dialect.read(text) {
                switch event {
                case .started:
                    audio.connect(socket)
                    finishStarting(nil)
                case let .failed(message, _):
                    finishStarting(LiveFailure(message))
                case let .closed(reason):
                    finishStarting(LiveFailure(reason.map { LiveFailure.readable($0, engine: dialect.engine) } ?? String(localized: "\(dialect.engine.name) ended the call.")))
                default:
                    break
                }
            }
        }
        listener?.liveCallReceived(text)
    }

    private func finishStarting(_ problem: Error?) {
        guard let started else { return }
        self.started = nil
        if let problem { started.resume(throwing: problem) } else { started.resume() }
    }

    private func lost(_ problem: String, from socket: URLSessionWebSocketTask) {
        guard !closed, socket === self.socket else { return }
        log.error("live call connection: \(problem, privacy: .public)")
        if started != nil {
            finishStarting(LiveFailure(String(localized: "\(dialect.engine.name) couldn't connect: \(problem)")))
        } else {
            listener?.liveCallChanged(.lost)
        }
    }

    private func speakingChanged(_ speaking: Bool) {
        guard !closed else { return }
        listener?.liveCallChanged(speaking ? .speaking : .quiet)
    }

    /// Made outside the main actor, so the audio thread can call it.
    nonisolated private static func speakingRelay(_ call: LiveCall) -> @Sendable (Bool) -> Void {
        { [weak call] speaking in Task { @MainActor in call?.speakingChanged(speaking) } }
    }

    #if DEBUG
    /// Every ten seconds, the connection's side of the cost: data each way, how much of the voice
    /// was waiting to play and how often it ran out, and where the sound went.
    private func measure() {
        Task { [weak self] in
            var last = self?.audio.snapshot()
            var at = Date.now
            while let self, !closed {
                try? await Task.sleep(for: .seconds(10))
                guard !closed, let before = last else { return }
                let now = audio.snapshot(), seconds = Date.now.timeIntervalSince(at)
                LiveMeasure.write(String(format: "connection: up %.0f kbit/s, down %.0f kbit/s, voice queued at most %.0f ms, ran dry %d times, gated %.1f s (echo %.3f, loudest while the voice played %.3f, between replies %.3f), talked over %d times, audio restarted %d times, out to %@%@",
                                         Double(now.sent - before.sent) * 8 / 1000 / seconds,
                                         Double(now.received - before.received) * 8 / 1000 / seconds,
                                         now.mostQueuedMs, now.underruns - before.underruns,
                                         now.gated - before.gated, now.echoNow, now.echoPeak, now.speechPeak, now.bargeIns - before.bargeIns,
                                         now.restarts, now.route,
                                         now.replyGaps.isEmpty ? "" : "; the voice's audio arrived " + now.replyGaps.map { "\($0) ms" }.joined(separator: ", ") + " after the person's last sound"))
                LiveMeasure.write(String(format: "audio: the voice played at most %.3f, out of the mixer at most %.3f; %@", now.voicePeak, now.mixedPeak, now.engine))
                audio.clearReplyGaps()
                last = now
                at = .now
            }
        }
    }
    #endif
}

/// The call's audio, away from the main actor: the microphone to the connection, the voice to the
/// speaker, on one engine with Apple's voice processing (echo cancellation works only for sound
/// played through the same I/O unit that records).
nonisolated final class LiveCallAudio: @unchecked Sendable {
    struct Snapshot {
        var sent = 0, received = 0, underruns = 0, restarts = 0
        /// Seconds of the microphone sent as silence by the gate, and the loudest it heard while
        /// the voice played; and times the person talked over a voice the microphone was shut for.
        var gated = 0.0
        var bargeIns = 0
        var echoPeak: Float = 0, echoNow: Float = 0
        /// The loudest the microphone was between replies: the person, as it hears them.
        var speechPeak: Float = 0
        var mostQueuedMs = 0.0
        var route = ""
        var replyGaps: [Int] = []
        #if DEBUG
        /// The loudest the voice played and the mixer's output were since the last look, and how
        /// the engine stood then.
        var voicePeak: Float = 0, mixedPeak: Float = 0
        var engine = ""
        #endif
    }

    private struct State {
        var socket: URLSessionWebSocketTask?
        /// The microphone's level while the voice plays, averaged: its echo (`heard`); and until
        /// when it stays open after speech.
        var echo: Float = 0
        var openUntil: UInt64 = 0
        var muted = false
        /// The voice's sound dropped as it comes (`setVoiceHeld`).
        var voiceHeld = false
        var stopped = false
        var input: Float = 0, output: Float = 0
        var speaking = false
        var lastLoud: UInt64 = 0
        /// When the voice's audio was last loud enough to hear: OpenAI sends it as a steady stream,
        /// silence included, so speaking is told by the sound, not by audio arriving.
        var lastAudible: UInt64 = 0
        var lastDry: UInt64 = 0
        var generation = 0
        /// When the person was last heard talking (the microphone open for them), for `patience`;
        /// and the answer held for it, counted so a check for an earlier one lets go of nothing.
        var spokeAt: UInt64 = 0
        var waiting = 0
        var waitedSince: UInt64 = 0
        var stats = Snapshot()
    }

    /// Audio held before the voice starts playing, and again after it runs dry, against the
    /// network's jitter: 60 ms ran dry 2 to 5 times every 10 s on Marta (2026-10-24).
    private static let jitter = 0.12
    /// The voice's level above which it is speaking.
    private static let audible: Float = 0.03
    /// The microphone goes out 20 ms at a time: each I/O cycle alone would be 50 to 100 messages a second.
    private static let sendSeconds = 0.02
    /// The echo gate (`heard`): while the voice has been playing this lately, the microphone goes
    /// out as silence unless the person is louder than this, which what is left of the voice's own
    /// sound after Apple's echo cancelling never is (it read 0.00; a person talking, 0.09).
    private static let echoTail = 0.3
    private static let bargeIn: Float = 0.03
    /// Between replies, speech this loud opens the microphone (a person close to the phone; the
    /// room's voices were 0.01 to 0.02 and got through below 0.012), held open this long after.
    private static let speech: Float = 0.03
    private static let hold = 0.5
    /// While the voice plays, the gate sits this far above what its echo has been measuring.
    private static let aboveEcho: Float = 3
    private static let ceiling: Float = 0.15
    private static let settling = 0.8
    /// A second and a half of quiet after the person before the voice is heard answering: a second
    /// asked 2026-10-25 (GPT-Live has no setting for it and answered the moment they paused), then
    /// a second and a half (2026-10-26: ElevenLabs began 1.1 to 1.3 s after them, and a second
    /// never held it). An answer that begins sooner waits on the phone; what the voice says while
    /// they go on talking is dropped.
    private static let patience = 1.5
    /// Talking within this of the wait beginning is the end of what they were saying, not more.
    private static let patienceGrace = 0.25
    /// A wait no quiet ends (a noisy room) lets the answer go after this long.
    private static let patienceLongest = 8.0
    /// Below this the stream is silence, skipped while the queue is behind (`queue`).
    private static let silent: Float = 0.002

    var onSpeaking: (@Sendable (Bool) -> Void)?
    /// What the service takes: mono signed 16-bit little-endian PCM at the dialect's input rate.
    private let wire: AVAudioFormat
    /// What it gives, as played: mono at its output rate.
    private let playing: AVAudioFormat
    /// The voice brought to about GPT-Live's level: the gain it starts at (`LiveDialect.outputGain`),
    /// then what its speech measures as it comes (`queue`): a fixed one per service left ElevenLabs
    /// at a fifth of that with another voice and model (Marta, 2026-10-25). Touched on `sending`.
    private let gain: Float
    private var leveller: Float = 0
    private var loudness: Float = 0
    /// What comes now is the service's waiting sound (`waiting`). Touched on `sending`.
    private var waitingSound = false
    /// The level speech is brought to (RMS: GPT-Live's as it comes; 0.12 played ElevenLabs about
    /// twice as loud), and the most it is raised or lowered.
    private static let speechLevel: Float = 0.06
    private static let gainRange: ClosedRange<Float> = 0.2...8
    private let sendBytes: Int
    /// The microphone's audio as the message the service takes (`LiveDialect.audio`), from base64.
    private let message: @Sendable (String) -> String
    /// When nothing goes while the voice plays (`heard`): never, on the phone's own speaker, always.
    enum HalfDuplex: Sendable { case never, onSpeaker, always }
    private let halfDuplex: HalfDuplex
    /// Whether the sound is on the phone's own speaker, looked at once a second (on `sending`).
    private var speakerCheckedAt: UInt64 = 0
    private var speakerNow = true
    /// Talking over a voice that can't be heard over (`HalfDuplex`): someone loud enough, long
    /// enough, for Redde's own voice's detector (`BargeInDetector`), and the voice is held, the
    /// microphone opened, what it heard just before sent first, so "stop" arrives whole; the
    /// service interrupts it (`flush`), or with nothing more said it goes on. Asked 2026-10-25:
    /// "I'd like to still be able to ask them to stop". All on `sending`.
    private var detector = BargeInDetector.echoCancelled
    private var wasPlaying = false
    private var bargingSince: UInt64 = 0
    private var bargeQuietSince: UInt64 = 0
    /// The microphone's own audio, the last moments of it, kept while silence went instead.
    private var preRoll = Data()
    private static let preRollSeconds = 0.5
    /// A held voice goes on after this long without the person talking (a false start), or this
    /// long at most.
    private static let bargeQuiet = 1.2
    private static let bargeLongest = 8.0
    /// `-echo.liveMeasure` (DEBUG): what the voice plays and what leaves the mixer are measured too.
    private let measuring: Bool
    private let engine = AVAudioEngine()
    /// The voice waiting to play, pulled by `speaker` as the engine wants it.
    private let voice: VoiceQueue
    private var speaker: AVAudioSourceNode?
    private var sink: AVAudioSinkNode?
    private var converter: AVAudioConverter?
    /// The microphone's own format, one channel of it.
    private var heardFormat: AVAudioFormat?
    private var observer: NSObjectProtocol?
    /// The microphone's audio leaves the audio thread here, to be converted and sent; so do restarts.
    private let sending = DispatchQueue(label: "com.goosehouse.echo.live-call", qos: .userInitiated)
    /// Converted audio not yet sent; touched only on `sending`.
    private var pending = Data()
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(inputRate: Double, outputRate: Double, gain: Float = 1, halfDuplex: HalfDuplex = .never, measuring: Bool = false,
         message: @escaping @Sendable (String) -> String) {
        wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: inputRate, channels: 1, interleaved: true)!
        playing = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false)!
        sendBytes = Int(inputRate * Self.sendSeconds) * 2
        voice = VoiceQueue(capacity: Int(outputRate * 60), lead: Int(outputRate * Self.jitter), rate: outputRate)
        self.measuring = measuring
        self.message = message
        self.gain = gain
        self.halfDuplex = halfDuplex
    }

    private func onSpeaker() -> Bool {
        let now = mach_absolute_time()
        if speakerCheckedAt == 0 || AVAudioTime.seconds(forHostTime: now - speakerCheckedAt) > 1 {
            speakerCheckedAt = now
            #if os(iOS)
            speakerNow = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver }
            #else
            speakerNow = true   // a Mac's own speakers, near its microphones
            #endif
        }
        return speakerNow
    }

    func start() throws {
        #if !targetEnvironment(simulator)
        // The simulator's audio doesn't run with voice processing on.
        try engine.inputNode.setVoiceProcessingEnabled(true)
        // Its gain control off: it raised what was left of the voice's own sound after the echo
        // cancelling, and voices across the room, until the service took them for the person
        // (Marta, 2026-10-25: the voice's words heard back as "I'll check with Joe", and a
        // conversation in the room handed to the agent). The person, close, needs none.
        engine.inputNode.isVoiceProcessingAGCEnabled = false
        #endif
        try connectNodes()
        // The engine stops itself when the audio is set up anew under it (voice processing
        // switching the session to voice chat, a route change): started again, at the
        // microphone's format as it is then.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil,
                                                          using: Self.restarter(self))
        engine.prepare()
        try engine.start()
        Self.keepOnSpeaker()
    }

    /// The session has started: the microphone's audio goes to it from now on.
    func connect(_ socket: URLSessionWebSocketTask?) { state.withLock { $0.socket = socket } }
    func setMuted(_ muted: Bool) { state.withLock { $0.muted = muted } }

    /// The voice's sound held back, what is queued of it gone at once; or let through again.
    func setVoiceHeld(_ held: Bool) {
        state.withLock { $0.voiceHeld = held }
        if held { flush() }
    }
    /// How loud the person and the voice are: the voice as it plays, not as it came, which with
    /// Gemini's and ElevenLabs' audio, sent seconds ahead, left the face's mouth still through
    /// what it said (2026-10-25).
    func levels() -> (input: Float, output: Float) { (state.withLock { $0.input }, voice.playingLevel) }
    func countReceived(_ bytes: Int) { state.withLock { $0.stats.received += bytes } }
    func clearReplyGaps() { state.withLock { $0.stats.replyGaps.removeAll() } }

    func snapshot() -> Snapshot {
        #if os(iOS)
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: "+")
        #else
        let route = "Mac"
        #endif
        #if DEBUG
        let engineNote = describeEngine()
        #endif
        return state.withLock { state in
            state.stats.route = route
            state.stats.echoNow = state.echo
            defer {
                state.stats.echoPeak = 0
                state.stats.speechPeak = 0
            }
            #if DEBUG
            state.stats.engine = engineNote
            defer {
                state.stats.voicePeak = 0
                state.stats.mixedPeak = 0
            }
            #endif
            return state.stats
        }
    }

    #if DEBUG
    /// Whether the engine runs, and the formats and volumes between the voice and the speaker.
    private func describeEngine() -> String {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let sessionRate = session.sampleRate, volume = session.outputVolume
        #else
        let sessionRate = 0.0, volume: Float = 1
        #endif
        let into = engine.outputNode.inputFormat(forBus: 0), hardware = engine.outputNode.outputFormat(forBus: 0)
        let mixed = engine.mainMixerNode.outputFormat(forBus: 0)
        return String(format: "engine %@, mixer out %.0f Hz %u ch, into the output %.0f Hz %u ch, output %.0f Hz %u ch, session %.0f Hz, volume %.2f",
                      engine.isRunning ? "running" : "stopped",
                      mixed.sampleRate, mixed.channelCount, into.sampleRate, into.channelCount, hardware.sampleRate, hardware.channelCount,
                      sessionRate, volume)
    }
    #endif

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.stop()
        state.withLock { state in
            state.socket = nil
            state.stopped = true
        }
    }

    // MARK: The engine

    /// The voice to the speaker, the microphone to the sink, at the microphone's format now.
    private func connectNodes() throws {
        let input = engine.inputNode
        // The voice is pulled from a queue of its own as the engine renders, never scheduled on a
        // player node: a player laid it out on the engine's timeline, and about half the calls
        // with OpenAI's steady stream played every piece of it into nothing, a whole call silent
        // (Marta, 2026-10-25, with a stand-in streaming as OpenAI does; timed, untimed and
        // re-timed scheduling all did it, flushed or not).
        if speaker == nil {
            let speaker = AVAudioSourceNode(format: playing, renderBlock: VoiceQueue.renderer(voice, dry: Self.dryNotice(self)))
            engine.attach(speaker)
            self.speaker = speaker
        }
        if let speaker {
            engine.disconnectNodeOutput(speaker)
            engine.connect(speaker, to: engine.mainMixerNode, format: playing)
        }
        #if DEBUG
        if measuring, let speaker {
            let mixer = engine.mainMixerNode
            mixer.removeTap(onBus: 0)
            mixer.installTap(onBus: 0, bufferSize: 1024, format: nil, block: Self.meter(self, mixer: true))
            speaker.removeTap(onBus: 0)
            speaker.installTap(onBus: 0, bufferSize: 1024, format: nil, block: Self.meter(self, mixer: false))
        }
        #endif
        if let sink {
            engine.disconnectNodeInput(sink)
            engine.detach(sink)
            self.sink = nil
        }
        let format = input.outputFormat(forBus: 0)
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: wire) else {
            throw LiveFailure(String(localized: "The microphone's audio can't be converted for the call."))
        }
        heardFormat = mono
        self.converter = converter
        // A sink, not a tap: it has each I/O cycle's audio (10 to 20 ms) as it comes, where a tap
        // gathers 100 ms first, and that would be heard as 100 ms more before the voice answers.
        let sink = AVAudioSinkNode(receiverBlock: Self.receiver(self, channels: Int(format.channelCount), interleaved: format.isInterleaved))
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        self.sink = sink
    }

    private static func restarter(_ audio: LiveCallAudio) -> @Sendable (Notification) -> Void {
        { [weak audio] _ in
            guard let audio else { return }
            audio.sending.async { [audio] in audio.restart() }
        }
    }

    private func restart() {
        guard !state.withLock({ $0.stopped }) else { return }
        engine.stop()
        do {
            try connectNodes()
            engine.prepare()
            try engine.start()
            Self.keepOnSpeaker()
            state.withLock { $0.stats.restarts += 1 }
        } catch {
            Logger(subsystem: "com.goosehouse.echo", category: "live").error("live call audio didn't restart: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Voice processing switches the audio to voice chat, which on the iPhone's own speakers means
    /// the earpiece: back on the loudspeaker, unless a headset or the car has it.
    private static func keepOnSpeaker() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        guard session.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) else { return }
        try? session.overrideOutputAudioPort(.speaker)
        #endif
    }

    #if DEBUG
    private static func meter(_ audio: LiveCallAudio, mixer: Bool) -> AVAudioNodeTapBlock {
        { [weak audio] buffer, _ in
            guard let audio else { return }
            let level = rms(buffer)
            audio.state.withLock { state in
                if mixer { state.stats.mixedPeak = max(state.stats.mixedPeak, level) } else { state.stats.voicePeak = max(state.stats.voicePeak, level) }
            }
        }
    }
    #endif

    // MARK: The microphone

    /// The audio thread's part: the first channel copied out, and off to `sending`.
    private static func receiver(_ audio: LiveCallAudio, channels: Int, interleaved: Bool) -> AVAudioSinkNodeReceiverBlock {
        { [weak audio] _, frames, list in
            guard let audio, frames > 0 else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            guard let first = buffers.first, let raw = first.mData else { return noErr }
            let samples = raw.assumingMemoryBound(to: Float.self)
            let stride = interleaved ? max(1, channels) : 1
            let copy = (0..<Int(frames)).map { samples[$0 * stride] }
            audio.sending.async { [audio, copy] in audio.heard(copy) }
            return noErr
        }
    }

    private func heard(_ samples: [Float]) {
        guard let heardFormat, let buffer = AVAudioPCMBuffer(pcmFormat: heardFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        let level = Self.rms(buffer)
        let (socket, muted) = state.withLock { state in
            state.input = level
            if level > 0.02 { state.lastLoud = mach_absolute_time() }
            return (state.socket, state.muted)
        }
        guard let socket, !muted, let converter else { return }
        // The echo gate: what is left of the voice's own sound in the microphone, under the echo
        // cancelling, was heard as the person by Gemini and ElevenLabs, which stopped to listen,
        // stopping and starting through a reply (Marta, 2026-10-25). Silence goes instead, the
        // stream unbroken; the person, louder, still talks over it.
        // The gate learns the echo as it goes: the microphone's level while the voice plays (the
        // person talking over it raises it too, so it is kept under a ceiling).
        let (playing, playingFor) = voice.playedLoudly(within: Self.echoTail)
        // Whether it hears the person while the voice plays: not with talking over it off, nor on the
        // phone's speaker where only headphones may (looked at only while it plays).
        let listening = !playing || !(halfDuplex == .always || (halfDuplex == .onSpeaker && onSpeaker()))
        let now = mach_absolute_time()
        let seconds = Double(samples.count) / heardFormat.sampleRate
        let barging = bargeIn(playing: playing, listening: listening, level: level, seconds: seconds, now: now)
        let open = barging || state.withLock { state -> Bool in
            if playing {
                state.echo = state.echo == 0 ? level : state.echo * 0.95 + level * 0.05
                state.stats.echoPeak = max(state.stats.echoPeak, level)
                // Talking over the voice off here (Settings → Voice → Talk over replies, as Redde's
                // own voice): its echo came back in bursts as loud as the person ("Nightstand"
                // heard as "I'm not in that", Marta, 2026-10-25), so nothing goes while it plays.
                guard listening else { return false }
                // Each time the voice starts after a quiet the echo cancelling takes a moment to
                // settle (a 0.12 echo, and a reply cut short, as ElevenLabs began to speak).
                if playingFor < Self.settling { return level >= Self.ceiling }
                return level >= min(Self.ceiling, max(Self.bargeIn, state.echo * Self.aboveEcho))
            }
            // Between replies: speech close to the phone opens it, held a moment after, so a word's
            // quiet end goes too; a room's murmur and voices across it don't (asked 2026-10-25).
            state.stats.speechPeak = max(state.stats.speechPeak, level)
            if level >= Self.speech { state.openUntil = now + AVAudioTime.hostTime(forSeconds: Self.hold) }
            return now < state.openUntil
        }
        if !open { state.withLock { $0.stats.gated += seconds } }
        else if level >= Self.speech { state.withLock { $0.spokeAt = now } }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * wire.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: capacity) else { return }
        let source = Fed(buffer)
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in source.next(status) }
        guard error == nil, out.frameLength > 0, let converted = out.int16ChannelData else { return }
        let real = Data(bytes: converted[0], count: Int(out.frameLength) * 2)
        // What it heard, kept a moment, for a talking-over to send from where it began; silence
        // goes out instead while closed, the stream unbroken.
        preRoll.append(real)
        let keep = Int(wire.sampleRate * Self.preRollSeconds) * 2
        if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
        pending.append(open ? real : Data(count: real.count))
        guard pending.count >= sendBytes else { return }
        let message = message(pending.base64EncodedString())
        pending.removeAll(keepingCapacity: true)
        state.withLock { $0.stats.sent += message.utf8.count }
        socket.send(.string(message)) { _ in }
    }

    /// Whether the person is talking over a voice the microphone is shut for (`detector`): true
    /// from when they start, the voice held and what was heard just before sent first, until the
    /// service interrupts it (`flush`) or they stop without it doing so (then the voice goes on).
    private func bargeIn(playing: Bool, listening: Bool, level: Float, seconds: Double, now: UInt64) -> Bool {
        defer { wasPlaying = playing }
        if bargingSince != 0 {
            if level >= Self.speech { bargeQuietSince = now }
            let quiet = AVAudioTime.seconds(forHostTime: now - bargeQuietSince)
            let long = AVAudioTime.seconds(forHostTime: now - bargingSince)
            guard quiet > Self.bargeQuiet || long > Self.bargeLongest else { return true }
            endBargeIn(resume: true)
            return false
        }
        guard playing, !listening else { return false }
        if !wasPlaying { detector.rearm() }
        guard detector.feed(decibels: 20 * log10(max(level, 1e-6)), seconds: seconds) else { return false }
        bargingSince = now
        bargeQuietSince = now
        voice.hold(true)
        pending.append(preRoll)
        preRoll.removeAll(keepingCapacity: true)
        state.withLock { $0.stats.bargeIns += 1 }
        return true
    }

    /// The talking-over is over: the voice gone (the service interrupted it) or going on.
    private func endBargeIn(resume: Bool) {
        bargingSince = 0
        detector.rearm()
        if resume { voice.hold(false) }
    }

    /// Hands the converter one buffer, then says there's no more for now (the stream goes on).
    private final class Fed {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let buffer else { status.pointee = .noDataNow; return nil }
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
    }

    // MARK: The voice

    /// The voice's PCM16, read off the connection on the reading thread; queued on `sending`.
    func play(_ pcm: Data) {
        guard pcm.count >= 2, !state.withLock({ $0.voiceHeld }) else { return }
        sending.async { [weak self] in self?.queue(pcm) }
    }

    /// An answer's sound, the voice's way, while the voice's own is held (`LiveCalling.playAnswer`).
    func playAnswer(_ pcm: Data) {
        guard pcm.count >= 2 else { return }
        sending.async { [weak self] in self?.queue(pcm) }
    }

    var queuedSeconds: Double { Double(voice.queued) / playing.sampleRate }

    /// The service's sound while a request is out (`LiveDialect.soundsWhileWaiting`, ElevenLabs'
    /// typing): what comes meanwhile isn't the voice, neither for whether it speaks nor for the
    /// face's mouth (2026-10-26: "the 'thinking' keyboard sound shows the bot as speaking").
    func waiting(_ on: Bool) {
        sending.async { [weak self] in
            guard let self, waitingSound != on else { return }
            waitingSound = on
            voice.markSound(on)
        }
    }

    /// The person talked over the voice: what is queued of it goes, at once.
    func flush() {
        voice.clear()
        sending.async { [weak self] in
            self?.endBargeIn(resume: false)
            self?.state.withLock { $0.waiting += 1 }
        }
    }

    /// Another voice from now (the call gone on as another bot): its loudness measured afresh.
    func newVoice() {
        sending.async { [weak self] in
            guard let self else { return }
            loudness = 0
            leveller = gain
        }
    }

    private func queue(_ data: Data) {
        let frames = data.count / 2
        var samples = [Float](repeating: 0, count: frames)
        data.withUnsafeBytes { raw in
            let pcm = raw.bindMemory(to: Int16.self)
            for index in 0..<frames { samples[index] = Float(Int16(littleEndian: pcm[index])) / 32_768 }
        }
        // Speech (not the silence a stream carries) sets how loud the voice is, slowly.
        let raw = Self.rms(samples)
        // An answer held for the person (`patience`) leaves the queue behind the stream, and
        // GPT-Live's never stops, silence and all: its quiet between replies is skipped until the
        // queue has caught up, or each wait would add to every later reply.
        if raw < Self.silent, voice.queued > voice.leadSamples, !state.withLock({ $0.speaking }) { return }
        if leveller == 0 { leveller = gain }
        // A soft voice's speech counts too (Home's measured a fifth of Sol's, much of it under
        // 0.01), and a new one is caught up with in a second or so.
        if raw > 0.003, !waitingSound {
            loudness = loudness == 0 ? raw : loudness * 0.8 + raw * 0.2
            leveller = min(Self.gainRange.upperBound, max(Self.gainRange.lowerBound, Self.speechLevel / loudness))
        }
        for index in samples.indices { samples[index] = min(1, max(-1, samples[index] * leveller)) }
        // The waiting sound is played, never taken for the voice.
        let level = waitingSound ? 0 : Self.rms(samples)
        let (waited, queued) = samples.withUnsafeBufferPointer { voice.append($0) }
        let now = mach_absolute_time()
        let (begins, ends) = state.withLock { state -> (Bool, Bool) in
            state.output = level
            state.stats.mostQueuedMs = max(state.stats.mostQueuedMs, Double(queued) / playing.sampleRate * 1000)
            // Dry for a moment while it streams is an underrun.
            if waited, state.lastDry != 0, Self.seconds(now - state.lastDry) < 0.3 { state.stats.underruns += 1 }
            var begins = false, ends = false
            if level > Self.audible {
                state.lastAudible = now
                if !state.speaking {
                    begins = true
                    state.speaking = true
                    if state.lastLoud != 0 { state.stats.replyGaps.append(Int(Self.seconds(now - state.lastLoud) * 1000)) }
                }
            } else if state.speaking, Self.seconds(now - state.lastAudible) > 0.5 {
                ends = true
                state.speaking = false
            }
            return (begins, ends)
        }
        if begins {
            onSpeaking?(true)
            waitForQuiet(from: now)
        }
        if ends { onSpeaking?(false) }
    }

    /// The voice begins: if the person spoke less than `patience` ago, it waits until they have
    /// been quiet that long.
    private func waitForQuiet(from now: UInt64) {
        let (wait, after) = state.withLock { state -> (Int?, Double?) in
            guard state.spokeAt != 0 else { return (nil, nil) }
            let after = Self.seconds(now - state.spokeAt)
            guard after < Self.patience else { return (nil, after) }
            state.waiting += 1
            state.waitedSince = now
            return (state.waiting, after)
        }
        if let after { Self.log(String(format: "voice began %.0f ms after the person last spoke%@", after * 1000, wait == nil ? "" : ": held")) }
        guard let wait else { return }
        voice.wait(true)
        checkQuiet(wait)
    }

    private func checkQuiet(_ wait: Int, dropped: Bool = false) {
        sending.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            let now = mach_absolute_time()
            let (current, spokeAt, since) = state.withLock { ($0.waiting == wait, $0.spokeAt, $0.waitedSince) }
            guard current else { return }
            if Self.seconds(now - spokeAt) >= Self.patience || Self.seconds(now - since) > Self.patienceLongest {
                voice.wait(false)
                Self.log(String(format: "voice let go after %.0f ms held", Self.seconds(now - since) * 1000))
                return
            }
            // Still talking, past the end of what they were saying: what the voice started on was
            // too soon, and goes; it answers again once they're done.
            var dropping = false
            if spokeAt > since, Self.seconds(spokeAt - since) > Self.patienceGrace, Self.seconds(now - spokeAt) < 0.15 {
                voice.clear()
                voice.wait(true)
                dropping = true
                if !dropped { Self.log("the person went on talking: what the voice began was dropped") }
            }
            checkQuiet(wait, dropped: dropped || dropping)
        }
    }

    /// The wait for the person, in a development build's call log (`LiveMeasure`), to tell from
    /// what they heard (2026-10-26: "it didn't wait 1 second").
    private static func log(_ line: String) {
        #if DEBUG
        Task { @MainActor in LiveMeasure.write(line) }
        #endif
    }

    private static func dryNotice(_ audio: LiveCallAudio) -> @Sendable () -> Void {
        { [weak audio] in
            guard let audio else { return }
            audio.sending.async { [audio] in audio.ranDry() }
        }
    }

    /// The voice ran out: quiet once nothing more has come for a moment.
    private func ranDry() {
        let generation = state.withLock { state in
            state.lastDry = mach_absolute_time()
            state.generation += 1
            return state.generation
        }
        sending.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let empty = voice.isEmpty
            let quiet = state.withLock { state -> Bool in
                guard state.generation == generation, empty, state.speaking else { return false }
                state.speaking = false
                state.output = 0
                return true
            }
            if quiet { onSpeaking?(false) }
        }
    }

    // MARK: Measures

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        return rms(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private static func rms<Samples: Collection>(_ samples: Samples) -> Float where Samples.Element == Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    private static func seconds(_ ticks: UInt64) -> Double {
        AVAudioTime.seconds(forHostTime: ticks)
    }
}

/// The voice between the connection and the speaker: a ring of samples, written as it arrives and
/// read as the engine renders. It holds `lead` samples before it starts to play, and again after it
/// runs out, against the network's jitter; past `capacity` (a minute) the oldest go.
nonisolated final class VoiceQueue: @unchecked Sendable {
    private struct Ring {
        var samples: [Float]
        var read = 0, count = 0
        /// Playing, as against holding back until `lead` has come.
        var flowing = false
        /// When what played was last loud enough to be heard back in the microphone.
        var loudAt: UInt64 = 0
        /// When the voice last started to be loud after a quiet: the echo cancelling settling.
        var loudSince: UInt64 = 0
        /// How loud what played last was (RMS), and when: the face's mouth goes by it.
        var playedLevel: Float = 0
        var playedAt: UInt64 = 0
        /// Held: silence plays, what is queued waits (the person talking over it).
        var held = false
        /// Waiting: the same, for the person to finish (`LiveCallAudio.patience`).
        var waiting = false
        /// Samples ever added and ever played (or dropped), and the stretches of them that are a
        /// sound the service plays while it waits (`markSound`), which leave the meter at rest.
        var written = 0, played = 0
        var soundFrom: Int?
        var sounds: [Range<Int>] = []

        func isSound(_ sample: Int) -> Bool {
            if let soundFrom, sample >= soundFrom { return true }
            return sounds.contains { $0.contains(sample) }
        }
    }

    private let lead: Int
    /// Its sample rate, for the meter's release.
    private let rate: Double
    private let ring: OSAllocatedUnfairLock<Ring>

    init(capacity: Int, lead: Int, rate: Double) {
        self.lead = lead
        self.rate = rate
        ring = OSAllocatedUnfairLock(initialState: Ring(samples: [Float](repeating: 0, count: max(capacity, lead * 2))))
    }

    var isEmpty: Bool { ring.withLock { $0.count == 0 } }
    /// How many samples are queued.
    var queued: Int { ring.withLock { $0.count } }
    /// How many it holds back before it starts to play.
    var leadSamples: Int { lead }

    /// How loud the voice is as it plays now: nothing once it has stopped.
    var playingLevel: Float {
        let (level, at) = ring.withLock { ($0.playedLevel, $0.playedAt) }
        return at != 0 && AVAudioTime.seconds(forHostTime: mach_absolute_time() - at) < 0.1 ? level : 0
    }

    /// The voice was played loud enough, this lately, to be heard back in the microphone; and how
    /// long it has been playing since it last started after a quiet.
    func playedLoudly(within seconds: Double) -> (playing: Bool, for: Double) {
        let (at, since) = ring.withLock { ($0.loudAt, $0.loudSince) }
        let now = mach_absolute_time()
        guard at != 0, AVAudioTime.seconds(forHostTime: now - at) < seconds else { return (false, 0) }
        return (true, AVAudioTime.seconds(forHostTime: now - since))
    }

    /// What is added from now on is (or no longer is) a sound the service plays while it waits,
    /// not the voice: played as it comes, with the meter at rest.
    func markSound(_ on: Bool) {
        ring.withLock { ring in
            if on {
                if ring.soundFrom == nil { ring.soundFrom = ring.written }
            } else if let from = ring.soundFrom {
                ring.sounds.append(from ..< ring.written)
                ring.soundFrom = nil
            }
        }
    }

    /// Everything queued gone, holding back again.
    func clear() {
        ring.withLock { ring in
            ring.played = ring.written
            ring.sounds.removeAll()
            if ring.soundFrom != nil { ring.soundFrom = ring.written }
            ring.count = 0
            ring.flowing = false
            ring.held = false
            ring.waiting = false
        }
    }

    /// Silence while held, what is queued kept for when it isn't.
    func hold(_ held: Bool) { ring.withLock { $0.held = held } }

    /// Silence while waiting for the person to finish, what is queued kept for when they have.
    func wait(_ waiting: Bool) { ring.withLock { $0.waiting = waiting } }

    /// The audio thread's part, for an `AVAudioSourceNode`: what is queued, or silence; `dry` told
    /// each time it runs out.
    static func renderer(_ voice: VoiceQueue, dry: (@Sendable () -> Void)? = nil) -> AVAudioSourceNodeRenderBlock {
        { isSilence, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let first = buffers.first, let raw = first.mData else { return noErr }
            let (played, ranDry) = voice.render(into: raw.assumingMemoryBound(to: Float.self), frames: Int(frames))
            if played == 0 { isSilence.pointee = true }
            if ranDry { dry?() }
            return noErr
        }
    }

    /// PCM16 as it comes over the connection, added at `gain`; returns its level (0…1, RMS).
    func appendPCM16(_ data: Data, gain: Float = 1) -> Float {
        let frames = data.count / 2
        guard frames > 0 else { return 0 }
        var samples = [Float](repeating: 0, count: frames)
        data.withUnsafeBytes { raw in
            let pcm = raw.bindMemory(to: Int16.self)
            for index in 0..<frames { samples[index] = Float(Int16(littleEndian: pcm[index])) / 32_768 * gain }
        }
        _ = samples.withUnsafeBufferPointer { append($0) }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(frames)).squareRoot()
    }

    /// Adds what came; says whether it came to a queue that had run dry, and how much is queued now.
    func append(_ new: UnsafeBufferPointer<Float>) -> (waited: Bool, queued: Int) {
        ring.withLockUnchecked { ring in
            let waited = !ring.flowing && ring.count == 0
            let size = ring.samples.count
            for sample in new {
                if ring.count == size {
                    ring.read = (ring.read + 1) % size
                    ring.count -= 1
                    ring.played += 1
                }
                ring.samples[(ring.read + ring.count) % size] = sample
                ring.count += 1
                ring.written += 1
            }
            if !ring.flowing, ring.count >= lead { ring.flowing = true }
            return (waited, ring.count)
        }
    }

    /// Fills `frames` samples for the speaker; returns how many were the voice's (the rest is
    /// silence) and whether it ran out just now.
    func render(into out: UnsafeMutablePointer<Float>, frames: Int) -> (played: Int, ranDry: Bool) {
        ring.withLockUnchecked { ring in
            var played = 0
            if ring.flowing, !ring.held, !ring.waiting {
                let size = ring.samples.count
                played = min(frames, ring.count)
                ring.samples.withUnsafeBufferPointer { samples in
                    for index in 0..<played { out[index] = samples[(ring.read + index) % size] }
                }
                ring.read = (ring.read + played) % size
                ring.count -= played
                let sound = ring.isSound(ring.played)
                ring.played += played
                ring.sounds.removeAll { $0.upperBound <= ring.played }
                var sum: Float = 0
                for index in 0..<played { sum += out[index] * out[index] }
                // As Redde's own voice is metered (`OutputMeter`): at once up, half again in 60 ms
                // down; unsmoothed, the face's mouth flickered with every few milliseconds. The
                // service's waiting sound is heard (and gated against below) but leaves the mouth at rest.
                let release = Float(pow(0.5, Double(frames) / (rate * 0.06)))
                let voiceLevel = played > 0 && !sound ? (sum / Float(played)).squareRoot() : 0
                ring.playedLevel = max(voiceLevel, ring.playedLevel * release)
                ring.playedAt = mach_absolute_time()
                if played > 0, (sum / Float(played)).squareRoot() > 0.02 {
                    let now = mach_absolute_time()
                    if ring.loudAt == 0 || AVAudioTime.seconds(forHostTime: now - ring.loudAt) > 0.5 { ring.loudSince = now }
                    ring.loudAt = now
                }
            }
            for index in played..<frames { out[index] = 0 }
            let ranDry = ring.flowing && ring.count == 0
            if ranDry { ring.flowing = false }
            return (played, ranDry)
        }
    }
}

// MARK: - Hermes Live / Codex

/// A Hermes Live / Codex call (`LiveEngine.hermesLive`, asked 2026-10-30): WebRTC, the microphone
/// its audio track and the voice played as WebRTC plays a call (its voice processing, echo
/// cancelling included), the events on its `oai-events` data channel (`HermesLiveDialect`). The
/// person's Hermes sets the session up through its talk-desktop plugin (`HermesLiveSignal`): the
/// call's offer goes to the Dashboard, the plugin answers it with the Codex sign-in on that machine,
/// and the sound then goes between the phone and OpenAI; cutting the voice off and stopping the
/// session are the plugin's routes too. A session that would work requests anywhere but this chat
/// (no client-managed handoffs) goes no further. WebRTC is Google's, built by stasel/WebRTC, and
/// carries its own BoringSSL for DTLS and SRTP, cryptography that isn't the operating system's:
/// why the other engines stay on WebSockets (`LiveCall`), and docs/app-store-listing.md (Export
/// compliance) says what it changes. In the iPhone and iPad app only; the Mac's has no WebRTC.
@MainActor
final class HermesLiveCall: LiveCalling {
    /// This build can make one.
    nonisolated static var available: Bool {
        #if canImport(WebRTC)
        return true
        #else
        return false
        #endif
    }

    private weak var listener: LiveCallListening?
    private let dialect: any LiveDialect
    /// The session on the Hermes: what asked for it, and what the plugin answered.
    private var signal: HermesLiveSignal?
    private var session: HermesLiveSession?
    private var stopped = false
    private var closed = false
    /// Its audio and its channel are open; and `connect` waiting for them, or why they never will.
    private var opened = false
    private var connecting: CheckedContinuation<Void, Error>?
    private var broken: String?
    private var muted = false
    private var speaking = false
    private var lastAudible = ContinuousClock.now
    private(set) var inputLevel: Float = 0
    private(set) var outputLevel: Float = 0
    private var following: Task<Void, Never>?
    private var metering: Task<Void, Never>?
    private var dropping: Task<Void, Never>?
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "live")
    #if canImport(WebRTC)
    private var link: HermesLiveLink?
    #endif
    #if canImport(WebRTC) && os(iOS)
    private var tookAudio = false
    #endif

    /// The voice is speaking above this level (WebRTC's, 0…1, as `LiveCallAudio` hears its own),
    /// and has stopped after this long below it.
    private static let audible: Float = 0.03
    private static let quietAfter: Duration = .milliseconds(500)
    /// How long the audio may take to come through once the plugin has answered.
    private static let openWithin: Duration = .seconds(20)
    /// A connection that drops can come back by itself (a change of network): lost after this long.
    private static let dropGrace: Duration = .seconds(6)

    init(listener: LiveCallListening, dialect: any LiveDialect = HermesLiveDialect()) {
        self.listener = listener
        self.dialect = dialect
    }

    func open() throws {
        #if canImport(WebRTC)
        guard link == nil, !closed else { return }
        #if os(iOS)
        takeAudio()
        #endif
        do {
            link = try HermesLiveLink(channel: HermesLiveLink.channelLabel)
        } catch {
            #if os(iOS)
            giveAudioBack()
            #endif
            throw error
        }
        #else
        throw LiveFailure(HermesLiveSignal.needsDevice)
        #endif
    }

    /// The offer to the plugin, its answer taken, the audio let through, and back once the audio
    /// and the data channel are open: the call is on. A session the plugin answers with
    /// requests going anywhere but this chat is stopped, and says why.
    func connect(_ connection: LiveConnection) async throws {
        #if canImport(WebRTC)
        guard let signal = connection.hermesLive else {
            throw LiveFailure(String(localized: "\(dialect.engine.name) has no session on your Hermes to connect to."))
        }
        guard let link, !closed else { throw LiveFailure(String(localized: "The call was closed.")) }
        self.signal = signal
        follow(link)
        let offer: String = try await withCheckedThrowingContinuation { made in
            link.offer { made.resume(with: $0) }
        }
        guard !closed else { throw LiveFailure(String(localized: "The call was closed.")) }
        let reply: JSONValue
        do {
            reply = try await signal.post(HermesLiveSignal.sessionPath, signal.sessionRequest(offer: offer))
        } catch {
            throw HermesLiveSignal.failure(error)
        }
        let session = try HermesLiveSession(reply: reply)
        // From here the session is the plugin's to stop, however the call ends.
        self.session = session
        guard !closed else {
            stopSession()
            throw LiveFailure(String(localized: "The call was closed."))
        }
        // Plugin warnings can include server-side account or session detail. Keep them out of
        // ordinary device logs; the user-facing failure below remains the explicit disclosure.
        for warning in session.warnings { log.notice("talk-desktop: \(warning, privacy: .private)") }
        if let problem = session.handoffProblem { throw LiveFailure(problem) }
        try await withCheckedThrowingContinuation { (answered: CheckedContinuation<Void, Error>) in
            link.takeAnswer(session.answer) { problem in
                if let problem { answered.resume(throwing: problem) } else { answered.resume() }
            }
        }
        guard !closed else { throw LiveFailure(String(localized: "The call was closed.")) }
        #if os(iOS)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
        Self.keepOnSpeaker()
        #endif
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.openWithin)
            guard !Task.isCancelled else { return }
            self?.finishConnecting(LiveFailure(String(localized: "Hermes Live / Codex didn't connect: the call's audio never came through.")))
        }
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { (open: CheckedContinuation<Void, Error>) in
            if opened {
                open.resume()
            } else if let broken {
                open.resume(throwing: LiveFailure(String(localized: "Hermes Live / Codex couldn't connect: \(broken).")))
            } else {
                connecting = open
            }
        }
        #else
        throw LiveFailure(HermesLiveSignal.needsDevice)
        #endif
    }

    /// Another voice would be another session of the plugin's, which says no line of Redde's
    /// (`LiveEngine.greets`): not offered, and refused.
    func reconnect(_ connection: LiveConnection) async throws {
        throw LiveFailure(String(localized: "\(dialect.engine.name) can't go on in another voice: your Hermes words its session."))
    }

    func send(_ event: String) -> Bool {
        #if canImport(WebRTC)
        guard !closed, opened, let link else { return false }
        return link.send(event)
        #else
        return false
        #endif
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        #if canImport(WebRTC)
        link?.setMicrophone(on: !muted)
        #endif
    }

    func interrupt() {
        guard !closed, let signal, let session else { return }
        Self.post(HermesLiveSignal.interruptPath, session.request(profile: signal.profile), with: signal, log: log)
    }

    func close() {
        guard !closed else { return }
        closed = true
        following?.cancel()
        metering?.cancel()
        dropping?.cancel()
        #if canImport(WebRTC)
        link?.close()
        link = nil
        #if os(iOS)
        giveAudioBack()
        #endif
        #endif
        stopSession()
        finishConnecting(LiveFailure(String(localized: "The call was closed.")))
    }

    /// The session ended on the Hermes, so it stops at once: asked once, not waited for.
    private func stopSession() {
        guard !stopped, let signal, let session else { return }
        stopped = true
        Self.post(HermesLiveSignal.stopPath, session.request(profile: signal.profile), with: signal, log: log)
    }

    private static func post(_ path: String, _ body: JSONValue, with signal: HermesLiveSignal, log: Logger) {
        Task {
            do {
                _ = try await signal.post(path, body)
            } catch {
                log.error("Hermes Live \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func finishConnecting(_ problem: Error?) {
        guard let connecting else { return }
        self.connecting = nil
        if let problem { connecting.resume(throwing: problem) } else { connecting.resume() }
    }

    /// The connection gone: while connecting, why it couldn't; once on, the call is lost.
    private func lost(_ why: String) {
        guard !closed else { return }
        log.error("Hermes Live call: \(why, privacy: .public)")
        if connecting != nil {
            finishConnecting(LiveFailure(String(localized: "Hermes Live / Codex couldn't connect: \(why).")))
        } else if opened {
            listener?.liveCallChanged(.lost)
        } else {
            broken = why
        }
    }

    /// The voice's level and the person's, every tenth of a second while the call is on: the
    /// screen's, and whether the voice is speaking (WebRTC plays it; nothing else tells).
    private func heard(input: Float, output: Float) {
        guard !closed else { return }
        inputLevel = muted ? 0 : input
        outputLevel = output
        let now = ContinuousClock.now
        if output > Self.audible {
            lastAudible = now
            if !speaking {
                speaking = true
                listener?.liveCallChanged(.speaking)
            }
        } else if speaking, now - lastAudible > Self.quietAfter {
            speaking = false
            listener?.liveCallChanged(.quiet)
        }
    }

    #if canImport(WebRTC)
    /// What the link says, in the order it said it.
    private func follow(_ link: HermesLiveLink) {
        following?.cancel()
        following = Task { [weak self] in
            for await event in link.events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: HermesLiveLink.Event) {
        guard !closed else { return }
        switch event {
        case let .message(text):
            listener?.liveCallReceived(text)
        case .open:
            guard !opened else { return }
            opened = true
            finishConnecting(nil)
            listener?.liveCallChanged(.connected)
            meter()
        case .closed:
            lost(String(localized: "its event channel closed"))
        case .connected:
            dropping?.cancel()
            dropping = nil
        case .disconnected:
            guard dropping == nil else { return }
            dropping = Task { [weak self] in
                try? await Task.sleep(for: Self.dropGrace)
                guard !Task.isCancelled else { return }
                self?.lost(String(localized: "the connection dropped"))
            }
        case .failed:
            lost(String(localized: "the connection failed"))
        }
    }

    private func meter() {
        metering?.cancel()
        metering = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let link = self?.link else { return }
                let levels = await withCheckedContinuation { (read: CheckedContinuation<HermesLiveLink.Levels, Never>) in
                    link.levels { read.resume(returning: $0) }
                }
                self?.heard(input: levels.input, output: levels.output)
            }
        }
    }
    #endif

    #if canImport(WebRTC) && os(iOS)
    /// WebRTC plays and records on the session voice mode set up (`AudioSessionController`), not
    /// on one of its own: given its category, mode and options so it changes none of them, told it
    /// is active already, and kept from starting its audio until the plugin has answered.
    private func takeAudio() {
        guard !tookAudio else { return }
        tookAudio = true
        let session = AVAudioSession.sharedInstance()
        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.category = session.category.rawValue
        configuration.categoryOptions = session.categoryOptions
        configuration.mode = session.mode.rawValue
        RTCAudioSessionConfiguration.setWebRTC(configuration)
        let rtc = RTCAudioSession.sharedInstance()
        rtc.useManualAudio = true
        rtc.isAudioEnabled = false
        rtc.audioSessionDidActivate(session)
    }

    /// WebRTC's audio stopped and the session no longer counted as its, without ending it: voice
    /// mode does that, after its closing cue.
    private func giveAudioBack() {
        guard tookAudio else { return }
        tookAudio = false
        let rtc = RTCAudioSession.sharedInstance()
        rtc.isAudioEnabled = false
        rtc.audioSessionDidDeactivate(AVAudioSession.sharedInstance())
    }

    /// Voice processing puts the iPhone's own output on the earpiece: back on the loudspeaker,
    /// unless a headset or the car has it (as `LiveCallAudio` does).
    private static func keepOnSpeaker() {
        let session = AVAudioSession.sharedInstance()
        guard session.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) else { return }
        try? session.overrideOutputAudioPort(.speaker)
    }
    #endif
}

#if canImport(WebRTC)
/// The WebRTC side of a Hermes Live call, off the main actor: WebRTC tells its delegates things
/// on threads of its own, and what they say goes to the call as `events`, in order. Audio only,
/// with no STUN or TURN server: the plugin's answer names where the media goes, and the phone
/// reaches no one else.
nonisolated final class HermesLiveLink: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case message(String)
        /// The data channel is open (and with it the connection), or closed.
        case open, closed
        /// The connection as ICE has it.
        case connected, disconnected, failed
    }

    struct Levels: Sendable {
        var input: Float = 0
        var output: Float = 0
    }

    /// The data channel OpenAI's realtime calls carry their events on.
    static let channelLabel = "oai-events"
    /// One for the app, as WebRTC advises: its threads and its audio are every call's.
    nonisolated(unsafe) private static let factory: RTCPeerConnectionFactory = {
        _ = RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    let events: AsyncStream<Event>
    private let feed: AsyncStream<Event>.Continuation
    private let peer: RTCPeerConnection
    private let channel: RTCDataChannel
    private let microphone: RTCAudioTrack
    private let shut = OSAllocatedUnfairLock(initialState: false)

    /// A peer connection with the microphone's track and a data channel named `label`. (Not a
    /// bare `init()`: NSObject's can't be overridden by one that throws.)
    init(channel label: String) throws {
        let factory = HermesLiveLink.factory
        let none = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: RTCConfiguration(), constraints: none, delegate: nil) else {
            throw LiveFailure(String(localized: "The call's connection couldn't be made."))
        }
        let microphone = factory.audioTrack(with: factory.audioSource(with: none), trackId: "redde-microphone")
        _ = peer.add(microphone, streamIds: ["redde"])
        guard let channel = peer.dataChannel(forLabel: label, configuration: RTCDataChannelConfiguration()) else {
            peer.close()
            throw LiveFailure(String(localized: "The call's event channel couldn't be made."))
        }
        let stream = AsyncStream.makeStream(of: Event.self)
        events = stream.stream
        feed = stream.continuation
        self.peer = peer
        self.channel = channel
        self.microphone = microphone
        super.init()
        peer.delegate = self
        channel.delegate = self
    }

    private var isShut: Bool { shut.withLock { $0 } }

    /// The call's offer, made and set as its own: the SDP the plugin answers.
    func offer(_ done: @escaping @Sendable (Result<String, any Error>) -> Void) {
        let none = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peer.offer(for: none) { [weak self] description, error in
            guard let self, let description else {
                done(.failure(error ?? LiveFailure(String(localized: "The call's offer couldn't be made."))))
                return
            }
            let sdp = description.sdp
            self.peer.setLocalDescription(description) { error in
                if let error { done(.failure(error)) } else { done(.success(sdp)) }
            }
        }
    }

    /// The plugin's answer, set as the other side's.
    func takeAnswer(_ sdp: String, _ done: @escaping @Sendable ((any Error)?) -> Void) {
        peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { error in done(error) }
    }

    /// One event on the data channel; false while it isn't open.
    func send(_ text: String) -> Bool {
        guard !isShut, channel.readyState == .open else { return false }
        return channel.sendData(RTCDataBuffer(data: Data(text.utf8), isBinary: false))
    }

    /// The microphone's track off (silence goes) or on again.
    func setMicrophone(on: Bool) { microphone.isEnabled = on }

    /// How loud the person and the voice are now, from WebRTC's own reckoning (`audioLevel`,
    /// 0…1): the microphone's source, and what comes in.
    func levels(_ done: @escaping @Sendable (Levels) -> Void) {
        guard !isShut else { done(Levels()); return }
        peer.statistics { report in
            var levels = Levels()
            for entry in report.statistics.values {
                guard let level = (entry.values["audioLevel"] as? NSNumber)?.floatValue else { continue }
                switch entry.type {
                case "inbound-rtp": levels.output = max(levels.output, level)
                case "media-source": levels.input = max(levels.input, level)
                default: break
                }
            }
            done(levels)
        }
    }

    func close() {
        let closing = shut.withLock { shut -> Bool in
            guard !shut else { return false }
            shut = true
            return true
        }
        guard closing else { return }
        channel.delegate = nil
        peer.delegate = nil
        channel.close()
        peer.close()
        feed.finish()
    }

    // MARK: WebRTC's delegates

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .connected, .completed: feed.yield(.connected)
        case .disconnected: feed.yield(.disconnected)
        case .failed: feed.yield(.failed)
        default: break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open: feed.yield(.open)
        case .closed: feed.yield(.closed)
        default: break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        feed.yield(.message(String(decoding: buffer.data, as: UTF8.self)))
    }
}
#endif
