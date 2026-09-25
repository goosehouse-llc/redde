import Foundation
import Testing
@testable import Echo

/// Siri AI (iOS 27 Messages schemas): ids, message composition, read marks, and a Siri-sent
/// turn through a scripted transport — the reply spoken when quick, "pending" when slow.
@MainActor
struct SiriSchemaTests {
    private typealias Scripted = ConversationLifecycleTests.ScriptedTransport

    private func makeConversation(_ transport: any HermesTransport) -> Conversation {
        let suite = UserDefaults(suiteName: "siri-\(UUID().uuidString)")!
        let settings = Settings(defaults: suite)
        settings.transport = .chatCompletions
        settings.fastLaneURL = "http://example.invalid:11500"
        settings.fastLaneModel = "test"
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "siri-\(UUID().uuidString)"))
        return Conversation(settings: settings, store: store, transportOverride: transport)
    }

    @Test func messageIDsRoundTrip() throws {
        let c = UUID(), m = UUID()
        let parsed = try #require(SiriID.parseMessage(SiriID.message(c, m)))
        #expect(parsed.conversation == c)
        #expect(parsed.message == m)
        #expect(SiriID.parseMessage("not-an-id") == nil)
        #expect(SiriID.parseMessage("\(c.uuidString):nope") == nil)
    }

    @Test func readMarksFollowTheConversation() {
        let c = UUID()
        let a = SiriID.message(c, UUID()), b = SiriID.message(c, UUID())
        ReadState.set(a, read: false)
        ReadState.set(b, read: false)
        #expect(!ReadState.isRead(a))
        ReadState.set(a, read: true)
        #expect(ReadState.isRead(a))
        #expect(!ReadState.isRead(b))
        ReadState.markConversationRead(c)
        #expect(ReadState.isRead(b))
    }

    @available(iOS 27.0, *)
    @Test func composeJoinsSubjectTextAndLinks() {
        let text = SiriTurn.compose(content: AttributedString("  did the backup run? "), subject: AttributedString("Backups"),
                                    links: [URL(string: "https://example.com/log")!])
        #expect(text == "Backups\n\ndid the backup run?\n\nhttps://example.com/log")
        #expect(SiriTurn.compose(content: AttributedString("   "), subject: nil, links: []).isEmpty)
    }

    @available(iOS 27.0, *)
    @Test func onlyTheAgentCanBeMessaged() throws {
        #expect(throws: SiriError.unknownRecipient(Settings.shared.headerTitle)) {
            try SiriTurn.check(.contact(.me))
        }
        #expect(throws: SiriError.unknownRecipient(Settings.shared.headerTitle)) {
            try SiriTurn.check(.recipients([.agent(named: "Sol"), .me]))
        }
        try SiriTurn.check(.contact(.agent(named: "Sol")))
        try SiriTurn.check(.recipients([.agent(named: "Sol")]))
    }

    @available(iOS 27.0, *)
    @Test func quickReplyIsSpokenAndHeldFromTheBanner() async throws {
        let c = makeConversation(Scripted([.textDelta("The backup "), .textDelta("**ran** at 3am."), .done]))
        let outcome = try await SiriTurn.send("did the backup run?", attachments: [], live: c)
        #expect(outcome.reply == .replied("The backup ran at 3am."))
        #expect(outcome.sent.count == 1)
        #expect(!Notifier.shared.holdsReplies)
        #expect(c.messages.map(\.role) == [.user, .assistant])
    }

    @available(iOS 27.0, *)
    @Test func slowReplyLeavesTheTurnRunning() async throws {
        let c = makeConversation(Scripted([.textDelta("thinking…")], hang: true))
        let budget = SiriTurn.replyBudget
        SiriTurn.replyBudget = .milliseconds(300)
        defer { SiriTurn.replyBudget = budget }
        let outcome = try await SiriTurn.send("plan my week", attachments: [], live: c)
        #expect(outcome.reply == .pending)
        #expect(c.isStreaming)   // Siri stopped waiting; the turn did not stop
        #expect(!Notifier.shared.holdsReplies)
        c.cancel()
    }

    @available(iOS 27.0, *)
    @Test func sendingBehindARunningReplyQueues() async throws {
        let c = makeConversation(Scripted([.textDelta("…")], hang: true))
        c.send("first")
        let outcome = try await SiriTurn.send("second", attachments: [], live: c)
        #expect(outcome.reply == .queued)
        #expect(outcome.sent.isEmpty)
        c.cancel()
    }
}
