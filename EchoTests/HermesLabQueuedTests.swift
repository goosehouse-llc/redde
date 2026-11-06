import Foundation
import Testing
@testable import Echo

/// A message sent with "Send after this reply" while a Dashboard reply streams, against the lab's
/// `approval` scenario (`scripts/hermes-lab/lab.sh up <tag> approval`), whose stub streams
/// "lab:drip" a word a second. 2026-11-05 on Marta two replies showed as one bubble, the first cut
/// mid-word: "…Want to tackle the ElevenLabs onLet me find all the receipts…". Each reply must be
/// whole, in its own bubble, after its own question. Skips when that lab isn't up.
@MainActor
struct HermesLabQueuedTests {
    private static let drip = "lab:drip, please"
    private static let dripped = "word0 word1 word2 word3 word4 word5 word6 word7 [drip done]"
    private static let second = "And a second question"

    @Test func aMessageQueuedDuringAReplyGetsItsOwnReply() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-queued-\(UUID().uuidString)")!)
        settings.transport = .hermesServe
        let conversation = Conversation(settings: settings,
                                        store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "lab-queued-\(UUID().uuidString)")),
                                        transportOverride: HermesServeTransport(client: client), dashboard: client)
        let start = Date()
        var heard: [String] = []
        let listener = client.addListener { event in
            let text = event.payload["text"]?.string.map { " \"\($0.prefix(40))\"" } ?? ""
            let running = event.payload["running"]?.bool.map { " running=\($0)" } ?? ""
            heard.append(String(format: "%6.2f ", Date().timeIntervalSince(start)) + "\(event.type) \(event.sessionID ?? "-")\(text)\(running)")
        }
        defer { client.removeListener(listener) }

        _ = conversation.send(Self.drip)
        try await Task.sleep(for: .seconds(4))
        _ = conversation.send(Self.second)   // "Send after this reply": into the outbox
        let queued = conversation.outbox.count
        for _ in 0 ..< 120 {
            try await Task.sleep(for: .milliseconds(250))
            let replies = conversation.messages.filter { $0.role == .assistant }
            if !conversation.isStreaming, conversation.outbox.isEmpty, replies.count >= 2, !(replies.last?.text.isEmpty ?? true) { break }
        }
        try await Task.sleep(for: .seconds(3))   // anything late

        print("  ----  events:")
        heard.forEach { print("  ----    \($0)") }
        print("  ----  transcript:")
        for m in conversation.messages { print("  ----    \(m.role) \(m.isSteer ? "(steer) " : "")\(m.text.debugDescription)") }

        let shown = conversation.messages.map { ($0.role, $0.text) }
        let ok = queued == 1 && shown.count == 4
            && shown[0] == (.user, Self.drip) && shown[1].0 == .assistant && shown[1].1 == Self.dripped
            && shown[2] == (.user, Self.second) && shown[3].0 == .assistant && !shown[3].1.isEmpty && !shown[3].1.contains("word")
        HermesLabApprovalTests.report(ok, "Dashboard: a message sent after a streaming reply gets its own reply, and the first stays whole",
                                      "queued: \(queued), transcript: \(shown)")
    }

    /// GitHub issue 60: Send Now on the queued message while the reply streams adds it to that
    /// reply as a steer (it had done nothing): out of the outbox, a steer note in the chat, and no
    /// turn of its own after. (A steer landing as the reply ends gets a step of its own from
    /// Hermes, a second reply bubble; that is the steer answered, not a new turn.)
    @Test func sendNowDuringAReplyAddsTheMessageToIt() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-queued-\(UUID().uuidString)")!)
        settings.transport = .hermesServe
        let conversation = Conversation(settings: settings,
                                        store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "lab-queued-\(UUID().uuidString)")),
                                        transportOverride: HermesServeTransport(client: client), dashboard: client)
        _ = conversation.send(Self.drip)
        try await Task.sleep(for: .seconds(3))
        _ = conversation.send(Self.second)
        let head = try #require(conversation.outbox.first)
        let joins = conversation.canSteer(head)
        conversation.sendQueuedNow(head.id)
        let leftQueue = conversation.outbox.isEmpty
        for _ in 0 ..< 80 {
            try await Task.sleep(for: .milliseconds(250))
            if !conversation.isStreaming, conversation.outbox.isEmpty { break }
        }
        try await Task.sleep(for: .seconds(3))   // a turn of its own would have started by now
        for m in conversation.messages { print("  ----    \(m.role) \(m.isSteer ? "(steer) " : "")\(m.text.debugDescription)") }
        print("  ----  status: \(conversation.statusLine ?? "-"), error: \(conversation.lastError ?? "-")")
        let steers = conversation.messages.filter(\.isSteer).map(\.text)
        let replies = conversation.messages.filter { $0.role == .assistant }.count
        let asked = conversation.messages.filter { $0.role == .user && !$0.isSteer }.map(\.text)
        let ok = joins && leftQueue && steers == [Self.second] && asked == [Self.drip] && replies >= 1 && conversation.outbox.isEmpty
        HermesLabApprovalTests.report(ok, "Dashboard: Send Now on a queued message during a reply steers it into that reply",
                                      "joins: \(joins), left queue: \(leftQueue), steers: \(steers), asked: \(asked), replies: \(replies), outbox: \(conversation.outbox.count)")
    }

    /// GitHub issue 57: a question the agent asks mid-turn shows in the chat with its answer,
    /// before the reply that asked, and stays when the chat is read again from the host (where
    /// the answer is no message).
    @Test func aQuestionAnsweredMidTurnShowsWithItsAnswer() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-queued-\(UUID().uuidString)")!)
        settings.transport = .hermesServe
        let conversation = Conversation(settings: settings,
                                        store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "lab-queued-\(UUID().uuidString)")),
                                        transportOverride: HermesServeTransport(client: client), dashboard: client)
        _ = conversation.send("lab:question please")
        var asked: ClarifyRequest?
        for _ in 0 ..< 80 {
            try await Task.sleep(for: .milliseconds(250))
            if let waiting = conversation.pendingInterrupt, case let .clarify(request) = waiting.interrupt { asked = request; break }
        }
        let request = try #require(asked, "the lab's question never came")
        let question = try #require(request.questions.first)
        conversation.respond(clarify: [request.isBatch ? question.id : "": "release"])
        for _ in 0 ..< 80 {
            try await Task.sleep(for: .milliseconds(250))
            if !conversation.isStreaming { break }
        }
        func row(_ messages: [Message]) -> (index: Int, reply: Int?)? {
            guard let i = messages.firstIndex(where: { $0.answering == question.question && $0.text == "release" }) else { return nil }
            return (i, messages.lastIndex { $0.role == .assistant })
        }
        let live = row(conversation.messages)
        let stored = try #require(conversation.serverSessionID)
        try await conversation.open(serverSession: stored)
        let reread = row(conversation.messages)
        for m in conversation.messages { print("  ----    \(m.role) \(m.answering.map { "[\($0)] " } ?? "")\(m.text.prefix(60).debugDescription)") }
        let ok = live != nil && (live?.reply ?? -1) > (live?.index ?? 0) && reread != nil
        HermesLabApprovalTests.report(ok, "Dashboard: a question answered mid-turn shows with its answer, before the reply, and stays on reading again",
                                      "live: \(String(describing: live)), read again: \(String(describing: reread))")
    }

    /// The same with the reply joined partway (the app was away while the agent worked, as with a
    /// slow local model), then the next message queued behind it.
    @Test func aMessageQueuedDuringAJoinedReplyGetsItsOwnReply() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-queued-\(UUID().uuidString)")!)
        settings.transport = .hermesServe
        settings.serveURL = "http://127.0.0.1:19119"
        settings.serveUsername = "lab"
        func conversation() -> Conversation {
            Conversation(settings: settings,
                         store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "lab-queued-\(UUID().uuidString)")),
                         transportOverride: HermesServeTransport(client: client), dashboard: client)
        }
        let start = Date()
        var heard: [String] = []
        let listener = client.addListener { event in
            let text = event.payload["text"]?.string.map { " \"\($0.prefix(40))\"" } ?? ""
            let running = event.payload["running"]?.bool.map { " running=\($0)" } ?? ""
            heard.append(String(format: "%6.2f ", Date().timeIntervalSince(start)) + "\(event.type) \(event.sessionID ?? "-")\(text)\(running)")
        }
        defer { client.removeListener(listener) }

        let away = conversation()
        _ = away.send(Self.drip)
        try await Task.sleep(for: .seconds(3))
        guard let stored = away.serverSessionID else {
            HermesLabApprovalTests.report(false, "Dashboard: a joined reply", "the conversation got no session")
            return
        }
        away.reset()   // left while the agent works
        let back = conversation()
        try await back.open(serverSession: stored)
        await back.rejoinIfWaiting()
        let joined = back.isStreaming
        try await Task.sleep(for: .seconds(2))
        _ = back.send(Self.second)
        let queued = back.outbox.count
        for _ in 0 ..< 120 {
            try await Task.sleep(for: .milliseconds(250))
            let replies = back.messages.filter { $0.role == .assistant }
            if !back.isStreaming, back.outbox.isEmpty, replies.count >= 2, !(replies.last?.text.isEmpty ?? true) { break }
        }
        try await Task.sleep(for: .seconds(3))

        print("  ----  events (joined):")
        heard.forEach { print("  ----    \($0)") }
        print("  ----  transcript (joined):")
        for m in back.messages { print("  ----    \(m.role) \(m.isSteer ? "(steer) " : "")\(m.text.debugDescription)") }
        let shown = back.messages.map { ($0.role, $0.text) }
        let ok = joined && queued == 1 && shown.count == 4
            && shown[1].0 == .assistant && shown[1].1 == Self.dripped
            && shown[2] == (.user, Self.second) && shown[3].0 == .assistant && !shown[3].1.isEmpty && !shown[3].1.contains("word")
        HermesLabApprovalTests.report(ok, "Dashboard: a message sent after a joined reply gets its own reply, and the first stays whole",
                                      "joined: \(joined), queued: \(queued), transcript: \(shown)")
    }

    /// The connection drops while the agent answers after a tool step (its line before the tool and
    /// the answer after it make one reply here), and comes back after the turn ended; meanwhile the
    /// next message waits behind it. 2026-11-05: Hermes closes a client that falls behind, and a
    /// phone in a pocket does.
    @Test func aReplyCutByADroppedConnectionIsFilledInAndTheNextGetsItsOwn() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-queued-\(UUID().uuidString)")!)
        settings.transport = .hermesServe
        settings.serveURL = "http://127.0.0.1:19119"
        settings.serveUsername = "lab"
        let conversation = Conversation(settings: settings,
                                        store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "lab-queued-\(UUID().uuidString)")),
                                        transportOverride: HermesServeTransport(client: client), dashboard: client)
        let start = Date()
        var heard: [String] = []
        let listener = client.addListener { event in
            let text = event.payload["text"]?.string.map { " \"\($0.prefix(40))\"" } ?? ""
            let running = event.payload["running"]?.bool.map { " running=\($0)" } ?? ""
            heard.append(String(format: "%6.2f ", Date().timeIntervalSince(start)) + "\(event.type) \(event.sessionID ?? "-")\(text)\(running)")
        }
        defer { client.removeListener(listener) }

        _ = conversation.send("lab:tooldrip, please")
        for _ in 0 ..< 120 where !(conversation.messages.last?.text.contains("word2") ?? false) {
            try await Task.sleep(for: .milliseconds(100))
        }
        client.dropForTesting(holdingReconnectFor: 10)
        heard.append(String(format: "%6.2f ", Date().timeIntervalSince(start)) + "-- dropped")
        _ = conversation.send(Self.second)
        let queued = conversation.outbox.count
        for _ in 0 ..< 160 {
            try await Task.sleep(for: .milliseconds(250))
            let replies = conversation.messages.filter { $0.role == .assistant }
            if !conversation.isStreaming, conversation.outbox.isEmpty, replies.count >= 2, !(replies.last?.text.isEmpty ?? true) { break }
        }
        try await Task.sleep(for: .seconds(3))

        print("  ----  events (dropped):")
        heard.forEach { print("  ----    \($0)") }
        print("  ----  transcript (dropped):")
        for m in conversation.messages { print("  ----    \(m.role) \(m.isSteer ? "(steer) " : "")\(m.text.debugDescription)") }
        if let stored = conversation.serverSessionID {
            print("  ----  as the host has it (reopened):")
            for m in Conversation.messages(fromServeRows: try await client.history(stored: stored)) {
                print("  ----    \(m.role) \(m.text.debugDescription)")
            }
        }
        let shown = conversation.messages.map { ($0.role, $0.text) }
        let ok = queued == 1 && shown.count == 4
            && shown[1].0 == .assistant && shown[1].1.hasPrefix("Let me look.") && shown[1].1.hasSuffix("word7 [tooldrip done]")
            && shown[2] == (.user, Self.second) && shown[3].0 == .assistant && !shown[3].1.isEmpty && !shown[3].1.contains("word")
        HermesLabApprovalTests.report(ok, "Dashboard: a reply cut by a dropped connection is whole once it is back, and the next message gets its own",
                                      "queued: \(queued), transcript: \(shown)")
    }

    /// GitHub #64: a skill typed as a slash command (`/lab-hello` with words after it) is the
    /// turn: Hermes is sent the skill and answers, rather than its own line coming back as the reply.
    @Test func aSkillCommandRunsAsTheTurn() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-skill-\(UUID().uuidString)")!)
        settings.transport = .hermesServe
        let conversation = Conversation(settings: settings,
                                        store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "lab-skill-\(UUID().uuidString)")),
                                        transportOverride: HermesServeTransport(client: client), dashboard: client)
        let typed = "/lab-hello in plain words please"
        _ = conversation.send(typed)
        for _ in 0 ..< 120 {
            try await Task.sleep(for: .milliseconds(250))
            if !conversation.isStreaming, !(conversation.messages.last { $0.role == .assistant }?.text.isEmpty ?? true) { break }
        }
        let reply = conversation.messages.last { $0.role == .assistant }?.text ?? ""
        print("  ----  transcript:")
        for m in conversation.messages { print("  ----    \(m.role) \(m.text.prefix(200).debugDescription)") }
        let ok = !reply.isEmpty && reply != typed && !reply.hasPrefix("/lab-hello")
        HermesLabApprovalTests.report(ok, "Dashboard: a skill typed as /command runs as the turn", "reply: \(reply.prefix(200))")
    }
}
