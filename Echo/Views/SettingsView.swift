import SwiftUI

/// Settings: the connection and a few switches on the first screen, and the long sections on
/// pages of their own (`SettingsPage`). It was one form of fourteen sections, every row of it
/// built as the sheet came up: half a second, the slowest thing in the app (2026-10-21). Each
/// section is its own view, so typing in one field re-evaluates that section rather than the
/// whole form. The two Keychain flags several sections gate on live here.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showSetup = false
    /// Whether a Hermes API key or a Dashboard login is there (`SettingsAccess`).
    @State private var access = SettingsAccess()
    /// Toggled whenever a secret is saved; drives the success haptic.
    @State private var secretSaved = false
    /// The page open over the first screen, if any.
    @State private var path: [SettingsPage] = []

    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
            Form {
                NameSettings()
                ProfileSettings()
                TransportSettings(showSetup: $showSetup)
                ModelSettings()
                Section {
                    ForEach(SettingsPage.offered) { page in
                        NavigationLink(value: page) { Label(page.title, systemImage: page.symbol) }
                    }
                }
                Section {
                    NavigationLink {
                        ConnectionDetailsView(hasStoredKey: $access.hasStoredKey,
                                              hasServePassword: $access.hasServePassword, saved: $secretSaved)
                    } label: { Label("Connection details", systemImage: "key") }
                } footer: {
                    Text("URLs, keys and logins for every connection, including ones you aren't using right now. The Hermes Dashboard login also unlocks the context and memory files, and files the agent sends, while you chat over the Hermes API.")
                }
                // A setting of its own, not under Agent (asked 2026-10-23): it is on the server,
                // and much of Redde comes through it.
                Section {
                    ReddePluginLink()
                } footer: {
                    Text("Redde's plugin on your Hermes: cards in replies, phone tools, the widget your agent writes on and notifications when Redde is closed all come through it.")
                }
                .id("plugin")
                MetricsSettings()
                ICloudSettings()
                LockSettings()
                AboutSettings()
                ResetSettings()
            }
            #if DEBUG
            // Dev hooks: `-echo.settingsAnchor` opens Agent on the context and memory files,
            // `-echo.settingsAnchor icloud` scrolls to Sync with iCloud and `-echo.settingsAnchor
            // plugin` to the Redde Plugin row, `voice` opens Voice, `appearance` Appearance with its
            // colors open; `-echo.expandAppIcons`
            // opens Appearance on the app icons (screenshots).
            .task {
                if DevHooks.expandAppIcons { path = [.appearance] }
                guard DevHooks.settingsAnchor else { return }
                try? await Task.sleep(for: .milliseconds(600))
                if let anchor = DevHooks.value("-echo.settingsAnchor"), ["icloud", "plugin"].contains(anchor) {
                    proxy.scrollTo(anchor, anchor: anchor == "plugin" ? .center : .top)
                } else if DevHooks.value("-echo.settingsAnchor") == "voice" {
                    path = [.voice]
                } else if DevHooks.value("-echo.settingsAnchor") == "appearance" {
                    path = [.appearance]
                } else {
                    path = [.agent]
                }
            }
            #endif
            }
            .navigationDestination(for: SettingsPage.self) { page in
                SettingsPageForm(page: page) { pageContent(page) }
            }
            .sheet(isPresented: $showSetup) { SetupView() }
            // Keychain reads once when the screen appears, not per parent render.
            .task { await access.check() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sensoryFeedback(.success, trigger: secretSaved)
        }
        .holdsWakePhrases(.settings)
        // Its own light or dark, kept up as it changes here (a wallpaper, Appearance): a sheet
        // that is open keeps the one it was presented with otherwise.
        .preferredColorScheme(Settings.shared.effectiveColorScheme)
    }


    @ViewBuilder
    private func pageContent(_ page: SettingsPage) -> some View {
        switch page {
        case .appearance: AppearanceSettings()
        case .writing: ComposerSettings()
        case .voice: VoiceSettings()
        case .notifications: NotificationSettings()
        case .siri: if #available(iOS 27.0, *) { SiriSettings() }
        case .agent:
            AgentSettingsPage(access: access, saved: $secretSaved)
        }
    }
}

/// A page of Settings: what was a section of the one long form.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case appearance, writing, voice, notifications, siri, agent

    var id: String { rawValue }

    /// The pages this device has: Siri's needs iOS 27.
    static var offered: [SettingsPage] {
        if #available(iOS 27.0, *) { return allCases }
        return allCases.filter { $0 != .siri }
    }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .writing: "Writing"
        case .voice: "Voice"
        case .notifications: "Notifications"
        case .siri: "Siri"
        case .agent: "Agent"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "paintbrush"
        case .writing: "keyboard"
        case .voice: "waveform"
        case .notifications: "bell.badge"
        case .siri: "sparkles"
        case .agent: "brain.head.profile"
        }
    }
}

/// A page's form, titled; on Agent, the dev hook that shows the context and memory files.
/// Whether a Hermes API key or a Dashboard login is there to use, which Agent's rows go by: an
/// object the pages watch. Handed to a page as values, through `navigationDestination`, they stayed
/// as they were before Settings had looked, and Skills, Tools and Plugins were greyed out with the
/// login stored (2026-10-26, on Marta; `-echo.settingsAnchor agent` shows it).
@Observable
final class SettingsAccess {
    var hasStoredKey = false
    var hasServePassword = false

    func check() async {
        hasStoredKey = Keychain.read(.gatewayAPIKey) != nil
        hasServePassword = Keychain.read(.serveDashboardPassword) != nil || HermesServeClient.shared.isSignedIn
        // A Dashboard with no password on it lets the phone in all the same.
        if !hasServePassword { hasServePassword = await HermesServeClient.shared.canUse() }
    }
}

/// Settings → Agent, following `SettingsAccess` as it changes, and looking again as it opens.
private struct AgentSettingsPage: View {
    let access: SettingsAccess
    @Binding var saved: Bool

    var body: some View {
        @Bindable var access = access
        AgentSettings(canReachGateway: access.hasStoredKey || access.hasServePassword, canEditFiles: access.hasServePassword) {
            ConnectionDetailsView(hasStoredKey: $access.hasStoredKey, hasServePassword: $access.hasServePassword, saved: $saved)
        }
        .task { await access.check() }
    }
}

private struct SettingsPageForm<Content: View>: View {
    let page: SettingsPage
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            Form { content() }
                #if DEBUG
                .task {
                    guard page == .agent, DevHooks.settingsAnchor else { return }
                    try? await Task.sleep(for: .milliseconds(500))
                    proxy.scrollTo("agentFiles", anchor: .top)
                }
                #endif
        }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension View {
    func urlFieldStyle() -> some View {
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .textContentType(.URL)
    }
}
