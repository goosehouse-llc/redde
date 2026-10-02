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

    // MARK: - A saved provider against the backend's current list

    private func choice(_ provider: String, _ model: String) -> ModelChoice {
        ModelChoice(provider: provider, providerName: provider, model: model, name: model, isCurrent: false)
    }

    @Test func aListedProviderIsKept() {
        let choices = [choice("custom:local", "gemma4-26b-a4b"), choice("custom:local", "qwen36-splash"), choice("custom:other", "qwen36-splash")]
        #expect(Conversation.liveProvider(for: "qwen36-splash", saved: "custom:other", in: choices) == "custom:other")
    }

    /// The reported failure: the rule still named a provider the host no longer has, and the
    /// turn died with "Unknown provider".
    @Test func aRenamedProviderFollowsTheModel() {
        let choices = [choice("custom:local", "gemma4-26b-a4b"), choice("custom:local", "qwen36-splash")]
        #expect(Conversation.liveProvider(for: "qwen36-splash", saved: "custom:gemma-4-26b-a4b-vision", in: choices) == "custom:local")
    }

    /// The host removed the rule's provider and no longer lists its model, which the endpoint
    /// still serves: the host's current provider takes it.
    @Test func anUnknownProviderAndModelGoToTheCurrentProvider() {
        var current = choice("custom:local", "qwen36-splash")
        current.isCurrent = true
        #expect(Conversation.liveProvider(for: "qwen36-35b-q4", saved: "custom:gone", in: [choice("anthropic", "claude-opus-5-5"), current]) == "custom:local")
        #expect(Conversation.liveProvider(for: "qwen36-35b-q4", saved: "custom:gone", in: [choice("custom:local", "qwen36-splash")]) == nil)
    }

    @Test func aNamedEndpointBeatsTheBareBucket() {
        let choices = [choice("custom", "qwen36-splash"), choice("custom:local", "qwen36-splash")]
        #expect(Conversation.liveProvider(for: "qwen36-splash", saved: "custom:gone", in: choices) == "custom:local")
        #expect(Conversation.liveProvider(for: "qwen36-splash", saved: "custom:gone", in: [choices[0]]) == "custom")
    }

    /// A live Dashboard switch is a `/model` line: a bare name is re-resolved under the session's
    /// bare "custom" provider and ends up at OpenRouter with no key.
    @Test func aLiveDashboardSwitchNamesItsProvider() {
        #expect(HermesServeClient.modelSwitchValue(model: "qwen36-35b-q4", provider: "custom:local") == "qwen36-35b-q4 --provider custom:local")
        #expect(HermesServeClient.modelSwitchValue(model: "qwen36-35b-q4", provider: nil) == "qwen36-35b-q4")
        #expect(HermesServeClient.modelSwitchValue(model: "qwen36-35b-q4", provider: "") == "qwen36-35b-q4")
    }

    @Test func aHiddenModelKeepsItsListedProvider() {
        let choices = [choice("custom:local", "gemma4-26b-a4b")]
        #expect(Conversation.liveProvider(for: "qwen3-4b", saved: "custom:local", in: choices) == "custom:local")
    }

    @Test func nothingChangesWithoutAList() {
        #expect(Conversation.liveProvider(for: "qwen36-splash", saved: "custom:gone", in: []) == "custom:gone")
        #expect(Conversation.liveProvider(for: "qwen36-splash", saved: nil, in: []) == nil)
    }

    /// A pick with no provider (a rule made on the fast lane) would go to the default endpoint,
    /// which may not serve the model: the provider that lists it takes it.
    @Test func aPickWithoutAProviderFindsOne() {
        var current = choice("custom:box-a", "alpha")
        current.isCurrent = true
        let choices = [current, choice("custom:box-b", "gamma")]
        #expect(Conversation.liveProvider(for: "gamma", saved: nil, in: choices) == "custom:box-b")
        #expect(Conversation.liveProvider(for: "gamma", saved: "", in: choices) == "custom:box-b")
        #expect(Conversation.liveProvider(for: "unlisted", saved: nil, in: choices) == "custom:box-a")
    }

    /// A leftover `providers: custom:` block lists models under a bare "custom" row that has no
    /// endpoint; picked, it fails with "Unknown provider 'custom:custom'". A host whose only
    /// endpoint *is* the bare bucket marks it current, and keeps it.
    @Test func theBareBucketYieldsToANamedEndpointUnlessItIsCurrent() {
        var named = choice("custom:my-local", "alpha")
        named.isCurrent = true
        #expect(Conversation.liveProvider(for: "alpha", saved: "custom", in: [choice("custom", "alpha"), named]) == "custom:my-local")
        var bare = choice("custom", "alpha")
        bare.isCurrent = true
        #expect(Conversation.liveProvider(for: "alpha", saved: "custom", in: [bare, choice("custom", "beta")]) == "custom")
        #expect(Conversation.liveProvider(for: "beta", saved: "custom", in: [bare, choice("custom", "beta")]) == "custom")
        #expect(Conversation.liveProvider(for: "alpha", saved: "custom", in: [choice("custom", "alpha")]) == "custom")
    }
}
