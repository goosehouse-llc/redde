import SwiftUI

/// Previous sessions. With the ledger transport this is Hermes's own session list, every
/// platform included. Tap to resume, swipe to delete.
/// Sheet wrapper for iPhone (drag it down, or open a conversation, to leave). On iPad the list
/// lives in the split view's sidebar instead.
struct ConversationsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ConversationsList(onOpened: { dismiss() })
        }
    }
}

/// Identifies the project a sidebar row pushes to. A dedicated type rather than the bare id,
/// so the destination can't collide with another String route in the same stack.
private struct ProjectRoute: Hashable {
    let id: String
}

struct ConversationsList: View {
    /// What to do after a session opens: the sheet dismisses itself; the iPad sidebar stays put.
    var onOpened: () -> Void = {}
    /// Shown in the iPad split view's sidebar rather than the iPhone sheet.
    var inSidebar = false
    @Environment(Conversation.self) private var conversation
    @State private var store = ConversationStore.shared
    @State private var settings = Settings.shared
    @State private var ledger: [HermesSessionsAPI.SessionSummary] = []
    @State private var ledgerError: String?
    @State private var loading = false
    @State private var opening: String?
    @State private var query = ""
    @State private var renaming: HermesSessionsAPI.SessionSummary?
    @State private var renameText = ""
    @State private var usageFor: HermesSessionsAPI.SessionSummary?
    @State private var projects: [HermesServeClient.Project] = []
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

    /// Sessions, scheduled jobs, or the kanban board; the latter two live on the gateway.
    enum Tab: String, CaseIterable, Identifiable {
        case sessions, cron, kanban
        var id: String { rawValue }
        var title: String { switch self { case .sessions: "Chats"; case .cron: "Cron"; case .kanban: "Kanban" } }
        var icon: String { switch self { case .sessions: "bubble.left.and.bubble.right"; case .cron: "clock"; case .kanban: "rectangle.split.3x1" } }
    }
    @State private var section: Tab = Self.initialSection

    /// Dev hook: `-echo.section cron|kanban` opens the list on that tab (screenshots).
    private static var initialSection: Tab {
        #if DEBUG
        if let tab = DevHooks.value("-echo.section").flatMap(Tab.init(rawValue:)) { return tab }
        #endif
        return .sessions
    }

    var body: some View {
        Group {
            switch section {
            case .sessions: sessionsList
            case .cron: CronView()
            case .kanban: KanbanView()
            }
        }
        .toolbar {
            // On iPhone, Chats, Cron and Kanban share the bar with Settings and New, so the large
            // title below stays free.
            if !inSidebar {
                ToolbarItem(placement: .principal) { sectionPicker.frame(maxWidth: 230) }
            }
        }
        // The iPad sidebar's bar also holds Select and the sidebar button, which squeezed the
        // segments to "C… C… K…"; there they get a full-width row of their own.
        .safeAreaInset(edge: .top, spacing: 0) {
            if inSidebar { sectionPicker.padding(.horizontal, 16).padding(.bottom, 8) }
        }
        .navigationTitle(section == .sessions ? "Conversations" : section.title)
        .navigationBarTitleDisplayMode(section == .sessions ? .large : .inline)
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

    private var sectionPicker: some View {
        Picker("Section", selection: $section) {
            ForEach(Tab.allCases) { s in Text(s.title).tag(s) }
        }
        .pickerStyle(.segmented)
    }

    private var sessionsList: some View {
        // The selection binding belongs to "Select" mode only. A sidebar List that always has
        // one treats a row tap as selection and swallows the NavigationLink, so project folders
        // never push on iPad.
        List(selection: selecting ? $selected : nil) {
            if usesLedger {
                if viaServe, !projects.isEmpty, query.isEmpty, !selecting { projectsSection }
                ledgerSection
            } else {
                localSection
            }
        }
        .listStyle(.plain)
        .navigationDestination(for: ProjectRoute.self) { route in
            if let project = projects.first(where: { $0.id == route.id }) {
                ProjectSessionsView(project: project, open: load, currentID: conversation.serverSessionID)
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
                        onOpened()
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
        // Keyed on the profile: a switch reloads the list (and the iPad sidebar, which stays up).
        .task(id: settings.hermesProfile) { if usesLedger { await refresh() } }
        .onChange(of: settings.hermesProfile) {
            // The old profile's sessions must not linger while the new list loads.
            ledger = []
            projects = []
            ledgerError = nil
        }
        .refreshable { if usesLedger { await refresh() } }
        .onChange(of: query, initial: true) { filterLedger() }
        .onChange(of: ledger) { filterLedger() }
        .sheet(item: $usageFor) { SessionUsageView(session: $0) }
        .alert("Rename session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") { if let s = renaming { rename(s, to: renameText) } }
            Button("Cancel", role: .cancel) { renaming = nil }
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
            }
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
        } else if let ledgerError {
            // A failed rename/pin/delete must not blank the loaded list; show it inline.
            Label(ledgerError, systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(.orange).listRowSeparator(.hidden)
        } else if ledger.isEmpty && !loading {
            ContentUnavailableView("No conversations yet", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Conversations from every platform appear here."))
                .listRowSeparator(.hidden)
        }
        let rows = visibleLedger
        let pinned = rows.filter { $0.pinned == true }
        if !pinned.isEmpty {
            Section { ForEach(pinned) { ledgerButton($0) } } header: { groupHeader("Pinned") }
        }
        ForEach(DateGroup.group(rows.filter { $0.pinned != true }, by: { $0.lastActiveDate }), id: \.title) { group in
            Section { ForEach(group.items) { ledgerButton($0) } } header: { groupHeader(group.title) }
        }
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func ledgerButton(_ session: HermesSessionsAPI.SessionSummary) -> some View {
        Button { if !selecting { open(session) } } label: { ledgerRow(session) }
            .buttonStyle(.plain)
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
                Button("Export as Markdown", systemImage: "square.and.arrow.up") { export(session) }
                Button("Archive", systemImage: "archivebox") { archive(session) }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { delete(session) }
            }
    }

    private func ledgerRow(_ session: HermesSessionsAPI.SessionSummary) -> some View {
        rowBody(session)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens this session")
    }

    /// Title and when on the first line, the last thing said beneath; where it came from when
    /// it wasn't this app.
    private func rowBody(_ session: HermesSessionsAPI.SessionSummary) -> some View {
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

    private func refresh() async {
        loading = true
        defer { loading = false }
        #if DEBUG
        // Dev hook: `-echo.demoProjects` fills the list from a fixture, so the project-folder
        // path can be driven without a gateway.
        if DevHooks.demoProjects {
            projects = Self.demoProjects
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
            ledger = try await backend.listSessions()
            if viaServe {
                // Projects are a bonus; a failure here must not hide the flat list.
                projects = ((try? await HermesServeClient.shared.projectTree()) ?? [])
                    .filter { $0.sessionCount > 0 }
                    .sorted { a, b in
                        if a.isHome != b.isHome { return a.isHome }
                        return (a.lastActive ?? .distantPast) > (b.lastActive ?? .distantPast)
                    }
            }
            ledgerError = nil
        } catch {
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
                onOpened()
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
        onOpened()
    }

    private func open(_ session: HermesSessionsAPI.SessionSummary) {
        opening = session.id
        Task {
            do { try await load(session) } catch { ledgerError = error.localizedDescription }
            opening = nil
        }
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
                onOpened()
            } label: {
                localRow(record)
            }
            .buttonStyle(.plain)
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(record.title).font(.body.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Text(DateGroup.rowTime(record.updatedAt)).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(record.turnCount) turn\(record.turnCount == 1 ? "" : "s") · \(record.transport == .chatCompletions ? "OpenAI-compatible" : "Hermes")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
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


/// One project's sessions, grouped by lane (repo checkout / branch), newest first.
struct ProjectSessionsView: View {
    let project: HermesServeClient.Project
    let open: (HermesSessionsAPI.SessionSummary) async throws -> Void
    let currentID: String?
    @Environment(\.dismiss) private var dismiss
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
                ContentUnavailableView("No sessions", systemImage: "folder").listRowSeparator(.hidden)
            }
            ForEach(lanes) { lane in
                let rows = filtered(lane.sessions)
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { session in
                            Button { openRow(session) } label: { row(session) }
                                .buttonStyle(.plain)
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
        .navigationBarTitleDisplayMode(.inline)
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
    /// One project, one lane, two sessions: enough to reach ProjectSessionsView and tap a row.
    static var demoProjects: [HermesServeClient.Project] {
        let json = """
        {"id":"/home/redde/echo","label":"Echo","path":"/home/redde/echo","isNoProject":false,
         "sessionCount":2,"lastActive":1773000000,"totalCostUsd":0.42,
         "repos":[{"id":"r","label":"Echo","groups":[{"id":"lane1","label":"main","sessions":[
           {"id":"demo-1","title":"Transcript scrolling","source":"cli","started_at":1772999000,"last_active":1773000000,"message_count":12},
           {"id":"demo-2","title":"Calendar MCP guards","source":"desktop","started_at":1772990000,"last_active":1772999000,"message_count":30}]}]}]}
        """
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let project = HermesServeClient.Project(value) else { return [] }
        return [project]
    }
}
#endif
