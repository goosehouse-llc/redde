import Foundation

/// Google's Gemini Live (`BidiGenerateContent` over a WebSocket, the key in its address): a
/// `setup` first, answered `setupComplete`; the microphone as `realtimeInput.audio` at 16 kHz, the
/// voice back at 24 kHz in `serverContent.modelTurn`; the agent as one NON_BLOCKING function, so
/// the voice can go on talking while it works, its answer the `toolResponse`, spoken when the
/// voice is idle. Read from Google's Live API pages, 2026-10-25 (gemini-3.8-live). A connection
/// lasts about ten minutes (`goAway`), which is a call's limit for now.
nonisolated struct GeminiLiveDialect: LiveDialect {
    static let model = "models/gemini-3.8-live"
    static let host = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    /// Its voices (Google's text-to-speech ones, which the Live model speaks), each in any
    /// language: the model picks the language from what is said. Puck, its usual default, first.
    static let voiceGroups: [(language: String, voices: [String])] = [
        ("Any language", ["Puck", "Kore", "Charon", "Aoede", "Fenrir", "Leda", "Orus", "Zephyr", "Callirrhoe", "Autonoe",
                          "Enceladus", "Iapetus", "Umbriel", "Algieba", "Despina", "Erinome", "Algenib", "Rasalgethi",
                          "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima", "Achird", "Zubenelgenubi",
                          "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat"]),
    ]
    /// How Google describes each.
    static let styles: [String: String] = [
        "Zephyr": String(localized: "Bright", comment: "How Google describes one of its voices"),
        "Puck": String(localized: "Upbeat", comment: "How Google describes one of its voices"),
        "Charon": String(localized: "Informative", comment: "How Google describes one of its voices"),
        "Kore": String(localized: "Firm", comment: "How Google describes one of its voices"),
        "Fenrir": String(localized: "Excitable", comment: "How Google describes one of its voices"),
        "Leda": String(localized: "Youthful", comment: "How Google describes one of its voices"),
        "Orus": String(localized: "Firm", comment: "How Google describes one of its voices"),
        "Aoede": String(localized: "Breezy", comment: "How Google describes one of its voices"),
        "Callirrhoe": String(localized: "Easy-going", comment: "How Google describes one of its voices"),
        "Autonoe": String(localized: "Bright", comment: "How Google describes one of its voices"),
        "Enceladus": String(localized: "Breathy", comment: "How Google describes one of its voices"),
        "Iapetus": String(localized: "Clear", comment: "How Google describes one of its voices"),
        "Umbriel": String(localized: "Easy-going", comment: "How Google describes one of its voices"),
        "Algieba": String(localized: "Smooth", comment: "How Google describes one of its voices"),
        "Despina": String(localized: "Smooth", comment: "How Google describes one of its voices"),
        "Erinome": String(localized: "Clear", comment: "How Google describes one of its voices"),
        "Algenib": String(localized: "Gravelly", comment: "How Google describes one of its voices"),
        "Rasalgethi": String(localized: "Informative", comment: "How Google describes one of its voices"),
        "Laomedeia": String(localized: "Upbeat", comment: "How Google describes one of its voices"),
        "Achernar": String(localized: "Soft", comment: "How Google describes one of its voices"),
        "Alnilam": String(localized: "Firm", comment: "How Google describes one of its voices"),
        "Schedar": String(localized: "Even", comment: "How Google describes one of its voices"),
        "Gacrux": String(localized: "Mature", comment: "How Google describes one of its voices"),
        "Pulcherrima": String(localized: "Forward", comment: "How Google describes one of its voices"),
        "Achird": String(localized: "Friendly", comment: "How Google describes one of its voices"),
        "Zubenelgenubi": String(localized: "Casual", comment: "How Google describes one of its voices"),
        "Vindemiatrix": String(localized: "Gentle", comment: "How Google describes one of its voices"),
        "Sadachbia": String(localized: "Lively", comment: "How Google describes one of its voices"),
        "Sadaltager": String(localized: "Knowledgeable", comment: "How Google describes one of its voices"),
        "Sulafat": String(localized: "Warm", comment: "How Google describes one of its voices"),
    ]

    var engine: LiveEngine { .gemini }
    var inputRate: Double { 16_000 }
    var outputRate: Double { 24_000 }
    var outputGain: Float { 0.5 }
    var streamsAnswers: Bool { false }

    func endpoint(key: String) async throws -> LiveEndpoint {
        var parts = URLComponents(string: Self.host)!
        parts.queryItems = [URLQueryItem(name: "key", value: key)]
        return LiveEndpoint(url: parts.url!)
    }

    func opening(_ plan: LivePlan) -> [JSONValue] {
        var setup: [String: JSONValue] = [
            "model": .string(Self.model),
            "generationConfig": .object([
                "responseModalities": .array([.string("AUDIO")]),
                "speechConfig": .object(["voiceConfig": .object(["prebuiltVoiceConfig": .object(["voiceName": .string(plan.voice)])])]),
            ]),
            "systemInstruction": .object(["parts": .array([.object(["text": .string(plan.instructions)])])]),
            "inputAudioTranscription": .object([:]),
            "outputAudioTranscription": .object([:]),
            // Patient, as ElevenLabs' agent was made after it answered while the person was still
            // finishing (2026-10-25): a second of quiet before it answers, and less taken by a noise
            // for the start of speech (the room's voices were heard as the person's).
            "realtimeInputConfig": .object([
                "automaticActivityDetection": .object([
                    "disabled": .bool(false), "silenceDurationMs": .number(1_000), "prefixPaddingMs": .number(200),
                    "startOfSpeechSensitivity": .string("START_SENSITIVITY_LOW"), "endOfSpeechSensitivity": .string("END_SENSITIVITY_LOW"),
                ]),
                "activityHandling": .string("START_OF_ACTIVITY_INTERRUPTS"),
            ]),
            // A long call's context kept short, so it isn't cut off (and isn't billed again whole each turn).
            "contextWindowCompression": .object(["triggerTokens": .number(25_000), "slidingWindow": .object(["targetTokens": .number(8_000)])]),
        ]
        if let agent = plan.agent {
            setup["tools"] = .array([.object(["functionDeclarations": .array([.object([
                "name": .string(LiveAgentTool.name),
                "description": .string(agent.description),
                "behavior": .string("NON_BLOCKING"),
                "parameters": .object([
                    "type": .string("OBJECT"),
                    "properties": .object(["request": .object(["type": .string("STRING"), "description": .string(LiveAgentTool.requestDescription)])]),
                    "required": .array([.string("request")]),
                ]),
            ])])])])
        }
        if !plan.history.isEmpty { setup["historyConfig"] = .object(["initialHistoryInClientContent": .bool(true)]) }
        return [.object(["setup": .object(setup)])]
    }

    func afterStart(_ plan: LivePlan, eventID: String) -> [JSONValue] {
        var messages: [JSONValue] = []
        // The conversation so far, which starts nothing by itself.
        if !plan.history.isEmpty {
            messages.append(.object(["clientContent": .object([
                "turns": .array(plan.history.map { line in
                    .object(["role": .string(line.fromPerson ? "user" : "model"), "parts": .array([.object(["text": .string(line.text)])])])
                }),
                "turnComplete": .bool(true),
            ])]))
        }
        // "Live API expects user input before it responds": a preview's line, asked for.
        if let greeting = plan.greeting {
            messages.append(Self.prompt("Say exactly this, once, in \(greeting.language), then stop: \"\(greeting.line)\""))
        }
        return messages
    }

    func audio(_ base64: String) -> String {
        "{\"realtimeInput\":{\"audio\":{\"data\":\"" + base64 + "\",\"mimeType\":\"audio/pcm;rate=16000\"}}}"
    }

    func answer(_ text: String, to id: String, final: Bool, eventID: String) -> [JSONValue] {
        guard final else { return [] }
        return [.object(["toolResponse": .object(["functionResponses": .array([.object([
            "id": .string(id), "name": .string(LiveAgentTool.name),
            "response": .object(["result": .string(text)]),
            "scheduling": .string("WHEN_IDLE"),
        ])])])])]
    }

    /// Said by asking for it: a turn from the app (not the person) the voice answers at once.
    func update(_ text: String, to id: String, eventID: String) -> [JSONValue] {
        [Self.prompt("(From the app, not the user: \(text) Tell the user that in a few words, without guessing the answer.)")]
    }

    /// Gemini has no quiet progress; the tool's result says what was done.
    func note(_ text: String, to id: String, eventID: String) -> [JSONValue] { [] }

    /// The microphone held shut sends nothing, which Google asks to be told of.
    func mute(_ muted: Bool, eventID: String) -> [JSONValue] {
        muted ? [.object(["realtimeInput": .object(["audioStreamEnd": .bool(true)])])] : []
    }

    func close() -> [JSONValue] { [.object(["realtimeInput": .object(["audioStreamEnd": .bool(true)])])] }

    func read(_ text: String) -> [LiveEvent] {
        guard let message = try? JSONValue.parse(Data(text.utf8)) else { return [] }
        var events: [LiveEvent] = []
        if message["setupComplete"] != nil { events.append(.started) }
        if let content = message["serverContent"] {
            for part in content["modelTurn"]?["parts"]?.array ?? [] {
                if let data = part["inlineData"]?["data"]?.string.flatMap({ Data(base64Encoded: $0) }) { events.append(.audio(data)) }
            }
            if let heard = content["inputTranscription"]?["text"]?.string, !heard.isEmpty {
                events.append(.transcript(.person, heard, startMs: nil, endMs: nil))
            }
            if let said = content["outputTranscription"]?["text"]?.string, !said.isEmpty {
                events.append(.transcript(.voice, said, startMs: nil, endMs: nil))
            }
            if content["interrupted"]?.bool == true { events.append(.interrupted) }
        }
        for call in message["toolCall"]?["functionCalls"]?.array ?? [] where call["name"]?.string == LiveAgentTool.name {
            if let id = call["id"]?.string { events.append(.delegated(id: id, request: call["args"]?["request"]?.string)) }
        }
        if let ids = message["toolCallCancellation"]?["ids"]?.array?.compactMap(\.string), !ids.isEmpty { events.append(.withdrawn(ids)) }
        if message["goAway"] != nil { events.append(.closed("go_away")) }
        return events
    }

    private static func prompt(_ text: String) -> JSONValue {
        .object(["clientContent": .object([
            "turns": .array([.object(["role": .string("user"), "parts": .array([.object(["text": .string(text)])])])]),
            "turnComplete": .bool(true),
        ])])
    }
}
