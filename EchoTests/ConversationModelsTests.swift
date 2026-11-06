import Foundation
import Testing
@testable import Echo

/// New Chats Use the Server's Model (GitHub issue 45): each conversation's own pick, kept by
/// connection and session, and the model each turn asks for with the setting off and on.
@MainActor
struct ConversationModelsTests {
    private typealias Pick = ConversationModels.Pick

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "models-\(UUID().uuidString)")! }

    // MARK: - The store

    @Test func aPickIsKeptByConnectionAndSession() {
        let store = defaults()
        let models = ConversationModels(defaults: store)
        models.set(Pick(model: "claude-opus-5-5", provider: "anthropic"), connection: "server-a|", session: "s1")
        #expect(models.pick(connection: "server-a|", session: "s1") == Pick(model: "claude-opus-5-5", provider: "anthropic"))
        #expect(models.pick(connection: "server-a|", session: "s2") == nil, "another conversation has none")
        #expect(models.pick(connection: "server-b|", session: "s1") == nil, "the same session id on another server is another conversation")
        #expect(ConversationModels(defaults: store).pick(connection: "server-a|", session: "s1")?.model == "claude-opus-5-5",
                "kept across launches")
    }

    @Test func aNewPickReplacesTheOldOneAndNilForgetsIt() {
        let models = ConversationModels(defaults: defaults())
        models.set(Pick(model: "a", provider: nil), connection: "c", session: "s1")
        models.set(Pick(model: "b", provider: "openrouter"), connection: "c", session: "s1")
        #expect(models.pick(connection: "c", session: "s1") == Pick(model: "b", provider: "openrouter"))
        models.set(nil, connection: "c", session: "s1")
        #expect(models.pick(connection: "c", session: "s1") == nil)
    }

    @Test func theOldestPicksGoPastTheLimit() {
        let models = ConversationModels(defaults: defaults())
        for i in 0 ... ConversationModels.limit {
            models.set(Pick(model: "m\(i)", provider: nil), connection: "c", session: "s\(i)")
        }
        #expect(models.pick(connection: "c", session: "s0") == nil, "the oldest went")
        #expect(models.pick(connection: "c", session: "s1")?.model == "m1")
        #expect(models.pick(connection: "c", session: "s\(ConversationModels.limit)")?.model == "m\(ConversationModels.limit)")
    }

    // MARK: - The model a turn asks for

    /// Settings as an older Redde left them: its one model for every conversation, which is no
    /// longer read (GitHub issue 58).
    private func settings() -> Settings {
        let settings = Settings(defaults: defaults())
        settings.transport = .hermesServe
        settings.gatewayModel = "claude-opus-5-5"
        settings.gatewayProvider = "anthropic"
        return settings
    }

    @Test func aTurnAsksForTheConversationsOwnPickElseNone() {
        let own = Pick(model: "qwen36-splash", provider: "custom:local")
        #expect(ConversationModels.turnModel(own: nil) == nil, "none: the bot's model, or the server's")
        #expect(ConversationModels.turnModel(own: own) == own)
    }

    @Test func theOldSwitchIsGone() {
        #expect(!Settings.syncedKeys.contains("newChatsUseServerModel"))
    }

    // MARK: - Through a conversation

    /// Keeps what it was sent; each turn gets the same session back.
    final class RecordingTransport: HermesTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [TurnRequest] = []
        var requests: [TurnRequest] { lock.withLock { kept } }
        nonisolated func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
            lock.withLock { kept.append(request) }
            return AsyncThrowingStream { continuation in
                continuation.yield(.sessionID("stored-1"))
                continuation.yield(.textDelta("Done."))
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }

    private func conversation(_ transport: RecordingTransport, models: ConversationModels) -> (Conversation, Settings) {
        let settings = settings()
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "models-\(UUID().uuidString)"))
        return (Conversation(settings: settings, store: store, transportOverride: transport, models: models), settings)
    }

    private func ask(_ conversation: Conversation, _ transport: RecordingTransport, _ text: String) async throws -> TurnRequest {
        let before = transport.requests.count
        _ = conversation.send(text)
        for _ in 0 ..< 300 where transport.requests.count == before || conversation.isStreaming {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(transport.requests.last)
    }

    @Test func aNewConversationSendsNoModelThoughAnOlderReddeHadOne() async throws {
        let transport = RecordingTransport()
        let (conversation, _) = conversation(transport, models: ConversationModels(defaults: defaults()))
        let first = try await ask(conversation, transport, "Hello.")
        #expect(first.model == nil && first.provider == nil, "it starts on the server's model (or its bot's), not the old one-for-all")
        let second = try await ask(conversation, transport, "Again.")
        #expect(second.model == nil && second.provider == nil)
    }

    @Test func aPickIsThisConversationsAloneAndGoesWithEveryTurn() async throws {
        let transport = RecordingTransport()
        let models = ConversationModels(defaults: defaults())
        let (conversation, settings) = conversation(transport, models: models)
        // Picked before the first message: held, then kept with the session it made.
        try await conversation.switchModel("qwen36-splash", provider: "custom:local")
        #expect(settings.gatewayModel == "claude-opus-5-5", "nothing of the app's own moves")
        let first = try await ask(conversation, transport, "Hello.")
        #expect(first.model == "qwen36-splash" && first.provider == "custom:local")
        #expect(models.pick(connection: settings.connectionKey, session: "stored-1")?.model == "qwen36-splash")
        let second = try await ask(conversation, transport, "Again.")
        #expect(second.model == "qwen36-splash" && second.provider == "custom:local", "later turns keep it")
        #expect(conversation.turnModel?.model == "qwen36-splash")

        conversation.reset()
        #expect(conversation.ownModel == nil, "a new conversation has no pick of its own")
        let other = try await ask(conversation, transport, "Something else.")
        #expect(other.model == nil, "and starts on the server's model")
    }
}
