import Foundation
import Testing
@testable import Echo

/// `Conversation.switchModel` is the sticky switch a spoken prefix makes: the setting moves, and
/// an open hermes session is re-pinned. Without a session there's nothing to pin, so these run
/// offline.
@MainActor
struct ModelSwitchTests {
    private func makeConversation(transport: Transport) -> (Conversation, Settings) {
        let settings = Settings(defaults: UserDefaults(suiteName: "switch-\(UUID().uuidString)")!)
        settings.transport = transport
        settings.fastLaneURL = "http://example.invalid:11500"
        settings.fastLaneModel = "before"
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "switch-\(UUID().uuidString)"))
        return (Conversation(settings: settings, store: store), settings)
    }

    @Test func fastLaneSwitchesTheRequestModel() async throws {
        let (conversation, settings) = makeConversation(transport: .chatCompletions)
        try await conversation.switchModel("qwen3-4b", provider: "ignored")
        #expect(settings.fastLaneModel == "qwen3-4b")
        #expect(settings.gatewayModel.isEmpty)
    }

    @Test func hermesSwitchesTheGatewayModelAndProvider() async throws {
        let (conversation, settings) = makeConversation(transport: .hermesSessions)
        try await conversation.switchModel("claude-opus-5-5", provider: "anthropic")
        #expect(settings.gatewayModel == "claude-opus-5-5")
        #expect(settings.gatewayProvider == "anthropic")
        #expect(settings.fastLaneModel == "before")
    }

    @Test func aMissingProviderClearsTheOldOne() async throws {
        let (conversation, settings) = makeConversation(transport: .hermesServe)
        settings.gatewayProvider = "openrouter"
        try await conversation.switchModel("gpt-5.5", provider: nil)
        #expect(settings.gatewayModel == "gpt-5.5")
        #expect(settings.gatewayProvider.isEmpty)
    }
}
