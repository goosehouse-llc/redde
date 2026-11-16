import Foundation

// HermesServeClient's sessions: open, resume, history, projects, live switches, and the session calls.
extension HermesServeClient {
    // MARK: - Sessions

    /// Runtime session id for a stored session (resuming it), or a fresh session when nil.
    /// Returns (runtime id, stored id). A fresh session works in `folder` when one is given (a
    /// project's): that is what puts it in the project.
    /// `hidden`: a fresh session no app lists (an incognito chat's).
    /// `profile`: a fresh session on that profile rather than the selected one; every later call
    /// about it names it.
    func openSession(stored: String?, model: String? = nil, provider: String? = nil, reasoningEffort: String? = nil,
                     folder: String? = nil, hidden: Bool = false, profile: String? = nil,
                     requestID: String? = nil) async throws -> (runtime: String, stored: String) {
        if let stored {
            let runtime: String
            if let cached = runtimeIDs[stored] {
                runtime = cached
            } else {
                let result = try await call("session.resume", params: .object(["session_id": .string(stored), "omit_messages": .bool(true)]))
                guard let id = result["session_id"]?.string else { throw TransportError.malformed("resume: no session id") }
                runtimeIDs[stored] = id
                runtime = id
                if let info = result["info"] { ChatControlStore.shared.note(info, for: stored) }
            }
            // A resumed session runs at the level that chat last used, not the phone's pick. The
            // level is a phone setting and follows the user into every session they open, so the
            // first turn on a session this connection hasn't pinned yet re-pins it. A failure (an
            // old host, a level this model refuses) must not block the turn.
            if let reasoningEffort, !reasoningEffort.isEmpty, pinnedEfforts[runtime] != reasoningEffort {
                try? await setSessionReasoning(runtimeSession: runtime, effort: reasoningEffort)
            }
            return (runtime, stored)
        }
        // "desktop", not "mobile": the source picks the platform hint in the agent's system
        // prompt, and hermes has no hint for "mobile" — the agent was told nothing about this
        // surface and would refuse to send images. The desktop hint teaches what Redde actually
        // renders: full GitHub markdown, and files delivered as MEDIA:/path tags, which the app
        // fetches via resolveServeMedia. (Desktop-only tools like terminal.read fail gracefully:
        // an unanswered server→client request returns empty.) Existing sessions keep their
        // stored source; only new conversations pick this up.
        var params: [String: JSONValue] = ["source": .string("desktop"), "close_on_disconnect": .bool(false)]
        if let model, !model.isEmpty { params["model"] = .string(model) }
        if let provider, !provider.isEmpty { params["provider"] = .string(provider) }
        if let reasoningEffort, !reasoningEffort.isEmpty { params["reasoning_effort"] = .string(reasoningEffort) }
        if let folder, !folder.isEmpty { params["cwd"] = .string(folder) }
        if hidden { params["hidden"] = .bool(true) }
        if let profile { params["profile"] = .string(profile) }
        params = HermesServeWire.create(params, canonical: usesSessionAuthority, requestID: requestID ?? UUID().uuidString)
        let result = try await call("session.create", params: .object(params))
        guard let runtime = result["session_id"]?.string else { throw TransportError.malformed("create: no session id") }
        let storedID = result["stored_session_id"]?.string ?? runtime
        if let profile { noteProfile(profile, forStored: storedID) }
        runtimeIDs[storedID] = runtime
        if let info = result["info"] { ChatControlStore.shared.note(info, for: storedID) }
        if let reasoningEffort, !reasoningEffort.isEmpty { pinnedEfforts[runtime] = reasoningEffort }
        return (runtime, storedID)
    }

    /// Re-attaches to a stored session after a reconnect. Returns the raw resume payload
    /// (`session_id`, `running`, `messages` when requested) and refreshes the runtime id map.
    func resume(stored: String, withMessages: Bool) async throws -> JSONValue {
        let result = try await call("session.resume", params: .object(["session_id": .string(stored), "omit_messages": .bool(!withMessages)]))
        if let runtime = result["session_id"]?.string { runtimeIDs[stored] = runtime }
        if let info = result["info"] { ChatControlStore.shared.note(info, for: stored) }
        return result
    }

    /// Hermes's refusal to resume a Kanban worker's session (RPC 4132, newer than 0.22.2): a
    /// resumed chat would be a writer the board can't watch. Its transcript is still there to read.
    nonisolated static func refusesWorkerRun(_ error: Error) -> Bool {
        guard let refusal = error as? RPCError else { return false }
        return refusal.code == 4132 || refusal.message.localizedCaseInsensitiveContains("Kanban worker transcript")
    }

    /// A stored session's newest messages, oldest first, from the Dashboard's messages page
    /// (0.21.0 onward): reading it doesn't resume the session. `limit` is what the caller needs —
    /// the whole transcript's 500 by default, one row for a caller asking only whether the host
    /// has moved on since its copy (`catchUp`).
    func transcript(stored: String, limit: Int = 500) async throws -> [HermesSessionsAPI.StoredMessage] {
        let data = try await rest("GET", "api/sessions/\(stored)/messages?order=latest&limit=\(limit)", body: nil, timeout: 120, about: stored)
        return try await Self.messagesPage(data)
    }

    /// The messages page read off the main actor (half a megabyte for 500 messages).
    @concurrent nonisolated private static func messagesPage(_ data: Data) async throws -> [HermesSessionsAPI.StoredMessage] {
        struct Page: Decodable { var messages: [HermesSessionsAPI.StoredMessage] }
        return try JSONDecoder().decode(Page.self, from: data).messages
    }

    func history(stored: String) async throws -> [JSONValue] {
        // The socket may have dropped since the list was fetched; opening a session must not
        // fail just because nothing has used the link in a while. A long transcript also takes
        // the host a while to assemble, so this one gets more than the default minute.
        try await ensureConnected()
        let result = try await call("session.resume",
                                    params: .object(["session_id": .string(stored), "omit_messages": .bool(false)]),
                                    timeout: 180)
        if let runtime = result["session_id"]?.string { runtimeIDs[stored] = runtime }
        if let info = result["info"] { ChatControlStore.shared.note(info, for: stored) }
        hostTodos[stored] = TodoList.list(result["todo_state"])
        return result["messages"]?.array ?? []
    }

    // MARK: - Projects (sessions grouped by working directory / repo)

    nonisolated struct Project: Identifiable, Sendable, Equatable {
        var id: String
        var label: String
        var path: String?
        var isHome: Bool
        /// Found by Hermes (a repository its conversations ran in), not made by anyone.
        var isAuto: Bool
        var sessionCount: Int
        var lastActive: Date?
        var totalCost: Double
        var lanes: [Lane]

        /// Made by someone, here or in Hermes Desktop: a name of its own over a folder, which can
        /// be renamed and removed.
        var isOwn: Bool { !isAuto && !isHome }

        /// The projects the list shows: Hermes's catch-all for conversations in none first, then
        /// the most recently used. One someone made shows before its first conversation; one
        /// Hermes found, only once it has some.
        static func listed(_ all: [Project]) -> [Project] {
            all.filter { $0.sessionCount > 0 || $0.isOwn }
                .sorted { a, b in
                    if a.isHome != b.isHome { return a.isHome }
                    return (a.lastActive ?? .distantPast) > (b.lastActive ?? .distantPast)
                }
        }

        nonisolated struct Lane: Identifiable, Sendable, Equatable {
            var id: String
            var label: String
            var repoLabel: String?
            var sessions: [HermesSessionsAPI.SessionSummary]
        }

        init?(_ j: JSONValue) {
            guard let id = j["id"]?.string else { return nil }
            self.id = id
            label = j["label"]?.string ?? id
            path = j["path"]?.string
            isHome = j["isNoProject"]?.bool ?? (id == "__no_project__")
            // Said by 0.21.0 and later; without it, a project counts as found, so an empty one stays out of the list.
            isAuto = j["isAuto"]?.bool ?? true
            sessionCount = j["sessionCount"]?.int ?? 0
            lastActive = j["lastActive"]?.number.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            totalCost = j["totalCostUsd"]?.number ?? 0
            var lanes: [Lane] = []
            for repo in j["repos"]?.array ?? [] {
                let repoLabel = repo["label"]?.string
                for g in repo["groups"]?.array ?? [] {
                    guard let gid = g["id"]?.string else { continue }
                    // One encode/decode per lane, not per row.
                    let rows: [HermesSessionsAPI.SessionSummary] = (g["sessions"]).flatMap { sessions in
                        (try? JSONEncoder().encode(sessions)).flatMap { try? JSONDecoder().decode([HermesSessionsAPI.SessionSummary].self, from: $0) }
                    } ?? []
                    lanes.append(Lane(id: gid, label: g["label"]?.string ?? "main", repoLabel: repoLabel, sessions: rows))
                }
            }
            self.lanes = lanes
        }
    }

    /// Project overview: counts and a few previews per project, no session rows in lanes.
    func projectTree() async throws -> [Project] {
        try await ensureConnected()
        let result = try await call("projects.tree", params: .object(["preview_limit": .number(0)]))
        return (result["projects"]?.array ?? []).compactMap(Project.init)
    }

    /// One project with every lane's sessions.
    func projectSessions(_ projectID: String) async throws -> Project? {
        try await ensureConnected()
        let result = try await call("projects.project_sessions", params: .object(["project_id": .string(projectID)]))
        return result["project"].flatMap(Project.init)
    }

    /// A REST call: the cookie is enough, no need to bring the WebSocket up for a list.
    func listSessions(limit: Int = 100) async throws -> [HermesSessionsAPI.SessionSummary] {
        let data = try await rest("GET", "api/sessions?limit=\(limit)&offset=0&order=recent", body: nil as Data?)
        struct Envelope: Decodable { var sessions: [HermesSessionsAPI.SessionSummary]? ; var data: [HermesSessionsAPI.SessionSummary]? }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return env.sessions ?? env.data ?? []
    }

    /// One stored session as the Dashboard keeps it (`GET /api/sessions/{id}`, its database row:
    /// tokens, cost and its status, billing, folder, the model's settings), for the chat's
    /// Session Details. In the profile named, else the one the session was listed in.
    func sessionDetail(stored: String, profile: String?) async throws -> JSONValue {
        var path = "api/sessions/" + (stored.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stored)
        if let profile, let name = profile.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { path += "?profile=\(name)" }
        return try JSONValue.parse(try await rest("GET", path, body: nil, about: stored))
    }

    /// Every profile's sessions at once, each with its profile, newest first
    /// (`GET /api/profiles/sessions`, Hermes 0.21.0 on): the chat list with All Profiles on.
    func allProfileSessions(limit: Int = 150) async throws -> [HermesSessionsAPI.SessionSummary] {
        let data = try await rest("GET", "api/profiles/sessions?profile=all&order=recent&limit=\(limit)", body: nil as Data?)
        struct Page: Decodable { var sessions: [HermesSessionsAPI.SessionSummary]? }
        return try JSONDecoder().decode(Page.self, from: data).sessions ?? []
    }

    /// A profile's archived sessions, hidden ones included (the Dashboard's list, Hermes 0.22): a
    /// bot's earlier chats are among them (`EarlierBotChats`).
    func archivedSessions(profile: String, limit: Int = 100) async throws -> [HermesSessionsAPI.SessionSummary] {
        let name = profile.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profile
        let data = try await rest("GET", "api/profiles/sessions?profile=\(name)&archived=only&order=recent&limit=\(limit)", body: nil as Data?)
        struct Page: Decodable { var sessions: [HermesSessionsAPI.SessionSummary]? }
        return try JSONDecoder().decode(Page.self, from: data).sessions ?? []
    }

    /// Switch a live session's model (`config.set key=model`); the swap is deferred if a turn is
    /// streaming. The value is a `/model` line, so the provider goes along as `--provider`.
    func setSessionModel(runtimeSession: String, model: String, provider: String? = nil) async throws {
        let result = try await call("config.set", params: .object([
            "session_id": .string(runtimeSession), "key": .string("model"),
            "value": .string(Self.modelSwitchValue(model: model, provider: provider))]))
        if result["confirm_required"]?.bool == true {
            throw TransportError.malformed(result["confirm_message"]?.string ?? String(localized: "The backend wants confirmation for this model."))
        }
    }

    /// The `/model` line for a live switch. Naming the provider matters: a session on a named
    /// custom endpoint reports its provider as the bare "custom", and a bare model name is
    /// re-resolved under that — which has no endpoint of its own, so the host falls through to
    /// OpenRouter with no key and the turn dies with "401 Missing Authentication header". With
    /// `--provider` the host looks the endpoint up by name; the switch stays session-scoped.
    nonisolated static func modelSwitchValue(model: String, provider: String?) -> String {
        guard let provider, !provider.isEmpty, !provider.contains(where: \.isWhitespace) else { return model }
        return "\(model) --provider \(provider)"
    }

    /// Set a live session's reasoning effort (`config.set key=reasoning`). Session-scoped: no
    /// `scope`, so this never touches config.yaml; the live agent picks the level up on its next
    /// turn. Levels are the ones `Settings.reasoningEfforts` offers (the host also takes
    /// `minimal`, `ultra` and `none`); anything else is rejected with 4002.
    func setSessionReasoning(runtimeSession: String, effort: String) async throws {
        _ = try await call("config.set", params: .object([
            "session_id": .string(runtimeSession), "key": .string("reasoning"), "value": .string(effort)]))
        pinnedEfforts[runtimeSession] = effort
    }

    /// Runs a session-scoped call against a stored session's runtime id, resuming once if the
    /// host no longer holds that id (4001: the runtime was reaped or the host restarted since
    /// it was cached). Without the retry, a stale id fails a model or reasoning switch, and on
    /// hosts older than the 4001 guard `config.set` fell through to a global config.yaml write.
    func withLiveSession<T: Sendable>(stored: String, _ body: (String) async throws -> T) async throws -> T {
        let (runtime, _) = try await openSession(stored: stored)
        do {
            return try await body(runtime)
        } catch let error as RPCError where error.code == 4001 {
            pinnedEfforts[runtimeIDs[stored] ?? ""] = nil
            runtimeIDs[stored] = nil
            let (fresh, _) = try await openSession(stored: stored)
            return try await body(fresh)
        }
    }

    /// One entry of the slash-command menu: `text` is what goes into the draft.
    nonisolated struct SlashCompletion: Identifiable, Equatable, Sendable {
        var text: String
        var display: String
        var meta: String
        var kind: String
        var id: String { text }
    }

    /// Completions for a draft that starts with "/": built-in commands, skills and bundles,
    /// ranked by the gateway. `replaceFrom` is where in the draft the chosen text goes.
    func completeSlash(_ text: String) async throws -> (items: [SlashCompletion], replaceFrom: Int) {
        try await ensureConnected()
        let result = try await call("complete.slash", params: .object(["text": .string(text)]), timeout: 10)
        let items = (result["items"]?.array ?? []).compactMap { item -> SlashCompletion? in
            guard let text = item["text"]?.string, !text.isEmpty else { return nil }
            return SlashCompletion(text: text, display: item["display"]?.string ?? text,
                                   meta: item["meta"]?.string ?? "", kind: item["kind"]?.string ?? "command")
        }
        return (items, result["replace_from"]?.int ?? 1)
    }

    /// Models the desktop gateway can route to (`model.options`).
    func modelOptions(refresh: Bool = false) async throws -> [ModelChoice] {
        try await ensureConnected()
        let result = try await call("model.options", params: .object(["explicit_only": .bool(true), "refresh": .bool(refresh)]))
        return HermesSessionsAPI.parseModelOptions(result)
    }

    /// Rename / pin / archive / mark read or unread through the dashboard's PATCH.
    func updateSession(stored: String, title: String? = nil, pinned: Bool? = nil, archived: Bool? = nil, unread: Bool? = nil) async throws {
        struct Body: Encodable { var title: String?; var pinned: Bool?; var archived: Bool?; var unread: Bool?
                                 var request_id: String?; var expected_revision: Int?; var expected_generation: Int? }
        var body = Body(title: title, pinned: pinned, archived: archived, unread: unread,
                        request_id: nil, expected_revision: nil, expected_generation: nil)
        // A Hermes backend from 2026-10-16 on fences every dashboard session write: a PATCH that
        // carries no request id and current revision is refused with 409 client_upgrade_required —
        // the "out of sync (different versions), update the app" notice (issue 52). The Desktop
        // fences the same way: read the session's revision from the snapshot route, send it with a
        // fresh request id (hermes-agent apps/desktop/src/api/sessions.ts). A named 409 —
        // revision_conflict or stale_generation, someone else wrote first — surfaces as the error:
        // the next user action reads a fresh precondition, as on the Desktop; nothing resends blind.
        do {
            let snapshot = try await restJSON("GET", "api/sessions/\(stored)/mutation-snapshot", about: stored)
            guard let revision = snapshot["runtime_revision"]?.int else { throw TransportError.malformed("mutation snapshot without a revision") }
            body.request_id = UUID().uuidString
            body.expected_revision = revision
            body.expected_generation = snapshot["runtime_generation"]?.int
        } catch let error as TransportError {
            // A host predating the fence has no snapshot route; the bare write is the one it takes.
            guard case .http(status: 404, _) = error else { throw error }
        }
        _ = try await rest("PATCH", "api/sessions/\(stored)", body: try JSONEncoder().encode(body), about: stored)
    }

    /// The conversations with a turn under way in this Dashboard, by stored id: working, or
    /// waiting on a person (`session.active_list`, every release; an approval counts as waiting
    /// from 0.21.3). Turns run elsewhere (cron, a messaging app, the Hermes API) aren't listed.
    func liveActivity() async throws -> (sessions: [String: ChatActivity.Kind], rooms: [String: ChatActivity.Kind]) {
        try await ensureConnected()
        let list = try await call("session.active_list", params: .object([:]), timeout: 15)
        return (ChatActivity.kinds(activeList: list), ChatActivity.roomKinds(activeList: list))
    }

    /// Branch a session (`session.branch`). Needs the session open on this connection.
    func deleteSession(stored: String) async throws {
        try await call("session.delete", params: .object(["session_id": .string(stored)]))
    }

    /// Deletes a session this connection may still have live (an incognito chat): closed here
    /// first, as Hermes refuses to delete a live one.
    func closeAndDeleteSession(stored: String) async throws {
        try await ensureConnected()
        if let runtime = runtimeIDs.removeValue(forKey: stored) {
            _ = try? await call("session.close", params: .object(["session_id": .string(runtime)]))
        }
        try await call("session.delete", params: .object(["session_id": .string(stored)]))
    }

    func branchSession(stored: String, title: String?) async throws -> String? {
        let (runtime, _) = try await openSession(stored: stored)
        var params: [String: JSONValue] = ["session_id": .string(runtime)]
        if let title, !title.isEmpty { params["name"] = .string(title) }
        let result = try await call("session.branch", params: .object(params))
        return result["stored_session_id"]?.string ?? result["session_key"]?.string ?? result["session_id"]?.string
    }

    /// `session.steer` → queued (true) or rejected (false). 4010 = this agent can't be steered.
    func steer(stored: String, text: String) async throws -> Bool {
        guard let runtime = runtimeIDs[stored] else { throw TransportError.malformed("session isn't open on this connection") }
        do {
            let result = try await call("session.steer", params: .object(["session_id": .string(runtime), "text": .string(text)]))
            return result["status"]?.string == "queued"
        } catch let error as RPCError where error.code == 4010 {
            return false
        }
    }

    /// Opens a stored session for watching only (no agent attached). The gateway mirrors a
    /// running child's activity onto this runtime id as ordinary stream events.
    func resumeLazy(stored: String) async throws -> (runtime: String, running: Bool, messages: [JSONValue]) {
        try await ensureConnected()
        let result = try await call("session.resume", params: .object([
            "session_id": .string(stored), "lazy": .bool(true), "omit_messages": .bool(false)]))
        guard let runtime = result["session_id"]?.string else { throw TransportError.malformed("no session id") }
        return (runtime, result["running"]?.bool ?? false, result["messages"]?.array ?? [])
    }

    func subagentSteer(id: String, text: String) async throws -> Bool {
        let result = try await call("subagent.steer", params: .object(["subagent_id": .string(id), "text": .string(text)]))
        return result["status"]?.string == "queued"
    }

    func subagentInterrupt(id: String) async throws -> Bool {
        let result = try await call("subagent.interrupt", params: .object(["subagent_id": .string(id)]))
        return result["found"]?.bool ?? false
    }

    func interrupt(runtimeSession: String, admissionID: String? = nil, executionGeneration: Int? = nil) {
        guard let stop = HermesServeWire.stop(sessionID: runtimeSession, canonical: usesSessionAuthority,
                                             admissionID: admissionID, generation: executionGeneration) else {
            log.warning("Stop withheld: no acknowledged admission or observed execution generation; reconcile the session first")
            return
        }
        Task {
            do { _ = try await call(stop.method, params: .object(stop.params)) }
            catch { log.error("Stop request failed: \(error.localizedDescription)") }
        }
    }
}
