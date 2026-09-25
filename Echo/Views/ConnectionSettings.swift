import SwiftUI

/// All backend URLs, keys and logins on one subscreen, off the main settings page. Entry for
/// the active transport duplicates the setup sheet on purpose: this is also the only place to
/// store the OTHER backends' credentials (the serve login unlocks file editing and agent-sent
/// files even on the sessions transport), to remove a stored secret, and to configure
/// Cloudflare Access.
struct ConnectionDetailsView: View {
    @Binding var hasStoredKey: Bool
    @Binding var hasServePassword: Bool
    @Binding var saved: Bool

    var body: some View {
        Form {
            GatewayKeySettings(hasStoredKey: $hasStoredKey, saved: $saved)
            ServeLoginSettings(hasServePassword: $hasServePassword, saved: $saved)
            CloudflareSettings()
            FastLaneSettings(saved: $saved)
        }
        .navigationTitle("Connection details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A secret's field with its Save/Remove row. The typed value lives here and is cleared on
/// save; whether one is stored belongs to the caller, which gates other sections on it.
private struct SecretField: View {
    let item: Keychain.Item
    let prompt: String
    let replacePrompt: String
    var saveTitle = "Save"
    var removeTitle = "Remove"
    /// Optional secrets show the buttons only once something is typed or stored.
    var optional = false
    @Binding var hasValue: Bool
    var onSaved: () -> Void = {}
    var onRemoved: () -> Void = {}
    @State private var text = ""

    var body: some View {
        SecureField(hasValue ? replacePrompt : prompt, text: $text)
            .onSubmit(save)
        if !optional || !text.isEmpty || hasValue {
            HStack {
                Button(saveTitle, action: save)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                if hasValue {
                    Button(removeTitle, role: .destructive) {
                        Keychain.delete(item)
                        hasValue = false
                        onRemoved()
                    }
                }
            }
            .font(.callout)
        }
    }

    private func save() {
        guard Keychain.write(item, value: text) else { return }
        text = ""
        hasValue = true
        onSaved()
    }
}

struct GatewayKeySettings: View {
    @Binding var hasStoredKey: Bool
    @Binding var saved: Bool
    @State private var settings = Settings.shared

    var body: some View {
        Section {
            TextField("https://your-gateway:8642", text: $settings.gatewayURL)
                .urlFieldStyle()
            SecretField(item: .gatewayAPIKey, prompt: "API key", replacePrompt: "Replace stored API key",
                        saveTitle: "Save key", removeTitle: "Remove key", hasValue: $hasStoredKey,
                        onSaved: { saved.toggle() })
        } header: {
            Text("Hermes API")
        } footer: {
            Text(hasStoredKey
                ? "A key is stored in the Keychain (this device only). It is never shown again."
                : "Paste the scoped API_SERVER_KEY. It is stored in the iOS Keychain only.")
        }
    }
}

struct ServeLoginSettings: View {
    @Binding var hasServePassword: Bool
    @Binding var saved: Bool
    @State private var settings = Settings.shared
    @State private var serve = HermesServeClient.shared

    var body: some View {
        Section {
            TextField("http://your-redde:9119", text: $settings.serveURL)
                .urlFieldStyle()
            TextField("Dashboard username", text: $settings.serveUsername)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecretField(item: .serveDashboardPassword, prompt: "Dashboard password", replacePrompt: "Replace stored password",
                        saveTitle: "Save password", hasValue: $hasServePassword,
                        onSaved: { saved.toggle(); serve.disconnect() }, onRemoved: { serve.disconnect() })
            LabeledContent("Connection") {
                Text(stateLabel).foregroundStyle(.secondary)
            }
        } header: {
            Text("Hermes Dashboard (WebSocket)")
        } footer: {
            Text("The same login as the Hermes Dashboard. Gives live reasoning, tool approvals and slash commands over one WebSocket.")
        }
    }

    private var stateLabel: String {
        switch serve.state {
        case .disconnected: "not connected"
        case .connecting: "connecting…"
        case .connected: "connected"
        case let .reconnecting(attempt): "reconnecting (try \(attempt))…"
        case let .failed(reason): "failed: \(reason)"
        }
    }
}

struct CloudflareSettings: View {
    @State private var settings = Settings.shared
    @State private var hasSecret = false

    var body: some View {
        Section {
            TextField("Client ID", text: $settings.cfAccessClientID)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onChange(of: settings.cfAccessClientID) { HermesServeClient.shared.disconnect() }
            SecretField(item: .cfAccessClientSecret, prompt: "Client secret", replacePrompt: "Replace stored client secret",
                        saveTitle: "Save secret", optional: true, hasValue: $hasSecret,
                        onSaved: { HermesServeClient.shared.disconnect() }, onRemoved: { HermesServeClient.shared.disconnect() })
        } header: {
            Text("Cloudflare Access (optional)")
        } footer: {
            Text("If the Hermes Dashboard sits behind Cloudflare Access instead of a tailnet, create a service token in Zero Trust and paste its ID and secret. Sent as CF-Access-Client-Id / -Secret on every request and WebSocket.")
        }
        .task { hasSecret = Keychain.read(.cfAccessClientSecret) != nil }
    }
}

struct FastLaneSettings: View {
    @Binding var saved: Bool
    @State private var settings = Settings.shared
    @State private var hasKey = false

    var body: some View {
        Section {
            TextField("http://your-server:8080", text: $settings.fastLaneURL)
                .urlFieldStyle()
            TextField("Model", text: $settings.fastLaneModel)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecretField(item: .fastLaneAPIKey, prompt: "API key (optional)", replacePrompt: "Replace stored API key",
                        saveTitle: "Save key", removeTitle: "Remove key", optional: true, hasValue: $hasKey,
                        onSaved: { saved.toggle() })
        } header: {
            Text("OpenAI-compatible (direct to a model)")
        } footer: {
            Text("Any OpenAI-compatible endpoint, with no agent in between: llama.cpp, llama-swap, vLLM, Ollama, or a hosted provider. No tools or memory, lowest latency.")
        }
        .task { hasKey = Keychain.read(.fastLaneAPIKey) != nil }
    }
}
