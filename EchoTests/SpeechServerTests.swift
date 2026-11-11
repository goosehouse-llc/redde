import Foundation
import Testing
@testable import Echo

/// Speech servers other than Kokoro (`SpeechServer`, `SpeechPCM`; asked 2026-11-10): the model
/// they're asked for, voices listed in any shape or not at all, and WAV at their own rate.
struct SpeechServerTests {
    /// A WAV file of `samples` (per channel, interleaved) at `rate`.
    static func wav(_ samples: [Int16], rate: Int, channels: Int = 1) -> Data {
        var data = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + samples.count * 2); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(channels); u32(rate); u32(rate * channels * 2); u16(channels * 2); u16(16)
        data.append(contentsOf: Array("LIST".utf8)); u32(4); data.append(contentsOf: Array("INFO".utf8))   // a chunk to step over
        data.append(contentsOf: Array("data".utf8)); u32(samples.count * 2)
        for sample in samples { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    static func samples(_ bytes: [UInt8]) -> [Int16] {
        stride(from: 0, to: bytes.count - 1, by: 2).map { Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8) }
    }

    /// Fed in pieces of `size` bytes, as a network would.
    static func read(_ data: Data, rate: Double = 24_000, size: Int) -> (out: [Int16], pcm: SpeechPCM) {
        var pcm = SpeechPCM(rate: rate)
        var out: [UInt8] = []
        var at = 0
        while at < data.count {
            out += pcm.feed(data[at ..< min(at + size, data.count)])
            at += size
        }
        out += pcm.finish()
        return (samples(out), pcm)
    }

    @Test func barePCMPassesThroughWhole() {
        let sound: [Int16] = (0 ..< 999).map { Int16($0 * 7 % 3000 - 1500) }
        let bytes = Data(sound.flatMap { withUnsafeBytes(of: $0.littleEndian, Array.init) })
        for size in [1, 3, 7, 1000] {
            #expect(Self.read(bytes, size: size).out == sound, "pieces of \(size)")
        }
    }

    @Test func aWavHeaderIsDroppedAndItsRateKept() {
        let sound: [Int16] = (0 ..< 480).map { Int16($0) }
        let (out, pcm) = Self.read(Self.wav(sound, rate: 24_000), size: 5)
        #expect(out == sound, "the header isn't sound")
        #expect(pcm.sourceRate == 24_000 && pcm.channels == 1)
    }

    /// Piper's 22,050 Hz, 16 kHz, 48 kHz: as long at 24 kHz as it was, the same shape.
    @Test func anotherRateIsConverted() {
        for rate in [22_050, 16_000, 48_000] {
            let seconds = 0.5
            let ramp: [Int16] = (0 ..< Int(Double(rate) * seconds)).map { Int16($0 * 20_000 / Int(Double(rate) * seconds)) }
            let (out, _) = Self.read(Self.wav(ramp, rate: rate), size: 333)
            #expect(abs(out.count - Int(24_000 * seconds)) <= 2, "\(rate) Hz: \(out.count) samples")
            #expect(zip(out, out.dropFirst()).allSatisfy { $0 <= $1 }, "\(rate) Hz: a rising ramp still rises")
            #expect(abs(Int(out.last ?? 0) - Int(ramp.last ?? 0)) < 30, "\(rate) Hz: it ends where it ended")
        }
    }

    @Test func stereoIsMixedDown() {
        let interleaved: [Int16] = [100, 300, -200, -400, 1000, 0]
        #expect(Self.read(Self.wav(interleaved, rate: 24_000, channels: 2), size: 4).out == [200, -300, 500])
    }

    @Test func voicesAreReadInAnyShape() {
        func ids(_ json: String) -> [String]? { SpeechServer.voiceIDs(in: Data(json.utf8)) }
        #expect(ids(#"{"voices": ["bf_emma", "af_heart"]}"#) == ["af_heart", "bf_emma"])
        #expect(ids(#"{"voices": [{"id": "af_heart"}, {"id": "am_adam"}]}"#) == ["af_heart", "am_adam"])
        #expect(ids(#"[{"name": "alloy"}, {"voice_id": "nova"}]"#) == ["alloy", "nova"])
        #expect(ids(#"{"data": ["en_US-amy-medium"]}"#) == ["en_US-amy-medium"])
        #expect(ids(#"{"voices": []}"#) == [])
        #expect(ids(#"{"detail": "Not Found"}"#) == nil && ids("<html>") == nil && ids(#"[{"x": 1}]"#) == nil)
        #expect(KokoroPlayer.isUnlisted(TransportError.http(status: 404, body: "")) && KokoroPlayer.isUnlisted(URLError(.cannotParseResponse)))
        #expect(!KokoroPlayer.isUnlisted(URLError(.cannotConnectToHost)) && !KokoroPlayer.isUnlisted(TransportError.http(status: 500, body: "")))
    }

    @Test func otherBotsShowOtherServersVoicesByTheirNames() {
        #expect(BotVoicePicker.kokoroName("alloy") == "alloy" && BotVoicePicker.kokoroName("en_US-amy-medium") == "en_US-amy-medium")
        #expect(BotVoicePicker.kokoroName("af_heart").hasPrefix("Heart"))
    }

    /// The model typed in Settings is what the server is asked for; nothing typed, "kokoro".
    @MainActor @Test func theServerIsAskedForItsModel() async throws {
        let settings = Settings(defaults: UserDefaults(suiteName: "speech-\(UUID().uuidString)")!)
        #expect(settings.speechModelOrDefault == "kokoro")
        settings.speechModel = "  tts-1 "
        #expect(settings.speechModelOrDefault == "tts-1")
        settings.replyVoice = .kokoro
        settings.kokoroURL = "http://speech.invalid"
        settings.kokoroVoice = "alloy"
        guard case let .server(_, model, voice, _) = LocalSpeech.reading(for: nil, settings: settings) else { Issue.record("not the server"); return }
        #expect(model == "tts-1" && voice == "alloy")

        let ramp: [Int16] = (0 ..< 2_205).map { Int16($0) }
        let server = try await DroppingSpeechServer.start(drops: 0, sound: Self.wav(ramp, rate: 22_050))
        defer { server.stop() }
        var sound = Data()
        for try await piece in LocalSpeech.server(server.baseURL, model: "piper", voice: "en_US-amy-medium", speed: 1).pcm("Hello.") { sound.append(piece) }
        #expect(abs(sound.count / 2 - 2_400) <= 2, "a tenth of a second at the call's rate: \(sound.count / 2)")
        let sent = String(decoding: try JSONEncoder().encode(SpeechServer.body("Hello.", model: "piper", voice: "en_US-amy-medium", speed: 1)), as: UTF8.self)
        #expect(sent.contains(#""model":"piper""#) && sent.contains(#""voice":"en_US-amy-medium""#) && sent.contains(#""response_format":"pcm""#), "\(sent)")
    }
}
