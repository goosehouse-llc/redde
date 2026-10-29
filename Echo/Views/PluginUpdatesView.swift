import SwiftUI

/// Plugins → Check for Updates (`PluginUpdates`): every plugin installed for your agent and, from
/// your agent's Plugins, for each bot too (each has its own copy), with what is newer, one at a
/// time or all at once.
struct PluginUpdatesView: View {
    /// Whose plugins: a profile (nil, the one Redde is on) and what it is called.
    let agents: [(profile: String?, owner: String)]

    @State private var checks: [PluginUpdateCheck] = []
    @State private var checking = true
    @State private var problems: [String] = []
    /// Being updated, and how each went.
    @State private var updating: Set<String> = []
    @State private var outcomes: [String: String] = [:]
    @State private var settings = Settings.shared
    private let client = HermesServeClient.shared

    private var updates: [PluginUpdateCheck] { checks.filter(\.state.hasUpdate) }
    private var others: [PluginUpdateCheck] { checks.filter { !$0.state.hasUpdate } }

    var body: some View {
        List {
            if checking, checks.isEmpty {
                HStack(spacing: 10) { ProgressView(); Text("Checking…").foregroundStyle(.secondary) }
            } else if updates.isEmpty, problems.isEmpty {
                Label("Everything that can be checked is up to date.", systemImage: "checkmark.circle")
            }
            if !updates.isEmpty {
                Section {
                    ForEach(updates) { row($0) }
                    if updates.filter(canUpdateHere).count > 1 {
                        Button("Update All") { Task { await updateAll() } }
                            .disabled(!updating.isEmpty)
                    }
                } header: {
                    Text("Updates · \(updates.count)")
                } footer: {
                    Text("A plugin runs inside Hermes and can do whatever Hermes can: an update can change what it does. Updated, its tools are there from the agent's next chat.")
                }
            }
            if !others.isEmpty {
                Section("Up to Date or Can't Tell") {
                    ForEach(others) { row($0) }
                }
            }
            ForEach(problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
            Section {
            } footer: {
                Text("Catalog plugins are checked by your Hermes against Nous Research's catalog. For one installed from GitHub, this iPhone asks GitHub whether newer commits change it, naming only the repository.")
            }
        }
        .navigationTitle("Plugin Updates")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await check() }
        .task { await check() }
    }

    private func row(_ check: PluginUpdateCheck) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(check.plugin.name)
                    if agents.count > 1 { Text(check.owner).font(.caption).foregroundStyle(.secondary) }
                }
                Text(outcomes[check.id] ?? describe(check)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if updating.contains(check.id) {
                ProgressView()
            } else if case .redde = check.state {
                NavigationLink("Open") { ReddePluginView() }.fixedSize()
            } else if check.state.hasUpdate, outcomes[check.id] == nil {
                Button("Update") { Task { await update(check) } }
                    .buttonStyle(.borderless)
                    .disabled(!updating.isEmpty)
            }
        }
    }

    private func describe(_ check: PluginUpdateCheck) -> String {
        let installed = check.plugin.version.nilIfEmpty.map { "v\($0)" }
        switch check.state {
        case let .catalog(version):
            return version.map { String(localized: "\(installed ?? "") → v\($0), from the catalog") } ?? String(localized: "A newer one is in the catalog")
        case let .commits(count): return String(localized: "\(installed ?? "") · \(count) newer commits on GitHub")
        case let .feed(version): return String(localized: "\(installed ?? "") → v\(version)")
        case let .redde(version): return String(localized: "\(installed ?? "") → v\(version), with this Redde: update it on the Redde Plugin page")
        case .current: return [installed, String(localized: "Up to date")].compactMap { $0 }.joined(separator: " · ")
        case let .unknown(why): return why
        }
    }

    private func canUpdateHere(_ check: PluginUpdateCheck) -> Bool {
        if case .redde = check.state { return false }
        return check.state.hasUpdate && outcomes[check.id] == nil
    }

    private func check() async {
        checking = true
        defer { checking = false }
        #if DEBUG
        if DemoDay.on {   // the day's video's
            try? await Task.sleep(for: .milliseconds(600))
            checks = DemoDay.pluginChecks
            return
        }
        #endif
        var found: [PluginUpdateCheck] = [], failed: [String] = []
        // One agent after another: GitHub counts the checks, and a server answers one at a time.
        for agent in agents {
            do {
                found += try await client.checkPluginUpdates(profile: agent.profile, owner: agent.owner)
            } catch {
                failed.append(String(localized: "Couldn't read \(agent.owner)'s plugins: \(error.localizedDescription)"))
            }
        }
        checks = found
        problems = failed
        outcomes = [:]
    }

    private func update(_ check: PluginUpdateCheck) async {
        updating.insert(check.id)
        defer { updating.remove(check.id) }
        #if DEBUG
        if DemoDay.on {   // the day's video: as if it went
            try? await Task.sleep(for: .milliseconds(700))
            outcomes[check.id] = String(localized: "Updated")
            return
        }
        #endif
        do {
            switch check.state {
            case .catalog:
                switch try await client.updatePlugin(check.plugin.name, profile: check.profile) {
                case .updated, .unchanged: outcomes[check.id] = String(localized: "Updated")
                case .wantsMore: outcomes[check.id] = String(localized: "It would do more than before: update it from its page, where it says what.")
                }
            case .commits, .feed:
                let outcome = try await client.reinstallPlugin(check)
                outcomes[check.id] = outcome.restartRequired ? String(localized: "Updated: it starts when Hermes restarts") : String(localized: "Updated")
            case .redde, .current, .unknown:
                return
            }
        } catch {
            outcomes[check.id] = String(localized: "Didn't update: \(error.localizedDescription)")
        }
    }

    private func updateAll() async {
        for check in updates where canUpdateHere(check) { await update(check) }
    }
}

extension PluginUpdatesView {
    /// Your agent and, on the Dashboard with bots, each bot.
    static func everyAgent(settings: Settings = .shared) -> [(profile: String?, owner: String)] {
        var agents: [(profile: String?, owner: String)] = [(nil, settings.headerTitle)]
        if BotDirectory.available(settings), BotDirectory.shared.key == settings.connectionKey {
            let current = settings.profileName ?? "default"
            for bot in BotDirectory.shared.roster?.listed ?? [] where !bot.viaAPI && bot.name != current {
                agents.append((bot.name, bot.label(mainName: settings.headerTitle)))
            }
        }
        return agents
    }
}
