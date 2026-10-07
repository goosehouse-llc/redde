import AuthenticationServices
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
            CustomHeadersSettings()
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
            // The watch is handed this connection whatever the phone itself uses: it can't open
            // the Dashboard's WebSocket, and without this it asks through the phone (`WatchLink.connection`).
            Text(hasStoredKey
                ? "A key is stored in the Keychain. It is never shown again. Redde on Apple Watch asks through this connection and keeps its own copy of the key."
                : "Paste the scoped API_SERVER_KEY. It is stored in the Keychain only. With it, Redde on Apple Watch asks on its own; without it, the watch asks through this iPhone, which has to be in reach.")
        }
    }
}

struct ServeLoginSettings: View {
    /// A Dashboard login is stored: a password, or a browser sign-in.
    @Binding var hasServePassword: Bool
    @Binding var saved: Bool
    @State private var settings = Settings.shared
    @State private var serve = HermesServeClient.shared
    @State private var signedIn = false
    @State private var signedInName = ""

    var body: some View {
        Section {
            TextField("http://your-redde:9119", text: $settings.serveURL)
                .urlFieldStyle()
            if signedIn {
                LabeledContent("Signed in") {
                    Text(signedInName.isEmpty ? "through a browser" : signedInName).foregroundStyle(.secondary)
                }
                Button("Sign out", role: .destructive) {
                    serve.signOut()
                    readSignIn()
                    hasServePassword = Keychain.read(.serveDashboardPassword) != nil
                }
            } else {
                TextField("Dashboard username", text: $settings.serveUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecretField(item: .serveDashboardPassword, prompt: "Dashboard password", replacePrompt: "Replace stored password",
                            saveTitle: "Save password", hasValue: $hasServePassword,
                            onSaved: { saved.toggle(); serve.disconnect() }, onRemoved: { serve.disconnect() })
                BrowserSignInButton { readSignIn(); hasServePassword = true; saved.toggle() }
            }
            LabeledContent("Connection") {
                Text(stateLabel).foregroundStyle(.secondary)
            }
        } header: {
            Text("Hermes Dashboard (WebSocket)")
        } footer: {
            Text("The same login as the Hermes Dashboard: its username and password, or, where it signs you in with Google or another provider, Sign in with a browser. Gives live reasoning, tool approvals and slash commands over one WebSocket.")
        }
        // Keyed on the server and its address: another one has its own sign-in, and a sign-in
        // isn't used at an address it wasn't made at.
        .task(id: settings.connectionKey + settings.serveURL) { readSignIn() }
    }

    private func readSignIn() {
        signedIn = serve.isSignedIn
        signedInName = ""
        guard signedIn else { return }
        Task { signedInName = (try? await serve.signedInName()) ?? "" }
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

/// "Sign in with a browser": for a Dashboard that signs people in with Google or another identity
/// provider and so has no password to type here (`HermesServeClient.signIn`). The page opens in a
/// system sign-in sheet, where the browser's saved logins and passkeys work.
struct BrowserSignInButton: View {
    var onSignedIn: () -> Void
    @State private var settings = Settings.shared
    @State private var working = false
    @State private var problem: String?
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        Button {
            Task { await signIn() }
        } label: {
            HStack {
                Text(working ? "Signing in…" : "Sign in with a browser")
                Spacer()
                if working { ProgressView() }
            }
        }
        .disabled(working || settings.serveBaseURL == nil)
        if let problem {
            Label(problem, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.footnote)
        }
    }

    private func signIn() async {
        working = true
        problem = nil
        defer { working = false }
        // The first page load carries the server's own headers (Cloudflare Access lets a service
        // token through on that one and remembers it with a cookie).
        let headers = settings.accessHeaders
        do {
            try await HermesServeClient.shared.signIn { url in
                _ = try await webAuthenticationSession.authenticate(
                    using: url, callback: .customScheme(DashboardSignIn.doneScheme), additionalHeaderFields: headers)
            }
            onSignedIn()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // Closed by hand: nothing to report.
        } catch is CancellationError {
        } catch {
            problem = error.localizedDescription
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

/// The person's own headers for a server behind a reverse proxy that asks for one (`CustomHeader`).
/// A value is a secret: it is typed once and never shown again, like a key.
struct CustomHeadersSettings: View {
    @State private var settings = Settings.shared
    @State private var headers: [CustomHeader] = []
    @State private var name = ""
    @State private var value = ""
    @State private var problem: String?

    var body: some View {
        Section {
            ForEach(headers) { header in
                HStack {
                    Text(header.name)
                    Spacer()
                    Button("Remove", role: .destructive) { save(headers.filter { $0.id != header.id }) }
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
            }
            TextField("Header name", text: $name)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Value", text: $value)
                .onSubmit(add)
            if !name.isEmpty || !value.isEmpty {
                Button("Add header", action: add)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || value.trimmingCharacters(in: .whitespaces).isEmpty)
                    .font(.callout)
            }
            if let problem {
                Label(problem, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        } header: {
            Text("Custom headers (optional)")
        } footer: {
            Text("If a reverse proxy in front of your Hermes server asks for a header of its own, add it here. It is sent with every request to this server's Dashboard and Hermes API, the WebSocket and Apple Watch included, and kept in the Keychain. Redde's own headers, such as the API key, take precedence.")
        }
        // Keyed on the server: each has its own.
        .task(id: settings.activeServerID) { headers = settings.customHeaders }
    }

    private func add() {
        let new = CustomHeader(name: name, value: value)
        problem = CustomHeader.problem(withName: new.name) ?? (new.value.isEmpty ? "Give the header a value." : nil)
        guard problem == nil else { return }
        save(CustomHeader.adding(new, to: headers))
        name = ""
        value = ""
    }

    private func save(_ new: [CustomHeader]) {
        settings.customHeaders = new
        headers = settings.customHeaders
        // The next request rebuilds the Dashboard link with them, and the watch hears of them.
        HermesServeClient.shared.disconnect()
        WatchLink.shared.push()
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
