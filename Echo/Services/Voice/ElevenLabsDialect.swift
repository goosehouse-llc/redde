import CryptoKit
import Foundation
import os

/// ElevenLabs' voice agents (`wss://api.elevenlabs.io/v1/convai/conversation`): a call runs an
/// agent kept in the person's ElevenLabs account, which Redde makes the first time ("Redde voice",
/// with the one client tool, sign-in required, the prompt, voice and first line overridable) and
/// remembers by the key's fingerprint; each call then gets a short-lived signed address with the
/// key, opens with `conversation_initiation_client_data` (the persona and the conversation so far
/// as the prompt, the voice), and is answered `conversation_initiation_metadata`. The microphone as
/// `user_audio_chunk` at 16 kHz, the voice back as `audio` at 24 kHz; the agent's answer a
/// `client_tool_result`. Read from ElevenLabs' docs and SDKs, 2026-10-25.
nonisolated struct ElevenLabsDialect: LiveDialect {
    static let host = "https://api.elevenlabs.io"
    /// Which agent Redde makes; a new one when what it asks of an agent changes.
    static let agentVersion = 1
    /// The settings Redde keeps on its agent, brought up to date on one made before (`settle`).
    static let settingsRevision = 4
    /// Patient turn-taking: ElevenLabs answered as the person was finishing a sentence, and their
    /// last words cut it short (Marta, 2026-10-25). And its longest wait for the person before it
    /// asks "are you still there?": it counts from when it has sent its last words, seconds before
    /// they have played here, so 7 came three seconds after an answer was heard.
    static let turnSettings: JSONValue = .object(["turn_eagerness": .string("patient"), "turn_timeout": .number(30)])
    /// What ElevenLabs keeps of a call: nothing it can be told not to (asked 2026-10-27, "as
    /// private as possible"). No recording, and the transcript and anything personal in it deleted
    /// once the call is over (its default: all of it, for two years). Calls made before are left as
    /// they were. Redde never reads a call back from ElevenLabs. What it sees during one, it must:
    /// the person's voice, the chat so far, the agent's answers. (Zero retention and redaction,
    /// which would cover more, are for its Enterprise customers only.)
    static let privacy: JSONValue = .object([
        "record_voice": .bool(false),
        "retention_days": .number(0),
        "delete_transcript_and_pii": .bool(true),
        "delete_audio": .bool(true),
    ])
    /// The agent's platform settings: a signed URL to call it, the prompt, first words, language and
    /// voice set per call, and `privacy`.
    static let platformSettings: JSONValue = .object([
        "auth": .object(["enable_auth": .bool(true)]),
        "overrides": .object(["conversation_config_override": .object([
            "agent": .object(["first_message": .bool(true), "language": .bool(true), "prompt": .object(["prompt": .bool(true)])]),
            "tts": .object(["voice_id": .bool(true)]),
        ])]),
        "privacy": privacy,
    ])

    var engine: LiveEngine { .elevenLabs }
    var inputRate: Double { 16_000 }
    var outputRate: Double { 24_000 }
    var outputGain: Float { 0.35 }
    var streamsAnswers: Bool { false }
    /// Its tool plays a typing sound while it waits (`tool_call_sound`).
    var soundsWhileWaiting: Bool { true }

    /// The voice's audio from before the person's last interruption still arriving: dropped.
    private let heard = OSAllocatedUnfairLock(initialState: -1)

    func endpoint(key: String) async throws -> LiveEndpoint {
        var agent = try await Self.agent(key: key)
        await Self.settle(agent: agent, key: key)
        var signed = try? await Self.signedURL(agent: agent, key: key)
        // The agent was deleted in ElevenLabs: made again, once.
        if signed == nil {
            Self.forget(key: key)
            agent = try await Self.agent(key: key)
            signed = try await Self.signedURL(agent: agent, key: key)
        }
        guard let signed else { throw LiveFailure(String(localized: "ElevenLabs didn't open a conversation.")) }
        return LiveEndpoint(url: signed)
    }

    func opening(_ plan: LivePlan) -> [JSONValue] {
        var prompt = plan.instructions
        if !plan.history.isEmpty {
            prompt += "\n\nThe conversation so far, newest last:\n"
                + plan.history.map { "\($0.fromPerson ? "User" : "Assistant"): \($0.text)" }.joined(separator: "\n")
        }
        // The agent's answer comes back as the tool's result: said near enough as it is.
        if plan.agent != nil { prompt += "\n\nWhen \(LiveAgentTool.name) returns, say its result to the user closely, in a natural voice." }
        var agent: [String: JSONValue] = [
            "prompt": .object(["prompt": .string(prompt)]),
            // Its first words: a preview's line, said as it is; a call starts by listening.
            "first_message": .string(plan.greeting?.line ?? ""),
        ]
        if plan.greeting != nil { agent["language"] = .string("en") }
        var override: [String: JSONValue] = ["agent": .object(agent)]
        if !plan.voice.isEmpty { override["tts"] = .object(["voice_id": .string(plan.voice)]) }
        return [.object(["type": .string("conversation_initiation_client_data"), "conversation_config_override": .object(override)])]
    }

    func afterStart(_ plan: LivePlan, eventID: String) -> [JSONValue] { [] }

    func audio(_ base64: String) -> String { "{\"user_audio_chunk\":\"" + base64 + "\"}" }

    func answer(_ text: String, to id: String, final: Bool, eventID: String) -> [JSONValue] {
        guard final else { return [] }
        return [.object(["type": .string("client_tool_result"), "tool_call_id": .string(id), "result": .string(text), "is_error": .bool(false)])]
    }

    /// Nothing is said while the tool waits (ElevenLabs plays a typing sound meanwhile); the agent
    /// is told, quietly, so it can say so if asked.
    func update(_ text: String, to id: String, eventID: String) -> [JSONValue] {
        [.object(["type": .string("contextual_update"), "text": .string(text), "context_id": .string("progress")])]
    }

    func note(_ text: String, to id: String, eventID: String) -> [JSONValue] { [] }

    func mute(_ muted: Bool, eventID: String) -> [JSONValue] { [] }
    func close() -> [JSONValue] { [] }

    func read(_ text: String) -> [LiveEvent] {
        // The voice's audio, many a second: read without building the whole tree.
        if text.contains("\"audio_event\"") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let event = object["audio_event"] as? [String: Any],
                  let base64 = event["audio_base_64"] as? String, let data = Data(base64Encoded: base64) else { return [] }
            let id = event["event_id"] as? Int ?? Int.max
            guard id > heard.withLock({ $0 }) else { return [] }
            return [.audio(data)]
        }
        guard let event = try? JSONValue.parse(Data(text.utf8)), let type = event["type"]?.string else { return [] }
        switch type {
        case "conversation_initiation_metadata":
            return [.started]
        case "user_transcript":
            let said = event["user_transcription_event"]?["user_transcript"]?.string ?? ""
            return said.isEmpty ? [] : [.transcript(.person, said + " ", startMs: nil, endMs: nil)]
        case "agent_response":
            let said = event["agent_response_event"]?["agent_response"]?.string ?? ""
            return said.isEmpty ? [] : [.transcript(.voice, said + " ", startMs: nil, endMs: nil)]
        case "interruption":
            if let id = event["interruption_event"]?["event_id"]?.int { heard.withLock { $0 = max($0, id) } }
            return [.interrupted]
        case "client_tool_call":
            let call = event["client_tool_call"]
            guard call?["tool_name"]?.string == LiveAgentTool.name, let id = call?["tool_call_id"]?.string else { return [] }
            return [.delegated(id: id, request: call?["parameters"]?["request"]?.string)]
        case "ping":
            let id = event["ping_event"]?["event_id"] ?? .null
            return [.reply(Self.encode(.object(["type": .string("pong"), "event_id": id])))]
        case "client_error", "error":
            let error = event["error_event"] ?? event["client_error"] ?? event
            return [.failed(error["message"]?.string ?? String(localized: "ElevenLabs refused the call."), code: error["code"]?.string ?? error["error_name"]?.string)]
        default:
            return []
        }
    }

    // MARK: - The agent

    /// Redde's agent for this key: made the first time, then remembered (by the key's fingerprint,
    /// never the key) on this device.
    static func agent(key: String) async throws -> String {
        if let known = UserDefaults.standard.dictionary(forKey: agentsKey)?[fingerprint(key)] as? String { return known }
        // The tool, made once: an agent refused after it was made doesn't leave one more each try.
        let tool = try await madeTool(key: key)
        var prompt: [String: JSONValue] = ["prompt": .string("You are a calm and friendly voice assistant."), "temperature": .number(0),
                                           "tool_ids": .array([.string(tool)])]
        if let model = await model(key: key) { prompt["llm"] = .string(model) }
        let events = ["conversation_initiation_metadata", "ping", "audio", "interruption", "user_transcript", "agent_response",
                      "agent_response_correction", "client_tool_call", "agent_tool_response", "client_error"]
        let agent = try await create("/v1/convai/agents/create", key: key, body: .object([
            "name": .string("Redde voice"),
            "conversation_config": .object([
                "agent": .object([
                    "first_message": .string(""),
                    "language": .string("en"),
                    "prompt": .object(prompt),
                ]),
                // ElevenLabs: "English agents must use turbo or flash v2" (v2.5 refused, 2026-10-25).
                "tts": .object(["model_id": .string("eleven_flash_v2"), "agent_output_audio_format": .string("pcm_24000")]),
                "asr": .object(["user_input_audio_format": .string("pcm_16000")]),
                "turn": turnSettings,
                "conversation": .object(["max_duration_seconds": .number(3_600), "client_events": .array(events.map { .string($0) })]),
            ]),
            "platform_settings": platformSettings,
        ]), field: "agent_id")
        var known = UserDefaults.standard.dictionary(forKey: agentsKey) ?? [:]
        known[fingerprint(key)] = agent
        UserDefaults.standard.set(known, forKey: agentsKey)
        remember(settingsRevision, key: key)
        return agent
    }

    /// An agent made before Redde's latest settings for it gets them, once (a PATCH of just those:
    /// its turn-taking, and its platform settings whole, privacy with them). A failure is let be:
    /// the call goes on, and the next one tries again.
    static func settle(agent: String, key: String) async {
        let had = UserDefaults.standard.dictionary(forKey: revisionsKey)?[fingerprint(key)] as? Int ?? 1
        guard had < settingsRevision else { return }
        var request = URLRequest(url: URL(string: host + "/v1/convai/agents/" + agent)!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(JSONValue.object([
            "conversation_config": .object(["turn": turnSettings]),
            "platform_settings": platformSettings,
        ]))
        do {
            _ = try await call(request, key: key)
        } catch {
            #if DEBUG
            let said = error.localizedDescription
            Task { @MainActor in LiveMeasure.write("ElevenLabs agent settings not updated (tried again next call): \(said)") }
            #endif
            return
        }
        remember(settingsRevision, key: key)
        #if DEBUG
        Task { @MainActor in LiveMeasure.write("ElevenLabs agent settings updated to revision \(settingsRevision)") }
        #endif
    }

    private static func remember(_ revision: Int, key: String) {
        var known = UserDefaults.standard.dictionary(forKey: revisionsKey) ?? [:]
        known[fingerprint(key)] = revision
        UserDefaults.standard.set(known, forKey: revisionsKey)
    }

    /// The agent's language model: it chats, hands requests over and says the answers, the agent
    /// doing the work, so the newest fast one ElevenLabs offers that isn't being retired (2.5 Flash,
    /// first picked, was by 2026-10-25). Nil, when the list can't be had: ElevenLabs' own default.
    private static func model(key: String) async -> String? {
        let preferred = ["gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.5-flash",
                         "gemini-3.5-flash-lite", "gemini-3.1-flash-lite"]
        guard let reply = try? await call(URLRequest(url: URL(string: host + "/v1/convai/llm/list")!), key: key) else { return nil }
        let current = Set((reply["llms"]?.array ?? []).compactMap { entry -> String? in
            let retiring = entry["deprecation_info"]?["is_deprecated"]?.bool == true || entry["deprecation_info"]?["is_in_warning_period"]?.bool == true
            return retiring ? nil : entry["llm"]?.string
        })
        return preferred.first(where: current.contains)
    }

    private static func madeTool(key: String) async throws -> String {
        if let known = UserDefaults.standard.dictionary(forKey: toolsKey)?[fingerprint(key)] as? String { return known }
        let tool = try await create("/v1/convai/tools", key: key, body: .object(["tool_config": .object([
            "type": .string("client"),
            "name": .string(LiveAgentTool.name),
            "description": .string(LiveAgentTool(agentName: "the user's agent").description),
            "parameters": .object([
                "type": .string("object"),
                "properties": .object(["request": .object(["type": .string("string"), "description": .string(LiveAgentTool.requestDescription)])]),
                "required": .array([.string("request")]),
            ]),
            "expects_response": .bool(true),
            // The agent may take minutes (a cold model): no time limit.
            "response_timeout_secs": .number(-1),
            "pre_tool_speech": .string("force"),
            "tool_call_sound": .string("typing"),
            "interruption_mode": .string("allow"),
            "execution_mode": .string("immediate"),
        ])]), field: "id")
        var known = UserDefaults.standard.dictionary(forKey: toolsKey) ?? [:]
        known[fingerprint(key)] = tool
        UserDefaults.standard.set(known, forKey: toolsKey)
        return tool
    }

    /// The agent gone from the account (deleted there): made again, its tool too.
    static func forget(key: String) {
        for store in [agentsKey, toolsKey] {
            var known = UserDefaults.standard.dictionary(forKey: store) ?? [:]
            known[fingerprint(key)] = nil
            UserDefaults.standard.set(known, forKey: store)
        }
    }

    private static let agentsKey = "elevenLabsAgents.v\(agentVersion)"
    private static let toolsKey = "elevenLabsTools.v\(agentVersion)"
    private static let revisionsKey = "elevenLabsAgentSettings.v\(agentVersion)"

    private static func fingerprint(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func signedURL(agent: String, key: String) async throws -> URL {
        var parts = URLComponents(string: host + "/v1/convai/conversation/get-signed-url")!
        parts.queryItems = [URLQueryItem(name: "agent_id", value: agent)]
        let reply = try await call(URLRequest(url: parts.url!), key: key)
        guard let url = reply["signed_url"]?.string.flatMap(URL.init(string:)) else { throw LiveFailure(String(localized: "ElevenLabs didn't open a conversation.")) }
        return url
    }

    private static func create(_ path: String, key: String, body: JSONValue, field: String) async throws -> String {
        var request = URLRequest(url: URL(string: host + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let reply = try await call(request, key: key)
        guard let id = reply[field]?.string else { throw LiveFailure(String(localized: "ElevenLabs didn't make Redde's voice agent.")) }
        return id
    }

    private static func call(_ request: URLRequest, key: String) async throws -> JSONValue {
        var request = request
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let reply = (try? JSONValue.parse(data)) ?? .null
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else {
            let said = reply["detail"]?["message"]?.string ?? reply["detail"]?.string ?? reply["message"]?.string
            throw LiveFailure(said.map { String(localized: "ElevenLabs refused: \($0)") } ?? String(localized: "ElevenLabs refused the key."))
        }
        return reply
    }
}

/// A voice in the person's ElevenLabs account, for the voice list: its own sample is the preview.
nonisolated struct ElevenLabsVoice: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var detail: String?
    var sample: URL?

    /// The account's voices (`GET /v2/voices`), the names kept for showing a picked one later.
    static func all(key: String) async throws -> [ElevenLabsVoice] {
        var request = URLRequest(url: URL(string: ElevenLabsDialect.host + "/v2/voices?page_size=100")!)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let reply = try? JSONValue.parse(data) else {
            throw LiveFailure(String(localized: "ElevenLabs didn't list the voices."))
        }
        let voices = (reply["voices"]?.array ?? []).compactMap { voice -> ElevenLabsVoice? in
            guard let id = voice["voice_id"]?.string, let name = voice["name"]?.string else { return nil }
            let labels = voice["labels"]?.object.map { $0.values.compactMap(\.string).joined(separator: ", ") }
            return ElevenLabsVoice(id: id, name: name, detail: voice["description"]?.string?.nilIfEmpty ?? labels?.nilIfEmpty,
                                   sample: voice["preview_url"]?.string.flatMap(URL.init(string:)))
        }
        var names = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        for voice in voices { names[voice.id] = voice.name }
        UserDefaults.standard.set(names, forKey: namesKey)
        return voices
    }

    /// A picked voice's name, as last listed.
    static func name(_ id: String) -> String? { (UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String])?[id] }

    private static let namesKey = "elevenLabsVoiceNames"
}
