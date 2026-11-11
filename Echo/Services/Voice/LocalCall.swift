import AVFoundation
import Foundation
import Speech
import os

// A local call (`LiveEngine.local`), asked 2026-11-10 by a user with a speech server of their own
// ("utiliser mon tts local pour les appels"): a live call with no voice service at all. The
// phone listens (Apple's on-device transcription, as Redde's own voice mode does), decides when
// the person has finished, hands what they said to the agent, and speaks the agent's answer as it
// is written in the bot's reading voice: a speech server of the person's own (Kokoro, or any that
// answers OpenAI's /v1/audio/speech), ElevenLabs, or the device's own voice. Everything else of a
// call is the same as with the cloud engines (`LiveVoice`: the call screen, the call bar, group
// chats, handing over to another bot, hanging up after a quiet), so `LocalCall` stands where a
// `LiveCall` would, and speaks to `LiveVoice` in events of its own (`LocalDialect`).

/// What a local call speaks with: the reading voice of the bot it is with (Settings → Voice, Edit
/// Bot → Voice), at that bot's speed.
nonisolated enum LocalSpeech: Sendable, Equatable {
    /// A speech server of the person's own at this address (Settings → Voice → Kokoro), in one of its voices.
    case server(URL, voice: String, speed: Double)
    case elevenLabs(voice: String, key: String, speed: Double)
    /// The device's own voice: this one, by its identifier, else the language's best.
    case device(voice: String?, language: String, speed: Double)

    /// The rate everything is spoken at: what Kokoro and ElevenLabs give as PCM.
    static let rate: Double = 24_000

    /// `profile`'s reading voice, as a reply in its chat is read. Hermes's own voice is the
    /// Dashboard's to play, not the call's: the device's voice speaks instead, as it does where a
    /// reading voice can't be reached.
    @MainActor static func reading(for profile: String?, settings: Settings) -> LocalSpeech {
        let picked = settings.botVoicesHere
        let speed = BotVoices.speed(for: profile, picked: picked, main: settings.voiceSpeed)
        let names = BotDirectory.shared.bots(for: settings.connectionKey).map(\.name)
        switch settings.readingVoice(for: profile) {
        case .kokoro:
            if let server = settings.kokoroBaseURL {
                let known = KokoroPlayer.knownVoiceIDs.withLock { $0 }
                let voice = BotVoices.kokoro(for: profile, picked: picked, main: settings.kokoroVoice,
                                             available: known.server == server ? known.ids : [], names: names)
                return .server(server, voice: voice ?? settings.kokoroVoice, speed: speed)
            }
        case .elevenLabs:
            if let key = ElevenLabsSpeech.key {
                let voice = BotVoices.elevenLabs(for: profile, picked: picked, main: settings.elevenLabsVoice, available: [], names: names)
                    ?? settings.elevenLabsVoice
                if !voice.isEmpty { return .elevenLabs(voice: voice, key: key, speed: speed) }
            }
        case .hermes, .onDevice:
            break
        }
        let language = settings.speechLanguage.isEmpty ? AVSpeechSynthesisVoice.currentLanguageCode() : settings.speechLanguage
        let installed = AVSpeechSynthesisVoice.speechVoices().map {
            SpokenLanguage.AppleVoice(identifier: $0.identifier, language: $0.language, quality: $0.quality.rawValue,
                                      novelty: $0.voiceTraits.contains(.isNoveltyVoice))
        }
        let base = SpokenLanguage.base(language)
        let main = SpokenLanguage.appleVoice(for: base, preferred: language, among: installed)?.identifier
        let own = BotVoices.onDevice(for: profile, picked: picked, language: base, main: main, installed: installed, names: names)
        return .device(voice: own ?? main, language: language, speed: speed)
    }

    /// One sentence, as mono 16-bit PCM at `rate`, in pieces as it comes.
    func pcm(_ text: String) -> AsyncThrowingStream<Data, Error> {
        switch self {
        case let .server(address, voice, speed): Self.fromServer(text, address: address, voice: voice, speed: speed)
        case let .elevenLabs(voice, key, speed): ElevenLabsSpeech.pcm(text, voice: voice, speed: speed, previous: nil, key: key)
        case let .device(voice, language, speed): Self.fromDevice(text, voice: voice, language: language, speed: speed)
        }
    }

    var isDevice: Bool { if case .device = self { true } else { false } }

    /// The device's voice in place of this one, for a sentence it couldn't say.
    @MainActor var fallback: LocalSpeech {
        let settings = Settings.shared
        let language = settings.speechLanguage.isEmpty ? AVSpeechSynthesisVoice.currentLanguageCode() : settings.speechLanguage
        return switch self {
        case .device: self
        case let .server(_, _, speed), let .elevenLabs(_, _, speed): .device(voice: nil, language: language, speed: speed)
        }
    }

    private static let log = Logger(subsystem: "com.goosehouse.echo", category: "live")

    /// The speech server's `/v1/audio/speech`, as Kokoro answers it (`KokoroPlayer`): PCM, streamed.
    private static func fromServer(_ text: String, address: URL, voice: String, speed: Double) -> AsyncThrowingStream<Data, Error> {
        struct Body: Encodable {
            var model = "kokoro"; var input: String; var voice: String
            var speed: Double
            var response_format = "pcm"; var stream = true
        }
        return AsyncThrowingStream { pieces in
            let work = Task {
                do {
                    let request = try StreamingHTTP.makeRequest(url: address.appending(path: "v1/audio/speech"), apiKey: nil,
                                                                body: Body(input: text, voice: voice, speed: speed))
                    let (http, data) = try await ChunkedResponse.start(request, session: StreamingHTTP.session)
                    guard (200 ..< 300).contains(http.statusCode) else { throw TransportError.http(status: http.statusCode, body: "") }
                    var pending: [UInt8] = []
                    var checked = false
                    for try await chunk in data {
                        pending.append(contentsOf: chunk)
                        if !checked, pending.count >= 44 {
                            checked = true
                            // A server that answers "pcm" with a WAV file: its header isn't sound.
                            if let found = KokoroPlayer.stripWavHeader(&pending), found != rate {
                                log.warning("speech server sends \(found) Hz, the call plays \(rate) Hz")
                            }
                        }
                        let whole = pending.count & ~1
                        guard checked, whole >= 4_800 else { continue }
                        pieces.yield(Data(pending[..<whole]))
                        pending.removeFirst(whole)
                    }
                    if pending.count >= 2 { pieces.yield(Data(pending[..<(pending.count & ~1)])) }
                    pieces.finish()
                } catch is CancellationError {
                    pieces.finish()
                } catch {
                    log.error("speech server: \(error.localizedDescription, privacy: .public)")
                    pieces.finish(throwing: error)
                }
            }
            pieces.onTermination = { _ in work.cancel() }
        }
    }

    /// The device's own voice, written to sound rather than played (`AVSpeechSynthesizer.write`),
    /// and brought to the call's rate. Made here, off the main actor: the synthesizer calls back on
    /// a thread of its own.
    private static func fromDevice(_ text: String, voice: String?, language: String, speed: Double) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { pieces in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: language)
            utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                                 max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(speed)))
            let speaking = DeviceSpeech(pieces)
            speaking.synthesizer.write(utterance, toBufferCallback: DeviceSpeech.callback(speaking))
            pieces.onTermination = { _ in speaking.synthesizer.stopSpeaking(at: .immediate) }
        }
    }
}

/// One sentence of the device's voice on its way to the call: the synthesizer kept until it is
/// done, its sound converted to the call's as it comes.
nonisolated private final class DeviceSpeech: @unchecked Sendable {
    let synthesizer = AVSpeechSynthesizer()
    private let pieces: AsyncThrowingStream<Data, Error>.Continuation
    private let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: LocalSpeech.rate, channels: 1, interleaved: true)!
    /// Touched only by the synthesizer's callbacks, which come one at a time.
    private var converter: AVAudioConverter?

    init(_ pieces: AsyncThrowingStream<Data, Error>.Continuation) { self.pieces = pieces }

    static func callback(_ speech: DeviceSpeech) -> AVSpeechSynthesizer.BufferCallback {
        { buffer in speech.take(buffer) }
    }

    private func take(_ buffer: AVAudioBuffer) {
        guard let buffer = buffer as? AVAudioPCMBuffer, buffer.frameLength > 0 else {
            pieces.finish()   // an empty buffer: the end
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: wire) }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * wire.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
        pieces.yield(Data(bytes: samples[0], count: Int(out.frameLength) * 2))
    }
}

// MARK: - The wire

/// How a local call speaks to `LiveVoice`, as the cloud engines' wires do: events it reads
/// (`read`), and the lines `LiveVoice` hands it to say (`answer`, `update`). Nothing goes to any
/// service: the "connection" is in the app.
nonisolated struct LocalDialect: LiveDialect {
    static let address = URL(string: "redde-local://call")!
    static let inputRate: Double = 16_000

    var engine: LiveEngine { .local }
    var inputRate: Double { Self.inputRate }
    var outputRate: Double { LocalSpeech.rate }
    var outputGain: Float { 1 }
    /// The agent's answer is said a sentence at a time as it is written.
    var streamsAnswers: Bool { true }

    func endpoint(key: String) async throws -> LiveEndpoint { LiveEndpoint(url: Self.address) }
    func opening(_ plan: LivePlan) -> [JSONValue] { [] }
    func afterStart(_ plan: LivePlan, eventID: String) -> [JSONValue] { [] }
    /// Never sent: the microphone goes to the listener on the device (`LocalCall`).
    func audio(_ base64: String) -> String { "" }

    /// Said as it is, unless it is a note for a voice model ("[Not to be read out: …]").
    func answer(_ text: String, to id: String, final: Bool, eventID: String) -> [JSONValue] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("[") else { return [] }
        return [Self.say(text, for: id)]
    }

    /// A long wait: a few words for the person, not the model-facing line `LiveVoice` words.
    func update(_ text: String, to id: String, eventID: String) -> [JSONValue] {
        [Self.say(String(localized: "Still working on it."), for: id)]
    }

    /// The agent's progress, for a voice model to mention: nobody here to mention it.
    func note(_ text: String, to id: String, eventID: String) -> [JSONValue] { [] }
    func mute(_ muted: Bool, eventID: String) -> [JSONValue] { [] }
    func close() -> [JSONValue] { [] }

    func read(_ text: String) -> [LiveEvent] {
        guard let event = try? JSONValue.parse(Data(text.utf8)), let type = event["type"]?.string else { return [] }
        switch type {
        case "started": return [.started]
        case "transcript":
            return [.transcript(event["speaker"]?.string == "voice" ? .voice : .person, event["text"]?.string ?? "", startMs: nil, endMs: nil)]
        case "delegated": return event["id"]?.string.map { [.delegated(id: $0, request: nil)] } ?? []
        case "interrupted": return [.interrupted]
        case "failed": return [.failed(event["message"]?.string ?? "", code: nil)]
        default: return []
        }
    }

    // What the call says, and what it is told to say.
    static func say(_ text: String, for id: String?) -> JSONValue {
        .object(["type": .string("say"), "text": .string(text), "id": id.map(JSONValue.string) ?? .null])
    }
    static let started = encode(.object(["type": .string("started")]))
    static let interrupted = encode(.object(["type": .string("interrupted")]))
    static func heard(_ text: String) -> String {
        encode(.object(["type": .string("transcript"), "speaker": .string("person"), "text": .string(text)]))
    }
    static func delegated(_ id: String) -> String { encode(.object(["type": .string("delegated"), "id": .string(id)])) }
    static func failed(_ message: String) -> String { encode(.object(["type": .string("failed"), "message": .string(message)])) }
}

// MARK: - The call

/// A call held on the device itself (`LiveEngine.local`): the call's audio as the cloud engines'
/// (`LiveCallAudio`: Apple's echo cancelling, the voice's queue, the gate that keeps its echo out
/// of the microphone), its microphone to the on-device transcriber instead of a socket. A turn
/// ends once what is heard has stood still for `settles` (and the person has gone quiet); then
/// it goes to `LiveVoice` as their words and a request for the agent, whose answer comes back a
/// sentence at a time and is spoken in the reading voice (`LocalSpeaking`). The person talking
/// over it stops it.
@MainActor
final class LocalCall: LiveCalling {
    private weak var listener: LiveCallListening?
    private let audio: LiveCallAudio
    private var hearing: LocalHearing?
    private var speech: LocalSpeech?
    private lazy var speaking = LocalSpeaking(audio: audio)
    private var endpointing: Task<Void, Never>?
    private var closed = false
    private var audible = false
    private var turns = 0
    /// The request whose answer is being said, and those the person talked over: what is still to
    /// come of their answers goes unsaid.
    private var saying: String?
    private var talkedOver: Set<String> = []
    /// What has been heard of the person's turn: final, and the guess at what follows.
    private var finalized = ""
    private var volatile = ""
    /// The next final result is the finished form of words already handed over.
    private var skipFinal = false
    private var changedAt: ContinuousClock.Instant?
    private var loudAt: ContinuousClock.Instant?
    private var turnStarted: ContinuousClock.Instant?
    private var ending = false
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "live")

    /// What is heard standing still this long, the person quiet for `quiet`, ends their turn (as
    /// Redde's own voice mode: `SpeechRecognizer.silenceTimeout`); standing still for `stuck` ends
    /// it whatever the room's noise; `longest`, a turn at most.
    static let settles: Duration = .milliseconds(1_200)
    static let quiet: Duration = .milliseconds(700)
    static let stuck: Duration = .milliseconds(2_500)
    static let longest: Duration = .seconds(45)
    /// The microphone's level above which the person is talking.
    private static let talking: Float = 0.03

    init(listener: LiveCallListening) {
        self.listener = listener
        // Talking over: as in the other calls (`LiveCall`), never with it off, and on the
        // phone's speaker only as loud as `BargeInDetector` asks.
        let halfDuplex: LiveCallAudio.HalfDuplex = Settings.shared.talkOver == .off ? .always : .onSpeaker
        audio = LiveCallAudio(inputRate: LocalDialect.inputRate, outputRate: LocalSpeech.rate, halfDuplex: halfDuplex, patient: false,
                              quietWhenPlayed: true, message: { _ in "" })
        audio.onSpeaking = Self.speakingRelay(self)
    }

    var inputLevel: Float { audio.levels().input }
    var outputLevel: Float { audio.levels().output }
    var queuedSeconds: Double { audio.queuedSeconds }

    func open() throws {
        do { try audio.start() } catch { throw LiveFailure(String(localized: "The microphone couldn't start: \(error.localizedDescription)")) }
    }

    func connect(_ connection: LiveConnection) async throws {
        speech = connection.plan.speech
        let hearing = try await LocalHearing.start { [weak self] text, final in self?.heard(text, final: final) }
        guard !closed else {
            hearing.stop()
            throw LiveFailure(String(localized: "The call was closed."))
        }
        self.hearing = hearing
        audio.connect(heard: hearing.feeder.sink())
        listener?.liveCallReceived(LocalDialect.started)
        endpointing = Task { [weak self] in await self?.watchForTurnsEnding() }
        if let greeting = connection.plan.greeting { say(greeting.line, for: nil) }
    }

    /// The call goes on as another bot (or a group chat's member saying its reply): its voice from
    /// now, what was being said dropped.
    func reconnect(_ connection: LiveConnection) async throws {
        speaking.stop()
        audio.flush()
        audio.newVoice()
        speech = connection.plan.speech
        saying = nil
        if let greeting = connection.plan.greeting { say(greeting.line, for: nil) }
    }

    /// What `LiveVoice` hands the call: a line to say (`LocalDialect.say`).
    func send(_ event: String) -> Bool {
        guard !closed else { return false }
        guard let message = try? JSONValue.parse(Data(event.utf8)), message["type"]?.string == "say",
              let text = message["text"]?.string else { return true }
        say(text, for: message["id"]?.string)
        return true
    }

    func setMuted(_ muted: Bool) { audio.setMuted(muted) }
    func setVoiceHeld(_ held: Bool) { audio.setVoiceHeld(held) }
    func playAnswer(_ pcm: Data) { audio.playAnswer(pcm) }

    func close() {
        guard !closed else { return }
        closed = true
        endpointing?.cancel()
        speaking.stop()
        hearing?.stop()
        hearing = nil
        audio.stop()
    }

    // MARK: Speaking

    private func say(_ text: String, for id: String?) {
        guard !closed, let speech else { return }
        if let id, talkedOver.contains(id) { return }
        saying = id
        let spoken = PlainText.spoken(text)
        guard spoken.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        speaking.say(spoken, with: speech)
    }

    /// The voice audible or quiet, from the audio thread: quiet only once nothing more is on its
    /// way, or a sentence slow to come would end the call's turn (and a group chat's next reply
    /// would begin over the rest of this one).
    private func speakingChanged(_ now: Bool) {
        guard !closed else { return }
        audible = now
        if !now, speaking.busy {
            speaking.whenDone { [weak self] in
                guard let self, !closed, !audible else { return }
                listener?.liveCallChanged(.quiet)
            }
            return
        }
        listener?.liveCallChanged(now ? .speaking : .quiet)
    }

    nonisolated private static func speakingRelay(_ call: LocalCall) -> @Sendable (Bool) -> Void {
        { [weak call] speaking in Task { @MainActor in call?.speakingChanged(speaking) } }
    }

    // MARK: Listening

    private func heard(_ text: String, final: Bool) {
        guard !closed else { return }
        if final {
            if skipFinal {
                skipFinal = false
                return
            }
            finalized += text
            volatile = ""
        } else {
            volatile = text
        }
        changedAt = .now
        if turnStarted == nil { turnStarted = .now }
        // The person talking over the voice: it stops, and the rest of that answer goes unsaid.
        if Self.hasWords(finalized + volatile), audible || speaking.busy {
            speaking.stop()
            audio.flush()
            if let saying { talkedOver.insert(saying) }
            listener?.liveCallReceived(LocalDialect.interrupted)
        }
    }

    private func watchForTurnsEnding() async {
        while !Task.isCancelled, !closed {
            try? await Task.sleep(for: .milliseconds(100))
            let now = ContinuousClock.now
            if inputLevel > Self.talking { loudAt = now }
            guard !ending, let changedAt, Self.hasWords(finalized + volatile) else { continue }
            let still = now - changedAt
            let quiet = now - max(loudAt ?? changedAt, changedAt)
            let long = turnStarted.map { now - $0 > Self.longest } ?? false
            if (still > Self.settles && quiet > Self.quiet) || still > Self.stuck || long { await endTurn() }
        }
    }

    /// The person's turn is over: the transcriber finishes what it has, and their words go to
    /// `LiveVoice`, followed by the request for the agent.
    private func endTurn() async {
        ending = true
        defer { ending = false }
        await hearing?.settle()
        // A moment for the finished words to come back.
        for _ in 0 ..< 8 where !volatile.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !closed else { return }
        let text = (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
        skipFinal = !volatile.isEmpty
        finalized = ""
        volatile = ""
        changedAt = nil
        turnStarted = nil
        guard Self.hasWords(text) else { return }
        turns += 1
        saying = nil
        listener?.liveCallReceived(LocalDialect.heard(text))
        listener?.liveCallReceived(LocalDialect.delegated("turn_\(turns)"))
    }

    nonisolated static func hasWords(_ text: String) -> Bool { text.contains { $0.isLetter || $0.isNumber } }
}

// MARK: - Hearing

/// The on-device transcriber a local call listens with: Redde's own (`SpeechRecognizer`'s model,
/// language and spoken-prefix words), fed the call's microphone (`LocalFeeder`) and never stopped
/// between turns; `settle` makes it finish what it has heard so far.
@MainActor
final class LocalHearing {
    let feeder: LocalFeeder
    private let analyzer: SpeechAnalyzer
    private var results: Task<Void, Never>?

    private init(feeder: LocalFeeder, analyzer: SpeechAnalyzer) {
        self.feeder = feeder
        self.analyzer = analyzer
    }

    static func start(_ heard: @escaping @MainActor (String, Bool) -> Void) async throws -> LocalHearing {
        try await SpeechRecognizer.prepareAssets()
        let transcriber = try await SpeechRecognizer.makeTranscriber()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber.module]) else {
            throw SpeechRecognizer.Failure.assetsUnavailable
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber.module])
        await SpeechRecognizer.applySpokenPrefixHints(to: analyzer)
        let (input, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        guard let feeder = LocalFeeder(to: format, continuation: continuation) else { throw SpeechRecognizer.Failure.audioFormat }
        let hearing = LocalHearing(feeder: feeder, analyzer: analyzer)
        hearing.results = Task {
            do {
                try await transcriber.results { text, final in
                    heard(text, final)
                    return true
                }
            } catch {
                Logger(subsystem: "com.goosehouse.echo", category: "live").error("local call transcriber: \(error.localizedDescription, privacy: .public)")
            }
        }
        try await analyzer.start(inputSequence: input)
        return hearing
    }

    /// What has been heard so far, finished.
    func settle() async { try? await analyzer.finalize(through: nil) }

    func stop() {
        feeder.finish()
        results?.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}

/// The call's microphone (PCM16 at `LocalDialect.inputRate`, from `LiveCallAudio`'s queue) to
/// the transcriber's format.
nonisolated final class LocalFeeder: @unchecked Sendable {
    private let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: LocalDialect.inputRate, channels: 1, interleaved: true)!
    private let target: AVAudioFormat
    private let converter: AVAudioConverter?
    private let continuation: AsyncStream<AnalyzerInput>.Continuation

    init?(to target: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.target = target
        self.continuation = continuation
        if target == wire {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: wire, to: target) else { return nil }
            self.converter = converter
        }
    }

    /// The closure the audio queue calls, made here, off the main actor.
    func sink() -> @Sendable (Data) -> Void { { [self] data in feed(data) } }

    func finish() { continuation.finish() }

    private func feed(_ data: Data) {
        let frames = AVAudioFrameCount(data.count / 2)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: frames), let samples = buffer.int16ChannelData else { return }
        buffer.frameLength = frames
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            samples[0].update(from: base.assumingMemoryBound(to: Int16.self), count: Int(frames))
        }
        guard let converter else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let capacity = AVAudioFrameCount(Double(frames) * target.sampleRate / wire.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: out))
    }
}

// MARK: - Speaking

/// The answer said a sentence at a time into the call's player: each sentence asked of the voice
/// a sentence ahead, played as it comes, kept no more than `ahead` seconds in front of what is
/// heard (the player holds a minute at most). A sentence the voice can't say (the speech server
/// down) is said in the device's voice instead.
@MainActor
final class LocalSpeaking {
    private final class Sentence {
        let text: String
        let speech: LocalSpeech
        var sound: AsyncThrowingStream<Data, Error>?
        init(_ text: String, _ speech: LocalSpeech) { self.text = text; self.speech = speech }
    }

    private let audio: LiveCallAudio
    private var waiting: [Sentence] = []
    private var player: Task<Void, Never>?
    private var generation = 0
    private var done: [() -> Void] = []
    private static let ahead = 8.0
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "live")

    init(audio: LiveCallAudio) { self.audio = audio }

    /// Sentences are waiting or on their way to the player.
    var busy: Bool { player != nil }

    func say(_ text: String, with speech: LocalSpeech) {
        waiting.append(Sentence(text, speech))
        askAhead()
        guard player == nil else { return }
        let generation = generation
        player = Task { [weak self] in await self?.play(generation) }
    }

    /// Everything still to say goes.
    func stop() {
        generation += 1
        player?.cancel()
        player = nil
        waiting.removeAll()
        finished()
    }

    /// Once everything has gone to the player.
    func whenDone(_ body: @escaping () -> Void) {
        if busy { done.append(body) } else { body() }
    }

    private func askAhead() {
        for sentence in waiting.prefix(2) where sentence.sound == nil { sentence.sound = sentence.speech.pcm(sentence.text) }
    }

    private func play(_ generation: Int) async {
        while generation == self.generation, let sentence = waiting.first {
            askAhead()
            var heardAny = false
            do {
                for try await piece in sentence.sound ?? sentence.speech.pcm(sentence.text) {
                    while audio.queuedSeconds > Self.ahead, generation == self.generation {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    guard generation == self.generation else { return }
                    audio.play(piece)
                    heardAny = true
                }
            } catch {
                guard generation == self.generation else { return }
                if !heardAny, !sentence.speech.isDevice {
                    log.error("local call: the reading voice couldn't say a sentence, the device's voice says it: \(error.localizedDescription, privacy: .public)")
                    do {
                        for try await piece in sentence.speech.fallback.pcm(sentence.text) {
                            guard generation == self.generation else { return }
                            audio.play(piece)
                        }
                    } catch {}
                }
            }
            guard generation == self.generation else { return }
            waiting.removeFirst()
        }
        guard generation == self.generation else { return }
        player = nil
        finished()
    }

    private func finished() {
        let done = done
        self.done.removeAll()
        done.forEach { $0() }
    }
}
