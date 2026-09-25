import Foundation
import os

/// Events emitted while a turn streams back from the model.
nonisolated enum TurnEvent: Sendable, Equatable {
    /// A fragment of assistant text, in order.
    case textDelta(String)
    /// The backend's authoritative text for the reply, replacing whatever streamed. The API
    /// server rewrites `MEDIA:<path>` tags into inline images only in this final form, so a
    /// reply that sends a picture is wrong until it arrives.
    case textFinal(String)
    /// Backend is doing something other than emitting text (tool call, thinking). Informational.
    case status(String)
    /// Prompt-processing progress before the first token (llama.cpp `return_progress`,
    /// fast lane only). `cached` tokens were already in the KV cache.
    case prefill(processed: Int, total: Int, cached: Int)
    /// Token accounting for the turn, sent at the end of the stream.
    case usage(TokenUsage)
    /// A fragment of the model's reasoning ("thinking"), streamed live where the backend allows.
    case reasoningDelta(String)
    /// The agent started a tool call.
    case toolStarted(name: String, preview: String?)
    /// A tool call ended. `name` may be empty when the backend doesn't repeat it.
    case toolFinished(name: String, failed: Bool)
    /// A delegated child agent started, called a tool, or finished.
    case subagent(SubagentUpdate)
    /// Server-side session id (Hermes ledger) this turn belongs to.
    case sessionID(String)
    /// API-server run id for this turn; needed to steer or stop it.
    case runID(String)
    /// The agent is waiting on you (hermes serve): approval, clarifying question, sudo, secret.
    case interrupt(Interrupt, runtimeSession: String)
    /// A pending interrupt timed out on the gateway.
    case interruptExpired(id: String)
    /// Stream finished normally.
    case done
}

/// One tool call as shown in the transcript.
nonisolated struct ToolActivity: Identifiable, Equatable, Sendable, Codable {
    enum Status: String, Codable, Sendable { case running, completed, failed }
    var id: UUID = UUID()
    var name: String
    var preview: String?
    var status: Status
}

/// One delegated child agent, as seen from the parent turn. hermes serve streams these live;
/// the ledger SSE stream only reveals the goals, so rows there stay at "dispatched".
nonisolated struct SubagentActivity: Identifiable, Equatable, Sendable, Codable {
    enum Status: String, Codable, Sendable { case running, dispatched, completed, failed }
    var id: String               // subagent_id, or a synthesized delegate-tool id
    var goal: String
    var taskIndex: Int = 0
    var taskCount: Int = 1
    var depth: Int = 0
    var status: Status = .running
    var toolCount: Int = 0
    var lastTool: String?
    var summary: String?
    var durationSeconds: Double?
    var childSessionID: String?
    var model: String?
}

/// A live change to one subagent, carried by `TurnEvent.subagent`.
nonisolated struct SubagentUpdate: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case started, tool(String), progress(String), completed(succeeded: Bool, summary: String?, duration: Double?), dispatched }
    var id: String
    var goal: String
    var taskIndex: Int = 0
    var taskCount: Int = 1
    var depth: Int = 0
    var toolCount: Int?
    var childSessionID: String?
    var model: String?
    var phase: Phase
}

nonisolated struct TokenUsage: Equatable, Sendable, Codable {
    /// Prompt tokens. On the fast lane this is the context the model saw for the one call. On the
    /// Hermes backends it is the session's running total across every API call, so it must not
    /// be read as context size; `contextUsed` carries that when the gateway reports it.
    var input: Int
    var output: Int
    /// Prompt tokens served from the prefix cache (llama.cpp reports this; the gateway doesn't).
    var cached: Int?
    /// Current context occupancy and window, when the backend states them.
    var contextUsed: Int? = nil
    var contextMax: Int? = nil

    var total: Int { input + output }
}

/// What the client sends for one turn.
nonisolated struct TurnRequest: Sendable {
    var userText: String
    /// Prior turns, oldest first, for stateless backends. Ignored when threading by id.
    var history: [Message]
    /// Hermes ledger session id (sessions transport). Created on first turn when nil.
    var sessionID: String?
    var model: String?
    var provider: String?
    /// "" or nil = gateway default; low | medium | high.
    var reasoningEffort: String?
    var instructions: String?
    var attachments: [Attachment] = []
}

/// One selectable model as the gateway lists it.
nonisolated struct ModelChoice: Identifiable, Equatable, Sendable, Codable {
    var id: String { provider + "/" + model }
    var provider: String        // slug
    var providerName: String
    var model: String
    var name: String
    var isCurrent: Bool
}

nonisolated enum TransportError: LocalizedError {
    case badURL
    case missingAPIKey
    case http(status: Int, body: String)
    case malformed(String)
    /// The server couldn't be reached before the turn was handed over; safe to send again later.
    case unreachable(String)
    /// The connection dropped after the server had the request; sending again could repeat it.
    case streamLost(String)

    var errorDescription: String? {
        switch self {
        case .badURL: "The endpoint URL is invalid."
        case .missingAPIKey: "No API key is stored. Add one in Settings."
        case let .http(status, body):
            "Server returned HTTP \(status)." + (body.isEmpty ? "" : " \(body.prefix(300))")
        case let .malformed(detail): "Unexpected response: \(detail)"
        case let .unreachable(detail): detail
        case let .streamLost(detail): "The connection dropped mid-reply: \(detail)"
        }
    }
}

/// Tells a connection that never reached the server apart from every other failure, so the
/// conversation can hold the message and send it later instead of reporting an error.
nonisolated enum NetworkFailure {
    private static let urlCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
        .timedOut, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive,
    ]
    /// ENETDOWN, ENETUNREACH, ECONNRESET, ENOTCONN, ETIMEDOUT, ECONNREFUSED, EHOSTDOWN, EHOSTUNREACH.
    private static let posixCodes: Set<Int> = [50, 51, 54, 57, 60, 61, 64, 65]

    static func isConnectivity(_ error: Error) -> Bool {
        if let transport = error as? TransportError {
            if case .unreachable = transport { return true }
            return false
        }
        if let url = error as? URLError { return urlCodes.contains(url.code) }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return urlCodes.contains(URLError.Code(rawValue: ns.code)) }
        if ns.domain == NSPOSIXErrorDomain { return posixCodes.contains(ns.code) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isConnectivity(underlying) }
        return false
    }
}

nonisolated protocol HermesTransport: Sendable {
    func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error>
}

/// Shared plumbing: build a request, open the byte stream, surface non-2xx bodies as errors,
/// and hand SSE events to a per-transport decoder.
/// Splits a byte stream into lines, keeping the trailing newline so SSE's blank-line event
/// delimiters survive. Pure and testable.
nonisolated struct LineBuffer: Sendable {
    private var pending: [UInt8] = []

    /// Feed a chunk; returns every complete line it closes (each ending in "\n").
    mutating func append(_ data: Data) -> [String] {
        pending.append(contentsOf: data)
        var lines: [String] = []
        var start = 0
        while let nl = pending[start...].firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[start...nl], as: UTF8.self))
            start = nl + 1
        }
        if start > 0 { pending.removeFirst(start) }
        return lines
    }

    /// Whatever is left without a newline (a final line the server didn't terminate).
    mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}

/// Delivers a response body as `Data` chunks through a delegate, instead of `AsyncBytes`'
/// one-suspension-per-byte iteration. A token stream or a 48 kB/s PCM stream is hundreds of
/// chunks per second at most, not tens of thousands of awaits.
nonisolated final class ChunkedResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var response: CheckedContinuation<HTTPURLResponse, Error>?
        var stream: AsyncThrowingStream<Data, Error>.Continuation?
        var finished = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let chunks: AsyncThrowingStream<Data, Error>

    private override init() {
        let (stream, cont) = AsyncThrowingStream<Data, Error>.makeStream()
        chunks = stream
        super.init()
        state.withLock { $0.stream = cont }
    }

    /// Starts the request and returns once headers arrive. Cancelling the calling task cancels it.
    static func start(_ request: URLRequest, session: URLSession) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let delegate = ChunkedResponse()
        let task = session.dataTask(with: request)
        task.delegate = delegate
        delegate.state.withLock { $0.stream?.onTermination = { (_: AsyncThrowingStream<Data, Error>.Continuation.Termination) in task.cancel() } }
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<HTTPURLResponse, Error>) in
                delegate.state.withLock { $0.response = c }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return (response, delegate.chunks)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let c = state.withLock { s -> CheckedContinuation<HTTPURLResponse, Error>? in defer { s.response = nil }; return s.response }
        if let http = response as? HTTPURLResponse { c?.resume(returning: http) }
        else { c?.resume(throwing: TransportError.malformed("not an HTTP response")) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        _ = state.withLock { $0.stream?.yield(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (respond, stream) = state.withLock { s -> (CheckedContinuation<HTTPURLResponse, Error>?, AsyncThrowingStream<Data, Error>.Continuation?) in
            defer { s.response = nil; s.finished = true }
            return (s.response, s.stream)
        }
        if let error {
            respond?.resume(throwing: error)
            stream?.finish(throwing: error)
        } else {
            respond?.resume(throwing: TransportError.malformed("connection closed before headers"))
            stream?.finish()
        }
    }
}

nonisolated enum StreamingHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120 // time between bytes; agent tool calls can be slow
        config.timeoutIntervalForResource = 600
        // Fail fast when there's no network: the conversation holds the message and retries,
        // rather than showing "thinking" for minutes while URLSession waits.
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": "Redde/\(Bundle.main.shortVersion) iOS"]
        return URLSession(configuration: config)
    }()

    static func makeRequest(url: URL, apiKey: String?, body: some Encodable) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        request.httpBody = try encoder.encode(body)
        return request
    }

    /// Runs the request and yields decoded events. `makeRequest` builds the body inside the
    /// stream's own task, off the main actor: base64 of a photo and the JSON of a long history
    /// are not something to do on the UI thread between the tap and the first token. `decode`
    /// turns one SSE event into zero or more `TurnEvent`s and returns `true` when the stream is
    /// logically complete.
    static func run(
        decode: @escaping @Sendable (SSEEvent) throws -> (events: [TurnEvent], finished: Bool),
        makeRequest: @escaping @Sendable () throws -> URLRequest
    ) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var headersArrived = false
                do {
                    let request = try makeRequest()
                    let (http, chunks) = try await ChunkedResponse.start(request, session: session)
                    headersArrived = true
                    guard (200 ..< 300).contains(http.statusCode) else {
                        var body = Data()
                        for try await chunk in chunks where body.count < 2000 { body.append(chunk) }
                        throw TransportError.http(status: http.statusCode, body: String(decoding: body.prefix(2000), as: UTF8.self))
                    }
                    var parser = SSEParser()
                    var finished = false
                    // Split on raw newlines: `AsyncBytes.lines` would swallow the blank lines that
                    // delimit SSE events, and per-byte iteration is far too slow for a token stream.
                    var lineBuffer = LineBuffer()
                    outer: for try await chunk in chunks {
                        for line in lineBuffer.append(chunk) {
                            guard let event = parser.feed(line: line) else { continue }
                            let (events, done) = try decode(event)
                            events.forEach { continuation.yield($0) }
                            if done { finished = true; break outer }
                        }
                    }
                    if !finished, let rest = lineBuffer.flush() {
                        for event in parser.feed(rest + "\n") {
                            let (events, _) = try decode(event)
                            events.forEach { continuation.yield($0) }
                        }
                    }
                    if !finished, let last = parser.finish() {
                        let (events, _) = try decode(last)
                        events.forEach { continuation.yield($0) }
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    // Once headers are back the server has the turn: a dropped connection now is not
                    // something to send again.
                    if headersArrived, NetworkFailure.isConnectivity(error) {
                        continuation.finish(throwing: TransportError.streamLost(error.localizedDescription))
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

nonisolated extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}


/// One clarifying question from the agent's `clarify` tool.
nonisolated struct ClarifyQuestion: Identifiable, Equatable, Sendable, Codable {
    var id: String          // qid ("" for the single-question form)
    var question: String
    var choices: [String]
    var multiSelect: Bool
}

nonisolated struct ClarifyRequest: Identifiable, Equatable, Sendable, Codable {
    var id: String          // request_id
    var questions: [ClarifyQuestion]
    /// Batched requests answer per question_id; the single form answers the request as a whole.
    var isBatch: Bool
}

nonisolated struct SecretRequest: Identifiable, Equatable, Sendable, Codable {
    var id: String
    var prompt: String
    var envVar: String
}

/// OpenAI-style multimodal input: text alone stays a string; with attachments it becomes
/// parts. Both parts dialects (sessions `input_*`, chat-completions bare names with a nested
/// image_url object) share this: text files inline into the prose, and anything else is
/// refused up front with the transport's name in the error.
nonisolated enum MultimodalInput {
    static func make(text: String, attachments: [Attachment],
                     textType: String, imageType: String, nestedImageURL: Bool,
                     transportName: String) throws -> JSONValue {
        guard !attachments.isEmpty else { return .string(text) }
        var parts: [JSONValue] = []
        var prose = text
        for att in attachments {
            switch att.kind {
            case .image:
                let url: JSONValue = nestedImageURL ? .object(["url": .string(att.dataURL)]) : .string(att.dataURL)
                parts.append(.object(["type": .string(imageType), "image_url": url]))
            case .text:
                if let add = att.promptAddendum { prose += "\n\n" + add }
            case .pdf, .other:
                throw AttachmentError.unsupported(att.kind == .pdf ? "PDF" : "File", transport: transportName)
            }
        }
        if !prose.isEmpty { parts.insert(.object(["type": .string(textType), "text": .string(prose)]), at: 0) }
        return .array(parts)
    }
}

/// Everything the gateway can pause a turn on.
nonisolated enum Interrupt: Equatable, Sendable {
    case approval(ApprovalRequest)
    case clarify(ClarifyRequest)
    case sudo(id: String)
    case secret(SecretRequest)

    var id: String {
        switch self {
        case let .approval(r): r.id
        case let .clarify(r): r.id
        case let .sudo(id): id
        case let .secret(r): r.id
        }
    }
}
