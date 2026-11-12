import SwiftUI

/// Saved Hermes servers: switch, add, rename, remove. The active server's connection is edited
/// with the usual setup sheet, since the connection settings are its working copy.
struct ServersView: View {
    @Environment(Conversation.self) private var conversation
    @State private var settings = Settings.shared
    @State private var showSetup = false
    @State private var naming: Naming?
    @State private var nameText = ""
    /// The server whose setup code is showing.
    @State private var sharing: HermesServer?

    /// The name prompt is for a new server or for renaming one.
    private enum Naming: Identifiable {
        case new
        case rename(UUID)
        var id: String { if case .rename(let id) = self { id.uuidString } else { "new" } }
    }

    var body: some View {
        Form {
            // One section per kind of agent: the Hermes servers, then the other agents (ACP).
            let groups = Self.grouped(settings.servers)
            ForEach(groups, id: \.kind) { group in
                Section {
                    ForEach(group.servers) { server in
                        let active = server.id == settings.activeServerID
                        Button { switchTo(server.id) } label: { row(server, active: active) }
                            .accessibilityAddTraits(active ? .isSelected : [])
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") { beginNaming(.rename(server.id), current: server.name) }
                                Button("Show setup code", systemImage: "qrcode") { sharing = server }
                            }
                            .swipeActions {
                                if !active {
                                    Button("Remove", systemImage: "trash", role: .destructive) { settings.removeServer(server.id) }
                                }
                            }
                    }
                } header: {
                    if groups.count > 1 { Label(group.kind.title, systemImage: group.kind.symbol) }
                } footer: {
                    if group.kind == groups.last?.kind {
                        Text("Tap a server to switch to it; that starts a new conversation. Touch and hold to rename or to show its setup code for another device, swipe to remove one you're not using. Each server keeps its own addresses, keys, profile and model.")
                    }
                }
            }

            Section {
                Button("Edit connection…", systemImage: "network") { showSetup = true }
                Button("Add server…", systemImage: "plus") { beginNaming(.new, current: "") }
            } footer: {
                Text("A new server can be filled in from a setup code: scan or paste one on its setup screen.")
            }

        }
        .navigationTitle("Servers")
        .sheet(isPresented: $showSetup) { SetupView() }
        .sheet(item: $sharing) { SetupCodeView(server: $0) }
        .alert(naming.map { if case .new = $0 { String(localized: "New server") } else { String(localized: "Rename server") } } ?? "",
               isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name, e.g. Home or Office", text: $nameText)
            Button("Cancel", role: .cancel) { naming = nil }
            Button(naming.map { if case .new = $0 { String(localized: "Add") } else { String(localized: "Save") } } ?? String(localized: "Save")) { commitName() }
        } message: {
            if case .new = naming { Text("Then set up how Redde reaches it.") }
        }
    }

    /// The servers by the kind of agent they reach, in that order, each kept in the order saved.
    static func grouped(_ servers: [HermesServer]) -> [(kind: Transport.Kind, servers: [HermesServer])] {
        Transport.Kind.allCases.compactMap { kind in
            let these = servers.filter { $0.transport.kind == kind }
            return these.isEmpty ? nil : (kind, these)
        }
    }

    private func row(_ server: HermesServer, active: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                // Explicit colors: inside a button, the hierarchical styles resolve to the tint.
                Text(server.title).foregroundStyle(Color.primary)
                Text(detail(server)).font(.footnote).foregroundStyle(Color.secondary).lineLimit(1)
            }
            Spacer()
            if active { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
        .contentShape(.rect)
    }

    /// The connection and address underneath the name, plus the profile when it isn't Default.
    private func detail(_ server: HermesServer) -> String {
        let (connection, address): (String, String) = switch server.transport {
        case .hermesSessions: ("Hermes API", server.gatewayURL)
        case .acp: (server.acpAgent.isEmpty ? "ACP" : "ACP · \(server.acpAgent)", server.acpURL)
        default: ("Hermes Dashboard", server.serveURL)
        }
        var parts = [connection, address.isEmpty ? String(localized: "not set up", comment: "A server with no address yet") : address]
        if server.transport == .hermesServe, server.serveOpenAccess, server.serveUsername.isEmpty {
            parts.append(String(localized: "no sign-in", comment: "Servers list: a Dashboard used with no sign-in, open to anyone who reaches it"))
        }
        let profile = server.hermesProfile.trimmingCharacters(in: .whitespaces)
        if !profile.isEmpty, profile.lowercased() != "default" { parts.append(String(localized: "profile \(profile)", comment: "A Hermes profile, by name")) }
        return parts.joined(separator: " · ")
    }

    private func switchTo(_ id: UUID) {
        ServerSwitcher.switchTo(id, conversation: conversation)
    }

    private func beginNaming(_ kind: Naming, current: String) {
        nameText = current
        naming = kind
    }

    private func commitName() {
        defer { naming = nil }
        switch naming {
        case .new:
            let id = settings.addServer(name: nameText)
            switchTo(id)
            showSetup = true
        case .rename(let id):
            settings.renameServer(id, to: nameText)
        case nil:
            break
        }
    }
}
