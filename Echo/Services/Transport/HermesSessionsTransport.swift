import Foundation

/// The profile a conversation lives in when it is neither the selected profile's nor a bot's
/// chat: one opened from the chat list with All Profiles on (his ask 2026-10-22, after a Reddit
/// request: Hermes Desktop shows every profile's sessions at once).
/// A row of the chat list from another saved server than the one the app is on (All Servers): its
/// id, to switch to it when the row is opened, and its name, for the row's tag.
nonisolated struct ServerTag: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
}

nonisolated struct ProfileRoute: Codable, Equatable, Sendable {
    var profile: String
    /// Reached by the Hermes API at /p/<profile>/ with that profile's own key, not the Dashboard.
    var viaAPI: Bool
}

/// A flag a server may send as true/false, 0/1 or a string of either, and may leave out.
@propertyWrapper
nonisolated struct LooseBool: Decodable, Equatable, Sendable {
    var wrappedValue: Bool?

    init(wrappedValue: Bool?) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            wrappedValue = nil
        } else if let flag = try? value.decode(Bool.self) {
            wrappedValue = flag
        } else if let number = try? value.decode(Double.self) {
            wrappedValue = number != 0
        } else if let text = try? value.decode(String.self) {
            wrappedValue = ["1", "true", "yes"].contains(text.lowercased())
        } else {
            wrappedValue = nil
        }
    }
}

nonisolated extension KeyedDecodingContainer {
    /// A `LooseBool` whose key is missing is nil, as a plain optional's would be.
    func decode(_ type: LooseBool.Type, forKey key: Key) throws -> LooseBool {
        try decodeIfPresent(type, forKey: key) ?? LooseBool(wrappedValue: nil)
    }
}

/// Hermes gateway sessions API: `/api/sessions/{id}/chat/stream`. This is the shared ledger every
/// Hermes platform writes to, so a conversation started here shows up next to Telegram and CLI
/// sessions, and any of theirs can be resumed here. Streams reasoning and tool activity live.
nonisolated struct HermesSessionsTransport: HermesTransport {
    var baseURL: URL
    var apiKey: String?
    /// The person's own headers for this server (a reverse proxy's), sent with each request.
    var headers: [String: String] = [:]

    struct Body: Encodable, Sendable {
        var input: JSONValue
        var instructions: String?
        var model: String?
        var provider: String?
        /// Sent with a picked model. Without it the gateway treats `model`/`provider` as a
        /// one-off: once the session has a stored model it runs that model on the *default*
        /// provider, so a model from any other provider or endpoint is sent to the wrong place
        /// (and Hermes before 0.21.4 fails the turn with "No LLM provider configured"). With it
        /// the gateway resolves the named provider every turn and pins the session to it.
        var require_model_lock: Bool?
        var model_options: ModelOptions?
        struct ModelOptions: Encodable, Sendable {
            var reasoning_effort: String?
            /// The provider's fast (priority) tier, for this turn (`RunChatControls`).
            var fast: Bool? = nil

            /// Nil when there's nothing to ask for.
            static func asked(effort: String?, fast: Bool) -> ModelOptions? {
                let effort = effort?.nilIfEmpty
                guard effort != nil || fast else { return nil }
                return ModelOptions(reasoning_effort: effort, fast: fast ? true : nil)
            }
        }
    }

    /// Appended by the gateway to its own system prompt every turn (`instructions` →
    /// `ephemeral_system_prompt`). The stock `api_server` platform hint tells the agent to assume
    /// a plain-text renderer and, on some endpoints, to print a bare file path instead of a
    /// `MEDIA:` tag — so it refuses to send pictures ("I am unable to display the image").
    /// This corrects both for Redde: markdown renders, and `MEDIA:` tags are fetched (through
    /// the Dashboard's login on a run; the chat stream puts small pictures in the reply itself),
    /// any kind of file, as the desktop app's hint has it.
    static let clientHint = """
        The user is on Redde, an iOS chat app that renders GitHub-flavored Markdown: headings, \
        bold/italic, tables, task lists, fenced code with syntax highlighting, $math$, and images. \
        Use markdown freely. To send the user a file from your machine, of any kind (a picture, \
        a recording, a PDF, a Markdown or HTML document you wrote, a spreadsheet), write \
        MEDIA:/absolute/path/to/file on a line of its own in your reply — the app fetches it and \
        shows it: pictures and sound in the chat, other files as one to open. This works here, on \
        this endpoint. Never say you cannot display images or send files, and never print a bare \
        file path or an [IMAGE: ...] placeholder in place of a MEDIA: tag. Put runnable commands in fenced code blocks \
        (```bash), which render with a Copy button — not inline backticks. To put something live in the chat (a chart, \
        a widget with buttons), write a single-file HTML page, then put ::preview{file="/absolute/path/page.html"} \
        alone on its own line. The app themes it before your styles, with var(--foreground), var(--muted-foreground), \
        var(--accent), var(--border) and var(--card), its font, no margins and a clear background: use those vars for \
        colour and set no background, font or margins of your own (only a standalone page, a poster or a game, \
        overrides them). It sizes itself to the content: lay it out flush left, with no centring wrapper. A page talks \
        back: data-hermes-send="prompt" on anything tappable, or window.hermes.send("prompt"), sends you that prompt \
        as a message starting [From the page in the chat]; answer it by writing the page's file again, not in prose: \
        the app reads the page again once you are done.
        """

    /// The API server takes text and images only (`input_text` / `input_image` parts).
    static func makeInput(text: String, attachments: [Attachment]) throws -> JSONValue {
        try MultimodalInput.make(text: text, attachments: attachments, textType: "input_text",
                                 imageType: "input_image", nestedImageURL: false,
                                 transportName: "the Hermes API")
    }

    /// One turn, as a run in the conversation's session (`HermesRuns`): it goes on on the host
    /// whatever becomes of this stream. Ending the stream stops the run, unless the conversation
    /// was left (`TurnRequest.departure`). A gateway without runs gets the chat stream, as before.
    func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        guard let apiKey, !apiKey.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: TransportError.noAPIKey) }
        }
        guard let sessionID = request.sessionID, !sessionID.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: TransportError.malformed("no session id")) }
        }
        let runs = HermesRuns(baseURL: baseURL, apiKey: apiKey, headers: headers)
        let chat = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                var runID: String?
                do {
                    guard let started = try await runs.start(try Self.runBody(request, sessionID: sessionID), key: request.turnKey) else {
                        for try await event in chat.chatStream(request, sessionID: sessionID, apiKey: apiKey) { continuation.yield(event) }
                        continuation.finish()
                        return
                    }
                    runID = started
                    continuation.yield(.sessionID(sessionID))
                    continuation.yield(.runID(started))
                    try await runs.follow(started) { continuation.yield($0) }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        // Stopped, the run is stopped on the host. Left for another conversation,
                        // it goes on there, and is taken up again when the conversation is opened.
                        if let runID, request.departure?.hasLeft != true { runs.stop(runID) }
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// What a run is started with. A picked model goes with its provider every turn: a run reads
    /// neither the session's stored model nor its lock.
    nonisolated struct RunBody: Encodable, Sendable {
        var input: JSONValue
        var session_id: String
        var instructions: String?
        var model: String?
        var provider: String?
        var model_options: Body.ModelOptions?
    }

    static func runBody(_ request: TurnRequest, sessionID: String) throws -> RunBody {
        RunBody(input: try runInput(text: PageTurn.text(of: request), attachments: request.attachments), session_id: sessionID,
                instructions: instructions(for: request), model: request.model?.nilIfEmpty, provider: request.provider?.nilIfEmpty,
                model_options: .asked(effort: request.reasoningEffort, fast: request.fast))
    }

    /// A run's message: the text, or with pictures one user message of parts as chat models take
    /// them. One message only: a run takes more than one as the conversation so far, in place of
    /// the session's own.
    static func runInput(text: String, attachments: [Attachment]) throws -> JSONValue {
        let content = try MultimodalInput.make(text: text, attachments: attachments, textType: "text", imageType: "image_url",
                                               nestedImageURL: true, transportName: "the Hermes API")
        if case .string = content { return content }
        return .array([.object(["role": .string("user"), "content": content])])
    }

    /// The turn's instructions to the agent, on top of Hermes's own: Redde's hint, then the
    /// reply language, the car's request for a short answer, and what a turn GPT-Live handed over is.
    static func instructions(for request: TurnRequest) -> String {
        ([clientHint] + [request.instructions?.nilIfEmpty, request.replyLanguage.map(ReplyLanguage.instruction),
                         request.brief ? CarBrevity.instruction : nil, request.incognito ? IncognitoNote.instruction : nil,
                         request.live.map { LiveVoiceNote.instruction(context: $0.context) },
                         request.answeringCall.map(CallNote.instruction)].compactMap { $0 })
            .joined(separator: "\n\n")
    }

    /// The chat stream (`/api/sessions/{id}/chat/stream`), for a gateway without runs. Hermes stops
    /// its turn when the stream is cut.
    func chatStream(_ request: TurnRequest, sessionID: String, apiKey: String) -> AsyncThrowingStream<TurnEvent, Error> {
        let baseURL = baseURL, headers = headers
        return StreamingHTTP.run(decode: Self.decode) {
            try StreamingHTTP.makeRequest(
                url: baseURL.appending(path: "api/sessions/\(sessionID)/chat/stream"),
                apiKey: apiKey, headers: headers, body: Body(
                    input: try Self.makeInput(text: PageTurn.text(of: request), attachments: request.attachments),
                    instructions: Self.instructions(for: request),
                    model: request.model, provider: request.provider,
                    require_model_lock: request.model?.nilIfEmpty == nil ? nil : true,
                    model_options: .asked(effort: request.reasoningEffort, fast: request.fast)))
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

    /// The name a finished call is matched to its step by. A `tool_call` that came without the
    /// arguments that say which tool it was matches the step still running, whatever its name.
    private static func finished(_ name: String) -> String { name == "tool_call" ? "" : name }

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
        // approval.request (from an approval bridge on the gateway)
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
            // A tool reached through `tool_call` is named as itself, as the Dashboard names it.
            let call = ToolActivity.unwrapped(name: env.tool_name ?? "tool", args: env.args)
            var events: [TurnEvent] = [.toolStarted(name: call.name, preview: env.preview, args: ToolActivity.args(call.name, call.args))]
            if call.name == "delegate_task" { events += delegatedGoals(call.args, runID: env.run_id).map { .subagent($0) } }
            return (events, false)
        case "tool.completed":
            let call = ToolActivity.unwrapped(name: env.tool_name ?? "", args: env.args)
            var events: [TurnEvent] = [.toolFinished(name: Self.finished(call.name), failed: false)]
            if call.name == "delegate_task" {
                // The API server drops subagent.* events; results land in a later turn. Mark as dispatched.
                events += delegatedGoals(call.args, runID: env.run_id).map { var u = $0; u.phase = .dispatched; return .subagent(u) }
            }
            return (events, false)
        case "tool.failed":
            return ([.toolFinished(name: Self.finished(ToolActivity.unwrapped(name: env.tool_name ?? "", args: env.args).name), failed: true)], false)
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
            // Not a failure: the reply above is whole and already stored. "done" ends the turn.
            if let message = env.message, isLockBucketMismatch(message) { return ([], false) }
            throw TransportError.malformed(env.message ?? String(localized: "run failed", comment: "Why a reply failed, when the server gave no reason"))
        case "done":
            return ([], true)
        default:
            return ([], false)
        }
    }
}

extension HermesSessionsTransport {
    /// Hermes before 0.21.4 ends a locked turn on a user-defined endpoint with "confirmed model
    /// lock runtime mismatch: expected provider=custom:name model=m; actual provider=custom
    /// model=m": its post-run check compares the endpoint's name with the bare "custom" bucket
    /// every such endpoint runs under. The turn itself ran on the right endpoint and model. Any
    /// other mismatch (another model, another provider) is real.
    nonisolated static func isLockBucketMismatch(_ message: String) -> Bool {
        let pattern = /lock runtime mismatch: expected provider=(\S+) model=(\S+); actual provider=(\S+) model=(\S+)/
        guard let match = message.firstMatch(of: pattern) else { return false }
        return match.output.2 == match.output.4 && match.output.3 == "custom" && match.output.1 != "custom"
    }
}

/// The non-streaming half of the ledger: list, read, create, delete sessions; list toolsets.
nonisolated struct HermesSessionsAPI: Sendable {
    var baseURL: URL
    var apiKey: String
    /// The person's own headers for this server (a reverse proxy's), sent with each request.
    var headers: [String: String] = [:]

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
        /// The folder the session works in, where the list says (the Dashboard's does): which
        /// project it is in.
        var cwd: String?
        /// A reply here since it was last marked read (`PATCH … {"unread": false}`), as Hermes
        /// keeps it for every app. Only the Dashboard's list says; the Hermes API's leaves it out.
        var unread: Bool?
        /// The profile it belongs to, where the list says (the Dashboard's does).
        var profile: String?
        /// Put aside, and kept out of every app's list (a bot's chat is born hidden), where the
        /// server says: a bot's earlier chats are its archived ones (`EarlierBotChats`). Read as
        /// either: the Dashboard's list of every profile sends SQLite's 0 and 1 for `hidden`.
        @LooseBool var archived: Bool? = nil
        @LooseBool var hidden: Bool? = nil
        /// Another profile than the selected one, and how to reach it: set by the chat list with All
        /// Profiles on (`SessionBackend.everyProfile`), never by the server.
        var elsewhere: ProfileRoute?
        /// Another saved server's, with All Servers on (`AllServers`): which, never by the server
        /// (a key no Hermes list has, so the rows decode as before).
        var otherServer: ServerTag?

        var totalTokens: Int { (input_tokens ?? 0) + (output_tokens ?? 0) }
        var cost: Double? { actual_cost_usd ?? estimated_cost_usd }

        /// "▲ 8.2k ▼ 1.1k · $0.01" for a list row; nil when the ledger has no usage yet.
        var usageLine: String? {
            guard totalTokens > 0 else { return nil }
            var parts = ["▲ \(Self.compact(input_tokens ?? 0)) ▼ \(Self.compact(output_tokens ?? 0))"]
            if let cost, cost > 0 { parts.append(cost.formatted(.currency(code: "USD").precision(.fractionLength(3)))) }
            return parts.joined(separator: " · ")
        }

        static func compact(_ n: Int) -> String {
            switch n {
            case ..<1000: n.formatted()
            case ..<1_000_000: n.formatted(.number.notation(.compactName).precision(.fractionLength(1)))
            default: n.formatted(.number.notation(.compactName).precision(.fractionLength(2)))
            }
        }

        var displayTitle: String {
            if let title, !title.isEmpty { return title }
            if let preview, !preview.isEmpty { return String(preview.prefix(80)) }
            return id
        }
        var lastActiveDate: Date? { (last_active ?? started_at).map { Date(timeIntervalSince1970: $0) } }
        /// A run of a scheduled job: Hermes makes a session of each one (GitHub issue 19).
        var isScheduledRun: Bool { source == "cron" }
        var sourceLabel: String {
            switch source ?? "" {
            case "api_server", "api-server": "Redde / API"
            case "cli": "CLI"
            case "": "?"
            default: (source ?? "").replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
    }

    /// One stored message. Decoded leniently, field by field: the gateway returns its database
    /// rows nearly as-is, and one field of an unexpected type (the row `id` is a number, and
    /// Redde read it as text) failed the whole transcript with "The data couldn't be read
    /// because it isn't in the correct format".
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

        private enum CodingKeys: String, CodingKey {
            case id, role, content, timestamp, reasoning, reasoning_content, display_kind, tool_calls, tool_name
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decodeIfPresent(String.self, forKey: .id))
                ?? (try? c.decodeIfPresent(Int.self, forKey: .id)).flatMap { $0.map(String.init) }
            role = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? ""
            content = try? c.decodeIfPresent(Content.self, forKey: .content)
            timestamp = (try? c.decodeIfPresent(Double.self, forKey: .timestamp))
                ?? (try? c.decodeIfPresent(String.self, forKey: .timestamp)).flatMap { $0.flatMap(Double.init) }
            reasoning = try? c.decodeIfPresent(String.self, forKey: .reasoning)
            reasoning_content = try? c.decodeIfPresent(String.self, forKey: .reasoning_content)
            display_kind = try? c.decodeIfPresent(String.self, forKey: .display_kind)
            tool_calls = try? c.decodeIfPresent([ToolCall].self, forKey: .tool_calls)
            tool_name = try? c.decodeIfPresent(String.self, forKey: .tool_name)
        }

        struct ToolCall: Decodable, Sendable {
            var function: Function?
            /// `arguments` is JSON, usually as a string.
            struct Function: Decodable, Sendable { var name: String?; var arguments: JSONValue? }
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

    private struct ListEnvelope<T: Decodable & Sendable>: Decodable, Sendable { var data: [T]; var has_more: Bool? }
    private struct SessionEnvelope: Decodable, Sendable { var session: SessionSummary }
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// `title` with `includeHidden`: the sessions of exactly that title, hidden ones too (a bot's
    /// chat; Hermes takes `include_hidden` only with a title). A release that knows neither lists as
    /// without them, so callers match the title themselves.
    func listSessions(limit: Int = 100, offset: Int = 0, title: String? = nil, includeHidden: Bool = false) async throws -> [SessionSummary] {
        var query: [URLQueryItem] = [.init(name: "limit", value: String(limit)), .init(name: "offset", value: String(offset))]
        if let title {
            query.append(.init(name: "title", value: title))
            if includeHidden { query.append(.init(name: "include_hidden", value: "true")) }
        }
        return try await get(ListEnvelope<SessionSummary>.self, "api/sessions", query: query).data
    }

    /// One session by its id, archived ones too (the list leaves those out); nil when it's gone.
    func session(id: String) async throws -> SessionSummary? {
        do {
            return try await get(SessionEnvelope.self, "api/sessions/\(id)").session
        } catch TransportError.http(404, _) {
            return nil
        }
    }

    /// A session's transcript, oldest first: its newest 500 messages, Hermes's most for a page
    /// (`latest` pages back from the newest and still answers in order, 0.21.0 to 0.22.2). It
    /// asked for the oldest 500, which left a longer conversation without its end.
    func messages(sessionID: String) async throws -> [StoredMessage] {
        try await newestMessages(sessionID: sessionID, limit: 500)
    }

    /// The newest stored messages of a session, oldest first: the end of its transcript.
    func newestMessages(sessionID: String, limit: Int) async throws -> [StoredMessage] {
        try await get(ListEnvelope<StoredMessage>.self, "api/sessions/\(sessionID)/messages",
                      query: [.init(name: "order", value: "latest"), .init(name: "limit", value: String(limit))]).data
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

    /// Pin an open session to a model (`POST /api/sessions/{id}/model`). The provider goes as the
    /// gateway lists it: the bare "custom" bucket names no endpoint, and a lock on it fails the
    /// turn. Each later turn repeats the pick with `require_model_lock` (see the chat body).
    func lockSessionModel(id: String, model: String, provider: String?) async throws {
        var body: [String: JSONValue] = ["model": .string(model)]
        if let provider = provider?.nilIfEmpty { body["provider"] = .string(provider) }
        _ = try await requestJSON("POST", "api/sessions/\(id)/model", body: .object(body))
    }

    /// Answer a pending tool approval on a run. `choice` is once | session | always | deny.
    func respondApproval(runID: String, requestID: String?, choice: String) async throws {
        var body: [String: JSONValue] = ["choice": .string(choice)]
        if let requestID, !requestID.isEmpty { body["request_id"] = .string(requestID) }
        _ = try await requestJSON("POST", "v1/runs/\(runID)/approval", body: .object(body))
    }

    /// Rename / pin / archive / mark read or unread. Only the given fields are sent.
    func updateSession(id: String, title: String? = nil, pinned: Bool? = nil, archived: Bool? = nil, unread: Bool? = nil,
                       hidden: Bool? = nil) async throws {
        struct Body: Encodable { var title: String?; var pinned: Bool?; var archived: Bool?; var unread: Bool?; var hidden: Bool? }
        _ = try await send("PATCH", "api/sessions/\(id)", body: try Self.encoder.encode(Body(title: title, pinned: pinned, archived: archived,
                                                                                               unread: unread, hidden: hidden)))
    }

    /// What has become of a run (`GET /v1/runs/{id}`): "queued", "running", "waiting_for_approval",
    /// "stopping", or how it ended. Nil when the host no longer knows it (restarted, or long after).
    func runStatus(_ runID: String) async throws -> String? {
        do {
            return try await requestJSON("GET", "v1/runs/\(runID)")["status"]?.string
        } catch TransportError.http(let status, _) where status == 404 {
            return nil
        }
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

    /// Generic JSON call against the API server (bearer-authenticated). It and `get` are
    /// `@concurrent` so a long transcript is decoded off the main actor: with approachable
    /// concurrency a plain nonisolated async function runs on its caller's actor.
    @concurrent func requestJSON(_ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil) async throws -> JSONValue {
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

    @concurrent private func get<T: Decodable & Sendable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
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
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
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

/// Hermes API turns as runs: started in the conversation's session (`POST /v1/runs`) and followed
/// through their events (`GET /v1/runs/{id}/events`). A run goes on whatever becomes of the app.
/// The chat stream's turn doesn't: Hermes stops it the moment its stream is cut, so leaving a
/// conversation, iOS suspending the app or a network change ended the reply. So the app can let
/// go of a run (another conversation opened, the app closed) and take it up again.
///
/// Hermes 0.22 keeps a run's events for whoever asks again, from where they left off (`seq`,
/// sent back as `Last-Event-ID`). 0.21.x keeps them for the first listener only: after that the
/// run is asked after by its status (`GET /v1/runs/{id}`) until it ends, and the reply comes whole.
/// Runs don't put an agent's pictures (`MEDIA:` tags) into the reply as the chat stream does; the
/// app fetches them through the Dashboard when it has the login.
nonisolated struct HermesRuns: Sendable {
    var baseURL: URL
    var apiKey: String
    var headers: [String: String] = [:]

    /// How a run ended, by its own word.
    enum Ending: Equatable, Sendable {
        case completed
        /// Stopped, or interrupted (from another app, or Hermes restarting).
        case stopped
        case failed(String)
    }

    /// One event of a run, read.
    struct Decoded: Equatable, Sendable {
        var events: [TurnEvent] = []
        /// Its number in the run's events (0.22).
        var seq: Int?
        var ending: Ending?
    }

    /// A stretch of trouble reaching the host longer than this ends the following: the run is
    /// still asked after when the conversation is opened again.
    static let patience: TimeInterval = 30 * 60

    /// Starts a run; its id. Nil when the gateway has no runs (the turn goes by the chat stream).
    /// `key` is the message's own id: sent again (it never got its answer through), it finds the
    /// run it started instead of starting another (Hermes keeps the keys for a day, restarts or not).
    func start(_ body: some Encodable & Sendable, key: String?) async throws -> String? {
        var request = try StreamingHTTP.makeRequest(url: baseURL.appending(path: "v1/runs"), apiKey: apiKey, headers: headers, body: body)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        if let key { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        var (data, response) = try await StreamingHTTP.session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 409, String(decoding: data, as: UTF8.self).contains("idempotency") {
            // Sent again with something changed meanwhile (another model picked): Hermes refuses
            // the key, so it goes as a message of its own.
            request.setValue(nil, forHTTPHeaderField: "Idempotency-Key")
            (data, response) = try await StreamingHTTP.session.data(for: request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 || status == 405 { return nil }
        guard (200 ..< 300).contains(status) else {
            throw TransportError.http(status: status, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let run = try JSONValue.parse(data)["run_id"]?.string else { throw TransportError.malformed(String(localized: "Hermes started no run")) }
        return run
    }

    /// Follows a run to its end, handing on what it says: its events while they last; when they
    /// stop short, its events again from where they were (0.22), else its status until it ends.
    /// Returns when the run is over, or when the host no longer knows it; throws when it failed.
    /// Off the main actor: its events, parsed here, are many and can be the whole reply again.
    @concurrent func follow(_ run: String, yield: @escaping @Sendable (TurnEvent) -> Void) async throws {
        let progress = RunProgress(yield: yield)
        var replayable = true
        var troubleSince: Date?
        while true {
            try Task.checkCancellation()
            do {
                let ending: Ending?
                if replayable {
                    ending = try await watched(run, progress: progress)
                } else {
                    guard let polled = try await poll(run, progress: progress) else { return }
                    ending = polled
                }
                if let ending { return try Self.finish(ending) }
                troubleSince = nil
                // The events stopped short of the end. 0.22 numbers them and has them again from
                // where they stopped; 0.21.x doesn't, and a second listener may hear nothing.
                if !progress.numbered { replayable = false }
            } catch TransportError.http(404, _) where replayable {
                replayable = false   // 0.21.x: the run's events were for the first listener only
            } catch {
                guard !Task.isCancelled, Self.isTransient(error) else { throw error }
                let since = troubleSince ?? .now
                troubleSince = since
                guard Date.now.timeIntervalSince(since) < Self.patience else {
                    throw TransportError.streamLost(String(localized: "Hermes couldn't be reached for half an hour; the reply will be there when it can."))
                }
                try await Task.sleep(for: .seconds(min(15, max(1, Date.now.timeIntervalSince(since) / 2))))
            }
        }
    }

    /// Stops the run on the host (Stop), without waiting for the answer.
    func stop(_ run: String) {
        let api = HermesSessionsAPI(baseURL: baseURL, apiKey: apiKey, headers: headers)
        Task { _ = try? await api.requestJSON("POST", "v1/runs/\(run)/stop") }
    }

    /// The run's events, with its status looked at every few seconds beside them: on 0.21.x a
    /// listener that comes after another can be left with events that never come, so a run its
    /// status says is over, and its events don't, ends there.
    private func watched(_ run: String, progress: RunProgress) async throws -> Ending? {
        try await withThrowingTaskGroup(of: Ending?.self) { group in
            group.addTask { try await self.events(run, progress: progress) }
            group.addTask {
                let api = HermesSessionsAPI(baseURL: baseURL, apiKey: apiKey, headers: headers)
                while true {
                    try await Task.sleep(for: Self.watchEvery)
                    guard let state = try? await api.requestJSON("GET", "v1/runs/\(run)") else { continue }
                    let decoded = Self.decode(status: state, run: run)
                    if decoded.ending == nil {
                        // What it waits on a person for, should the events not say.
                        decoded.events.forEach(progress.hand)
                        continue
                    }
                    // Over: the events have a moment to say so themselves, with all they have.
                    try await Task.sleep(for: .seconds(3))
                    decoded.events.forEach(progress.hand)
                    return decoded.ending
                }
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    static let watchEvery: Duration = .seconds(5)

    /// The run's events, from after the last one handed on. Nil when they stopped before the run
    /// said how it ended.
    private func events(_ run: String, progress: RunProgress) async throws -> Ending? {
        var request = URLRequest(url: baseURL.appending(path: "v1/runs/\(run)/events"))
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let cursor = progress.cursor { request.setValue(String(cursor), forHTTPHeaderField: "Last-Event-ID") }
        let (http, chunks) = try await ChunkedResponse.start(request, session: StreamingHTTP.longSession)
        guard (200 ..< 300).contains(http.statusCode) else {
            var body = Data()
            for try await chunk in chunks where body.count < 300 { body.append(chunk) }
            throw TransportError.http(status: http.statusCode, body: String(decoding: body.prefix(300), as: UTF8.self))
        }
        var parser = SSEParser()
        var lines = LineBuffer()
        for try await chunk in chunks {
            for line in lines.append(chunk) {
                guard let sse = parser.feed(line: line), let decoded = Self.decode(sse, run: run),
                      progress.take(decoded.seq) else { continue }
                decoded.events.forEach(progress.hand)
                if let ending = decoded.ending { return ending }
            }
        }
        return nil
    }

    /// The run's status, every second or few, until it ends. Nil when the host doesn't know it.
    private func poll(_ run: String, progress: RunProgress) async throws -> Ending? {
        let api = HermesSessionsAPI(baseURL: baseURL, apiKey: apiKey, headers: headers)
        var wait = 1.0
        while true {
            try Task.checkCancellation()
            let state: JSONValue
            do {
                state = try await api.requestJSON("GET", "v1/runs/\(run)")
            } catch TransportError.http(404, _) {
                return nil
            }
            let decoded = Self.decode(status: state, run: run)
            decoded.events.forEach(progress.hand)
            if let ending = decoded.ending { return ending }
            try await Task.sleep(for: .seconds(wait))
            wait = min(wait * 1.5, 4)
        }
    }

    /// Where following a run has got to, shared by its events and its status: the last event
    /// handed on, and the approvals already put to the person.
    nonisolated final class RunProgress: @unchecked Sendable {
        private let lock = NSLock()
        private let yield: @Sendable (TurnEvent) -> Void
        private var _cursor: Int?
        private var asked: Set<String> = []

        init(yield: @escaping @Sendable (TurnEvent) -> Void) { self.yield = yield }

        /// The last numbered event handed on (0.22).
        var cursor: Int? { lock.withLock { _cursor } }
        /// The events came numbered: Hermes 0.22, which has them again from where they stopped.
        var numbered: Bool { cursor != nil }

        /// Whether an event numbered `seq` is new; an event asked for again from before isn't.
        func take(_ seq: Int?) -> Bool {
            lock.withLock {
                guard let seq else { return true }
                if let seen = _cursor, seq <= seen { return false }
                _cursor = seq
                return true
            }
        }

        /// Hands an event on; an approval only once, however often the host says it waits.
        func hand(_ event: TurnEvent) {
            if case let .interrupt(.approval(request), _) = event {
                guard lock.withLock({ asked.insert(request.id).inserted }) else { return }
            }
            yield(event)
        }
    }

    private static func finish(_ ending: Ending) throws {
        switch ending {
        case .completed: return
        case .stopped: throw TransportError.malformed(String(localized: "The agent stopped before it finished (stopped elsewhere, or Hermes restarted)."))
        case let .failed(message): throw TransportError.malformed(message)
        }
    }

    /// Trouble that passes: the connection, the host restarting behind a proxy, a timeout.
    static func isTransient(_ error: Error) -> Bool {
        if NetworkFailure.isConnectivity(error) { return true }
        if case .streamLost = error as? TransportError { return true }
        if case let .http(status, _) = error as? TransportError { return [408, 429, 500, 502, 503, 504].contains(status) }
        if let url = error as? URLError { return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .secureConnectionFailed].contains(url.code) }
        return false
    }

    // MARK: Reading

    /// One event of a run's stream (`data: {"event": …}`; 0.22 numbers them).
    static func decode(_ sse: SSEEvent, run: String) -> Decoded? {
        guard let json = try? JSONValue.parse(Data(sse.data.utf8)), let name = json["event"]?.string ?? sse.event else { return nil }
        var out = Decoded()
        out.seq = json["seq"]?.int ?? sse.id.flatMap { Int($0) }
        switch name {
        case "message.delta":
            if let delta = json["delta"]?.string, !delta.isEmpty { out.events = [.textDelta(delta)] }
        case "reasoning.available":
            if let text = json["text"]?.string, !text.isEmpty { out.events = [.reasoningDelta(text)] }
        case "tool.started":
            let call = ToolActivity.unwrapped(name: json["tool"]?.string ?? json["tool_name"]?.string ?? "tool", args: json["args"])
            out.events = [.toolStarted(name: call.name, preview: json["preview"]?.string?.nilIfEmpty, args: ToolActivity.args(call.name, call.args))]
        case "tool.completed", "tool.failed":
            let tool = ToolActivity.unwrapped(name: json["tool"]?.string ?? json["tool_name"]?.string ?? "", args: json["args"]).name
            out.events = [.toolFinished(name: tool == "tool_call" ? "" : tool,
                                        failed: name == "tool.failed" || json["error"]?.bool == true || json["is_error"]?.bool == true,
                                        output: json["preview"]?.string?.nilIfEmpty)]
        case "subagent.start", "subagent.tool", "subagent.progress", "subagent.complete":
            if let update = SubagentUpdate(event: name, json) { out.events = [.subagent(update)] }
        case "approval.request":
            let request = ApprovalRequest(payload: json)
            if !request.id.isEmpty { out.events = [.interrupt(.approval(request), runtimeSession: run)] }
        case "run.completed", "run.failed", "run.cancelled", "run.interrupted":
            out = decode(status: json, run: run, ending: name)
            out.seq = json["seq"]?.int ?? sse.id.flatMap { Int($0) }
        default:
            break
        }
        return out
    }

    /// A run's status (`GET /v1/runs/{id}`), or one of its closing events: the reply whole, what
    /// it cost, and how it ended; or what it waits on a person for.
    static func decode(status json: JSONValue, run: String, ending event: String? = nil) -> Decoded {
        var out = Decoded()
        let status = event.map { String($0.dropFirst("run.".count)) } ?? json["status"]?.string ?? ""
        switch status {
        case "completed":
            if let output = json["output"]?.string, !output.isEmpty { out.events.append(.textFinal(output)) }
            if let usage = json["usage"], let input = (usage["input_tokens"] ?? usage["prompt_tokens"])?.int {
                out.events.append(.usage(TokenUsage(input: input, output: (usage["output_tokens"] ?? usage["completion_tokens"])?.int ?? 0, cached: nil)))
            }
            out.ending = .completed
        case "failed":
            let message = json["error"]?.string ?? String(localized: "The run failed", comment: "Why a reply failed, when the server gave no reason")
            if HermesSessionsTransport.isLockBucketMismatch(message) {
                // The pre-0.21.4 check on a named endpoint, wrong about a turn that ran where it should.
                if let output = json["output"]?.string, !output.isEmpty { out.events.append(.textFinal(output)) }
                out.ending = .completed
            } else {
                out.ending = .failed(message)
            }
        case "cancelled", "interrupted":
            out.ending = .stopped
        case "waiting_for_approval":
            if let approval = json["approval"] {
                let request = ApprovalRequest(payload: approval)
                if !request.id.isEmpty { out.events = [.interrupt(.approval(request), runtimeSession: run)] }
            }
        default:
            break
        }
        return out
    }
}
