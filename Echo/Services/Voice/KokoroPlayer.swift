import Accelerate
import AVFoundation
import Foundation
import Observation
import os

/// Streams speech from a Kokoro (OpenAI-compatible) TTS server on the tailnet and plays it as
/// the bytes arrive. One request per sentence, a couple fetched ahead, played strictly in order.
/// Wire format: `response_format: pcm` = 24 kHz, 16-bit signed little-endian, mono.
@Observable
final class KokoroPlayer {
    nonisolated static let sampleRate: Double = 24_000

    var onFirstAudio: (() -> Void)?
    var onDrained: (() -> Void)?
    /// Called when a sentence couldn't be fetched, with the text, so a fallback voice can say it.
    /// Playback waits for it to return, so the fallback never talks over the next sentence.
    var onFailure: ((String) async -> Void)?

    nonisolated private static let log = Logger(subsystem: "com.goosehouse.echo", category: "kokoro")
    private var log: Logger { Self.log }
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = KokoroPlayer.makeFormat()

    private var queue: [Sentence] = []
    /// The sentence being played, once it has left `queue`; its fetch is cancelled with the rest.
    private var current: Sentence?
    private var playbackTask: Task<Void, Never>?
    /// Playback parked on an empty queue; `enqueue`, `finish` and `stop` wake it.
    private var wake: CheckedContinuation<Void, Never>?
    private var warmTask: Task<Void, Never>?
    private var pendingBuffers = 0
    private var announcedFirst = false
    private var finished = false
    /// Held by the Pause button: buffers still arriving are scheduled but must not restart play.
    private var paused = false
    private var generation = 0
    /// When a request last completed; a fresh connection needs no warm-up probe.
    private var lastRequestAt: Date?
    /// Sentences fetched ahead of the one playing. More only compete with it for the server's
    /// GPU, which lengthens the wait for the sentence that is actually due.
    private static let lookahead = 2

    private final class Sentence {
        let text: String
        let baseURL: URL
        let voice: String
        let speed: Double
        let chunks: AsyncThrowingStream<AVAudioPCMBuffer, Error>
        let continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation
        var fetch: Task<Void, Never>?

        init(text: String, baseURL: URL, voice: String, speed: Double) {
            self.text = text; self.baseURL = baseURL; self.voice = voice; self.speed = speed
            (chunks, continuation) = AsyncThrowingStream.makeStream()
        }
    }

    /// How loud the reply is right now, 0…1, for voice mode's waveform.
    private let meter = OutputMeter()
    var meterLevel: Float { meter.level }

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        meter.install(on: engine.mainMixerNode)
    }

    // Standard float mono at 24 kHz always exists; the fallback is only to keep the initializer total.
    nonisolated private static func makeFormat() -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    }

    // MARK: - Control

    func begin(baseURL: URL? = nil) {
        stop()
        finished = false
        announcedFirst = false
        generation += 1
        // Open the TCP connection now, while the model is still producing its first tokens, so
        // the first sentence doesn't pay DNS + handshake (~0.5 s on the tailnet). A connection
        // used in the last half minute is still pooled; no need to touch it.
        if let baseURL, Date().timeIntervalSince(lastRequestAt ?? .distantPast) > 30 {
            warmTask?.cancel()
            warmTask = Task.detached(priority: .userInitiated) {
                var probe = URLRequest(url: baseURL.appending(path: "v1/audio/voices"))
                probe.timeoutInterval = 5
                _ = try? await StreamingHTTP.session.data(for: probe)
            }
        }
        // Warm the engine now so the first chunk doesn't pay for a cold start. It stays running
        // between replies; `release()` is what stops it.
        startEngine(reason: "warmup")
    }

    func enqueue(_ text: String, baseURL: URL, voice: String, speed: Double = 1.0) {
        queue.append(Sentence(text: text, baseURL: baseURL, voice: voice, speed: speed))
        fetchAhead()
        if playbackTask == nil { startPlayback(generation: generation) } else { wakePlayback() }
    }

    /// No more sentences are coming; `onDrained` fires after the last one plays.
    func finish() {
        finished = true
        if queue.isEmpty, playbackTask == nil, pendingBuffers == 0 { onDrained?() }
        wakePlayback()
    }

    /// Holds playback; queued and still-arriving sentences wait behind it.
    func pause() { paused = true; player.pause() }
    func resume() { paused = false; player.play() }

    func stop() {
        meter.reset()
        warmTask?.cancel(); warmTask = nil
        generation += 1
        for sentence in queue { sentence.fetch?.cancel() }
        current?.fetch?.cancel()
        current = nil
        queue = []
        playbackTask?.cancel()
        playbackTask = nil
        wakePlayback()
        pendingBuffers = 0
        paused = false
        player.stop()
    }

    /// `stop()` plus the engine, so the audio session can deactivate.
    func release() {
        stop()
        if engine.isRunning { engine.stop() }
    }

    private func wakePlayback() {
        wake?.resume()
        wake = nil
    }

    private func startEngine(reason: String) {
        guard !engine.isRunning else { return }
        let t = Date()
        do { try engine.start() } catch { log.error("engine \(reason) failed: \(error.localizedDescription)"); return }
        log.info("engine \(reason) \(Date().timeIntervalSince(t), format: .fixed(precision: 3))s")
    }

    // MARK: - Fetch

    /// Starts fetches for the next sentences due, up to the lookahead.
    private func fetchAhead() {
        for sentence in queue.prefix(Self.lookahead) { startFetch(sentence) }
    }

    private func startFetch(_ sentence: Sentence) {
        guard sentence.fetch == nil else { return }
        let text = sentence.text, baseURL = sentence.baseURL, voice = sentence.voice, speed = sentence.speed
        let continuation = sentence.continuation
        sentence.fetch = Task { [weak self] in
            // The bytes are decoded off the main actor; only the bookkeeping hops back.
            if await Self.fetch(text, baseURL: baseURL, voice: voice, speed: speed, into: continuation) {
                self?.lastRequestAt = .now
            }
        }
    }

    /// Streams one sentence's PCM into `chunks`, ~100 ms per buffer. Returns whether it completed.
    nonisolated private static func fetch(_ text: String, baseURL: URL, voice: String, speed: Double,
                                          into chunks: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation) async -> Bool {
        struct Body: Encodable {
            var model = "kokoro"; var input: String; var voice: String
            var speed: Double = 1.0
            var response_format = "pcm"; var stream = true
        }
        let format = makeFormat()
        do {
            let request = try StreamingHTTP.makeRequest(
                url: baseURL.appending(path: "v1/audio/speech"), apiKey: nil,
                body: Body(input: text, voice: voice, speed: speed))
            let sentAt = Date()
            let (http, data) = try await ChunkedResponse.start(request, session: StreamingHTTP.session)
            log.info("kokoro headers after \(Date().timeIntervalSince(sentAt), format: .fixed(precision: 3))s")
            var firstChunkLogged = false
            guard (200 ..< 300).contains(http.statusCode) else {
                throw TransportError.http(status: http.statusCode, body: "")
            }
            var pending: [UInt8] = []
            pending.reserveCapacity(9600)
            var checkedHeader = false
            for try await chunk in data {
                pending.append(contentsOf: chunk)
                if !checkedHeader, pending.count >= 44 {
                    checkedHeader = true
                    // Some servers answer "pcm" with a WAV container; decoding its header as
                    // samples is the click at the start of every sentence.
                    if let rate = stripWavHeader(&pending), rate != sampleRate {
                        log.warning("kokoro stream is \(rate) Hz, player expects \(sampleRate) Hz; pitch will be off")
                    }
                }
                // ~100 ms of audio per buffer keeps startup snappy without a callback storm.
                if let buffer = drainFrames(&pending, minimum: 4800, format: format) {
                    if !firstChunkLogged {
                        firstChunkLogged = true
                        log.info("kokoro first chunk after \(Date().timeIntervalSince(sentAt), format: .fixed(precision: 3))s")
                    }
                    chunks.yield(buffer)
                }
                if Task.isCancelled { chunks.finish(); return false }
            }
            if let buffer = drainFrames(&pending, minimum: 2, format: format) { chunks.yield(buffer) }
            chunks.finish()
            return true
        } catch is CancellationError {
            chunks.finish()
        } catch {
            log.error("kokoro fetch failed: \(error.localizedDescription)")
            chunks.finish(throwing: error)
        }
        return false
    }

    /// If `bytes` starts with a RIFF/WAVE header, removes it (through the `data` chunk header)
    /// and returns the declared sample rate. Returns nil for a bare PCM stream.
    nonisolated static func stripWavHeader(_ bytes: inout [UInt8]) -> Double? {
        guard bytes.count >= 44, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46], bytes[8..<12] == [0x57, 0x41, 0x56, 0x45] else { return nil }
        func u32(_ i: Int) -> UInt32 { UInt32(bytes[i]) | UInt32(bytes[i+1]) << 8 | UInt32(bytes[i+2]) << 16 | UInt32(bytes[i+3]) << 24 }
        var rate: Double?
        var i = 12
        while i + 8 <= bytes.count {
            let id = Array(bytes[i..<i+4]), size = Int(u32(i + 4))
            if id == [0x66, 0x6D, 0x74, 0x20], i + 16 <= bytes.count { rate = Double(u32(i + 12)) }   // "fmt "
            if id == [0x64, 0x61, 0x74, 0x61] { bytes.removeFirst(i + 8); return rate ?? 0 }         // "data"
            i += 8 + size + (size & 1)
        }
        return nil
    }

    /// Once `pending` holds at least `minimum` bytes, converts its whole 16-bit frames and leaves
    /// a split sample's first byte for the next chunk. Chunks arrive at arbitrary byte counts;
    /// flushing an odd count would shift every later sample by a byte and turn speech into static.
    nonisolated static func drainFrames(_ pending: inout [UInt8], minimum: Int, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard pending.count >= max(minimum, 2) else { return nil }
        let whole = pending.count & ~1
        guard let buffer = floatBuffer(from: pending, format: format) else { return nil }   // reads count / 2 frames
        pending.removeFirst(whole)
        return buffer
    }

    nonisolated private static func floatBuffer(from bytes: [UInt8], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = bytes.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let out = channels[0]
        // Little-endian Int16 → Float, then scaled; the array's storage is aligned for Int16.
        bytes.withUnsafeBufferPointer { raw in
            raw.baseAddress!.withMemoryRebound(to: Int16.self, capacity: frames) { samples in
                vDSP_vflt16(samples, 1, out, 1, vDSP_Length(frames))
            }
        }
        var scale: Float = 1 / 32768
        vDSP_vsmul(out, 1, &scale, out, 1, vDSP_Length(frames))
        return buffer
    }

    // MARK: - Playback

    private func startPlayback(generation gen: Int) {
        playbackTask = Task { [weak self] in
            guard let self else { return }
            while gen == generation, !Task.isCancelled {
                guard !queue.isEmpty else {
                    if finished { break }
                    await withCheckedContinuation { wake = $0 }
                    continue
                }
                let sentence = queue.removeFirst()
                current = sentence
                startFetch(sentence)
                fetchAhead()
                do {
                    for try await buffer in sentence.chunks {
                        guard gen == generation else { return }
                        schedule(buffer)
                    }
                } catch {
                    guard gen == generation else { return }
                    await onFailure?(sentence.text)
                }
                guard gen == generation else { return }
                current = nil
            }
            guard gen == generation else { return }
            playbackTask = nil
            if pendingBuffers == 0 { onDrained?() }
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        startEngine(reason: "cold start")
        guard engine.isRunning else { return }
        pendingBuffers += 1
        let gen = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferPlayed(generation: gen) }
        }
        if !paused, !player.isPlaying { player.play() }
        if !announcedFirst {
            announcedFirst = true
            onFirstAudio?()
        }
    }

    private func bufferPlayed(generation gen: Int) {
        guard gen == generation else { return }
        pendingBuffers = max(pendingBuffers - 1, 0)
        if pendingBuffers == 0, playbackTask == nil, finished { onDrained?() }
    }
}

/// Loudness of what the engine is playing, measured on the render thread: attack at once,
/// release to about half in 60 ms, the same scale as the mic meter (-50…0 dB → 0…1).
/// Installed from here, not from main-actor code: a closure formed there inherits main-actor
/// isolation, and the render thread would trip the runtime check.
nonisolated final class OutputMeter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Float(0))
    var level: Float { lock.withLock { $0 } }

    func install(on node: AVAudioNode) {
        node.installTap(onBus: 0, bufferSize: 512, format: nil) { [self] buffer, _ in
            measure(buffer)
        }
    }

    func reset() { lock.withLock { $0 = 0 } }

    private func measure(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, vDSP_Length(buffer.frameLength))
        let normalized = min(max((20 * log10(max(rms, 1e-6)) + 50) / 50, 0), 1)
        let release = Float(pow(0.5, Double(buffer.frameLength) / (buffer.format.sampleRate * 0.06)))
        lock.withLock { $0 = max(normalized, $0 * release) }
    }
}
