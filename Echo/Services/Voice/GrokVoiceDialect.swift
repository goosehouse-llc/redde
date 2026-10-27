import Foundation

/// xAI's Grok Voice (`wss://api.x.ai/v1/realtime`, OpenAI's Realtime events with extensions):
/// the key traded first for a short-lived secret, which goes as the WebSocket's subprotocol
/// (xAI's own iOS sample: URLSession drops an Authorization header on the upgrade);
/// `session.update` with the instructions (the conversation so far in them: an item sent
/// separately costs $0.004), the voice, server turn detection and PCM16 both ways; the agent as
/// one function, its answer a `function_call_output` and then `response.create`. Read from
/// docs.x.ai and xAI's cookbook, 2026-10-25 (grok-voice-3.0).
nonisolated struct GrokVoiceDialect: LiveDialect {
    static let model = "grok-voice-3.0"
    static let host = URL(string: "wss://api.x.ai/v1/realtime")!
    static let secrets = URL(string: "https://api.x.ai/v1/realtime/client_secrets")!

    /// Its voices, each speaking every language it has (it hears which); Eve, its default, first.
    static let voiceGroups: [(language: String, voices: [String])] = [
        ("Any language", ["eve", "ara", "rex", "sal", "leo", "carina", "zagan", "helix", "orion", "luna", "iris", "altair",
                          "zenith", "perseus", "helios", "lux", "kepler", "rigel", "cosmo", "celeste", "ursa", "sirius",
                          "lumen", "castor", "naksh", "atlas", "aurora", "liora"]),
    ]
    /// How xAI describes the ones it does.
    static let styles: [String: String] = [
        "eve": String(localized: "Energetic, British", comment: "How xAI describes one of its voices"),
        "ara": String(localized: "Warm, friendly", comment: "How xAI describes one of its voices"),
        "rex": String(localized: "Confident, clear", comment: "How xAI describes one of its voices"),
        "sal": String(localized: "Smooth, balanced", comment: "How xAI describes one of its voices"),
        "leo": String(localized: "Authoritative, British", comment: "How xAI describes one of its voices"),
        "rigel": String(localized: "Australian", comment: "How xAI describes one of its voices"),
        "naksh": String(localized: "Indian", comment: "How xAI describes one of its voices"),
    ]

    var engine: LiveEngine { .grok }
    var inputRate: Double { 16_000 }
    var outputRate: Double { 24_000 }
    /// Not yet heard on a phone: as it comes.
    var outputGain: Float { 1 }
    var streamsAnswers: Bool { false }

    func endpoint(key: String) async throws -> LiveEndpoint {
        var request = URLRequest(url: Self.secrets)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"expires_after":{"seconds":300}}"#.utf8)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let reply = try? JSONValue.parse(data)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let secret = reply?["value"]?.string else {
            let said = reply?["error"]?["message"]?.string ?? reply?["error"]?.string ?? reply?["message"]?.string
            throw LiveFailure(said.map { String(localized: "xAI didn't take the key: \($0)") } ?? String(localized: "xAI didn't take the key."))
        }
        var parts = URLComponents(url: Self.host, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "model", value: Self.model)]
        return LiveEndpoint(url: parts.url!, headers: ["Sec-WebSocket-Protocol": "xai-client-secret.\(secret)"])
    }

    func opening(_ plan: LivePlan) -> [JSONValue] {
        var instructions = plan.instructions
        if !plan.history.isEmpty {
            instructions += "\n\nThe conversation so far, newest last:\n"
                + plan.history.map { "\($0.fromPerson ? "User" : "Assistant"): \($0.text)" }.joined(separator: "\n")
        }
        var session: [String: JSONValue] = [
            "instructions": .string(instructions),
            "voice": .string(plan.voice),
            "reasoning": .object(["effort": .string("none")]),
            "turn_detection": .object(["type": .string("server_vad")]),
            "audio": .object([
                // What the person says written down too: for the chat, and what a request refers to.
                "input": .object(["format": .object(["type": .string("audio/pcm"), "rate": .number(inputRate)]),
                                  "transcription": .object(["model": .string("grok-transcribe")])]),
                "output": .object(["format": .object(["type": .string("audio/pcm"), "rate": .number(outputRate)])]),
            ]),
        ]
        if let agent = plan.agent {
            session["tools"] = .array([.object([
                "type": .string("function"),
                "name": .string(LiveAgentTool.name),
                "description": .string(agent.description),
                "parameters": .object([
                    "type": .string("object"),
                    "properties": .object(["request": .object(["type": .string("string"), "description": .string(LiveAgentTool.requestDescription)])]),
                    "required": .array([.string("request")]),
                ]),
            ])])
        }
        return [.object(["type": .string("session.update"), "session": .object(session)])]
    }

    /// A preview's line, word for word: xAI's `force_message`, which it speaks without being asked.
    func afterStart(_ plan: LivePlan, eventID: String) -> [JSONValue] {
        guard let greeting = plan.greeting else { return [] }
        return [.object(["type": .string("conversation.item.create"), "item": .object([
            "type": .string("force_message"), "role": .string("assistant"), "interruptible": .bool(true),
            "content": .array([.object(["type": .string("output_text"), "text": .string(greeting.line)])]),
        ])])]
    }

    func audio(_ base64: String) -> String {
        "{\"type\":\"input_audio_buffer.append\",\"audio\":\"" + base64 + "\"}"
    }

    func answer(_ text: String, to id: String, final: Bool, eventID: String) -> [JSONValue] {
        guard final else { return [] }
        return [
            .object(["type": .string("conversation.item.create"), "item": .object([
                "type": .string("function_call_output"), "call_id": .string(id), "output": .string(text),
            ])]),
            .object(["type": .string("response.create")]),
        ]
    }

    /// No documented way to say something while a call waits on its tool: a note from the app, and
    /// a response asked for (xAI's guide words interim results so).
    func update(_ text: String, to id: String, eventID: String) -> [JSONValue] {
        [
            .object(["type": .string("conversation.item.create"), "item": .object([
                "type": .string("message"), "role": .string("system"),
                "content": .array([.object(["type": .string("input_text"),
                                            "text": .string("\(text) Tell the user that in a few words, without guessing the answer.")])]),
            ])]),
            .object(["type": .string("response.create")]),
        ]
    }

    func note(_ text: String, to id: String, eventID: String) -> [JSONValue] { [] }

    /// The microphone held shut sends nothing; server turn detection hears nothing.
    func mute(_ muted: Bool, eventID: String) -> [JSONValue] { [] }
    /// No close event: the socket closing ends it (and its billing).
    func close() -> [JSONValue] { [] }

    func read(_ text: String) -> [LiveEvent] {
        // The voice's audio, many a second: read without building the whole tree.
        if text.contains("\"response.output_audio.delta\"") || text.contains("\"response.audio.delta\"") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let delta = object["delta"] as? String, let data = Data(base64Encoded: delta) else { return [] }
            return [.audio(data)]
        }
        guard let event = try? JSONValue.parse(Data(text.utf8)), let type = event["type"]?.string else { return [] }
        switch type {
        case "session.updated":
            return [.started]
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            return [.transcript(.voice, event["delta"]?.string ?? "", startMs: nil, endMs: nil)]
        case "conversation.item.input_audio_transcription.completed":
            return [.transcript(.person, (event["transcript"]?.string ?? "") + " ", startMs: nil, endMs: nil)]
        case "input_audio_buffer.speech_started":
            return [.interrupted]
        case "response.function_call_arguments.done":
            guard event["name"]?.string == LiveAgentTool.name, let id = event["call_id"]?.string else { return [] }
            let arguments = event["arguments"]?.string.flatMap { try? JSONValue.parse(Data($0.utf8)) }
            return [.delegated(id: id, request: arguments?["request"]?.string)]
        case "ping":
            let stamp = event["ping_timestamp"] ?? .null
            return [.reply(Self.encode(.object(["type": .string("pong"), "ping_timestamp": stamp])))]
        case "error":
            let error = event["error"] ?? event
            let kind = error["type"]?.string
            let message = error["message"]?.string ?? String(localized: "xAI refused the call.")
            if kind == "max_duration" { return [.closed("max_duration")] }
            return [.failed(message, code: error["code"]?.string ?? kind)]
        default:
            return []
        }
    }
}
