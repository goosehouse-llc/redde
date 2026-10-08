import SwiftUI

/// Settings → Gateway: the Hermes server itself. What is running and what it is connected to,
/// its MCP servers, its logs, and restarting or updating it, through the Dashboard's own
/// administration routes (`GatewayAdmin.swift`).
struct GatewayView: View {
    @State private var model: GatewayModel
    @State private var confirming: GatewayModel.Work?
    @Environment(\.theme) private var theme

    init(source: (any GatewayAdministering)? = nil) {
        _model = State(initialValue: GatewayModel(source: source ?? Self.defaultSource))
    }

    /// The server Settings is about, or sample data for a look at the screen.
    static var defaultSource: any GatewayAdministering {
        #if DEBUG
        if DevHooks.demoGateway { return DemoGateway() }
        #endif
        return HermesServeClient.shared
    }

    var body: some View {
        List {
            if let status = model.status {
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange).listRowSeparator(.hidden)
                }
                statusSection(status)
                if !status.platforms.isEmpty { connectionsSection(status) }
                serversSection
                Section {
                    NavigationLink { GatewayLogView(source: model.source) } label: { Label("Logs", systemImage: "text.alignleft") }
                }
                maintenanceSection(status)
            } else if let problem = model.problem {
                ContentUnavailableView("Couldn't reach the gateway", systemImage: "wifi.exclamationmark", description: Text(problem))
                    .listRowSeparator(.hidden)
            } else {
                ProgressView("Loading from Redde…")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Gateway")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .confirmationDialog(confirming == .updating ? "Update Hermes?" : "Restart the gateway?",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { work in
            Button(work == .updating ? "Update Hermes" : "Restart", role: .destructive) {
                Task { if work == .updating { await model.applyUpdate() } else { await model.restart() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { work in
            Text(work == .updating ? Self.updateWarning(model.update, host: model.host) : Self.restartWarning(turns: model.status?.activeTurns ?? 0))
        }
    }

    // MARK: Status

    private func statusSection(_ status: GatewayStatus) -> some View {
        Section {
            LabeledContent("Hermes", value: [status.version, status.releaseDate].filter { !$0.isEmpty }.joined(separator: " · "))
            LabeledContent("Gateway") {
                HStack(spacing: 6) {
                    Circle().fill(status.gatewayRunning ? Color.green : Color.red).frame(width: 8, height: 8)
                    Text(status.gatewayLabel)
                }
            }
            .accessibilityElement(children: .combine)
            if !status.gatewayRunning, let reason = status.exitReason {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }
            if status.activeTurns > 0 {
                LabeledContent("Turns running", value: "\(status.activeTurns)")
            }
            if let host = model.host {
                if !host.hostname.isEmpty { LabeledContent("Host", value: host.hostname) }
                if !host.system.isEmpty { LabeledContent("System", value: host.system) }
                if let up = host.uptimeLabel { LabeledContent("Up for", value: up) }
                if let memory = host.memoryPercent { LabeledContent("Memory in use", value: Self.percent(memory)) }
                if let disk = host.diskPercent { LabeledContent("Disk in use", value: Self.percent(disk)) }
            }
            ForEach(status.troubles) { trouble in
                Label("\(trouble.id.capitalized): \(trouble.status)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Status")
        }
    }

    private func connectionsSection(_ status: GatewayStatus) -> some View {
        Section {
            ForEach(status.platforms) { platform in
                VStack(alignment: .leading, spacing: 3) {
                    LabeledContent(platform.title) {
                        Text(platform.state.replacingOccurrences(of: "_", with: " ").capitalized)
                            .foregroundStyle(platform.isConnected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    }
                    if let error = platform.error {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Connections")
        } footer: {
            Text("What the gateway is connected to. Messaging platforms are set up on the Hermes host.")
        }
    }

    // MARK: MCP servers

    private var serversSection: some View {
        Section {
            if model.servers.isEmpty {
                Text("No MCP servers are set up on this Hermes.").foregroundStyle(.secondary)
            }
            ForEach(model.servers) { server in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(server.name)
                        Spacer()
                        if server.plugin == nil {
                            Toggle(server.name, isOn: Binding(get: { server.enabled }, set: { on in Task { await model.setServer(server, enabled: on) } }))
                                .labelsHidden()
                                .disabled(model.busy.contains(server.name))
                        }
                    }
                    if !server.target.isEmpty {
                        Text(server.target).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if let plugin = server.plugin {
                        Text("From the plugin \(plugin); switched with it.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button("Test") { Task { await model.test(server) } }
                            .buttonStyle(.borderless)
                            .font(.footnote.weight(.medium))
                            .disabled(model.busy.contains(server.name))
                            .accessibilityLabel("Test \(server.name)")
                        if model.busy.contains(server.name) { ProgressView().controlSize(.mini) }
                        if let probe = model.probes[server.name] {
                            Text(probe.summary).font(.footnote).foregroundStyle(probe.ok ? Color.secondary : Color.orange).lineLimit(3)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("MCP servers")
        } footer: {
            Text("A switch changes Hermes's config, as the Dashboard's own does. It takes effect in new conversations. Test has Hermes connect to the server and list its tools.")
        }
    }

    // MARK: Restart and update

    @ViewBuilder
    private func maintenanceSection(_ status: GatewayStatus) -> some View {
        Section {
            if let work = model.work {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(work == .updating ? "Updating Hermes…" : "Restarting the gateway…")
                    }
                    if !model.progress.isEmpty {
                        Text(model.progress.joined(separator: "\n")).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(4)
                    }
                    if work == .updating {
                        Text("Hermes restarts on the way and answers nothing for a while. This can take a few minutes.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else {
                Button("Restart Gateway…") { confirming = .restarting }
                if status.canUpdate {
                    Button {
                        Task { await model.checkForUpdate() }
                    } label: {
                        HStack {
                            Text("Check for Updates")
                            Spacer()
                            if model.checkingUpdate { ProgressView() }
                        }
                    }
                    .disabled(model.checkingUpdate)
                    if let update = model.update {
                        LabeledContent("Hermes \(update.currentVersion)", value: update.summary)
                        if update.available, update.canApply {
                            Button("Update Hermes…") { confirming = .updating }
                        } else if update.available, !update.command.isEmpty {
                            Text("Update it on the host: \(update.command)").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let outcome = model.outcome {
                Label(outcome.text, systemImage: outcome.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(outcome.ok ? Color.green : Color.red)
                    .font(.footnote)
            }
        } header: {
            Text("Maintenance")
        } footer: {
            Text(status.canUpdate
                 ? "Restarting stops whatever the gateway is in the middle of. Updating runs hermes update on the host and restarts Hermes."
                 : "Restarting stops whatever the gateway is in the middle of. This Hermes is updated outside its Dashboard (a container or a package manager), so there is no update here.")
        }
    }

    // MARK: Words

    nonisolated static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    nonisolated static func restartWarning(turns: Int) -> String {
        let cut = "Replies in progress over the Hermes API and on the messaging platforms are stopped, and the gateway is away for a few seconds."
        return turns > 0 ? "\(turns) turn\(turns == 1 ? " is" : "s are") running now. " + cut : cut
    }

    nonisolated static func updateWarning(_ update: HermesUpdate?, host: HostStats?) -> String {
        let place = host.flatMap { $0.hostname.isEmpty ? nil : " on \($0.hostname)" } ?? ""
        let size = update?.behind.map { $0 > 0 ? ", \($0) change\($0 == 1 ? "" : "s")," : "" } ?? ""
        return "This runs hermes update\(place)\(size) and restarts Hermes. Everything it is doing stops, and changes made by hand to Hermes's own code there can be lost."
    }
}

/// The server's log files, newest line last, as `hermes logs` shows them.
struct GatewayLogView: View {
    let source: any GatewayAdministering
    @State private var file = GatewayLog.agent
    @State private var level = GatewayLog.Level.all
    @State private var search = ""
    @State private var lines: [String] = []
    @State private var loading = true
    @State private var problem: String?

    private struct Query: Equatable {
        var file: GatewayLog
        var level: GatewayLog.Level
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    } else if lines.isEmpty, !loading {
                        Text(search.isEmpty ? "Nothing in this log." : "No line matches.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Self.colour(of: line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .textSelection(.enabled)
            }
            .onChange(of: lines) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Log", selection: $file) {
                ForEach(GatewayLog.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .overlay { if loading, lines.isEmpty { ProgressView() } }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search this log")
        .onSubmit(of: .search) { Task { await load() } }
        .onChange(of: search) { _, now in if now.isEmpty { Task { await load() } } }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Show", selection: $level) {
                        ForEach(GatewayLog.Level.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Label("Filter", systemImage: level == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                ShareLink(item: lines.joined(separator: "\n")) { Label("Share", systemImage: "square.and.arrow.up") }
                    .disabled(lines.isEmpty)
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
            }
        }
        .task(id: Query(file: file, level: level)) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            lines = try await source.gatewayLogs(file, lines: GatewayLog.mostLines, level: level, search: search)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private static func colour(of line: String) -> Color {
        switch GatewayLog.level(of: line) {
        case .error: .red
        case .warning: .orange
        case .all: .primary
        }
    }
}
