import SwiftUI

/// Toolsets the API server platform has enabled, read from the gateway.
struct ToolsView: View {
    @Environment(Conversation.self) private var conversation
    @State private var toolsets: [HermesSessionsAPI.Toolset] = []
    @State private var error: String?
    @State private var loading = true
    @State private var busy: Set<String> = []

    private var enabled: [HermesSessionsAPI.Toolset] { toolsets.filter { $0.enabled == true }.sorted { $0.name < $1.name } }
    private var disabled: [HermesSessionsAPI.Toolset] { toolsets.filter { $0.enabled != true }.sorted { $0.name < $1.name } }
    /// Toggling needs the hermes serve login; read once per load, not once per row.
    @State private var canToggle = HermesServeClient.shared.hasCredentials

    var body: some View {
        List {
            if let error, toolsets.isEmpty {
                ContentUnavailableView("Couldn't reach the gateway", systemImage: "wifi.exclamationmark", description: Text(error))
                    .listRowSeparator(.hidden)
            } else if loading, toolsets.isEmpty {
                ProgressView("Loading from Redde…")
            } else {
                // A failed toggle/refresh must not blank a loaded list; show it inline instead.
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange).listRowSeparator(.hidden)
                }
                Section {
                    ForEach(enabled) { row($0) }
                } header: {
                    Text("Enabled · \(enabled.count)")
                } footer: {
                    Text(canToggle
                        ? "Switches change the toolset's platform setting in Redde's config, the same as the dashboard. The API server's own list (platform_toolsets.api_server) is separate and set in config.yaml on the Redde host."
                        : "Anything here can be used by asking in plain words. Add the Redde serve login to toggle toolsets from here.")
                }
                if !disabled.isEmpty {
                    Section("Not enabled · \(disabled.count)") {
                        ForEach(disabled) { row($0) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Tools")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ set: HermesSessionsAPI.Toolset) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(set.label ?? set.name).font(.body)
                Spacer()
                if let tools = set.tools, !tools.isEmpty { Text("\(tools.count)").font(.caption).foregroundStyle(.secondary) }
                if canToggle {
                    Toggle("", isOn: Binding(get: { set.enabled == true }, set: { toggle(set, $0) }))
                        .labelsHidden()
                        .disabled(busy.contains(set.name))
                }
            }
            if let description = set.description, !description.isEmpty {
                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if let tools = set.tools, !tools.isEmpty {
                Text(tools.joined(separator: " · ")).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }

    private func toggle(_ set: HermesSessionsAPI.Toolset, _ on: Bool) {
        busy.insert(set.name)
        if let i = toolsets.firstIndex(where: { $0.name == set.name }) { toolsets[i].enabled = on }
        Task {
            do { try await HermesServeClient.shared.toggleToolset(name: set.name, enabled: on) }
            catch { self.error = error.localizedDescription }
            await load()
            busy.remove(set.name)
        }
    }

    private func load() async {
        canToggle = HermesServeClient.shared.hasCredentials
        do {
            if canToggle {
                // Prefer the dashboard: its flags are the ones the switches change.
                toolsets = try await HermesServeClient.shared.dashboardToolsets()
            } else if let api = conversation.ledgerAPI() {
                toolsets = try await api.toolsets()
            } else {
                error = "Add the Redde API key or the Redde serve login in Settings."
                loading = false
                return
            }
            error = nil
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}

/// Skills the agent knows, read from the gateway; create and edit via hermes serve.
struct SkillsView: View {
    @Environment(Conversation.self) private var conversation
    @State private var skills: [HermesSessionsAPI.Skill] = []
    @State private var error: String?
    @State private var loading = true
    @State private var busy: Set<String> = []

    /// Writing and toggling need the hermes serve login; reading works with either credential.
    /// Read once per load, not twice per row.
    @State private var canWrite = HermesServeClient.shared.hasCredentials

    private var byCategory: [(category: String, skills: [HermesSessionsAPI.Skill])] {
        let grouped = Dictionary(grouping: skills) { ($0.category?.isEmpty == false ? $0.category! : "Other") }
        return grouped.keys.sorted().compactMap { key in grouped[key].map { (key, $0.sorted { $0.name < $1.name }) } }
    }

    var body: some View {
        List {
            if let error, skills.isEmpty {
                ContentUnavailableView("Couldn't reach the gateway", systemImage: "wifi.exclamationmark", description: Text(error))
                    .listRowSeparator(.hidden)
            } else if loading, skills.isEmpty {
                ProgressView("Loading from Redde…")
            } else {
                // A failed toggle/refresh must not blank a loaded list; show it inline instead.
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange).listRowSeparator(.hidden)
                }
                Section {
                    Label(canWrite ? "Switch a skill off and Redde stops loading it; edit or create with the editor." : "Add the Redde serve username and password in Settings to create, edit or toggle skills.",
                          systemImage: canWrite ? "sparkles" : "pencil.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if skills.isEmpty {
                    ContentUnavailableView("No skills", systemImage: "sparkles", description: Text("The gateway reports no skills."))
                        .listRowSeparator(.hidden)
                }
                ForEach(byCategory, id: \.category) { group in
                    Section("\(group.category.capitalized) · \(group.skills.count)") {
                        ForEach(group.skills) { skill in
                            HStack {
                                NavigationLink {
                                    SkillEditorView(existing: skill.name) { Task { await load() } }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(skill.name).font(.body)
                                            .foregroundStyle(skill.enabled == false ? .secondary : .primary)
                                        if let description = skill.description, !description.isEmpty {
                                            Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                        }
                                    }
                                }
                                .disabled(!canWrite)
                                if canWrite, skill.enabled != nil {
                                    Toggle("", isOn: Binding(get: { skill.enabled ?? true }, set: { toggle(skill, $0) }))
                                        .labelsHidden()
                                        .disabled(busy.contains(skill.name))
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    SkillEditorView(existing: nil) { Task { await load() } }
                } label: {
                    Label("New skill", systemImage: "plus")
                }
                .disabled(!canWrite)
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func toggle(_ skill: HermesSessionsAPI.Skill, _ on: Bool) {
        busy.insert(skill.name)
        if let i = skills.firstIndex(where: { $0.name == skill.name }) { skills[i].enabled = on }
        Task {
            do { try await HermesServeClient.shared.toggleSkill(name: skill.name, enabled: on) }
            catch { self.error = error.localizedDescription }
            await load()
            busy.remove(skill.name)
        }
    }

    private func load() async {
        canWrite = HermesServeClient.shared.hasCredentials
        do {
            if canWrite {
                // The dashboard list carries the enabled flag the switches change.
                skills = try await HermesServeClient.shared.dashboardSkills().map {
                    HermesSessionsAPI.Skill(name: $0.name, description: $0.description, category: $0.category, enabled: $0.enabled ?? true)
                }
            } else if let api = conversation.ledgerAPI() {
                skills = try await api.skills()
            } else {
                error = "Add the Redde API key or the Redde serve login in Settings."
                loading = false
                return
            }
            error = nil
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}
