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

    private func settings(on: Bool) -> Settings {
        let settings = Settings(defaults: defaults())
        settings.transport = .hermesServe
        settings.gatewayModel = "claude-opus-5-5"
        settings.gatewayProvider = "anthropic"
        settings.newChatsUseServerModel = on
        return settings
    }

    @Test func offEveryTurnAsksForReddesPick() {
        let settings = settings(on: false)
        let own = Pick(model: "qwen36-splash", provider: "custom:local")
        #expect(ConversationModels.turnModel(settings: settings, own: nil) == Pick(model: "claude-opus-5-5", provider: "anthropic"))
        #expect(ConversationModels.turnModel(settings: settings, own: own)?.model == "claude-opus-5-5", "a conversation's own pick is for the setting on")
        settings.gatewayModel = ""
        settings.gatewayProvider = ""
        #expect(ConversationModels.turnModel(settings: settings, own: nil) == nil, "Gateway default asks for none")
    }

    @Test func onATurnAsksForTheConversationsOwnPickElseNone() {
        let settings = settings(on: true)
        let own = Pick(model: "qwen36-splash", provider: "custom:local")
        #expect(ConversationModels.turnModel(settings: settings, own: nil) == nil, "Redde's pick is not sent")
        #expect(ConversationModels.turnModel(settings: settings, own: own) == own)
        #expect(settings.startingModel.isEmpty && settings.startingProvider.isEmpty)
    }

    @Test func theSettingIsSynced() {
        #expect(Settings.syncedKeys.contains("newChatsUseServerModel"))
        let settings = settings(on: true)
        settings.applySynced("newChatsUseServerModel", nil)
        #expect(!settings.newChatsUseServerModel)
        settings.applySynced("newChatsUseServerModel", true)
        #expect(settings.newChatsUseServerModel)
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

    private func conversation(on: Bool, _ transport: RecordingTransport, models: ConversationModels) -> (Conversation, Settings) {
        let settings = settings(on: on)
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

    @Test func offANewConversationStartsOnReddesPick() async throws {
        let transport = RecordingTransport()
        let (conversation, _) = conversation(on: false, transport, models: ConversationModels(defaults: defaults()))
        let first = try await ask(conversation, transport, "Hello.")
        #expect(first.model == "claude-opus-5-5" && first.provider == "anthropic")
    }

    @Test func onANewConversationSendsNoModel() async throws {
        let transport = RecordingTransport()
        let (conversation, _) = conversation(on: true, transport, models: ConversationModels(defaults: defaults()))
        let first = try await ask(conversation, transport, "Hello.")
        #expect(first.model == nil && first.provider == nil, "it starts on the server's model")
        let second = try await ask(conversation, transport, "Again.")
        #expect(second.model == nil && second.provider == nil)
    }

    @Test func onAPickIsThisConversationsAloneAndGoesWithEveryTurn() async throws {
        let transport = RecordingTransport()
        let models = ConversationModels(defaults: defaults())
        let (conversation, settings) = conversation(on: true, transport, models: models)
        // Picked before the first message: held, then kept with the session it made.
        try await conversation.switchModel("qwen36-splash", provider: "custom:local")
        #expect(settings.gatewayModel == "claude-opus-5-5" && settings.gatewayProvider == "anthropic", "Redde's pick is untouched")
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
