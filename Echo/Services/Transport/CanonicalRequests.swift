import Foundation

/// The Dashboard requests whose shape differs where Hermes's canonical session owner keeps the
/// sessions (`HermesServeClient.sessionAuthority`: 0.23 and later, a Dashboard the gateway serves
/// itself, as its Webapp does), from what `hermes serve` takes (GitHub issue 81). That owner's
/// params refuse any key they don't know (4001 `invalid_params`), so each request is built for
/// one or the other. Read from 0.23.1's `tui_gateway/contracts/canonical_sessions.py` and tried on
/// the lab's (`LAB_WEBAPP=1 scripts/hermes-lab/lab.sh up v0.23.1 approval`).
nonisolated enum CanonicalRequests {
    /// `session.create`. Redde's source is "desktop" on `hermes serve`, for the desktop hint in the
    /// agent's system prompt (full markdown, files as MEDIA: tags); the canonical owner calls that
    /// surface "gui" and gives it the same hint. It has no `close_on_disconnect` (its sessions
    /// outlast every connection), and the reasoning level is `reasoning`.
    static func create(model: String?, provider: String?, reasoningEffort: String?, folder: String?,
                       hidden: Bool, profile: String?, canonical: Bool) -> [String: JSONValue] {
        var params: [String: JSONValue] = canonical ? ["source": .string("gui")]
            : ["source": .string("desktop"), "close_on_disconnect": .bool(false)]
        if let model, !model.isEmpty { params["model"] = .string(model) }
        if let provider, !provider.isEmpty { params["provider"] = .string(provider) }
        if let reasoningEffort, !reasoningEffort.isEmpty { params[canonical ? "reasoning" : "reasoning_effort"] = .string(reasoningEffort) }
        if let folder, !folder.isEmpty { params["cwd"] = .string(folder) }
        if hidden { params["hidden"] = .bool(true) }
        if let profile { params["profile"] = .string(profile) }
        return params
    }

    /// `prompt.submit` names the message once and for all on the canonical owner (`submission_id`,
    /// required there): the same message sent again is the one admission, not a second turn. The
    /// message's own id when it has one (`TurnRequest.turnKey`), else a new one.
    static func submit(_ params: [String: JSONValue], key: String?, canonical: Bool) -> [String: JSONValue] {
        guard canonical else { return params }
        var params = params
        params["submission_id"] = .string(key?.isEmpty == false ? key! : UUID().uuidString)
        return params
    }

    /// Whether `prompt.submit`'s answer means the message waits behind a running turn. The
    /// canonical owner admits every message as "queued", running or not: there it says nothing.
    static func waitsBehindATurn(_ receipt: JSONValue, canonical: Bool) -> Bool {
        !canonical && receipt["status"]?.string == "queued"
    }

    /// `session.resume` for watching a session only: `hermes serve` attaches no agent when asked
    /// `lazy`; the canonical owner has no such key (it never attaches one for a viewer).
    static func resumeToWatch(stored: String, canonical: Bool) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["session_id": .string(stored), "omit_messages": .bool(false)]
        if !canonical { params["lazy"] = .bool(true) }
        return params
    }

    /// Where a session's turns stand, from a resume's snapshot: which run of the agent is the
    /// current one (`execution_generation`, which stopping or steering it has to name: one that
    /// names an older run is refused as stale, and naming the one before a turn starts stops
    /// nothing), whether a turn runs, and whether a message waits to start one.
    struct Turn: Equatable {
        var generation: Int
        var running: Bool
        var waiting: Bool
    }

    /// `session.mutate`, which on the canonical session owner is every edit of a session that
    /// `hermes serve` has a method of its own for (`session.title`, `.archive`, `.branch`,
    /// `.delete`, `.undo`, `.workspace.move`, a model picked with `config.set`), all of them
    /// refused there as unknown methods. Fenced by the session's revision, and for the edits that
    /// change what the agent works from by its current run too, both from a resume's snapshot;
    /// `requestID` makes a retry of the same edit the one edit.
    static func mutation(stored: String, operation: String, payload: [String: JSONValue], snapshot: JSONValue,
                         requestID: String, profile: String?) -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            "session_id": .string(stored), "request_id": .string(requestID), "operation": .string(operation),
            "expected_revision": .number(Double(snapshot["revision"]?.int ?? 0)), "payload": .object(payload)]
        if fencedByRun.contains(operation) { params["expected_generation"] = .number(Double(snapshot["execution_generation"]?.int ?? 0)) }
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        return params
    }

    /// The edits Hermes refuses without the current run (`SessionMutateParams`, 0.23.1).
    static let fencedByRun: Set<String> = ["delete", "rewind", "reset", "branch", "model", "compress", "reasoning", "workspace"]

    /// The row a rewind of the last `turns` messages goes back to: the earliest of those messages,
    /// by the row id the host gives it (`row_id`). Nil when the host's transcript has fewer.
    static func rewindTarget(_ messages: [JSONValue], turns: Int) -> Int? {
        let asked = messages.filter { $0["role"]?.string == "user" }
        guard turns > 0, asked.count >= turns else { return nil }
        return asked[asked.count - turns]["row_id"]?.int
    }

    /// `approval.respond` / `clarify.respond` there: the prompt by its id and the run it was asked
    /// in (`prompt_id`, `execution_generation`, as the prompt or a resume's `prompts` give them),
    /// with the answer (`choice`, `answer`).
    static func promptAnswer(runtime: String, prompt: JSONValue, _ answer: [String: JSONValue]) -> [String: JSONValue] {
        var params = answer
        params["session_id"] = .string(runtime)
        params["prompt_id"] = .string(prompt["prompt_id"]?.string ?? "")
        params["execution_generation"] = .number(Double(prompt["execution_generation"]?.int ?? 0))
        return params
    }

    /// The message a running turn answers, from a resume's snapshot there: the admission that
    /// has started (`hermes serve` says it as `inflight.user`).
    static func answering(_ snapshot: JSONValue) -> String? {
        snapshot["pending"]?.array?.first { $0["status"]?.string == "started" }?["text"]?.string
    }

    static func turn(_ snapshot: JSONValue) -> Turn {
        let pending = snapshot["pending"]?.array ?? []
        return Turn(generation: snapshot["execution_generation"]?.int ?? 0,
                    running: snapshot["running"]?.bool ?? false,
                    waiting: pending.contains { ["queued", "started"].contains($0["status"]?.string ?? "") })
    }
}
