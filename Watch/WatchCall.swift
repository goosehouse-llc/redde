import AVFoundation
import Foundation
import Observation
import os
import WatchKit

/// A live call on the watch by itself: a voice service (GPT-Live, Gemini Live or Grok Voice)
/// holds the conversation straight from the wrist, and every real request it hands over goes to
/// the agent the way the watch's questions do (`WatchStore.answerForCall`: the Hermes API, the
/// fast lane, or through the iPhone), its answer back to the voice to say. The socket and the
/// audio are the phone's own (`LiveCall`), and so is each service's wire (`LiveDialect`).
///
/// watchOS lets an app open a socket only while it streams audio: the play-and-record session
/// is set up and made active, synchronously, before the call connects, and a socket the watch
/// gave no network fails at once and says so (`noNetwork`).
@MainActor
@Observable
final class WatchCall {
    enum State: Equatable { case connecting, listening, thinking, speaking, ended }

    private(set) var state: State = .connecting
    /// What the person is saying, and what the voice is saying, as transcribed.
    private(set) var heard = ""
    private(set) var said = ""
    private(set) var isMuted = false
    /// Why the call ended, when the person didn't end it.
    private(set) var problem: String?
    let engine: LiveEngine

    private let live: WatchLive
    private let agentName: String
    private unowned let store: WatchStore
    private let dialect: any LiveDialect
    private var call: LiveCall?
    @ObservationIgnored private lazy var relay = Relay(owner: self)
    private var connected = false
    private var voiceSpeaking = false
    private var fragments: [LiveFragment] = []
    /// Where the words of the next request begin: after those of the last one handed over.
    private var handedOverAt = 0
    private var lastSpeaker: LiveFragment.Speaker?
    /// The request handed over and being worked on: its id, and the work.
    private var delegation: String?
    private var turn: Task<Void, Never>?
    private var started: ContinuousClock.Instant?
    private var eventCount = 0
    private let log = Logger(subsystem: "com.goosehouse.echo.watch", category: "call")

    /// Nil when the phone handed over no service the watch can call.
    init?(live: WatchLive, agentName: String, store: WatchStore) {
        guard WatchLive.engines.contains(live.engine), let engine = LiveEngine(rawValue: live.engine), !live.key.isEmpty else { return nil }
        self.live = live
        self.engine = engine
        self.agentName = agentName
        self.store = store
        dialect = engine.dialect
    }

    func start() async {
        started = .now
        do {
            try Self.startAudio()
            let call = LiveCall(listener: relay, dialect: dialect)
            self.call = call
            try call.open()
            var endpoint: LiveEndpoint
            #if DEBUG
            // `-echo.liveEndpoint <ws url>`: a stand-in service, for the simulator.
            let args = ProcessInfo.processInfo.arguments
            if let e = args.firstIndex(of: "-echo.liveEndpoint"), e + 1 < args.count, let url = URL(string: args[e + 1]) {
                endpoint = LiveEndpoint(url: url)
            } else {
                endpoint = try await dialect.endpoint(key: live.key)
            }
            #else
            endpoint = try await dialect.endpoint(key: live.key)
            #endif
            guard state != .ended else { return }
            let plan = LivePlan(voice: live.voice.isEmpty ? engine.defaultVoice : live.voice,
                                instructions: LiveSetup.persona(name: agentName, engine: engine) + "\n\n" + Self.onTheWatch,
                                history: store.history.map { LiveLine(fromPerson: $0.role == .user, text: $0.text) },
                                agent: engine == .gptLive ? nil : LiveAgentTool(agentName: agentName))
            try await call.connect(LiveConnection(url: endpoint.url, headers: endpoint.headers, plan: plan))
        } catch {
            guard state != .ended else { return }
            end(problem: Self.readable(error, engine: engine))
        }
    }

    /// The person ends the call: the service is told, so its bill stops at once.
    func hangUp() {
        guard state != .ended else { return }
        turn?.cancel()
        if delegation != nil { store.stop() }
        send(dialect.close())
        let call = call
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            call?.close()
        }
        self.call = nil
        finish()
    }

    func toggleMute() {
        isMuted.toggle()
        call?.setMuted(isMuted)
        send(dialect.mute(isMuted, eventID: nextID("mute")))
    }

    var inputLevel: Float { call?.inputLevel ?? 0 }
    var outputLevel: Float { call?.outputLevel ?? 0 }

    // MARK: - What the service says

    fileprivate func received(_ text: String) {
        for event in dialect.read(text) {
            guard state != .ended else { return }
            switch event {
            case .started:
                guard !connected else { continue }
                connected = true
                WKInterfaceDevice.current().play(.start)
                if let started { log.info("\(self.engine.name, privacy: .public) call on after \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds], width: .narrow)), privacy: .public)") }
                changed()
            case let .transcript(speaker, piece, startMs, endMs):
                if speaker == .person, !piece.contains(where: { $0.isLetter || $0.isNumber }) { continue }
                let now = started.map { Int((ContinuousClock.now - $0) / .milliseconds(1)) } ?? 0
                transcribed(LiveFragment(speaker: speaker, text: piece, startMs: startMs ?? now, endMs: endMs ?? now))
            case let .delegated(id, request):
                delegated(id, request: request)
            case let .withdrawn(ids):
                if let delegation, ids.contains(delegation) {
                    turn?.cancel()
                    store.stop()
                    self.delegation = nil
                    changed()
                }
            case let .failed(message, code):
                if code == "context_injection_incomplete" { continue }
                log.error("\(self.engine.name, privacy: .public): \(message, privacy: .public)")
            case let .closed(reason):
                end(problem: reason.map { LiveFailure.readable($0, engine: engine) })
            case .interrupted, .audio, .reply:
                break
            }
        }
    }

    fileprivate func callChanged(_ state: LiveCallState) {
        switch state {
        case .speaking: voiceSpeaking = true; changed()
        case .quiet: voiceSpeaking = false; changed()
        case .lost: end(problem: connected ? String(localized: "The connection to \(engine.name) dropped.") : Self.noNetwork)
        }
    }

    private func transcribed(_ fragment: LiveFragment) {
        fragments.append(fragment)
        if fragments.count > 400 {
            fragments.removeFirst(100)
            handedOverAt = max(0, handedOverAt - 100)
        }
        switch fragment.speaker {
        case .person:
            if lastSpeaker != .person { heard = "" }
            heard += fragment.text
        case .voice:
            if lastSpeaker != .voice { said = "" }
            said += fragment.text
        }
        lastSpeaker = fragment.speaker
    }

    // MARK: - Handing a request to the agent

    /// The voice wants the agent: the person's last words (or the voice's wording of them) go as
    /// the watch's questions do, and the answer goes back for the voice to say. A newer request
    /// stops one still being worked on.
    private func delegated(_ id: String, request: String?) {
        turn?.cancel()
        delegation = id
        changed()
        // Gemini's transcripts come in no set order: a moment for the words the request is about.
        let settle: Duration = dialect.streamsAnswers ? .zero : .milliseconds(700)
        turn = Task { [weak self] in
            if settle > .zero { try? await Task.sleep(for: settle) }
            guard let self, delegation == id, !Task.isCancelled else { return }
            let spoken = LiveFragment.delegation(from: Array(fragments[min(handedOverAt, fragments.count)...])).prompt
            handedOverAt = fragments.count
            let asked = (spoken.isEmpty ? request ?? "" : spoken)
                .replacingOccurrences(of: LiveSetup.readAloudMark, with: "").trimmingCharacters(in: .whitespaces)
            var answer: String
            do {
                answer = try await store.answerForCall(asked.isEmpty ? request ?? "" : asked)
            } catch is CancellationError {
                return
            } catch {
                answer = "I couldn't get that from \(agentName): \(error.localizedDescription)"
            }
            guard delegation == id, !Task.isCancelled else { return }
            let words = PlainText.spoken(answer)
            let whole = words.isEmpty ? "\(agentName) finished that request without anything to say." : words
            if dialect.streamsAnswers {
                for part in LiveFragment.appendable(whole) { send(dialect.answer(part, to: id, final: false, eventID: nextID("say"))) }
            } else {
                send(dialect.answer(whole, to: id, final: true, eventID: nextID("say")))
            }
            delegation = nil
            changed()
        }
    }

    // MARK: - The call's end

    private func end(problem: String?) {
        guard state != .ended else { return }
        self.problem = problem
        turn?.cancel()
        call?.close()
        call = nil
        if problem != nil { WKInterfaceDevice.current().play(.failure) }
        finish()
    }

    private func finish() {
        state = .ended
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func changed() {
        guard state != .ended else { return }
        state = !connected ? .connecting : voiceSpeaking ? .speaking : delegation != nil ? .thinking : .listening
    }

    private func send(_ messages: [JSONValue]) {
        guard let call else { return }
        for message in messages { _ = call.send(type(of: dialect).encode(message)) }
    }

    private func nextID(_ prefix: String) -> String {
        eventCount += 1
        return "\(prefix)_\(eventCount)"
    }

    // MARK: - The watch's part

    /// Play and record through the watch's own speaker (long-form audio would want headphones),
    /// made active here and now: watchOS lets the call's socket out only while it streams audio.
    private static func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, policy: .default, options: [])
        try session.setActive(true)
    }

    /// What the voice is told besides who it is: it is on a watch, so it keeps it short.
    static let onTheWatch = """
        The user is talking to you on their Apple Watch. Keep what you say short: a sentence or two, \
        unless they ask for more.
        """

    /// The socket never opened: watchOS gave it no network (its low-level networking goes apart
    /// from the watch's ordinary internet).
    static let noNetwork = String(localized: "The watch couldn't reach the voice service. Try again with your iPhone nearby or on Wi-Fi.",
                                  comment: "Watch: a live call's connection got no network")

    static func readable(_ error: Error, engine: LiveEngine) -> String {
        let code = (error as NSError).code
        if (error as NSError).domain == NSURLErrorDomain, [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost].contains(code) {
            return noNetwork
        }
        return error.localizedDescription
    }
}

/// The call's events, held weakly: `LiveCall` keeps its listener.
@MainActor
private final class Relay: LiveCallListening {
    weak var owner: WatchCall?
    init(owner: WatchCall) { self.owner = owner }
    func liveCallReceived(_ event: String) { owner?.received(event) }
    func liveCallChanged(_ state: LiveCallState) { owner?.callChanged(state) }
}

/// One call is one screen: told apart by identity (`navigationDestination(item:)`).
extension WatchCall: Hashable {
    nonisolated static func == (a: WatchCall, b: WatchCall) -> Bool { a === b }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
