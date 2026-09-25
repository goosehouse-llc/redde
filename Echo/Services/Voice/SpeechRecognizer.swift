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
    enum State: Equatable { case idle, preparing, listening, finalizing }
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
            case .localeUnsupported: "On-device transcription isn't available for this language."
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

    /// Ensures the on-device model for the current locale is installed. Safe to call every launch.
    /// The module must belong to an analyzer before AssetInventory will talk about it
    /// ("not subscribed to transcription.en" otherwise).
    static func prepareAssets() async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw Failure.localeUnsupported
        }
        let probe = try await Self.makeTranscriber()
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
    static func makeTranscriber() async throws -> SpeechTranscriber {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw Failure.localeUnsupported
        }
        // Allocate the locale for this app. Without it the framework warns
        // "Cannot use modules with unallocated locales" and AssetInventory refuses downloads.
        if await !AssetInventory.reservedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            _ = try await AssetInventory.reserve(locale: locale)
        }
        return SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    /// Transcribes an audio file through the exact pipeline the mic uses (converter + analyzer).
    /// Used by tests; the test machine has no microphone, so this is how STT gets verified offline.
    static func transcribe(fileURL: URL) async throws -> String {
        let transcriber = try await makeTranscriber()
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure.assetsUnavailable
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: fileURL)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: analyzerFormat) else {
            throw Failure.audioFormat
        }
        let (inputSequence, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        guard let tap = TapProcessor(converter: converter, targetFormat: analyzerFormat, continuation: continuation) else {
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
        // A cancel() may still be finalizing; wait for it rather than silently doing nothing.
        if let pending = finalizeTask { _ = await pending.value }
        // A cancelled start() may still be inside analyzer.start with its tap on the bus: wait for
        // it to unwind, or this one installs a second tap (an ObjC exception) or gets torn down
        // by the old one's cleanup.
        if let pending = setupTask { _ = try? await pending.value }
        let task = Task { [self] in try await begin(onEnd: onEnd) }
        setupTask = task
        defer { if setupTask == task { setupTask = nil } }
        try await task.value
    }

    private var setupTask: Task<Void, any Error>?

    private func begin(onEnd: @escaping (String) -> Void) async throws {
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
        let micFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: micFormat, to: analyzerFormat),
              let tap = TapProcessor(converter: converter, targetFormat: analyzerFormat, continuation: continuation) else {
            abandon(); throw Failure.audioFormat
        }
        self.tap = tap
        tap.install(on: input, format: micFormat)

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
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
        startedAt = .now
        state = .listening
        log.info("listening (mic \(micFormat.sampleRate)Hz → analyzer \(analyzerFormat.sampleRate)Hz \(analyzerFormat.commonFormat == .pcmFormatInt16 ? "int16" : "float"))")

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
                    log.info("endpoint: stable \(stableFor, format: .fixed(precision: 2))s quiet \(quietFor, format: .fixed(precision: 2))s floor \(noiseFloor, format: .fixed(precision: 2))")
                    let text = await finish()
                    onEnd(text)
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
        case .listening: _ = startFinalize()
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
        guard state == .listening || finalizeTask != nil else {
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

    init?(converter: AVAudioConverter, targetFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.converter = converter
        self.targetFormat = targetFormat
        self.continuation = continuation
        let ratio = targetFormat.sampleRate / converter.inputFormat.sampleRate
        let perCallback = AVAudioFrameCount(Double(Self.maxInputFrames) * ratio) + 32
        yieldFrames = AVAudioFrameCount(targetFormat.sampleRate / 10)
        guard let scratch = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: perCallback),
              let staged = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: yieldFrames + perCallback) else { return nil }
        self.scratch = scratch
        self.staged = staged
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
            append(out)
            if staged.frameLength >= yieldFrames { handOff() }
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
