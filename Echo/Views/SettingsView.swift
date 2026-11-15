import SwiftUI

/// Settings: the name, and three groups of rows on the first screen, each opening a page of its
/// own (`SettingsPage`): the connection, your agent, and the app (reorganised 2026-11-15: "a bit
/// difficult to find what I'm looking for"). It was one form of fourteen sections, every row of it
/// built as the sheet came up: half a second, the slowest thing in the app (2026-10-21). Each
/// section is its own view, and each page is built when it is opened, so typing in one field
/// re-evaluates that section rather than the whole form. The two Keychain flags several sections
/// gate on live here.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showSetup = false
    /// Whether a Hermes API key or a Dashboard login is there (`SettingsAccess`).
    @State private var access = SettingsAccess()
    /// Toggled whenever a secret is saved; drives the success haptic.
    @State private var secretSaved = false
    /// The page open over the first screen, if any.
    @State private var path: [SettingsPage] = []
    #if DEBUG
    /// `-echo.settingsAnchor plugins|catalog|tools` (`PluginsDemo`).
    @State private var demoPage: String?
    #endif

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
                ConnectionGroup()
                ModelSettings()
                AgentGroup()
                Section {
                    ForEach(SettingsPage.appPages) { page in
                        NavigationLink(value: page) { Label(page.title, systemImage: page.symbol) }
                    }
                } header: {
                    Text("The App", comment: "Settings: header of the group of pages about the app itself (General, Appearance, Chat List, Voice…)")
                }
                AboutSettings()
            }
            #if DEBUG
            // Dev hooks: `-echo.settingsAnchor` opens Agent on the context and memory files,
            // `-echo.settingsAnchor icloud` General on Sync with iCloud and `-echo.settingsAnchor
            // plugin` scrolls to the Redde Plugin row, `voice` opens Voice, `appearance` Appearance with its
            // colors open (`fonts` with its Font list open), `day` Your Day, `location` or `leaveBy` Location,
            // and any other page by its `SettingsPage` name; `-echo.expandAppIcons` opens Appearance on
            // the app icons (screenshots).
            .task {
                if DevHooks.expandAppIcons { path = [.appearance] }
                guard DevHooks.settingsAnchor else { return }
                try? await Task.sleep(for: .milliseconds(600))
                let anchor = DevHooks.value("-echo.settingsAnchor") ?? ""
                if ["plugins", "catalog", "tools", "mcp"].contains(anchor) {
                    demoPage = anchor
                } else if anchor == "plugin" {
                    proxy.scrollTo(anchor, anchor: .center)
                } else if anchor == "icloud" {
                    path = [.general]
                } else if anchor == "voice" {
                    path = [.voice]
                } else if ["appearance", "fonts"].contains(anchor) {
                    path = [.appearance]
                } else if anchor == "day" {
                    path = [.day]
                } else if ["location", "leaveBy"].contains(anchor) {
                    path = [.location]
                } else if let page = SettingsPage(rawValue: anchor), page.isOffered {
                    // Any other page by its name: `connection`, `general`, `chatList`, `carPlay`…
                    path = [page]
                } else {
                    path = [.agent]
                }
            }
            #endif
            }
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                // The pages that were already screens of their own, with their own forms.
                case .email: MailSettingsView()
                case .phoneTools: PhoneToolsSettingsView()
                case .calendars: CalendarsSettingsView()
                case .location: LocationSettingsView()
                case .chatList: ChatListCardsSettingsView()
                default: SettingsPageForm(page: page) { pageContent(page) }
                }
            }
            .sheet(isPresented: $showSetup) { SetupView() }
            #if DEBUG
            .sheet(isPresented: Binding(get: { demoPage != nil }, set: { if !$0 { demoPage = nil } })) {
                if let demoPage { PluginsDemo.Screen(page: demoPage) }
            }
            #endif
            // Keychain reads once when the screen appears, not per parent render.
            .task { await access.check() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            #endif
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
        case .connection: ConnectionSettingsPage(access: access, saved: $secretSaved, showSetup: $showSetup)
        case .agent: AgentSettingsPage(access: access, saved: $secretSaved)
        case .day: YourDaySettingsPage(access: access)
        // Erasing closes Settings, not only the page it is on.
        case .general: GeneralSettings(closeSettings: { dismiss() })
        case .appearance: AppearanceSettings()
        case .writing: ComposerSettings()
        case .voice: VoiceSettings()
        case .notifications: NotificationSettings()
        case .carPlay:
            #if os(iOS)
            CarPlaySettings()
            #else
            EmptyView()
            #endif
        case .siri: if #available(iOS 27.0, macOS 27.0, *) { SiriSettings() }
        // Their own screens (`navigationDestination`).
        case .email, .phoneTools, .calendars, .location, .chatList: EmptyView()
        }
    }
}

/// A page of Settings, opened from a row of the first screen.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    // The connection group.
    case connection
    // Your agent: what it knows and does, and what of this device it may use.
    case agent, day, email, phoneTools, calendars, location
    // The app itself.
    case general, appearance, chatList, writing, voice, notifications, carPlay, siri

    var id: String { rawValue }

    /// The Your Agent group's pages, in order (the Redde Plugin row sits after Agent).
    static let agentPages: [SettingsPage] = [.agent, .day, .email, .phoneTools, .calendars, .location]

    /// The app group's pages this device has: CarPlay's needs an iPhone, Siri's iOS 27.
    static var appPages: [SettingsPage] {
        [.general, .appearance, .chatList, .writing, .voice, .notifications, .carPlay, .siri].filter(\.isOffered)
    }

    var isOffered: Bool {
        switch self {
        case .carPlay:
            #if os(iOS)
            // An iPad has no CarPlay.
            return UIDevice.current.userInterfaceIdiom == .phone
            #else
            return false
            #endif
        case .siri:
            if #available(iOS 27.0, macOS 27.0, *) { return true }
            return false
        default:
            return true
        }
    }

    var title: String {
        switch self {
        case .connection: String(localized: "Connection", comment: "Settings page: the kind of connection, setting one up, and every connection's URLs, keys and logins")
        case .agent: String(localized: "Agent", comment: "Settings page: the agent's skills, tools and files")
        case .day: String(localized: "Your Day", comment: "Settings page: what the agent does on its own through the day: daily jobs, goals, watches, approvals")
        case .email: String(localized: "Email", comment: "Settings › Email: title")
        case .phoneTools: String(localized: "Phone Tools")
        case .calendars: String(localized: "Calendars")
        case .location: String(localized: "Location", comment: "Settings › Location: title")
        case .general: String(localized: "General", comment: "Settings page: where Redde opens, Sync with iCloud, the lock, and erasing everything")
        case .appearance: String(localized: "Appearance")
        case .chatList: String(localized: "Chat List", comment: "Settings page: what the chat list shows: bots, projects, the cards and Today tiles above the conversations")
        case .writing: String(localized: "Replies & Writing", comment: "Settings page: suggested replies, cards and link previews in replies, and the Return key")
        case .voice: String(localized: "Voice")
        case .notifications: String(localized: "Notifications")
        case .carPlay: String(localized: "CarPlay")
        case .siri: String(localized: "Siri")
        }
    }

    var symbol: String {
        switch self {
        case .connection: "network"
        case .agent: "brain.head.profile"
        case .day: "sunrise"
        case .email: "envelope"
        case .phoneTools: "iphone.gen3"
        case .calendars: "calendar"
        case .location: "location"
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .chatList: "list.bullet.below.rectangle"
        case .writing: "keyboard"
        case .voice: "waveform"
        case .notifications: "bell.badge"
        case .carPlay: "car"
        case .siri: "sparkles"
        }
    }
}

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

/// Settings → Connection: the kind of connection, setting one up, every connection's URLs, keys
/// and logins, and the context window for the "ctx %" figure. Its row on the first screen says
/// which connection is in use.
private struct ConnectionSettingsPage: View {
    let access: SettingsAccess
    @Binding var saved: Bool
    @Binding var showSetup: Bool

    var body: some View {
        @Bindable var access = access
        TransportSettings(showSetup: $showSetup)
        Section {
            NavigationLink {
                ConnectionDetailsView(hasStoredKey: $access.hasStoredKey,
                                      hasServePassword: $access.hasServePassword, saved: $saved)
            } label: { Label("Connection details", systemImage: "key") }
        } footer: {
            Text("URLs, keys and logins for every connection, including ones you aren't using right now. The Hermes Dashboard login also unlocks the context and memory files, and files the agent sends, while you chat over the Hermes API.")
        }
        MetricsSettings()
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

/// Settings → Your Day (2.4 tidy, 2026-11-05): what the agent does on its own, moved off Agent.
private struct YourDaySettingsPage: View {
    let access: SettingsAccess

    var body: some View {
        YourDaySettings(canReachGateway: access.hasStoredKey || access.hasServePassword)
            .task { await access.check() }
    }
}

/// A page's form, titled; on Agent and General, the dev hooks that scroll to the context and
/// memory files and to Sync with iCloud.
private struct SettingsPageForm<Content: View>: View {
    let page: SettingsPage
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            Form { content() }
                #if DEBUG
                .task {
                    guard DevHooks.settingsAnchor else { return }
                    if page == .agent {
                        try? await Task.sleep(for: .milliseconds(500))
                        proxy.scrollTo("agentFiles", anchor: .top)
                    } else if page == .general, DevHooks.value("-echo.settingsAnchor") == "icloud" {
                        try? await Task.sleep(for: .milliseconds(500))
                        proxy.scrollTo("icloud", anchor: .top)
                    }
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
