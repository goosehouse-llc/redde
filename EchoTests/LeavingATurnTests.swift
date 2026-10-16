import Foundation
import Testing
@testable import Echo

/// What becomes of a turn when its conversation is left for another one (GitHub issue 12): on a
/// Hermes connection the app lets go of it and the host finishes it; Stop and deleting stop it;
/// the fast lane, with no host to go on, stops it whatever. The host's side is checked against
/// real Hermes in `HermesLabSwitchTests`; here, what the transport is told.
@MainActor
struct LeavingATurnTests {
    /// A turn that never ends by itself, and remembers how it was let go of.
    final class HangingTransport: HermesTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var departures: [TurnDeparture?] = []
        var departure: TurnDeparture? { lock.withLock { departures.last ?? nil } }
        nonisolated func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
            lock.withLock { departures.append(request.departure) }
            return AsyncThrowingStream { continuation in
                let task = Task {
                    continuation.yield(.sessionID("stored-1"))
                    try? await Task.sleep(for: .seconds(30))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    private func conversation(_ transport: HangingTransport, on kind: Transport = .hermesServe) -> Conversation {
        let settings = Settings(defaults: UserDefaults(suiteName: "leaving-\(UUID().uuidString)")!)
        settings.transport = kind
        settings.fastLaneURL = "http://example.invalid:11500"
        settings.fastLaneModel = "test"
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "leaving-\(UUID().uuidString)"))
        return Conversation(settings: settings, store: store, transportOverride: transport)
    }

    /// A turn under way, as far as the transport goes.
    private func asking(_ conversation: Conversation, _ transport: HangingTransport) async throws -> TurnDeparture {
        _ = conversation.send("Do the long thing.")
        for _ in 0 ..< 100 where transport.departure == nil { try await Task.sleep(for: .milliseconds(10)) }
        return try #require(transport.departure)
    }

    @Test func startingAnotherConversationLetsTheTurnGoOn() async throws {
        let transport = HangingTransport()
        let conversation = conversation(transport)
        let departure = try await asking(conversation, transport)
        conversation.reset()
        #expect(departure.hasLeft, "a new conversation lets go of the turn; the host finishes it")
        #expect(!conversation.isStreaming)
    }

    @Test func openingAnotherConversationLetsTheTurnGoOn() async throws {
        let transport = HangingTransport()
        let conversation = conversation(transport)
        let other = ConversationRecord(id: UUID(), title: "Earlier", createdAt: .now, updatedAt: .now, transport: .hermesServe,
                                       serverSessionID: "stored-2", messages: [Message(role: .user, text: "Earlier.")])
        let departure = try await asking(conversation, transport)
        conversation.load(other)
        #expect(departure.hasLeft)
        #expect(conversation.messages.first?.text == "Earlier.")
    }

    @Test func stopAndDeleteStopTheTurn() async throws {
        let transport = HangingTransport()
        let conversation = conversation(transport)
        let stopped = try await asking(conversation, transport)
        conversation.cancel()
        #expect(!stopped.hasLeft, "Stop stops the agent")

        // (After a Stop the next message waits in the queue: a conversation of its own.)
        let other = HangingTransport()
        let deleting = self.conversation(other)
        let deleted = try await asking(deleting, other)
        deleting.delete(id: deleting.id)
        #expect(!deleted.hasLeft, "a deleted conversation's turn is stopped, not left to run")
    }

    @Test func theFastLaneHasNoHostToGoOnSoLeavingStopsIt() async throws {
        let transport = HangingTransport()
        let conversation = conversation(transport, on: .chatCompletions)
        let departure = try await asking(conversation, transport)
        conversation.reset()
        #expect(!departure.hasLeft)
    }
}
