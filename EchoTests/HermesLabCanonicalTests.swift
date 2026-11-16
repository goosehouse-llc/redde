import Foundation
import Testing
@testable import Echo

/// A Dashboard the gateway serves itself (Hermes 0.23's Webapp, on the lab's :19120), whose
/// WebSocket goes to Hermes's canonical session owner: `gateway.ready` says `session_authority`,
/// and creating a chat, sending a message, stopping and steering a turn take that owner's shapes
/// (GitHub issue 81: "invalid_params (4001)" on every new chat and every message). The app's own
/// client against it, with the lab's login: a chat made and answered twice, read again, a turn
/// stopped, one steered, and the chat deleted. Skips when that lab isn't up
/// (`LAB_WEBAPP=1 scripts/hermes-lab/lab.sh up v0.23.1 approval`).
@MainActor
@Suite(.serialized)
struct HermesLabCanonicalTests {
    private static let webapp = URL(string: "http://127.0.0.1:19120")!
    private static func report(_ ok: Bool, _ what: String, _ detail: String = "") { HermesLabApprovalTests.report(ok, what, detail) }

    private func conversation(_ client: HermesServeClient) -> Conversation {
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-canonical-\(UUID().uuidString)")!)
        settings.transport = .hermesServe
        settings.serveURL = Self.webapp.absoluteString
        settings.serveUsername = "lab"
        return Conversation(settings: settings,
                            store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "lab-canonical-\(UUID().uuidString)")),
                            transportOverride: HermesServeTransport(client: client), dashboard: client)
    }

    /// Until the conversation is done with its replies (or `seconds` pass): the status lines it
    /// showed meanwhile.
    @discardableResult
    private func settle(_ conversation: Conversation, replies: Int, seconds: Double = 30) async throws -> Set<String> {
        var said: Set<String> = []
        for _ in 0 ..< Int(seconds * 20) {
            try await Task.sleep(for: .milliseconds(50))
            if let line = conversation.statusLine { said.insert(line) }
            let answered = conversation.messages.filter { $0.role == .assistant && !$0.text.isEmpty }.count
            if !conversation.isStreaming, conversation.outbox.isEmpty, answered >= replies { break }
        }
        return said
    }

    private func transcript(_ conversation: Conversation) -> [String] {
        conversation.messages.map { "\($0.role): \($0.text.prefix(60))" + ($0.error.map { " (error: \($0))" } ?? "") }
    }

    @Test func aChatIsMadeAnsweredReadAgainAndDeleted() async throws {
        guard let client = await HermesLabApprovalTests.client(at: Self.webapp) else { return }
        defer { client.disconnect() }
        Self.report(client.sessionAuthority, "Webapp: the gateway's Dashboard says its sessions are the canonical owner's")
        guard client.sessionAuthority else { return }

        let chat = conversation(client)
        _ = chat.send("Hello, lab.")
        try await settle(chat, replies: 1)
        let first = chat.messages.last { $0.role == .assistant }?.text ?? ""
        Self.report(first.contains("[A:alpha]"), "Webapp: a new chat is made and answered", "transcript: \(transcript(chat)), error: \(String(describing: chat.lastError))")
        _ = chat.send("And again.")
        let said = try await settle(chat, replies: 2)
        let answered = chat.messages.filter { $0.role == .assistant && $0.text.contains("[A:alpha]") }.count
        Self.report(answered == 2 && chat.messages.count == 4, "Webapp: the same chat answers a second message", "transcript: \(transcript(chat))")
        Self.report(!said.contains { $0.contains("queued") }, "Webapp: a message to an idle chat isn't said to wait behind a turn", "said: \(said)")

        let stored = try #require(chat.serverSessionID)
        let again = conversation(client)
        try await again.open(serverSession: stored)
        Self.report(again.messages.filter { $0.role == .user }.count == 2 && again.messages.filter { $0.role == .assistant }.count == 2,
                    "Webapp: the chat reads back with both messages and replies", "transcript: \(transcript(again))")

        var deleted = true
        var problem = ""
        do { try await client.deleteSession(stored: stored) } catch { deleted = false; problem = error.localizedDescription }
        let rows = (try? await client.listSessions(limit: 100)) ?? []
        Self.report(deleted && !rows.contains { $0.id == stored }, "Webapp: the chat is deleted, and isn't listed", problem)
    }

    /// The edits that are `session.mutate` there: a model picked, a move to a folder, a branch,
    /// the last message taken back (Regenerate, Edit), and renaming and archiving, which go by
    /// the Dashboard's REST routes on either owner.
    @Test func aChatIsEdited() async throws {
        guard let client = await HermesLabApprovalTests.client(at: Self.webapp), client.sessionAuthority else { return }
        defer { client.disconnect() }
        let chat = conversation(client)
        _ = chat.send("First.")
        try await settle(chat, replies: 1)
        _ = chat.send("Second.")
        try await settle(chat, replies: 2)
        let stored = try #require(chat.serverSessionID)
        func info() async throws -> JSONValue {
            try await client.call("session.resume", params: .object(["session_id": .string(stored), "omit_messages": .bool(true)]))["info"] ?? .null
        }

        var problem = ""
        do {
            let (runtime, _) = try await client.openSession(stored: stored)
            try await client.setSessionModel(runtimeSession: runtime, model: "beta", provider: "custom:my-local")
        } catch { problem = error.localizedDescription }
        let model = try await info()["model"]?.string ?? ""
        Self.report(problem.isEmpty && model == "beta", "Webapp: a model picked for the chat is its model", "model: \(model) \(problem)")

        problem = ""
        let folder = FileManager.default.temporaryDirectory.appending(path: "lab-canonical-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        do { try await client.moveSession(stored: stored, toFolder: folder) } catch { problem = error.localizedDescription }
        let cwd = try await info()["cwd"]?.string ?? ""
        Self.report(problem.isEmpty && URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == URL(fileURLWithPath: folder).resolvingSymlinksInPath().path,
                    "Webapp: the chat moves to a folder", "cwd: \(cwd) \(problem)")

        problem = ""
        var branch: String?
        do { branch = try await client.branchSession(stored: stored, title: "Lab branch") } catch { problem = error.localizedDescription }
        Self.report(branch?.isEmpty == false && branch != stored, "Webapp: the chat is branched", "branch: \(String(describing: branch)) \(problem)")
        if let branch { try? await client.deleteSession(stored: branch) }

        problem = ""
        do { try await client.rewind(stored: stored, turns: 1) } catch { problem = error.localizedDescription }
        let rows = try await client.call("session.resume", params: .object(["session_id": .string(stored), "omit_messages": .bool(false)]))["messages"]?.array ?? []
        // (What rode on the message, a turn note with no Redde plugin to hand it to, is kept with it.)
        let asked = rows.filter { $0["role"]?.string == "user" }.compactMap { $0["content"]?.string }
        Self.report(problem.isEmpty && asked.count == 1 && asked[0].hasPrefix("First."), "Webapp: the last message is taken back", "asked: \(asked) \(problem)")

        problem = ""
        let title = "Lab renamed \(UUID().uuidString.prefix(6))"   // titles are unique on a Hermes
        do {
            try await client.updateSession(stored: stored, title: title)
            try await client.updateSession(stored: stored, archived: true)
        } catch { problem = error.localizedDescription }
        let after = try await info()
        Self.report(problem.isEmpty && after["title"]?.string == title && after["archived"]?.bool == true,
                    "Webapp: the chat is renamed and archived", "title: \(String(describing: after["title"])), archived: \(String(describing: after["archived"])) \(problem)")
        try? await client.deleteSession(stored: stored)
    }

    @Test func aTurnIsStoppedAndOneIsSteered() async throws {
        guard let client = await HermesLabApprovalTests.client(at: Self.webapp), client.sessionAuthority else { return }
        defer { client.disconnect() }

        // The stand-in answers "lab:slow" after eight seconds: stopped after two, the host has no
        // turn running well before then.
        let slow = conversation(client)
        _ = slow.send("lab:slow, please")
        try await Task.sleep(for: .seconds(2))
        let stored = try #require(slow.serverSessionID)
        let before = try await client.currentTurn(stored)
        slow.cancel()
        var stopped = false
        for _ in 0 ..< 16 where !stopped {
            try await Task.sleep(for: .milliseconds(250))
            stopped = (try? await client.currentTurn(stored).running) == false
        }
        Self.report(before.running && stopped, "Webapp: Stop ends the turn on the host", "before: \(before), stopped: \(stopped)")
        try? await client.deleteSession(stored: stored)

        // Stop pressed as the message goes: the run hasn't started yet, and still has to end.
        let early = conversation(client)
        _ = early.send("lab:slow, again")
        for _ in 0 ..< 40 where early.serverSessionID == nil { try await Task.sleep(for: .milliseconds(50)) }
        early.cancel()
        let earlyStored = try #require(early.serverSessionID)
        var earlyStopped = false
        try await Task.sleep(for: .seconds(1))
        for _ in 0 ..< 16 where !earlyStopped {
            try await Task.sleep(for: .milliseconds(250))
            let turn = try? await client.currentTurn(earlyStored)
            earlyStopped = turn.map { !$0.running && !$0.waiting } ?? false
        }
        Self.report(earlyStopped, "Webapp: Stop pressed as the message is sent ends its turn too")
        try? await client.deleteSession(stored: earlyStored)

        // "lab:drip" streams a word a second: a steer sent meanwhile is taken.
        let drip = conversation(client)
        _ = drip.send("lab:drip, please")
        try await Task.sleep(for: .seconds(3))
        let dripStored = try #require(drip.serverSessionID)
        let taken = (try? await client.steer(stored: dripStored, text: "And mention the weather.")) ?? false
        Self.report(taken, "Webapp: a steer sent while the reply streams is taken")
        try await settle(drip, replies: 1)
        try? await client.deleteSession(stored: dripStored)
    }
}
