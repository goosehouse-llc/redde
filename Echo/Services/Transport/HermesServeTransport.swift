import Foundation

/// One turn over the desktop gateway. Opens/resumes the session, submits the prompt, and maps
/// the event stream to `TurnEvent`s until the turn ends. Slash commands go to `slash.exec`.
/// If the socket drops mid-turn, waits for the client to reconnect, re-attaches to the session,
/// and either keeps streaming (turn still running) or backfills the reply from history.
nonisolated struct HermesServeTransport: HermesTransport {
    /// Mutable per-turn state shared between the event listener and the driver.
    @MainActor
    private final class TurnState {
        var runtime: String
        var stored: String
        var streamed = ""
        var recovering = false
        /// The reconnect wait after a drop; cancelled with the turn so a stopped turn doesn't
        /// poll for 90 s and then pull the whole transcript into a finished continuation.
        var recoverTask: Task<Void, Never>?
        init(runtime: String, stored: String) { self.runtime = runtime; self.stored = stored }
    }

    func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                let client = HermesServeClient.shared
                var listener: UUID?
                var state: TurnState?
                defer {
                    if let listener { client.removeListener(listener) }
                    state?.recoverTask?.cancel()
                }
                do {
                    try await client.ensureConnected()
                    let (runtime, stored) = try await client.openSession(
                        stored: request.sessionID, model: request.model, provider: request.provider,
                        reasoningEffort: request.reasoningEffort)
                    let turn = TurnState(runtime: runtime, stored: stored)
                    state = turn
                    continuation.yield(.sessionID(stored))

                    if request.userText.hasPrefix("/") {
                        for event in try await Self.runSlash(request.userText, runtime: runtime, client: client) {
                            continuation.yield(event)
                        }
                        continuation.yield(.done)
                        continuation.finish()
                        return
                    }

                    let finished = AsyncStream<Result<Void, Error>>.makeStream()
                    listener = client.addListener { event in
                        let p = event.payload
                        switch event.type {
                        case "connection.lost":
                            guard !turn.recovering else { return }
                            turn.recovering = true
                            continuation.yield(.status("connection lost, reconnecting…"))
                            turn.recoverTask = Task { @MainActor in
                                await Self.recover(turn, client: client, continuation: continuation, finished: finished.continuation)
                            }
                            return
                        case "connection.restored":
                            return
                        default:
                            break
                        }
                        guard event.sessionID == turn.runtime else { return }
                        switch event.type {
                        case "message.delta":
                            if let t = p["text"]?.string, !t.isEmpty { turn.streamed += t; continuation.yield(.textDelta(t)) }
                        case "reasoning.delta", "reasoning.available":
                            if let t = p["text"]?.string { continuation.yield(.reasoningDelta(t)) }
                        case "tool.start":
                            continuation.yield(.toolStarted(name: p["name"]?.string ?? "tool", preview: p["context"]?.string))
                        case "tool.complete":
                            let failed = p["error"] != nil && !(p["error"]?.isNull ?? true)
                            continuation.yield(.toolFinished(name: p["name"]?.string ?? "", failed: failed))
                        case "subagent.start", "subagent.tool", "subagent.progress", "subagent.complete":
                            if let update = Self.parseSubagent(event.type, p) { continuation.yield(.subagent(update)) }
                        case "approval.request":
                            let req = ApprovalRequest(
                                id: p["request_id"]?.string ?? "",
                                command: p["command"]?.string ?? "",
                                description: p["description"]?.string,
                                choices: p["choices"]?.array?.compactMap(\.string) ?? ["once", "session", "always", "deny"])
                            continuation.yield(.interrupt(.approval(req), runtimeSession: turn.runtime))
                        case "clarify.request":
                            continuation.yield(.interrupt(.clarify(Self.parseClarify(p)), runtimeSession: turn.runtime))
                        case "sudo.request":
                            continuation.yield(.interrupt(.sudo(id: p["request_id"]?.string ?? ""), runtimeSession: turn.runtime))
                        case "secret.request":
                            let req = SecretRequest(id: p["request_id"]?.string ?? "", prompt: p["prompt"]?.string ?? "",
                                                    envVar: p["env_var"]?.string ?? "")
                            continuation.yield(.interrupt(.secret(req), runtimeSession: turn.runtime))
                        case "approval.expire", "clarify.expire", "sudo.expire", "secret.expire":
                            continuation.yield(.interruptExpired(id: p["request_id"]?.string ?? ""))
                        case "status.update":
                            if let t = p["text"]?.string { continuation.yield(.status(t)) }
                        case "message.complete":
                            // The turn's terminal event: final text (if nothing streamed), the
                            // authoritative usage, and the status.
                            if turn.streamed.isEmpty, let t = p["text"]?.string, !t.isEmpty { turn.streamed = t; continuation.yield(.textDelta(t)) }
                            if let u = p["usage"], let input = (u["input"] ?? u["prompt"])?.int {
                                continuation.yield(.usage(TokenUsage(input: input, output: (u["output"] ?? u["completion"])?.int ?? 0, cached: nil,
                                                                     contextUsed: u["context_used"]?.int, contextMax: u["context_max"]?.int)))
                            }
                            if p["status"]?.string == "error" {
                                finished.continuation.yield(.failure(TransportError.malformed(p["error"]?.string ?? p["text"]?.string ?? "run failed")))
                            } else {
                                finished.continuation.yield(.success(()))
                            }
                        case "session.usage":
                            // A periodic tick from the gateway while the turn runs (context occupancy
                            // for the footer). It says nothing about whether the turn is over.
                            if let u = p["usage"], let used = u["context_used"]?.int, let max = u["context_max"]?.int, max > 0 {
                                continuation.yield(.usage(TokenUsage(input: (u["input"] ?? u["prompt"])?.int ?? 0,
                                                                     output: (u["output"] ?? u["completion"])?.int ?? 0, cached: nil,
                                                                     contextUsed: used, contextMax: max)))
                            }
                        case "session.info":
                            if p["running"]?.bool == false { finished.continuation.yield(.success(())) }
                        case "error":
                            finished.continuation.yield(.failure(TransportError.malformed(p["message"]?.string ?? "gateway error")))
                        default:
                            break
                        }
                    }

                    for att in request.attachments {
                        try await Self.attach(att, runtime: runtime, client: client)
                    }
                    let submit = try await client.call("prompt.submit", params: .object([
                        "session_id": .string(runtime), "text": .string(request.userText)]))
                    if submit["status"]?.string == "queued" { continuation.yield(.status("queued behind a running turn…")) }

                    for await outcome in finished.stream {
                        if case let .failure(error) = outcome { throw error }
                        break
                    }
                    // Stop ends this loop by cancellation, which `for await` reports as a plain
                    // end of stream; without this the turn reads as done and the agent runs on.
                    try Task.checkCancellation()
                    continuation.yield(.done)
                    continuation.finish()
                } catch is CancellationError {
                    if let state { client.interrupt(runtimeSession: state.runtime) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Single form `{question, choices, multi_select?}` or batch `{questions: [{qid, …}]}`.
    /// `subagent.*` frames arrive on the parent session; the child is identified by `subagent_id`.
    nonisolated static func parseSubagent(_ type: String, _ p: JSONValue) -> SubagentUpdate? {
        guard let id = p["subagent_id"]?.string ?? p["child_session_id"]?.string else { return nil }
        let phase: SubagentUpdate.Phase
        switch type {
        case "subagent.start": phase = .started
        case "subagent.tool": phase = .tool(p["tool_name"]?.string ?? "tool")
        case "subagent.progress": phase = .progress(p["text"]?.string ?? "")
        case "subagent.complete":
            let status = p["status"]?.string ?? "success"
            phase = .completed(succeeded: !(status == "error" || status == "failed" || status == "timeout"),
                               summary: p["summary"]?.string ?? p["text"]?.string, duration: p["duration_seconds"]?.number)
        default: return nil
        }
        return SubagentUpdate(id: id, goal: p["goal"]?.string ?? "", taskIndex: p["task_index"]?.int ?? 0,
                              taskCount: p["task_count"]?.int ?? 1, depth: p["depth"]?.int ?? 0,
                              toolCount: p["tool_count"]?.int, childSessionID: p["child_session_id"]?.string,
                              model: p["model"]?.string, phase: phase)
    }

    nonisolated static func parseClarify(_ p: JSONValue) -> ClarifyRequest {
        let id = p["request_id"]?.string ?? ""
        if let batch = p["questions"]?.array, !batch.isEmpty {
            return ClarifyRequest(id: id, questions: batch.map {
                ClarifyQuestion(id: $0["qid"]?.string ?? "", question: $0["question"]?.string ?? "",
                                choices: $0["choices"]?.array?.compactMap(\.string) ?? [],
                                multiSelect: $0["multi_select"]?.bool ?? false)
            }, isBatch: true)
        }
        return ClarifyRequest(id: id, questions: [
            ClarifyQuestion(id: "", question: p["question"]?.string ?? "",
                            choices: p["choices"]?.array?.compactMap(\.string) ?? [],
                            multiSelect: p["multi_select"]?.bool ?? false)], isBatch: false)
    }

    /// After a drop: wait for the socket, re-attach, then continue or backfill.
    @MainActor
    private static func recover(_ turn: TurnState, client: HermesServeClient,
                                continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation,
                                finished: AsyncStream<Result<Void, Error>>.Continuation) async {
        guard await client.waitForConnection(timeout: 90) else {
            finished.yield(.failure(TransportError.malformed("lost the connection to Redde serve and couldn't get it back")))
            return
        }
        do {
            let info = try await client.resume(stored: turn.stored, withMessages: true)
            guard let runtime = info["session_id"]?.string else { throw TransportError.malformed("resume gave no session id") }
            turn.runtime = runtime
            turn.recovering = false
            continuation.yield(.status("reconnected"))
            if info["running"]?.bool == true {
                return // still generating; events now arrive under the new runtime id
            }
            // The turn finished while we were away: fill in whatever we missed.
            if let last = info["messages"]?.array?.last(where: { $0["role"]?.string == "assistant" }),
               let text = last["text"]?.string ?? last["content"]?.string, text.count > turn.streamed.count,
               text.hasPrefix(turn.streamed) {
                continuation.yield(.textDelta(String(text.dropFirst(turn.streamed.count))))
                turn.streamed = text
            }
            finished.yield(.success(()))
        } catch {
            finished.yield(.failure(error))
        }
    }

    /// Stages one attachment on the session; the next `prompt.submit` consumes it. The disk
    /// read and base64 of up to 8 MB happen off the main actor.
    @MainActor
    private static func attach(_ att: Attachment, runtime: String, client: HermesServeClient) async throws {
        let (method, params) = await Task.detached { Self.attachFrame(att, runtime: runtime) }.value
        try await client.call(method, params: params)
    }

    nonisolated private static func attachFrame(_ att: Attachment, runtime: String) -> (method: String, params: JSONValue) {
        switch att.kind {
        case .image:
            ("image.attach_bytes", .object(["session_id": .string(runtime), "content_base64": .string(att.data.base64EncodedString()),
                                            "filename": .string(att.filename)]))
        case .pdf:
            ("pdf.attach", .object(["session_id": .string(runtime), "content_base64": .string(att.data.base64EncodedString()),
                                    "filename": .string(att.filename)]))
        case .text, .other:
            ("file.attach", .object(["session_id": .string(runtime), "data_url": .string(att.dataURL), "name": .string(att.filename)]))
        }
    }

    /// `/help`, `/model`, custom user commands… `slash.exec` first; 4018 means "use dispatch".
    @MainActor
    private static func runSlash(_ text: String, runtime: String, client: HermesServeClient) async throws -> [TurnEvent] {
        let body = String(text.dropFirst())
        do {
            let result = try await client.call("slash.exec", params: .object(["session_id": .string(runtime), "command": .string(body)]))
            let output = result["output"]?.displayText ?? ""
            return [.textDelta(output.isEmpty ? "(no output)" : output)]
        } catch let error as HermesServeClient.RPCError where error.code == 4018 {
            let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
            let result = try await client.call("command.dispatch", params: .object([
                "session_id": .string(runtime), "name": .string(parts.first ?? body), "arg": .string(parts.count > 1 ? parts[1] : "")]))
            if result["type"]?.string == "send", let message = result["message"]?.string {
                _ = try await client.call("prompt.submit", params: .object(["session_id": .string(runtime), "text": .string(message)]))
                return [.status("running \(parts.first ?? body)…")]
            }
            let shown = result["display"]?.string ?? result["output"]?.displayText ?? result["message"]?.string ?? "(done)"
            return [.textDelta(shown)]
        }
    }
}
