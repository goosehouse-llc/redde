import Foundation

/// Hermes gateway sessions API: `/api/sessions/{id}/chat/stream`. This is the shared ledger every
/// Hermes platform writes to, so a conversation started here shows up next to Telegram and CLI
/// sessions, and any of theirs can be resumed here. Streams reasoning and tool activity live.
nonisolated struct HermesSessionsTransport: HermesTransport {
    var baseURL: URL
    var apiKey: String?

    private struct Body: Encodable {
        var input: JSONValue
        var instructions: String?
        var model: String?
        var provider: String?
        var model_options: ModelOptions?
        struct ModelOptions: Encodable { var reasoning_effort: String? }
    }

    /// Appended by the gateway to its own system prompt every turn (`instructions` →
    /// `ephemeral_system_prompt`). The stock `api_server` platform hint tells the agent to assume
    /// a plain-text renderer and, on some endpoints, to print a bare file path instead of a
    /// `MEDIA:` tag — so it refuses to send pictures ("I am unable to display the image").
    /// This corrects both for Redde: markdown renders, and `MEDIA:` tags are resolved on the
    /// sessions chat stream.
    static let clientHint = """
        The user is on Redde, an iOS chat app that renders GitHub-flavored Markdown: headings, \
        bold/italic, tables, task lists, fenced code with syntax highlighting, $math$, and images. \
        Use markdown freely. To show the user an image file from your machine (a camera snapshot, \
        a generated chart), write MEDIA:/absolute/path/to/file in your reply — it is inlined \
        server-side and the app displays the picture. This works here, on this endpoint. Never \
        say you cannot display images, and never print a bare file path or an [IMAGE: ...] \
        placeholder in place of a MEDIA: tag. Put runnable commands in fenced code blocks \
        (```bash), which render with a Copy button — not inline backticks.
        """

    /// The API server takes text and images only (`input_text` / `input_image` parts).
    static func makeInput(text: String, attachments: [Attachment]) throws -> JSONValue {
        try MultimodalInput.make(text: text, attachments: attachments, textType: "input_text",
                                 imageType: "input_image", nestedImageURL: false,
                                 transportName: "the Hermes API")
    }

    func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        guard let apiKey, !apiKey.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: TransportError.missingAPIKey) }
        }
        guard let sessionID = request.sessionID, !sessionID.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: TransportError.malformed("no session id")) }
        }
        let baseURL = baseURL
        return StreamingHTTP.run(decode: Self.decode) {
            try StreamingHTTP.makeRequest(
                url: baseURL.appending(path: "api/sessions/\(sessionID)/chat/stream"),
                apiKey: apiKey, body: Body(
                    input: try Self.makeInput(text: request.userText, attachments: request.attachments),
                    instructions: Self.clientHint,
                    model: request.model, provider: request.provider,
                    model_options: request.reasoningEffort.map { .init(reasoning_effort: $0) }))
        }
    }

    /// The API server never forwards subagent events, so rows are synthesized from the
    /// `delegate_task` arguments: one per task goal.
    nonisolated static func delegatedGoals(_ args: JSONValue?, runID: String?) -> [SubagentUpdate] {
        guard let args else { return [] }
        var goals: [String] = []
        if let tasks = args["tasks"]?.array {
            goals = tasks.compactMap { $0["goal"]?.string ?? $0.string }
        } else if let goal = args["goal"]?.string {
            goals = [goal]
        }
        return goals.enumerated().map { i, goal in
            SubagentUpdate(id: "delegate:\(runID ?? "run"):\(i)", goal: goal, taskIndex: i, taskCount: goals.count, phase: .started)
        }
    }

    private struct Envelope: Decodable {
        var session_id: String?
        var run_id: String?
        var delta: String?
        var content: String?
        var tool_name: String?
        var preview: String?
        var args: JSONValue?
        var message: String?
        var usage: Usage?
        // approval.request (the dchermes approval bridge)
        var request_id: String?
        var command: String?
        var description: String?
        var choices: [String]?
        struct Usage: Decodable { var input_tokens: Int?; var output_tokens: Int?; var prompt_tokens: Int?; var completion_tokens: Int? }
    }

    private static let decoder = JSONDecoder()

    @Sendable
    static func decode(_ sse: SSEEvent) throws -> (events: [TurnEvent], finished: Bool) {
        guard let event = sse.event else { return ([], false) }
        let env = (try? decoder.decode(Envelope.self, from: Data(sse.data.utf8))) ?? Envelope()
        switch event {
        case "run.started":
            var events: [TurnEvent] = []
            if let sid = env.session_id { events.append(.sessionID(sid)) }
            if let rid = env.run_id { events.append(.runID(rid)) }
            return (events, false)
        case "assistant.delta":
            return (env.delta.map { [.textDelta($0)] } ?? [], false)
        case "assistant.completed":
            // The finished reply, and the only form with `MEDIA:<path>` tags resolved into
            // inline images — the deltas carry the bare tag. Replaces what streamed.
            guard let content = env.content, !content.isEmpty else { return ([], false) }
            return ([.textFinal(content)], false)
        case "tool.progress":
            // Reasoning arrives as a pseudo-tool named "_thinking".
            if env.tool_name == "_thinking", let delta = env.delta { return ([.reasoningDelta(delta)], false) }
            return ([], false)
        case "tool.started":
            var events: [TurnEvent] = [.toolStarted(name: env.tool_name ?? "tool", preview: env.preview)]
            if env.tool_name == "delegate_task" { events += delegatedGoals(env.args, runID: env.run_id).map { .subagent($0) } }
            return (events, false)
        case "tool.completed":
            var events: [TurnEvent] = [.toolFinished(name: env.tool_name ?? "", failed: false)]
            if env.tool_name == "delegate_task" {
                // The API server drops subagent.* events; results land in a later turn. Mark as dispatched.
                events += delegatedGoals(env.args, runID: env.run_id).map { var u = $0; u.phase = .dispatched; return .subagent(u) }
            }
            return (events, false)
        case "tool.failed":
            return ([.toolFinished(name: env.tool_name ?? "", failed: true)], false)
        case "approval.request":
            // The gateway pauses the run on an approval-gated tool call; answered via
            // POST /v1/runs/{run_id}/approval, so the run id rides as the routing token.
            guard let requestID = env.request_id else { return ([], false) }
            let request = ApprovalRequest(id: requestID, command: env.command ?? "",
                                          description: env.description?.nilIfEmpty,
                                          choices: env.choices ?? ["once", "deny"])
            return ([.interrupt(.approval(request), runtimeSession: env.run_id ?? "")], false)
        case "run.completed":
            var events: [TurnEvent] = []
            if let u = env.usage, let input = u.input_tokens ?? u.prompt_tokens {
                events.append(.usage(TokenUsage(input: input, output: u.output_tokens ?? u.completion_tokens ?? 0, cached: nil)))
            }
            return (events, false)
        case "error":
            throw TransportError.malformed(env.message ?? "run failed")
        case "done":
            return ([], true)
        default:
            return ([], false)
        }
    }
}

/// The non-streaming half of the ledger: list, read, create, delete sessions; list toolsets.
nonisolated struct HermesSessionsAPI: Sendable {
    var baseURL: URL
    var apiKey: String

    struct SessionSummary: Decodable, Identifiable, Sendable, Equatable {
        var id: String
        var source: String?
        var title: String?
        var preview: String?
        var model: String?
        var message_count: Int?
        var started_at: Double?
        var last_active: Double?
        var pinned: Bool?
        var tool_call_count: Int?
        var input_tokens: Int?
        var output_tokens: Int?
        var cache_read_tokens: Int?
        var cache_write_tokens: Int?
        var reasoning_tokens: Int?
        var estimated_cost_usd: Double?
        var actual_cost_usd: Double?
        var api_call_count: Int?

        var totalTokens: Int { (input_tokens ?? 0) + (output_tokens ?? 0) }
        var cost: Double? { actual_cost_usd ?? estimated_cost_usd }

        /// "▲ 8.2k ▼ 1.1k · $0.01" for a list row; nil when the ledger has no usage yet.
        var usageLine: String? {
            guard totalTokens > 0 else { return nil }
            var parts = ["▲ \(Self.compact(input_tokens ?? 0)) ▼ \(Self.compact(output_tokens ?? 0))"]
            if let cost, cost > 0 { parts.append(String(format: "$%.3f", cost)) }
            return parts.joined(separator: " · ")
        }

        static func compact(_ n: Int) -> String {
            switch n {
            case ..<1000: "\(n)"
            case ..<1_000_000: String(format: "%.1fk", Double(n) / 1000)
            default: String(format: "%.2fM", Double(n) / 1_000_000)
            }
        }

        var displayTitle: String {
            if let title, !title.isEmpty { return title }
            if let preview, !preview.isEmpty { return String(preview.prefix(80)) }
            return id
        }
        var lastActiveDate: Date? { (last_active ?? started_at).map { Date(timeIntervalSince1970: $0) } }
        var sourceLabel: String {
            switch source ?? "" {
            case "api_server", "api-server": "Redde / API"
            case "cli": "CLI"
            case "": "?"
            default: (source ?? "").replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
    }

    struct StoredMessage: Decodable, Sendable {
        var id: String?
        var role: String
        var content: Content?
        var timestamp: Double?
        var reasoning: String?
        var reasoning_content: String?
        var display_kind: String?
        var tool_calls: [ToolCall]?
        var tool_name: String?

        struct ToolCall: Decodable, Sendable {
            var function: Function?
            struct Function: Decodable, Sendable { var name: String? }
        }
        /// Content may be a string or an array of parts.
        enum Content: Decodable, Sendable {
            case text(String)
            case parts([String])
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { self = .text(s); return }
                struct Part: Decodable { var type: String?; var text: String? }
                let parts = try c.decode([Part].self)
                self = .parts(parts.compactMap(\.text))
            }
            var text: String {
                switch self {
                case let .text(s): s
                case let .parts(p): p.joined(separator: "\n")
                }
            }
        }
    }

    struct Toolset: Decodable, Identifiable, Sendable {
        var name: String
        var label: String?
        var description: String?
        var enabled: Bool?
        var configured: Bool?
        var tools: [String]?
        var id: String { name }
    }

    private struct ListEnvelope<T: Decodable>: Decodable { var data: [T]; var has_more: Bool? }
    private struct SessionEnvelope: Decodable { var session: SessionSummary }
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    func listSessions(limit: Int = 100, offset: Int = 0) async throws -> [SessionSummary] {
        try await get(ListEnvelope<SessionSummary>.self, "api/sessions",
                      query: [.init(name: "limit", value: String(limit)), .init(name: "offset", value: String(offset))]).data
    }

    func messages(sessionID: String) async throws -> [StoredMessage] {
        try await get(ListEnvelope<StoredMessage>.self, "api/sessions/\(sessionID)/messages",
                      query: [.init(name: "order", value: "oldest"), .init(name: "limit", value: "500")]).data
    }

    func createSession(title: String?, model: String? = nil, provider: String? = nil, reasoningEffort: String? = nil) async throws -> SessionSummary {
        struct Body: Encodable {
            var title: String?; var model: String?; var provider: String?
            var model_options: Options?
            struct Options: Encodable { var reasoning_effort: String? }
        }
        let body = Body(title: title, model: model, provider: provider,
                        model_options: reasoningEffort.map { .init(reasoning_effort: $0) })
        let data = try await send("POST", "api/sessions", body: try Self.encoder.encode(body))
        return try Self.decoder.decode(SessionEnvelope.self, from: data).session
    }

    /// Inject guidance into a running turn. 409 when the run is no longer accepting steers.
    func steer(runID: String, text: String) async throws -> Bool {
        struct Body: Encodable { var text: String }
        do {
            _ = try await send("POST", "v1/runs/\(runID)/steer", body: try Self.encoder.encode(Body(text: text)))
            return true
        } catch TransportError.http(409, _) {
            return false
        }
    }

    /// Pin an open session to a model (`POST /api/sessions/{id}/model`). Once a session has a
    /// stored model, per-turn model fields are ignored, so this is the only way to switch
    /// mid-conversation.
    func lockSessionModel(id: String, model: String, provider: String?) async throws {
        var body: [String: JSONValue] = ["model": .string(model)]
        if let provider = Self.lockProvider(provider) { body["provider"] = .string(provider) }
        _ = try await requestJSON("POST", "api/sessions/\(id)/model", body: .object(body))
    }

    /// The lock's post-run check compares the agent's *normalized* provider, which is the bare
    /// bucket for named custom endpoints — locking "custom:endpoint" fails that check even
    /// though the right model ran, so send "custom".
    static func lockProvider(_ provider: String?) -> String? {
        guard let provider, !provider.isEmpty else { return nil }
        return provider.hasPrefix("custom:") ? "custom" : provider
    }

    /// Answer a pending tool approval on a run. `choice` is once | session | always | deny.
    func respondApproval(runID: String, requestID: String?, choice: String) async throws {
        var body: [String: JSONValue] = ["choice": .string(choice)]
        if let requestID, !requestID.isEmpty { body["request_id"] = .string(requestID) }
        _ = try await requestJSON("POST", "v1/runs/\(runID)/approval", body: .object(body))
    }

    /// Rename / pin / archive. Only the given fields are sent.
    func updateSession(id: String, title: String? = nil, pinned: Bool? = nil, archived: Bool? = nil) async throws {
        struct Body: Encodable { var title: String?; var pinned: Bool?; var archived: Bool? }
        _ = try await send("PATCH", "api/sessions/\(id)", body: try Self.encoder.encode(Body(title: title, pinned: pinned, archived: archived)))
    }

    /// Branch a session: a new one carrying a copy of the transcript.
    func forkSession(id: String, title: String?) async throws -> SessionSummary {
        struct Body: Encodable { var title: String? }
        let data = try await send("POST", "api/sessions/\(id)/fork", body: try Self.encoder.encode(Body(title: title)))
        return try Self.decoder.decode(SessionEnvelope.self, from: data).session
    }

    func deleteSession(id: String) async throws {
        _ = try await send("DELETE", "api/sessions/\(id)")
    }

    /// Models the gateway can route to, grouped by provider (`/api/model/options`).
    func modelOptions() async throws -> [ModelChoice] {
        try Self.parseModelOptions(try await send("GET", "api/model/options"))
    }

    /// Shared with hermes serve's `model.options`, which returns the same payload.
    static func parseModelOptions(_ data: Data) throws -> [ModelChoice] {
        parseModelOptions(try JSONValue.parse(data))
    }

    static func parseModelOptions(_ json: JSONValue) -> [ModelChoice] {
        var out: [ModelChoice] = []
        // The payload's top-level model/provider name the active selection.
        let currentModel = json["model"]?.string
        for provider in json["providers"]?.array ?? [] {
            let slug = provider["slug"]?.string ?? provider["id"]?.string ?? ""
            let pname = provider["name"]?.string ?? slug
            let current = provider["is_current"]?.bool ?? false
            for model in provider["models"]?.array ?? [] {
                // Live payloads carry models as bare id strings; keep the object shape too.
                let id = model.string ?? model["id"]?.string ?? model["model"]?.string ?? ""
                guard !id.isEmpty else { continue }
                out.append(ModelChoice(provider: slug, providerName: pname, model: id,
                                       name: model["name"]?.string ?? id,
                                       isCurrent: current && (model["is_current"]?.bool ?? (id == currentModel))))
            }
        }
        return out
    }

    /// Generic JSON call against the API server (bearer-authenticated).
    func requestJSON(_ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil) async throws -> JSONValue {
        let data = try await send(method, path, query: query, body: try body.map { try Self.encoder.encode($0) },
                                  timeout: method == "POST" && path.hasSuffix("/run") ? 600 : 20)
        if data.isEmpty { return .null }
        return try JSONValue.parse(data)
    }

    func toolsets() async throws -> [Toolset] {
        try await get(ListEnvelope<Toolset>.self, "v1/toolsets").data
    }

    struct Skill: Decodable, Identifiable, Sendable {
        var name: String
        var description: String?
        var category: String?
        /// Only the dashboard reports this; nil from the API server.
        var enabled: Bool?
        var id: String { name }
    }

    func skills() async throws -> [Skill] {
        try await get(ListEnvelope<Skill>.self, "v1/skills").data
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        try Self.decoder.decode(type, from: try await send("GET", path, query: query, timeout: 15))
    }

    /// The one bearer-authenticated request every call above goes through.
    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                      timeout: TimeInterval = 20) async throws -> Data {
        guard var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else { throw TransportError.badURL }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw TransportError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await StreamingHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TransportError.malformed("not HTTP") }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw TransportError.http(status: http.statusCode, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }
}
