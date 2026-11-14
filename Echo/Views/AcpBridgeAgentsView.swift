import SwiftUI

/// An agent in the ACP registry, as the bridge's computer would run it (`_redde/registry`).
nonisolated struct AcpRegistryAgent: Identifiable, Hashable, Sendable {
    var id: String
    /// Its id on the bridge once added ("pi-acp" → "pi").
    var bridgeID: String
    var name: String
    var version: String
    var summary: String
    var license: String
    var website: URL?
    /// What the computer runs: "npx -y pi-acp@0.0.34", or the program a download brings.
    var runs: String
    var installed: Bool
    /// A program of its own the adapter runs, which has to be installed on the computer first.
    var needs: Needs?

    struct Needs: Hashable, Sendable {
        var program: String
        var install: String
        var found: Bool
    }

    init?(_ json: JSONValue) {
        guard let id = json["id"]?.string, let name = json["name"]?.string else { return nil }
        self.id = id
        bridgeID = json["bridgeId"]?.string ?? id
        self.name = name
        version = json["version"]?.string ?? ""
        summary = json["description"]?.string ?? ""
        license = json["license"]?.string ?? ""
        website = json["website"]?.string.flatMap { URL(string: $0) }.flatMap { $0.scheme == "https" ? $0 : nil }
        runs = json["runs"]?.string ?? ""
        installed = json["installed"]?.bool ?? false
        if let needs = json["needs"], let program = needs["program"]?.string {
            self.needs = Needs(program: program, install: needs["install"]?.string ?? "", found: needs["found"]?.bool ?? false)
        }
    }
}

/// The agents on a Redde bridge, and the ACP registry's to add (asked 2026-11-14, "more bridge
/// agents, maybe Pi"): the bridge downloads one when it's a program of its own, writes it to its
/// config and serves it at once. Swipe to take one off; its chats stay with the agent.
struct AcpBridgeAgentsView: View {
    let endpoint: AcpEndpoint
    /// The agent this connection is on, which can't be taken off from here.
    let current: String
    /// After an agent is added or taken off.
    var changed: () -> Void = {}

    @State private var onBridge: [AcpEndpoint.Agent] = []
    @State private var registry: [AcpRegistryAgent] = []
    @State private var loading = true
    @State private var problem: String?
    @State private var search = ""
    @State private var asking: AcpRegistryAgent?
    @State private var removing: AcpEndpoint.Agent?
    @State private var working: String?
    @State private var added: AcpRegistryAgent?

    private var toAdd: [AcpRegistryAgent] {
        let words = search.trimmingCharacters(in: .whitespaces)
        return registry.filter { !$0.installed }
            .filter { words.isEmpty || $0.name.localizedCaseInsensitiveContains(words) || $0.summary.localizedCaseInsensitiveContains(words) }
    }

    var body: some View {
        List {
            if let added {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(added.name) is on the bridge", comment: "Bridge agents: after an agent was added; the agent")
                                .font(.headline)
                            Text("Pick it from the agent menu at the top of the chat list.", comment: "Bridge agents: where an added agent is found")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if let needs = added.needs, !needs.found {
                                needsNote(needs, for: added)
                            }
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
            Section {
                ForEach(onBridge) { agent in
                    HStack {
                        Text(agent.name)
                        Spacer()
                        if working == agent.id {
                            ProgressView()
                        } else if agent.id == current {
                            Text("This connection", comment: "Bridge agents: the agent this server is on").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        if agent.id != current, working == nil {
                            Button(String(localized: "Remove", comment: "A to-do list: take one item off it"), role: .destructive) {
                                removing = agent
                            }
                        }
                    }
                }
            } header: {
                Text("On the Bridge", comment: "Bridge agents: the agents the bridge serves")
            }
            Section {
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button(String(localized: "Try Again", comment: "Retry button")) { Task { await load(fresh: true) } }
                } else if toAdd.isEmpty {
                    Text(search.isEmpty ? String(localized: "Every agent in the registry is on the bridge.", comment: "Bridge agents: nothing left to add")
                                        : String(localized: "No agent matches.", comment: "Bridge agents: a search with no results"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(toAdd) { agent in row(agent) }
                }
            } header: {
                Text("Add from the ACP Registry", comment: "Bridge agents: the registry's agents to add")
            } footer: {
                Text("The registry lists the agents that speak ACP. The computer runs the one you pick; some need signing in on the computer once.",
                     comment: "Bridge agents: under the registry's list")
            }
        }
        .searchable(text: $search, prompt: Text("Search agents", comment: "Bridge agents: the search field's prompt"))
        .navigationTitle(String(localized: "Agents", comment: "Bridge agents: the screen's title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await load(fresh: true) }
        .task { await load(fresh: false) }
        .confirmationDialog(asking.map { String(localized: "Add \($0.name)?", comment: "Bridge agents: confirm adding an agent; its name") } ?? "",
                            isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), titleVisibility: .visible,
                            presenting: asking) { agent in
            Button(String(localized: "Add to the Bridge", comment: "Bridge agents: confirms adding an agent")) {
                Task { await add(agent) }
            }
            .accessibilityIdentifier("acp-add-agent-confirm")
        } message: { agent in
            Text("The computer will run \(agent.runs).", comment: "Bridge agents: what adding an agent runs on the computer; the command")
        }
        .confirmationDialog(removing.map { String(localized: "Remove \($0.name) from the bridge?", comment: "Bridge agents: confirm taking an agent off; its name") } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible,
                            presenting: removing) { agent in
            Button(String(localized: "Remove", comment: "A to-do list: take one item off it"), role: .destructive) {
                Task { await remove(agent) }
            }
        } message: { _ in
            Text("Its chats stay on the computer, and come back if you add it again.", comment: "Bridge agents: what removing an agent keeps")
        }
    }

    private func row(_ agent: AcpRegistryAgent) -> some View {
        Button {
            asking = agent
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    if !agent.summary.isEmpty {
                        Text(agent.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text([agent.version, agent.license].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.tertiary)
                    if let needs = agent.needs, !needs.found {
                        Text("Needs \(needs.program) on the computer", comment: "Bridge agents: an agent whose program isn't installed yet; the program")
                            .font(.caption.weight(.medium)).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 8)
                if working == agent.id {
                    ProgressView()
                } else {
                    Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(.green)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(working != nil)
        .accessibilityIdentifier("acp-registry-\(agent.id)")
    }

    private func needsNote(_ needs: AcpRegistryAgent.Needs, for agent: AcpRegistryAgent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("It runs \(needs.program), which isn't on the computer yet. Install it there, then set it up:", comment: "Bridge agents: an added agent's program is missing; the program")
                .font(.subheadline)
            Text(needs.install).font(.caption.monospaced()).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: .rect(cornerRadius: 8))
            Button(String(localized: "Copy Command", comment: "Copies a command to paste on the computer")) {
                UIPasteboard.general.string = needs.install
            }
            .font(.subheadline)
        }
        .padding(.top, 4)
    }

    private func load(fresh: Bool) async {
        if registry.isEmpty { loading = true }
        defer { loading = false }
        onBridge = (try? await endpoint.agents()) ?? onBridge
        do {
            registry = try await AcpClient.client(for: endpoint).registry(fresh: fresh)
            problem = nil
        } catch {
            problem = (error as? AcpError)?.message ?? error.localizedDescription
        }
    }

    private func add(_ agent: AcpRegistryAgent) async {
        working = agent.id
        defer { working = nil }
        do {
            _ = try await AcpClient.client(for: endpoint).addAgent(agent.id)
            withAnimation { added = agent }
            await load(fresh: false)
            changed()
        } catch {
            problem = (error as? AcpError)?.message ?? error.localizedDescription
        }
    }

    private func remove(_ agent: AcpEndpoint.Agent) async {
        working = agent.id
        defer { working = nil }
        do {
            try await AcpClient.client(for: endpoint).removeAgent(agent.id)
            if added?.bridgeID == agent.id { added = nil }
            await load(fresh: false)
            changed()
        } catch {
            problem = (error as? AcpError)?.message ?? error.localizedDescription
        }
    }
}
