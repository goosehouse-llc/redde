import AVFoundation
import Foundation

/// A live voice heard before it is picked (GPT-Live's, Gemini's, Grok's). They publish no
/// samples, so this is a call of a few seconds, with the key kept in Redde, in which that voice
/// says one line; billed as a call is (GPT-Live about half a cent; Grok's and Gemini's less). For
/// the voice lists (`LiveVoiceList`).
@MainActor @Observable
final class LiveVoicePreview {
    /// The voice being connected to or heard, for its row.
    private(set) var playing: String?
    private(set) var problem: String?
    private var task: Task<Void, Never>?

    /// `voice` of `engine` says a line as `name`, in `language` (its group's; "Any language" is English).
    func play(_ voice: String, of engine: LiveEngine, as name: String, in language: String) {
        stop()
        playing = voice
        problem = nil
        let spoken = language == "Any language" ? "English" : language
        task = Task { [weak self] in
            do {
                try await Self.say(voice: voice, engine: engine, greeting: LiveGreeting(line: "Hi, I'm \(name). This is how I sound.", language: spoken))
            } catch is CancellationError {
            } catch {
                self?.problem = error.localizedDescription
            }
            if self?.playing == voice { self?.playing = nil }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        sampler?.pause()
        sampler = nil
        playing = nil
    }

    /// A voice's own sample, where its company has one (ElevenLabs): played, no call needed.
    func playSample(_ url: URL, of voice: String) {
        stop()
        playing = voice
        problem = nil
        try? AudioSessionController.shared.activateForPlayback()
        let player = AVPlayer(url: url)
        sampler = player
        player.play()
        task = Task { [weak self] in
            // Over when it has played out (or after half a minute, whatever it is).
            for _ in 0..<300 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                if let item = player.currentItem, item.status == .failed {
                    problem = "The sample didn't play."
                    break
                }
                if let item = player.currentItem, item.duration.isNumeric, player.currentTime() >= item.duration { break }
            }
            if self?.playing == voice { self?.playing = nil }
        }
    }

    private var sampler: AVPlayer?

    /// The longest a preview runs, connecting included.
    private static let limit: Duration = .seconds(15)
    /// Its line is over after this long without the voice audible (the audio may go on, silent).
    private static let over: Duration = .milliseconds(800)

    private static func say(voice: String, engine: LiveEngine, greeting: LiveGreeting) async throws {
        let dialect = engine.dialect
        let endpoint = try await endpoint(engine)
        try AudioSessionController.shared.activateForPlayback()
        let speaker = try PreviewSpeaker(rate: dialect.outputRate)
        defer { speaker.stop() }
        var request = URLRequest(url: endpoint.url)
        for (field, value) in endpoint.headers { request.setValue(value, forHTTPHeaderField: field) }
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.maximumMessageSize = 8 << 20
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let plan = LivePlan(voice: voice, instructions: "You are letting someone hear your voice before they choose it. Speak warmly and naturally.",
                            greeting: greeting, preview: true)
        func send(_ messages: [JSONValue]) async throws {
            for message in messages { try await socket.send(.string(type(of: dialect).encode(message))) }
        }
        var silence: Task<Void, Never>?
        defer { silence?.cancel() }
        // What came back, for when it says nothing.
        var heard: [String] = [], peak: Float = 0
        try await withTaskCancellationHandler {
            try await send(dialect.opening(plan))
            let began = ContinuousClock.now
            var lastAudible: ContinuousClock.Instant?
            reading: while ContinuousClock.now - began < limit {
                try Task.checkCancellation()
                let text: String
                switch try await socket.receive() {
                case let .string(string): text = string
                case let .data(data): text = String(decoding: data, as: UTF8.self)
                @unknown default: continue
                }
                for event in dialect.read(text) {
                    switch event {
                    case .started:
                        heard.append("started")
                        try await send(dialect.afterStart(plan, eventID: "greet_1"))
                        // The microphone's side flowing, silence and all: GPT-Live says nothing without it.
                        silence = Self.silence(to: socket, dialect: dialect)
                    case let .audio(data):
                        let level = speaker.queue.appendPCM16(data, gain: dialect.outputGain)
                        peak = max(peak, level)
                        if level > 0.03 { lastAudible = .now }
                    case let .failed(message, _):
                        throw LiveFailure(message)
                    case let .closed(reason):
                        heard.append("closed \(reason ?? "")")
                        break reading
                    case let .reply(message):
                        try? await socket.send(.string(message))
                    case let .transcript(_, piece, _, _):
                        if heard.last != "transcript" { heard.append("transcript") }
                        _ = piece
                    default:
                        break
                    }
                }
                if let lastAudible, ContinuousClock.now - lastAudible > over { break }
            }
            guard lastAudible != nil else {
                #if DEBUG
                throw LiveFailure("The voice didn't speak. Try again. (Heard: \(heard.joined(separator: ", ")); loudest \(String(format: "%.3f", peak)).)")
                #else
                throw LiveFailure("The voice didn't speak. Try again.")
                #endif
            }
            // Its last words still queued: heard out before the call closes.
            let draining = ContinuousClock.now
            while !speaker.queue.isEmpty, ContinuousClock.now - draining < .seconds(3) {
                try await Task.sleep(for: .milliseconds(50))
            }
            try? await send(dialect.close())
        } onCancel: {
            socket.cancel(with: .normalClosure, reason: nil)
        }
    }

    /// The microphone's side of the call, as silence, 100 ms at a time until cancelled.
    private static func silence(to socket: URLSessionWebSocketTask, dialect: any LiveDialect) -> Task<Void, Never> {
        let message = dialect.audio(Data(count: Int(dialect.inputRate / 10) * 2).base64EncodedString())
        return Task {
            while !Task.isCancelled {
                try? await socket.send(.string(message))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private static func endpoint(_ engine: LiveEngine) async throws -> LiveEndpoint {
        #if DEBUG
        // `-echo.liveEndpoint ws://…`: the stand-in (scripts/live-standin.py) plays a tone.
        if let lab = DevHooks.value("-echo.liveEndpoint").flatMap(URL.init(string:)) { return LiveEndpoint(url: lab) }
        #endif
        guard let key = Keychain.read(engine.keyItem)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw LiveFailure("Hearing a voice needs your \(engine.company) key, in Settings → Voice → Conversation.")
        }
        return try await engine.dialect.endpoint(key: key)
    }
}

/// The preview's speaker: the voice's queue pulled by the engine, nothing recorded.
nonisolated final class PreviewSpeaker: @unchecked Sendable {
    let queue: VoiceQueue
    private let engine = AVAudioEngine()

    init(rate: Double) throws {
        queue = VoiceQueue(capacity: Int(rate * 30), lead: Int(rate * 0.12), rate: rate)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else {
            throw LiveFailure("The voice can't be played.")
        }
        let node = AVAudioSourceNode(format: format, renderBlock: VoiceQueue.renderer(queue))
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
    }

    func stop() { engine.stop() }
}
