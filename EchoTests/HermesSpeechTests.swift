import AVFoundation
import Foundation
import Testing
@testable import Echo

/// Replies read out by the voice the person's Hermes is set up with (GitHub issue 7): the sound
/// as the Dashboard sends it, a whole sentence's file, the setting that picks the voice. Real
/// Hermes is in `HermesLabSpeechTests`.
@MainActor
struct HermesSpeechTests {
    private let player = KokoroPlayer.makeFormat()

    /// A 440 Hz tone at 0.3 of full scale, as Hermes sends PCM: 16-bit little-endian mono.
    private func tone(seconds: Double, rate: Double) -> Data {
        var data = Data()
        for i in 0 ..< Int(seconds * rate) {
            let sample = Int16(0.3 * 32767 * sin(2 * .pi * 440 * Double(i) / rate))
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func wav(_ pcm: Data, rate: UInt32) -> Data {
        var data = Data("RIFF".utf8)
        func le<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        le(UInt32(36 + pcm.count))
        data.append(contentsOf: Data("WAVEfmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(rate); le(rate * 2); le(UInt16(2)); le(UInt16(16))
        data.append(contentsOf: Data("data".utf8))
        le(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    /// The bytes fed in pieces of `size`, as the socket hands them over, then the end.
    private func heard(_ bytes: Data, size: Int, rate: Double? = nil) -> [Float] {
        var stream = PCMStream(target: player)
        if let rate { stream.rate = rate }
        var out: [[Float]] = []
        var start = 0
        while start < bytes.count {
            out += stream.append(bytes.subdata(in: start ..< min(start + size, bytes.count)))
            start += size
        }
        out += stream.finish()
        return out.flatMap(\.self)
    }

    private func peak(_ samples: [Float]) -> Float { samples.map(abs).max() ?? 0 }

    @Test func pcmAtThePlayersRateComesThroughWhole() {
        let bytes = tone(seconds: 1, rate: 24_000)
        // An odd size: every other piece ends halfway through a sample.
        let samples = heard(bytes, size: 4801)
        #expect(samples.count == 24_000, "not a sample lost or doubled")
        #expect(abs(peak(samples) - 0.3) < 0.01, "read as 16-bit samples, not shifted a byte into noise")
        var stream = PCMStream(target: player)
        #expect(stream.append(bytes.prefix(1000)).isEmpty, "a few milliseconds wait for more")
    }

    @Test func anotherRateIsBroughtToThePlayers() {
        // What Hermes 0.22 sends for a voice that writes 22.05 kHz files (Piper, the lab's).
        let samples = heard(tone(seconds: 1, rate: 22_050), size: 3333, rate: 22_050)
        #expect(abs(samples.count - 24_000) < 200, "a second is still a second: \(samples.count) samples")
        #expect(abs(peak(samples) - 0.3) < 0.03, "and as loud: \(peak(samples))")
    }

    @Test func aWavHeaderIsNotPlayedAndSaysTheRate() {
        // An OpenAI-compatible server that answers "pcm" with a WAV file, passed on by Hermes.
        let samples = heard(wav(tone(seconds: 0.5, rate: 16_000), rate: 16_000), size: 2048)
        #expect(abs(samples.count - 12_000) < 200, "16 kHz from the header, brought to 24 kHz: \(samples.count)")
        #expect(abs(peak(samples) - 0.3) < 0.03, "no click from the header read as samples: \(peak(samples))")
    }

    @Test func aWholeSentenceFileIsDecodedInQuarterSeconds() throws {
        let file = wav(tone(seconds: 1, rate: 22_050), rate: 22_050)
        let pieces = try HermesSpeech.decodeFile(file, mimeType: "audio/wav", to: player)
        #expect(pieces.dropLast().allSatisfy { $0.count == 6000 }, "a quarter of a second each, so a route change replays a moment")
        let total = pieces.map(\.count).reduce(0, +)
        #expect(abs(total - 24_000) < 200, "\(total) samples")
        #expect(abs(peak(pieces.flatMap(\.self)) - 0.3) < 0.03)
        #expect(throws: (any Error).self) { try HermesSpeech.decodeFile(Data("not audio".utf8), mimeType: "audio/mpeg", to: player) }
    }

    @Test func dataURLsAreRead() {
        let read = HermesSpeech.decodeDataURL("data:audio/mpeg;base64," + Data("abc".utf8).base64EncodedString())
        #expect(read?.data == Data("abc".utf8))
        #expect(read?.mimeType == "audio/mpeg")
        #expect(HermesSpeech.decodeDataURL("data:audio/mpeg,abc") == nil, "not base64")
        #expect(HermesSpeech.decodeDataURL("data:audio/mpeg;base64,") == nil, "nothing in it")
        #expect(HermesSpeech.decodeDataURL("https://example.com/a.mp3") == nil)
    }

    @Test func buffersCarryTheSamples() throws {
        let buffer = try #require(HermesSpeech.buffer([0.1, -0.2, 0.3], format: player))
        #expect(buffer.frameLength == 3)
        #expect(try HermesSpeech.samples(of: buffer) == [0.1, -0.2, 0.3])
        #expect(HermesSpeech.buffer([], format: player) == nil)
    }

    @Test func providersAreNamedWithWhereTheTextGoes() {
        #expect(HermesSpeech.providerName("elevenlabs") == "ElevenLabs")
        #expect(HermesSpeech.providerName("edge").contains("Microsoft"), "Hermes's default is online, not on the server")
        #expect(HermesSpeech.providerName("piper").contains("your server"))
        #expect(HermesSpeech.providerName("my-voice") == "my-voice", "a voice of the person's own keeps its name")
    }

    @Test func theSpeakRouteIsAskedForTheProfilesVoice() {
        #expect(HermesServeClient.profilePlacement(method: "POST", path: "api/audio/speak") == .query)
    }

    @Test func theVoiceSettingKeepsAnEarlierKokoroSwitch() {
        func defaults(_ set: [String: Any]) -> UserDefaults {
            let defaults = UserDefaults(suiteName: "voice-test-\(UUID().uuidString)")!
            set.forEach { defaults.set($1, forKey: $0) }
            return defaults
        }
        #expect(Settings(defaults: defaults([:])).replyVoice == .onDevice)
        #expect(Settings(defaults: defaults(["useKokoro": true])).replyVoice == .kokoro, "Kokoro was a switch before")
        #expect(Settings(defaults: defaults(["useKokoro": true, "replyVoice": "hermes"])).replyVoice == .hermes)
        let stored = defaults([:])
        Settings(defaults: stored).replyVoice = .hermes
        #expect(Settings(defaults: stored).replyVoice == .hermes)
        #expect(!Settings(defaults: stored).useKokoro)
    }
}

/// Replies read out by an unmodified Hermes's own voice (`scripts/hermes-lab/lab.sh speech`). The
/// lab's voices answer with a 440 Hz tone, 50 ms for each character, so the length and loudness of
/// what the app heard say whether anything was lost or misread. `LAB_SPEAKS` says whether the
/// Dashboard should stream this voice (`stream`) or send the app for whole sentences (`whole`);
/// `LAB_VOICE` the provider it should name. Skips when no such lab is up.
struct HermesLabSpeechTests {
    private static let sentence = "Hello from the lab. This is how Redde hears your Hermes."

    private typealias Chunks = AsyncThrowingStream<AVAudioPCMBuffer, Error>

    /// Everything `run` yields, and what it said.
    private static func heard<T>(_ run: (Chunks.Continuation) async throws -> T) async -> (samples: [Float], result: Result<T, Error>) {
        let (stream, continuation) = Chunks.makeStream()
        let result: Result<T, Error>
        do { result = .success(try await run(continuation)) } catch { result = .failure(error) }
        continuation.finish()
        var samples: [Float] = []
        do {
            for try await buffer in stream { samples += try HermesSpeech.samples(of: buffer) }
        } catch {}
        return (samples, result)
    }

    /// About 50 ms a character of the sentence, as loud as the tone was made.
    private static func judged(_ samples: [Float]) -> (ok: Bool, said: String) {
        let expected = Double(sentence.count) * 0.05 * 24_000, loud = samples.map(abs).max() ?? 0
        let ok = Double(samples.count) > expected * 0.85 && Double(samples.count) < expected * 1.1 && abs(loud - 0.3) < 0.05
        return (ok, String(format: "%.2f s heard (%.2f s sent), peak %.2f", Double(samples.count) / 24_000, expected / 24_000, loud))
    }

    @Test func repliesAreReadOutByHermessOwnVoice() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        func report(_ ok: Bool, _ what: String, _ detail: String = "") { HermesLabApprovalTests.report(ok, what, detail) }
        let environment = ProcessInfo.processInfo.environment
        let speaks = environment["LAB_SPEAKS"] ?? "stream", voice = environment["LAB_VOICE"] ?? "openai"
        let format = KokoroPlayer.makeFormat()

        // The socket alone.
        let socket = await Self.heard { try await HermesSpeech.streamed(Self.sentence, client: client, format: format, into: $0) }
        let streamed = try? socket.result.get()
        let detail = (try? socket.result.get()).map { "streamed: \($0)" } ?? "\(socket.result)"
        if speaks == "stream" {
            let judged = Self.judged(socket.samples)
            report(streamed == true && judged.ok, "the Dashboard streams this voice, and the app hears all of it as it was made",
                   "\(detail); \(judged.said)")
        } else {
            report(streamed == false && socket.samples.isEmpty, "a voice that can't stream: the Dashboard says so before any sound",
                   "\(detail); \(socket.samples.count) samples")
        }

        // What the player asks for: streamed, or whole after a "fallback".
        let server = URL(string: "http://lab-\(UUID().uuidString.prefix(8)).test")!
        let fetched = await Self.heard { await HermesSpeech.fetch(Self.sentence, client: client, server: server, format: format, into: $0) }
        let judgedFetch = Self.judged(fetched.samples)
        report((try? fetched.result.get()) == true && judgedFetch.ok, "a sentence for the player is heard whole (\(speaks))", judgedFetch.said)
        let again = await Self.heard { await HermesSpeech.fetch(Self.sentence, client: client, server: server, format: format, into: $0) }
        report((try? again.result.get()) == true && Self.judged(again.samples).ok, "and the next one too", Self.judged(again.samples).said)

        // Whole, as Settings' test sentence asks, which names the provider.
        do {
            let said = try await HermesSpeech.whole(Self.sentence, client: client, format: format)
            let judged = Self.judged(said.samples.flatMap(\.self))
            report(judged.ok && said.provider == voice, "a sentence spoken whole is heard, and Hermes names its voice (\(voice))",
                   "\(judged.said); provider \(said.provider ?? "none")")
        } catch {
            report(false, "a sentence spoken whole", String(error.localizedDescription.prefix(160)))
        }

        // Stopped mid-sentence (a reply interrupted): the sentence ends at once, quietly. A sentence
        // spoken whole has all arrived by its first sound, so there it only has to end quietly.
        let long = String(repeating: "A longer sentence that goes on for a while. ", count: 10)
        let (stream, continuation) = Chunks.makeStream()
        let started = Date()
        let task = Task { await HermesSpeech.fetch(long, client: client, server: server, format: format, into: continuation) }
        var stoppedCleanly = true, frames = 0
        do {
            for try await buffer in stream {
                if frames == 0 { task.cancel() }
                frames += Int(buffer.frameLength)
            }
        } catch {
            stoppedCleanly = false
        }
        let completed = await task.value
        let took = Date().timeIntervalSince(started)
        report(stoppedCleanly && (speaks == "whole" || !completed) && took < 15,
               speaks == "whole" ? "a sentence stopped after it arrived ends without an error to say aloud"
                   : "a sentence stopped partway ends there, without an error to say aloud",
               String(format: "%.1f s, %d frames, error: %@", took, frames, stoppedCleanly ? "no" : "yes"))
    }
}
