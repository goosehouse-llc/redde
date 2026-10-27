import SwiftUI

/// The server's projects that are a folder, as last fetched: what a conversation can be added to
/// from its ••• menu. Fetched again whenever the chat list's are, and when a conversation opens.
@Observable
final class ProjectDirectory {
    static let shared = ProjectDirectory()

    private(set) var folders: [HermesServeClient.Project] = []
    /// The connection they are from (`Settings.connectionKey`).
    private(set) var key = ""

    func set(_ all: [HermesServeClient.Project], key: String) {
        folders = all.filter { $0.path?.isEmpty == false && !$0.isHome }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        self.key = key
    }

    func refresh(settings: Settings = .shared) async {
        guard settings.transport == .hermesServe, HermesServeClient.shared.hasCredentials else { return }
        let key = settings.connectionKey
        guard let all = try? await HermesServeClient.shared.projectTree(), key == settings.connectionKey else { return }
        set(all, key: key)
    }
}

/// "Add to Project" in a chat's ••• menu, on the Dashboard: the projects there are, but the one
/// the conversation is in, and a new one. Adding it moves its working folder to the project's,
/// as the chat list's "Move to Project" does.
struct ChatProjectMenu: View {
    @Environment(Conversation.self) private var conversation
    @Binding var naming: Bool
    @Binding var problem: String?
    @State private var directory = ProjectDirectory.shared
    @State private var settings = Settings.shared

    var body: some View {
        let current = ChatControlStore.shared.project(for: conversation.serverSessionID)?.name
        let targets = directory.key == settings.connectionKey ? directory.folders.filter { $0.label != current } : []
        Menu(current == nil ? String(localized: "Add to Project") : String(localized: "Move to Project"), systemImage: "folder") {
            ForEach(targets) { project in
                Button(project.label) {
                    guard let stored = conversation.serverSessionID, let path = project.path else { return }
                    Task {
                        do { try await ChatProjectPrompt.move(stored, to: path) } catch {
                            problem = String(localized: "Couldn't move it to \(project.label): \(error.localizedDescription)")
                        }
                    }
                }
            }
            if !targets.isEmpty { Divider() }
            Button("New Project…", systemImage: "folder.badge.plus") { naming = true }
        }
    }
}

/// What "Add to Project" needs beside the menu: the New Project prompt, a failure's alert, and the
/// projects fetched for the menu while a Dashboard conversation is open.
struct ChatProjectPrompt: ViewModifier {
    @Environment(Conversation.self) private var conversation
    @Binding var naming: Bool
    @Binding var problem: String?
    @State private var name = ""
    @State private var settings = Settings.shared

    func body(content: Content) -> some View {
        content
            .alert("New Project", isPresented: $naming) {
                TextField("Name", text: $name)
                Button("Create") { create() }
                    .disabled(HermesServeClient.projectFolderName(for: name) == nil)
                Button("Cancel", role: .cancel) { name = "" }
            } message: {
                Text("A folder of that name is made in ~/Projects on your server, and this conversation works in it from now on.")
            }
            .alert("Couldn't add it to a project", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
            .task(id: "\(settings.connectionKey)|\(conversation.serverSessionID ?? "")") {
                if settings.transport == .hermesServe, conversation.serverSessionID != nil { await ProjectDirectory.shared.refresh() }
            }
    }

    private func create() {
        let typed = name
        name = ""
        guard let stored = conversation.serverSessionID else { return }
        Task {
            do {
                let place = try await HermesServeClient.shared.createProject(named: typed)
                try await Self.move(stored, to: place.path)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// Moves a conversation into a project's folder; the header then names the project.
    static func move(_ stored: String, to path: String) async throws {
        let client = HermesServeClient.shared
        try await client.moveSession(stored: stored, toFolder: path)
        _ = try? await client.chatControls(stored: stored)
        await ProjectDirectory.shared.refresh()
    }
}
