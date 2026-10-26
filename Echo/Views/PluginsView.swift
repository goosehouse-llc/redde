import SwiftUI

/// Hermes plugins for a profile: those installed (on or off, updated, set up, removed) and the
/// catalog to find more in (`CatalogPlugin`), over the Dashboard. `profile` nil: the one Redde is
/// on; a bot's from Edit Bot. Asked 2026-10-26: "search and install of official hermes plugins
/// through Redde".
struct PluginsView: View {
    let profile: String?
    /// Whose they are, in words ("Sol", "Home").
    let owner: String

    @State private var installed: [InstalledPlugin] = []
    @State private var release: String?
    @State private var loading = true
    @State private var problem: String?
    private let client = HermesServeClient.shared

    var body: some View {
        List {
            if !client.hasCredentials {
                ContentUnavailableView("Needs the Hermes Dashboard", systemImage: "puzzlepiece.extension",
                                       description: Text("Plugins are installed through the Hermes Dashboard: add its address and login in Settings. The Hermes API has no way to."))
            } else {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
                Section {
                    NavigationLink {
                        PluginCatalogView(profile: profile, owner: owner, installed: Set(installed.compactMap(\.catalogName)), release: release) {
                            Task { await load() }
                        }
                    } label: {
                        Label("Find Plugins", systemImage: "magnifyingglass")
                    }
                } footer: {
                    Text("Nous Research's catalog of Hermes plugins. A plugin runs on your server inside Hermes and can do whatever Hermes can: Official ones are Nous Research's own, Verified ones Nous has checked, Community ones anyone's.")
                }
                Section {
                    if loading, installed.isEmpty {
                        ProgressView()
                    } else if added.isEmpty {
                        Text("None yet.").foregroundStyle(.secondary)
                    }
                    ForEach(added) { plugin in link(plugin) }
                } header: {
                    Text(added.isEmpty ? "Installed" : "Installed · \(added.count)")
                } footer: {
                    Text("\(owner)'s own: each bot has its plugins, set in Edit Bot. A new bot starts with a copy of your agent's.")
                }
                if !bundled.isEmpty {
                    Section {
                        NavigationLink {
                            List { ForEach(bundled) { plugin in link(plugin) } }
                                .navigationTitle("Come with Hermes")
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            LabeledContent("Come with Hermes", value: "\(bundled.filter(\.enabled).count) of \(bundled.count) on")
                        }
                    }
                }
            }
        }
        .navigationTitle("Plugins")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private var added: [InstalledPlugin] { installed.filter { !$0.bundled } }
    private var bundled: [InstalledPlugin] { installed.filter(\.bundled) }

    private func link(_ plugin: InstalledPlugin) -> some View {
        NavigationLink {
            InstalledPluginView(plugin: plugin, profile: profile, owner: owner) { Task { await load() } }
        } label: {
            InstalledPluginRow(plugin: plugin)
        }
    }

    private func load() async {
        guard client.hasCredentials else { return loading = false }
        loading = true
        defer { loading = false }
        async let version = client.hermesRelease()
        do {
            // One row each: a plugin Hermes finds twice (two entry points) is listed once.
            var seen = Set<String>()
            installed = try await client.installedPlugins(profile: profile)
                .filter { seen.insert($0.key).inserted }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            problem = nil
        } catch {
            problem = "Couldn't read the plugins: \(error.localizedDescription)"
        }
        release = await version
    }
}

private struct InstalledPluginRow: View {
    let plugin: InstalledPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(plugin.name).foregroundStyle(plugin.enabled ? .primary : .secondary)
                if let tier = plugin.catalogTier { TierBadge(tier: tier) }
                if plugin.updateAvailable { Text("Update").font(.caption2.bold()).foregroundStyle(.tint) }
            }
            Text([plugin.enabled ? "On" : "Off", plugin.version.nilIfEmpty.map { "v\($0)" }, plugin.bundled ? "Comes with Hermes" : nil]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct TierBadge: View {
    let tier: CatalogPlugin.Tier

    var body: some View {
        Text(tier.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch tier {
        case .official: .blue
        case .verified: .green
        case .community: .secondary
        }
    }
}

// MARK: - The catalog

private struct PluginCatalogView: View {
    let profile: String?
    let owner: String
    let installed: Set<String>
    let release: String?
    var changed: () -> Void

    @State private var catalog: PluginCatalog?
    @State private var problem: String?
    @State private var query = ""
    @State private var everyone = false
    @State private var category: String?

    private var tiers: Set<CatalogPlugin.Tier> { everyone ? Set(CatalogPlugin.Tier.allCases) : [.official, .verified] }
    private var found: [CatalogPlugin] { catalog?.search(query, tiers: tiers, category: category) ?? [] }

    var body: some View {
        List {
            if let problem, catalog == nil {
                ContentUnavailableView("Couldn't get the catalog", systemImage: "wifi.exclamationmark", description: Text(problem))
            } else if catalog == nil {
                ProgressView()
            } else {
                Section {
                    Picker("Show", selection: $everyone) {
                        Text("Official and Verified").tag(false)
                        Text("All").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if everyone {
                        Text("Community plugins are anyone's, unchecked by Nous Research. Look at what one does and who made it before you install it.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    if found.isEmpty { Text("No plugins match.").foregroundStyle(.secondary) }
                    ForEach(found) { plugin in
                        NavigationLink {
                            CatalogPluginView(plugin: plugin, profile: profile, owner: owner, installed: installed.contains(plugin.name),
                                              release: release, changed: changed)
                        } label: {
                            CatalogRow(plugin: plugin, installed: installed.contains(plugin.name))
                        }
                    }
                } header: {
                    Text("\(found.count) plugin\(found.count == 1 ? "" : "s")")
                } footer: {
                    Text("From Nous Research's site, fetched by this phone and kept a few hours.")
                }
            }
        }
        .navigationTitle("Find Plugins")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search plugins")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Category", selection: $category) {
                        Text("Every Category").tag(String?.none)
                        ForEach(catalog?.categories ?? [], id: \.self) { Text($0.capitalized).tag(String?.some($0)) }
                    }
                } label: {
                    Label("Category", systemImage: category == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .disabled(catalog == nil)
            }
        }
        .refreshable { await load(refresh: true) }
        .task { await load() }
    }

    private func load(refresh: Bool = false) async {
        do {
            catalog = try await PluginCatalogStore.load(refresh: refresh)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

private struct CatalogRow: View {
    let plugin: CatalogPlugin
    let installed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(plugin.title)
                TierBadge(tier: plugin.tier)
                if installed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Installed") }
            }
            Text(plugin.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text([plugin.maintainer.nilIfEmpty, plugin.category.capitalized].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// One catalog plugin: what it does and needs, and Install, asked first.
private struct CatalogPluginView: View {
    let plugin: CatalogPlugin
    let profile: String?
    let owner: String
    let installed: Bool
    let release: String?
    var changed: () -> Void

    @State private var asking = false
    @State private var installing = false
    @State private var outcome: PluginOutcome?
    @State private var problem: String?

    private var tooOld: Bool { release.flatMap { plugin.runs(onHermes: $0) } == false }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(plugin.title).font(.title3.bold())
                        TierBadge(tier: plugin.tier)
                    }
                    Text([plugin.maintainer.nilIfEmpty.map { "By \($0)" }, plugin.version.map { "v\($0)" }, plugin.category.capitalized]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text(plugin.summary)
            }
            if let disclosure = plugin.disclosure {
                Section("What it sends and costs") { Text(disclosure).font(.callout) }
            }
            if !plugin.tools.isEmpty || !plugin.hooks.isEmpty || !plugin.middleware.isEmpty || !plugin.keys.isEmpty {
                Section("What it adds") {
                    if !plugin.tools.isEmpty { LabeledContent("Tools", value: plugin.tools.joined(separator: ", ")) }
                    if !plugin.hooks.isEmpty { LabeledContent("Hooks", value: plugin.hooks.joined(separator: ", ")) }
                    if !plugin.middleware.isEmpty { LabeledContent("Middleware", value: plugin.middleware.joined(separator: ", ")) }
                    if !plugin.keys.isEmpty { LabeledContent("Keys it needs", value: plugin.keys.joined(separator: ", ")) }
                }
            }
            Section {
                if let requires = plugin.requiresHermes {
                    LabeledContent("Hermes", value: requires.replacingOccurrences(of: ">=", with: "") + (requires.hasPrefix(">=") ? " or later" : ""))
                }
                if !plugin.platforms.isEmpty {
                    LabeledContent("Runs on", value: plugin.platforms.map { $0 == "macos" ? "macOS" : $0.capitalized }.joined(separator: ", "))
                }
                if let docs = plugin.docs { Link("Documentation", destination: docs) }
                if let repo = URL(string: plugin.repo) { Link("Source", destination: repo) }
            } footer: {
                if tooOld, let release { Text("Your server runs Hermes \(release): update Hermes first.") }
            }
            if !plugin.knownIssues.isEmpty {
                Section("Known issues") { ForEach(plugin.knownIssues, id: \.self) { Text($0).font(.callout) } }
            }
            Section {
                if installed {
                    Label("Installed for \(owner)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button {
                        asking = true
                    } label: {
                        if installing {
                            HStack { ProgressView(); Text("Installing… this can take a minute or two") }
                        } else {
                            Label("Install for \(owner)", systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(installing || tooOld)
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text("Hermes fetches it from \(plugin.repo.replacingOccurrences(of: "https://", with: "")) at the version its catalog names, checks it, and switches it on.")
            }
        }
        .navigationTitle(plugin.title)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Install \(plugin.title) for \(owner)?", isPresented: $asking, titleVisibility: .visible) {
            Button("Install") { install() }
        } message: {
            Text(plugin.tier == .community
                 ? "A community plugin, unchecked by Nous Research. It runs on your server inside Hermes, with everything Hermes can reach."
                 : "It runs on your server inside Hermes, with everything Hermes can reach.")
        }
        .sheet(item: Binding(get: { outcome.map(OutcomeSheet.Item.init) }, set: { if $0 == nil { outcome = nil } })) { item in
            OutcomeSheet(outcome: item.outcome, profile: profile, verb: "Installed")
        }
    }

    private func install() {
        installing = true
        problem = nil
        Task {
            defer { installing = false }
            do {
                outcome = try await HermesServeClient.shared.installPlugin(plugin.name, profile: profile)
                changed()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

// MARK: - One installed

private struct InstalledPluginView: View {
    @State var plugin: InstalledPlugin
    let profile: String?
    let owner: String
    var changed: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var problem: String?
    @State private var outcome: PluginOutcome?
    @State private var wantsMore: [String]?
    @State private var removing = false
    @State private var edits: [String: String] = [:]

    private let client = HermesServeClient.shared

    var body: some View {
        Form {
            Section {
                Toggle("On", isOn: Binding(get: { plugin.enabled }, set: { on in run { try await switchTo(on) } }))
                    .disabled(working)
                if !plugin.description.isEmpty { Text(plugin.description).font(.callout) }
                LabeledContent("Version", value: plugin.version.nilIfEmpty ?? "—")
                if let tier = plugin.catalogTier { LabeledContent("Catalog") { TierBadge(tier: tier) } }
                if plugin.bundled { LabeledContent("Comes with Hermes", value: "Yes") }
            } footer: {
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            if plugin.updateAvailable {
                Section {
                    Button("Update to the Catalog's Version") { run { try await update(accepting: false) } }
                        .disabled(working)
                }
            }
            if !plugin.servers.isEmpty {
                Section("Its servers") {
                    ForEach(plugin.servers, id: \.name) { server in
                        LabeledContent(server.name, value: server.sentence.nilIfEmpty ?? server.state.replacingOccurrences(of: "_", with: " "))
                    }
                }
            }
            if !plugin.settings.isEmpty {
                Section {
                    ForEach(plugin.settings) { setting in settingRow(setting) }
                    if !edits.isEmpty {
                        Button("Save Settings") { run { try await saveSettings() } }.disabled(working)
                    }
                } header: {
                    Text("Settings")
                } footer: {
                    Text("A key is kept in \(owner)'s .env on your server and never shown again here.")
                }
            }
            if !plugin.bundled {
                Section {
                    Button("Remove Plugin", role: .destructive) { removing = true }.disabled(working)
                }
            }
        }
        .navigationTitle(plugin.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove \(plugin.name) from \(owner)?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { run { try await remove() } }
        }
        .alert("It does more than before", isPresented: Binding(get: { wantsMore != nil }, set: { if !$0 { wantsMore = nil } })) {
            Button("Update") { run { try await update(accepting: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text((wantsMore ?? []).joined(separator: "\n"))
        }
        .sheet(item: Binding(get: { outcome.map(OutcomeSheet.Item.init) }, set: { if $0 == nil { outcome = nil } })) { item in
            OutcomeSheet(outcome: item.outcome, profile: profile, verb: "Done")
        }
    }

    @ViewBuilder private func settingRow(_ setting: PluginSetting) -> some View {
        switch setting.kind {
        case .secret:
            if let env = setting.env {
                PluginKeyField(name: env, label: setting.label, isSet: setting.isSet, profile: profile)
            }
        case .boolean:
            Toggle(setting.label, isOn: Binding(
                get: { edits[setting.key].map { $0 == "true" } ?? (setting.value?.bool ?? false) },
                set: { edits[setting.key] = $0 ? "true" : "false" }))
        case .enum:
            Picker(setting.label, selection: Binding(
                get: { edits[setting.key] ?? setting.value?.string ?? "" },
                set: { edits[setting.key] = $0 })) {
                ForEach(setting.choices, id: \.self) { Text($0).tag($0) }
            }
        default:
            LabeledContent(setting.label) {
                TextField(setting.description.nilIfEmpty ?? setting.label, text: Binding(
                    get: { edits[setting.key] ?? setting.value?.displayText ?? "" },
                    set: { edits[setting.key] = $0 }))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(setting.kind == .number ? .decimalPad : .default)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        working = true
        problem = nil
        Task {
            defer { working = false }
            do { try await work() } catch { problem = error.localizedDescription }
        }
    }

    private func switchTo(_ on: Bool) async throws {
        let result = try await client.switchPlugin(plugin, on: on, profile: profile)
        plugin.status = on ? "enabled" : "disabled"
        if on, !result.liveNow.isEmpty || !result.nextChat.isEmpty || result.restartRequired || !result.missingKeys.isEmpty { outcome = result }
        changed()
    }

    /// By its folder's name, which Hermes updates by.
    private func update(accepting: Bool) async throws {
        switch try await client.updatePlugin(plugin.name, accepting: accepting, profile: profile) {
        case let .wantsMore(lines): wantsMore = lines
        case .unchanged: plugin.updateAvailable = false
        case let .updated(result):
            plugin.updateAvailable = false
            outcome = result
        }
        changed()
    }

    private func saveSettings() async throws {
        var values: [String: JSONValue] = [:]
        for setting in plugin.settings where setting.kind != .secret {
            guard let text = edits[setting.key] else { continue }
            values[setting.key] = switch setting.kind {
            case .boolean: .bool(text == "true")
            case .number: Double(text).map(JSONValue.number) ?? .string(text)
            case .json: (try? JSONValue.parse(Data(text.utf8))) ?? .string(text)
            default: .string(text)
            }
        }
        try await client.setPluginSettings(plugin, values, profile: profile)
        edits = [:]
        changed()
    }

    private func remove() async throws {
        try await client.removePlugin(plugin.name, profile: profile)
        changed()
        dismiss()
    }
}

/// A key typed once and stored in the profile's .env (`setPluginKey`); only whether one is set is
/// ever shown.
private struct PluginKeyField: View {
    let name: String
    let label: String
    @State var isSet: Bool
    let profile: String?

    @State private var value = ""
    @State private var saving = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField(isSet ? "\(label): set, type to replace" : label, text: $value)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button(saving ? "Saving…" : "Save") { save() }
                    .disabled(value.isEmpty || saving)
            }
            Text(name).font(.caption2.monospaced()).foregroundStyle(.secondary)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await HermesServeClient.shared.setPluginKey(name, value: value, profile: profile)
                value = ""
                isSet = true
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// What an install or a change did: what works now, from the next chat, after a restart, and the
/// keys still wanted.
private struct OutcomeSheet: View {
    struct Item: Identifiable {
        var outcome: PluginOutcome
        var id: String { outcome.name }
    }

    let outcome: PluginOutcome
    let profile: String?
    let verb: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if !outcome.liveNow.isEmpty {
                    Section("Working now") { ForEach(outcome.liveNow, id: \.self) { Text($0) } }
                }
                if !outcome.nextChat.isEmpty {
                    Section {
                        ForEach(outcome.nextChat, id: \.self) { Text($0) }
                    } header: {
                        Text("From the next chat")
                    } footer: {
                        Text("Chats already open keep the tools they started with.")
                    }
                }
                if outcome.restartRequired {
                    Section { Label("Hermes takes it up when it next restarts.", systemImage: "arrow.clockwise") }
                }
                if !outcome.missingKeys.isEmpty {
                    Section {
                        ForEach(outcome.missingKeys, id: \.self) { key in
                            PluginKeyField(name: key, label: key, isSet: false, profile: profile)
                        }
                    } header: {
                        Text("Keys it needs")
                    } footer: {
                        Text("Kept in the .env on your server; never shown again here.")
                    }
                }
                if !outcome.notes.isEmpty {
                    Section("Notes") { ForEach(outcome.notes, id: \.self) { Text($0).font(.callout) } }
                }
                if outcome.liveNow.isEmpty, outcome.nextChat.isEmpty, !outcome.restartRequired, outcome.missingKeys.isEmpty, outcome.notes.isEmpty {
                    Section { Label("\(outcome.name) is on.", systemImage: "checkmark.circle.fill") }
                }
            }
            .navigationTitle("\(verb): \(outcome.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
