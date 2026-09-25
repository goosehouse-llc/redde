import Foundation
import Testing
@testable import Echo

/// Drives Conversation through a fake transport to pin the turn lifecycle.
@MainActor
struct ConversationLifecycleTests {
    /// Emits the given events with a small delay between them, forever if asked, so cancellation can be tested.
    final class ScriptedTransport: HermesTransport {
        let events: [TurnEvent]
        let hang: Bool
        init(_ events: [TurnEvent], hang: Bool = false) { self.events = events; self.hang = hang }
        nonisolated func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
            let events = events, hang = hang
            return AsyncThrowingStream { continuation in
                let task = Task {
                    for e in events {
                        try await Task.sleep(for: .milliseconds(20))
                        continuation.yield(e)
                    }
                    if hang { try await Task.sleep(for: .seconds(30)) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    /// Plays one script per call, in order; the last script repeats. A script may end by throwing.
    final class SequencedTransport: HermesTransport, @unchecked Sendable {
        struct Script: Sendable { var events: [TurnEvent]; var error: Error?; var hang = false }
        private let lock = NSLock()
        private var scripts: [Script]
        private(set) var calls = 0
        private(set) var prompts: [String] = []
        init(_ scripts: [Script]) { self.scripts = scripts }
        nonisolated func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
            lock.lock()
            let script = scripts.count > 1 ? scripts.removeFirst() : scripts[0]
            calls += 1; prompts.append(request.userText)
            lock.unlock()
            return AsyncThrowingStream { continuation in
                let task = Task {
                    for e in script.events {
                        try await Task.sleep(for: .milliseconds(20))
                        continuation.yield(e)
                    }
                    if script.hang { try await Task.sleep(for: .seconds(30)) }
                    if let error = script.error { continuation.finish(throwing: error) } else { continuation.finish() }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    private static let offline = URLError(.notConnectedToInternet)

    /// Fast-lane settings in a throwaway defaults suite, so no ledger session is created first.
    private func makeConversation(_ transport: any HermesTransport, store: ConversationStore? = nil) -> Conversation {
        let suite = UserDefaults(suiteName: "lifecycle-\(UUID().uuidString)")!
        let settings = Settings(defaults: suite)
        settings.transport = .chatCompletions
        settings.fastLaneURL = "http://example.invalid:11500"
        settings.fastLaneModel = "test"
        settings.contextWindow = 4096
        let store = store ?? Self.makeStore()
        let c = Conversation(settings: settings, store: store, transportOverride: transport)
        c.retryDelays = [30]   // tests trigger retries themselves
        return c
    }

    private static func makeStore() -> ConversationStore {
        ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "lifecycle-\(UUID().uuidString)"))
    }

    // MARK: - Offline queue

    @Test func unreachableServerHoldsTheMessageInsteadOfFailing() async throws {
        let t = SequencedTransport([.init(events: [], error: Self.offline)])
        let c = makeConversation(t)
        for await _ in c.send("are you there?") {}
        try await Task.sleep(for: .milliseconds(150))
        #expect(c.messages.isEmpty, "the question comes back out of the transcript")
        #expect(c.outbox.map(\.message.text) == ["are you there?"])
        #expect(c.outbox.first?.state == .waitingForConnection)
        #expect(c.lastError == nil && !c.isStreaming && c.lastSendWasHeld)
    }

    @Test func heldMessageSendsWhenTheConnectionReturns() async throws {
        let t = SequencedTransport([.init(events: [], error: Self.offline), .init(events: [.textDelta("back"), .done], error: nil)])
        let c = makeConversation(t)
        for await _ in c.send("hello") {}
        try await Task.sleep(for: .milliseconds(100))
        c.retryOutbox()
        try await Task.sleep(for: .milliseconds(250))
        #expect(c.outbox.isEmpty)
        #expect(c.messages.map(\.text) == ["hello", "back"])
        #expect(t.prompts == ["hello", "hello"])
    }

    @Test func connectionLostMidReplyIsAFailureNotAResend() async throws {
        let t = SequencedTransport([.init(events: [.textDelta("half an ans")], error: Self.offline)])
        let c = makeConversation(t)
        for await _ in c.send("question") {}
        try await Task.sleep(for: .milliseconds(150))
        #expect(c.outbox.isEmpty, "the server already had it; sending again could repeat the turn")
        #expect(c.messages.last?.error != nil)
    }

    @Test func serverErrorsStillFail() async throws {
        let t = SequencedTransport([.init(events: [], error: TransportError.http(status: 401, body: "bad key"))])
        let c = makeConversation(t)
        for await _ in c.send("question") {}
        try await Task.sleep(for: .milliseconds(150))
        #expect(c.outbox.isEmpty)
        #expect(c.lastError != nil)
    }

    @Test func messagesSentWhileOfflineQueueBehindAndGoInOrder() async throws {
        let t = SequencedTransport([.init(events: [], error: Self.offline),
                                    .init(events: [.textDelta("one"), .done], error: nil),
                                    .init(events: [.textDelta("two"), .done], error: nil)])
        let c = makeConversation(t)
        for await _ in c.send("first") {}
        try await Task.sleep(for: .milliseconds(100))
        #expect(c.outbox.map(\.message.text) == ["first"])
        // Sending again is itself a reason to retry: "first" goes, and "second" follows it.
        _ = c.send("second")
        try await Task.sleep(for: .milliseconds(600))
        #expect(c.outbox.isEmpty)
        #expect(c.messages.map(\.text) == ["first", "one", "second", "two"])
    }

    @Test func staleHeldMessageWaitsForConfirmation() async throws {
        let store = Self.makeStore()
        var old = Message(role: .user, text: "from this morning")
        old.createdAt = .now.addingTimeInterval(-7200)
        store.upsert(ConversationRecord(id: UUID(), title: "t", createdAt: .now, updatedAt: .now, transport: .chatCompletions,
                                        serverSessionID: nil, messages: [],
                                        outbox: [OutboxItem(message: old, state: .waitingForConnection, queuedAt: .now.addingTimeInterval(-7200))]))
        let t = SequencedTransport([.init(events: [.textDelta("ok"), .done], error: nil)])
        let c = makeConversation(t, store: store)
        #expect(c.outbox.count == 1, "restored from disk")
        c.retryOutbox()
        try await Task.sleep(for: .milliseconds(150))
        #expect(c.outbox.first?.state == .paused && t.calls == 0, "hours-old messages don't send on their own")
        c.sendQueuedNow(try #require(c.outbox.first).id)
        try await Task.sleep(for: .milliseconds(250))
        #expect(c.outbox.isEmpty && c.messages.map(\.text) == ["from this morning", "ok"])
    }

    @Test func heldMessagesSurviveARelaunch() async throws {
        let store = Self.makeStore()
        let c = makeConversation(SequencedTransport([.init(events: [], error: Self.offline)]), store: store)
        for await _ in c.send("remember me") {}
        try await Task.sleep(for: .milliseconds(800))   // debounced save
        let relaunched = makeConversation(SequencedTransport([.init(events: [.textDelta("hi"), .done], error: nil)]), store: store)
        #expect(relaunched.outbox.map(\.message.text) == ["remember me"])
    }

    // MARK: - Queue while streaming

    @Test func sendingDuringAReplyQueuesTheNextQuestion() async throws {
        let t = SequencedTransport([.init(events: [.textDelta("a"), .textDelta("b"), .textDelta("c"), .done], error: nil),
                                    .init(events: [.textDelta("second answer"), .done], error: nil)])
        let c = makeConversation(t)
        _ = c.send("first")
        try await Task.sleep(for: .milliseconds(30))
        #expect(c.isStreaming)
        _ = c.send("second")
        #expect(c.outbox.map(\.message.text) == ["second"] && c.outbox.first?.state == .queued)
        try await Task.sleep(for: .milliseconds(600))
        #expect(c.outbox.isEmpty)
        #expect(c.messages.map(\.text) == ["first", "abc", "second", "second answer"])
    }

    @Test func stopPausesTheQueue() async throws {
        let t = SequencedTransport([.init(events: [.textDelta("x")], error: nil, hang: true),
                                    .init(events: [.textDelta("later"), .done], error: nil)])
        let c = makeConversation(t)
        _ = c.send("first")
        try await Task.sleep(for: .milliseconds(60))
        _ = c.send("second")
        c.cancel()
        try await Task.sleep(for: .milliseconds(200))
        #expect(c.outbox.first?.state == .paused && t.calls == 1, "Stop means stop: the queued message waits for Send")
        c.sendQueuedNow(try #require(c.outbox.first).id)
        try await Task.sleep(for: .milliseconds(250))
        #expect(c.outbox.isEmpty && c.messages.last?.text == "later")
    }

    @Test func removingAQueuedMessageHandsItBack() async throws {
        let t = SequencedTransport([.init(events: [], error: Self.offline)])
        let c = makeConversation(t)
        for await _ in c.send("draft me") {}
        try await Task.sleep(for: .milliseconds(100))
        let removed = c.removeQueued(try #require(c.outbox.first).id)
        #expect(removed?.text == "draft me" && c.outbox.isEmpty)
    }

    @Test func completedTurnRecordsMetricsAndText() async throws {
        let c = makeConversation(ScriptedTransport([.textDelta("Hello "), .textDelta("there."), .done]))
        for await _ in c.send("hi") {}
        try await Task.sleep(for: .milliseconds(150))
        let reply = try #require(c.messages.last)
        #expect(reply.role == .assistant && reply.text == "Hello there.")
        #expect(reply.metrics?.completedAt != nil)
        #expect(!c.isStreaming && c.lastError == nil)
    }

    @Test func cancelledTurnIsNotReportedAsCompleted() async throws {
        let c = makeConversation(ScriptedTransport([.textDelta("partial")], hang: true))
        _ = c.send("hi")
        try await Task.sleep(for: .milliseconds(120))
        c.cancel()
        try await Task.sleep(for: .milliseconds(150))
        let reply = try #require(c.messages.last)
        #expect(reply.text == "partial")
        #expect(reply.metrics?.completedAt == nil, "a cancelled turn must not be stamped complete")
        #expect(reply.error == nil, "cancellation is not a failure")
        #expect(!c.isStreaming)
    }

    @Test func cancelledTailDoesNotClobberNextTurn() async throws {
        let c = makeConversation(ScriptedTransport([.textDelta("x")], hang: true))
        _ = c.send("first")
        try await Task.sleep(for: .milliseconds(60))
        c.cancel()
        _ = c.send("second")   // starts while the first turn's task is still unwinding
        try await Task.sleep(for: .milliseconds(200))
        #expect(c.isStreaming, "the second turn must still be streaming after the first turn's tail ran")
        c.cancel()
    }

    @Test func regenerateReplacesTheReplyInPlace() async throws {
        let c = makeConversation(ScriptedTransport([.textDelta("Hello "), .textDelta("there."), .done]))
        for await _ in c.send("hi") {}
        try await Task.sleep(for: .milliseconds(150))
        let firstReply = try #require(c.messages.last)
        await c.regenerate(replyID: firstReply.id)
        try await Task.sleep(for: .milliseconds(250))
        #expect(c.messages.count == 2, "the question and one reply, not two exchanges")
        #expect(c.messages.first?.text == "hi")
        #expect(c.messages.last?.id != firstReply.id && c.messages.last?.text == "Hello there.")
    }

    @Test func editAndResendTruncatesEverythingAfterTheMessage() async throws {
        let c = makeConversation(ScriptedTransport([.textDelta("ok"), .done]))
        for await _ in c.send("first") {}
        for await _ in c.send("second") {}
        try await Task.sleep(for: .milliseconds(150))
        let first = try #require(c.messages.first)
        await c.resend(replacing: first.id, text: "first, edited", attachments: [])
        try await Task.sleep(for: .milliseconds(200))
        #expect(c.messages.map(\.text) == ["first, edited", "ok"])
    }

    @Test func attachmentOnlyMessageSurvivesPersist() async throws {
        let c = makeConversation(ScriptedTransport([.textDelta("ok"), .done]))
        let att = Attachment(kind: .text, filename: "a.txt", mimeType: "text/plain", data: Data("hi".utf8))
        for await _ in c.send("", attachments: [att]) {}
        try await Task.sleep(for: .milliseconds(150))
        #expect(c.messages.first?.attachments.count == 1)
        try await Task.sleep(for: .milliseconds(600))   // debounced save
        #expect(c.persistedMessageCountForTesting == 2)
    }

    @Test func switchingConversationsDoesNotReorderTheList() async throws {
        let store = Self.makeStore()
        let c = makeConversation(ScriptedTransport([.textDelta("ok"), .done]), store: store)
        for await _ in c.send("older") {}
        try await Task.sleep(for: .milliseconds(150))
        let older = c.id
        c.reset()
        for await _ in c.send("newer") {}
        try await Task.sleep(for: .milliseconds(150))
        let newer = c.id
        c.load(try #require(store.record(id: older)))
        c.load(try #require(store.record(id: newer)))   // leaving `older` used to stamp it newest
        #expect(store.sorted.map(\.id) == [newer, older], "the list orders by content changes, not by what was last viewed")
    }
}
