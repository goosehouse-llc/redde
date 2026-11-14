import SwiftUI

// The chat list's projects, moving chats into them, and the chats selected together.

extension ConversationsList {
    // MARK: - Projects (hermes serve groups sessions by working directory)

    var projectsSection: some View {
        Section {
            if showProjects {
            ForEach(projects) { project in
                // Value-based: a destination-based link in a split view's sidebar resolves
                // against the detail column instead of the sidebar's own stack, which pushed
                // the folder over the transcript with no way back.
                NavigationLink(value: ProjectRoute(id: project.id)) {
                    HStack(spacing: 12) {
                        Image(systemName: project.isHome ? "house.fill" : "folder.fill")
                            .foregroundStyle(project.isHome ? Color.orange : Settings.shared.resolvedTheme.accent)
                            .frame(width: 28, height: 28)
                            .background(.quaternary, in: .rect(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.label).chatFont(.body).lineLimit(1)
                            HStack(spacing: 4) {
                                Text(String(localized: "\(project.sessionCount) conversations"))
                                if let when = project.lastActive { Text("·"); Text(when, format: .relative(presentation: .named)) }
                            }
                            .chatFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .accessibilityHint("Shows this project's sessions")
                .contextMenu { projectMenu(project) }
            }
            if viaServe {
            Button {
                newProjectName = ""
                newProject = .start
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .foregroundStyle(Settings.shared.resolvedTheme.accent)
                        .frame(width: 28, height: 28)
                        .background(.quaternary, in: .rect(cornerRadius: 7))
                    Text("New Project").chatFont(.body)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Makes a project folder on your server and starts a conversation in it")
            }
            }
        } header: {
            foldingHeader(String(localized: "Projects"), count: projects.count, isOpen: $showProjects)
        }
    }

    /// A header that folds its section away and opens it again; folded, it says how many rows wait.
    func foldingHeader(_ title: String, count: Int, isOpen: Binding<Bool>) -> some View {
        FoldingHeader(title: title, count: count, isOpen: isOpen)
    }

    /// Ids of the rows currently shown, for select-all and bulk actions: folded runs aren't, nor
    /// the bots' chats (each is its bot's, changed from the bot's menu).
    var visibleIDs: Set<String> {
        usesLedger ? Set(visibleLedger.filter { (showScheduled || !Self.isFoldable($0)) && botChatRows[$0.id] == nil }.map(\.id))
                   : Set(visibleLocal.map { $0.id.uuidString })
    }

    /// A row that goes under Scheduled runs rather than among the chats: a run nobody pinned.
    static func isFoldable(_ session: HermesSessionsAPI.SessionSummary) -> Bool {
        session.isScheduledRun && session.pinned != true
    }

    var visibleLocal: [ConversationSummary] {
        store.sorted.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }

    func bulkArchive() {
        bulk(selected) { backend, id in
            try await backend.archive(id)
            if id == conversation.serverSessionID { conversation.reset() }
        }
    }

    func bulkDelete() {
        if usesLedger {
            bulk(selected) { backend, id in
                try await backend.delete(id)
                if let local = store.summaries.first(where: { $0.serverSessionID == id }) { conversation.delete(id: local.id) }
            }
        } else {
            visibleLocal.filter { selected.contains($0.id.uuidString) }.forEach { conversation.delete(id: $0.id) }
            selecting = false; selected = []
        }
    }

    /// One task, one refresh at the end: a refresh per row raced the deletes and could put
    /// removed sessions back until the next pull.
    private func bulk(_ ids: Set<String>, _ op: @escaping (SessionBackend, String) async throws -> Void) {
        selecting = false; selected = []
        // Each by its own profile's backend: with All Profiles on, they can be several.
        let rows = ledger.filter { ids.contains($0.id) }
        ledger.removeAll { ids.contains($0.id) }
        Task {
            for row in rows {
                guard let backend = SessionBackend.owning(row, conversation) else { continue }
                do { try await op(backend, row.id) } catch { ledgerError = error.localizedDescription }
            }
            await refresh()
        }
    }

    /// Export a ledger session without opening it: fetch its rows, map, write, share.
    func export(_ session: HermesSessionsAPI.SessionSummary) {
        Task {
            do {
                guard let backend = SessionBackend.owning(session, conversation) else { return }
                let messages = try await backend.messages(for: session.id)
                shareItem = ShareItem(url: try await TranscriptExporter.export(title: session.displayTitle, messages: messages))
            } catch {
                ledgerError = error.localizedDescription
            }
        }
    }

    /// "Move to Project": the projects that are folders on the server, other than the one the
    /// conversation is in, and a new one. On the Dashboard only, which is where projects are.
    @ViewBuilder
    func moveMenu(for session: HermesSessionsAPI.SessionSummary) -> some View {
        if viaServe {
            let targets = HermesServeClient.Project.moveTargets(in: folders, from: session.cwd)
            Menu("Move to Project", systemImage: "folder") {
                ForEach(targets) { project in
                    Button(project.label) { move(session, to: project) }
                }
                if !targets.isEmpty { Divider() }
                Button("New Project…", systemImage: "folder.badge.plus") {
                    newProjectName = ""
                    newProject = .move(session)
                }
            }
        }
    }

    private func move(_ session: HermesSessionsAPI.SessionSummary, to project: HermesServeClient.Project) {
        guard let path = project.path else { return }
        Task {
            do {
                try await moveSession(session, to: path)
            } catch {
                ledgerError = String(localized: "Couldn't move it to \(project.label): \(error.localizedDescription)")
            }
        }
    }

    private func moveSession(_ session: HermesSessionsAPI.SessionSummary, to path: String) async throws {
        let client = HermesServeClient.shared
        try await client.moveSession(stored: session.id, toFolder: path)
        // The open conversation's header names its project: have the server say the new one.
        if session.id == conversation.serverSessionID { _ = try? await client.chatControls(stored: session.id) }
        await refresh()
    }

    // MARK: - Making and keeping projects

    /// A project row's menu: a conversation in it, and for a project someone made, its name and
    /// its place on the list.
    @ViewBuilder
    private func projectMenu(_ project: HermesServeClient.Project) -> some View {
        if project.path != nil, !project.isHome {
            Button("New Conversation", systemImage: "square.and.pencil") { startNew(in: project) }
        }
        if project.isOwn {
            Button("Rename", systemImage: "pencil") {
                projectRenameText = project.label
                projectRenaming = project
            }
            Divider()
            Button("Remove Project", systemImage: "folder.badge.minus", role: .destructive) { projectRemoving = project }
        }
    }

    func startNew(in project: HermesServeClient.Project) {
        guard let path = project.path, !project.isHome else { return }
        conversation.startNew(in: ProjectPlace(name: project.label, path: path))
        opened()
    }

    /// Makes the project named in the prompt; then starts a conversation in it, or moves the one
    /// whose menu asked into it.
    func makeProject() {
        let name = newProjectName
        let purpose = newProject
        newProject = nil
        Task {
            do {
                let place = try await HermesServeClient.shared.createProject(named: name)
                if case let .move(session) = purpose {
                    try await moveSession(session, to: place.path)
                } else {
                    conversation.startNew(in: place)
                    opened()
                    await refresh()
                }
            } catch {
                ledgerError = String(localized: "Couldn't make the project: \(ServerFiles.explain(error))")
            }
        }
    }

    func renameProject(_ project: HermesServeClient.Project, to name: String) {
        projectRenaming = nil
        Task {
            do {
                try await HermesServeClient.shared.renameProject(project.id, to: name)
                // The open conversation's header names its project.
                if let open = conversation.serverSessionID { _ = try? await HermesServeClient.shared.chatControls(stored: open) }
                await refresh()
            } catch {
                ledgerError = String(localized: "Couldn't rename \(project.label): \(error.localizedDescription)")
            }
        }
    }

    func removeProject(_ project: HermesServeClient.Project) {
        projectRemoving = nil
        Task {
            do {
                try await HermesServeClient.shared.removeProject(project.id)
                if let open = conversation.serverSessionID { _ = try? await HermesServeClient.shared.chatControls(stored: open) }
                await refresh()
            } catch {
                ledgerError = String(localized: "Couldn't remove \(project.label): \(error.localizedDescription)")
            }
        }
    }
}
