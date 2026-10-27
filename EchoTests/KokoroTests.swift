import AVFoundation
import Foundation
import Network
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

/// A Kokoro that drops the first `drops` connections before it reads them a word, the way a
/// connection goes when Redde has been away in another app, then answers with silence.
nonisolated final class DroppingSpeechServer: @unchecked Sendable {
    let port: UInt16
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    private let listener: NWListener
    private let lock = NSLock()
    private var count = 0
    private static let queue = DispatchQueue(label: "dropping-speech-server")

    /// How many times a sentence has been asked for.
    var connections: Int { lock.withLock { count } }

    private init(listener: NWListener, port: UInt16) { self.listener = listener; self.port = port }

    static func start(drops: Int, seconds: Double = 0.3) async throws -> DroppingSpeechServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let box = Box()
        let pcm = Data(count: Int(KokoroPlayer.sampleRate * seconds) * 2)   // 16-bit silence
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
                guard let server = box.server, server.connected() > drops else { connection.cancel(); return }
                let head = "HTTP/1.1 200 OK\r\nContent-Type: audio/pcm\r\nContent-Length: \(pcm.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + pcm, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, _, _ in connection.cancel() }
                })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { ready in
            let resumed = NSLock()
            nonisolated(unsafe) var done = false
            listener.stateUpdateHandler = { state in
                resumed.lock(); defer { resumed.unlock() }
                guard !done else { return }
                switch state {
                case .ready: done = true; ready.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): done = true; ready.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        let server = DroppingSpeechServer(listener: listener, port: port)
        box.server = server
        return server
    }

    func stop() { listener.cancel() }
    /// Counts this connection in; returns how many there have been.
    private func connected() -> Int { lock.withLock { count += 1; return count } }

    private final class Box: @unchecked Sendable { var server: DroppingSpeechServer? }
}

/// GitHub issue 11: a reply read out by Kokoro (or Hermes) went on in Apple's voice as well, on
/// top of it, after Redde had been away in another app.
struct KokoroFailureTests {
    /// Plays until `onDrained`, or gives up after `limit`. False when it never drained.
    private func playToTheEnd(_ player: KokoroPlayer, limit: Duration = .seconds(10),
                              _ enqueue: @escaping () -> Void) async -> Bool {
        await withCheckedContinuation { done in
            var resumed = false
            player.onDrained = {
                guard !resumed else { return }
                resumed = true
                done.resume(returning: true)
            }
            player.begin()   // no address: no warm-up request to count
            enqueue()
            player.finish()
            Task {
                try? await Task.sleep(for: limit)
                guard !resumed else { return }
                resumed = true
                done.resume(returning: false)
            }
        }
    }

    @Test func aSentenceWhoseConnectionDroppedIsAskedForAgain() async throws {
        let server = try await DroppingSpeechServer.start(drops: 1)
        defer { server.stop() }
        let player = KokoroPlayer()
        var failed: [String] = []
        player.onFailure = { failed.append($0) }
        let drained = await playToTheEnd(player) {
            player.enqueue("Said in Kokoro's voice after all.", baseURL: server.baseURL, voice: "af_heart")
        }
        player.release()
        #expect(drained)
        #expect(server.connections == 2)
        #expect(failed.isEmpty, "the second ask was answered: nothing for another voice to say")
    }

    @Test func theOtherVoiceWaitsForWhatIsStillPlaying() async throws {
        let server = try await DroppingSpeechServer.start(drops: .max)
        defer { server.stop() }
        let player = KokoroPlayer()
        let started = ContinuousClock.now
        var failedAfter: [Duration] = []
        player.onFailure = { _ in failedAfter.append(ContinuousClock.now - started) }
        let drained = await playToTheEnd(player) {
            // A second of the sentence before, already in hand, and then one that can't be had.
            player.enqueue(samples: [[Float](repeating: 0, count: Int(KokoroPlayer.sampleRate))], text: "One second.")
            player.enqueue("Then one that never comes.", baseURL: server.baseURL, voice: "af_heart")
        }
        player.release()
        #expect(drained)
        #expect(server.connections == 2, "asked for twice before giving up on it")
        #expect(failedAfter.count == 1)
        let after = try #require(failedAfter.first)
        #expect(after >= .milliseconds(900), "the other voice began \(after) in, over the second still playing")
    }

    @Test func whichFailuresAreWorthAskingAgain() {
        #expect(KokoroPlayer.worthAskingAgain(URLError(.networkConnectionLost)))
        #expect(KokoroPlayer.worthAskingAgain(POSIXError(.ECONNABORTED)), "a socket iOS took back while Redde was away")
        #expect(KokoroPlayer.worthAskingAgain(TransportError.http(status: 503, body: "")))
        #expect(!KokoroPlayer.worthAskingAgain(URLError(.timedOut)))
        #expect(!KokoroPlayer.worthAskingAgain(TransportError.unreachable("Hermes stopped answering mid-sentence")))
        #expect(!KokoroPlayer.worthAskingAgain(CancellationError()))
    }

    /// ElevenLabs busy (its limit on requests at once, a live call with it holding one): asked
    /// again a few times, after longer waits, before the on-device voice reads the sentence.
    @Test func busyIsWaitedOut() {
        #expect(KokoroPlayer.isBusy(TransportError.http(status: 429, body: "too_many_concurrent_requests")))
        #expect(!KokoroPlayer.isBusy(TransportError.http(status: 401, body: "missing the permission text_to_speech")))
        #expect(!KokoroPlayer.isBusy(URLError(.networkConnectionLost)))
    }
}

/// A group chat's next bot: its first sentence is fetched while another is read, and played from
/// what was fetched when its turn comes (`KokoroPlayer.prefetch`).
struct KokoroPrefetchTests {
    /// Plays one sentence to the end; false when it never drained.
    private func play(_ player: KokoroPlayer, _ text: String, server: URL, voice: String) async -> Bool {
        await withCheckedContinuation { done in
            var resumed = false
            player.onDrained = {
                guard !resumed else { return }
                resumed = true
                done.resume(returning: true)
            }
            player.begin()   // as a reply's start does: a stop, which leaves what was fetched ahead
            player.enqueue(text, baseURL: server, voice: voice)
            player.finish()
            Task {
                try? await Task.sleep(for: .seconds(10))
                guard !resumed else { return }
                resumed = true
                done.resume(returning: false)
            }
        }
    }

    @Test func aSentenceFetchedAheadIsNotAskedForAgain() async throws {
        let server = try await DroppingSpeechServer.start(drops: 0)
        defer { server.stop() }
        let player = KokoroPlayer()
        player.prefetch("Falls Loop is open.", baseURL: server.baseURL, voice: "am_adam")
        player.prefetch("Falls Loop is open.", baseURL: server.baseURL, voice: "am_adam")   // the same again: left as it is
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.connections == 1)
        #expect(await play(player, "Falls Loop is open.", server: server.baseURL, voice: "am_adam"))
        #expect(server.connections == 1, "played from what was fetched")
        // In another voice it is another sentence.
        player.prefetch("Bring layers.", baseURL: server.baseURL, voice: "am_adam")
        try await Task.sleep(for: .milliseconds(300))
        #expect(await play(player, "Bring layers.", server: server.baseURL, voice: "bf_emma"))
        #expect(server.connections == 3)
        player.release()
    }
}
