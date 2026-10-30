import SwiftUI
import WidgetKit

struct NameSettings: View {
    @State private var settings = Settings.shared

    var body: some View {
        Section {
            TextField("Redde", text: $settings.displayName)
                .textInputAutocapitalization(.words)
        } header: {
            Text("Name")
        } footer: {
            Text("Shown in the header and the message box. Siri phrases and the Home Screen icon keep the app's real name.")
        }
    }
}

struct AppearanceSettings: View {
    @State private var settings = Settings.shared
    #if DEBUG
    @State private var showThemes = false
    @State private var showColors = DevHooks.value("-echo.settingsAnchor") == "appearance"
    #else
    @State private var showThemes = false
    @State private var showColors = false
    #endif

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $showThemes) {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(Settings.Appearance.allCases) { Text($0.label).tag($0) }
                }
                .adaptiveSegmented()
                .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
                .accessibilityLabel("Light, dark or system appearance")
                .disabled(active.palette.scheme != nil)
                if active.palette.scheme != nil {
                    Text("The wallpaper sets light or dark, so the text reads on it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Theme.allCases) { theme in
                    Button { settings.theme = theme } label: {
                        HStack(spacing: 12) {
                            ThemeSwatch(theme: settings.resolved(theme)).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(theme.label).foregroundStyle(.primary)
                                Text(theme.blurb).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if settings.theme == theme {
                                Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(settings.theme == theme ? .isSelected : [])
                }
            } label: {
                DisclosureSummary(title: String(localized: "Theme")) {
                    Text("\(settings.theme.label), \(settings.appearance.label.lowercased())")
                }
            }

            DisclosureGroup(isExpanded: $showColors) {
                ColorPicker("Accent", selection: accent, supportsOpacity: false)
                ColorPicker(active.promptPrefix != nil ? String(localized: "Your messages") : String(localized: "Your bubbles"),
                            selection: bubble, supportsOpacity: false)
                ColorPicker("Wallpaper", selection: wallpaper, supportsOpacity: false)
                if settings.themeColors[settings.theme.rawValue]?.wallpaper != nil {
                    Button("No wallpaper") { settings.themeColors[settings.theme.rawValue]?.wallpaper = nil }
                }
                if !(settings.themeColors[settings.theme.rawValue]?.isEmpty ?? true) {
                    Button("Use \(settings.theme.label)'s own colors") {
                        settings.themeColors[settings.theme.rawValue] = nil
                    }
                }
            } label: {
                DisclosureSummary(title: String(localized: "\(settings.theme.label) colors")) {
                    HStack(spacing: 4) {
                        Circle().fill(accent.wrappedValue).frame(width: 14, height: 14)
                        Circle().fill(bubble.wrappedValue).frame(width: 14, height: 14)
                        Circle().fill(wallpaper.wrappedValue).frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(.quaternary))
                    }
                    .accessibilityHidden(true)
                }
            }

            Toggle(isOn: $settings.botFaces) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bot faces")
                    Text("Off, each bot, Redde too, is its initial on a circle of its color, and voice mode shows the Bubble orb in place of a face. The bots work the same either way.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $settings.botPictures) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pictures from Hermes")
                    Text("A bot with a picture set in Hermes Desktop shows that picture instead of its face.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker(selection: $settings.eventColor) {
                ForEach(Settings.EventColor.allCases) { choice in
                    if let color = choice.color {
                        Label { Text(choice.label) } icon: { Image(systemName: "circle.fill").foregroundStyle(color) }.tag(choice)
                    } else {
                        Text(choice.label).tag(choice)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calendar Events")
                    Text("On a calendar card: each calendar in its own color, or every event in one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $settings.botColors) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bot colors in their chats")
                    Text("Your bubbles and the buttons in a bot's chat take its color, and Redde's own chats take its face's if it has one. Group chats keep the theme's.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            // What the chat list shows above the conversations (GitHub issue 32).
            if BotDirectory.reachable(settings) {
                Toggle(isOn: $settings.showBots) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bots in the chat list")
                        Text("Your server's bots and group chats, at the top of the list.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if settings.transport == .hermesServe {
                Toggle(isOn: $settings.projectsInChatList) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Projects in the chat list")
                        Text("Your Hermes projects, above the conversations. Off, their conversations are still in the list.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Picker("Chat text size", selection: $settings.chatTextSize) {
                ForEach(Array(Settings.chatTextSizes), id: \.self) { Text(ChatTextSize.label($0)).tag($0) }
            }
            .pickerStyle(.menu)
            Toggle(isOn: $settings.linkPreviews) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Link previews")
                    Text("A card with the page's title and picture under a message with a link. To make it, Redde opens the page itself, so the site sees the visit. Off, Redde only talks to your own servers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            #if os(iOS)
            AppIconSettings()
            #endif
            VoiceOrbSettings()
            #if os(iOS)
            // An iPad has no CarPlay.
            if UIDevice.current.userInterfaceIdiom == .phone {
                CarPlayCardSettings()
                CarPlayVoiceSettings()
                // The Bots tab is there with Bots on the Dashboard (or the Hermes API through its login).
                if BotDirectory.available(settings) { CarPlayBotSettings() }
            }
            #endif
        } header: {
            Text("Appearance")
        } footer: {
            if showColors {
                Text("Each theme keeps its own colors. Text on your bubbles and on accent buttons turns light or dark to stay readable.")
            } else {
                Text("“Chat text size” sets the conversation larger or smaller than the rest of the iPhone's text. It still follows the iPhone's own text size from there.")
            }
        }
    }

    private var active: ResolvedTheme { settings.resolvedTheme }

    private var accent: Binding<Color> {
        Binding {
            active.accent
        } set: {
            settings.themeColors[settings.theme.rawValue, default: ThemeColors()].accent = ThemeColors.RGB($0)
        }
    }

    /// The page behind the chat, voice mode and group chats. Its text, and light or dark, follow
    /// from it (`Theme.resolved(with:)`).
    private var wallpaper: Binding<Color> {
        Binding {
            active.pageColor
        } set: {
            settings.themeColors[settings.theme.rawValue, default: ThemeColors()].wallpaper = ThemeColors.RGB($0)
        }
    }

    /// Prompt themes (Terminal, Amber CRT) have no bubble: the pick colors your prompt line.
    private var bubble: Binding<Color> {
        Binding {
            active.promptPrefix != nil ? active.promptColor : active.userBubble
        } set: {
            settings.themeColors[settings.theme.rawValue, default: ThemeColors()].bubble = ThemeColors.RGB($0)
        }
    }
}

/// How the message field behaves.
struct ComposerSettings: View {
    @State private var settings = Settings.shared

    var body: some View {
        Section {
            Toggle("Suggest follow-up questions", isOn: $settings.suggestFollowUps)
                .disabled(Settings.normalizedBase(settings.fastLaneURL) == nil)
        } header: {
            Text("Replies")
        } footer: {
            Text("Three things you might ask next under each reply, written by the model on your OpenAI-compatible connection (it needs that address set, whichever connection the conversation uses).")
        }
        Section {
            Picker("Return key", selection: $settings.returnSends) {
                Text("New line").tag(false)
                Text("Sends").tag(true)
            }
            .pickerStyle(.menu)
        } header: {
            Text("Writing")
        } footer: {
            settings.returnSends
                ? Text("Return sends the message. On a keyboard, Shift-Return starts a new line; for a long message, the field's editor button opens a page where Return always does.")
                : Text("Return starts a new line, and the Send button sends. On a keyboard, ⌘Return sends.")
        }
    }
}

/// Which Hermes server and profile Redde talks to: near the top of Settings, since they decide
/// whose sessions, skills and memory everything below shows. Hidden on the OpenAI-compatible
/// connection.
struct ProfileSettings: View {
    @State private var settings = Settings.shared

    var body: some View {
        if settings.transport != .chatCompletions {
            Section {
                NavigationLink { ServersView() } label: {
                    LabeledContent {
                        Text(settings.activeServer?.title ?? "").foregroundStyle(.secondary).lineLimit(1)
                    } label: {
                        Label("Server", systemImage: "server.rack")
                    }
                }
                NavigationLink { ProfilePickerView() } label: {
                    LabeledContent {
                        Text(settings.profileName ?? String(localized: "Default", comment: "The Hermes server's main profile")).foregroundStyle(.secondary).lineLimit(1)
                    } label: {
                        Label("Profile", systemImage: "person.2")
                    }
                }
            } header: {
                Text("Hermes server")
            } footer: {
                Text(String(localized: "The server and agent profile Redde talks to. Chats, skills, tools, cron jobs and memory all follow them.")
                     + (BotDirectory.reachable(settings)
                        ? " " + String(localized: "Bots are your other profiles, as Hermes Desktop shows them: each has one chat of its own, listed under Bots once the server has more than one profile.")
                            + (settings.transport == .hermesSessions ? " " + String(localized: "On the Hermes API they go by the Dashboard's login.") : "")
                        : ""))
            }
        }
    }
}

struct TransportSettings: View {
    @Binding var showSetup: Bool
    @State private var settings = Settings.shared
    /// The server whose setup code is showing (the active one; its code carries the
    /// OpenAI-compatible endpoint too, so this is here for every connection).
    @State private var sharing: HermesServer?

    var body: some View {
        Section {
            Picker("Backend", selection: $settings.transport) {
                ForEach(Transport.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Button("Set up connection…", systemImage: "network") { showSetup = true }
            Button("Set up another device…", systemImage: "qrcode") { sharing = settings.activeServer }
                .sheet(item: $sharing) { SetupCodeView(server: $0) }
        } header: {
            Text("Connection")
        }
    }
}

/// The model and reasoning effort, per transport.
struct ModelSettings: View {
    @State private var settings = Settings.shared

    var body: some View {
        Section {
            NavigationLink {
                ModelPickerView()
            } label: {
                LabeledContent("Model") {
                    Text(modelSummary).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } header: {
            Text("Model")
        }
    }

    private var modelSummary: String {
        let model = settings.transport == .chatCompletions ? settings.fastLaneModel : (settings.gatewayModel.isEmpty ? String(localized: "Default", comment: "The model the gateway is set up with") : settings.gatewayModel)
        let effort = settings.reasoningEffort.isEmpty ? "" : " · \(Settings.effortLabel(settings.reasoningEffort))"
        return model + effort
    }
}

/// Settings → Agent → Current Location (`CurrentLocation`, asked 2026-10-30): the switch, and
/// under it, while on, what the agent hears, or that the device doesn't allow it, with the way to
/// Settings. Turning it on asks for the permission the first time.
struct CurrentLocationSection: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { Settings.shared.currentLocation }, set: { on in
                Settings.shared.currentLocation = on
                CurrentLocationService.shared.turned(on: on)
            })) {
                Label("Current Location", systemImage: "location")
            }
            if Settings.shared.currentLocation { status }
        } footer: {
            Text("Only when you ask about places, directions, maps or the weather does your agent hear roughly where you are, the neighborhood and town. It goes to your own server and nowhere else.")
        }
        .id("currentLocation")
    }

    @ViewBuilder private var status: some View {
        let service = CurrentLocationService.shared
        Group {
            if service.refused {
                Button(String(localized: "Redde isn't allowed your location. Open Settings…",
                              comment: "Settings → Agent → Current Location, when location is denied for Redde")) {
                    if let url = URL(string: Self.settingsLink) { openURL(url) }
                }
            } else if let kept = service.kept {
                let place = kept.words ?? String(format: "%.3f, %.3f", kept.latitude, kept.longitude)
                Label {
                    Text("Your agent hears “near \(place)”.", comment: "Settings → Agent → Current Location: the place the agent is told, e.g. near Thornton Park, Orlando, FL")
                } icon: {
                    Image(systemName: "location.fill").foregroundStyle(.tint)
                }
                .foregroundStyle(.secondary)
            } else if service.allowed || service.finding {
                Label {
                    Text("Finding where you are…", comment: "Settings → Agent → Current Location, while the first fix is found")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .onAppear { service.cameForward() }   // a fresh fix, if the last is a few minutes old
    }

    /// Location Services in the system's settings: the app's own page on the iPhone, the
    /// Location Services list on the Mac.
    private static var settingsLink: String {
        #if os(macOS)
        "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        #else
        UIApplication.openSettingsURLString
        #endif
    }
}

/// Settings → Agent → Leave-By Alerts (`LeaveBy`, asked 2026-10-30), and the Heads-Ups page under
/// Getting There: the switch; under it, while on, the way of getting about (`showsWay`) and the
/// next alert, or what the device doesn't allow, with the way to Settings. Turning it on asks for
/// what it needs (`LeaveByAlerts.turned`).
struct LeaveByAlertsSection: View {
    var showsWay = true
    @State private var mode = LeaveTime.mode()
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { Settings.shared.leaveByAlerts }, set: { on in
                Settings.shared.leaveByAlerts = on
                if on { Task { await LeaveByAlerts.shared.turned(on: true) } }
            })) {
                Label("Leave-By Alerts", systemImage: symbol)
            }
            if Settings.shared.leaveByAlerts {
                if showsWay {
                    Picker("Getting There", selection: $mode) {
                        Text("By Car").tag(LeaveTime.Mode.driving)
                        Text("By Transit").tag(LeaveTime.Mode.transit)
                        Text("On Foot").tag(LeaveTime.Mode.walking)
                        Text("Don't Work It Out").tag(LeaveTime.Mode.off)
                    }
                    .onChange(of: mode) { _, mode in
                        LeaveTime.setMode(mode)
                        LeaveByAlerts.shared.wayChanged()
                    }
                }
                status
            }
        } footer: {
            Text("Redde looks at your calendar and Apple Maps on this device and tells you when to leave, a few minutes early. Only events with a street address.")
        }
        .id("leaveByAlerts")
        .onAppear { mode = LeaveTime.mode() }   // (the Heads-Ups page's picker may have changed it)
        .task { await LeaveByAlerts.shared.check() }
    }

    private var symbol: String {
        switch mode {
        case .transit: "tram"
        case .walking: "figure.walk"
        default: "car"
        }
    }

    @ViewBuilder private var status: some View {
        let alerts = LeaveByAlerts.shared
        Group {
            if !alerts.missing.isEmpty {
                Button(String(localized: "Redde needs access to \(missing(alerts.missing)). Open Settings…",
                              comment: "Settings → Leave-By Alerts, when a permission is denied: e.g. Calendars and Location")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } else if mode == .off {
                Text("No alerts while Getting There is set to Don't Work It Out.", comment: "Settings → Leave-By Alerts, with the way of getting about set to none")
            } else if let next = alerts.next {
                Label {
                    Text("Next: \(next.title), leave by \(Self.when(next.leave))", comment: "Settings → Leave-By Alerts: the next alert, e.g. Next: Dentist, leave by 2:05 PM")
                } icon: {
                    Image(systemName: "clock").foregroundStyle(.tint)
                }
            } else if alerts.working {
                Label {
                    Text("Working out when to leave…", comment: "Settings → Leave-By Alerts, while the calendar and Apple Maps are looked at")
                } icon: {
                    ProgressView().controlSize(.small)
                }
            } else {
                Text("Nothing with a street address on your calendar in the next day and a half.", comment: "Settings → Leave-By Alerts, with no event to leave for")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    /// "Calendars, Location and Notifications", as the device's own settings name them.
    private func missing(_ missing: Set<LeaveByAlerts.Missing>) -> String {
        let names = [(LeaveByAlerts.Missing.calendar, String(localized: "Calendars")),
                     (.location, String(localized: "Location", comment: "The location permission, as the device's settings name it")),
                     (.notifications, String(localized: "Notifications"))]
        return ListFormatter.localizedString(byJoining: names.filter { missing.contains($0.0) }.map(\.1))
    }

    /// A time today ("2:05 PM"), or with its day ("Sat 8:10 AM").
    private static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// Skills, tools and the agent's context and memory files. All live on the gateway.
struct AgentSettings<Details: View>: View {
    /// An API key or a Dashboard login is stored.
    let canReachGateway: Bool
    /// The file editors need the Dashboard login specifically: the Hermes API server has no
    /// file endpoints (its capabilities report memory_write_api: false).
    let canEditFiles: Bool
    /// Where the Dashboard login is entered, linked from the locked file sections.
    @ViewBuilder let connectionDetails: () -> Details

    var body: some View {
        Section {
            NavigationLink { SkillsView() } label: { Label("Skills", systemImage: "sparkles") }
                .disabled(!canReachGateway)
        } footer: {
            Text("What Redde knows how to do. Create and edit from here; changes are live on the next turn.")
        }

        Section {
            NavigationLink { ToolsView() } label: { Label("Tools", systemImage: "wrench.and.screwdriver") }
                .disabled(!canReachGateway)
        } footer: {
            Text("Toolsets enabled on the gateway. Read through the Hermes API key or the Hermes Dashboard login, whichever is set.")
        }

        Section {
            NavigationLink { PluginsView(profile: nil, owner: String(localized: "Your agent")) } label: { Label("Plugins", systemImage: "puzzlepiece.extension") }
                .disabled(!canEditFiles)
        } footer: {
            canEditFiles ? Text("Find and install Hermes plugins from Nous Research's catalog, and switch them on and off.") : Text("Find and install Hermes plugins: needs the Hermes Dashboard login.")
        }

        Section {
            NavigationLink { KeyRequestsView() } label: { Label("Keys Asked For", systemImage: "key") }
        } footer: {
            Text("When an agent needs a key, it asks here, not in a chat. What you paste goes sealed straight into that profile's .env on your Hermes.")
        }

        Section {
            NavigationLink { DailyJobView(daily: MorningIdeas.job) } label: { Label("Morning Ideas", systemImage: "lightbulb") }
                .disabled(!canReachGateway)
            NavigationLink { DailyJobView(daily: HeadsUps.job) } label: { Label("Heads-Ups", systemImage: "bell.badge") }
                .disabled(!canReachGateway)
            NavigationLink { DailyJobView(daily: EveningWrapUp.job) } label: { Label("Evening Wrap-up", systemImage: "moon.stars") }
                .disabled(!canReachGateway)
            NavigationLink { DailyJobView(daily: WeekAhead.job) } label: { Label("Week Ahead", systemImage: "calendar") }
                .disabled(!canReachGateway)
            NavigationLink { DailyJobView(daily: RoutineSuggestions.job) } label: { Label("Routine Suggestions", systemImage: "repeat") }
                .disabled(!canReachGateway)
            NavigationLink { BriefingsList() } label: { Label("Briefings", systemImage: "doc.text") }
            #if os(iOS)
            NavigationLink { PlacesView() } label: { Label(String(localized: "places.title", defaultValue: "Places", comment: "Settings: places the iPhone notices arriving at or leaving"), systemImage: "mappin.and.ellipse") }
            if HealthDays.available {
                NavigationLink { HealthDaysView() } label: { Label("Health", systemImage: "heart.text.square") }
            }
            #endif
            NavigationLink { BeforeActingView() } label: { Label("Before Acting", systemImage: "hand.raised") }
            NavigationLink { TriggersView() } label: { Label("Triggers from Your iPhone", systemImage: "bolt.badge.clock") }
            NavigationLink { AgentActivityView() } label: { Label("Agent Activity", systemImage: "list.bullet.rectangle") }
        } header: {
            Text("Your Day")
        } footer: {
            Text("Ideas each morning, cards you take or put away with a swipe; a heads-up before events; a wrap-up each evening. Heads-ups and wrap-ups stay in Briefings, at the top of your chats. Triggers start your agent's work from your iPhone: arriving home, a time of day, a Focus.")
        }

        Section {
            NavigationLink { WatchesView() } label: { Label("Watches & Follow-ups", systemImage: "eye") }
                .disabled(!canReachGateway)
        } footer: {
            Text("Things your agent keeps an eye on and tells you only when they change, and loose ends it brings back to you when they're due.")
        }

        Section {
            NavigationLink { ApprovalHistoryView() } label: { Label("Approval History", systemImage: "checkmark.shield") }
        } footer: {
            Text("Every time your agent asked before running something, what it was, why it asked and what you answered. Kept on this device only.")
        }

        Section {
            NavigationLink { PhoneToolsSettingsView() } label: {
                LabeledContent {
                    Settings.shared.phoneTools.on ? Text("On") : Text("Off")
                } label: {
                    Label("Phone tools", systemImage: "iphone.gen3")
                }
            }
        } footer: {
            Text("Let your agent use this device's calendar, reminders, contacts, photos and a folder of files, set alarms, write on a widget, and start calls and messages, through Redde.")
        }

        // Which calendars the agent looks at and cards show (`CalendarChoice`, asked 2026-10-30).
        Section {
            NavigationLink { CalendarsSettingsView() } label: {
                LabeledContent {
                    (Settings.shared.agendaCalendars.isEmpty ? Text("All") : Text(Settings.shared.agendaCalendars.joined(separator: ", "))).lineLimit(1)
                } label: {
                    Label("Calendars", systemImage: "calendar")
                }
            }
        } footer: {
            Text("The calendars your agent looks at when you ask what's on, and the events calendar cards show.")
        }

        CurrentLocationSection()

        LeaveByAlertsSection()

        Section {
            Toggle(isOn: Binding(get: { Settings.shared.replyCards }, set: { Settings.shared.replyCards = $0 })) {
                Label("Cards in replies", systemImage: "map")
            }
            Toggle(isOn: Binding(get: { Settings.shared.addressMaps }, set: { Settings.shared.addressMaps = $0 })) {
                Label("Maps for addresses", systemImage: "mappin.and.ellipse")
            }
            Picker(selection: Binding(get: { Settings.shared.measureUnits }, set: { Settings.shared.measureUnits = $0 })) {
                Text(MeasureUnits.usesUS(.automatic) ? String(localized: "Automatic (US)") : String(localized: "Automatic (Metric)"))
                    .tag(MeasureUnits.automatic)
                Text("US (miles, °F)").tag(MeasureUnits.us)
                Text("Metric (km, °C)").tag(MeasureUnits.metric)
            } label: {
                Label("Units", systemImage: "ruler")
            }
        } footer: {
            Text("Your agent can show a map, places, the weather and the time under its reply, through Redde's Hermes plugin. The weather comes from Open-Meteo. Off, it isn't offered them, which makes every prompt a little shorter. With Maps for addresses on, a reply or a heads-up that names a street address gets a map of it, found by Apple Maps.")
        }

        Section {
            if !canEditFiles { filesLocked }
            NavigationLink {
                ContextFileEditorView(title: "SOUL.md", file: "SOUL.md",
                                      purpose: String(localized: "The agent's persona: who Redde is, how it speaks, what it values."))
            } label: { Label("SOUL.md", systemImage: "person.text.rectangle") }
            .disabled(!canEditFiles)
            NavigationLink {
                ContextFileEditorView(title: "ENVIRONMENT.md", file: "ENVIRONMENT.md",
                                      purpose: String(localized: "Standing facts about your setup: machines, services, names, conventions."))
            } label: { Label("ENVIRONMENT.md", systemImage: "server.rack") }
            .disabled(!canEditFiles)
        } header: {
            Text("Context files")
        } footer: {
            if canEditFiles { Text("Edited in place on the Hermes host through the Hermes Dashboard.") }
        }
        .id("agentFiles")

        Section {
            NavigationLink {
                ContextFileEditorView(title: "MEMORY.md", file: "memories/MEMORY.md",
                                      purpose: String(localized: "The agent's own notes: things it decided to remember across conversations. Injected into every system prompt."))
            } label: { Label("MEMORY.md", systemImage: "brain") }
            NavigationLink {
                ContextFileEditorView(title: "USER.md", file: "memories/USER.md",
                                      purpose: String(localized: "What the agent knows about you: preferences, facts, how you like answers. Also injected into every prompt."))
            } label: { Label("USER.md", systemImage: "person.crop.circle") }
        } header: {
            Text("Memory")
        } footer: {
            canEditFiles
                ? Text("The files the memory tool writes when you say “remember that…”. Edit them here to correct or prune what Redde carries into every conversation.")
                : Text("The files the memory tool writes when you say “remember that…”. Like the context files, they need the Hermes Dashboard login.")
        }
        .disabled(!canEditFiles)

        Section {
            NavigationLink { FilesView() } label: { Label("Files", systemImage: "folder") }
                .disabled(!canBrowseFiles)
        } footer: {
            canBrowseFiles
                ? Text("The folders on the Hermes host: look at files, change text ones, upload from this iPhone, make folders and delete.")
                : Text("The folders on the Hermes host: look at files, upload from this iPhone, make folders and delete. Needs the Hermes Dashboard login.")
        }

        #if os(iOS)
        Section {
            NavigationLink { TerminalSettingsView() } label: { Label("Terminal", systemImage: "apple.terminal") }
        } footer: {
            Text("A shell on your Hermes server over SSH, signed in with a key made on this iPhone. Also in a chat's More menu, in the chat's folder.")
        }
        #endif

        Section {
            NavigationLink { GatewayView() } label: { Label("Gateway", systemImage: "gearshape.2") }
                .disabled(!canAdminister)
        } footer: {
            canAdminister
                ? Text("The Hermes server itself: what it is connected to, its MCP servers and logs, and restarting or updating it.")
                : Text("The Hermes server itself: what it is connected to, its MCP servers and logs, and restarting or updating it. Needs the Hermes Dashboard login.")
        }
    }

    /// The Gateway screen is the Dashboard's own administration, so it takes that login.
    private var canAdminister: Bool {
        #if DEBUG
        if DevHooks.demoGateway { return true }
        #endif
        return canEditFiles
    }

    /// The file browser is the Dashboard's file manager, so it takes that login too.
    private var canBrowseFiles: Bool {
        #if DEBUG
        if DevHooks.demoFiles { return true }
        #endif
        return canEditFiles
    }

    /// Why the files are greyed out with only the Hermes API set up, and the way to fix it
    /// without switching connections.
    private var filesLocked: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Needs the Hermes Dashboard login", systemImage: "lock")
                .font(.subheadline.weight(.semibold))
            Text("The Hermes API can't read or edit files on your server. Keep using it for chat, and add your Dashboard login (from hermes serve) to unlock these files and your memory.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            NavigationLink { connectionDetails() } label: {
                Text("Add Dashboard login").font(.subheadline.weight(.medium))
            }
        }
        .padding(.vertical, 4)
    }
}

struct VoiceSettings: View {
    @State private var settings = Settings.shared
    /// Motion & Fitness has been refused for Redde: the nod switch went back off, and says why.
    @State private var motionRefused = false
    @Environment(\.openURL) private var openURL

    private var listeningLanguageName: String {
        SpeechLanguageView.name(settings.speechLanguage.isEmpty ? Locale.current.identifier(.bcp47) : settings.speechLanguage)
    }

    /// The footer's opening: what the chosen voice is, and where the reply's text goes for it.
    private var voiceFooter: String {
        switch settings.replyVoice {
        case .onDevice:
            String(localized: "Apple's on-device synthesizer. Zero network, fastest start.") + " "
                + String(localized: "“Voice for replies”: Match each reply picks a voice for the language each reply is written in, so a reply in Spanish gets a Spanish voice. Download more voices in the iPhone's Settings → Accessibility → Read & Speak → Voices.") + " "
        case .kokoro:
            String(localized: "Streams audio from a Kokoro-compatible TTS server and starts playing before the sentence finishes. Falls back to the on-device voice if the server is unreachable.") + " "
                + String(localized: "“Voice for replies”: Match each reply picks a voice for the language each reply is written in, so a reply in Spanish gets a Spanish voice (the built-in one when Kokoro has none for it).") + " "
        case .elevenLabs:
            String(localized: "ElevenLabs reads replies out on your own key, the one live calls with ElevenLabs use, starting before the sentence is finished, in any language. Each bot reads in an ElevenLabs voice of its own (Edit Bot → Voice), in group chats too. The reply's text goes from your iPhone to ElevenLabs, which bills your account by the character. ElevenLabs takes speeds from 0.7× to 1.2×. Falls back to the on-device voice without a key or a connection; the watch reads with its own.") + " "
        case .hermes:
            String(localized: "Your Hermes reads replies out with the voice set under tts in its config.yaml (ElevenLabs, OpenAI, Gemini, a voice running on the server, and others), through the Dashboard connection. The phone needs no voice key and no second server. The reply's text goes from your Hermes to that provider; Hermes's default, Edge, is Microsoft's online voice. “Say a test sentence” shows which one speaks. Speed and language are Hermes's settings too. Falls back to the on-device voice when the Dashboard can't speak.") + " "
        }
    }

    /// Wake Phrase's row: off, the one phrase, or how many.
    private var wakeSummary: String {
        let targets = settings.wakeListening ? settings.wakeTargets : []
        return targets.isEmpty ? String(localized: "Off") : targets.count == 1 ? targets[0].phrase : String(localized: "\(targets.count) phrases")
    }

    /// Voice mode as it is set: Redde's own, or a call.
    static func modeName(_ engine: LiveEngine?) -> String { engine.map { String(localized: "\($0.name) call") } ?? String(localized: "Listen and read aloud") }

    /// Two choices, kept apart (2026-10-26: "Conversation can be set to Redde, but the next down is
    /// kokoro, hermes, elevenlabs"): who holds voice mode, and which voice reads replies aloud.
    var body: some View {
        Section {
            NavigationLink {
                LiveVoiceSettings()
            } label: {
                LabeledContent("Voice mode") {
                    Text(Self.modeName(settings.voiceEngine.live)).lineLimit(1)
                }
            }
        } header: {
            Text("Voice mode")
        } footer: {
            Text(settings.voiceEngine.live.map { String(localized: "Voice mode is a \($0.name) call: \($0.company)'s voice talks and listens at once, and hands anything real to your agent. Bots can have their own (Edit Bot → Voice).") }
                 ?? String(localized: "Your iPhone listens, your agent answers, and the reading voice below reads the answer out. Or make voice mode a live call with GPT-Live, Gemini Live, Grok Voice or ElevenLabs. Bots can have their own (Edit Bot → Voice)."))
        }
        Section {
            Picker("Reading voice", selection: $settings.replyVoice) {
                Text("On-device").tag(Settings.ReplyVoice.onDevice)
                Text("Kokoro").tag(Settings.ReplyVoice.kokoro)
                Text("Hermes").tag(Settings.ReplyVoice.hermes)
                Text("ElevenLabs").tag(Settings.ReplyVoice.elevenLabs)
            }
            .adaptiveSegmented()
            if settings.replyVoice == .hermes {
                HermesVoiceRows()
            }
            if settings.replyVoice == .elevenLabs {
                ElevenLabsVoiceRows()
            }
            if settings.useKokoro {
                TextField("http://your-tts-server:8880", text: $settings.kokoroURL)
                    .urlFieldStyle()
                NavigationLink {
                    KokoroVoicesView()
                } label: {
                    LabeledContent("Voice") {
                        Text(settings.kokoroVoice).font(.callout.monospaced()).lineLimit(1)
                    }
                }
            }
            // Hermes's voice is the one it is set up with: no language to match, no speed to send.
            // ElevenLabs' voices speak whatever language the reply is in.
            if settings.replyVoice != .hermes {
                if settings.replyVoice != .elevenLabs {
                    Picker("Voice for replies", selection: $settings.matchReplyLanguage) {
                        Text("Match each reply").tag(true)
                        (settings.useKokoro ? Text("Always your Kokoro voice") : Text("Always \(listeningLanguageName)")).tag(false)
                    }
                    .pickerStyle(.menu)
                }
                // Applies to Kokoro and the built-in fallback voice alike.
                VStack(alignment: .leading, spacing: 2) {
                    LabeledContent("Voice speed") {
                        Text(settings.voiceSpeed.formatted(.number.precision(.fractionLength(2))) + "×").monospacedDigit()
                    }
                    Slider(value: $settings.voiceSpeed, in: 0.5...2.0, step: 0.05)
                        .accessibilityLabel("Voice speed")
                }
            }
            Toggle("Earpiece when raised to your ear", isOn: $settings.earpieceAtEar)
        } header: {
            Text("Reading voice")
        } footer: {
            Text(voiceFooter + String(localized: "It reads replies aloud in voice mode (when that isn't a call), in group chats, in the car and with Read aloud, each bot in a voice of its own unless it has its own reading voice (Edit Bot → Voice). “Earpiece” plays replies through the earpiece when the phone is at your ear, like a call; turn it off for hands-free use with the phone face down."))
        }
        Section {
            NavigationLink {
                SpeechLanguageView()
            } label: {
                LabeledContent("Listening language") {
                    Text(settings.speechLanguage.isEmpty ? String(localized: "iPhone's language") : SpeechLanguageView.name(settings.speechLanguage))
                        .lineLimit(1)
                }
            }
            NavigationLink {
                ReplyLanguageView()
            } label: {
                LabeledContent("Reply language") {
                    Text(settings.replyLanguage.isEmpty ? String(localized: "Automatic") : ReplyLanguage.displayName(settings.replyLanguage))
                        .lineLimit(1)
                }
            }
            NavigationLink {
                SpokenPrefixesView()
            } label: {
                LabeledContent("Spoken prefixes") {
                    (settings.spokenPrefixes.isEmpty ? Text("Off") : Text("\(settings.spokenPrefixes.count)"))
                        .lineLimit(1)
                }
            }
            NavigationLink {
                WakePhraseSettings()
            } label: {
                LabeledContent("Wake phrase") {
                    Text(wakeSummary).lineLimit(1)
                }
            }
        } header: {
            Text("Listening")
        } footer: {
            Text("A spoken prefix is a word you choose at the start of what you say: it adds a text prefix, switches model or goes to a bot (“Opus, review this diff”). With a wake phrase on, say “Hey” and an agent's name while Redde is open.")
        }
        Section {
            Toggle("Start voice mode in hands-free", isOn: $settings.handsFreeByDefault)
            Picker("Talk over replies", selection: $settings.talkOver) {
                Text("Off").tag(Settings.TalkOver.off)
                Text("With headphones").tag(Settings.TalkOver.headphones)
                Text("Headphones and speaker").tag(Settings.TalkOver.everywhere)
            }
            .pickerStyle(.menu)
            if settings.talkOver != .off {
                Picker("Interrupt with", selection: $settings.interruption) {
                    Text("Anything you say").tag(Settings.Interruption.speech)
                    Text("Only “stop”").tag(Settings.Interruption.stopWord)
                }
                .pickerStyle(.menu)
            }
            NavigationLink {
                StopPhrasesView()
            } label: {
                LabeledContent("Stop phrases") {
                    (settings.stopPhrases.isEmpty ? Text("Built-in") : Text("+\(settings.stopPhrases.count)"))
                        .lineLimit(1)
                }
            }
            Picker("Thinking sound", selection: Binding(
                get: { settings.thinkingSound },
                set: { choice in
                    settings.thinkingSound = choice
                    // Heard as it is chosen, like a ringtone.
                    if choice != .off { ThinkingSoundPlayer.shared.preview() }
                })) {
                Text("Off").tag(Settings.ThinkingSound.off)
                Text("In the car").tag(Settings.ThinkingSound.car)
                Text("Always").tag(Settings.ThinkingSound.always)
            }
            .pickerStyle(.menu)
            Toggle("New conversation in voice mode", isOn: $settings.newConversationForVoice)
        } header: {
            Text("Talking")
        } footer: {
            Text("“Talk over replies” lets you interrupt a spoken reply by speaking: the reply stops and what you say is your next message. With headphones it costs nothing. On the phone's speaker Redde has to cancel its own echo for as long as it speaks, so replies play at call volume, quieter than usual; that is why the speaker is a separate choice. “Interrupt with” says what counts: anything you say, or only the word “stop”, for when other people are talking nearby. “Stop phrases” adds your own ways of ending a hands-free conversation to the built-in ones; with “Only “stop””, they end a reply as well. “New conversation in voice mode” starts a fresh conversation each time you come into voice mode from Siri, the Action button, a control or opening Redde; the Talk button in a chat carries that chat on.")
        }
        Section {
            Toggle("Answer requests by voice", isOn: $settings.answerRequestsByVoice)
            if settings.answerRequestsByVoice, HeadGestures.isAvailable {
                Toggle("Nod or shake to answer", isOn: Binding(
                    get: { settings.answerRequestsByNod },
                    set: { on in
                        settings.answerRequestsByNod = on
                        motionRefused = false
                        guard on else { return }
                        // iOS asks for Motion & Fitness here, not in the middle of a conversation.
                        Task {
                            guard await !HeadGestures.shared.askToSense() else { return }
                            settings.answerRequestsByNod = false
                            motionRefused = true
                        }
                    }))
                if motionRefused {
                    Button("Allow Motion & Fitness for Redde…") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
        } header: {
            Text("Requests by voice")
        } footer: {
            Text(String(localized: "In voice mode and in the car, Redde reads out a command that waits for your approval, or a question from your agent, and takes your spoken answer: “approve” or “deny”, or the answer to the question. Anyone in earshot can answer, and what the agent wants to run is said aloud, so it is off until you turn it on. Passwords and secrets are only ever asked for on the screen.")
                + (HeadGestures.isAvailable
                    ? " " + String(localized: "“Nod or shake to answer” adds your head, with AirPods that sense movement (AirPods Pro, AirPods Max, AirPods 3 or later): once the request has been read out, nod a couple of times to approve, or shake your head to deny. iOS asks for Motion & Fitness when you turn it on; the movement is read on this device and kept nowhere.")
                    : ""))
        }
        // An iPad has no car.
        if UIDevice.current.userInterfaceIdiom == .phone {
            Section {
                Toggle(isOn: $settings.stopAndSkipInCar) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stop and Skip in the car")
                        Text("While Redde speaks in the car, say “stop” to end the reply, or “skip” to jump to its end.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Short answers in the car", isOn: $settings.shortAnswersInCar)
            } header: {
                Text("In the car")
            } footer: {
                Text("“Stop and Skip in the car” listens for two words alone while Redde speaks: “stop”, which ends the reply as a stop phrase does, and “skip”, which jumps to its end (hands-free then listens for what's next). The car's speakers sit near its microphone, so it is off until you turn it on. “Short answers in the car”: a question asked by voice while your iPhone is connected to a car asks your agent for two or three sentences and to offer the rest; say “more” and it carries on. On the Hermes Dashboard connection the request is a line added to your message, which other apps on the same server will show.")
            }
        }
        Section {
            Picker("When Redde opens", selection: $settings.launchScreen) {
                Text("Last conversation").tag(Settings.LaunchScreen.conversation)
                // The iPad keeps the list beside the chat, so there's nothing extra to open.
                if UIDevice.current.userInterfaceIdiom != .pad || settings.launchScreen == .conversations {
                    Text("Conversations").tag(Settings.LaunchScreen.conversations)
                }
                Text("Voice").tag(Settings.LaunchScreen.voice)
            }
            .pickerStyle(.menu)
            Toggle("Listen whenever Redde opens", isOn: $settings.listenOnOpen)
        } header: {
            Text("When Redde opens")
        } footer: {
            Text("Where Redde starts: your last conversation, the conversation list, or voice mode. “Listen whenever Redde opens” starts the mic as well, so “Hey Siri, open Redde” goes straight to listening.")
        }
    }
}

/// Settings → Notifications: what Redde tells you while you're elsewhere, and how. Under Voice
/// until 2026-10-26, when that page was split up ("there are a ton of voice settings now").
struct NotificationSettings: View {
    @State private var settings = Settings.shared

    var body: some View {
        Section {
            Toggle("Notify me in the background", isOn: Binding(
                get: { settings.notifyInBackground },
                set: { on in
                    if on { Task { settings.notifyInBackground = await Notifier.shared.requestAuthorization() } }
                    else { settings.notifyInBackground = false }
                }))
            Toggle("Announce on AirPods", isOn: $settings.announceOnAirPods)
                .disabled(!settings.notifyInBackground)
            Toggle("Notification sound", isOn: $settings.notificationSound)
        } footer: {
            Text("Background notifications tell you when Redde needs an approval or an answer, or when a reply finishes, while you're in another app. “Announce on AirPods” marks them time-sensitive so Siri can read them aloud through AirPods (turn on Announce Notifications for Redde in the iPhone's Settings) and so they reach you in a Focus. “Notification sound” off makes all of them silent, those from your Hermes too; they still appear.")
        }
        QuietHoursSection()
        Section {
            NavigationLink { PushSettingsView() } label: {
                LabeledContent("Notify when Redde is closed", value: PushService.shared.pairings.contains(where: \.isPaired) ? String(localized: "On") : String(localized: "Off"))
            }
        } footer: {
            Text("Background notifications stop when iOS closes Redde; with this, your Hermes sends them from then on.")
        }
        #if os(iOS)
        Section {
            NavigationLink { AgentCallsSettingsView() } label: {
                LabeledContent("Calls from Agents", value: settings.agentCalls ? String(localized: "On") : String(localized: "Off"))
            }
        } footer: {
            Text("An agent you allow rings this iPhone like a phone call when something shouldn't wait.")
        }
        #endif
        Section {
            Toggle("Live Activity while Redde works", isOn: $settings.showLiveActivity)
        } footer: {
            Text("A reply being worked on shows on the Lock Screen and in the Dynamic Island.")
        }
    }
}

/// Siri AI (iOS 27). Off by default because it is the one path where Apple's models, not
/// just your own servers, see what you ask. See README → "Siri AI".
@available(iOS 27.0, macOS 27.0, *)
struct SiriSettings: View {
    @State private var settings = Settings.shared

    var body: some View {
        Section {
            Toggle("Let Siri use Redde", isOn: $settings.siriAIEnabled)
            if settings.siriAIEnabled {
                Toggle("Drafts in a new conversation", isOn: $settings.siriDraftsInNewConversation)
            }
        } header: {
            Text("Siri")
        } footer: {
            Text(String(localized: "Lets Siri message \(settings.headerTitle) in your own words (“Hey Siri, ask \(settings.headerTitle) in Redde whether the backup ran”), read its replies, and find your conversations. Siri waits about 20 seconds and reads the reply; longer answers come back as a notification you can reply to by voice. Apple Intelligence processes what you say to Siri and can see Redde's recent conversations, so this is the one path where Apple, not only your own servers, handles your requests. Turning it off removes Redde from Spotlight. With App Lock on, only conversation titles are searchable. “Hey Siri, ask Redde” (open and listen) works either way.")
                 + (settings.siriAIEnabled
                    ? " " + String(localized: "A message Siri drafts for you waits in the message field of the conversation you have open, or, with “Drafts in a new conversation”, of a new one.")
                    : ""))
        }
    }
}

struct MetricsSettings: View {
    @State private var settings = Settings.shared

    var body: some View {
        Section {
            LabeledContent("Context window") {
                TextField("131072", value: $settings.contextWindow, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Metrics")
        } footer: {
            Text("Used for the “ctx %” figure when the backend can't report its window. A llama.cpp server reports it automatically.")
        }
    }
}

/// Sync with iCloud (`CloudSync`): this device's settings and servers, and the others'.
struct ICloudSettings: View {
    @State private var sync = CloudSync.shared

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { sync.phase == .on || sync.phase == .looking },
                set: { on in
                    if on { Task { await sync.turnOn() } } else { sync.turnOff() }
                })) {
                HStack {
                    Text("Sync with iCloud")
                    if sync.phase == .looking { ProgressView().controlSize(.small) }
                }
            }
            .disabled(sync.phase == .looking)
        } header: {
            Text("iCloud")
        } footer: {
            switch sync.phase {
            case .noAccount:
                Text("Sign in to iCloud in the Settings app first, with iCloud Drive on.")
                    .foregroundStyle(.orange)
            case .looking:
                Text("Looking in iCloud for what your other devices put there…")
            default:
                Text("Your servers with their keys and passwords, and your settings, on every iPhone, iPad and Mac signed in to your Apple Account. Keys and passwords go through iCloud Keychain, end-to-end encrypted. Which server and profile each device is on, App Lock, Siri, Phone tools, notifications and browser sign-ins stay on each device. Turn it on first where your settings are as you want them.")
            }
        }
        .id("icloud")
    }
}

struct LockSettings: View {
    @State private var settings = Settings.shared

    var body: some View {
        Section {
            Toggle("Require \(AppLock.biometryName)", isOn: Binding(
                get: { settings.requireBiometrics },
                set: { on in
                    if on { Task { settings.requireBiometrics = await AppLock.shared.enable() } }
                    else { settings.requireBiometrics = false }
                }))
            // The banner's Reply action follows the lock: registered again when it changes.
            .onChange(of: settings.requireBiometrics) { Notifier.shared.registerCategories() }
            if settings.requireBiometrics {
                Picker("Lock after", selection: $settings.lockGraceSeconds) {
                    Text("Immediately").tag(0.0)
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("15 minutes").tag(900.0)
                    Text("1 hour").tag(3600.0)
                }
            }
        } header: {
            Text("Lock")
        } footer: {
            settings.requireBiometrics
                ? Text("Redde locks when it's been in the background longer than this. The device passcode works as a fallback. Background Shortcuts runs aren't gated.")
                : Text("Gate the app behind \(AppLock.biometryName). The phone holds the Hermes API key and the dashboard password.")
        }
    }
}

struct AboutSettings: View {
    @State private var copiedVersion = false

    var body: some View {
        Section("Privacy invariant") {
            Text("On-device speech recognition and synthesis. No analytics. Every request goes only to the servers you configured. The exceptions are opt-in: with “Let Siri use Redde” on, Apple Intelligence handles what you say to Siri; with a Hermes paired under “Notify when Redde is closed”, its notifications pass through Goosehouse's relay, encrypted; and with “Sync with iCloud” on, your settings and servers are kept in your own iCloud, their keys and passwords in iCloud Keychain, end-to-end encrypted.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section {
            NavigationLink { TipJarView() } label: { Label("Support Redde", systemImage: "heart") }
            Link(destination: URL(string: "https://apps.apple.com/app/id6810900557?action=write-review")!) {
                Label("Rate Redde on the App Store", systemImage: "star")
            }
            if let release = WhatsNew.highlights(of: WhatsNew.currentVersion) {
                NavigationLink("What's New in Redde") { WhatsNewView(release: release) }
            }
            NavigationLink("Acknowledgements") { AcknowledgementsView() }
            Button {
                UIPasteboard.general.string = SettingsView.versionLine
                copiedVersion = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copiedVersion = false }
            } label: {
                LabeledContent("Version") {
                    Text(copiedVersion ? String(localized: "Copied") : SettingsView.versionLine).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Copies the version for a bug report")
        }
    }
}

/// Back to a fresh install: conversations, attachments, credentials, settings, widget data.
struct ResetSettings: View {
    @Environment(Conversation.self) private var conversation
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    var body: some View {
        Section {
            Button("Erase everything…", role: .destructive) { confirming = true }
        } footer: {
            Text("Deletes every conversation and attachment on this device, forgets all servers, keys and passwords, and returns the settings to their defaults. Nothing on your servers is touched, and Sync with iCloud turns off first, so your other devices keep theirs.")
        }
        .confirmationDialog("Erase everything on this device?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Erase everything", role: .destructive) { eraseEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Conversations, attachments, credentials and settings. This can't be undone.")
        }
    }

    private func eraseEverything() {
        // First, so what is in iCloud stays for the other devices: only this device's copies go.
        CloudSync.shared.turnOff()
        HermesServeClient.shared.disconnect()
        // Dashboard logins (every server's), which disconnect() leaves in the cookie store.
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        conversation.eraseAll()
        AttachmentFiles.deleteAll()
        WebBlockHeights.clear()
        LinkPreviews.shared.clear()
        // Every server's secrets and every profile key; only the push registration secret stays.
        for account in Keychain.allAccounts() where account != Keychain.Item.pushRegisterSecret.rawValue {
            Keychain.delete(account: account)
        }
        KnownHosts.forgetAll()
        TerminalAccount.forgetAll()
        WidgetSnapshot.clear()
        NeedsYou.clear()
        ContextReading.clear()
        AgentBoard.clear()
        WidgetCenter.shared.reloadAllTimelines()
        Notifier.shared.clearDelivered()
        Settings.shared.reset()
        dismiss()
    }
}

/// A tiny two-bubble preview of a theme's palette.
/// The label of a collapsed settings group: its name, and the current choice on the trailing side.
struct DisclosureSummary<Value: View>: View {
    let title: String
    @ViewBuilder let value: Value

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            value.foregroundStyle(.secondary)
        }
    }
}

struct ThemeSwatch: View {
    let theme: ResolvedTheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.pageColor)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(theme.surfaceColor).frame(width: 26, height: 8)
                Capsule().fill(theme.userBubble).frame(width: 20, height: 8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(7)
        }
        .frame(width: 52, height: 40)
    }
}

/// Settings → Notifications → Quiet Hours (`QuietHours`).
struct QuietHoursSection: View {
    @State private var quiet = QuietHours.load()

    var body: some View {
        Section {
            Toggle("Quiet Hours", isOn: Binding(get: { quiet.on }, set: { quiet.on = $0; quiet.save() }))
            if quiet.on {
                DatePicker("From", selection: time(\.start), displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: time(\.end), displayedComponents: .hourAndMinute)
            }
        } footer: {
            Text("Between these times, what your agents send on their own (ideas, briefings and heads-ups, watches, scheduled answers) arrives without a sound or a banner, and one notification when the quiet ends says what came. Approvals, questions, replies you're waiting for and calls come through as always.")
        }
    }

    private func time(_ part: WritableKeyPath<QuietHours, Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: quiet[keyPath: part] / 60, minute: quiet[keyPath: part] % 60, second: 0, of: .now) ?? .now
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            quiet[keyPath: part] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            quiet.save()
        })
    }
}
