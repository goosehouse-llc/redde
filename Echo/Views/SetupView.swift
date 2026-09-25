import SwiftUI

/// First run: pick how Echo reaches your assistant, enter the details, prove the connection.
/// Reused from Settings as "Set up connection". Nothing here is prefilled in shipped builds.
struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = Settings.shared
    // Secrets are never read back into the form; typed values are written, blanks leave the
    // stored value alone.
    @State private var apiKey = ""
    @State private var servePassword = ""
    @State private var fastLaneKey = ""
    @State private var hasAPIKey = false
    @State private var hasServePassword = false
    @State private var hasFastLaneKey = false
    @State private var testing = false
    @State private var outcome: ConnectionTester.Outcome?
    var onDone: () -> Void = {}

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        ReddeMark()
                            .frame(width: 76, height: 76)
                            .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
                            .accessibilityHidden(true)
                        VStack(spacing: 4) {
                            Text("Welcome to Redde")
                                .font(.title2.bold())
                            Text("Talk to your own AI agent by voice or chat.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                    .listRowBackground(Color.clear)
                }

                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        SetupFeature(symbol: "server.rack", title: "Your own server",
                                     detail: "Works with Hermes, the open-source agent you run on your own machine, or any OpenAI-compatible model server.")
                        SetupFeature(symbol: "lock.shield", title: "Private by design",
                                     detail: "Nothing is sent anywhere except the server you enter below.")
                        SetupFeature(symbol: "waveform", title: "Speech stays on device",
                                     detail: "Your voice is recognized on this device, not in the cloud.")
                    }
                    .padding(.vertical, 6)
                }

                Section("How does Redde reach it?") {
                    Picker("Backend", selection: $settings.transport) {
                        ForEach(Transport.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .onChange(of: settings.transport) { outcome = nil }
                }

                switch settings.transport {
                case .hermesSessions:
                    Section {
                        TextField("https://your-gateway:8642", text: $settings.gatewayURL).urlFieldStyle()
                        SecureField(hasAPIKey ? "Replace stored API key" : "API key", text: $apiKey)
                    } header: {
                        Text("Redde API server")
                    } footer: {
                        Text("The gateway's API server and its API_SERVER_KEY. Sessions from every platform appear in Redde.")
                    }
                case .hermesServe:
                    Section {
                        TextField("http://your-redde:9119", text: $settings.serveURL).urlFieldStyle()
                        TextField("Dashboard username", text: $settings.serveUsername)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField(hasServePassword ? "Replace stored password" : "Dashboard password", text: $servePassword)
                    } header: {
                        Text("Redde serve")
                    } footer: {
                        Text("The same login as the Redde dashboard. Adds tool approvals and slash commands.")
                    }
                case .chatCompletions:
                    Section {
                        TextField("http://your-server:8080", text: $settings.fastLaneURL).urlFieldStyle()
                        SecureField(hasFastLaneKey ? "Replace stored API key" : "API key (if the endpoint needs one)", text: $fastLaneKey)
                        TextField("Model name", text: $settings.fastLaneModel)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: {
                        Text("OpenAI-compatible endpoint")
                    } footer: {
                        Text("Straight to a model with no agent in between: llama.cpp, llama-swap, vLLM, Ollama, or a hosted provider.")
                    }
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text(testing ? "Testing…" : "Test connection")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(testing || !fieldsFilled)
                    if let outcome {
                        Label(outcome.message, systemImage: outcome.isOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(outcome.isOK ? .green : .red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Set up Redde")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { finish() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish() }
                        .disabled(!(outcome?.isOK ?? false))
                }
            }
            .interactiveDismissDisabled()
            .task {
                // Re-running setup from Settings: a stored secret counts as filled in.
                hasAPIKey = Keychain.read(.gatewayAPIKey) != nil
                hasServePassword = Keychain.read(.serveDashboardPassword) != nil
                hasFastLaneKey = Keychain.read(.fastLaneAPIKey) != nil
            }
        }
    }

    private var fieldsFilled: Bool {
        switch settings.transport {
        case .hermesSessions: settings.gatewayBaseURL != nil && (!apiKey.isEmpty || hasAPIKey)
        case .hermesServe: settings.serveBaseURL != nil && !settings.serveUsername.isEmpty && (!servePassword.isEmpty || hasServePassword)
        case .chatCompletions: settings.activeBaseURL != nil
        }
    }

    private func persistSecrets() {
        if !apiKey.isEmpty, Keychain.write(.gatewayAPIKey, value: apiKey) { hasAPIKey = true }
        if !servePassword.isEmpty, Keychain.write(.serveDashboardPassword, value: servePassword) { hasServePassword = true }
        if !fastLaneKey.isEmpty, Keychain.write(.fastLaneAPIKey, value: fastLaneKey) { hasFastLaneKey = true }
        HermesServeClient.shared.disconnect()
    }

    private func test() async {
        persistSecrets()
        testing = true
        defer { testing = false }
        switch settings.transport {
        case .hermesSessions:
            guard let url = settings.gatewayBaseURL else { outcome = .failed("Enter a valid URL."); return }
            outcome = await ConnectionTester.hermesAPI(url: url, apiKey: apiKey.isEmpty ? Keychain.read(.gatewayAPIKey) : apiKey)
        case .hermesServe:
            guard let url = settings.serveBaseURL else { outcome = .failed("Enter a valid URL."); return }
            outcome = await ConnectionTester.hermesServe(url: url)
        case .chatCompletions:
            guard let url = settings.activeBaseURL else { outcome = .failed("Enter a valid URL."); return }
            outcome = await ConnectionTester.fastLane(url: url, apiKey: fastLaneKey.isEmpty ? Keychain.read(.fastLaneAPIKey) : fastLaneKey, model: settings.fastLaneModel)
        }
    }

    private func finish() {
        persistSecrets()
        settings.setupDone = true
        onDone()
        dismiss()
    }
}

/// One line of the setup intro: a tinted symbol, a short title, a sentence of detail.
private struct SetupFeature: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The app's default icon (Graphite) at the top of the intro: the picker's copy of it,
/// with the Home Screen's rounded corners.
struct ReddeMark: View {
    var body: some View {
        Image("IconPreviews/AppIcon")
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}
