import Foundation

/// Edits of a session on Hermes's canonical session owner (`sessionAuthority`, GitHub issue 81),
/// where every one is `session.mutate` (`CanonicalRequests.mutation`).
extension HermesServeClient {
    /// One edit, fenced by where the session stands now: read from a resume, and read again if
    /// the session moved on in between (`revision_conflict`, a turn ending meanwhile).
    @discardableResult
    func mutate(stored: String, _ operation: String, _ payload: [String: JSONValue] = [:], profile: String? = nil) async throws -> JSONValue {
        try await ensureConnected()
        let requestID = UUID().uuidString
        // A bot's chat is its profile's session: named with it, as noted when it was found.
        let profile = profile ?? sessionProfiles[stored]
        var resume: [String: JSONValue] = ["session_id": .string(stored), "omit_messages": .bool(true)]
        if let profile, !profile.isEmpty { resume["profile"] = .string(profile) }
        for attempt in 1 ... 3 {
            let snapshot = try await call("session.resume", params: .object(resume))
            if let runtime = snapshot["session_id"]?.string { runtimeIDs[stored] = runtime }
            do {
                return try await call("session.mutate", params: .object(CanonicalRequests.mutation(
                    stored: stored, operation: operation, payload: payload, snapshot: snapshot, requestID: requestID, profile: profile)))
            } catch let error as RPCError where ["revision_conflict", "stale_generation"].contains(error.message) && attempt < 3 {
                continue
            }
        }
        throw TransportError.malformed("session.mutate \(operation): the session kept changing")
    }

    /// Answers a prompt the canonical owner put to the turn (an approval, a question): named by
    /// its id and by the run it was asked in, which is the current one while the turn waits on it.
    func answerPrompt(_ method: String, runtimeSession: String, promptID: String, _ answer: [String: JSONValue]) async throws {
        let stored = runtimeIDs.first { $0.value == runtimeSession }?.key ?? runtimeSession
        let generation = try await currentTurn(stored).generation
        let prompt: JSONValue = .object(["prompt_id": .string(promptID), "execution_generation": .number(Double(generation))])
        try await call(method, params: .object(onItsProfile(CanonicalRequests.promptAnswer(runtime: runtimeSession, prompt: prompt, answer), stored: stored)))
    }

    /// A request about a bot's chat names the bot's profile there, whose owner keeps the session.
    func onItsProfile(_ params: [String: JSONValue], stored: String) -> [String: JSONValue] {
        guard let profile = sessionProfiles[stored], !profile.isEmpty else { return params }
        var params = params
        params["profile"] = .string(profile)
        return params
    }

    /// Takes back the last `turns` messages and what came after them (Hermes serve's
    /// `session.undo`, once per message): a rewind to the earliest of them.
    func rewind(stored: String, turns: Int) async throws {
        let snapshot = try await call("session.resume", params: .object(["session_id": .string(stored), "omit_messages": .bool(false)]), timeout: 180)
        guard let target = CanonicalRequests.rewindTarget(snapshot["messages"]?.array ?? [], turns: turns) else { return }
        try await mutate(stored: stored, "rewind", ["target_message_id": .number(Double(target))])
    }
}
