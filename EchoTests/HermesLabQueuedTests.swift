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
}
