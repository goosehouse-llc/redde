import Foundation

/// A speech server that answers OpenAI's `/v1/audio/speech` (asked 2026-11-10: "utiliser mon tts
/// local"): Kokoro-FastAPI first of all, and any other of its kind (openedai-speech, Speaches,
/// LocalAI, Chatterbox, Orpheus…). The address, the `model` it is asked for (Settings → Reading
/// voice; "kokoro" unless typed), and the voice by name. Reading voice, local calls and the watch
/// ask the same way.
nonisolated enum SpeechServer {
    /// What `/v1/audio/speech` is sent: PCM, streamed, at the reader's speed. A server that has
    /// no "pcm" answers with WAV, which `SpeechPCM` reads too.
    struct Body: Encodable {
        var model: String
        var input: String
        var voice: String
        var speed: Double
        var response_format = "pcm"
        var stream = true
    }

    static func body(_ text: String, model: String, voice: String, speed: Double) -> Body {
        Body(model: model, input: text, voice: voice, speed: speed)
    }

    /// The voices a server names at `/v1/audio/voices`, in whichever shape it gives them:
    /// `{"voices": ["af_heart", …]}`, `{"voices": [{"id": …}, …]}`, a bare list, or
    /// entries with `name` or `voice_id`. Nil when it names none it can be read for.
    static func voiceIDs(in data: Data) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let list: [Any]? = (json as? [Any]) ?? ((json as? [String: Any]).flatMap { $0["voices"] ?? $0["data"] } as? [Any])
        guard let list else { return nil }
        let ids = list.compactMap { entry -> String? in
            if let id = entry as? String { return id }
            guard let object = entry as? [String: Any] else { return nil }
            return (object["id"] ?? object["voice_id"] ?? object["name"]) as? String
        }
        return ids.isEmpty && !list.isEmpty ? nil : Array(Set(ids)).sorted()
    }
}

/// A speech server's sound as Redde plays it: 16-bit mono PCM, little-endian, at `rate`. Bare PCM
/// passes through (Kokoro's, at 24 kHz); a WAV file is read for its rate and channels, its header
/// dropped, stereo mixed down and the rate converted (Piper's 22.05 kHz played as 24 kHz was a
/// tenth too high). Fed in pieces as they arrive, whatever their sizes.
nonisolated struct SpeechPCM {
    let rate: Double
    private(set) var sourceRate: Double?
    private(set) var channels = 1
    /// Bytes held until the start is known to be WAV or not, then a split sample's.
    private var held: [UInt8] = []
    private var decided = false
    /// The rate conversion: samples kept for the next piece, and where it reads between them.
    private var samples: [Int16] = []
    private var phase: Double = 0

    init(rate: Double) { self.rate = rate }

    /// The longest a WAV header is looked through for its sound before the bytes are taken as
    /// bare PCM.
    private static let longestHeader = 4_096

    mutating func feed(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        held.append(contentsOf: bytes)
        if !decided {
            guard decide(final: false) else { return [] }
        }
        return convert(final: false)
    }

    /// What is left once the server has finished.
    mutating func finish() -> [UInt8] {
        if !decided { _ = decide(final: true) }
        return convert(final: true)
    }

    /// Whether the start has been read: WAV (its header gone, its rate and channels kept), or not.
    private mutating func decide(final: Bool) -> Bool {
        guard held.count >= 12 || final else { return false }
        guard held.count >= 12, held[0 ..< 4].elementsEqual([0x52, 0x49, 0x46, 0x46]), held[8 ..< 12].elementsEqual([0x57, 0x41, 0x56, 0x45]) else {
            decided = true
            return true
        }
        func u16(_ i: Int) -> Int { Int(held[i]) | Int(held[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        var i = 12
        while i + 8 <= held.count {
            let id = held[i ..< i + 4], size = u32(i + 4)
            if id.elementsEqual([0x66, 0x6D, 0x74, 0x20]), i + 24 <= held.count {          // "fmt "
                channels = max(1, u16(i + 10))
                sourceRate = Double(u32(i + 12))
            }
            if id.elementsEqual([0x64, 0x61, 0x74, 0x61]) {                                 // "data"
                held.removeFirst(i + 8)
                decided = true
                return true
            }
            i += 8 + size + (size & 1)
        }
        guard final || held.count > Self.longestHeader else { return false }
        decided = true   // a header with no sound in reach: the bytes as they are
        return true
    }

    private mutating func convert(final: Bool) -> [UInt8] {
        let frame = 2 * channels
        let whole = held.count / frame * frame
        guard whole > 0 else { return [] }
        var mono = [Int16]()
        mono.reserveCapacity(whole / frame)
        held.withUnsafeBufferPointer { bytes in
            for start in stride(from: 0, to: whole, by: frame) {
                var sum = 0
                for channel in 0 ..< channels {
                    let at = start + channel * 2
                    sum += Int(Int16(bitPattern: UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8))
                }
                mono.append(Int16(sum / channels))
            }
        }
        held.removeFirst(whole)
        let out = resample(mono, final: final)
        var bytes = [UInt8]()
        bytes.reserveCapacity(out.count * 2)
        for sample in out {
            let bits = UInt16(bitPattern: sample)
            bytes.append(UInt8(bits & 0xFF)); bytes.append(UInt8(bits >> 8))
        }
        return bytes
    }

    /// Straight-line between neighbouring samples: plenty for a voice.
    private mutating func resample(_ input: [Int16], final: Bool) -> [Int16] {
        guard let source = sourceRate, source > 0, abs(source - rate) > 1 else { return input }
        samples += input
        let step = source / rate
        var out = [Int16]()
        out.reserveCapacity(Int(Double(input.count) / step) + 1)
        while phase + 1 < Double(samples.count) {
            let at = Int(phase), part = phase - Double(at)
            out.append(Int16((Double(samples[at]) * (1 - part) + Double(samples[at + 1]) * part).rounded()))
            phase += step
        }
        if final, Int(phase) < samples.count { out.append(samples[Int(phase)]) }
        let used = min(Int(phase), max(samples.count - 1, 0))
        samples.removeFirst(used)
        phase -= Double(used)
        return out
    }
}
