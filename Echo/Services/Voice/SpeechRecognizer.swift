import Accelerate
@preconcurrency import AVFoundation
import Foundation
import Observation
import Speech
import os

/// On-device live transcription using iOS 26 SpeechAnalyzer. Nothing here can reach a server:
/// SpeechTranscriber has no cloud path. Endpointing (deciding the user stopped talking) is ours,
/// because the API doesn't provide it: we watch mic level and the volatile transcript.
@Observable
final class SpeechRecognizer {
    /// `holding`: the microphone is open and nothing is transcribed yet (see `startHeld`).
    enum State: Equatable { case idle, preparing, holding, listening, finalizing }
    enum Failure: LocalizedError {
        case permissionDenied
        case localeUnsupported
        case assetsUnavailable
        case audioFormat
        case busy

        var errorDescription: String? {
            switch self {
            case .busy: "The microphone is still shutting down. Try again in a moment."
            case .permissionDenied: "Microphone access was denied. Enable it for Redde in Settings."
            case .localeUnsupported: "On-device transcription isn't available for this language. Pick another under Settings → Voice → Listening language."
            case .assetsUnavailable: "The on-device speech model isn't installed yet."
            case .audioFormat: "Couldn't set up the microphone audio format."
            }
        }
    }

    private(set) var state: State = .idle
    /// Live text: finalized segments plus the current volatile tail.
    private(set) var transcript = ""
    /// 0...1 smoothed input level: endpointing reads it, and the glow around the voice orb.
    private(set) var level: Float = 0
    /// 0...1 fast input level for the waveform bars: jumps up at once, falls quickly, and is
    /// read about 60 times a second. Endpointing never looks at it. Read straight off the tap:
    /// a stored copy written every 16 ms would invalidate the orb's view body on each write, on
    /// top of the waveform's own per-frame timeline.
    var meterLevel: Float { tap?.meterLevel ?? 0 }

    /// Seconds of quiet after speech before a turn ends automatically. Tune on-device.
    var silenceTimeout: TimeInterval = 1.2
    /// How far above the room's noise floor the level must rise to count as speech (0…1 scale).
    var speechMargin: Float = 0.12
    /// Hard cap so a stuck mic never records forever.
    var maxUtterance: TimeInterval = 45

    nonisolated private static let log = Logger(subsystem: "com.goosehouse.echo", category: "stt")
    private var log: Logger { Self.log }
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var endpointTask: Task<Void, Never>?
    /// In-flight teardown; `stop()`, the endpoint and `cancel()` all share one so a second caller
    /// waits for the finalized text instead of getting the pre-finalization transcript.
    private var finalizeTask: Task<String, Never>?
    /// Bumped by `start()` and `cancel()`; a `start()` still in its awaits checks it and bails
    /// out instead of opening the mic after the caller gave up.
    private var generation = 0
    private var finalizedText = ""
    private var volatileText = ""
    private var tap: TapProcessor?

    private var lastVoiceAt: Date?
    private var lastTextChangeAt: Date?
    private var startedAt: Date?

    // MARK: - Permissions & assets

    /// Only the microphone needs consent. SpeechAnalyzer is on-device and does not use the
    /// SFSpeechRecognizer authorization, whose system prompt wrongly says audio goes to Apple.
    static func requestPermissions() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Ensures the on-device model for the listening language is installed. Safe to call every launch.
    /// The module must belong to an analyzer before AssetInventory will talk about it
    /// ("not subscribed to transcription.en" otherwise).
    /// `chosen` is read once by the caller, so a language picked meanwhile can't mix into this one.
    static func prepareAssets(for chosen: Locale = Settings.shared.speechLocale) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: chosen) else {
            throw Failure.localeUnsupported
        }
        let probe = try await Self.makeTranscriber(for: chosen)
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) { return }
        // The module must stay attached to an analyzer while AssetInventory is asked about it;
        // referencing `analyzer` after the awaits keeps it alive through them.
        let analyzer = SpeechAnalyzer(modules: [probe])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            Self.log.info("downloading speech assets for \(locale.identifier)")
            try await request.downloadAndInstall()
            Self.log.info("speech assets installed")
        }
        withExtendedLifetime(analyzer) {}
    }

    func prepareAssets() async throws { try await Self.prepareAssets() }

    // MARK: - Shared setup

    /// Same module configuration the live path uses, so file-based tests exercise the real thing.
    static func makeTranscriber(for chosen: Locale = Settings.shared.speechLocale) async throws -> SpeechTranscriber {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: chosen) else {
            throw Failure.localeUnsupported
        }
        // Allocate the locale for this app. Without it the framework warns
        // "Cannot use modules with unallocated locales" and AssetInventory refuses downloads.
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            // An app may hold only a few: after switching listening languages, let the oldest go,
            // only as many as needed.
            var held = reserved.count
            for old in reserved where held >= AssetInventory.maximumReservedLocales {
                if await AssetInventory.release(reservedLocale: old) { held -= 1 }
                else { log.warning("couldn't release speech locale \(old.identifier)") }
            }
            _ = try await AssetInventory.reserve(locale: locale)
        }
        return SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    /// Tells the analyzer the spoken-prefix words, so "Claude" is heard as Claude rather than
    /// "cloud". Nothing when no prefixes are set up; a context the analyzer can't take is ignored,
    /// so this can never break transcription.
    private static func applySpokenPrefixHints(to analyzer: SpeechAnalyzer) async {
        let rules = Settings.shared.spokenPrefixes
        guard !rules.isEmpty else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = VoiceRouting.contextualStrings(for: rules)
        try? await analyzer.setContext(context)
    }

    /// Transcribes an audio file through the exact pipeline the mic uses (converter + analyzer).
    /// Used by tests; the test machine has no microphone, so this is how STT gets verified offline.
    static func transcribe(fileURL: URL) async throws -> String {
        let transcriber = try await makeTranscriber()
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure.assetsUnavailable
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        await applySpokenPrefixHints(to: analyzer)
        let file = try AVAudioFile(forReading: fileURL)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: analyzerFormat) else {
            throw Failure.audioFormat
        }
        let (inputSequence, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        guard let tap = TapProcessor(converter: converter, targetFormat: analyzerFormat, continuation: continuation, onVoice: {}) else {
            throw Failure.audioFormat
        }

        var finalText = ""
        let collector = Task {
            for try await result in transcriber.results where result.isFinal {
                finalText += String(result.text.characters)
            }
        }
        try await analyzer.start(inputSequence: inputSequence)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            tap.process(buffer)
        }
        tap.flush()
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await collector.value
        return finalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Lifecycle

    /// Starts listening. Returns when audio is flowing; results arrive via `transcript`.
    /// `onEnd` fires once with the final text when the utterance ends (silence, cap, or `stop()`).
    /// Throws `CancellationError` if `cancel()` (or another `start()`) came in during setup.
    func start(onEnd: @escaping (String) -> Void) async throws {
        try await start(held: false, onEnd: onEnd)
    }

    /// Opens the microphone without transcribing: for a reply that can be talked over. Nothing
    /// reaches the recogniser while Redde's own voice is in the air; the last second of audio is
    /// kept instead, and `watchForVoice` says when someone starts talking. `beginTranscribing`
    /// then listens as `start` does, and `onEnd` fires as it does there.
    func startHeld(onEnd: @escaping (String) -> Void) async throws {
        try await start(held: true, onEnd: onEnd)
    }

    private func start(held: Bool, onEnd: @escaping (String) -> Void) async throws {
        // A cancel() may still be finalizing; wait for it rather than silently doing nothing.
        if let pending = finalizeTask { _ = await pending.value }
        // A cancelled start() may still be inside analyzer.start with its tap on the bus: wait for
        // it to unwind, or this one installs a second tap (an ObjC exception) or gets torn down
        // by the old one's cleanup.
        if let pending = setupTask { _ = try? await pending.value }
        let task = Task { [self] in try await begin(held: held, onEnd: onEnd) }
        setupTask = task
        defer { if setupTask == task { setupTask = nil } }
        try await task.value
    }

    private var setupTask: Task<Void, any Error>?
    /// Who to tell when the utterance ends, and when a voice is heard over a reply.
    private var onEnd: ((String) -> Void)?
    private var onVoice: (() -> Void)?

    /// Held → listening. With `withHeldAudio` the recogniser first gets the second of audio from
    /// before this call, so the words that set it off aren't lost; without it (a reply that ended
    /// by itself) it starts from now. `endsOnSilence`: the utterance ends by itself after a pause,
    /// as with `start`. Without it the recogniser only transcribes, for as long as it is left to:
    /// while it is being found out whether a voice over a reply is words, a pause must not end
    /// anything.
    func beginTranscribing(withHeldAudio: Bool, endsOnSilence: Bool) {
        guard state == .holding, let tap else { return }
        tap.watch(nil)
        tap.release(withHeldAudio: withHeldAudio)
        lastVoiceAt = nil
        lastTextChangeAt = nil
        startedAt = .now
        state = .listening
        if endsOnSilence { startEndpointing(tap) }
    }

    /// Transcribing without an end → an utterance like any other, ended by a pause from here on.
    func endOnSilence() {
        guard state == .listening, endpointTask == nil, let tap else { return }
        startedAt = .now
        startEndpointing(tap)
    }

    /// Listening → held again: what set it off wasn't words.
    func holdAgain() {
        guard state == .listening, let tap else { return }
        endpointTask?.cancel()
        endpointTask = nil
        tap.hold()
        state = .holding
        // Whatever it made of that noise belongs to no utterance.
        finalizedText = ""
        volatileText = ""
        transcript = ""
    }

    /// While held: `heard` is called, once, when the level says someone has started talking.
    /// Nil stops watching.
    func watchForVoice(_ detector: BargeInDetector?, heard: (() -> Void)?) {
        onVoice = heard
        tap?.watch(detector)
    }

    /// The tap's word that the level rose, from the audio thread by way of the main actor.
    fileprivate func voiceHeard() {
        guard state == .holding else { return }
        onVoice?()
    }

    private func begin(held: Bool, onEnd: @escaping (String) -> Void) async throws {
        guard state == .idle else { throw Failure.busy }
        state = .preparing
        generation += 1
        let gen = generation
        transcript = ""
        finalizedText = ""
        volatileText = ""
        lastVoiceAt = nil
        lastTextChangeAt = nil

        // Only our own state is reset on failure: after a cancel() the slot may already belong to
        // a newer start().
        func abandon() { if gen == generation { state = .idle } }
        func stillPreparing() throws {
            guard gen == generation, state == .preparing else { throw CancellationError() }
        }

        let transcriber: SpeechTranscriber
        do { transcriber = try await Self.makeTranscriber() } catch { abandon(); throw error }
        try stillPreparing()
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            abandon(); throw Failure.assetsUnavailable
        }
        try stillPreparing()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        await Self.applySpokenPrefixHints(to: analyzer)
        self.transcriber = transcriber
        self.analyzer = analyzer

        let (inputSequence, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputContinuation = continuation

        let input = engine.inputNode
        // Acoustic echo cancellation: without this the app's own spoken reply feeds straight back
        // into the mic. Headphones and AirPods keep the reply out of the mic themselves, and the
        // processing would only dull their microphone, so it's off there. Must be set before reading
        // the format, which changes when it's on.
        let wantsEchoCancellation = !AudioSessionController.shared.onHeadphones
        if input.isVoiceProcessingEnabled != wantsEchoCancellation {
            do { try input.setVoiceProcessingEnabled(wantsEchoCancellation) } catch { log.error("voice processing toggle failed: \(error.localizedDescription)") }
        }
        if input.isVoiceProcessingEnabled {
            // Voice processing ducks all other audio by default, and the reply is other audio (Kokoro's
            // engine, the built-in voice): it played so quietly on the speaker it sounded like the earpiece.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let micFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: micFormat, to: analyzerFormat),
              let tap = TapProcessor(converter: converter, targetFormat: analyzerFormat, continuation: continuation,
                                     onVoice: TapProcessor.report(to: self)) else {
            abandon(); throw Failure.audioFormat
        }
        self.tap = tap
        if held { tap.hold() }   // before any audio flows: nothing of a reply may reach the analyzer
        tap.install(on: input, format: micFormat)

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    // Held again after a false alarm: whatever the recogniser still makes of that
                    // noise belongs to no utterance.
                    if state == .holding {
                        finalizedText = ""; volatileText = ""
                        if !transcript.isEmpty { transcript = "" }
                        continue
                    }
                    if result.isFinal {
                        finalizedText += text
                        volatileText = ""
                    } else {
                        volatileText = text
                    }
                    let combined = (finalizedText + volatileText).trimmingCharacters(in: .whitespaces)
                    if combined != transcript {
                        transcript = combined
                        lastTextChangeAt = .now
                    }
                }
            } catch {
                Self.log.error("transcriber results ended: \(error.localizedDescription)")
            }
        }

        do {
            try await analyzer.start(inputSequence: inputSequence)
            try stillPreparing()
            engine.prepare()
            try engine.start()
        } catch {
            // The tap is on the bus and the results task is running: undo it all, or every later
            // start() is `.busy` until relaunch and the next installTap raises.
            input.removeTap(onBus: 0)
            continuation.finish()
            resultsTask?.cancel(); resultsTask = nil
            inputContinuation = nil
            self.tap = nil; self.analyzer = nil; self.transcriber = nil
            abandon()
            throw error
        }
        self.onEnd = onEnd
        log.info("\(held ? "holding" : "listening") (mic \(micFormat.sampleRate)Hz → analyzer \(analyzerFormat.sampleRate)Hz \(analyzerFormat.commonFormat == .pcmFormatInt16 ? "int16" : "float"))")
        if held {
            state = .holding
        } else {
            startedAt = .now
            state = .listening
            startEndpointing(tap)
        }
    }

    private func startEndpointing(_ tap: TapProcessor) {
        endpointTask = Task { [weak self] in
            // Endpointing: the transcript going stable is the primary signal; the level check only
            // has to confirm the room is no louder than its own noise floor. An absolute threshold
            // doesn't work because room noise on a phone mic varies by 20 dB between places.
            var noiseFloor: Float = 1
            var ticks = 0
            while let self, state == .listening {
                try? await Task.sleep(for: .milliseconds(100))
                let current = tap.smoothedLevel
                if current != level { level = current }
                // Floor snaps down to quieter levels and creeps up slowly so it tracks the room.
                noiseFloor = min(current, noiseFloor + 0.004)
                let now = Date.now
                let speaking = current > noiseFloor + speechMargin && current > 0.15
                if speaking { lastVoiceAt = now }
                let heardSomething = !transcript.isEmpty
                let stableFor = now.timeIntervalSince(lastTextChangeAt ?? now)
                let quietFor = now.timeIntervalSince(lastVoiceAt ?? startedAt ?? now)
                let ranFor = now.timeIntervalSince(startedAt ?? now)
                ticks += 1
                if ticks % 10 == 0 {
                    log.debug("level \(current, format: .fixed(precision: 2)) floor \(noiseFloor, format: .fixed(precision: 2)) speaking \(speaking) stable \(stableFor, format: .fixed(precision: 1))s")
                }
                if (heardSomething && stableFor > silenceTimeout && quietFor > silenceTimeout * 0.6)
                    || ranFor > maxUtterance {
                    log.notice("endpoint: stable \(stableFor, format: .fixed(precision: 2))s quiet \(quietFor, format: .fixed(precision: 2))s floor \(noiseFloor, format: .fixed(precision: 2))")
                    let onEnd = onEnd
                    let text = await finish()
                    onEnd?(text)
                    return
                }
            }
        }
    }

    /// Ends the utterance now (user tapped stop). Returns the final transcript.
    @discardableResult
    func stop() async -> String {
        endpointTask?.cancel()
        endpointTask = nil
        return await finish()
    }

    func cancel() {
        generation += 1
        endpointTask?.cancel()
        endpointTask = nil
        switch state {
        case .preparing: state = .idle   // start() sees the generation change and unwinds
        case .listening, .holding: _ = startFinalize()
        case .idle, .finalizing: break
        }
    }

    private func finish() async -> String {
        if state == .preparing {
            // Stop before the mic opened: unwind the start() instead of letting it finish setup
            // and listen on with the session already idle.
            generation += 1
            state = .idle
            return ""
        }
        guard state == .listening || state == .holding || finalizeTask != nil else {
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return await startFinalize().value
    }

    private func startFinalize() -> Task<String, Never> {
        if let finalizeTask { return finalizeTask }
        let task = Task { [self] in
            let text = await teardownAndFinalize()
            finalizeTask = nil
            return text
        }
        finalizeTask = task
        return task
    }

    private func teardownAndFinalize() async -> String {
        state = .finalizing
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Echo cancellation off while the mic is closed: left on, iOS treats the app as in a call
        // and the reply plays at a level the volume buttons don't fully control (still loud at
        // zero). start() turns it back on for the next utterance.
        if engine.inputNode.isVoiceProcessingEnabled {
            do { try engine.inputNode.setVoiceProcessingEnabled(false) } catch { log.error("voice processing off failed: \(error.localizedDescription)") }
            // Toggling the voice-processing unit puts the output back on the earpiece.
            AudioSessionController.shared.refreshRoute()
        }
        tap?.flush()   // the last few frames still staged for the analyzer
        inputContinuation?.finish()
        inputContinuation = nil
        let finalizeStart = Date.now
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            log.error("finalize failed: \(error.localizedDescription)")
        }
        await resultsTask?.value
        log.info("finalize took \(Date.now.timeIntervalSince(finalizeStart), format: .fixed(precision: 3))s")
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        tap = nil
        onEnd = nil
        onVoice = nil
        level = 0
        state = .idle
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs on the audio render thread: converts mic buffers to the analyzer's format, measures level,
/// and hands buffers to the analyzer stream. Kept off the main actor on purpose.
nonisolated private final class TapProcessor: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let lock = OSAllocatedUnfairLock(initialState: Float(0))
    /// The meter and the room's noise floor it's measured against (render thread only reads/writes).
    private let meterLock = OSAllocatedUnfairLock(initialState: (meter: Float(0), floor: Float(1)))
    /// Nothing is allocated per callback: one callback's converted audio lands in `scratch`, is
    /// appended to `staged`, and every ~100 ms of speech goes to the analyzer in one buffer. The
    /// analyzer keeps what it is handed, so only that hand-off buffer is fresh. `stageLock` is
    /// uncontended except for `flush()`, which runs once the tap is off the bus.
    private let scratch: AVAudioPCMBuffer
    private let staged: AVAudioPCMBuffer
    private let stageLock = OSAllocatedUnfairLock(initialState: ())
    private let yieldFrames: AVAudioFrameCount
    /// While held, the analyzer gets nothing: the newest `heldSeconds` of audio wait in `kept`
    /// (under `stageLock`, like `staged`), for `release` to send first or drop.
    private let kept: AVAudioPCMBuffer
    private var holding = false
    private static let heldSeconds = 1.0
    /// Watches the level for a voice while a reply plays; nil when nobody asked.
    private let watch = OSAllocatedUnfairLock<BargeInDetector?>(initialState: nil)
    private let onVoice: @Sendable () -> Void
    /// Largest hardware buffer a tap may deliver; a longer one falls back to a one-off allocation.
    private static let maxInputFrames: AVAudioFrameCount = 4096

    var smoothedLevel: Float { lock.withLock { $0 } }
    var meterLevel: Float { meterLock.withLock { $0.meter } }

    /// Installed from here, not from the main-actor recognizer: a closure formed in main-actor
    /// code inherits that isolation, and the audio render thread would trip the runtime check.
    func install(on node: AVAudioInputNode, format: AVAudioFormat) {
        // ~10 ms buffers at 48 kHz, so the waveform can follow a voice; the smoothed level below is
        // scaled per frame, so endpointing behaves the same at any buffer size.
        node.installTap(onBus: 0, bufferSize: 512, format: format) { [self] buffer, _ in
            process(buffer)
        }
    }

    init?(converter: AVAudioConverter, targetFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
          onVoice: @escaping @Sendable () -> Void) {
        self.converter = converter
        self.targetFormat = targetFormat
        self.continuation = continuation
        self.onVoice = onVoice
        let ratio = targetFormat.sampleRate / converter.inputFormat.sampleRate
        let perCallback = AVAudioFrameCount(Double(Self.maxInputFrames) * ratio) + 32
        yieldFrames = AVAudioFrameCount(targetFormat.sampleRate / 10)
        guard let scratch = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: perCallback),
              let staged = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: yieldFrames + perCallback),
              let kept = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                          frameCapacity: AVAudioFrameCount(targetFormat.sampleRate * Self.heldSeconds) + perCallback) else { return nil }
        self.scratch = scratch
        self.staged = staged
        self.kept = kept
    }

    /// The closure the audio thread calls when a voice is heard. Made here, off the main actor:
    /// one written in the recogniser would carry its isolation onto the audio thread and trap.
    static func report(to recognizer: SpeechRecognizer) -> @Sendable () -> Void {
        { [weak recognizer] in Task { @MainActor in recognizer?.voiceHeard() } }
    }

    /// Stop feeding the analyzer and keep the newest audio instead.
    func hold() {
        stageLock.withLock {
            if staged.frameLength > 0 { handOff() }
            kept.frameLength = 0
            holding = true
        }
    }

    /// Feed the analyzer again, first what was kept if `withHeldAudio`.
    func release(withHeldAudio: Bool) {
        stageLock.withLock {
            if withHeldAudio, kept.frameLength > 0, let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: kept.frameLength) {
                Self.copy(kept.frameLength, from: kept, to: buffer, at: 0)
                buffer.frameLength = kept.frameLength
                continuation.yield(AnalyzerInput(buffer: buffer))
            }
            kept.frameLength = 0
            holding = false
        }
    }

    /// Start (or with nil, stop) watching the level for a voice.
    func watch(_ detector: BargeInDetector?) {
        watch.withLock { $0 = detector }
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        updateLevel(buffer)
        let out: AVAudioPCMBuffer
        if buffer.frameLength <= Self.maxInputFrames {
            out = scratch
        } else {
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate) + 32
            guard let fresh = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            out = fresh
        }
        out.frameLength = 0
        // The input block is not Sendable (NS_SWIFT_NONSENDABLE) and runs inline: hand the one
        // buffer over exactly once with a plain flag.
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return }
        stageLock.withLock {
            if holding { keep(out); return }
            append(out)
            if staged.frameLength >= yieldFrames { handOff() }
        }
    }

    /// Adds to the held audio, letting the oldest go once there is more than `heldSeconds` of it.
    private func keep(_ out: AVAudioPCMBuffer) {
        let limit = AVAudioFrameCount(targetFormat.sampleRate * Self.heldSeconds)
        let n = min(out.frameLength, kept.frameCapacity)
        if kept.frameLength + n > limit, kept.frameLength > 0 {
            let drop = min(kept.frameLength, kept.frameLength + n - limit)
            Self.shift(kept, by: drop)
            kept.frameLength -= drop
        }
        guard kept.frameLength + n <= kept.frameCapacity else { return }
        Self.copy(n, from: out, to: kept, at: kept.frameLength)
        kept.frameLength += n
    }

    /// Moves a buffer's frames `drop` places towards its start.
    private static func shift(_ buffer: AVAudioPCMBuffer, by drop: AVAudioFrameCount) {
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let remaining = Int(buffer.frameLength - drop) * bytesPerFrame
        for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = channel.mData, remaining > 0 else { continue }
            memmove(data, data + Int(drop) * bytesPerFrame, remaining)
        }
    }

    /// Sends whatever is staged; called once the tap is removed so the analyzer sees the tail.
    func flush() {
        stageLock.withLock { if staged.frameLength > 0 { handOff() } }
    }

    private func append(_ out: AVAudioPCMBuffer) {
        let n = min(out.frameLength, staged.frameCapacity - staged.frameLength)
        guard n > 0 else { return }
        Self.copy(n, from: out, to: staged, at: staged.frameLength)
        staged.frameLength += n
    }

    private func handOff() {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: staged.frameLength) else { staged.frameLength = 0; return }
        Self.copy(staged.frameLength, from: staged, to: buffer, at: 0)
        buffer.frameLength = staged.frameLength
        staged.frameLength = 0
        continuation.yield(AnalyzerInput(buffer: buffer))
    }

    /// A raw byte copy: the analyzer picks its own sample format (16-bit as readily as float),
    /// and `floatChannelData` is nil for anything but float, which would silently drop every frame.
    private static func copy(_ n: AVAudioFrameCount, from src: AVAudioPCMBuffer, to dst: AVAudioPCMBuffer, at dstFrame: AVAudioFrameCount) {
        let bytesPerFrame = Int(src.format.streamDescription.pointee.mBytesPerFrame)
        let s = UnsafeMutableAudioBufferListPointer(src.mutableAudioBufferList)
        let d = UnsafeMutableAudioBufferListPointer(dst.mutableAudioBufferList)
        for i in 0 ..< min(s.count, d.count) {
            guard let sp = s[i].mData, let dp = d[i].mData else { continue }
            memcpy(dp + Int(dstFrame) * bytesPerFrame, sp, Int(n) * bytesPerFrame)
        }
    }

    private func updateLevel(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, vDSP_Length(buffer.frameLength))
        // Map roughly -50dB…0dB onto 0…1 and smooth.
        let db = 20 * log10(max(rms, 1e-6))
        // A reply is playing and someone may talk over it: the detector hears this buffer, and
        // says so once. It is taken out before the call, so a second buffer can't say it again.
        let voice = watch.withLock { detector -> Bool in
            guard var watching = detector else { return false }
            let heard = watching.feed(decibels: db, seconds: Double(buffer.frameLength) / buffer.format.sampleRate)
            detector = heard ? nil : watching
            return heard
        }
        if voice { onVoice() }
        let normalized = min(max((db + 50) / 50, 0), 1)
        // Same smoothing as when buffers were 4096 frames: keep 0.7 of the old value per 4096 frames.
        let keep = pow(0.7, Float(buffer.frameLength) / 4096)
        lock.withLock { $0 = $0 * keep + normalized * (1 - keep) }
        // The meter: how far above the room's noise floor, 0…1. The floor snaps down to quieter
        // readings and creeps up slowly (like endpointing's), so room noise reads as silence
        // wherever you are. Attack at once, release to about half in 40 ms.
        let frames = Float(buffer.frameLength)
        let release = pow(0.5, frames / 1920)
        meterLock.withLock { m in
            m.floor = min(normalized, m.floor + 0.0009 * frames / 1024)
            // 0.10 above the floor before anything counts: breaths, rustles and distant voices stay flat.
            let above = max(0, normalized - m.floor - 0.10) / max(0.2, 1 - m.floor)
            m.meter = max(min(above, 1), m.meter * release)
        }
    }
}
