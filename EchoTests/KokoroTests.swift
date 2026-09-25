import AVFoundation
import Foundation
import Testing
@testable import Echo

struct KokoroTests {
    /// Streams one sentence from the real Kokoro server and checks audio actually plays.
    @Test(.enabled(if: TestEndpoints.kokoro != nil, "no Kokoro endpoint in LocalDefaults.json"))
    func streamsAndPlaysASentence() async throws {
        let base = TestEndpoints.kokoro!
        var probe = URLRequest(url: base.appending(path: "v1/audio/voices"))
        probe.timeoutInterval = 3
        guard let (_, resp) = try? await URLSession.shared.data(for: probe),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            print("SKIP: Kokoro not reachable at \(base)")
            return
        }
        let player = KokoroPlayer()
        let started = Date()
        let result: (first: TimeInterval, drained: TimeInterval) = await withCheckedContinuation { cont in
            var first: TimeInterval = -1
            var done = false
            player.onFirstAudio = { first = Date().timeIntervalSince(started) }
            player.onDrained = {
                guard !done else { return }
                done = true
                cont.resume(returning: (first, Date().timeIntervalSince(started)))
            }
            player.onFailure = { _ in
                guard !done else { return }
                done = true
                cont.resume(returning: (-1, -1))
            }
            player.begin(baseURL: base)
            Task {
                // Simulate the model's TTFT: the first sentence arrives a moment after the reply starts.
                try? await Task.sleep(for: .milliseconds(300))
                player.enqueue("Echo is speaking through Kokoro.", baseURL: base, voice: TestEndpoints.kokoroVoice)
                player.finish()
            }
            Task {
                try? await Task.sleep(for: .seconds(15))
                guard !done else { return }
                done = true
                cont.resume(returning: (first, -2))
            }
        }
        player.stop()
        print(String(format: "Kokoro first audio %.2fs, drained %.2fs", result.first, result.drained))
        #expect(result.first >= 0, "no audio started")
        #expect(result.drained > result.first, "playback never drained")
    }
}

struct KokoroFramingTests {
    /// Chunks split samples at arbitrary bytes; the drained audio must still be the original samples.
    @Test func oddSizedChunksKeepSampleAlignment() throws {
        let samples: [Int16] = (0 ..< 500).map { Int16(truncatingIfNeeded: $0 * 61 - 12_000) }
        var wire: [UInt8] = []
        for s in samples { let u = UInt16(bitPattern: s); wire.append(UInt8(u & 0xFF)); wire.append(UInt8(u >> 8)) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))

        var pending: [UInt8] = []
        var decoded: [Float] = []
        for chunk in stride(from: 0, to: wire.count, by: 7).map({ Array(wire[$0 ..< min($0 + 7, wire.count)]) }) {
            pending.append(contentsOf: chunk)
            if let buffer = KokoroPlayer.drainFrames(&pending, minimum: 50, format: format) {
                decoded += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            }
        }
        if let buffer = KokoroPlayer.drainFrames(&pending, minimum: 2, format: format) {
            decoded += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        #expect(pending.isEmpty)
        #expect(decoded.count == samples.count)
        #expect(decoded == samples.map { Float($0) / 32768 })
    }
}
