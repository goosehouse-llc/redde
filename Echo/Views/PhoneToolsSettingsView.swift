import SwiftUI

/// Settings → Phone tools: which of this iPhone's own things the agent may ask Redde for
/// (`DeviceTool`), what it has asked for lately, and the plugin on the Hermes server that offers
/// the tools to the agent.
struct PhoneToolsSettingsView: View {
    @State private var settings = Settings.shared
    @State private var service = DeviceToolsService.shared
    @State private var looking = PhotoLooking.shared
    @State private var plugin = PushPluginModel(manager: PhoneToolsSettingsView.server)
    @State private var refused: Set<DeviceArea> = []
    /// Whether iOS will show an alarm Redde sets: it does so as a Live Activity.
    @State private var alarmsShow = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmingInstall = false
    @Environment(\.openURL) private var openURL

    private static var server: any PushPluginManaging {
        #if DEBUG
        if let demo = DevHooks.value("-echo.demoPlugin") { return DemoPushPlugin(demo) }
        #endif
        return HermesServeClient.shared
    }

    var body: some View {
        Form {
            Section {
                Toggle("Phone tools", isOn: Binding(get: { settings.phoneTools.on }, set: { settings.phoneTools.on = $0 }))
            } footer: {
                Text("Lets your agent ask Redde for things on this \(device): your calendar, reminders, contacts, photos, a folder of files, alarms, a widget it can write on, and calls and messages. It is asked each time it wants to add, change or delete something. It can't go into other apps; iOS allows no app that.")
            }

            if settings.phoneTools.on {
                Section {
                    ForEach(DeviceArea.allCases) { area in
                        VStack(alignment: .leading, spacing: 4) {
                            Picker(selection: access(area)) {
                                Text("Off").tag(PhoneToolsSettings.Access.off)
                                if area.offersAsking { Text("Ask each time").tag(PhoneToolsSettings.Access.ask) }
                                Text(area.allowLabel).tag(PhoneToolsSettings.Access.allow)
                            } label: {
                                Label(area.label, systemImage: area.symbol)
                            }
                            Text(area.blurb).font(.footnote).foregroundStyle(.secondary)
                            if area == .photos {
                                Text(Self.photosNote(on: device)).font(.footnote).foregroundStyle(.secondary)
                                if settings.phoneTools.access(.photos) != .off, looking.total > 0 {
                                    Text(Self.lookingLine(looked: looking.looked, of: looking.total, working: looking.isWorking))
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            if area == .alarms, settings.phoneTools.access(.alarms) != .off, !alarmsShow {
                                Button("Live Activities are off for Redde, and iOS neither shows nor sounds an alarm without them. Open Settings…") {
                                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                                }
                                .font(.footnote)
                                .foregroundStyle(.red)
                            }
                            if service.unoffered.contains(area), settings.phoneTools.access(area) != .off {
                                Text("Redde's plugin on your Hermes is older than this and doesn't offer it, so your agent isn't given it.")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                            if refused.contains(area) {
                                Button("iOS doesn't allow Redde this. Open Settings…") {
                                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                                }
                                .font(.footnote)
                            }
                        }
                    }
                } header: {
                    Text("What it may use")
                } footer: {
                    Text("“Ask each time” puts every request to you first. “Allow reading” lets it look things up without asking; adding, changing and deleting are still put to you, and deleting photos is put to you by iOS with the photos shown. Files are Redde's folder in the Files app, under On My \(device). The widget is Redde's own, “From Your Agent”, which you add to your Home Screen: allowed, your agent writes on it without asking, also while Redde is closed if this \(device) is paired for notifications. A call is put to you by iOS before it goes out, and a message is written for you to send: Redde asks about neither, and can send nothing.")
                }

                Section {
                    pluginRow
                    ReddePluginLink()
                } header: {
                    Text("On your Hermes")
                } footer: {
                    Text("The tools are offered to your agent by Redde's plugin on your Hermes, the one that also sends notifications, from version 1.3.0. Redde talks to it through the Hermes Dashboard login. Phone tools work while Redde is open and following the conversation: a request made from somewhere else gets no answer.")
                }

                Section {
                    if service.log.isEmpty {
                        Text("Nothing has been asked for yet.").foregroundStyle(.secondary)
                    }
                    ForEach(service.log) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(entry.title, systemImage: symbol(entry.outcome))
                                .foregroundStyle(entry.outcome == .done ? Color.primary : Color.secondary)
                            Text(([entry.detail, entry.note].compactMap { $0?.nilIfEmpty } + [entry.at.formatted(date: .abbreviated, time: .shortened)]).joined(separator: " · "))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if !service.log.isEmpty { Button("Clear", role: .destructive) { service.clearLog() } }
                } header: {
                    Text("Asked for lately")
                }
            }
        }
        .navigationTitle("Phone Tools")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("\(plugin.installTitle) on your Hermes?", isPresented: $confirmingInstall, titleVisibility: .visible) {
            Button(plugin.installTitle) { Task { await plugin.install(); await service.publish() } }
        } message: {
            Text("Hermes downloads it from github.com/goosehouse-llc/redde and switches it on. It is the same plugin that sends notifications.")
        }
        .task { await plugin.refresh() }
        // Read again on coming back from the iPhone's Settings, where it is switched.
        #if os(iOS)
        .onChange(of: scenePhase, initial: true) { alarmsShow = SystemAlarms().canShow }
        #endif
        .task(id: settings.phoneTools) { await service.publish() }
        .onChange(of: settings.phoneTools.access(.photos), initial: true) { looking.resume() }
    }

    /// How far Redde has got with looking at the pictures, which is what a search by what they
    /// show goes by.
    static func lookingLine(looked: Int, of total: Int, working: Bool) -> String {
        let (seen, all) = (looked.formatted(), total.formatted())
        if looked >= total { return String(localized: "Redde has looked at all \(all) pictures.") }
        if working { return String(localized: "Redde has looked at \(seen) of \(all) pictures so far, and goes on while it is open.") }
        return String(localized: "Redde has looked at \(seen) of \(all) pictures; the others couldn't be looked at.")
    }

    /// Where the pictures are looked at, and what of them leaves the phone: said under Photos
    /// before it is turned on. Only what is true is said: the list of matches and a photo the
    /// agent asks to look at do go to the person's own server.
    static func photosNote(on device: String) -> String {
        String(localized: "To find a photo by what it shows, Redde looks at your pictures on this \(device) and keeps what it finds here.")
            + " " + String(localized: "Your agent is told only about the photos that match what it asks for, and gets a photo only when it asks to look at one.")
            + " " + String(localized: "Redde sends both to your Hermes and nowhere else.")
    }

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    /// An area's setting. Turned on, iOS is asked for its permission there and then; refused,
    /// the area stays off and says why.
    private func access(_ area: DeviceArea) -> Binding<PhoneToolsSettings.Access> {
        Binding(get: { settings.phoneTools.access(area) }, set: { wanted in
            refused.remove(area)
            guard wanted != .off else { settings.phoneTools.set(area, .off); return }
            Task {
                if await Self.permission(area) {
                    settings.phoneTools.set(area, wanted)
                } else {
                    settings.phoneTools.set(area, .off)
                    refused.insert(area)
                }
            }
        })
    }

    static func permission(_ area: DeviceArea) async -> Bool {
        switch area {
        case .calendar: await DeviceCalendar.allowed(.event)
        case .reminders: await DeviceCalendar.allowed(.reminder)
        case .contacts: await DeviceContacts.allowed()
        case .photos: await DevicePhotos.allowed()
        case .files: true
        #if os(iOS)
        case .alarms: await SystemAlarms().allowed()
        #else
        case .alarms: false   // a Mac has no alarms for Redde to set
        #endif
        case .widget, .people: true
        }
    }

    private func symbol(_ outcome: DeviceToolsService.Entry.Outcome) -> String {
        switch outcome {
        case .done: "checkmark.circle"
        case .denied: "hand.raised"
        case .failed: "exclamationmark.triangle"
        }
    }

    @ViewBuilder
    private var pluginRow: some View {
        switch plugin.phase {
        case .checking:
            HStack(spacing: 10) {
                ProgressView()
                Text("Looking for the plugin…").foregroundStyle(.secondary)
            }
        case .unknown:
            Text("The Hermes Dashboard couldn't be asked. Phone tools need its login: Settings → Connection details.")
                .foregroundStyle(.secondary)
        case let .known(state):
            VStack(alignment: .leading, spacing: 6) {
                Label(PushSettingsView.pluginLine(state, restart: plugin.outcome == .needsRestart),
                      systemImage: state.installed && state.enabled && !state.isOutdated ? "checkmark.circle" : "shippingbox")
                if plugin.outcome == .needsRestart {
                    Text("Hermes loads it when it next starts. Restart the gateway and the Dashboard on that machine.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let problem = plugin.problem { Text(problem).font(.footnote).foregroundStyle(.red) }
            }
            if plugin.installing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Hermes is fetching it from GitHub. This can take a minute.").font(.footnote).foregroundStyle(.secondary)
                }
            } else if plugin.offersInstall {
                // Nothing goes onto the person's server on one tap: asked first, as on the notifications screen.
                Button(plugin.installTitle, systemImage: "arrow.down.circle") { confirmingInstall = true }
            }
        }
    }
}
