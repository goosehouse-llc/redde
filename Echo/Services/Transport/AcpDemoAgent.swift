import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Redde's own demo agent (address `demo`): an agent over ACP that runs inside the app, so the
/// Other Agents connection can be seen without a computer, a bridge or a token. Built for App
/// Review (2.6), which has no bridge to reach, and kept for anyone who wants a look first.
///
/// It speaks the same JSON-RPC as Claude Code or Codex behind the bridge, through the same
/// `AcpClient`, so what it shows is what they show: a streamed reply, its reasoning, a task
/// list, steps with a file's diff, an approval for a command, a plan to approve, a question card,
/// a mode menu and slash commands. No model: a script, in English, as an agent's own words are.
/// Its chats are kept in the app's caches, so they reopen like any agent's.
nonisolated final class AcpDemoSocket: AcpSocket {
    private let wire = AcpDemoWire()
    private let agent: AcpDemoAgent
    /// The app's frames, read in the order they were sent.
    private let inbox: AsyncStream<JSONValue>.Continuation

    init(pace: Duration = .milliseconds(35), store: URL? = AcpDemoAgent.defaultStore) {
        let agent = AcpDemoAgent(wire: wire, pace: pace, store: store)
        self.agent = agent
        let (frames, inbox) = AsyncStream.makeStream(of: JSONValue.self)
        self.inbox = inbox
        Task { for await frame in frames { await agent.heard(frame) } }
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        let text: String? = switch message {
        case let .string(text): text
        case let .data(data): String(data: data, encoding: .utf8)
        @unknown default: nil
        }
        completionHandler(nil)
        guard let text, let frame = try? JSONValue.parse(Data(text.utf8)) else { return }
        inbox.yield(frame)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        guard let text = await wire.next() else { throw URLError(.networkConnectionLost) }
        return .string(text)
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) { pongReceiveHandler(nil) }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        inbox.finish()
        Task { await wire.close() }
    }
}

/// The frames on their way to the app, one at a time.
actor AcpDemoWire {
    private var queue: [String] = []
    private var waiter: CheckedContinuation<String?, Never>?
    private var closed = false

    func push(_ frame: JSONValue) {
        guard !closed, let data = try? JSONEncoder().encode(frame) else { return }
        let text = String(decoding: data, as: UTF8.self)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: text)
        } else {
            queue.append(text)
        }
    }

    func next() async -> String? {
        if !queue.isEmpty { return queue.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }

    func close() {
        closed = true
        waiter?.resume(returning: nil)
        waiter = nil
    }
}

actor AcpDemoAgent {
    /// A chat as the demo keeps it: what `session/load` replays.
    struct Chat: Codable {
        var id: String
        var title: String?
        var updatedAt: Date
        var mode: String
        var updates: [JSONValue]
    }

    private let wire: AcpDemoWire
    private var chats: [String: Chat]
    private var waiting: [String: CheckedContinuation<JSONValue, Never>] = [:]
    private var cancelled: Set<String> = []
    private var nextRequest = 1
    /// How long between streamed words: quick, but slow enough to see it stream (and for tests, none).
    var pace: Duration

    static let folder = "/demo"
    static let mainFile = "notes.md"

    init(wire: AcpDemoWire, pace: Duration = .milliseconds(35), store: URL? = AcpDemoAgent.defaultStore) {
        self.wire = wire
        self.pace = pace
        self.store = store
        chats = store.flatMap { try? JSONDecoder().decode([String: Chat].self, from: Data(contentsOf: $0)) } ?? [:]
    }

    private let store: URL?
    static let defaultStore: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appending(path: "redde-demo-agent.json")

    private func save() {
        guard let store, let data = try? JSONEncoder().encode(chats) else { return }
        try? data.write(to: store, options: .atomic)
    }

    // MARK: Frames

    /// A frame from the app. Answers and cancels are taken at once; a method is answered on its
    /// own, so a turn waiting on the person doesn't hold up the answer it waits for.
    func heard(_ frame: JSONValue) {
        let method = frame["method"]?.string
        let id = frame["id"]
        if method == nil, let key = id?.string ?? id?.int.map(String.init) {
            waiting.removeValue(forKey: key)?.resume(returning: frame["result"] ?? .null)
            return
        }
        guard let method else { return }
        let params = frame["params"] ?? .null
        guard let id, !id.isNull else {
            if method == "session/cancel", let session = params["sessionId"]?.string { cancel(session) }
            return
        }
        Task { await self.reply(id, method, params) }
    }

    private func reply(_ id: JSONValue, _ method: String, _ params: JSONValue) async {
        do {
            let result = try await answer(method, params)
            await wire.push(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
            // The commands of a new chat, once the app knows the chat.
            if method == "session/new", let session = result["sessionId"]?.string { await tell(session, Self.commands, keep: false) }
        } catch let error as AcpError {
            await wire.push(.object(["jsonrpc": .string("2.0"), "id": id,
                                     "error": .object(["code": .number(Double(error.code)), "message": .string(error.message)])]))
        } catch {}
    }

    private func answer(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize":
            #if DEBUG
            let title = persona.flatMap { Self.personas[$0] } ?? "Demo Agent"
            #else
            let title = "Demo Agent"
            #endif
            return .object([
                "protocolVersion": .number(1),
                "agentInfo": .object(["name": .string("redde-demo"), "title": .string(title), "version": .string(Bundle.main.shortVersion)]),
                "agentCapabilities": .object([
                    "loadSession": .bool(true),
                    "promptCapabilities": .object(["image": .bool(false), "embeddedContext": .bool(false)]),
                    "sessionCapabilities": .object(["list": .object([:]), "delete": .object([:]), "title": .object([:])]),
                ]),
            ])
        case "session/new":
            let id = "demo-" + UUID().uuidString.lowercased()
            chats[id] = Chat(id: id, updatedAt: .now, mode: "ask", updates: [])
            save()
            return .object(["sessionId": .string(id), "configOptions": .array(options(mode: "ask"))])
        case "session/load":
            guard let id = params["sessionId"]?.string, let chat = chats[id] else {
                throw AcpError(code: -32002, message: "The demo agent doesn't have that chat any more.")
            }
            for update in chat.updates { await tell(id, update, keep: false) }
            await tell(id, Self.commands, keep: false)
            return .object(["configOptions": .array(options(mode: chat.mode))])
        case "session/list":
            let rows = chats.values.sorted { $0.updatedAt > $1.updatedAt }.map { chat -> JSONValue in
                .object(["sessionId": .string(chat.id), "cwd": .string(Self.folder), "title": chat.title.map(JSONValue.string) ?? .null,
                         "updatedAt": .string(chat.updatedAt.ISO8601Format())])
            }
            return .object(["sessions": .array(rows)])
        case "session/delete":
            if let id = params["sessionId"]?.string { chats[id] = nil; save() }
            return .object([:])
        case "session/set_title":
            if let id = params["sessionId"]?.string, let title = params["title"]?.string { chats[id]?.title = title; save() }
            return .object([:])
        case "session/set_config_option":
            guard let id = params["sessionId"]?.string, params["configId"]?.string == "mode",
                  let value = params["value"]?.string, ["ask", "auto"].contains(value) else {
                throw AcpError(code: -32602, message: "The demo agent has only its mode to set.")
            }
            chats[id]?.mode = value
            save()
            return .object(["configOptions": .array(options(mode: value))])
        case "session/prompt":
            guard let id = params["sessionId"]?.string, chats[id] != nil else {
                throw AcpError(code: -32002, message: "The demo agent doesn't have that chat any more.")
            }
            let said = (params["prompt"]?.array ?? []).compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
            cancelled.remove(id)
            let reason = await turn(id, said: said)
            chats[id]?.updatedAt = .now
            save()
            return .object(["stopReason": .string(reason)])
        default:
            throw AcpError(code: -32601, message: "The demo agent doesn't do \(method).")
        }
    }

    // MARK: A turn

    enum Script: Equatable { case tour, plan, question, screenshot, help }

    /// What a message asks the demo for: a slash command, or its words.
    static func script(for said: String, first: Bool) -> Script {
        let words = said.lowercased()
        if words.hasPrefix("/plan") || words.contains("plan") { return .plan }
        if words.hasPrefix("/question") || words.contains("question") || words.contains("ask me") { return .question }
        if words.hasPrefix("/screenshot") || ["screenshot", "picture", "how does it look"].contains(where: words.contains) { return .screenshot }
        if first || words.hasPrefix("/tour") || ["fix", "tour", "demo", "edit", "note", "show me"].contains(where: words.contains) { return .tour }
        return .help
    }

    private func turn(_ id: String, said: String) async -> String {
        let first = chats[id]?.updates.isEmpty ?? true
        await tell(id, .object(["sessionUpdate": .string("user_message_chunk"), "content": text(said)]), live: false)
        if chats[id]?.title == nil {
            let title = String(said.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
            chats[id]?.title = title.isEmpty ? "Demo" : title
            await tell(id, .object(["sessionUpdate": .string("session_info_update"), "title": .string(chats[id]?.title ?? "")]))
        }
        #if DEBUG
        if let persona { return await standIn(persona, id) }
        #endif
        switch Self.script(for: said, first: first) {
        case .tour: return await tour(id)
        case .plan: return await plan(id)
        case .question: return await question(id)
        case .screenshot: return await screenshot(id)
        case .help:
            await say(id, "I'm Redde's demo agent, so I can only show what Redde does with a coding agent. Try “Fix the notes”, “Show me a plan”, “Take a screenshot” or “Ask me a question”, or type / for my commands.")
            return "end_turn"
        }
    }

    /// The whole run of a coding agent's turn: thinking, a task list, a file read and changed, a
    /// command that asks first, and the answer.
    private func tour(_ id: String) async -> String {
        await think(id, "The notes have a typo. I'll fix it, then run the checks.")
        await todos(id, ["completed", "pending", "pending"])
        await step(id, "read-1", kind: "read", title: "Read \(Self.mainFile)", input: ["path": .string(Self.mainFile)],
                   content: [.object(["type": .string("content"), "content": text(Self.before)])])
        guard await carryOn(id) else { return "cancelled" }
        await step(id, "edit-1", kind: "edit", title: "Edit \(Self.mainFile)",
                   input: ["file_path": .string(Self.mainFile), "old_string": .string("alowd"), "new_string": .string("aloud")],
                   content: [.object(["type": .string("diff"), "path": .string(Self.mainFile), "oldText": .string(Self.before), "newText": .string(Self.after)])])
        await todos(id, ["completed", "completed", "in_progress"])
        guard await carryOn(id) else { return "cancelled" }
        let call: [String: JSONValue] = ["toolCallId": .string("run-1"), "kind": .string("execute"), "title": .string("make check"),
                                         "rawInput": .object(["command": .string("make check"), "description": .string("Run the project's checks")])]
        let asked = chats[id]?.mode != "auto"
        var allowed = !asked
        if asked {
            await tell(id, .object(["sessionUpdate": .string("tool_call"), "status": .string("pending")].merging(call) { $1 }))
            let answer = await ask(id, "session/request_permission", [
                "sessionId": .string(id), "toolCall": .object(call),
                "options": .array([
                    .object(["optionId": .string("allow"), "name": .string("Allow"), "kind": .string("allow_once")]),
                    .object(["optionId": .string("always"), "name": .string("Always allow make check"), "kind": .string("allow_always")]),
                    .object(["optionId": .string("deny"), "name": .string("Deny"), "kind": .string("reject_once")]),
                ]),
            ])
            guard !cancelled.contains(id) else { return "cancelled" }
            let picked = answer["outcome"]?["optionId"]?.string
            allowed = picked == "allow" || picked == "always"
            if picked == "always" { chats[id]?.mode = "auto"; await tell(id, .object(["sessionUpdate": .string("config_option_update"), "configOptions": .array(options(mode: "auto"))])) }
        }
        if allowed {
            await step(id, "run-1", kind: "execute", title: "make check", input: ["command": .string("make check"), "description": .string("Run the project's checks")],
                       content: [.object(["type": .string("content"), "content": text("✓ spelling\n✓ links\n✓ format\n3 checks passed")])],
                       update: asked)
            await todos(id, ["completed", "completed", "completed"])
            await say(id, "Done: I fixed the typo in \(Self.mainFile), and all three checks pass.\n\nI'm Redde's demo agent: nothing ran on a computer and no AI wrote this. It shows how Claude Code, Codex and other agents work in Redde, by chat or by voice. Try “Show me a plan” or “Ask me a question”, or connect your own agent through the Redde bridge.")
        } else {
            await tell(id, .object(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("run-1"), "status": .string("failed")]))
            await todos(id, ["completed", "completed", "pending"])
            await say(id, "Okay, I didn't run the checks. The typo in \(Self.mainFile) is fixed.")
        }
        return "end_turn"
    }

    /// A plan to approve before anything is changed, as Claude Code's plan mode asks.
    private func plan(_ id: String) async -> String {
        await think(id, "Planning first: nothing changes until the plan is approved.")
        let plan = "## Tidy the notes\n\n1. Fix the typo in \(Self.mainFile)\n2. Add a line about voice mode\n3. Run the checks"
        let answer = await ask(id, "session/request_permission", [
            "sessionId": .string(id),
            "toolCall": .object(["toolCallId": .string("plan-1"), "kind": .string("switch_mode"), "title": .string("Approve Plan"),
                                 "rawInput": .object(["plan": .string(plan)])]),
            "options": .array([
                .object(["optionId": .string("go"), "name": .string("Yes, go ahead"), "kind": .string("allow_once")]),
                .object(["optionId": .string("no"), "name": .string("No, keep planning"), "kind": .string("reject_once")]),
            ]),
        ])
        guard !cancelled.contains(id) else { return "cancelled" }
        if answer["outcome"]?["optionId"]?.string == "go" {
            await todos(id, ["completed", "completed", "completed"], entries: ["Fix the typo in \(Self.mainFile)", "Add a line about voice mode", "Run the checks"])
            await say(id, "Plan done: the typo is fixed, there's a line about voice mode, and the checks pass.")
        } else {
            await say(id, "Okay, nothing changed. Tell me what to plan differently.")
        }
        return "end_turn"
    }

    /// A screenshot the agent takes and looks at, as Claude Code reads one: the picture comes back
    /// in the step's content, and Redde shows it with the reply.
    private func screenshot(_ id: String) async -> String {
        await think(id, "I'll take a screenshot of the app and look at it.")
        await step(id, "shot-1", kind: "execute", title: "xcrun simctl io booted screenshot screen.png",
                   input: ["command": .string("xcrun simctl io booted screenshot screen.png")],
                   content: [.object(["type": .string("content"), "content": text("Wrote screen.png")])])
        guard await carryOn(id) else { return "cancelled" }
        let picture: [JSONValue] = Self.screenPNG.map {
            [.object(["type": .string("content"), "content": .object(["type": .string("image"), "mimeType": .string("image/png"),
                                                                       "data": .string($0.base64EncodedString())])])]
        } ?? []
        await step(id, "read-shot", kind: "read", title: "Read screen.png", input: ["file_path": .string("screen.png")], content: picture)
        await say(id, "Here's the screen: a title bar and three chats. Pictures an agent takes or reads come with its reply, like this one.")
        return "end_turn"
    }

    /// The demo's screenshot, drawn: a phone screen with a title bar and three rows.
    static let screenPNG: Data? = {
        let width = 390, height = 640
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.35, green: 0.32, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 110, width: width, height: 110))
        for row in 0..<3 {
            let y = CGFloat(height - 200 - row * 110)
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.addPath(CGPath(roundedRect: CGRect(x: 20, y: y, width: CGFloat(width - 40), height: 90), cornerWidth: 18, cornerHeight: 18, transform: nil))
            context.fillPath()
            context.setFillColor(CGColor(srgbRed: 0.35 + Double(row) * 0.2, green: 0.6, blue: 0.9 - Double(row) * 0.2, alpha: 1))
            context.fillEllipse(in: CGRect(x: 36, y: y + 21, width: 48, height: 48))
            context.setFillColor(CGColor(srgbRed: 0.8, green: 0.8, blue: 0.84, alpha: 1))
            context.fill(CGRect(x: 100, y: y + 52, width: 200, height: 12))
            context.fill(CGRect(x: 100, y: y + 28, width: 140, height: 10))
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, image, nil)
        return CGImageDestinationFinalize(out) ? data as Data : nil
    }()

    /// A question with choices, as Claude Code's AskUserQuestion asks it (a form).
    private func question(_ id: String) async -> String {
        let choices = ["A plan to approve", "A file change", "Just a hello"]
        let answer = await ask(id, "elicitation/create", [
            "sessionId": .string(id), "mode": .string("form"), "message": .string("Which should I show you next?"),
            "requestedSchema": .object(["type": .string("object"), "properties": .object([
                "pick": .object(["type": .string("string"), "title": .string("Which should I show you next?"),
                                 "enum": .array(choices.map(JSONValue.string))]),
            ])]),
        ])
        guard !cancelled.contains(id) else { return "cancelled" }
        let picked = answer["action"]?.string == "accept" ? answer["content"]?["pick"]?.string : nil
        guard let picked else {
            await say(id, "No answer, no problem.")
            return "end_turn"
        }
        if picked == choices[0] { return await plan(id) }
        if picked == choices[1] { return await tour(id) }
        await say(id, "You picked “\(picked)”. Hello from Redde's demo agent!")
        return "end_turn"
    }

    #if DEBUG
    // MARK: The agents video's stand-ins

    /// `-echo.demoCoders` (the agents video, design/video/make_agents.py): scripted stand-ins for
    /// Claude Code and Codex, by the agent named in the demo address's place (`redde-demo://claude`).
    /// Each keeps its chats in a file of its own. Nothing here is either agent's: the words are
    /// the video's.
    static let personas = ["claude": "Claude Code", "codex": "Codex"]

    static func store(persona: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appending(path: "redde-demo-agent-\(persona).json")
    }

    /// Which stand-in this is, by its store's name; nil for the demo agent itself.
    private var persona: String? {
        guard let name = store?.deletingPathExtension().lastPathComponent, name.hasPrefix("redde-demo-agent-") else { return nil }
        let persona = String(name.dropFirst("redde-demo-agent-".count))
        return Self.personas[persona] == nil ? nil : persona
    }

    static let loginBefore = """
        func signIn() async throws -> User {
            guard session.expiresAt > .now else {
                throw LoginError.expired
            }
            return try await api.user(session)
        }
        """
    static let loginAfter = """
        func signIn() async throws -> User {
            if session.expiresAt <= .now {
                session = try await api.refresh(session)
            }
            return try await api.user(session)
        }
        """

    private func standIn(_ persona: String, _ id: String) async -> String {
        let file = "Login.swift"
        let diff: JSONValue = .object(["type": .string("diff"), "path": .string(file), "oldText": .string(Self.loginBefore), "newText": .string(Self.loginAfter)])
        let entries = persona == "claude" ? ["Find the bug", "Fix it", "Run the tests"] : ["Read the change", "Review it", "Test a failed refresh"]
        if persona == "claude" {
            await think(id, "Sign-in fails once the session has run out. I'll find where the session is checked.")
            await todos(id, ["in_progress", "pending", "pending"], entries: entries)
            await step(id, "read-1", kind: "read", title: "Read \(file)", input: ["path": .string(file)],
                       content: [.object(["type": .string("content"), "content": text(Self.loginBefore)])])
            await todos(id, ["completed", "in_progress", "pending"], entries: entries)
            await step(id, "edit-1", kind: "edit", title: "Edit \(file)",
                       input: ["file_path": .string(file), "old_string": .string("throw LoginError.expired"), "new_string": .string("session = try await api.refresh(session)")],
                       content: [diff])
            await todos(id, ["completed", "completed", "in_progress"], entries: entries)
        } else {
            await think(id, "Reading Claude Code's change to \(file).")
            await todos(id, ["in_progress", "pending", "pending"], entries: entries)
            await step(id, "read-1", kind: "read", title: "Read the change to \(file)", input: ["path": .string(file)], content: [diff])
            await todos(id, ["completed", "completed", "pending"], entries: entries)
            await say(id, "Looks good ✅ The session is refreshed before sign-in, so nobody gets signed out.\n\nOne gap: no test covers a refresh that fails. I'll add one and run the login tests.")
        }
        let command = persona == "claude" ? "swift test" : "swift test --filter LoginTests"
        let reason = persona == "claude" ? "Run the tests" : "Add a test and run the login tests"
        let call: [String: JSONValue] = ["toolCallId": .string("run-1"), "kind": .string("execute"), "title": .string(command),
                                         "rawInput": .object(["command": .string(command), "description": .string(reason)])]
        await tell(id, .object(["sessionUpdate": .string("tool_call"), "status": .string("pending")].merging(call) { $1 }))
        let answer = await ask(id, "session/request_permission", [
            "sessionId": .string(id), "toolCall": .object(call),
            "options": .array([
                .object(["optionId": .string("allow"), "name": .string("Allow"), "kind": .string("allow_once")]),
                .object(["optionId": .string("deny"), "name": .string("Deny"), "kind": .string("reject_once")]),
            ]),
        ])
        guard !cancelled.contains(id) else { return "cancelled" }
        guard answer["outcome"]?["optionId"]?.string == "allow" else {
            await tell(id, .object(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("run-1"), "status": .string("failed")]))
            await say(id, "Okay, I didn't run them.")
            return "end_turn"
        }
        let passed = persona == "claude" ? "Test Suite 'All tests' passed\nExecuted 42 tests, with 0 failures" : "Test Suite 'LoginTests' passed\nExecuted 7 tests, with 0 failures"
        await step(id, "run-1", kind: "execute", title: command, input: ["command": .string(command), "description": .string(reason)],
                   content: [.object(["type": .string("content"), "content": text(passed)])], update: true)
        await todos(id, ["completed", "completed", "completed"], entries: entries)
        await say(id, persona == "claude"
            ? "Fixed ✅ When the session has run out, sign-in now refreshes it instead of failing. All 42 tests pass."
            : "Added the test, and all 7 login tests pass.")
        return "end_turn"
    }
    #endif

    // MARK: Parts of a turn

    static let before = "# Notes\n\nRedde talks to your agent by voice or chat.\nIn the car, replies are read alowd.\n"
    static let after = "# Notes\n\nRedde talks to your agent by voice or chat.\nIn the car, replies are read aloud.\n"

    private static var commands: JSONValue {
        .object(["sessionUpdate": .string("available_commands_update"), "availableCommands": .array([
            .object(["name": .string("tour"), "description": .string("Fix the notes, step by step")]),
            .object(["name": .string("plan"), "description": .string("Show a plan to approve")]),
            .object(["name": .string("question"), "description": .string("Ask you a question")]),
            .object(["name": .string("screenshot"), "description": .string("Take a screenshot and show it")]),
        ])])
    }

    private func options(mode: String) -> [JSONValue] {
        [.object(["id": .string("mode"), "name": .string("Mode"), "category": .string("mode"), "type": .string("select"),
                  "currentValue": .string(mode), "options": .array([
                      .object(["value": .string("ask"), "name": .string("Ask first"), "description": .string("Asks before it runs a command")]),
                      .object(["value": .string("auto"), "name": .string("Auto"), "description": .string("Runs commands without asking")]),
                  ])])]
    }

    private func text(_ words: String) -> JSONValue { .object(["type": .string("text"), "text": .string(words)]) }

    private func think(_ id: String, _ words: String) async {
        await tell(id, .object(["sessionUpdate": .string("agent_thought_chunk"), "content": text(words)]))
        try? await Task.sleep(for: pace * 12)
    }

    private func todos(_ id: String, _ statuses: [String], entries: [String] = ["Read the notes", "Fix the typo", "Run the checks"]) async {
        let rows = zip(entries, statuses).map { JSONValue.object(["content": .string($0), "status": .string($1), "priority": .string("medium")]) }
        await tell(id, .object(["sessionUpdate": .string("plan"), "entries": .array(rows)]))
    }

    /// A step: announced, then done with what it gave.
    private func step(_ id: String, _ call: String, kind: String, title: String, input: [String: JSONValue], content: [JSONValue], update: Bool = false) async {
        let head: [String: JSONValue] = ["toolCallId": .string(call), "kind": .string(kind), "title": .string(title), "rawInput": .object(input)]
        if !update {
            await tell(id, .object(["sessionUpdate": .string("tool_call"), "status": .string("in_progress")].merging(head) { $1 }))
        }
        try? await Task.sleep(for: pace * 15)
        await tell(id, .object(["sessionUpdate": .string("tool_call_update"), "status": .string("completed"), "content": .array(content)].merging(head) { $1 }))
    }

    /// The answer, a few words at a time.
    private func say(_ id: String, _ words: String) async {
        var chunk = ""
        for (i, word) in words.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            chunk += (i == 0 ? "" : " ") + word
            if chunk.count > 12 {
                await tell(id, .object(["sessionUpdate": .string("agent_message_chunk"), "content": text(chunk)]))
                chunk = ""
                try? await Task.sleep(for: pace)
                if cancelled.contains(id) { return }
            }
        }
        if !chunk.isEmpty { await tell(id, .object(["sessionUpdate": .string("agent_message_chunk"), "content": text(chunk)])) }
    }

    private func carryOn(_ id: String) async -> Bool {
        try? await Task.sleep(for: pace * 6)
        return !cancelled.contains(id)
    }

    private func cancel(_ session: String) {
        cancelled.insert(session)
        // A question waiting on the person ends with the turn.
        for key in waiting.keys { waiting.removeValue(forKey: key)?.resume(returning: .object(["outcome": .object(["outcome": .string("cancelled")])])) }
    }

    /// A request to the app, answered when the person answers.
    private func ask(_ id: String, _ method: String, _ params: [String: JSONValue]) async -> JSONValue {
        let key = "demo-request-\(nextRequest)"
        nextRequest += 1
        return await withCheckedContinuation { cont in
            waiting[key] = cont
            Task { await wire.push(.object(["jsonrpc": .string("2.0"), "id": .string(key), "method": .string(method), "params": .object(params)])) }
        }
    }

    /// A `session/update`, kept for the chat's replay unless it's only for now.
    private func tell(_ id: String, _ update: JSONValue, keep: Bool = true, live: Bool = true) async {
        if keep { chats[id]?.updates.append(update) }
        if live { await wire.push(.object(["jsonrpc": .string("2.0"), "method": .string("session/update"),
                                           "params": .object(["sessionId": .string(id), "update": update])])) }
    }
}
