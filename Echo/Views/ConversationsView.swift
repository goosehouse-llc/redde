import SwiftUI

/// Previous sessions. With the ledger transport this is Hermes's own session list, every
/// platform included. Tap to resume, swipe to delete.
/// The iPhone's panel from the left (opening a conversation closes it). On iPad the list lives
/// in the split view's sidebar instead.
struct ConversationsView: View {
    /// The panel stays built while closed, so it slides in without a hitch; this says whether
    /// it's out.
    var isShowing: Bool
    var onOpened: () -> Void
    var body: some View {
        NavigationStack {
            ConversationsList(onOpened: onOpened, isShowing: isShowing)
        }
    }
}

/// Identifies the project a sidebar row pushes to. A dedicated type rather than the bare id,
/// so the destination can't collide with another String route in the same stack.
private struct ProjectRoute: Hashable {
    let id: String
}

struct ConversationsList: View {
    /// What to do after a session opens: the iPhone's panel closes; the iPad sidebar stays put.
    var onOpened: () -> Void = {}
    /// False while the iPhone's panel is closed: Chats and Cron refresh when it opens again.
    /// (The Kanban board and its live socket go away once the panel has slid out: `panelParked`.)
    var isShowing = true
    @Environment(Conversation.self) private var conversation
    @Environment(\.sidePanelParked) private var panelParked
    @State private var store = ConversationStore.shared
    @State private var settings = Settings.shared
    @State private var drafts = Drafts.shared
    @State private var ledger: [HermesSessionsAPI.SessionSummary] = []
    @State private var ledgerError: String?
    @State private var loading = false
    @State private var opening: String?
    /// A conversation the server wouldn't hand over just now, of which this iPhone has a copy.
    @State private var savedCopyOffered: UUID?
    @State private var query = ""
    @State private var renaming: HermesSessionsAPI.SessionSummary?
    @State private var renameText = ""
    @State private var usageFor: HermesSessionsAPI.SessionSummary?
    @State private var projects: [HermesServeClient.Project] = []
    /// Every project that is a folder, with or without conversations: where one can be moved to.
    @State private var folders: [HermesServeClient.Project] = []
    /// The New Project prompt, and what the project is for once made.
    @State private var newProject: NewProject?
    @State private var newProjectName = ""
    @State private var projectRenaming: HermesServeClient.Project?
    @State private var projectRenameText = ""
    @State private var projectRemoving: HermesServeClient.Project?
    @AppStorage("sessions.showProjects") private var showProjects = true
    @State private var shareItem: ShareItem?
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var confirmBulkDelete = false
    @State private var showSettings = false
    /// Pinned first, then most recent; filtered by the search field. Cached: the body reads it
    /// several times per pass and every keystroke in the search field would repeat the sort.
    @State private var visibleLedger: [HermesSessionsAPI.SessionSummary] = []

    private var usesLedger: Bool { settings.transport.hasLedger }
    private var viaServe: Bool { settings.transport == .hermesServe }

    /// A project being made: to start a conversation in, or to move one into.
    private enum NewProject {
        case start
        case move(HermesSessionsAPI.SessionSummary)
    }

    /// Sessions, scheduled jobs, or the kanban board; the latter two live on the gateway.
    enum Tab: String, CaseIterable, Identifiable {
        case sessions, cron, kanban
        var id: String { rawValue }
        var title: String { switch self { case .sessions: "Chats"; case .cron: "Cron"; case .kanban: "Kanban" } }
        var icon: String { switch self { case .sessions: "bubble.left.and.bubble.right"; case .cron: "clock"; case .kanban: "rectangle.split.3x1" } }
    }
    /// Chats, Cron or Kanban: kept across launches, and shared with the iPad's detail pane.
    @AppStorage(Self.sectionKey) private var section: Tab = .sessions
    static let sectionKey = "conversations.section"

    /// On iPad the list stays in the sidebar and the switcher picks what the wide pane beside it
    /// shows: the chat, the cron jobs or the Kanban board (ContentView). Here it's always the chats.
    var wideDetail = false

    /// The bar's title. "Conversations" over the chats; Cron and Kanban name themselves.
    /// On iPad from iPadOS 27 the sidebar's title is no longer drawn large under the bar but in
    /// it, beside four buttons, where "Conversations" was cut to "Conversa…". There it is
    /// "Chats": what the sidebar lists, whichever section the wide pane shows. And nothing while
    /// selecting, when Cancel and Deselect all need the room.
    private var listTitle: String {
        if #available(iOS 27.0, *), wideDetail { return selecting ? "" : "Chats" }
        return section == .sessions || wideDetail ? "Conversations" : section.title
    }

    /// A conversation opened (or a new one started): on iPad, the chat takes the wide pane again.
    private func opened() {
        if wideDetail { section = .sessions }
        onOpened()
    }

    var body: some View {
        Group {
            switch wideDetail ? .sessions : section {
            case .sessions: sessionsList
            // Rebuilt on a server or profile switch, so nothing (or no live socket) carries over.
            case .cron: CronView(topRow: AnyView(topRow), isShowing: isShowing).id(settings.connectionKey)
            case .kanban:
                // Gone once the panel has slid out (not as it starts to), taking its live socket along.
                if !panelParked { KanbanView(topRow: AnyView(topRow)).id(settings.connectionKey) } else { Color.clear }
            }
        }
        // From inside the navigation stack: hiding the whole panel doesn't reach UIKit's list,
        // and VoiceOver could swipe into rows parked off screen.
        .accessibilityHidden(panelParked)
        .navigationTitle(listTitle)
        .toolbarVisibility(panelParked ? .hidden : .automatic, for: .navigationBar)
        .navigationBarTitleDisplayMode(section == .sessions || wideDetail ? .large : .inline)
        #if DEBUG
        // Dev hook: `-echo.section cron|kanban` opens on that tab (screenshots).
        .onAppear { if let tab = DevHooks.value("-echo.section").flatMap(Tab.init(rawValue:)) { section = tab } }
        #endif
        .sheet(isPresented: $showSettings) { SettingsView() }
        .background {
            Group {
                Button("Sessions") { section = .sessions }.keyboardShortcut("1", modifiers: .command)
                Button("Cron") { section = .cron }.keyboardShortcut("2", modifiers: .command)
                Button("Kanban") { section = .kanban }.keyboardShortcut("3", modifiers: .command)
            }
            .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }

    /// Switch servers without going through Settings.
    private var serverMenu: some View {
        Menu {
            Picker("Server", selection: Binding(
                get: { settings.activeServerID },
                set: { ServerSwitcher.switchTo($0, conversation: conversation) })) {
                ForEach(settings.servers) { server in Text(server.title).tag(server.id) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                Text(settings.activeServer?.title ?? "").lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("Server")
        .accessibilityValue(settings.activeServer?.title ?? "")
    }

    /// The server switch (once there's more than one) and Chats, Cron and Kanban, as the first
    /// row of whichever list is showing: they move with it when you pull to refresh or scroll.
    /// Full width: in the bar, next to Settings, Select and New, they were squeezed to "Kanb…".
    private var topRow: some View {
        VStack(spacing: 8) {
            // Not on the OpenAI-compatible connection, which belongs to no server (as in Settings).
            if settings.servers.count > 1, settings.transport != .chatCompletions { serverMenu }
            sectionPicker
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .selectionDisabled()
        .accessibilityHidden(panelParked)   // UIKit's segmented control ignores it from further out
    }

    private var sectionPicker: some View {
        // Through its own binding, not `$section`: with the stored one, the first tap after the
        // panel opened blinked and didn't switch (seen on device, never in the simulator).
        Picker("Section", selection: Binding(get: { section }, set: { section = $0 })) {
            ForEach(Tab.allCases) { s in Text(s.title).tag(s) }
        }
        .pickerStyle(.segmented)
    }

    private var sessionsList: some View {
        // The selection binding belongs to "Select" mode only. A sidebar List that always has
        // one treats a row tap as selection and swallows the NavigationLink, so project folders
        // never push on iPad.
        List(selection: selecting ? $selected : nil) {
            topRow
            if query.isEmpty, !selecting { waitingNotesSection }
            if usesLedger {
                if viaServe, query.isEmpty, !selecting { projectsSection }
                ledgerSection
            } else {
                localSection
            }
        }
        .listStyle(.plain)
        .navigationDestination(for: ProjectRoute.self) { route in
            if let project = projects.first(where: { $0.id == route.id }) {
                ProjectSessionsView(project: project, open: load, currentID: conversation.serverSessionID,
                                    startNew: { startNew(in: $0) })
            }
        }
        .environment(\.editMode, .constant(selecting ? .active : .inactive))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if selecting {
                    Button("Cancel") { selecting = false; selected = [] }
                } else {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if selecting {
                    Button(selected.count == visibleIDs.count ? "Deselect all" : "Select all") {
                        selected = selected.count == visibleIDs.count ? [] : visibleIDs
                    }
                } else {
                    if !visibleIDs.isEmpty {
                        Button("Select", systemImage: "checkmark.circle") { selecting = true }
                    }
                    Button("New conversation", systemImage: "square.and.pencil") {
                        conversation.reset()
                        opened()
                    }
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if selecting {
                    if usesLedger {
                        Button("Archive \(selected.count)", systemImage: "archivebox") { bulkArchive() }.disabled(selected.isEmpty)
                        Spacer()
                    }
                    Button("Delete \(selected.count)", systemImage: "trash", role: .destructive) { confirmBulkDelete = true }
                        .disabled(selected.isEmpty)
                }
            }
        }
        .confirmationDialog("Delete \(selected.count) conversation\(selected.count == 1 ? "" : "s")?", isPresented: $confirmBulkDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { bulkDelete() }
        } message: {
            Text(usesLedger ? "They are removed from the Redde ledger for every client." : "This only removes them from this phone.")
        }
        .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search conversations")
        // Keyed on the server and profile: a switch reloads the list (and the iPad sidebar,
        // which stays up).
        // Not while the iPhone's panel is closed: it loads when it opens (isShowing below).
        .task(id: settings.connectionKey) { if usesLedger, isShowing { await refresh() } }
        .onChange(of: settings.connectionKey) {
            // The old server's or profile's sessions must not linger while the new list loads.
            ledger = []
            projects = []
            ledgerError = nil
            selecting = false
            selected = []
        }
        .refreshable { if usesLedger { await refresh() } }
        .onChange(of: isShowing) { _, showing in
            if showing, usesLedger { Task { await refresh() } }
        }
        .onChange(of: query, initial: true) { filterLedger() }
        .onChange(of: ledger) { filterLedger() }
        .sheet(item: $usageFor) { SessionUsageView(session: $0) }
        .alert("Rename session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") { if let s = renaming { rename(s, to: renameText) } }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("New Project", isPresented: Binding(get: { newProject != nil }, set: { if !$0 { newProject = nil } })) {
            TextField("Name", text: $newProjectName)
            Button("Create") { makeProject() }
                .disabled(HermesServeClient.projectFolderName(for: newProjectName) == nil)
            Button("Cancel", role: .cancel) { newProject = nil }
        } message: {
            Text("A folder of that name is made in ~/Projects on your server. The project's conversations work in it.")
        }
        .alert("Rename project", isPresented: Binding(get: { projectRenaming != nil }, set: { if !$0 { projectRenaming = nil } })) {
            TextField("Name", text: $projectRenameText)
            Button("Save") { if let p = projectRenaming { renameProject(p, to: projectRenameText) } }
            Button("Cancel", role: .cancel) { projectRenaming = nil }
        } message: {
            Text("Its folder keeps its name.")
        }
        .confirmationDialog("Remove “\(projectRemoving?.label ?? "")” from Projects?",
                            isPresented: Binding(get: { projectRemoving != nil }, set: { if !$0 { projectRemoving = nil } }),
                            titleVisibility: .visible) {
            Button("Remove Project", role: .destructive) { if let p = projectRemoving { removeProject(p) } }
        } message: {
            Text("Its folder and its conversations stay on the server. The conversations just aren't grouped under it any more.")
        }
    }

    private func filterLedger() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? ledger : ledger.filter {
            $0.displayTitle.lowercased().contains(q) || ($0.preview ?? "").lowercased().contains(q) || $0.sourceLabel.lowercased().contains(q)
        }
        visibleLedger = filtered.sorted { a, b in
            if (a.pinned ?? false) != (b.pinned ?? false) { return a.pinned ?? false }
            return (a.lastActiveDate ?? .distantPast) > (b.lastActiveDate ?? .distantPast)
        }
    }

    // MARK: - Projects (hermes serve groups sessions by working directory)

    private var projectsSection: some View {
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
                            Text(project.label).font(.body).lineLimit(1)
                            HStack(spacing: 4) {
                                Text("\(project.sessionCount) conversation\(project.sessionCount == 1 ? "" : "s")")
                                if let when = project.lastActive { Text("·"); Text(when, format: .relative(presentation: .named)) }
                            }
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .accessibilityHint("Shows this project's sessions")
                .contextMenu { projectMenu(project) }
            }
            Button {
                newProjectName = ""
                newProject = .start
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .foregroundStyle(Settings.shared.resolvedTheme.accent)
                        .frame(width: 28, height: 28)
                        .background(.quaternary, in: .rect(cornerRadius: 7))
                    Text("New Project").font(.body)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Makes a project folder on your server and starts a conversation in it")
            }
        } header: {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showProjects.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Projects")
                    if !showProjects {
                        Text("\(projects.count)").font(.caption2.weight(.semibold)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showProjects ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showProjects ? "Hide projects" : "Show projects")
            .accessibilityAddTraits(.isHeader)
        }
    }

    /// Ids of the rows currently shown, for select-all and bulk actions.
    private var visibleIDs: Set<String> {
        usesLedger ? Set(visibleLedger.map(\.id)) : Set(visibleLocal.map { $0.id.uuidString })
    }

    private var visibleLocal: [ConversationSummary] {
        store.sorted.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func bulkArchive() {
        bulk(selected) { backend, id in
            try await backend.archive(id)
            if id == conversation.serverSessionID { conversation.reset() }
        }
    }

    private func bulkDelete() {
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
        ledger.removeAll { ids.contains($0.id) }
        Task {
            guard let backend = SessionBackend.current(conversation) else { return }
            for id in ids {
                do { try await op(backend, id) } catch { ledgerError = error.localizedDescription }
            }
            await refresh()
        }
    }

    /// Export a ledger session without opening it: fetch its rows, map, write, share.
    private func export(_ session: HermesSessionsAPI.SessionSummary) {
        Task {
            do {
                guard let backend = SessionBackend.current(conversation) else { return }
                let messages = try await backend.messages(for: session.id)
                shareItem = ShareItem(url: try await TranscriptExporter.export(title: session.displayTitle, messages: messages))
            } catch {
                ledgerError = error.localizedDescription
            }
        }
    }

    // MARK: - Ledger (gateway)

    @ViewBuilder
    private var ledgerSection: some View {
        if let ledgerError, ledger.isEmpty {
            ConnectionProblemCard(message: ledgerError,
                                  retry: { Task { await refresh() } },
                                  openSettings: { showSettings = true })
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            // The server can't be reached: what this iPhone kept of its conversations can still be read.
            savedCopiesSection
        } else if let ledgerError {
            // A failed rename/pin/delete must not blank the loaded list; show it inline.
            Label(ledgerError, systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(.orange).listRowSeparator(.hidden)
            if let id = savedCopyOffered, let copy = store.summaries.first(where: { $0.id == id }) {
                Button("Open the copy on this iPhone, from \(DateGroup.rowTime(copy.updatedAt))", systemImage: "internaldrive") { openSaved(copy) }
                    .font(.footnote)
                    .listRowSeparator(.hidden)
            }
        } else if ledger.isEmpty && !loading {
            ContentUnavailableView("No conversations yet", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Conversations from every platform appear here."))
                .listRowSeparator(.hidden)
        }
        let rows = visibleLedger
        let pinned = rows.filter { $0.pinned == true }
        let drafted = draftedSessions
        if !pinned.isEmpty {
            Section { ForEach(pinned) { ledgerButton($0, hasDraft: drafted.contains($0.id)) } } header: { groupHeader("Pinned") }
        }
        ForEach(DateGroup.group(rows.filter { $0.pinned != true }, by: { $0.lastActiveDate }), id: \.title) { group in
            Section { ForEach(group.items) { ledgerButton($0, hasDraft: drafted.contains($0.id)) } } header: { groupHeader(group.title) }
        }
    }

    /// Quick capture's notes that haven't reached the server yet (`CaptureInbox`): shown until
    /// they have, so that a note is never somewhere nobody can see it. A swipe throws one away.
    @ViewBuilder
    private var waitingNotesSection: some View {
        let notes = CaptureInbox.shared.waiting
        if !notes.isEmpty {
            Section {
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.text).lineLimit(3)
                        Text(DateGroup.rowTime(note.at)).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .selectionDisabled()
                    .swipeActions { Button("Delete", role: .destructive) { CaptureInbox.shared.remove(note.id) } }
                }
            } header: {
                groupHeader("Notes waiting to be sent")
            } footer: {
                Text("Filed as soon as your server can be reached, in a chat called Notes.")
            }
        }
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func ledgerButton(_ session: HermesSessionsAPI.SessionSummary, hasDraft: Bool) -> some View {
        Button { if !selecting { open(session) } } label: { ledgerRow(session, hasDraft: hasDraft) }
            .buttonStyle(.plain)
            .opensConversation()
            .tag(session.id)
            .listRowBackground(session.id == conversation.serverSessionID ? Settings.shared.resolvedTheme.accent.opacity(0.08) : nil)
            .disabled(opening != nil)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { setPinned(session, !(session.pinned ?? false)) } label: {
                    Label(session.pinned == true ? "Unpin" : "Pin", systemImage: session.pinned == true ? "pin.slash" : "pin")
                }
                .tint(.orange)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { delete(session) } label: { Label("Delete", systemImage: "trash") }
                Button { archive(session) } label: { Label("Archive", systemImage: "archivebox") }
                    .tint(.gray)
            }
            .contextMenu {
                Button("Usage & cost", systemImage: "chart.bar") { usageFor = session }
                Button("Rename", systemImage: "pencil") { renameText = session.title ?? ""; renaming = session }
                Button(session.pinned == true ? "Unpin" : "Pin", systemImage: "pin") { setPinned(session, !(session.pinned ?? false)) }
                Button("Fork", systemImage: "arrow.triangle.branch") { fork(session) }
                moveMenu(for: session)
                Button("Export as Markdown", systemImage: "square.and.arrow.up") { export(session) }
                Button("Archive", systemImage: "archivebox") { archive(session) }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { delete(session) }
            }
    }

    /// "Move to Project": the projects that are folders on the server, other than the one the
    /// conversation is in, and a new one. On the Dashboard only, which is where projects are.
    @ViewBuilder
    private func moveMenu(for session: HermesSessionsAPI.SessionSummary) -> some View {
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
                ledgerError = "Couldn't move it to \(project.label): \(error.localizedDescription)"
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

    private func startNew(in project: HermesServeClient.Project) {
        guard let path = project.path, !project.isHome else { return }
        conversation.startNew(in: ProjectPlace(name: project.label, path: path))
        opened()
    }

    /// Makes the project named in the prompt; then starts a conversation in it, or moves the one
    /// whose menu asked into it.
    private func makeProject() {
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
                ledgerError = "Couldn't make the project: \(ServerFiles.explain(error))"
            }
        }
    }

    private func renameProject(_ project: HermesServeClient.Project, to name: String) {
        projectRenaming = nil
        Task {
            do {
                try await HermesServeClient.shared.renameProject(project.id, to: name)
                // The open conversation's header names its project.
                if let open = conversation.serverSessionID { _ = try? await HermesServeClient.shared.chatControls(stored: open) }
                await refresh()
            } catch {
                ledgerError = "Couldn't rename \(project.label): \(error.localizedDescription)"
            }
        }
    }

    private func removeProject(_ project: HermesServeClient.Project) {
        projectRemoving = nil
        Task {
            do {
                try await HermesServeClient.shared.removeProject(project.id)
                if let open = conversation.serverSessionID { _ = try? await HermesServeClient.shared.chatControls(stored: open) }
                await refresh()
            } catch {
                ledgerError = "Couldn't remove \(project.label): \(error.localizedDescription)"
            }
        }
    }

    private func ledgerRow(_ session: HermesSessionsAPI.SessionSummary, hasDraft: Bool) -> some View {
        rowBody(session, hasDraft: hasDraft)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens this session")
    }

    /// Title and when on the first line, the last thing said beneath; where it came from when
    /// it wasn't this app.
    private func rowBody(_ session: HermesSessionsAPI.SessionSummary, hasDraft: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if session.pinned == true {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange).accessibilityLabel("Pinned")
                }
                Text(session.displayTitle).font(.body.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                if opening == session.id {
                    ProgressView().controlSize(.small)
                } else if let when = session.lastActiveDate {
                    Text(DateGroup.rowTime(when)).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                if hasDraft { draftMark }
                if let source = session.source, !["api_server", "api-server"].contains(source) {
                    Text(session.sourceLabel)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }
                Text(session.preview?.nilIfEmpty ?? session.message_count.map { "\($0) messages" } ?? " ")
                    .lineLimit(1)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// "Draft", in front of a row's second line: something was written there and not sent.
    private var draftMark: some View {
        Text("Draft")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Settings.shared.resolvedTheme.accent)
            .accessibilityLabel("Has a draft")
    }

    /// The server conversations with a draft waiting, by their id on the server. Drafts are kept
    /// by a conversation's id on this iPhone; the server's list knows only its own.
    private var draftedSessions: Set<String> {
        Self.drafted(drafts.waiting, in: store.summaries)
    }

    static func drafted(_ waiting: Set<String>, in summaries: [ConversationSummary]) -> Set<String> {
        guard !waiting.isEmpty else { return [] }
        return Set(summaries.filter { waiting.contains($0.id.uuidString) }.compactMap(\.serverSessionID))
    }

    private func refresh() async {
        loading = true
        defer { loading = false }
        // An answer from before a server or profile switch belongs to the old list: drop it.
        let key = settings.connectionKey
        var current: Bool { key == settings.connectionKey && !Task.isCancelled }
        #if DEBUG
        // Dev hook: `-echo.demoProjects` fills the list from a fixture, so the project-folder
        // path can be driven without a gateway.
        if DevHooks.demoProjects {
            projects = Self.demoProjects
            folders = Self.demoProjects
            ledger = Self.demoProjects.flatMap { $0.lanes.flatMap(\.sessions) }
            ledgerError = nil
            return
        }
        #endif
        do {
            guard let backend = SessionBackend.current(conversation) else {
                ledgerError = "Add the gateway API key in Settings."
                return
            }
            let sessions = try await backend.listSessions()
            guard current else { return }
            ledger = sessions
            conversation.noteServerTitles(sessions)
            if viaServe {
                // Projects are a bonus; a failure here must not hide the flat list.
                let all = (try? await HermesServeClient.shared.projectTree()) ?? []
                let tree = HermesServeClient.Project.listed(all)
                guard current else { return }
                projects = tree
                folders = all.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            }
            ledgerError = nil
        } catch {
            // A refresh cut short (tab switched, server changed) is not an error to show.
            guard current, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            ledgerError = error.localizedDescription
        }
    }

    // MARK: - Housekeeping

    private func housekeeping(_ session: HermesSessionsAPI.SessionSummary, _ work: @escaping () async throws -> Void) {
        Task {
            do { try await work(); await refresh() } catch { ledgerError = error.localizedDescription }
        }
    }

    private func rename(_ session: HermesSessionsAPI.SessionSummary, to title: String) {
        renaming = nil
        let t = title.trimmingCharacters(in: .whitespaces)
        housekeeping(session) {
            try await SessionBackend.current(conversation)?.rename(session.id, to: t)
        }
    }

    private func setPinned(_ session: HermesSessionsAPI.SessionSummary, _ pinned: Bool) {
        housekeeping(session) {
            try await SessionBackend.current(conversation)?.setPinned(session.id, pinned)
        }
    }

    /// Archived sessions leave the list but stay in Hermes's database (the dashboard can restore them).
    private func archive(_ session: HermesSessionsAPI.SessionSummary) {
        ledger.removeAll { $0.id == session.id }
        housekeeping(session) {
            try await SessionBackend.current(conversation)?.archive(session.id)
            if session.id == conversation.serverSessionID { conversation.reset() }
        }
    }

    /// Fork copies the transcript into a new session and opens it.
    private func fork(_ session: HermesSessionsAPI.SessionSummary) {
        let title = "\(session.displayTitle) (fork)"
        housekeeping(session) {
            if let forked = try await SessionBackend.current(conversation)?.fork(session.id, title: title) {
                try await conversation.loadLedgerSession(forked)
                opened()
            }
        }
    }

    private func delete(_ session: HermesSessionsAPI.SessionSummary) {
        ledger.removeAll { $0.id == session.id }
        housekeeping(session) {
            try await SessionBackend.current(conversation)?.delete(session.id)
            if let local = store.summaries.first(where: { $0.serverSessionID == session.id }) { conversation.delete(id: local.id) }
        }
    }

    /// Swaps the transcript to this session. Throws, so callers can show what went wrong.
    private func load(_ session: HermesSessionsAPI.SessionSummary) async throws {
        if viaServe {
            try await conversation.loadServeSession(session)
        } else {
            try await conversation.loadLedgerSession(session)
        }
        opened()
    }

    private func open(_ session: HermesSessionsAPI.SessionSummary) {
        opening = session.id
        Task {
            do {
                try await load(session)
                savedCopyOffered = nil
            } catch {
                ledgerError = error.localizedDescription
                savedCopyOffered = store.summaries.first { $0.serverSessionID == session.id }?.id
            }
            opening = nil
        }
    }

    // MARK: - Saved copies (the server can't be reached)

    /// This server's conversations as this iPhone last saw them: every one that was opened or
    /// held here is kept on the device (`ConversationStore`), so it can be read with no
    /// connection. Newest first, as the store has them.
    static func savedCopies(in summaries: [ConversationSummary], server: UUID, matching query: String) -> [ConversationSummary] {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        return summaries.filter {
            $0.serverSessionID != nil && $0.transport != .chatCompletions && ($0.serverID ?? server) == server
                && (wanted.isEmpty || $0.title.localizedCaseInsensitiveContains(wanted))
        }
    }

    @ViewBuilder
    private var savedCopiesSection: some View {
        let copies = Self.savedCopies(in: store.sorted, server: settings.activeServerID, matching: query)
        if !copies.isEmpty {
            Section {
                ForEach(copies) { copy in
                    Button { openSaved(copy) } label: { savedRow(copy) }
                        .buttonStyle(.plain)
                        .opensConversation()
                        .listRowBackground(copy.id == conversation.id ? Settings.shared.resolvedTheme.accent.opacity(0.08) : nil)
                }
            } header: {
                groupHeader("On this iPhone")
            } footer: {
                Text("As each conversation was when it was last open here. A message you send now waits, and goes when the connection is back.")
            }
        }
    }

    private func savedRow(_ copy: ConversationSummary) -> some View {
        keptRow(copy, caption: "Saved copy · \(Self.turns(copy))")
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the copy kept on this iPhone")
    }

    private func openSaved(_ copy: ConversationSummary) {
        guard !selecting, let full = store.record(id: copy.id) else { return }
        conversation.load(full)
        savedCopyOffered = nil
        opened()
    }

    // MARK: - Local (fast lane)

    @ViewBuilder
    private var localSection: some View {
        if store.sorted.isEmpty {
            ContentUnavailableView("No conversations yet", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Finished conversations show up here."))
                .listRowSeparator(.hidden)
        }
        ForEach(DateGroup.group(visibleLocal, by: { $0.updatedAt }), id: \.title) { group in
            Section { ForEach(group.items) { localButton($0) } } header: { groupHeader(group.title) }
        }
    }

    private func localButton(_ record: ConversationSummary) -> some View {
            Button {
                if selecting { return }
                if let full = store.record(id: record.id) { conversation.load(full) }
                opened()
            } label: {
                localRow(record)
            }
            .buttonStyle(.plain)
            .opensConversation()
            .tag(record.id.uuidString)
            .listRowBackground(record.id == conversation.id ? Settings.shared.resolvedTheme.accent.opacity(0.08) : nil)
            .contextMenu {
                Button("Export as Markdown", systemImage: "square.and.arrow.up") {
                    Task {
                        // Decode and write off the main actor; a long transcript is a big file.
                        guard let full = await store.loadRecord(id: record.id),
                              let url = try? await TranscriptExporter.export(title: record.title, messages: full.messages) else { return }
                        shareItem = ShareItem(url: url)
                    }
                }
                Button("Delete", systemImage: "trash", role: .destructive) { conversation.delete(id: record.id) }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { conversation.delete(id: record.id) } label: { Label("Delete", systemImage: "trash") }
            }
    }

    private func localRow(_ record: ConversationSummary) -> some View {
        keptRow(record, caption: "\(Self.turns(record)) · \(record.transport == .chatCompletions ? "OpenAI-compatible" : "Hermes")")
    }

    /// A conversation kept on this iPhone, as a row: its title and when it was last used, then
    /// the "Draft" mark if it has one and what there is to say about it.
    private func keptRow(_ record: ConversationSummary, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(record.title).font(.body.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Text(DateGroup.rowTime(record.updatedAt)).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if drafts.isWaiting(record.id) { draftMark }
                Text(caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// "1 turn", "12 turns".
    private static func turns(_ record: ConversationSummary) -> String {
        "\(record.turnCount) turn\(record.turnCount == 1 ? "" : "s")"
    }
}

/// Today, Yesterday, This week, then month by month: how the conversation list is sectioned.
enum DateGroup {
    struct Group<Item> { let title: String; let items: [Item] }

    static func group<Item>(_ items: [Item], by date: (Item) -> Date?, now: Date = .now) -> [Group<Item>] {
        var order: [String] = []
        var buckets: [String: [Item]] = [:]
        for item in items {
            let title = title(for: date(item), now: now)
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(item)
        }
        return order.map { Group(title: $0, items: buckets[$0] ?? []) }
    }

    static func title(for date: Date?, now: Date = .now) -> String {
        guard let date else { return "Earlier" }
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return "Today" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "Yesterday" }
        if let week = cal.date(byAdding: .day, value: -7, to: now), date > week { return "This week" }
        if cal.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.month(.wide)) }
        return date.formatted(.dateTime.month(.wide).year())
    }

    /// The time on a row: a clock time today, a weekday this week, a date before that.
    static func rowTime(_ date: Date, now: Date = .now) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let week = cal.date(byAdding: .day, value: -6, to: now), date > week { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

struct SessionUsageView: View {
    let session: HermesSessionsAPI.SessionSummary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Tokens") {
                    row("Input", session.input_tokens)
                    row("Output", session.output_tokens)
                    row("Reasoning", session.reasoning_tokens)
                    row("Cache read", session.cache_read_tokens)
                    row("Cache write", session.cache_write_tokens)
                    LabeledContent("Total") { Text(session.totalTokens.formatted()).monospacedDigit() }
                }
                if (session.cost ?? 0) > 0 {
                    Section("Cost") {
                        LabeledContent("Estimated") { Text(money(session.estimated_cost_usd)).monospacedDigit() }
                        LabeledContent("Actual") { Text(money(session.actual_cost_usd)).monospacedDigit() }
                    }
                }
                Section("Activity") {
                    row("Messages", session.message_count)
                    row("Tool calls", session.tool_call_count)
                    row("API calls", session.api_call_count)
                    if let model = session.model, !model.isEmpty { LabeledContent("Model", value: model) }
                    LabeledContent("Source", value: session.sourceLabel)
                }
                if (session.cost ?? 0) > 0 {
                    Section {
                        Text("Costs are the gateway's own estimate from provider pricing.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(session.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private func row(_ label: String, _ value: Int?) -> some View {
        LabeledContent(label) { Text((value ?? 0).formatted()).monospacedDigit() }
    }

    private func money(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value == 0 ? "$0" : String(format: "$%.4f", value)
    }
}


/// One project's sessions, grouped by lane (repo checkout / branch), newest first, and a new
/// conversation in it.
struct ProjectSessionsView: View {
    let project: HermesServeClient.Project
    let open: (HermesSessionsAPI.SessionSummary) async throws -> Void
    let currentID: String?
    /// Starts a conversation in this project (its folder); nil where that isn't offered.
    var startNew: ((HermesServeClient.Project) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidePanelParked) private var panelParked
    @State private var lanes: [HermesServeClient.Project.Lane] = []
    @State private var error: String?
    @State private var loading = true
    @State private var query = ""
    /// Which row is being resumed, and why it failed. Without these the screen looks inert
    /// while a long transcript loads, and says nothing at all when the load fails.
    @State private var opening: String?
    @State private var openError: String?

    var body: some View {
        List {
            if let error {
                ContentUnavailableView("Couldn't load the project", systemImage: "wifi.exclamationmark", description: Text(error))
                    .listRowSeparator(.hidden)
            } else if lanes.allSatisfy(\.sessions.isEmpty), !loading {
                ContentUnavailableView {
                    Label("No conversations yet", systemImage: "folder")
                } description: {
                    if canStart, let path = project.path {
                        VStack(spacing: 6) {
                            Text("Conversations started here work in its folder on your server:")
                            Text(path).font(.footnote.monospaced()).textSelection(.enabled)
                        }
                    }
                } actions: {
                    if canStart { Button("New Conversation") { startNew?(project) }.buttonStyle(.borderedProminent) }
                }
                .listRowSeparator(.hidden)
            }
            ForEach(lanes) { lane in
                let rows = filtered(lane.sessions)
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { session in
                            Button { openRow(session) } label: { row(session) }
                                .buttonStyle(.plain)
                                .opensConversation()
                                .disabled(opening != nil)
                                .listRowBackground(session.id == currentID ? Settings.shared.resolvedTheme.accent.opacity(0.08) : nil)
                        }
                    } header: {
                        if lanes.count > 1 || lane.label != "main" {
                            HStack(spacing: 4) {
                                if let r = lane.repoLabel, r != project.label { Text(r); Text("/") }
                                Text(lane.label)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(project.label)
        .toolbarVisibility(panelParked ? .hidden : .automatic, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canStart {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Conversation", systemImage: "square.and.pencil") { startNew?(project) }
                        .accessibilityHint("Starts a conversation in \(project.label)")
                }
            }
        }
        .searchable(text: $query, prompt: "Search in \(project.label)")
        .overlay { if loading { ProgressView() } }
        .alert("Couldn't open the session", isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            Button("OK", role: .cancel) { openError = nil }
        } message: {
            Text(openError ?? "")
        }
        .task {
            // The list already handed us this project's lanes: show them at once, then refresh.
            // A refresh that fails must not blank a folder we could already display.
            if lanes.isEmpty {
                lanes = project.lanes.filter { !$0.sessions.isEmpty }
                loading = lanes.isEmpty
            }
            #if DEBUG
            // The fixture's projects have no server behind them: what the list handed over is all.
            if DevHooks.demoProjects { loading = false; return }
            #endif
            do {
                let full = try await HermesServeClient.shared.projectSessions(project.id)
                lanes = (full?.lanes ?? []).filter { !$0.sessions.isEmpty }
                error = nil
            } catch {
                if lanes.isEmpty { self.error = error.localizedDescription }
            }
            loading = false
        }
    }

    /// A conversation can start here: a project with a folder, not the catch-all for none.
    private var canStart: Bool { startNew != nil && project.path != nil && !project.isHome }

    private func openRow(_ session: HermesSessionsAPI.SessionSummary) {
        guard opening == nil else { return }
        opening = session.id
        Task {
            do { try await open(session) } catch { openError = error.localizedDescription }
            opening = nil
        }
    }

    private func filtered(_ rows: [HermesSessionsAPI.SessionSummary]) -> [HermesSessionsAPI.SessionSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? rows : rows.filter { $0.displayTitle.lowercased().contains(q) || ($0.preview ?? "").lowercased().contains(q) }
        return list.sorted { ($0.lastActiveDate ?? .distantPast) > ($1.lastActiveDate ?? .distantPast) }
    }

    private func row(_ session: HermesSessionsAPI.SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.displayTitle).font(.body).lineLimit(1)
                Spacer()
                if opening == session.id {
                    ProgressView().controlSize(.small)
                } else if session.id == currentID {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
            HStack(spacing: 6) {
                Text(session.sourceLabel).font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: .capsule)
                if let when = session.lastActiveDate { Text(when, format: .relative(presentation: .named)) }
                if let n = session.message_count { Text("·"); Text("\(n) messages") }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let p = session.preview, !p.isEmpty { Text(p).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this session")
    }
}

#if DEBUG
extension ConversationsList {
    /// One project Hermes found, with one lane and two sessions (enough to reach
    /// ProjectSessionsView and tap a row), and one someone made, still empty.
    static var demoProjects: [HermesServeClient.Project] {
        let json = """
        {"id":"/home/redde/echo","label":"Echo","path":"/home/redde/echo","isNoProject":false,
         "sessionCount":2,"lastActive":1773000000,"totalCostUsd":0.42,
         "repos":[{"id":"r","label":"Echo","groups":[{"id":"lane1","label":"main","sessions":[
           {"id":"demo-1","title":"Transcript scrolling","source":"cli","started_at":1772999000,"last_active":1773000000,"message_count":12},
           {"id":"demo-2","title":"Calendar MCP guards","source":"desktop","started_at":1772990000,"last_active":1772999000,"message_count":30}]}]}]}
        """
        // And one made by someone, with no conversations yet.
        let own = """
        {"id":"p_demo","label":"Garden","path":"/home/redde/Projects/Garden","isAuto":false,"isNoProject":false,
         "sessionCount":0,"lastActive":0,"totalCostUsd":0,"repos":[]}
        """
        return [json, own].compactMap { text in
            guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
            return HermesServeClient.Project(value)
        }
    }
}
#endif
