import Foundation

/// OpenAI-compatible `/v1/chat/completions` streaming. Stateless: the full history is sent each
/// turn. Earlier turns are never rewritten so the server's prefix cache stays warm.
nonisolated struct ChatCompletionsTransport: HermesTransport {
    var baseURL: URL
    var apiKey: String?

    private struct Body: Encodable {
        struct Msg: Encodable { var role: String; var content: JSONValue }
        struct StreamOptions: Encodable { var include_usage = true }
        var model: String
        var messages: [Msg]
        var stream = true
        var stream_options = StreamOptions()
        /// llama.cpp: stream `prompt_progress` chunks during prefill. Only sent to self-hosted
        /// endpoints — OpenAI rejects requests carrying unrecognized arguments.
        var return_progress: Bool?
        /// The picked reasoning level, as the OpenAI-compatible field. Sent whenever a level is
        /// picked, to every endpoint: cloud reasoning models and local servers that grade effort
        /// honour it, the rest ignore it. Not sent for None: most cloud models reject the word,
        /// and locally the template switch below already turns thinking off.
        var reasoning_effort: String?
        /// llama.cpp: per-request chat-template switches, so a picked level reaches templates
        /// that read it (`enable_thinking` for Qwen, `reasoning_effort` for gpt-oss and others).
        /// Self-hosted endpoints only, like return_progress: OpenAI rejects unknown arguments.
        var chat_template_kwargs: [String: JSONValue]?
    }

    /// The level as it goes on the wire in `reasoning_effort`: nil for Default and None.
    static func wireEffort(_ effort: String?) -> String? {
        guard let effort = effort?.nilIfEmpty?.lowercased(), effort != "none" else { return nil }
        return effort
    }

    /// Template switches for a picked level on a self-hosted endpoint, whatever the model: any
    /// level turns thinking on where the template has a switch, None turns it off, and the
    /// level itself goes to templates that grade it. Default leaves the server's settings alone.
    static func thinkingKwargs(effort: String?, baseURL: URL) -> [String: JSONValue]? {
        guard isSelfHosted(baseURL), let effort = effort?.nilIfEmpty?.lowercased() else { return nil }
        return ["enable_thinking": .bool(effort != "none"), "reasoning_effort": .string(effort)]
    }

    /// Whether the endpoint looks self-hosted (localhost, LAN, tailnet, or a private-looking
    /// name), where the llama.cpp progress extension is safe to request.
    static func isSelfHosted(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        if !host.contains(".") && !host.contains(":") { return true }   // single-label: MagicDNS or a LAN name
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".ts.net")
            || host.hasSuffix(".internal") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 127 || parts[0] == 10
            || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 100 && (64...127).contains(parts[1]))   // CGNAT, i.e. Tailscale
    }

    func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        let (baseURL, apiKey) = (baseURL, apiKey)
        return StreamingHTTP.run(session: StreamingHTTP.longSession, decode: Self.decode) {
            var messages: [Body.Msg] = []
            let system = [request.instructions?.nilIfEmpty, request.replyLanguage.map(ReplyLanguage.instruction)].compactMap { $0 }
            if !system.isEmpty {
                messages.append(.init(role: "system", content: .string(system.joined(separator: "\n\n"))))
            }
            messages += request.history.map { .init(role: $0.role.rawValue, content: .string($0.text)) }
            messages.append(.init(role: "user", content: try Self.makeContent(text: request.userText, attachments: request.attachments)))
            let model = request.model?.nilIfEmpty ?? ""   // no pick: the server's default
            let body = Body(model: model, messages: messages,
                            return_progress: Self.isSelfHosted(baseURL) ? true : nil,
                            reasoning_effort: Self.wireEffort(request.reasoningEffort),
                            chat_template_kwargs: Self.thinkingKwargs(effort: request.reasoningEffort, baseURL: baseURL))
            return try StreamingHTTP.makeRequest(url: baseURL.appending(path: "v1/chat/completions"), apiKey: apiKey, body: body)
        }
    }

    /// llama.cpp takes OpenAI vision parts when the model has a projector; text files are inlined.
    /// Chat-completions dialect: `text` / `image_url` parts with a nested url object.
    static func makeContent(text: String, attachments: [Attachment]) throws -> JSONValue {
        try MultimodalInput.make(text: text, attachments: attachments, textType: "text",
                                 imageType: "image_url", nestedImageURL: true,
                                 transportName: "the OpenAI-compatible server")
    }

    private struct ToolProgress: Decodable { var tool: String?; var label: String?; var status: String? }

    private struct Chunk: Decodable {
        var choices: [Choice]?
        var usage: Usage?
        var error: ErrorObject?
        var prompt_progress: PromptProgress?
        struct PromptProgress: Decodable { var total: Int?; var cache: Int?; var processed: Int? }
        struct Usage: Decodable {
            var prompt_tokens: Int?
            var completion_tokens: Int?
            var prompt_tokens_details: Details?
            struct Details: Decodable { var cached_tokens: Int? }
        }
        struct Choice: Decodable {
            var delta: Delta?
            var finish_reason: String?
            struct Delta: Decodable { var content: String?; var reasoning_content: String? }
        }
        struct ErrorObject: Decodable { var message: String? }
    }

    private static let decoder = JSONDecoder()

    @Sendable
    static func decode(_ sse: SSEEvent) throws -> (events: [TurnEvent], finished: Bool) {
        if sse.data == "[DONE]" { return ([], true) }
        guard let data = sse.data.data(using: .utf8) else { return ([], false) }
        if sse.event == "hermes.tool.progress" {
            // Hermes gateway extension: tool activity interleaved with content chunks.
            let progress = try decoder.decode(ToolProgress.self, from: data)
            let name = progress.tool ?? progress.label ?? "tool"
            switch progress.status {
            case "completed": return ([.toolFinished(name: name, failed: false)], false)
            case "failed", "error": return ([.toolFinished(name: name, failed: true)], false)
            default: return ([.toolStarted(name: name, preview: progress.label)], false)
            }
        }
        let chunk = try decoder.decode(Chunk.self, from: data)
        if let message = chunk.error?.message { throw TransportError.malformed(message) }
        var events: [TurnEvent] = []
        if let progress = chunk.prompt_progress, let total = progress.total, total > 0 {
            events.append(.prefill(processed: progress.processed ?? 0, total: total, cached: progress.cache ?? 0))
        }
        // The stream ends on `[DONE]`, not on finish_reason: providers (OpenRouter, llama.cpp)
        // send the usage chunk *after* the chunk that carries finish_reason.
        if let usage = chunk.usage, let input = usage.prompt_tokens {
            events.append(.usage(TokenUsage(input: input, output: usage.completion_tokens ?? 0,
                                            cached: usage.prompt_tokens_details?.cached_tokens,
                                            contextUsed: input + (usage.completion_tokens ?? 0))))
        }
        for choice in chunk.choices ?? [] {
            if let text = choice.delta?.content, !text.isEmpty { events.append(.textDelta(text)) }
            if let thought = choice.delta?.reasoning_content, !thought.isEmpty { events.append(.reasoningDelta(thought)) }
        }
        return (events, false)   // the stream ends only on [DONE]; usage may follow finish_reason
    }
}

nonisolated extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
