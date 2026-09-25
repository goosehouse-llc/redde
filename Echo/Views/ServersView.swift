import SwiftUI

/// Saved Hermes servers: switch, add, rename, remove. The active server's connection is edited
/// with the usual setup sheet, since the connection settings are its working copy.
struct ServersView: View {
    @Environment(Conversation.self) private var conversation
    @State private var settings = Settings.shared
    @State private var showSetup = false
    @State private var naming: Naming?
    @State private var nameText = ""

    /// The name prompt is for a new server or for renaming one.
    private enum Naming: Identifiable {
        case new
        case rename(UUID)
        var id: String { if case .rename(let id) = self { id.uuidString } else { "new" } }
    }

    var body: some View {
        Form {
            Section {
                ForEach(settings.servers) { server in
                    let active = server.id == settings.activeServerID
                    Button { switchTo(server.id) } label: { row(server, active: active) }
                        .accessibilityAddTraits(active ? .isSelected : [])
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { beginNaming(.rename(server.id), current: server.name) }
                        }
                        .swipeActions {
                            if !active {
                                Button("Remove", systemImage: "trash", role: .destructive) { settings.removeServer(server.id) }
                            }
                        }
                }
            } footer: {
                Text("Tap a server to switch to it; that starts a new conversation. Touch and hold to rename, swipe to remove one you're not using. Each server keeps its own addresses, keys, profile and model.")
            }

            Section {
                Button("Edit connection…", systemImage: "network") { showSetup = true }
                Button("Add server…", systemImage: "plus") { beginNaming(.new, current: "") }
            }
        }
        .navigationTitle("Servers")
        .sheet(isPresented: $showSetup) { SetupView() }
        .alert(naming.map { if case .new = $0 { "New server" } else { "Rename server" } } ?? "",
               isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name, e.g. Home or Office", text: $nameText)
            Button("Cancel", role: .cancel) { naming = nil }
            Button(naming.map { if case .new = $0 { "Add" } else { "Save" } } ?? "Save") { commitName() }
        } message: {
            if case .new = naming { Text("Then set up how Redde reaches it.") }
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
        let address = server.transport == .hermesSessions ? server.gatewayURL : server.serveURL
        let connection = server.transport == .hermesSessions ? "Hermes API" : "Hermes Dashboard"
        var parts = [connection, address.isEmpty ? "not set up" : address]
        let profile = server.hermesProfile.trimmingCharacters(in: .whitespaces)
        if !profile.isEmpty, profile.lowercased() != "default" { parts.append("profile \(profile)") }
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
