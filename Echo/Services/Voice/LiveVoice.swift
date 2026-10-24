import Foundation
import os

/// GPT-Live (Settings → Voice → Conversation): OpenAI's voice model holds the conversation,
/// talking and listening at once, and hands every real request to the agent, whose answer it
/// then says in its own words. Hermes keeps everything else: the model, the tools, the memory,
/// the approvals. This is Hermes Desktop's live voice (tools/voice_live.py and its desktop
/// client), on Redde's connections: the call goes straight from the phone to OpenAI over WebRTC
/// (`LiveCalling`); the person's Hermes sets it up with its own OpenAI key, or Redde with one kept
/// in it (`LiveSetup`). The voice session drives this in place of its recogniser and its voice.
final class LiveVoice {
    enum State: Equatable { case connecting, listening, thinking, speaking, ended }

    private(set) var state: State = .connecting
    /// What the person is saying, from the start of what they're saying now.
    private(set) var heard = ""
    /// What the voice is saying, from the start of what it's saying now.
    private(set) var said = ""
    /// What the agent is doing for the request handed to it.
    private(set) var tool: String?
    private(set) var isMuted = false
    /// Why the call ended, when the person didn't end it.
    private(set) var problem: String?
    /// The call is set up and its audio flowing.
    private(set) var connected = false
    /// Each change, for the voice session to show.
    var onChange: (() -> Void)?

    var inputLevel: Float { call?.inputLevel ?? 0 }
    var outputLevel: Float { call?.outputLevel ?? 0 }

    private let conversation: Conversation
    private let settings: Settings
    private let makeCall: (LiveCallListening) throws -> LiveCalling
    private let setUp: LiveSetup.Resolver
    private var call: LiveCalling?
    private lazy var relay = Relay(owner: self)
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "live")

    /// The spoken exchange as transcribed, both sides, for what a handed-over request refers to.
    private var fragments: [LiveFragment] = []
    private var lastSpeaker: LiveFragment.Speaker?
    /// The person's words since they last started talking, judged once they stop: a stop phrase ends the call.
    private var utterance = ""
    private var utteranceSettles: Task<Void, Never>?
    private var voiceSpeaking = false
    /// The request the agent is working on (`session.delegation.created`), and the turn doing it.
    private var delegation: String?
    private var turn: Task<Void, Never>?
    private var chunker = SentenceChunker()
    private var spokenAnything = false
    /// The Dashboard takes the turn as a live voice one itself (`LiveTurn.surface`).
    private var hermesKnowsLiveTurns = false
    private var eventCount = 0
    private var lastActivity = ContinuousClock.now
    private var quietWatch: Task<Void, Never>?
    /// When `start` began, for the log of how long each step of setting the call up took.
    private var callStarted: ContinuousClock.Instant?

    init(conversation: Conversation, settings: Settings = .shared,
         makeCall: @escaping (LiveCallListening) throws -> LiveCalling = { try LiveEngine.makeCall(listener: $0) },
         setUp: @escaping LiveSetup.Resolver = LiveSetup.resolve) {
        self.conversation = conversation
        self.settings = settings
        self.makeCall = makeCall
        self.setUp = setUp
    }

    // MARK: - The call

    /// Sets the call up: the microphone and the offer, while (at the same time) it is found out
    /// who sets it up; then the session, then the answer. The audio session is the caller's,
    /// active for voice already.
    func start() async {
        let started = ContinuousClock.now
        callStarted = started
        func took() -> String { (ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds], width: .narrow)) }
        let call: LiveCalling
        do { call = try makeCall(relay) } catch { end(problem: error.localizedDescription); return }
        self.call = call
        async let found = setUp(conversation, settings)
        do {
            let offer = try await withCheckedThrowingContinuation { (sent: CheckedContinuation<String, Error>) in
                call.makeOffer { offer, problem in
                    if let offer { sent.resume(returning: offer) } else { sent.resume(throwing: LiveFailure(problem ?? "No offer.")) }
                }
            }
            note("offer ready after \(took())")
            let setup = try await found
            guard state != .ended else { return }
            hermesKnowsLiveTurns = setup.hermesKnowsLiveTurns
            let answer = try await setup.open(offer, LiveSetup.history(conversation.messages))
            note("answered through \(setup.label) after \(took())")
            guard state != .ended else { return }
            try await withCheckedThrowingContinuation { (applied: CheckedContinuation<Void, Error>) in
                call.accept(answer) { problem in
                    if let problem { applied.resume(throwing: LiveFailure(problem)) } else { applied.resume() }
                }
            }
            note("answer applied after \(took())")
        } catch {
            guard state != .ended else { return }
            end(problem: error.localizedDescription)
        }
    }

    /// The person ends the call. OpenAI is told, so that its bill stops at once, and a moment
    /// after (for that to go out) the connection closes.
    func hangUp() {
        guard state != .ended else { return }
        _ = send(["type": .string("session.close")])
        let call = call
        Task { try? await Task.sleep(for: .milliseconds(250)); call?.close() }
        self.call = nil
        end(problem: nil)
    }

    func setMuted(_ muted: Bool) {
        guard muted != isMuted, state != .ended else { return }
        isMuted = muted
        call?.setMuted(muted)
        _ = send(["type": .string(muted ? "session.input_audio.mute" : "session.input_audio.unmute"), "event_id": .string(nextID(muted ? "mute" : "unmute"))])
        changed()
    }

    private func end(problem: String?) {
        guard state != .ended else { return }
        if let callStarted { note("ended after \((ContinuousClock.now - callStarted).formatted(.units(allowed: [.seconds], width: .narrow)))\(problem.map { ": " + $0 } ?? "")") }
        self.problem = problem
        if let problem { log.error("GPT-Live call ended: \(problem, privacy: .public)") }
        state = .ended
        utteranceSettles?.cancel()
        quietWatch?.cancel()
        turn?.cancel()
        turn = nil
        delegation = nil
        call?.close()
        call = nil
        onChange?()
    }

    private func changed() {
        guard state != .ended else { return }
        let now: State = !connected ? .connecting : voiceSpeaking ? .speaking : delegation != nil ? .thinking : .listening
        state = now
        onChange?()
    }

    // MARK: - What the call says

    fileprivate func received(_ text: String) {
        guard state != .ended, let event = try? JSONValue.parse(Data(text.utf8)), let type = event["type"]?.string else { return }
        switch type {
        case "session.started":
            began()
        case "session.input_transcript.delta", "session.output_transcript.delta":
            let speaker: LiveFragment.Speaker = type == "session.input_transcript.delta" ? .person : .voice
            let delta = event["delta"]?.string ?? ""
            transcribed(LiveFragment(speaker: speaker, text: delta, startMs: event["start_ms"]?.int ?? 0, endMs: event["end_ms"]?.int ?? 0))
        case "session.delegation.created":
            if let id = event["delegation"]?["id"]?.string { delegated(id) }
        case "error":
            // Appends after the call is over, or to a request it has moved on from: expected.
            if event["error"]?["code"]?.string == "context_injection_incomplete" { return }
            log.error("GPT-Live: \(event["error"]?["message"]?.string ?? "an error", privacy: .public)")
        case "session.closed":
            let reason = event["reason"]?.string ?? ""
            end(problem: reason.isEmpty || reason == "close_requested" ? nil : LiveFailure.readable(reason))
        default:
            break
        }
    }

    fileprivate func callChanged(_ state: LiveCallState) {
        switch state {
        case .connected: began()
        case .speaking:
            voiceSpeaking = true
            lastActivity = .now
            changed()
        case .quiet:
            voiceSpeaking = false
            lastActivity = .now
            changed()
        case .lost:
            end(problem: "The connection to GPT-Live dropped.")
        }
    }

    private func began() {
        guard !connected else { return }
        if let callStarted { note("connected after \((ContinuousClock.now - callStarted).formatted(.units(allowed: [.milliseconds], width: .narrow)))") }
        connected = true
        #if DEBUG
        if DevHooks.has("-echo.liveMeasure") { measure() }
        #endif
        lastActivity = .now
        watchForQuiet()
        changed()
    }

    private func transcribed(_ fragment: LiveFragment) {
        lastActivity = .now
        fragments.append(fragment)
        if fragments.count > 2_000 { fragments.removeFirst(500) }
        switch fragment.speaker {
        case .person:
            if lastSpeaker != .person { heard = "" }
            heard += fragment.text
            utterance += fragment.text
            // The voice model answers a bare "stop" itself, going quiet, and never hands it over:
            // what the person said is looked at once they've stopped saying it.
            utteranceSettles?.cancel()
            utteranceSettles = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1_500))
                guard !Task.isCancelled, let self else { return }
                let said = utterance
                utterance = ""
                if StopPhrase.matches(said, own: settings.stopPhrases) {
                    log.info("stop phrase heard on the call")
                    hangUp()
                }
            }
        case .voice:
            if lastSpeaker != .voice { said = "" }
            said += fragment.text
        }
        lastSpeaker = fragment.speaker
        onChange?()
    }

    /// Hangs up after Settings' minutes of nobody saying anything and nothing being worked on:
    /// OpenAI bills the silence too.
    private func watchForQuiet() {
        quietWatch?.cancel()
        let minutes = settings.liveHangUp
        guard minutes > 0 else { return }
        quietWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                if delegation == nil, !voiceSpeaking, ContinuousClock.now - lastActivity > .seconds(minutes * 60) {
                    log.info("GPT-Live call quiet for \(minutes) min: hanging up")
                    hangUp()
                    return
                }
            }
        }
    }

    // MARK: - Handing a request to the agent

    /// The voice wants the agent: what the person last said becomes a turn in the conversation,
    /// with the exchange around it for the agent alone. A newer request stops one still being
    /// worked on, so the answer the voice gives is to what was asked last.
    private func delegated(_ id: String) {
        lastActivity = .now
        let (prompt, context) = LiveFragment.delegation(from: recentFragments())
        if StopPhrase.matches(prompt, own: settings.stopPhrases) { hangUp(); return }
        turn?.cancel()
        if conversation.isStreaming { conversation.cancel() }
        delegation = id
        tool = nil
        spokenAnything = false
        chunker = SentenceChunker()
        changed()
        turn = Task { [weak self] in await self?.work(on: prompt, context: context, for: id) }
    }

    private func work(on prompt: String, context: String, for id: String) async {
        // Spoken prefixes, as in Redde's own voice: "Home, …" goes to that bot's chat first.
        let route = VoiceRouting.route(prompt, rules: settings.spokenPrefixes)
        if let bot = route?.bot {
            _ = try? await conversation.goToBot(bot, mainName: settings.headerTitle)
        }
        if let model = route?.model { try? await conversation.switchModel(model, provider: route?.provider) }
        guard delegation == id, !Task.isCancelled else { return }
        let events = conversation.send(route?.text ?? prompt, live: LiveTurn(context: context, surface: hermesKnowsLiveTurns))
        for await event in events {
            guard delegation == id, !Task.isCancelled else { return }
            lastActivity = .now
            switch event {
            case let .textDelta(delta):
                chunker.append(delta).forEach { say($0, for: id) }
            case let .toolStarted(name, _, _):
                tool = name
                think("\(agentName) is working: \(name). Not done yet.", for: id)
                changed()
            case .toolFinished:
                tool = nil
                changed()
            case .interrupt:
                think("\(agentName) is waiting for the user to answer a request on their iPhone's screen.", for: id)
            default:
                break
            }
        }
        guard delegation == id, !Task.isCancelled else { return }
        if let tail = chunker.flush() { say(tail, for: id) }
        if conversation.lastSendWasHeld {
            say("That request is waiting behind another one; it goes as soon as that's done.", for: id)
        } else if let error = conversation.lastError {
            say("I couldn't get that from \(agentName): \(error)", for: id)
        } else if !spokenAnything {
            think("\(agentName) finished that request without anything to say.", for: id)
        }
        delegation = nil
        tool = nil
        changed()
    }

    /// How setting the call up went, in the log; with `-echo.liveMeasure` (DEBUG), in
    /// Library/Caches/live-measure.log as well, with the call's cost to the phone every ten seconds.
    private func note(_ line: String) {
        log.info("GPT-Live: \(line, privacy: .public)")
        #if DEBUG
        guard DevHooks.has("-echo.liveMeasure") else { return }
        let file = URL.cachesDirectory.appending(path: "live-measure.log")
        let text = Date.now.formatted(.iso8601.time(includingFractionalSeconds: true)) + " " + line + "\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
        #endif
    }

    #if DEBUG
    private func measure() {
        func cpu() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        func footprint() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
        }
        Task { [weak self] in
            var last = (cpu: cpu(), at: Date.now)
            while let self, state != .ended {
                try? await Task.sleep(for: .seconds(10))
                guard state != .ended else { return }
                let now = (cpu: cpu(), at: Date.now)
                note(String(format: "%@: %.1f%% of a core, %.1f MB, levels %.2f in %.2f out", "\(state)",
                            (now.cpu - last.cpu) / now.at.timeIntervalSince(last.at) * 100, footprint(), inputLevel, outputLevel))
                last = now
            }
        }
    }
    #endif

    /// Whose agent this is: the bot's whose chat it is, else the main one's name.
    private var agentName: String { conversation.bot?.name ?? settings.headerTitle }

    /// The agent's answer, a sentence at a time as it is written, for the voice to say.
    private func say(_ text: String, for id: String) {
        let spoken = PlainText.spoken(text)
        // A table's rule or a code block's fence, alone on its line: nothing to say.
        guard spoken.contains(where: { $0.isLetter || $0.isNumber }), !spoken.hasPrefix("`") else { return }
        spokenAnything = true
        for part in LiveFragment.appendable(spoken) {
            _ = send(["type": .string("session.commentary.append"), "content": .string(part),
                      "delegation_id": .string(id), "event_id": .string(nextID("say"))])
        }
    }

    /// Quiet progress, for the voice to mention if it likes ("it's checking your calendar").
    private func think(_ text: String, for id: String) {
        _ = send(["type": .string("session.thinking.append"), "content": .string(String(text.prefix(LiveFragment.appendLimit))),
                  "delegation_id": .string(id), "event_id": .string(nextID("think"))])
    }

    private func send(_ event: [String: JSONValue]) -> Bool {
        guard let call, let data = try? JSONEncoder().encode(JSONValue.object(event)) else { return false }
        return call.send(String(decoding: data, as: UTF8.self))
    }

    private func nextID(_ prefix: String) -> String {
        eventCount += 1
        return "\(prefix)_\(eventCount)"
    }

    /// The last five minutes of the exchange, eighty pieces at most, as Hermes Desktop sends.
    private func recentFragments() -> [LiveFragment] {
        guard let last = fragments.last else { return [] }
        return Array(fragments.filter { $0.endMs >= last.endMs - 5 * 60_000 }.suffix(80))
    }
}

/// Why a call couldn't be had, in words.
nonisolated struct LiveFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }

    /// A machine reason from the service, as a sentence where Redde knows it.
    static func readable(_ reason: String) -> String {
        switch reason {
        case "connection_lost": "The connection to GPT-Live dropped."
        case "max_duration", "session_expired": "The GPT-Live call reached its time limit."
        default: "GPT-Live ended the call (\(reason))."
        }
    }
}

/// A piece of the spoken exchange as the service transcribes it.
nonisolated struct LiveFragment: Equatable, Sendable {
    enum Speaker: Equatable, Sendable { case person, voice }
    var speaker: Speaker
    var text: String
    var startMs: Int
    var endMs: Int

    /// The most one append may carry: the service takes 500 tokens; about four characters each, with room.
    static let appendLimit = 1_400

    /// What a handed-over request is: the person's last words (what the chat shows they said),
    /// and the exchange before them, newest last, for the agent alone.
    static func delegation(from fragments: [LiveFragment]) -> (prompt: String, context: String) {
        var turns: [(speaker: Speaker, text: String)] = []
        for fragment in fragments {
            if let last = turns.last, last.speaker == fragment.speaker {
                turns[turns.count - 1].text += fragment.text
            } else {
                turns.append((fragment.speaker, fragment.text))
            }
        }
        func clean(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let prompt = clean(turns.last { $0.speaker == .person }?.text ?? "")
        let context = turns.compactMap { turn -> String? in
            let text = clean(turn.text)
            return text.isEmpty ? nil : "\(turn.speaker == .person ? "User" : "Voice assistant"): \(text)"
        }.joined(separator: "\n")
        return (prompt.isEmpty ? String(context.suffix(400)) : prompt, context)
    }

    /// Text in pieces the service takes: whole sentences where they fit.
    static func appendable(_ text: String, limit: Int = appendLimit) -> [String] {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard clean.count > limit else { return clean.isEmpty ? [] : [clean] }
        var parts: [String] = []
        var current = ""
        var sentences: [String] = []
        var rest = Substring(clean)
        while let end = rest.firstMatch(of: /[.!?]\s+/) {
            sentences.append(String(rest[...end.range.lowerBound]))
            rest = rest[end.range.upperBound...]
        }
        if !rest.isEmpty { sentences.append(String(rest)) }
        for sentence in sentences {
            if sentence.count > limit {
                if !current.isEmpty { parts.append(current); current = "" }
                var rest = Substring(sentence)
                while !rest.isEmpty { parts.append(String(rest.prefix(limit))); rest = rest.dropFirst(limit) }
                continue
            }
            let joined = current.isEmpty ? sentence : current + " " + sentence
            if joined.count > limit { parts.append(current); current = sentence } else { current = joined }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

/// Hears the call for `LiveVoice`: a call holds what it tells weakly, and has to be told by
/// an Objective-C object.
private final class Relay: NSObject, LiveCallListening {
    weak var owner: LiveVoice?
    init(owner: LiveVoice) { self.owner = owner }
    func liveCallReceived(_ event: String) { owner?.received(event) }
    func liveCallChanged(_ state: String) { LiveCallState(rawValue: state).map { owner?.callChanged($0) } }
}

/// Loads ReddeLive.framework, which carries WebRTC, the first time it is wanted and never before
/// (`LiveCallBridge`).
enum LiveEngine {
    nonisolated private static let path = Bundle.main.privateFrameworksPath.map { $0 + "/ReddeLive.framework/ReddeLive" }
    private static var callType: NSObject.Type?

    /// Loads it away from the main thread when the voice screen opens with GPT-Live chosen: a
    /// first load takes up to 50 ms, a stall in the screen's opening on the main thread.
    nonisolated static func preload() {
        guard let path else { return }
        Task.detached(priority: .userInitiated) { _ = dlopen(path, RTLD_NOW) }
    }

    /// Whether it is loaded in this process (it shouldn't be, until a call).
    nonisolated static var isLoaded: Bool {
        (0..<_dyld_image_count()).contains { String(cString: _dyld_get_image_name($0)).hasSuffix("/ReddeLive.framework/ReddeLive") }
    }

    static func makeCall(listener: LiveCallListening) throws -> LiveCalling {
        guard let made = try load().perform(NSSelectorFromString("makeWithListener:"), with: listener)?.takeUnretainedValue(),
              let call = made as? LiveCalling else { throw LiveFailure("GPT-Live couldn't start.") }
        return call
    }

    private static func load() throws -> NSObject.Type {
        if let callType { return callType }
        guard let path, dlopen(path, RTLD_NOW) != nil else {
            throw LiveFailure("GPT-Live couldn't load: \(dlerror().map { String(cString: $0) } ?? "no framework").")
        }
        guard let type = NSClassFromString("ReddeLiveCall") as? NSObject.Type else { throw LiveFailure("GPT-Live couldn't load.") }
        callType = type
        return type
    }
}
