import Accelerate
import AVFoundation
import Foundation
import os

/// Speaks replies with the voice the person's Hermes is set up with (`tts:` in its config.yaml:
/// Edge, ElevenLabs, OpenAI, Gemini, a voice on the server…), through the Dashboard (GitHub
/// issue 7). No voice key reaches the phone: the text goes to their own Hermes, and Hermes takes
/// it to its provider.
///
/// One sentence at a time, so `KokoroPlayer` plays it like a Kokoro sentence: fetched ahead,
/// played in order, the built-in voice saying one that fails.
/// - `api/audio/speak-stream`, a WebSocket in every release Redde supports: `{"text", "done":
///   true}` in; `{"type": "start", "sample_rate"}`, 16-bit mono PCM and `{"type": "end"}` out.
/// - Up to 0.21.5 it answers `{"type": "fallback"}` at once for a provider with no streaming API
///   (Edge, the default, and the voices that run on the server). 0.22 speaks those itself a
///   sentence at a time and says fallback only when that made no sound (no ffmpeg on the server
///   to decode Edge's MP3). Either way `POST api/audio/speak` then speaks the sentence whole, as
///   a data URL of MP3 or WAV.
/// The Hermes API server has no speech routes (`audio_api: false`): this needs the Dashboard.
nonisolated enum HermesSpeech {
    private static let log = Logger(subsystem: "com.goosehouse.echo", category: "hermes-voice")

    /// Dashboards whose socket said "fallback" lately, by address: their sentences go straight to
    /// the POST, not through a socket that can only say so again. Forgotten after ten minutes,
    /// in case the voice was changed on the server meanwhile.
    private static let wholeOnly = OSAllocatedUnfairLock(initialState: [String: Date]())
    private static let wholeOnlyFor: TimeInterval = 600
    /// Longest wait for the next frame of a sentence: a voice on a busy server can take a while
    /// to start, but one that says nothing for this long has gone, and the built-in voice had
    /// better say the sentence.
    private static let frameTimeout: Duration = .seconds(15)

    /// A Dashboard with a login to speak through.
    @MainActor static var isAvailable: Bool {
        Settings.shared.serveBaseURL != nil && HermesServeClient.shared.hasCredentials
    }

    /// Streams one sentence's audio into `chunks`, in `format` (the player's), ~100 ms a buffer.
    /// Returns whether it completed; a failure finishes `chunks` with the error.
    static func fetch(_ text: String, client: HermesServeClient, server: URL, format: AVAudioFormat,
                      into chunks: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation) async -> Bool {
        let key = server.absoluteString
        do {
            let lately = wholeOnly.withLock { $0[key].map { Date.now.timeIntervalSince($0) < wholeOnlyFor } ?? false }
            if !lately, try await streamed(text, client: client, format: format, into: chunks) {
                chunks.finish()
                return true
            }
            if !lately {
                log.info("the Dashboard can't stream this voice; sentences go whole")
                wholeOnly.withLock { $0[key] = .now }
            }
            for piece in try await whole(text, client: client, format: format).samples {
                if let buffer = buffer(piece, format: format) { chunks.yield(buffer) }
            }
            chunks.finish()
            return true
        } catch {
            // A sentence no longer wanted ends quietly, however the socket's closing was put.
            if error is CancellationError || Task.isCancelled { chunks.finish(); return false }
            log.error("hermes voice failed: \(error.localizedDescription)")
            chunks.finish(throwing: error)
        }
        return false
    }

    /// One sentence over `api/audio/speak-stream`. False when the Dashboard said "fallback"
    /// before any sound: the sentence is still to be said.
    static func streamed(_ text: String, client: HermesServeClient, format: AVAudioFormat,
                         into chunks: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation) async throws -> Bool {
        let socket = try await client.openSpeechSocket()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        // A sentence no longer wanted (the reply stopped) closes its socket, which tells Hermes
        // to stop too.
        return try await withTaskCancellationHandler {
            let frame = try JSONSerialization.data(withJSONObject: ["text": text, "done": true])
            try await socket.send(.string(String(decoding: frame, as: UTF8.self)))
            var decoder = PCMStream(target: format)
            var heard = false
            func play(_ pieces: [[Float]]) {
                for piece in pieces { if let buffer = buffer(piece, format: format) { chunks.yield(buffer) } }
            }
            while true {
                let message = try await receive(socket)
                try Task.checkCancellation()
                switch message {
                case let .data(bytes):
                    heard = true
                    play(decoder.append(bytes))
                case let .string(json):
                    let said = try? JSONValue.parse(Data(json.utf8))
                    switch said?["type"]?.string {
                    case "start":
                        decoder.rate = said?["sample_rate"]?.number ?? decoder.rate
                    case "end":
                        play(decoder.finish())
                        return true
                    case "fallback":
                        if heard { throw TransportError.malformed("Hermes stopped speaking mid-sentence") }
                        return false
                    default:
                        continue
                    }
                @unknown default:
                    continue
                }
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private static func receive(_ socket: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await socket.receive() }
            group.addTask {
                try await Task.sleep(for: frameTimeout)
                throw TransportError.unreachable("Hermes stopped answering mid-sentence")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// One sentence spoken whole (`POST api/audio/speak`): its samples in `format`, a quarter of
    /// a second at a time, and the provider Hermes says spoke it ("elevenlabs", "edge"…).
    static func whole(_ text: String, client: HermesServeClient, format: AVAudioFormat) async throws -> (samples: [[Float]], provider: String?) {
        let answer = try await client.restJSON("POST", "api/audio/speak", body: .object(["text": .string(text)]), timeout: 60)
        guard let dataURL = answer["data_url"]?.string, let audio = decodeDataURL(dataURL) else {
            throw TransportError.malformed("Hermes sent no audio")
        }
        let samples = try decodeFile(audio.data, mimeType: answer["mime_type"]?.string ?? audio.mimeType, to: format)
        return (samples, answer["provider"]?.string)
    }

    /// How Settings names the provider Hermes says spoke ("elevenlabs" → "ElevenLabs"), and
    /// where the text went when the name alone doesn't say: Edge is online, not on the server.
    static func providerName(_ id: String) -> String {
        switch id.lowercased() {
        case "": "your Hermes"
        case "edge": "Edge, Microsoft's online voice"
        case "elevenlabs": "ElevenLabs"
        case "openai": "OpenAI, or a server like it"
        case "gemini": "Google Gemini"
        case "xai": "xAI"
        case "minimax": "MiniMax"
        case "mistral": "Mistral"
        case "deepinfra": "DeepInfra"
        case "neutts": "NeuTTS, on your server"
        case "kittentts": "KittenTTS, on your server"
        case "piper": "Piper, on your server"
        default: id
        }
    }

    /// `data:audio/mpeg;base64,…` → its bytes and type.
    static func decodeDataURL(_ url: String) -> (data: Data, mimeType: String)? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        guard header.hasSuffix(";base64"), let data = Data(base64Encoded: String(url[url.index(after: comma)...])), !data.isEmpty else { return nil }
        return (data, String(header.dropLast(";base64".count)))
    }

    /// A whole audio file (MP3, WAV, FLAC; Ogg where the system reads it) as samples in
    /// `format`, a quarter of a second a piece, so a route change replays a moment and not the
    /// sentence.
    static func decodeFile(_ data: Data, mimeType: String, to format: AVAudioFormat) throws -> [[Float]] {
        let ext = switch mimeType.lowercased() {
        case "audio/wav", "audio/wave", "audio/x-wav": "wav"
        case "audio/ogg": "ogg"
        case "audio/flac": "flac"
        default: "mp3"
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "hermes-voice-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        guard let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw TransportError.malformed("Hermes's audio is empty")
        }
        try file.read(into: read)
        let all = try samples(of: convert(read, to: format))
        let piece = Int(format.sampleRate / 4)
        return stride(from: 0, to: all.count, by: piece).map { Array(all[$0 ..< min($0 + piece, all.count)]) }
    }

    /// `buffer` in another rate or channel count, in one go.
    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw TransportError.malformed("Hermes's audio can't be played (\(buffer.format))")
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024) else {
            throw TransportError.malformed("Hermes's audio is empty")
        }
        var given = false, error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return out
    }

    /// A mono float buffer's samples.
    static func samples(of buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard let data = buffer.floatChannelData?[0] else { throw TransportError.malformed("Hermes's audio can't be played") }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    /// The player's buffer for `samples`. Made only as it's handed over: a buffer is not
    /// something two places may hold.
    static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let out = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}

/// The speak-stream socket's PCM as the player's samples: 16-bit mono at whatever rate the
/// start frame said (ElevenLabs and OpenAI 24 kHz, the rate an OpenAI-compatible server reports
/// on 0.22), brought to the player's rate. Frames arrive at any byte count; a split sample waits
/// for the next one.
nonisolated struct PCMStream {
    let target: AVAudioFormat
    var rate: Double {
        didSet { if rate != oldValue { converter = nil } }
    }
    private var pending: [UInt8] = []
    private var converter: AVAudioConverter?
    private var checkedHeader = false

    init(target: AVAudioFormat, rate: Double = 24_000) {
        self.target = target
        self.rate = rate
    }

    /// Bytes from the socket; returns what is ready to play (~100 ms at a time).
    mutating func append(_ bytes: Data) -> [[Float]] {
        pending.append(contentsOf: bytes)
        if !checkedHeader, pending.count >= 44 {
            checkedHeader = true
            // An OpenAI-compatible server that answers "pcm" with a WAV file: Hermes passes it on
            // as it came, header and all. Read as samples, the header is a click.
            if let declared = KokoroPlayer.stripWavHeader(&pending), declared > 0 { rate = declared }
        }
        guard checkedHeader, pending.count >= Int(rate / 10) * 2 else { return [] }
        return drain(last: false)
    }

    /// The end of the sentence: whatever is left, and what the rate converter still holds.
    mutating func finish() -> [[Float]] {
        drain(last: true)
    }

    private mutating func drain(last: Bool) -> [[Float]] {
        // Whole 16-bit frames only; a split sample's first byte stays for the next chunk.
        let whole = pending.count & ~1
        var samples = [Float](repeating: 0, count: whole / 2)
        if !samples.isEmpty {
            samples.withUnsafeMutableBufferPointer { out in
                pending.withUnsafeBufferPointer { raw in
                    raw.baseAddress!.withMemoryRebound(to: Int16.self, capacity: out.count) { int16 in
                        vDSP_vflt16(int16, 1, out.baseAddress!, 1, vDSP_Length(out.count))
                    }
                }
                var scale: Float = 1 / 32768
                vDSP_vsmul(out.baseAddress!, 1, &scale, out.baseAddress!, 1, vDSP_Length(out.count))
            }
            pending.removeFirst(whole)
        }
        if rate == target.sampleRate { return samples.isEmpty ? [] : [samples] }
        guard let source = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return [] }
        if converter == nil { converter = AVAudioConverter(from: source, to: target) }
        guard let converter, !samples.isEmpty || last else { return [] }
        let input = HermesSpeech.buffer(samples, format: source)
        let frames = Double(samples.count) * target.sampleRate / rate
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(frames) + 1024) else { return [] }
        var given = false, error: NSError?
        // The converter keeps a few frames for the next call (`noDataNow`) until the end of the
        // sentence lets it give them up (`endOfStream`).
        _ = converter.convert(to: out, error: &error) { _, status in
            if given || input == nil { status.pointee = last ? .endOfStream : .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return input
        }
        let converted = (try? HermesSpeech.samples(of: out)) ?? []
        return converted.isEmpty ? [] : [converted]
    }
}
