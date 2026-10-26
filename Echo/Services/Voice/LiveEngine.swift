import Foundation

/// Who holds a live voice call (Settings → Voice → Voice mode, or a bot's own): OpenAI's
/// GPT-Live, Google's Gemini Live, xAI's Grok Voice or an ElevenLabs voice agent. Each is a WebSocket on Apple's TLS straight
/// from the phone, with a key of its own kept in Redde, and speaks a wire of its own
/// (`LiveDialect`); the rest of a call, the audio, the screen, handing requests to the agent, is
/// the same for all (`LiveCall`, `LiveVoice`). Gemini and Grok asked 2026-10-25, for cost; then
/// ElevenLabs, for its voices.
nonisolated enum LiveEngine: String, CaseIterable, Codable, Sendable {
    case gptLive, gemini, grok, elevenLabs

    var name: String {
        switch self {
        case .gptLive: "GPT-Live"
        case .gemini: "Gemini Live"
        case .grok: "Grok Voice"
        case .elevenLabs: "ElevenLabs"
        }
    }

    var company: String {
        switch self {
        case .gptLive: "OpenAI"
        case .gemini: "Google"
        case .grok: "xAI"
        case .elevenLabs: "ElevenLabs"
        }
    }

    /// Its key, kept in Redde (and synced with iCloud Keychain like the others).
    var keyItem: Keychain.Item {
        switch self {
        case .gptLive: .openAILive
        case .gemini: .geminiLive
        case .grok: .grokVoice
        case .elevenLabs: .elevenLabsLive
        }
    }

    var dialect: any LiveDialect {
        switch self {
        case .gptLive: GPTLiveDialect()
        case .gemini: GeminiLiveDialect()
        case .grok: GrokVoiceDialect()
        case .elevenLabs: ElevenLabsDialect()
        }
    }

    /// Its voices by the language each speaks, the default first.
    var voiceGroups: [(language: String, voices: [String])] {
        switch self {
        case .gptLive: LiveSetup.voiceGroups
        case .gemini: GeminiLiveDialect.voiceGroups
        case .grok: GrokVoiceDialect.voiceGroups
        case .elevenLabs: []
        }
    }

    var voices: [String] { voiceGroups.flatMap(\.voices) }
    /// Its voices are the person's account's, listed when picked (`ElevenLabsVoice`), not Redde's to know.
    var voicesFromAccount: Bool { self == .elevenLabs }
    /// The voice nothing picked gives it; none for ElevenLabs: its agent's own.
    var defaultVoice: String { voices.first ?? "" }

    /// A voice to show, by its id.
    func voiceName(_ voice: String) -> String {
        guard voicesFromAccount else { return voice.capitalized }
        return voice.isEmpty ? "The agent's own" : ElevenLabsVoice.name(voice) ?? "A voice of yours"
    }

    /// How its company describes a voice, where it does.
    func style(of voice: String) -> String? {
        switch self {
        case .gptLive: nil
        case .gemini: GeminiLiveDialect.styles[voice]
        case .grok: GrokVoiceDialect.styles[voice]
        case .elevenLabs: nil
        }
    }

    /// What a call costs, for its settings.
    var cost: String {
        switch self {
        case .gptLive: "OpenAI bills the key's account $0.05 a minute, quiet minutes too."
        case .gemini: "Google bills the key's account about $0.005 a minute for what you say and $0.018 a minute for what the voice says (about $0.12 for ten minutes); a free tier is offered, whose conversations Google may use to improve its products."
        case .grok: "xAI bills the key's account $0.08 a minute."
        case .elevenLabs: "ElevenLabs bills the key's account by the minute past what its plan includes ($0.08 a minute), with the agent's language model on top; silence past ten seconds at a twentieth of that. The first call makes a voice agent named Redde voice in your ElevenLabs account."
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
            return [.failed(event["error"]?["message"]?.string ?? "OpenAI refused the call.", code: event["error"]?["code"]?.string)]
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
