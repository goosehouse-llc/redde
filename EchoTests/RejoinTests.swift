import Foundation
import Testing
@testable import Echo

/// A conversation picking up a turn that is under way on the host: one the app didn't start in
/// this run. The transport here says what the host would (`RejoinedTurn`); the Dashboard's real
/// answer is checked in the lab (`HermesLabApprovalTests`).
@MainActor
struct RejoinTests {
    /// A Dashboard whose stored session has a turn under way, or not.
    final class Host: HermesTransport, @unchecked Sendable {
        var turn: RejoinedTurn?
        private(set) var asked: [String] = []
        private(set) var stops = 0
        private var feed: AsyncThrowingStream<TurnEvent, Error>.Continuation?

        nonisolated func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        nonisolated func rejoin(stored: String) async throws -> RejoinedTurn? {
            await MainActor.run {
                asked.append(stored)
                return turn
            }
        }

        /// A turn under way: `emit` and `end` play it; `recorded` is what the host has at the end.
        func start(question: String = "Clean up the build folder", recorded: [Message] = []) {
            let (events, feed) = AsyncThrowingStream<TurnEvent, Error>.makeStream()
            self.feed = feed
            turn = RejoinedTurn(question: question, events: events,
                                stop: { [weak self] in Task { @MainActor in self?.stops += 1 } },
                                transcript: { recorded })
        }

        func emit(_ events: TurnEvent...) { for event in events { feed?.yield(event) } }
        func end(throwing error: Error? = nil) { feed?.finish(throwing: error) }
    }

    private static let approval = ApprovalRequest(id: "srq-1", command: "rm -rf build", description: "recursive delete",
                                                  choices: ["once", "session", "always", "deny"])

    /// A Dashboard conversation as it is after being opened from the server: the question asked,
    /// and nothing after it.
    private func opened(_ host: Host, transport: Transport = .hermesServe) -> Conversation {
        let settings = Settings(defaults: UserDefaults(suiteName: "rejoin-\(UUID().uuidString)")!)
        settings.transport = transport
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "rejoin-\(UUID().uuidString)"))
        let conversation = Conversation(settings: settings, store: store, transportOverride: host)
        conversation.replaceForDemo(serverSessionID: "20261007_1", messages: [Message(role: .user, text: "Clean up the build folder")])
        return conversation
    }

    private func wait(_ what: String, until condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(what)")
    }

    @Test func theCardComesBackAndTheReplyIsFollowedToItsEnd() async throws {
        let host = Host()
        var reply = Message(role: .assistant, text: "Removing it. Done: the folder is gone.")
        reply.tools = [ToolActivity(name: "terminal", preview: "rm -rf build", status: .completed)]
        host.start(recorded: [Message(role: .user, text: "Clean up the build folder"), reply])
        let conversation = opened(host)

        await conversation.rejoinIfWaiting()
        #expect(host.asked == ["20261007_1"])
        #expect(conversation.isStreaming)
        #expect(conversation.messages.count == 2 && conversation.messages[1].role == .assistant, "a reply in progress under the question")

        host.emit(.textDelta("Removing it. "), .interrupt(.approval(Self.approval), runtimeSession: "rt-1"))
        try await wait("the approval card") { conversation.pendingInterrupt != nil }
        guard case let .approval(asked)? = conversation.pendingInterrupt?.interrupt else {
            Issue.record("not an approval")
            return
        }
        #expect(asked == Self.approval && conversation.pendingInterrupt?.runtimeSession == "rt-1")

        // Answered (here or anywhere): the tool finishes and the reply runs on.
        host.emit(.toolFinished(name: "terminal", failed: false, output: nil), .textDelta("Done: the folder is gone."), .done)
        host.end()
        try await wait("the end of the turn") { !conversation.isStreaming }
        #expect(conversation.pendingInterrupt == nil)
        #expect(conversation.messages.map(\.text) == ["Clean up the build folder", "Removing it. Done: the folder is gone."])
        #expect(conversation.messages[1].tools.map(\.name) == ["terminal"],
                "the tool call made before the app joined comes from the host's record")
        #expect(conversation.messages[1].id == conversation.messages.last?.id && conversation.messages.count == 2)
        #expect(conversation.lastError == nil)
        #expect(host.stops == 0)
    }

    @Test func theRecordFillsInWhatWasMissedAndTakesNothingAway() async throws {
        let host = Host()
        // The app joined after the reply had begun, and the host had no words so far to hand over.
        host.start(recorded: [Message(role: .user, text: "Clean up the build folder"),
                              Message(role: .assistant, text: "First the cache. Then the build folder: both are gone.")])
        let conversation = opened(host)
        await conversation.rejoinIfWaiting()
        host.emit(.toolStarted(name: "terminal", preview: "rm -rf build"), .toolFinished(name: "terminal", failed: false, output: nil),
                  .textDelta("both are gone."), .done)
        host.end()
        try await wait("the end of the turn") { !conversation.isStreaming }
        #expect(conversation.messages.last?.text == "First the cache. Then the build folder: both are gone.", "the record has the whole reply")
        #expect(conversation.messages.last?.tools.map(\.name) == ["terminal"], "the tool call that was heard stays, though the record lists none")
    }

    @Test func aRecordThatCannotBeFetchedLeavesWhatWasHeard() async throws {
        let host = Host()
        host.start()
        host.turn?.transcript = { throw TransportError.unreachable("gone") }
        let conversation = opened(host)
        await conversation.rejoinIfWaiting()
        host.emit(.textDelta("Still here."), .done)
        host.end()
        try await wait("the end of the turn") { !conversation.isStreaming }
        #expect(conversation.messages.map(\.text) == ["Clean up the build folder", "Still here."])
    }

    @Test func nothingUnderWayChangesNothing() async {
        let host = Host()
        let conversation = opened(host)
        await conversation.rejoinIfWaiting()
        #expect(host.asked == ["20261007_1"])
        #expect(!conversation.isStreaming && conversation.messages.count == 1)
    }

    @Test func aConversationCutOffBeforeItsReplyIsTheOneThatCatchesUp() async throws {
        let host = Host()
        let conversation = opened(host)
        #expect(conversation.endsUnanswered, "a question and nothing after it")
        host.start()
        await conversation.rejoinIfWaiting()
        #expect(!conversation.endsUnanswered, "a reply is on its way")
        host.emit(.textDelta("Done."), .done)
        host.end()
        try await wait("the end of the turn") { !conversation.isStreaming }
        #expect(!conversation.endsUnanswered, "answered")
        conversation.reset()
        #expect(!conversation.endsUnanswered, "an empty conversation is waiting for nothing")
    }

    @Test func onlyADashboardConversationThatIsIdleAsks() async {
        let host = Host()
        host.start()
        let viaAPI = opened(host, transport: .hermesSessions)
        await viaAPI.rejoinIfWaiting()
        #expect(host.asked.isEmpty, "the Hermes API keeps no turn to join")

        let fresh = opened(host)
        fresh.reset()   // a new conversation: no session on the host yet
        await fresh.rejoinIfWaiting()
        #expect(host.asked.isEmpty)

        let joined = opened(host)
        await joined.rejoinIfWaiting()
        await joined.rejoinIfWaiting()   // already following it
        #expect(host.asked == ["20261007_1"])
    }

    @Test func leavingTheConversationLeavesTheTurnRunning() async throws {
        let host = Host()
        host.start()
        let conversation = opened(host)
        await conversation.rejoinIfWaiting()
        host.emit(.interrupt(.approval(Self.approval), runtimeSession: "rt-1"))
        try await wait("the approval card") { conversation.pendingInterrupt != nil }

        conversation.reset()   // off to a new conversation
        try await Task.sleep(for: .milliseconds(50))
        #expect(!conversation.isStreaming && conversation.pendingInterrupt == nil)
        #expect(host.stops == 0, "someone else may be waiting for that turn; it was only being watched")
        #expect(conversation.messages.isEmpty)
    }

    @Test func stopStopsIt() async throws {
        let host = Host()
        host.start()
        let conversation = opened(host)
        await conversation.rejoinIfWaiting()
        host.emit(.textDelta("Working on"))
        try await wait("the first words") { conversation.messages.last?.text == "Working on" }

        conversation.cancel()
        try await wait("the stop reaching the host") { host.stops == 1 }
        #expect(!conversation.isStreaming)
        #expect(conversation.messages.last?.text == "Working on", "what was heard stays")
    }

    @Test func aTurnThatWasNeverHeardFromLeavesNoTrace() async throws {
        let host = Host()
        host.start()
        let conversation = opened(host)
        await conversation.rejoinIfWaiting()
        host.end(throwing: TransportError.unreachable("lost the connection"))
        try await wait("the end of the turn") { !conversation.isStreaming }
        #expect(conversation.messages.count == 1, "no empty reply, and no error under a question that wasn't asked here")
        #expect(conversation.lastError == nil)
    }
}
