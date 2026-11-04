import Foundation

/// Who holds a live voice call (Settings → Voice → Voice mode, or a bot's own): OpenAI's
/// GPT-Live, Google's Gemini Live, xAI's Grok Voice or an ElevenLabs voice agent. Each is a WebSocket on Apple's TLS straight
/// from the phone, with a key of its own kept in Redde, and speaks a wire of its own
/// (`LiveDialect`); the rest of a call, the audio, the screen, handing requests to the agent, is
/// the same for all (`LiveCall`, `LiveVoice`). Gemini and Grok asked 2026-10-25, for cost; then
/// ElevenLabs, for its voices. Then Hermes Live / Codex (2026-10-30), the one apart: set up by the
/// person's Hermes through its talk-desktop plugin, on the ChatGPT subscription Codex is signed in
/// with there, so with no key in Redde, and over WebRTC (`HermesLiveCall`), not a WebSocket.
nonisolated enum LiveEngine: String, CaseIterable, Codable, Sendable {
    case gptLive, gemini, grok, elevenLabs, hermesLive

    /// The engines that call on a key kept in Redde, which a bot can also be given as its own
    /// (Edit Bot → Voice, `BotConversation`, which lists these by name). Not Hermes Live / Codex:
    /// the Hermes host sets its calls up, and a bot's choice has no such case, so Edit Bot doesn't
    /// offer it. Settings → Voice → Voice mode offers every engine (`voiceModes`).
    static var allCases: [LiveEngine] { [.gptLive, .gemini, .grok, .elevenLabs] }
    /// What Settings → Voice → Voice mode offers: every engine.
    static var voiceModes: [LiveEngine] { allCases + [.hermesLive] }

    var name: String {
        switch self {
        case .gptLive: "GPT-Live"
        case .gemini: "Gemini Live"
        case .grok: "Grok Voice"
        case .elevenLabs: "ElevenLabs"
        case .hermesLive: "Hermes Live / Codex"
        }
    }

    /// Whose voice it is, and where the microphone's sound goes while a call is open.
    var company: String {
        switch self {
        case .gptLive: "OpenAI"
        case .gemini: "Google"
        case .grok: "xAI"
        case .elevenLabs: "ElevenLabs"
        case .hermesLive: "OpenAI"
        }
    }

    /// Its key, kept in Redde (and synced with iCloud Keychain like the others). None for Hermes
    /// Live / Codex: the Hermes host's own Codex sign-in sets its calls up, and Redde never asks
    /// for, keeps or syncs an OpenAI key for them.
    var key: Keychain.Item? {
        switch self {
        case .gptLive: .openAILive
        case .gemini: .geminiLive
        case .grok: .grokVoice
        case .elevenLabs: .elevenLabsLive
        case .hermesLive: nil
        }
    }

    /// `key`, for the screens outside voice mode's settings that ask it of an engine they know
    /// has one (ElevenLabs' reading voice, a voice's preview). Never read or written for Hermes
    /// Live / Codex: nothing offers it a key field or a preview (`greets`), and its setup asks no
    /// key (`LiveSetup.resolve`); GPT-Live's item only keeps this total.
    var keyItem: Keychain.Item { key ?? .openAILive }

    /// The Hermes host sets its calls up (the talk-desktop plugin, over the Dashboard), and they go
    /// over WebRTC (`HermesLiveCall`) rather than a WebSocket of Redde's.
    var setUpByHermes: Bool { self == .hermesLive }

    /// It can open a session saying a line Redde gives it: a voice's preview, a group chat
    /// member's reply in its voice, a request's answer in another bot's voice (`LiveGreeting`).
    /// Not Hermes Live / Codex: the plugin words its sessions, and takes no line of Redde's.
    var greets: Bool { self != .hermesLive }

    /// The voice hands requests over by delegation (GPT-Live's own), not through a tool it is
    /// given (`LiveAgentTool`).
    var handsOverByDelegation: Bool { self == .gptLive || self == .hermesLive }

    var dialect: any LiveDialect {
        switch self {
        case .gptLive: GPTLiveDialect()
        case .gemini: GeminiLiveDialect()
        case .grok: GrokVoiceDialect()
        case .elevenLabs: ElevenLabsDialect()
        case .hermesLive: HermesLiveDialect()
        }
    }

    /// Its voices by the language each speaks, the default first. Hermes Live / Codex uses the
    /// v3 voice list accepted by the talk-desktop plugin, not GPT-Live's older list.
    var voiceGroups: [(language: String, voices: [String])] {
        switch self {
        case .gptLive: LiveSetup.voiceGroups
        case .hermesLive: HermesLiveDialect.voiceGroups
        case .gemini: GeminiLiveDialect.voiceGroups
        case .grok: GrokVoiceDialect.voiceGroups
        case .elevenLabs: []
        }
    }

    var voices: [String] { voiceGroups.flatMap(\.voices) }
    /// Its voices are the person's account's, listed when picked (`ElevenLabsVoice`), not Redde's to know.
    var voicesFromAccount: Bool { self == .elevenLabs }
    /// Redde reads the agent's every answer itself, in the call's own voice, as it is written
    /// (`LiveAnswerReader`), the voice held meanwhile: ElevenLabs takes a tool's result only whole,
    /// so the person waited for all of it, and its model then said it in other words (asked
    /// 2026-10-27, quicker and more private: the agent's answers no longer reach that model).
    var answersReadAloud: Bool { self == .elevenLabs }
    /// The voice nothing picked gives it; none for ElevenLabs: its agent's own.
    var defaultVoice: String { voices.first ?? "" }

    /// A voice to show, by its id.
    func voiceName(_ voice: String) -> String {
        guard voicesFromAccount else { return voice.capitalized }
        return voice.isEmpty ? String(localized: "The agent's own") : ElevenLabsVoice.name(voice) ?? String(localized: "A voice of yours")
    }

    /// How its company describes a voice, where it does.
    func style(of voice: String) -> String? {
        switch self {
        case .gptLive, .hermesLive: nil
        case .gemini: GeminiLiveDialect.styles[voice]
        case .grok: GrokVoiceDialect.styles[voice]
        case .elevenLabs: nil
        }
    }

    /// What a call costs, for its settings.
    var cost: String {
        switch self {
        case .gptLive: String(localized: "OpenAI bills the key's account $0.05 a minute, quiet minutes too.")
        case .gemini: String(localized: "Google bills the key's account about $0.005 a minute for what you say and $0.018 a minute for what the voice says (about $0.12 for ten minutes); a free tier is offered, whose conversations Google may use to improve its products.")
        case .grok: String(localized: "xAI bills the key's account $0.08 a minute.")
        case .elevenLabs: String(localized: "ElevenLabs bills the key's account by the minute past what its plan includes ($0.08 a minute), with the agent's language model on top; silence past ten seconds at a twentieth of that. The first call makes a voice agent named Redde voice in your ElevenLabs account.")
        case .hermesLive: String(localized: "Calls run on the ChatGPT plan Codex is signed in with on your Hermes, within that plan's limits: no API key, and nothing billed through Redde.")
        }
    }
}

/// What a session opens with, the same for every engine; each dialect words it its own way.
nonisolated struct LivePlan: Sendable, Equatable {
    var voice: String
    var instructions: String
    /// The conversation so far, newest last (`LiveSetup.history`).
    var history: [LiveLine] = []
    /// The one tool the voice hands real requests to the agent through, where requests go as tool
    /// calls (Gemini, Grok); GPT-Live hands them over its own way. Nil: no agent (a preview).
    var agent: LiveAgentTool?
    /// A line it says at once: a preview's, or the answer a call handed to another bot opens with.
    var greeting: LiveGreeting?
    /// A voice preview: no agent to hand anything to.
    var preview = false
}

/// A preview's line, and the language to say it in (the voice's group's).
nonisolated struct LiveGreeting: Sendable, Equatable {
    var line: String
    var language: String
    /// As OpenAI's guide words a greeting: the language, the words, to begin at once, then to stop.
    var asked: String { "Begin immediately: in \(language), say \"\(line)\" Then stop and listen." }
}

/// Where a call connects: its address, and headers (a key, a WebSocket subprotocol).
nonisolated struct LiveEndpoint: Sendable {
    var url: URL
    var headers: [String: String] = [:]
}

/// A message of the conversation so far, as text.
nonisolated struct LiveLine: Sendable, Equatable {
    var fromPerson: Bool
    var text: String
}

/// The agent as a tool the voice calls with the request in its own words.
nonisolated struct LiveAgentTool: Sendable, Equatable {
    static let name = "ask_agent"
    var agentName: String

    var description: String {
        "Hands a request to \(agentName), the user's own AI agent, and returns its answer. \(agentName) has tools: it can run commands, "
            + "read and edit files, browse the web, search, remember things, schedule tasks, use the user's phone and home, and reason "
            + "carefully. Use it for anything that needs facts, current information, careful reasoning, or doing something. It can take "
            + "a while; say briefly that you're checking, then wait for the result and say it in your own words."
    }
    static let requestDescription = "What the user wants, in their own words where you can, with anything from the conversation it needs."

    /// What goes with an answer to the voice, not to be said: whether the agent used its tools for
    /// it. Asked "did you run a tool?", ElevenLabs' voice said yes; it had handed the question
    /// over, and Home had answered from memory (Marta, 2026-10-26).
    static func checked(_ tools: [String], agent: String) -> String {
        tools.isEmpty
            ? "[Not to be read out: \(agent) used none of its tools for this answer. It answered from what it already had and checked nothing just now.]"
            : "[Not to be read out: \(agent) used its tools for this answer: \(tools.joined(separator: ", ")).]"
    }
}

/// What a service said, in Redde's terms: the same events whichever engine it is.
nonisolated enum LiveEvent: Sendable, Equatable {
    /// The session is set up: the call is on.
    case started
    /// The voice's sound: PCM16, little-endian, mono, at the dialect's output rate.
    case audio(Data)
    /// A piece of what the person or the voice said, as transcribed; times where the service gives them.
    case transcript(LiveFragment.Speaker, String, startMs: Int?, endMs: Int?)
    /// The voice hands a request to the agent; `request` is its own wording where it gives one.
    case delegated(id: String, request: String?)
    /// It no longer wants these (the person moved on).
    case withdrawn([String])
    /// The person talked over the voice: what is queued to play goes.
    case interrupted
    /// The service ended the call; nil when it was asked to.
    case closed(String?)
    /// Something it refused or failed at.
    case failed(String, code: String?)
    /// A message to send straight back (a keepalive's answer).
    case reply(String)
}

/// One engine's wire: what Redde sends it and how what it sends reads. Messages are JSON; the
/// microphone's (many a second) is built as a string on the audio queue.
nonisolated protocol LiveDialect: Sendable {
    var engine: LiveEngine { get }
    /// The microphone's audio, and the voice's, as PCM16 at these rates.
    var inputRate: Double { get }
    var outputRate: Double { get }
    /// The voice brought to about GPT-Live's level: Gemini's played twice as loud and ElevenLabs'
    /// three times, enough to be heard back in the microphone through the echo cancelling.
    var outputGain: Float { get }
    /// The agent's answer goes as it is written (GPT-Live's commentary), or whole once done, as the
    /// tool call's result (Gemini, Grok).
    var streamsAnswers: Bool { get }
    /// The service plays a sound of its own while a request it handed over is out (ElevenLabs'
    /// typing), in the voice's stream: not the voice speaking. None by default.
    var soundsWhileWaiting: Bool { get }
    /// The person's words can be written down after the voice has handed their request over (a
    /// transcription done once they've finished): a request waits a moment for them, rather than
    /// take the words of the one before (`LiveVoice.delegated`). No by default.
    var waitsForWords: Bool { get }
    /// Where a call connects with `key` (which may first be traded for a short-lived one).
    func endpoint(key: String) async throws -> LiveEndpoint
    /// What opens the session, before it says it has started.
    func opening(_ plan: LivePlan) -> [JSONValue]
    /// What follows once it has: history it takes then, a preview's line.
    func afterStart(_ plan: LivePlan, eventID: String) -> [JSONValue]
    /// A piece of the microphone's audio, base64 PCM16 at `inputRate`, as the message.
    func audio(_ base64: String) -> String
    /// The agent's answer to request `id`: a part as it comes, or the whole with `final`.
    func answer(_ text: String, to id: String, final: Bool, eventID: String) -> [JSONValue]
    /// While the agent works, something the person should hear ("still working on it").
    func update(_ text: String, to id: String, eventID: String) -> [JSONValue]
    /// While the agent works, something the voice may mention if it likes.
    func note(_ text: String, to id: String, eventID: String) -> [JSONValue]
    func mute(_ muted: Bool, eventID: String) -> [JSONValue]
    /// What ends the session, so the bill stops at once.
    func close() -> [JSONValue]
    /// One message from the service.
    func read(_ text: String) -> [LiveEvent]
}

nonisolated extension LiveDialect {
    var soundsWhileWaiting: Bool { false }
    var waitsForWords: Bool { false }
}

nonisolated extension LiveDialect {
    static func encode(_ value: JSONValue) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self)
    }
}

// MARK: - GPT-Live

/// OpenAI's GPT-Live (`wss://api.openai.com/v1/live/sessions`): `session.start` with client
/// delegation; the agent's answer as `session.commentary.append`, progress as
/// `session.thinking.append`, both naming the delegation (null included, or OpenAI refuses them).
nonisolated struct GPTLiveDialect: LiveDialect {
    var engine: LiveEngine { .gptLive }
    var inputRate: Double { LiveSetup.audioRate }
    var outputRate: Double { LiveSetup.audioRate }
    var outputGain: Float { 1 }
    var streamsAnswers: Bool { true }

    func endpoint(key: String) async throws -> LiveEndpoint { LiveEndpoint(url: LiveSetup.endpoint, headers: ["Authorization": "Bearer \(key)"]) }

    func opening(_ plan: LivePlan) -> [JSONValue] {
        var history = plan.history.map(Self.message)
        // A preview's line, as OpenAI's guide has a greeting: in the input, and again once started.
        if let greeting = plan.greeting {
            history.append(.object(["type": .string("message"), "role": .string("developer"),
                                    "content": .array([.object(["type": .string("input_text"), "text": .string(greeting.asked)])])]))
        }
        var session: [String: JSONValue] = [
            "model": .string(LiveSetup.model),
            "instructions": .string(plan.instructions),
            "audio": .object([
                "format": .object(["type": .string("audio/pcm"), "rate": .number(inputRate)]),
                "output": .object(["voice": .string(plan.voice)]),
            ]),
        ]
        if !plan.preview { session["delegation"] = .object(["type": .string("client")]) }
        if !history.isEmpty { session["input"] = .array(history) }
        return [.object(["type": .string("session.start"), "session": .object(session)])]
    }

    func afterStart(_ plan: LivePlan, eventID: String) -> [JSONValue] {
        guard let greeting = plan.greeting else { return [] }
        return [.object(["type": .string("session.commentary.append"), "event_id": .string(eventID),
                         "content": .string(greeting.asked), "delegation_id": .null])]
    }

    func audio(_ base64: String) -> String {
        "{\"type\":\"session.input_audio.append\",\"audio\":\"" + base64 + "\"}"
    }

    func answer(_ text: String, to id: String, final: Bool, eventID: String) -> [JSONValue] {
        text.isEmpty ? [] : [append("session.commentary.append", text, id, eventID)]
    }

    func update(_ text: String, to id: String, eventID: String) -> [JSONValue] {
        [append("session.commentary.append", text, id, eventID)]
    }

    func note(_ text: String, to id: String, eventID: String) -> [JSONValue] {
        [append("session.thinking.append", String(text.prefix(LiveFragment.appendLimit)), id, eventID)]
    }

    func mute(_ muted: Bool, eventID: String) -> [JSONValue] {
        [.object(["type": .string(muted ? "session.input_audio.mute" : "session.input_audio.unmute"), "event_id": .string(eventID)])]
    }

    func close() -> [JSONValue] { [.object(["type": .string("session.close")])] }

    func read(_ text: String) -> [LiveEvent] {
        // The voice's audio, many a second: read without building the whole tree.
        if text.contains("\"session.output_audio.delta\"") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let delta = object["delta"] as? String, let data = Data(base64Encoded: delta) else { return [] }
            return [.audio(data)]
        }
        guard let event = try? JSONValue.parse(Data(text.utf8)), let type = event["type"]?.string else { return [] }
        switch type {
        case "session.started":
            return [.started]
        case "session.input_transcript.delta", "session.output_transcript.delta":
            return [.transcript(type == "session.input_transcript.delta" ? .person : .voice, event["delta"]?.string ?? "",
                                startMs: event["start_ms"]?.int, endMs: event["end_ms"]?.int)]
        case "session.delegation.created":
            return event["delegation"]?["id"]?.string.map { [.delegated(id: $0, request: nil)] } ?? []
        case "error":
            return [.failed(event["error"]?["message"]?.string ?? String(localized: "OpenAI refused the call."), code: event["error"]?["code"]?.string)]
        case "session.closed":
            let reason = event["reason"]?.string ?? ""
            return [.closed(reason.isEmpty || reason == "close_requested" ? nil : reason)]
        default:
            return []
        }
    }

    private func append(_ type: String, _ content: String, _ id: String, _ eventID: String) -> JSONValue {
        .object(["type": .string(type), "content": .string(content), "delegation_id": .string(id), "event_id": .string(eventID)])
    }

    private static func message(_ line: LiveLine) -> JSONValue {
        .object(["type": .string("message"), "role": .string(line.fromPerson ? "user" : "assistant"),
                 "content": .array([.object(["type": .string(line.fromPerson ? "input_text" : "output_text"), "text": .string(line.text)])])])
    }
}

// MARK: - Hermes Live / Codex

/// Hermes Live / Codex's events, on the WebRTC data channel (`oai-events`) of a session that the
/// talk-desktop plugin on the person's Hermes set up (`HermesLiveCall`, `HermesLiveSignal`). The
/// voice hands a request over with `delegation.created`; the agent's answer goes back on
/// `delegation.context.append`, a sentence at a time as GPT-Live's commentary does, and so do the
/// notes on its progress, each naming the delegation. The session itself (its voice and
/// instructions, cutting the voice off, stopping it) is the plugin's, over the Dashboard, and the
/// sound is WebRTC's: nothing here carries audio. Transcripts are read as GPT-Live words them and
/// as OpenAI's realtime events do. Written 2026-10-30 from the plugin's routes and event names,
/// not yet tried against a real session.
nonisolated struct HermesLiveDialect: LiveDialect {
    /// Codex Live v3 voices accepted by talk-desktop's local broker. Keep this list separate from
    /// GPT-Live: selecting Marin there is valid, but the v3 broker rejects it before SDP setup.
    static let voiceGroups: [(language: String, voices: [String])] = [
        ("English", ["juniper", "maple", "spruce", "ember", "vale", "breeze", "arbor", "sol", "cove"]),
    ]
    var engine: LiveEngine { .hermesLive }
    /// WebRTC carries the sound, at rates of its own: never used.
    var inputRate: Double { 48_000 }
    var outputRate: Double { 48_000 }
    var outputGain: Float { 1 }
    var streamsAnswers: Bool { true }
    /// A transcription done once the person has finished can come after the hand-over.
    var waitsForWords: Bool { true }

    func endpoint(key: String) async throws -> LiveEndpoint {
        throw LiveFailure(String(localized: "Hermes Live / Codex calls are set up by your Hermes, with no key of Redde's."))
    }

    func opening(_ plan: LivePlan) -> [JSONValue] { [] }
    func afterStart(_ plan: LivePlan, eventID: String) -> [JSONValue] { [] }
    /// The microphone goes as WebRTC's audio, not as messages.
    func audio(_ base64: String) -> String { "" }

    func answer(_ text: String, to id: String, final: Bool, eventID: String) -> [JSONValue] {
        text.isEmpty ? [] : [append(text, id, eventID)]
    }

    func update(_ text: String, to id: String, eventID: String) -> [JSONValue] {
        [append(text, id, eventID)]
    }

    func note(_ text: String, to id: String, eventID: String) -> [JSONValue] {
        [append(String(text.prefix(LiveFragment.appendLimit)), id, eventID)]
    }

    /// The microphone is shut on the phone (its track off), not by a message.
    func mute(_ muted: Bool, eventID: String) -> [JSONValue] { [] }
    /// Stopping is the plugin's (`/codexlive/stop`, asked as the call closes).
    func close() -> [JSONValue] { [] }

    func read(_ text: String) -> [LiveEvent] {
        guard let event = try? JSONValue.parse(Data(text.utf8)), let type = event["type"]?.string else { return [] }
        switch type {
        case "session.created", "session.started":
            return [.started]
        case "delegation.created", "session.delegation.created":
            // Codex Live v3 puts a client-managed delegation in `item`, not the legacy
            // `delegation` object. Retain the latter for compatible brokers, but prefer the
            // v3 item and its authoritative input_text content.
            let delegation = event["item"] ?? event["delegation"]
            guard let id = (delegation?["id"] ?? event["delegation_id"] ?? event["delegationId"])?.string, !id.isEmpty else { return [] }
            let content = delegation?["content"]?.array?.compactMap { $0["text"]?.string }
                .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let request = (!((content ?? "").isEmpty) ? content : Self.requestKeys.lazy.compactMap { (delegation?[$0] ?? event[$0])?.string }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            return [.delegated(id: id, request: request)]
        case "delegation.cancelled", "delegation.canceled":
            let id = (event["delegation"]?["id"] ?? event["delegation_id"] ?? event["delegationId"])?.string
            return id.map { [.withdrawn([$0])] } ?? []
        case "input_transcript.added":
            // Codex Live v3's frameless wire carries the growing transcript in `item.text`,
            // rather than the older `delta` field. Keep it as a live fragment so a later
            // client-managed delegation is grounded in what was actually said.
            let words = event["item"]?["text"]?.string ?? event["text"]?.string ?? ""
            return words.isEmpty ? [] : [.transcript(.person, words, startMs: nil, endMs: nil)]
        case "output_transcript.added":
            let words = event["item"]?["text"]?.string ?? event["text"]?.string ?? ""
            return words.isEmpty ? [] : [.transcript(.voice, words, startMs: nil, endMs: nil)]
        case "session.input_transcript.delta", "input_transcript.delta":
            return [.transcript(.person, event["delta"]?.string ?? "", startMs: event["start_ms"]?.int, endMs: event["end_ms"]?.int)]
        case "session.output_transcript.delta", "output_transcript.delta", "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            return [.transcript(.voice, event["delta"]?.string ?? "", startMs: event["start_ms"]?.int, endMs: event["end_ms"]?.int)]
        case "conversation.item.input_audio_transcription.completed":
            // Whole, once the person has finished: a space after it, so the next isn't run into it.
            let words = event["transcript"]?.string ?? ""
            return words.isEmpty ? [] : [.transcript(.person, words + " ", startMs: nil, endMs: nil)]
        case "error":
            return [.failed(event["error"]?["message"]?.string ?? String(localized: "Hermes Live / Codex refused something Redde sent."),
                            code: event["error"]?["code"]?.string)]
        case "session.closed", "session.ended":
            let reason = event["reason"]?.string ?? ""
            return [.closed(reason.isEmpty || reason == "close_requested" ? nil : reason)]
        default:
            return []
        }
    }

    /// Where a delegation may carry the voice's own wording of the request.
    private static let requestKeys = ["request", "prompt", "input", "instructions", "task", "text", "query"]

    private func append(_ content: String, _ id: String, _ eventID: String) -> JSONValue {
        // Codex v3 accepts the result only on its client-managed handoff item. The legacy
        // delegation_id/string shape silently leaves the focused Hermes chat's answer unheard.
        .object(["type": .string("delegation.context.append"), "delegation_item_id": .string(id),
                 "content": .array([.object(["type": .string("input_text"), "text": .string(content)])])])
    }
}
