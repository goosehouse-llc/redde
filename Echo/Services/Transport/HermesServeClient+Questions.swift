import Foundation

// HermesServeClient's questions from the host (approvals, clarify, sudo, secrets) and the answers to them.
extension HermesServeClient {
    // MARK: - Questions from the host

    /// The questions the Dashboard asks of its client that Redde can put to a person.
    nonisolated static let promptMethods: Set<String> = ["approval", "clarify", "sudo", "secret"]

    /// A JSON-RPC id as a dictionary key (Hermes uses strings, `srq-…`; a number is allowed).
    nonisolated static func key(_ id: JSONValue?) -> String? {
        id?.string ?? id?.int.map(String.init)
    }

    /// Hermes 0.21.3 and later ask for an approval, an answer, the sudo password or a secret as
    /// a JSON-RPC *request* to the client, answered by the response frame with the same id.
    /// Hermes 0.21.0 sent a `<kind>.request` notification, answered by a `<kind>.respond` call.
    /// A client that only knows the old way never sees the question, and the command is
    /// refused. Both forms carry the same fields, so the request is handed to listeners as the
    /// notification, its frame id standing in as `request_id`, and one path draws the card. The
    /// answer goes back the way the question came (`answer`).
    nonisolated static func prompt(method: String, id: String, params: JSONValue) -> Event? {
        guard promptMethods.contains(method) else { return nil }
        var payload = params.object ?? [:]
        payload["request_id"] = .string(id)
        return ("\(method).request", params["session_id"]?.string, .object(payload))
    }

    /// Answers a question that came as a request, with the response frame it is waiting for.
    /// False when it didn't come that way (an older host): the caller answers by method call.
    private func answer(_ requestID: String, _ result: [String: JSONValue]) -> Bool {
        guard let open = openRequests.removeValue(forKey: requestID) else { return false }
        send(.object(["jsonrpc": .string("2.0"), "id": open.id, "result": .object(result)]))
        return true
    }

    /// Questions still waiting from before this connection, as a `session.resume` result lists
    /// them: put to listeners again, under the session's id as resumed, so a card lost with the
    /// socket comes back. Returns how many the session is waiting on.
    ///
    /// Hermes 0.21.0 has no such list, but says which approval is pending; that one is put the
    /// way that release asks (and is answered by `approval.respond`, having no frame to answer).
    /// `includingKnown` puts again those this connection heard already: for a turn being joined,
    /// whose listener wasn't there when they came.
    @discardableResult
    func replayOpenRequests(in resumed: JSONValue, includingKnown: Bool = false) -> Int {
        let session = resumed["session_id"]?.string
        let open = resumed["open_requests"]?.array ?? []
        for request in open {
            guard let id = request["id"], let key = Self.key(id), includingKnown || openRequests[key] == nil, let method = request["method"]?.string,
                  var event = Self.prompt(method: method, id: key, params: request["params"] ?? .null) else { continue }
            event.sessionID = session ?? event.sessionID
            openRequests[key] = (id, method)
            for l in listeners.values { l(event) }
        }
        if open.isEmpty, let pending = resumed["pending_approval"], pending["request_id"]?.string != nil {
            for l in listeners.values { l(("approval.request", session, pending)) }
            return 1
        }
        return open.count
    }

    /// What became of an answer given without the card: from a notification's buttons.
    enum WaitingApproval: Equatable, Sendable {
        case answered
        /// Nothing is waiting any more: answered elsewhere, timed out, or the turn was stopped.
        case nothingWaiting
        /// A command is waiting, but not the one the person was shown.
        case anotherCommand
    }

    /// Answers the approval a stored session is waiting on, for a client that wasn't there when
    /// it was asked: the app, started in the background by a notification's Approve or Deny.
    /// `digest` is of the command the notification showed (`PushNote.digest`); a yes or no meant
    /// for one command is never given to another.
    func answerWaitingApproval(stored: String, digest: String, approve: Bool) async throws -> WaitingApproval {
        try await ensureConnected()
        let resumed = try await call("session.resume", params: .object(["session_id": .string(stored), "omit_messages": .bool(true)]))
        guard let runtime = resumed["session_id"]?.string else { throw TransportError.malformed("resume gave no session id") }
        runtimeIDs[stored] = runtime
        func choice(_ request: ApprovalRequest) -> String { (approve ? request.yesNo?.approve : request.yesNo?.deny) ?? (approve ? "once" : "deny") }
        if let waiting = resumed["open_requests"]?.array?.first(where: { $0["method"]?.string == "approval" }), let id = waiting["id"] {
            let request = HermesServeTransport.parseApproval(waiting["params"] ?? .null)
            guard PushNote.digest(of: request.command) == digest else { return .anotherCommand }
            if let key = Self.key(id) { openRequests[key] = nil }
            send(.object(["jsonrpc": .string("2.0"), "id": id, "result": .object(["choice": .string(choice(request))])]))
            return .answered
        }
        // Hermes 0.21.0: no list of open requests; the pending approval is answered by call.
        if let pending = resumed["pending_approval"], let requestID = pending["request_id"]?.string {
            let request = HermesServeTransport.parseApproval(pending)
            guard PushNote.digest(of: request.command) == digest else { return .anotherCommand }
            try await call("approval.respond", params: .object(["session_id": .string(runtime), "request_id": .string(requestID),
                                                                 "choice": .string(choice(request))]))
            return .answered
        }
        return .nothingWaiting
    }

    /// What became of an answer to a question given without the card.
    enum WaitingQuestion: Equatable, Sendable {
        case answered
        /// No question is waiting any more: answered elsewhere, timed out, or the turn stopped.
        /// Also what a Hermes that keeps no list of what it waits on (0.21.0) always gives.
        case nothingWaiting
        /// Something is being asked, but not what the person was shown: another question, or
        /// several at once.
        case anotherQuestion
    }

    /// Answers the question a stored session is waiting on, for a client that wasn't there when
    /// it was asked: the app, started in the background by a reply on the notification. `digest`
    /// is of the question the notification showed (`PushNote.digest`); an answer meant for one
    /// question is never given to another.
    func answerWaitingQuestion(stored: String, digest: String, answer: String) async throws -> WaitingQuestion {
        try await ensureConnected()
        let resumed = try await call("session.resume", params: .object(["session_id": .string(stored), "omit_messages": .bool(true)]))
        guard let runtime = resumed["session_id"]?.string else { throw TransportError.malformed("resume gave no session id") }
        runtimeIDs[stored] = runtime
        guard let waiting = resumed["open_requests"]?.array?.first(where: { $0["method"]?.string == "clarify" }),
              let id = waiting["id"], let key = Self.key(id) else { return .nothingWaiting }
        let request = HermesServeTransport.parseClarify(waiting["params"] ?? .null)
        guard request.questions.count == 1, let question = request.questions.first,
              PushNote.digest(of: question.question) == digest else { return .anotherQuestion }
        if question.id.isEmpty {
            openRequests[key] = nil
            send(.object(["jsonrpc": .string("2.0"), "id": id, "result": .object(["answer": .string(answer)])]))
        } else {
            // Asked as a list of one: answered a question at a time, and the last answer settles it.
            try await call("clarify.lock", params: .object(["request_id": .string(key), "question_id": .string(question.id), "answer": .string(answer)]))
            openRequests[key] = nil
        }
        return .answered
    }

    // Each answer goes back the way its question came: the response frame for a request
    // (Hermes 0.21.3 and later), the `<kind>.respond` call for a notification (0.21.0).

    func respondApproval(runtimeSession: String, requestID: String, choice: String) async throws {
        if answer(requestID, ["choice": .string(choice)]) { return }
        try await call("approval.respond", params: .object(["session_id": .string(runtimeSession),
                                                             "request_id": .string(requestID), "choice": .string(choice)]))
    }

    /// Single-question clarify: `answer`. Batched: one call per `question_id`.
    func respondClarify(runtimeSession: String, requestID: String, questionID: String?, answer text: String) async throws {
        if openRequests[requestID] != nil {
            guard let questionID, !questionID.isEmpty else {
                _ = answer(requestID, ["answer": .string(text)])
                return
            }
            // A batch is answered a question at a time; the last one settles the request.
            let result = try await call("clarify.lock", params: .object(["request_id": .string(requestID),
                                                                         "question_id": .string(questionID), "answer": .string(text)]))
            if result["remaining"]?.array?.isEmpty ?? true { openRequests[requestID] = nil }
            return
        }
        var params: [String: JSONValue] = ["session_id": .string(runtimeSession), "request_id": .string(requestID), "answer": .string(text)]
        if let questionID, !questionID.isEmpty { params["question_id"] = .string(questionID) }
        try await call("clarify.respond", params: .object(params))
    }

    func respondSudo(runtimeSession: String, requestID: String, password: String) async throws {
        if answer(requestID, ["value": .string(password)]) { return }
        try await call("sudo.respond", params: .object(["session_id": .string(runtimeSession), "request_id": .string(requestID), "password": .string(password)]))
    }

    /// Empty value = skip; the gateway records the secret as not provided.
    func respondSecret(runtimeSession: String, requestID: String, value: String) async throws {
        if answer(requestID, ["value": .string(value)]) { return }
        try await call("secret.respond", params: .object(["session_id": .string(runtimeSession), "request_id": .string(requestID), "value": .string(value)]))
    }
}
