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
            PangolinSettings()
            CustomHeadersSettings()
            FastLaneSettings(saved: $saved)
        }
        .navigationTitle("Connection details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A secret's field with its Save/Remove row. The typed value lives here and is cleared on
/// save; whether one is stored belongs to the caller, which gates other sections on it.
struct SecretField: View {
    let item: Keychain.Item
    let prompt: String
    let replacePrompt: String
    var saveTitle = String(localized: "Save")
    var removeTitle = String(localized: "Remove")
    /// Optional secrets show the buttons only once something is typed or stored.
    var optional = false
    @Binding var hasValue: Bool
    var onSaved: () -> Void = {}
    var onRemoved: () -> Void = {}
    /// What is stored for what was typed, or nil to refuse it with `refusal`. Stored as typed without.
    var accept: ((String) -> String?)?
    var refusal = ""
    @State private var text = ""
    @State private var refused = false

    var body: some View {
        SecureField(hasValue ? replacePrompt : prompt, text: $text)
            .onSubmit(save)
            .onChange(of: text) { refused = false }
        if refused {
            Text(refusal).font(.footnote).foregroundStyle(.red)
        }
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
        let value = accept.map { $0(text) } ?? text
        guard let value else { refused = true; return }
        guard Keychain.write(item, value: value) else { return }
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
            SecretField(item: .gatewayAPIKey, prompt: String(localized: "API key"), replacePrompt: String(localized: "Replace stored API key"),
                        saveTitle: String(localized: "Save key"), removeTitle: String(localized: "Remove key"), hasValue: $hasStoredKey,
                        onSaved: { saved.toggle() })
        } header: {
            Text("Hermes API")
        } footer: {
            // The watch is handed this connection whatever the phone itself uses: it can't open
            // the Dashboard's WebSocket, and without this it asks through the phone (`WatchLink.connection`).
            hasStoredKey
                ? Text("A key is stored in the Keychain. It is never shown again. Redde on Apple Watch asks through this connection and keeps its own copy of the key.")
                : Text("Paste the scoped API_SERVER_KEY. It is stored in the Keychain only. With it, Redde on Apple Watch asks on its own; without it, the watch asks through this iPhone, which has to be in reach.")
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
                    Text(signedInName.isEmpty ? String(localized: "through a browser", comment: "Signed in: through a browser, with no name to show")
                                              : signedInName).foregroundStyle(.secondary)
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
                SecretField(item: .serveDashboardPassword, prompt: String(localized: "Dashboard password"),
                            replacePrompt: String(localized: "Replace stored password"),
                            saveTitle: String(localized: "Save password"), hasValue: $hasServePassword,
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
        case .disconnected: String(localized: "not connected", comment: "The Dashboard connection's state")
        case .connecting: String(localized: "connecting…", comment: "The Dashboard connection's state")
        case .connected: String(localized: "connected", comment: "The Dashboard connection's state")
        case let .reconnecting(attempt): String(localized: "reconnecting (try \(attempt))…", comment: "The Dashboard connection's state, with the attempt's number")
        case let .failed(reason): String(localized: "failed: \(reason)", comment: "The Dashboard connection's state, with why")
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
                working ? Text("Signing in…") : Text("Sign in with a browser")
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
            SecretField(item: .cfAccessClientSecret, prompt: String(localized: "Client secret"),
                        replacePrompt: String(localized: "Replace stored client secret"),
                        saveTitle: String(localized: "Save secret"), optional: true, hasValue: $hasSecret,
                        onSaved: { HermesServeClient.shared.disconnect() }, onRemoved: { HermesServeClient.shared.disconnect() })
        } header: {
            Text("Cloudflare Access (optional)")
        } footer: {
            Text("If the Hermes Dashboard sits behind Cloudflare Access instead of a tailnet, create a service token in Zero Trust and paste its ID and secret. Sent as CF-Access-Client-Id / -Secret on every request and WebSocket.")
        }
        .task { hasSecret = Keychain.read(.cfAccessClientSecret) != nil }
    }
}

/// Pangolin (pangolin.net) in front of the Dashboard or the Hermes API: a Link's access token for
/// each resource, sent as its two headers on every request (`Settings.pangolinHeaders`). A Link
/// opens one resource; when only one token is given it is sent to both, for a Dashboard and API
/// behind the one resource. (Its header authentication, a Basic `Authorization` header, goes in
/// Custom headers for the Dashboard; on the Hermes API that header carries the key.)
struct PangolinSettings: View {
    @State private var hasDashboard = false
    @State private var hasAPI = false

    var body: some View {
        Section {
            field(.pangolinDashboard, String(localized: "Dashboard access token"),
                  replace: String(localized: "Replace stored dashboard access token"), has: $hasDashboard)
            field(.pangolinAPI, String(localized: "Hermes API access token"),
                  replace: String(localized: "Replace stored hermes api access token"), has: $hasAPI)
        } header: {
            Text("Pangolin (optional)")
        } footer: {
            Text("If the Dashboard or the Hermes API sits behind Pangolin, make a Link to its resource and paste its access token here: the token ID and token as id.token, or the link that has p_token= in it. Sent as P-Access-Token-Id / P-Access-Token on every request and WebSocket. One token is used for both when the other is empty. Treat it like a password.")
        }
        .task {
            hasDashboard = Keychain.read(.pangolinDashboard) != nil
            hasAPI = Keychain.read(.pangolinAPI) != nil
        }
    }

    private func field(_ item: Keychain.Item, _ prompt: String, replace: String, has: Binding<Bool>) -> some View {
        SecretField(item: item, prompt: prompt, replacePrompt: replace, saveTitle: String(localized: "Save token"),
                    optional: true, hasValue: has,
                    onSaved: { HermesServeClient.shared.disconnect() }, onRemoved: { HermesServeClient.shared.disconnect() },
                    accept: Settings.pangolinToken,
                    refusal: String(localized: "That isn't a Pangolin access token. Paste the token ID and token as id.token, or the Link with p_token= in it."))
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
        problem = CustomHeader.problem(withName: new.name) ?? (new.value.isEmpty ? String(localized: "Give the header a value.") : nil)
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
            SecretField(item: .fastLaneAPIKey, prompt: String(localized: "API key (optional)"), replacePrompt: String(localized: "Replace stored API key"),
                        saveTitle: String(localized: "Save key"), removeTitle: String(localized: "Remove key"), optional: true, hasValue: $hasKey,
                        onSaved: { saved.toggle() })
        } header: {
            Text("OpenAI-compatible (direct to a model)")
        } footer: {
            Text("Any OpenAI-compatible endpoint, with no agent in between: llama.cpp, llama-swap, vLLM, Ollama, or a hosted provider. No tools or memory, lowest latency.")
        }
        .task { hasKey = Keychain.read(.fastLaneAPIKey) != nil }
    }
}
