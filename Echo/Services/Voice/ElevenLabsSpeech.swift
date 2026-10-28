import AVFoundation
import Foundation
import os

/// Replies read out by ElevenLabs on the person's own key (Settings → Voice → ElevenLabs; asked
/// 2026-10-26, so bots in a group chat each have an ElevenLabs voice without a call). A sentence
/// at a time, as Kokoro's are, streamed as 24 kHz PCM straight into the reply player
/// (`KokoroPlayer`): its first sound comes while the rest is still being made. The key is the one
/// live calls with ElevenLabs use (`LiveEngine.elevenLabs.keyItem`), never sent anywhere else.
nonisolated enum ElevenLabsSpeech {
    /// Flash: its quickest to first sound, and every language.
    static let model = "eleven_flash_v2_5"
    /// ElevenLabs takes speeds from 0.7 to 1.2 (its own pace is 1).
    static let speeds: ClosedRange<Double> = 0.7...1.2

    private static let log = Logger(subsystem: "com.goosehouse.echo", category: "tts")

    /// What ElevenLabs answered the last time it wouldn't read a sentence, which the on-device
    /// voice then read (Settings → Voice shows it, a call's log too); nil once it reads again.
    static var problem: String? { lastProblem.withLock { $0 } }
    private static let lastProblem = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The key, when one is saved.
    static var key: String? {
        Keychain.read(LiveEngine.elevenLabs.keyItem)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// One sentence's request. `previous`: the sentence before it in the same reply, which
    /// ElevenLabs reads for how this one should follow on, and doesn't say.
    static func request(_ text: String, voice: String, speed: Double, previous: String?, key: String,
                        host: String = ElevenLabsDialect.host) -> URLRequest {
        var parts = URLComponents(string: host)!
        let segment = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        parts.percentEncodedPath = "/v1/text-to-speech/" + (voice.addingPercentEncoding(withAllowedCharacters: segment) ?? voice) + "/stream"
        parts.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/pcm", forHTTPHeaderField: "Accept")
        var body: [String: JSONValue] = ["text": .string(text), "model_id": .string(model)]
        let speed = min(max(speed, speeds.lowerBound), speeds.upperBound)
        if abs(speed - 1) > 0.001 { body["voice_settings"] = .object(["speed": .number(speed)]) }
        if let previous = previous?.nilIfEmpty { body["previous_text"] = .string(String(previous.suffix(500))) }
        request.httpBody = try? JSONEncoder().encode(JSONValue.object(body))
        return request
    }

    /// Streams one sentence's audio into `chunks`, ~100 ms a buffer. Returns whether it completed;
    /// a refusal fails the stream, and the player reads that sentence with the built-in voice.
    /// One sentence's sound as it comes, or why ElevenLabs won't make it.
    @concurrent private static func open(_ text: String, voice: String, speed: Double, previous: String?, key: String,
                                         host: String = ElevenLabsDialect.host) async throws -> AsyncThrowingStream<Data, Error> {
        let (http, data) = try await ChunkedResponse.start(request(text, voice: voice, speed: speed, previous: previous, key: key, host: host),
                                                           session: StreamingHTTP.session)
        guard (200 ..< 300).contains(http.statusCode) else {
            var said = Data()
            for try await chunk in data where said.count < 2_000 { said.append(chunk) }
            let reply = (try? JSONValue.parse(said)) ?? .null
            let message = reply["detail"]?["message"]?.string ?? reply["detail"]?.string ?? String(decoding: said.prefix(200), as: UTF8.self)
            throw TransportError.http(status: http.statusCode, body: message)
        }
        return data
    }

    /// One sentence as it comes, for a live call's own player (`LiveAnswerReader`): mono 16-bit
    /// PCM at 24 kHz, the rate ElevenLabs' calls play at, in pieces of whole samples. Asked for at
    /// once; what comes waits in the stream until it is read.
    static func pcm(_ text: String, voice: String, speed: Double, previous: String?, key: String,
                    host: String = ElevenLabsDialect.host) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { pieces in
            let work = Task {
                do {
                    var pending = Data()
                    var first = true
                    for try await chunk in try await open(text, voice: voice, speed: speed, previous: previous, key: key, host: host) {
                        pending.append(chunk)
                        let whole = pending.count & ~1
                        guard whole >= 4_800 else { continue }
                        if first {
                            first = false
                            lastProblem.withLock { $0 = nil }
                        }
                        pieces.yield(pending.prefix(whole))
                        pending = pending.count > whole ? Data(pending.suffix(from: pending.startIndex + whole)) : Data()
                    }
                    if pending.count >= 2 { pieces.yield(pending.prefix(pending.count & ~1)) }
                    pieces.finish()
                } catch is CancellationError {
                    pieces.finish()
                } catch {
                    log.error("elevenlabs speech failed: \(error.localizedDescription, privacy: .public)")
                    lastProblem.withLock { $0 = error.localizedDescription }
                    pieces.finish(throwing: error)
                }
            }
            pieces.onTermination = { _ in work.cancel() }
        }
    }

    @concurrent static func fetch(_ text: String, voice: String, speed: Double, previous: String?, key: String,
                                  into chunks: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation) async -> Bool {
        let format = KokoroPlayer.makeFormat()
        do {
            let sentAt = Date()
            let data = try await open(text, voice: voice, speed: speed, previous: previous, key: key)
            var pending: [UInt8] = []
            pending.reserveCapacity(9_600)
            var first = true
            for try await chunk in data {
                pending.append(contentsOf: chunk)
                if let buffer = KokoroPlayer.drainFrames(&pending, minimum: 4_800, format: format) {
                    if first {
                        first = false
                        lastProblem.withLock { $0 = nil }
                        log.info("elevenlabs first audio after \(Date().timeIntervalSince(sentAt), format: .fixed(precision: 3))s")
                    }
                    chunks.yield(buffer)
                }
                if Task.isCancelled { chunks.finish(); return false }
            }
            if let buffer = KokoroPlayer.drainFrames(&pending, minimum: 2, format: format) { chunks.yield(buffer) }
            chunks.finish()
            return true
        } catch is CancellationError {
            chunks.finish()
        } catch {
            log.error("elevenlabs speech failed: \(error.localizedDescription, privacy: .public)")
            lastProblem.withLock { $0 = error.localizedDescription }
            chunks.finish(throwing: error)
        }
        return false
    }
}
