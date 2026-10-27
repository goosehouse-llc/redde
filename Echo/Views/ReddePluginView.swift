import SwiftUI

/// The Redde plugin on the user's Hermes, on a page of its own (Settings → Redde Plugin, on the
/// first screen; it was under Agent until he moved it, 2026-10-23): what it does for Redde, whether
/// it is there and how new, and the button that installs or updates it. It does far more than
/// notifications, where its row used to be the only one (asked 2026-10-23, "is the plugin really
/// only for Voice?"): cards in replies, the phone tools, the widget the agent writes on, and
/// notifications when Redde is closed. Phone tools links here too; the notifications screen shows
/// the same row.
struct ReddePluginView: View {
    @State private var settings = Settings.shared
    @State private var plugin = PushPluginModel(manager: PushSettingsView.pluginManager)

    var body: some View {
        Form {
            Section {
                if PushSettingsView.canAskDashboard {
                    ReddePluginRow(plugin: plugin, serverName: settings.activeServer.flatMap { $0.name.isEmpty ? nil : $0.name })
                } else {
                    CommandRow(title: "On the machine that runs Hermes, install the plugin, then restart Hermes", command: PushSettingsView.installCommand)
                }
            } footer: {
                Text("Redde asks your Hermes about the plugin through its Dashboard login. Without one, the command installs it; run it again with --force to update it.")
            }
            Section {
                Label("Cards in replies: maps, places, the weather and the time", systemImage: "map")
                Label("Phone tools: your calendar, reminders, contacts, photos and alarms, as you allow", systemImage: "iphone")
                Label("The widget your agent writes on", systemImage: "rectangle.on.rectangle")
                Label("Notifications when Redde is closed, encrypted end to end", systemImage: "bell.badge")
            } header: {
                Text("What it does")
            } footer: {
                Text("The plugin runs on your Hermes. Hermes downloads it from github.com/goosehouse-llc/redde. It sends nothing anywhere but to this iPhone, through the notification relay when you pair, except to look up the weather or the time somewhere: then it asks Open-Meteo, with the place's name.")
            }
        }
        .navigationTitle("Redde Plugin")
        .navigationBarTitleDisplayMode(.inline)
        .task { if PushSettingsView.canAskDashboard { await plugin.refresh() } }
    }
}

/// Whether the plugin is on the server, and the button that puts it there or brings it up to date.
struct ReddePluginRow: View {
    let plugin: PushPluginModel
    let serverName: String?
    @State private var confirmingInstall = false

    var body: some View {
        Group {
            switch plugin.phase {
            case .checking:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for the plugin on \(serverName ?? String(localized: "your Hermes"))…").foregroundStyle(.secondary)
                }
            case .unknown:
                // The Dashboard couldn't be asked: the terminal's way still works.
                CommandRow(title: "On the machine that runs Hermes, install the plugin, then restart Hermes", command: PushSettingsView.installCommand)
            case let .known(state):
                VStack(alignment: .leading, spacing: 6) {
                    Label(PushSettingsView.pluginLine(state, restart: plugin.outcome == .needsRestart),
                          systemImage: state.installed && state.enabled && !state.isOutdated ? "checkmark.circle" : "shippingbox")
                    if plugin.outcome == .needsRestart {
                        Text("Hermes loads it when it next starts. Restart the gateway and the Dashboard on that machine.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let problem = plugin.problem {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                    }
                }
                if plugin.installing {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Hermes is fetching it from GitHub. This can take a minute.").font(.footnote).foregroundStyle(.secondary)
                    }
                } else if plugin.offersInstall {
                    Button(plugin.installTitle, systemImage: "arrow.down.circle") { confirmingInstall = true }
                }
                if plugin.outcome == .needsRestart {
                    CommandRow(title: "On that machine", command: "hermes gateway restart")
                }
            }
        }
        .confirmationDialog(installQuestion, isPresented: $confirmingInstall, titleVisibility: .visible) {
            Button(plugin.installTitle) { Task { await plugin.install() } }
        } message: {
            Text("Hermes downloads it from github.com/goosehouse-llc/redde and switches it on. It is the same plugin the command in a terminal installs.")
        }
    }

    private var installQuestion: String {
        let server = serverName ?? String(localized: "your Hermes")
        return plugin.state?.installed == true ? String(localized: "Have \(server) fetch the plugin again?") : String(localized: "Have \(server) install the Redde plugin?")
    }
}

/// A row that opens the Redde Plugin page, for the screens whose features need it.
struct ReddePluginLink: View {
    var body: some View {
        NavigationLink { ReddePluginView() } label: {
            Label("Redde Plugin", systemImage: "shippingbox")
        }
    }
}
