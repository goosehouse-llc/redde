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
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = ConversationStore.shared
    /// Working, Needs you and Unread, for the rows.
    @State private var activity = ChatActivity.shared
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
    /// The server's bots (Hermes's Bot Mode), for the Bots section.
    @State private var botDirectory = BotDirectory.shared
    @AppStorage("sessions.showBots") private var showBotRows = true
    /// More than six bots: all of them showing, or the first few and "more".
    @AppStorage("sessions.botsExpanded") private var botsExpanded = false
    /// New Bot, Topology and Hidden after the bots, or folded into one More (his ask 2026-10-22).
    @AppStorage("sessions.botActionsShown") private var botActionsShown = true
    /// Every profile's chats in the list at once, each tagged with its profile, as Hermes Desktop
    /// can (his ask 2026-10-22, after a Reddit request); off, the selected profile's alone.
    @AppStorage("sessions.allProfiles") private var allProfiles = false
    /// Every saved server's chats in the list, each tagged with its server (`AllServers`).
    @AppStorage("sessions.allServers") private var allServers = false
    /// The servers that didn't answer, with All Servers on.
    @State private var serversUnreachable: [String] = []
    /// The bot whose chat is being found or made.
    @State private var openingBot: String?
    /// "Let bots message each other", being asked about.
    @State private var askingBotMessaging = false
    /// The server's group chats (Hermes's bot rooms; the one open in the chat's place is
    /// `groups.open`), and a new one being made.
    @State private var groups = GroupDirectory.shared
    @State private var makingGroup = false
    @State private var dateGroupExpansion: [String: Bool] = [:]
    /// The bot whose face is being picked.
    @State private var facing: HermesBot?
    /// A bot being made or changed, and the hidden ones being looked at.
    @State private var editingBot: BotEditor.Mode?
    /// A bot being added for the Hermes API alone.
    @State private var addingAPIBot = false
    /// The map of the bots, their group chats and models (`BotTopologyView`).
    @State private var showingTopology = false
    /// The bot whose voice is being picked.
    @State private var voicing: HermesBot?
    /// The bot whose schedules are open (`BotSchedulesView`).
    @State private var scheduling: HermesBot?
    @State private var showingHiddenBots = false
    @AppStorage("sessions.showScheduled") private var showScheduled = false
    @State private var shareItem: ShareItem?
    @State private var selecting = false
    /// The Bots section being put in order: only its bots and group chats show, with handles.
    @State private var arrangingBots = false
    @State private var selected: Set<String> = []
    @State private var confirmBulkDelete = false
    @State private var showSettings = false
    @Environment(\.showSettingsSheet) private var showSettingsSheet
    @Environment(\.wideLayout) private var wide
    /// Pinned first, then most recent; filtered by the search field. Cached: the body reads it
    /// several times per pass and every keystroke in the search field would repeat the sort.
    @State private var visibleLedger: [HermesSessionsAPI.SessionSummary] = []
    /// Conversations with a message matching the search, from the server (`MessageSearch`).
    @State private var messageHits: [MessageSearchHit] = []
    @State private var searchingMessages = false
    @State private var messageSearchProblem: String?

    private var usesLedger: Bool { settings.transport.hasLedger }
    private var viaServe: Bool { settings.transport == .hermesServe }
    /// The server's bots can be reached: on the Dashboard, and on the Hermes API through the
    /// Dashboard's login (`BotDirectory.reachable`).
    private var botsHere: Bool { BotDirectory.reachable(settings) || apiBotsOnly }
    /// The Hermes API with no Dashboard login: the bots are the ones added here (`APIBot`).
    private var apiBotsOnly: Bool { BotDirectory.apiOnly(settings) }
    /// Searching inside messages takes the Dashboard (only it has the route), on either connection.
    private var searchesMessages: Bool { usesLedger && settings.serveBaseURL != nil }

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
        if #available(iOS 27.0, *), wideDetail { return selecting || arrangingBots ? "" : "Chats" }
        return section == .sessions || wideDetail ? "Conversations" : section.title
    }

    /// A conversation opened (or a new one started), or with `room` a group chat: it takes the
    /// chat's place (on iPad, the wide pane again).
    /// Settings, from the app's root where there is one (it stays up when the layout changes
    /// under the list), else on the list.
    private func openSettings() {
        if let showSettingsSheet { showSettingsSheet() } else { showSettings = true }
    }

    private func opened(room: GroupRoom? = nil) {
        groups.open = room
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
        // Group chats, from the Bots section: here, not on the section, which a list builds lazily.
        .sheet(isPresented: $makingGroup) {
            NewGroupChatView(bots: listedBots, mainName: settings.headerTitle) { room in
                Task { await groups.refresh() }
                opened(room: room)
            }
        }
        .sheet(item: $voicing) { BotVoicePicker(bot: $0, mainName: settings.headerTitle) }
        .sheet(item: $scheduling) { BotSchedulesView(bot: $0, mainName: settings.headerTitle) }
        .sheet(item: $facing) { bot in
            BotFacePicker(bot: bot, name: bot.label(mainName: settings.headerTitle),
                          current: botDirectory.roster?.faces[bot.name] ?? BotFace(seed: bot.name)) {
                Task { _ = try? await botDirectory.refresh() }
            }
        }
        .sheet(item: $editingBot) { mode in
            BotEditor(mode: mode, mainName: settings.headerTitle) { botEdited($0) }
        }
        .sheet(isPresented: $showingHiddenBots) { HiddenBotsView(mainName: settings.headerTitle) }
        .sheet(isPresented: $showingTopology) { BotTopologyView(openBot: openBot, openRoom: { opened(room: $0) }) }
        // A bot's chat opened, or left: seen up to now.
        .onChange(of: conversation.bot?.profile) { old, new in
            for name in [old, new].compactMap(\.self) { activity.botSeen(name) }
        }
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
    /// The server the app is on, or All Servers: every saved server's chats in the list, the one
    /// the app is on still the one new chats start on (a Reddit request, 2026-10-21).
    private var serverMenu: some View {
        let title = allServers ? "All Servers" : settings.activeServer?.title ?? ""
        return Menu {
            Button { allServers = true } label: {
                Label("All Servers", systemImage: allServers ? "checkmark" : "square.stack.3d.up")
            }
            Divider()
            ForEach(settings.servers) { server in
                Button {
                    allServers = false
                    ServerSwitcher.switchTo(server.id, conversation: conversation)
                } label: {
                    if !allServers, server.id == settings.activeServerID { Label(server.title, systemImage: "checkmark") } else { Text(server.title) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: allServers ? "square.stack.3d.up" : "server.rack")
                Text(title).lineLimit(1)
                if allServers, let here = settings.activeServer?.title {
                    Text("· new chats on \(here)").foregroundStyle(.secondary).lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("Server")
        .accessibilityValue(title)
    }

    /// The profiles this server has, as far as the phone knows.
    private var knownProfiles: [KnownProfile] { ProfileCatalog.known(settings: settings) }

    /// The profiles the menu offers: the known ones, then any the server's bots and the list of
    /// every profile's chats have shown.
    private var menuProfiles: [String] {
        var names = knownProfiles.map(\.name)
        let roster = botDirectory.key == settings.connectionKey ? (botDirectory.roster?.bots.map(\.name) ?? []) : []
        for name in roster + ledger.compactMap(\.elsewhere?.profile) where !names.contains(name) { names.append(name) }
        return names
    }

    /// Which profile's chats the list shows: all of them, or one, which is then the one new chats
    /// start in (the app's profile, as Settings → Profile picks it). One tap from the list, not
    /// a trip to Settings (a Reddit report, 2026-10-22: moving between profiles was clunky).
    private var profileMenu: some View {
        let current = settings.profileName ?? ProfileCatalog.defaultID
        let title = allProfiles ? "All Profiles" : profileLabel(current)
        return Menu {
            Button { allProfiles = true } label: {
                Label("All Profiles", systemImage: allProfiles ? "checkmark" : "rectangle.stack")
            }
            Divider()
            ForEach(menuProfiles, id: \.self) { name in
                Button {
                    allProfiles = false
                    let known = knownProfiles.first { $0.name == name } ?? KnownProfile(name: name, title: profileLabel(name))
                    _ = ProfileCatalog.use(known, conversation: conversation, settings: settings)
                } label: {
                    if !allProfiles, name == current { Label(profileLabel(name), systemImage: "checkmark") } else { Text(profileLabel(name)) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: allProfiles ? "rectangle.stack" : "person.crop.circle")
                Text(title).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("Profile")
        .accessibilityValue(title)
    }

    /// What a profile is called in the list: its bot's name, the name the Dashboard gave it, or its
    /// own.
    private func profileLabel(_ name: String) -> String {
        if let bot = botDirectory.roster?.named(name), !bot.isDefault { return bot.label(mainName: settings.headerTitle) }
        if name == ProfileCatalog.defaultID { return settings.headerTitle }
        return knownProfiles.first { $0.name == name }?.title ?? name
    }

    /// The server switch (once there's more than one) and Chats, Cron and Kanban, as the first
    /// row of whichever list is showing: they move with it when you pull to refresh or scroll.
    /// Full width: in the bar, next to Settings, Select and New, they were squeezed to "Kanb…".
    private var topRow: some View {
        VStack(spacing: 8) {
            // Not on the OpenAI-compatible connection, which belongs to no server (as in Settings).
            if settings.servers.count > 1, settings.transport != .chatCompletions { serverMenu }
            if settings.transport != .chatCompletions, allProfiles || menuProfiles.count > 1 { profileMenu }
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
            if arrangingBots {
                botsSection
            } else {
                topRow
                if query.isEmpty, !selecting { waitingNotesSection }
                if usesLedger {
                    if query.isEmpty, !selecting {
                        if botsHere { botsSection }
                        if viaServe { projectsSection }
                    }
                    ledgerSection
                    if searchesMessages, !selecting { messageHitsSection }
                } else {
                    localSection
                }
            }
        }
        .listStyle(.plain)
        .navigationDestination(for: ProjectRoute.self) { route in
            if let project = projects.first(where: { $0.id == route.id }) {
                ProjectSessionsView(project: project, open: load, currentID: conversation.serverSessionID,
                                    startNew: { startNew(in: $0) })
            }
        }
        .environment(\.editMode, .constant(selecting || arrangingBots ? .active : .inactive))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if selecting {
                    Button("Cancel") { selecting = false; selected = [] }
                } else if !arrangingBots {
                    Button("Settings", systemImage: "gearshape") { openSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if arrangingBots {
                    Button("Done") { withAnimation { arrangingBots = false } }
                        .fontWeight(.semibold)
                } else if selecting {
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
        .modifier(ListSearchCarry(query: $query, wide: wide))
        // Keyed on the server and profile: a switch reloads the list (and the iPad sidebar,
        // which stays up).
        // Not while the iPhone's panel is closed: it loads when it opens (isShowing below).
        // (All Profiles turned on or off loads the list again too.)
        .task(id: "\(settings.connectionKey)|\(allProfiles)|\(allServers)") { if usesLedger, isShowing { await refresh() } }
        .onChange(of: settings.connectionKey) {
            // The old server's or profile's sessions must not linger while the new list loads.
            ledger = []
            projects = []
            ledgerError = nil
            selecting = false
            selected = []
            arrangingBots = false
        }
        .refreshable { if usesLedger { await refresh() } }
        .onChange(of: isShowing) { _, showing in
            if showing, usesLedger { Task { await refresh() } }
        }
        .modifier(WatchingActivity(key: "\(settings.connectionKey)|\(isShowing)|\(scenePhase == .active)",
                                   openID: conversation.serverSessionID, watch: watchActivity, opened: openChanged))
        .onChange(of: query, initial: true) { filterLedger() }
        .task(id: "\(query)|\(settings.connectionKey)") { await searchMessages() }
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
        // Incognito chats aren't listed, here or (hidden on the Dashboard) by any app, until they go.
        let incognito = Incognito.sessions(on: settings.activeServerID.uuidString)
            .union(conversation.isIncognito ? [conversation.serverSessionID].compactMap(\.self) : [])
        let listed = incognito.isEmpty ? ledger : ledger.filter { !incognito.contains($0.id) }
        let filtered = q.isEmpty ? listed : listed.filter {
            $0.displayTitle.lowercased().contains(q) || ($0.preview ?? "").lowercased().contains(q) || $0.sourceLabel.lowercased().contains(q)
        }
        visibleLedger = filtered.sorted { a, b in
            if (a.pinned ?? false) != (b.pinned ?? false) { return a.pinned ?? false }
            return (a.lastActiveDate ?? .distantPast) > (b.lastActiveDate ?? .distantPast)
        }
    }

    // MARK: - Bots (Hermes's Bot Mode, on the Dashboard)

    /// The bots the list shows: none with the setting off, or while the main profile is the only one.
    private var listedBots: [HermesBot] {
        guard settings.showBots, botDirectory.key == settings.connectionKey else { return [] }
        return botDirectory.roster?.listed ?? []
    }

    /// The server's bots as last read, with the setting on: nil before they are (or can't be) read.
    private var serverBots: [HermesBot]? {
        guard settings.showBots, botDirectory.key == settings.connectionKey else { return nil }
        return botDirectory.roster?.bots
    }

    /// The Bots section: once the server's bots are read, even with none yet but the main
    /// profile, for New Bot.
    @ViewBuilder
    private var botsSection: some View {
        if let all = serverBots {
            let bots = listedBots
            let hidden = all.filter { $0.isHidden && !$0.isDefault }
            let faces = botDirectory.roster?.faces ?? [:]
            // (Group chats are the Dashboard's: none on the Hermes API alone, whatever was read before.)
            let hasRooms = !apiBotsOnly && !bots.isEmpty && groups.key == settings.connectionKey && groups.supported
            let items = BotListItem.arranged(bots: bots, rooms: hasRooms ? groups.rooms : [], order: botOrder)
            Section {
                if arrangingBots {
                    // Bots and group chats in one run, in the order they were put in (Reorder Bots).
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Group {
                            switch item {
                            case .bot(let bot): botRow(bot, face: faces[bot.name] ?? BotFace(seed: bot.name))
                            case .room(let room): groupRow(room, faces: faces)
                            }
                        }
                        // Being put in order, a row moves by its handle and opens nothing.
                        .allowsHitTesting(false)
                        .accessibilityAction(named: "Move up") { if index > 0 { moveBotRows(IndexSet(integer: index), to: index - 1, in: items) } }
                        .accessibilityAction(named: "Move down") { if index < items.count - 1 { moveBotRows(IndexSet(integer: index), to: index + 2, in: items) } }
                    }
                    .onMove { moveBotRows($0, to: $1, in: items) }
                } else if showBotRows {
                    // The bots as faces, five to a row (a Reddit suggestion, 2026-10-21: a line of
                    // context under each took a screen's worth), New Bot after them; the group
                    // chats under them.
                    botGrid(items.compactMap { if case .bot(let bot) = $0 { bot } else { nil } }, faces: faces, hidden: hidden.count)
                    ForEach(items.compactMap { if case .room(let room) = $0 { room } else { nil } }) { room in
                        groupRow(room, faces: faces)
                    }
                    if hasRooms, groups.writable {
                        sectionAction("New Group Chat", systemImage: "person.3", hint: "Starts a chat with several bots at once") { makingGroup = true }
                    }
                    if !apiBotsOnly, !bots.isEmpty, botDirectory.roster?.messagingIsOn == false {
                        sectionAction("Let bots message each other", systemImage: "bubble.left.and.text.bubble.right",
                                      hint: "Sets your main profile up as a bot on the server, as Hermes Desktop does") { askingBotMessaging = true }
                    }
                }
            } header: {
                if arrangingBots { Text("Bots") } else { foldingHeader("Bots", count: bots.count, isOpen: $showBotRows) }
            } footer: {
                if arrangingBots {
                    Text("Drag bots and group chats by their handles into the order you want.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if apiBotsOnly, showBotRows, bots.isEmpty {
                    Text("Bots are your server's other profiles. On the Hermes API, add each by its name and its own API key; with the Dashboard login saved in Settings, Redde lists them and has group chats too.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $addingAPIBot) {
                APIBotEditor { Task { _ = await botDirectory.refreshAPI() } }
            }
            .confirmationDialog("Let bots message each other?", isPresented: $askingBotMessaging, titleVisibility: .visible) {
                Button("Let Them") { letBotsMessageEachOther() }
            } message: {
                Text("Hermes gives each bot's chat a tool to message the other bots, so you can say \u{201C}@scout, what do you think?\u{201D} in one bot's chat and have it ask. Redde turns this on the way Hermes Desktop does, by setting your main profile up as a bot on the server. Chats with your agent stay as they are.")
            }
        }
    }

    /// The order the Bots section's rows were put in on this server; empty, none.
    private var botOrder: [String] { settings.botOrderHere }

    /// A bot or group chat dragged to another place: the section keeps that order from now on.
    private func moveBotRows(_ moving: IndexSet, to destination: Int, in items: [BotListItem]) {
        withAnimation {
            settings.botOrderHere = BotListItem.order(after: moving, to: destination, in: items, kept: botOrder)
        }
    }

    /// In a bot's or group chat's menu: put the section in order, or (once it is) back to the most
    /// recent first.
    @ViewBuilder
    private var orderingBots: some View {
        Button("Reorder Bots", systemImage: "arrow.up.arrow.down") { withAnimation { arrangingBots = true } }
        if !botOrder.isEmpty {
            Button("Sort Bots by Recent", systemImage: "clock.arrow.circlepath") {
                withAnimation { settings.botOrderHere = [] }
            }
        }
    }

    /// A row that does something in its section (New Group Chat), drawn as New Project is.
    private func sectionAction(_ title: String, systemImage: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(Settings.shared.resolvedTheme.accent)
                    .frame(width: 32, height: 32)
                Text(title).font(.body)
            }
            // The whole row: a short title ("Topology") left most of it dead to a tap.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint)
    }

    /// The bots side by side, five to a row, each its face over its name, and after them New Bot
    /// (Add Bot on the Hermes API alone) and the hidden ones: every bot in sight, nothing to scroll
    /// sideways. More than six fold to one row, the first four and "more", open or folded as last
    /// left.
    private func botGrid(_ bots: [HermesBot], faces: [String: BotFace], hidden: Int) -> some View {
        let folds = bots.count > Self.foldsAfter
        let shown = folds && !botsExpanded ? Array(bots.prefix(Self.gridColumns - 1)) : bots
        return VStack(spacing: 2) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2, alignment: .top), count: Self.gridColumns), spacing: 6) {
                ForEach(shown, id: \.name) { bot in
                    botTile(bot, face: faces[bot.name] ?? BotFace(seed: bot.name))
                }
                if folds, !botsExpanded {
                    gridAction("\(bots.count - shown.count) more", systemImage: "chevron.down", hint: "Shows all your bots") {
                        withAnimation { botsExpanded = true }
                    }
                } else if !botActionsShown {
                    // Folded away, one tile for them all, so they aren't always on screen.
                    gridAction("More", systemImage: "ellipsis", hint: "Shows New Bot, Topology and the hidden bots") {
                        withAnimation { botActionsShown = true }
                    }
                } else {
                    if apiBotsOnly {
                        // No Dashboard to make or list them: a profile on the server, by its own key.
                        gridAction("Add Bot", systemImage: "plus", hint: "Adds one of your server's profiles as a bot, with its own API key") { addingAPIBot = true }
                    } else {
                        gridAction("New Bot", systemImage: "plus", hint: "Makes a bot on your server, with a chat of its own") { editingBot = .new }
                    }
                    // Beside New Bot, the same size (his ask 2026-10-22).
                    gridAction("Topology", systemImage: "point.3.connected.trianglepath.dotted",
                               hint: "Shows your bots, your group chats and the models they run on") { showingTopology = true }
                    if hidden > 0 {
                        gridAction("Hidden", systemImage: "eye.slash", hint: "Shows the \(hidden) bots hidden from this list") { showingHiddenBots = true }
                    }
                    gridAction("Less", systemImage: "chevron.left", hint: "Folds New Bot, Topology and the hidden bots into one tile") {
                        withAnimation { botActionsShown = false }
                    }
                }
            }
            // Under them, small: a whole row of its own for it was a row of nothing.
            if folds, botsExpanded {
                Button { withAnimation { botsExpanded = false } } label: {
                    Label("Fewer", systemImage: "chevron.up")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Settings.shared.resolvedTheme.accent)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fewer")
                .accessibilityHint("Shows only the first of your bots")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .listRowInsets(EdgeInsets())
    }

    /// Bots to a row in the Bots section, and how many there can be before they fold to one row.
    private static let gridColumns = 5
    private static let foldsAfter = 6
    /// The size of a face there.
    private static let tileFace: CGFloat = 52

    /// A bot there: its face, always (never its initial on a disc), and its name under it,
    /// marked as a conversation's row is (at work, waiting on the person, something not yet seen).
    /// A tap opens its chat; a long press, its menu (a menu of its own: in a list row a context
    /// menu opens the row's first one, whichever bot was pressed).
    private func botTile(_ bot: HermesBot, face: BotFace) -> some View {
        let name = bot.label(mainName: settings.headerTitle)
        let isOpen = groups.open == nil && conversation.bot?.profile == bot.name
        let muted = Mutes.isMuted("bot:" + bot.name, settings: settings)
        let marks = ChatMarks(kind: activity.kind(of: bot, open: conversation), unread: !muted && activity.isUnread(bot, open: conversation),
                              muted: muted)
        let accent = Settings.shared.resolvedTheme.accent
        return Menu {
            botMenu(bot, unread: marks.unread, isOpen: isOpen)
        } label: {
            VStack(spacing: 3) {
                BotAvatar(face: face, size: Self.tileFace)
                    .overlay(alignment: .topTrailing) {
                        if openingBot == bot.name || marks.kind == .working {
                            ProgressView().controlSize(.mini)
                                .padding(2)
                                .background(.background, in: .rect(cornerRadius: 6))
                                .offset(x: 8, y: -4)
                        } else if marks.kind == .needsYou {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.caption).foregroundStyle(.orange)
                                .background(.background, in: .circle)
                                .offset(x: 6, y: -4)
                        } else if marks.unread {
                            Circle().fill(accent).frame(width: 9, height: 9).offset(x: 4, y: -2)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if muted {
                            Image(systemName: "bell.slash.fill")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                                .padding(2)
                                .background(.background, in: .circle)
                                .offset(x: 5, y: 3)
                        }
                    }
                Text(name).lineLimit(1).truncationMode(.tail)
                    .font(.caption.weight(isOpen ? .semibold : .regular))
                    .foregroundStyle(isOpen ? accent : .primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(isOpen ? accent.opacity(0.1) : .clear, in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        } primaryAction: {
            openBot(bot)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .opensConversation()
        .disabled(opening != nil || openingBot != nil)
        .accessibilityLabel(name)
        .accessibilityValue(marks.spoken)
        .accessibilityHint("Opens your chat with this bot")
    }

    /// What follows the bots (New Bot, the hidden ones, "more"): a symbol where a face goes, and
    /// its name.
    private func gridAction(_ title: String, systemImage: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Settings.shared.resolvedTheme.accent)
                    .frame(width: Self.tileFace, height: Self.tileFace)
                Text(title).font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
    }

    /// A bot's menu, on its face in the row and on its row while the bots are put in order.
    @ViewBuilder
    private func botMenu(_ bot: HermesBot, unread: Bool, isOpen: Bool) -> some View {
        if bot.chatID != nil, !isOpen {
            if unread {
                Button("Mark as Read", systemImage: "envelope.open") { activity.botSeen(bot.name) }
            } else {
                Button("Mark as Unread", systemImage: "envelope.badge") { activity.markUnread(bot: bot.name) }
            }
        }
        if !bot.isDefault {
            Button("Voice…", systemImage: "waveform") { voicing = bot }
        }
        MuteMenu(item: "bot:" + bot.name)
        // Its schedules are kept on the server through the Dashboard, delivered into its Bot Chat.
        if !bot.viaAPI {
            Button("Schedules…", systemImage: "clock") { scheduling = bot }
        }
        if bot.viaAPI {
            // Added here for the Hermes API: its settings and face are the Dashboard's.
            if !bot.isDefault {
                Button("Remove from Redde", systemImage: "minus.circle", role: .destructive) { removeAPIBot(bot) }
            }
        } else {
            Button("Edit Bot…", systemImage: "slider.horizontal.3") { editingBot = .edit(bot) }
            Button("Change Face…", systemImage: "face.smiling") { facing = bot }
            if !bot.isDefault {
                Button("Hide", systemImage: "eye.slash") { hide(bot) }
            }
        }
        Divider()
        orderingBots
    }

    /// A bot's row while the bots are put in order: its creature, its name and its chat's last
    /// line, marked as a conversation's row is (at work, waiting on the person, or something not
    /// yet seen).
    private func botRow(_ bot: HermesBot, face: BotFace) -> some View {
        let name = bot.label(mainName: settings.headerTitle)
        let isOpen = groups.open == nil && conversation.bot?.profile == bot.name
        // Muted: no unread dot (at work, or waiting on the person, still shows).
        let muted = Mutes.isMuted("bot:" + bot.name, settings: settings)
        let marks = ChatMarks(kind: activity.kind(of: bot, open: conversation), unread: !muted && activity.isUnread(bot, open: conversation),
                              muted: muted)
        let roster = botDirectory.roster?.bots ?? []
        return Button { openBot(bot) } label: {
            HStack(spacing: 12) {
                BotAvatar(face: face, name: name)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name).font(.body.weight(.semibold)).lineLimit(1)
                        if muted { MutedMark() }
                        Spacer(minLength: 8)
                        if openingBot == bot.name || marks.kind == .working {
                            ProgressView().controlSize(.small)
                        } else if let when = bot.lastActive {
                            Text(DateGroup.rowTime(when)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 6) {
                        if marks.kind == .needsYou { NeedsYouTag() }
                        Text(BotMessages.rowPreview(bot.preview, roster: roster, mainName: settings.headerTitle)
                             ?? bot.description.nilIfEmpty ?? "@\(bot.handle)")
                            .lineLimit(1)
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .unreadDot(marks.unread)
        .opensConversation()
        .listRowBackground(isOpen ? Settings.shared.resolvedTheme.accent.opacity(0.08) : nil)
        .disabled(opening != nil || openingBot != nil)
        .contextMenu { botMenu(bot, unread: marks.unread, isOpen: isOpen) }
        .accessibilityElement(children: .combine)
        .accessibilityValue(marks.spoken)
        .accessibilityHint("Opens your chat with this bot")
    }

    /// A group chat's row: its bots' faces, its name, and who is in it, marked as a bot's row
    /// is (a bot at work in it, one waiting on the person, or something not yet seen).
    private func groupRow(_ room: GroupRoom, faces: [String: BotFace]) -> some View {
        let isOpen = groups.open?.id == room.id
        let muted = Mutes.isMuted("room:" + room.id, settings: settings)
        let marks = ChatMarks(kind: activity.kind(of: room), unread: !muted && activity.isUnread(room, isOpen: isOpen), muted: muted)
        return Button { opened(room: room) } label: {
            HStack(spacing: 12) {
                FaceStack(faces: room.members.prefix(2).map { (faces[$0.profile] ?? BotFace(seed: $0.profile), $0.label) }, size: 24)
                    .frame(width: 32, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(room.name).font(.body.weight(.semibold)).lineLimit(1)
                        if muted { MutedMark() }
                        Spacer(minLength: 8)
                        if marks.kind == .working {
                            ProgressView().controlSize(.small)
                        } else if let when = room.updatedAt {
                            Text(DateGroup.rowTime(when)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 5) {
                        if marks.kind == .needsYou { NeedsYouTag() }
                        if room.inDesktop {
                            Image(systemName: "desktopcomputer").accessibilityLabel("Runs in Hermes Desktop")
                        }
                        Text(room.members.map(\.label).formatted(.list(type: .and)))
                    }
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .unreadDot(marks.unread)
        .listRowBackground(isOpen ? Settings.shared.resolvedTheme.accent.opacity(0.08) : nil)
        .contextMenu {
            if !isOpen, room.activityMark != nil {
                if marks.unread {
                    Button("Mark as Read", systemImage: "envelope.open") { activity.roomSeen(room.id, upTo: room.activityMark) }
                } else {
                    Button("Mark as Unread", systemImage: "envelope.badge") { activity.markUnread(room: room.id) }
                }
            }
            // Hermes Desktop's group chats never notify: nothing to mute.
            if !room.inDesktop { MuteMenu(item: "room:" + room.id) }
            Divider()
            orderingBots
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(marks.spoken)
        .accessibilityHint(room.inDesktop ? "Shows this Hermes Desktop group chat's last messages" : "Opens this group chat")
    }

    private func openBot(_ bot: HermesBot) {
        // Its chat is the conversation under the group chat: back to it, as it was.
        if groups.open != nil, conversation.bot?.profile == bot.name { return opened() }
        openingBot = bot.name
        Task {
            do {
                try await conversation.openBot(bot, mainName: settings.headerTitle)
                opened()
            } catch {
                ledgerError = error.localizedDescription
            }
            openingBot = nil
        }
    }

    /// A bot made, changed or deleted in BotEditor: the list reads the bots again; a new one's
    /// chat opens, and a deleted one's, if open, is left for a new conversation.
    private func botEdited(_ outcome: BotEditor.Outcome) {
        Task {
            do {
                let roster = try await botDirectory.refresh()
                switch outcome {
                case let .made(name):
                    if let bot = roster.bots.first(where: { $0.name == name }) { openBot(bot) }
                case let .deleted(name):
                    if conversation.bot?.profile == name { conversation.reset() }
                case .changed:
                    break
                }
            } catch {
                ledgerError = error.localizedDescription
            }
        }
    }

    /// An API bot taken off this iPhone: its key goes, its chat and profile stay on the server.
    private func removeAPIBot(_ bot: HermesBot) {
        settings.apiBotsHere.removeAll { $0.profile == bot.name }
        Keychain.delete(account: Keychain.profileAccount(bot.name, server: settings.activeServerID.uuidString))
        if conversation.bot?.profile == bot.name { conversation.reset() }
        Task { _ = await botDirectory.refreshAPI() }
    }

    private func hide(_ bot: HermesBot) {
        Task {
            do {
                _ = try await HermesServeClient.shared.changeBot(bot, BotChange(hidden: true))
                try await botDirectory.refresh()
            } catch {
                ledgerError = "Couldn't hide \(bot.label(mainName: settings.headerTitle)): \(error.localizedDescription)"
            }
        }
    }

    private func letBotsMessageEachOther() {
        guard let roster = botDirectory.roster else { return }
        Task {
            do {
                try await HermesServeClient.shared.letBotsMessageEachOther(roster)
                try await botDirectory.refresh()
            } catch {
                ledgerError = "Couldn't set that up: \(error.localizedDescription)"
            }
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
            foldingHeader("Projects", count: projects.count, isOpen: $showProjects)
        }
    }

    /// A header that folds its section away and opens it again; folded, it says how many rows wait.
    private func foldingHeader(_ title: String, count: Int, isOpen: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { isOpen.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                if !isOpen.wrappedValue {
                    Text("\(count)").font(.caption2.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isOpen.wrappedValue ? 90 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isOpen.wrappedValue ? "Hide" : "Show") \(title.lowercased())")
        .accessibilityAddTraits(.isHeader)
    }

    /// Ids of the rows currently shown, for select-all and bulk actions: folded runs aren't.
    private var visibleIDs: Set<String> {
        usesLedger ? Set(visibleLedger.filter { showScheduled || !Self.isFoldable($0) }.map(\.id))
                   : Set(visibleLocal.map { $0.id.uuidString })
    }

    /// A row that goes under Scheduled runs rather than among the chats: a run nobody pinned.
    private static func isFoldable(_ session: HermesSessionsAPI.SessionSummary) -> Bool {
        session.isScheduledRun && session.pinned != true
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
    private func export(_ session: HermesSessionsAPI.SessionSummary) {
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

    // MARK: - Ledger (gateway)

    @ViewBuilder
    private var ledgerSection: some View {
        if let ledgerError, ledger.isEmpty {
            ConnectionProblemCard(message: ledgerError,
                                  retry: { Task { await refresh() } },
                                  openSettings: { openSettings() })
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
        if !serversUnreachable.isEmpty {   // (empty unless All Servers is on)
            Label("\(serversUnreachable.formatted()) didn't answer, so \(serversUnreachable.count == 1 ? "its" : "their") chats aren't here.",
                  systemImage: "wifi.exclamationmark")
                .font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
        }
        let rows = visibleLedger
        let pinned = rows.filter { $0.pinned == true }
        let runs = rows.filter(Self.isFoldable)
        let drafted = draftedSessions
        if !pinned.isEmpty {
            let isOpen = isDateGroupOpen("Pinned")
            Section {
                if isOpen { ForEach(pinned) { ledgerButton($0, hasDraft: drafted.contains($0.id)) } }
            } header: {
                dateGroupHeader("Pinned", count: pinned.count)
            }
        }
        ForEach(DateGroup.group(rows.filter { $0.pinned != true && !$0.isScheduledRun }, by: { $0.lastActiveDate }), id: \.title) { group in
            let isOpen = isDateGroupOpen(group.title)
            Section {
                if isOpen { ForEach(group.items) { ledgerButton($0, hasDraft: drafted.contains($0.id)) } }
            } header: {
                dateGroupHeader(group.title, count: group.items.count)
            }
        }
        // Hermes makes a session of every run of a scheduled job, and a busy schedule buried
        // the conversations (GitHub issue 19): the runs wait at the end, folded unless opened.
        if !runs.isEmpty {
            Section {
                if showScheduled { ForEach(runs) { ledgerButton($0, hasDraft: drafted.contains($0.id)) } }
            } header: {
                foldingHeader("Scheduled runs", count: runs.count, isOpen: $showScheduled)
            }
        }
    }

    // MARK: - Searching inside messages

    /// Conversations that match only inside their messages: the ones the search field's own
    /// filter (titles, previews) already lists above are left out.
    @ViewBuilder
    private var messageHitsSection: some View {
        let typed = query.trimmingCharacters(in: .whitespaces)
        let listed = Set(visibleLedger.map(\.id))
        let hits = messageHits.filter { !listed.contains($0.id) }
        if typed.count >= Self.messageSearchMinimum, searchingMessages || !hits.isEmpty || messageSearchProblem != nil {
            Section {
                ForEach(hits) { hit in
                    Button { open(hit.session, find: hit.findText(typed: typed)) } label: { messageHitRow(hit) }
                        .buttonStyle(.plain)
                        .opensConversation()
                        .disabled(opening != nil)
                }
                if let messageSearchProblem {
                    Label(messageSearchProblem, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
                }
            } header: {
                HStack(spacing: 6) {
                    groupHeader("In messages")
                    if searchingMessages { ProgressView().controlSize(.mini) }
                }
            }
        }
    }

    /// Title and when, then who said it and the matching words, marked.
    private func messageHitRow(_ hit: MessageSearchHit) -> some View {
        let session = hit.session
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(session.displayTitle).font(.body.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                if opening == session.id {
                    ProgressView().controlSize(.small)
                } else if let when = session.lastActiveDate {
                    Text(DateGroup.rowTime(when)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(Self.snippetText(hit, accent: Settings.shared.resolvedTheme.accent))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if hit.archived || !["api_server", "api-server", ""].contains(session.source ?? "") {
                HStack(spacing: 6) {
                    if !["api_server", "api-server", ""].contains(session.source ?? "") { capsule(session.sourceLabel) }
                    if hit.archived { capsule("Archived") }
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this conversation at the match")
    }

    private func capsule(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.quaternary, in: .capsule)
    }

    /// "You: …the >>>words<<< that matched…", the matched words in the accent and bold.
    static func snippetText(_ hit: MessageSearchHit, accent: Color) -> AttributedString {
        var out = AttributedString()
        if let speaker = hit.speaker {
            var who = AttributedString(speaker + ": ")
            who.font = .subheadline.weight(.semibold)
            out += who
        }
        for run in hit.runs {
            var piece = AttributedString(run.text)
            if run.matched {
                piece.font = .subheadline.weight(.semibold)
                piece.foregroundColor = accent
            }
            out += piece
        }
        return out
    }

    static let messageSearchMinimum = 2

    /// The search behind "In messages", a moment after typing stops. Quiet about a Hermes
    /// without the route (it predates 0.21): the titles above are then all there is.
    private func searchMessages() async {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard searchesMessages, typed.count >= Self.messageSearchMinimum else {
            messageHits = []
            messageSearchProblem = nil
            searchingMessages = false
            return
        }
        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
        searchingMessages = true
        defer { if !Task.isCancelled { searchingMessages = false } }
        do {
            let hits = try await HermesServeClient.shared.searchMessages(typed)
            guard !Task.isCancelled else { return }
            messageHits = hits
            messageSearchProblem = nil
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            messageHits = []
            if case let .http(status, _) = error as? TransportError, status == 404 {
                messageSearchProblem = nil
            } else {
                messageSearchProblem = "Couldn't search inside messages: \(error.localizedDescription)"
            }
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

    private func isDateGroupOpen(_ title: String) -> Bool {
        dateGroupExpansion[title] ?? (title == "Pinned" || title == "Today")
    }

    private func dateGroupHeader(_ title: String, count: Int) -> some View {
        let isOpen = isDateGroupOpen(title)
        return Button {
            withAnimation(.snappy) { dateGroupExpansion[title] = !isOpen }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                if !isOpen {
                    Text("\(count)").font(.caption2.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isOpen ? "Hide" : "Show") \(title.lowercased())")
        .accessibilityValue("\(count) chats")
        .accessibilityAddTraits(.isHeader)
    }

    private func marks(_ session: HermesSessionsAPI.SessionSummary) -> ChatMarks {
        ChatMarks(kind: activity.kind(of: session.id, open: conversation),
                  unread: activity.isUnread(session, open: conversation))
    }

    private func ledgerButton(_ session: HermesSessionsAPI.SessionSummary, hasDraft: Bool) -> some View {
        Group {
            if let server = session.otherServer {
                remoteButton(session, on: server, hasDraft: hasDraft)
            } else {
                ownButton(session, hasDraft: hasDraft)
            }
        }
    }

    /// Another server's row (All Servers): it opens on its server, and is changed there.
    private func remoteButton(_ session: HermesSessionsAPI.SessionSummary, on server: ServerTag, hasDraft: Bool) -> some View {
        Button { if !selecting { open(session) } } label: { ledgerRow(session, hasDraft: hasDraft, marks: ChatMarks(kind: nil, unread: session.unread == true)) }
            .buttonStyle(.plain)
            .opensConversation()
            .tag(session.id)
            .selectionDisabled()
            .disabled(opening != nil)
            .contextMenu {
                Button("Open on \(server.name)", systemImage: "server.rack") { open(session) }
            }
            .accessibilityHint("Opens it on \(server.name); Redde moves to that server")
    }

    private func ownButton(_ session: HermesSessionsAPI.SessionSummary, hasDraft: Bool) -> some View {
        let marks = marks(session)
        // The open conversation is read whatever it is marked: leaving it marks it read again.
        let canMark = session.id != conversation.serverSessionID
        return Button { if !selecting { open(session) } } label: { ledgerRow(session, hasDraft: hasDraft, marks: marks) }
            .buttonStyle(.plain)
            .opensConversation()
            .tag(session.id)
            .listRowBackground(groups.open == nil && session.id == conversation.serverSessionID ? Settings.shared.resolvedTheme.accent.opacity(0.08) : nil)
            .disabled(opening != nil)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if canMark {
                    Button { setUnread(session, !marks.unread) } label: {
                        Label(marks.unread ? "Read" : "Unread", systemImage: marks.unread ? "checkmark.message" : "message.badge")
                    }
                    .tint(Settings.shared.resolvedTheme.accent)
                }
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
                if canMark {
                    Button(marks.unread ? "Mark as Read" : "Mark as Unread", systemImage: marks.unread ? "checkmark.message" : "message.badge") {
                        setUnread(session, !marks.unread)
                    }
                }
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

    private func ledgerRow(_ session: HermesSessionsAPI.SessionSummary, hasDraft: Bool, marks: ChatMarks) -> some View {
        rowBody(session, hasDraft: hasDraft, marks: marks)
            .unreadDot(marks.unread && !selecting)
            .accessibilityElement(children: .combine)
            .accessibilityValue(marks.spoken)
            .accessibilityHint("Opens this session")
    }

    /// Title and when on the first line, the last thing said beneath; where it came from when
    /// it wasn't this app.
    private func rowBody(_ session: HermesSessionsAPI.SessionSummary, hasDraft: Bool, marks: ChatMarks) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if session.pinned == true {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange).accessibilityLabel("Pinned")
                }
                Text(session.displayTitle).font(.body.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                if opening == session.id || marks.kind == .working {
                    ProgressView().controlSize(.small)
                } else if let when = session.lastActiveDate {
                    Text(DateGroup.rowTime(when)).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                if marks.kind == .needsYou { NeedsYouTag() }
                if hasDraft { draftMark }
                // Another server's, with All Servers on: which.
                if let server = session.otherServer {
                    Label(server.name, systemImage: "server.rack")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                        .lineLimit(1)
                        .fixedSize()
                }
                // Another profile's, with All Profiles on: whose it is.
                if let route = session.elsewhere {
                    Text(profileLabel(route.profile))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Settings.shared.resolvedTheme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Settings.shared.resolvedTheme.accent.opacity(0.14), in: .capsule)
                        .lineLimit(1)
                        .fixedSize()
                }
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
            ledger = Self.demoProjects.flatMap { $0.lanes.flatMap(\.sessions) } + Self.demoScheduledRuns
            // `-echo.demoAllServers`: two chats of another server's among them (All Servers).
            if DevHooks.has("-echo.demoAllServers") {
                ledger = (ledger + Self.demoOtherServer).sorted { ($0.lastActiveDate ?? .distantPast) > ($1.lastActiveDate ?? .distantPast) }
                serversUnreachable = ["Cabin"]
            }
            if DevHooks.demoBots {
                botDirectory.set(Self.demoBots, key: settings.connectionKey)
                groups.set(rooms: [.demo, .demoDesktop], supported: true, writable: true, key: settings.connectionKey)
                // `-echo.openGroup [desktop]`: that group chat open, or the Hermes Desktop one (screenshots).
                if DevHooks.has("-echo.openGroup"), !Self.openedDemoGroup {
                    Self.openedDemoGroup = true   // once: the list loads again each time it opens
                    // After the launch's conversation has loaded: a change of conversation closes
                    // a group chat, and the iPad's sidebar gets here before that load is done.
                    let room: GroupRoom = DevHooks.value("-echo.openGroup") == "desktop" ? .demoDesktop : .demo
                    Task {
                        await conversation.initialLoad?.value
                        try? await Task.sleep(for: .milliseconds(300))
                        opened(room: room)
                    }
                }
                // `-echo.demoMuted`: Scout and the demo group chat muted (screenshots).
                if DevHooks.has("-echo.demoMuted"), !Mutes.isMuted("bot:scout") {
                    Mutes.mute("bot:scout", for: .untilUnmuted)
                    Mutes.mute("room:" + GroupRoom.demo.id, for: .eightHours)
                }
                // `-echo.topology`: the Topology map open (screenshots).
                if DevHooks.has("-echo.topology"), !Self.openedDemoTopology {
                    Self.openedDemoTopology = true
                    showingTopology = true
                }
                // `-echo.botVoice <bot>`: that bot's voice being picked (screenshots).
                if let which = DevHooks.value("-echo.botVoice") { voicing = Self.demoBots.bots.first { $0.name == which } }
                // `-echo.botSchedules <bot>`: that bot's schedules open (screenshots).
                if let which = DevHooks.value("-echo.botSchedules") { scheduling = Self.demoBots.bots.first { $0.name == which } }
                // `-echo.botEditor new|<bot>`: New Bot, or that bot's settings, open (screenshots).
                if let which = DevHooks.value("-echo.botEditor") {
                    editingBot = which == "new" ? .new : Self.demoBots.bots.first { $0.name == which }.map { .edit($0) }
                }
            }
            if DevHooks.demoMarks {
                ledger += Self.demoMarkedRows
                activity.showDemo(["demo-1": .working, "demo-marks-2": .needsYou], bots: ["scout": .working, "fixit": .needsYou], unreadBots: ["writer"],
                                  rooms: [GroupRoom.demo.id: .needsYou], unreadRooms: [GroupRoom.demoDesktop.id])
            }
            ledgerError = nil
            return
        }
        #endif
        do {
            guard let backend = SessionBackend.list(conversation) else {
                ledgerError = "Add the gateway API key in Settings."
                return
            }
            let sessions = allProfiles
                ? try await SessionBackend.everyProfile(conversation, bots: botDirectory.roster)
                : try await backend.listSessions()
            guard current else { return }
            ledger = sessions
            activity.listed(sessions)
            conversation.noteServerTitles(sessions)
            // Every other saved server's, once they answer: this server's rows don't wait for them.
            if allServers, settings.servers.count > 1 {
                let others = await AllServers.otherServers(settings)
                guard current else { return }
                // One Hermes saved twice (its Dashboard and its API) lists its chats once.
                var seen = Set(sessions.map(\.id))
                let theirs = others.rows.filter { seen.insert($0.id).inserted }
                ledger = (sessions + theirs).sorted { ($0.lastActiveDate ?? .distantPast) > ($1.lastActiveDate ?? .distantPast) }
                serversUnreachable = others.unreachable
            } else {
                serversUnreachable = []
            }
            // Bots and projects are a bonus; a failure here must not hide the flat list.
            if botsHere, settings.showBots {
                if apiBotsOnly {
                    activity.listed(await botDirectory.refreshAPI().bots)
                } else {
                    if let roster = try? await botDirectory.refresh() { activity.listed(roster.bots) }
                    await groups.refresh()
                    activity.listed(groups.rooms)
                }
            }
            if viaServe {
                let all = (try? await HermesServeClient.shared.projectTree()) ?? []
                let tree = HermesServeClient.Project.listed(all)
                guard current else { return }
                ProjectDirectory.shared.set(all, key: key)
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
            try await SessionBackend.owning(session, conversation)?.rename(session.id, to: t)
        }
    }

    private func setPinned(_ session: HermesSessionsAPI.SessionSummary, _ pinned: Bool) {
        housekeeping(session) {
            try await SessionBackend.owning(session, conversation)?.setPinned(session.id, pinned)
        }
    }

    /// The open conversation changed: both have just been marked read on the host (the one left,
    /// the one opened), and the rows say so now rather than at the next fetch.
    private func openChanged(from old: String?, to new: String?) {
        for id in [old, new].compactMap(\.self) {
            if let i = ledger.firstIndex(where: { $0.id == id }), ledger[i].unread == true { ledger[i].unread = false }
        }
    }

    /// Mark as Read / Mark as Unread. A row the host marks (the Dashboard's) changes at once.
    private func setUnread(_ session: HermesSessionsAPI.SessionSummary, _ unread: Bool) {
        if let i = ledger.firstIndex(where: { $0.id == session.id }), ledger[i].unread != nil { ledger[i].unread = unread }
        if unread {
            activity.markUnread(session.id, conversation: conversation)
        } else {
            activity.markRead(session.id, conversation: conversation)
        }
    }

    /// While the list is on screen: what the host is doing, every few seconds (a turn under way,
    /// one waiting on the person), and the conversations fetched again when a turn ends or, at
    /// most every thirty seconds, when the Dashboard says they changed.
    private func watchActivity() async {
        guard usesLedger, isShowing, scenePhase == .active else { return }
        #if DEBUG
        if DevHooks.demoProjects { return }
        #endif
        var fetchedAt = Date.now
        var botsAt = Date.now
        var changes = activity.changes
        while !Task.isCancelled {
            let before = Set(activity.live.keys), roomsBefore = Set(activity.liveRooms.keys)
            let reached = await activity.look(conversation)
            let ended = !before.subtracting(activity.live.keys).isEmpty
            let changed = activity.changes != changes && Date.now.timeIntervalSince(fetchedAt) >= 30
            if ended || changed {
                changes = activity.changes
                fetchedAt = .now
                botsAt = .now
                await refresh()
            } else if !roomsBefore.subtracting(activity.liveRooms.keys).isEmpty {
                // A group chat went quiet: the group chats alone again, for what is new in it (the
                // whole list was fetched again for each bot's turn, some seven calls a time).
                await groups.refresh()
                activity.listed(groups.rooms)
            } else if botsHere, settings.showBots, Date.now.timeIntervalSince(botsAt) >= 15 {
                // The bots' chats and workers, which the gateway's list doesn't all show (a bot's
                // worker runs on its own): their last activity, now and then.
                botsAt = .now
                if apiBotsOnly {
                    activity.listed(await botDirectory.refreshAPI().bots)
                } else {
                    if let roster = try? await botDirectory.refresh() { activity.listed(roster.bots) }
                    // The group chats' latest events, for what is new in them.
                    await groups.refresh()
                    activity.listed(groups.rooms)
                }
            }
            // A host that can't be asked is asked less often.
            try? await Task.sleep(for: reached ? .seconds(4) : .seconds(30))
        }
    }

    /// Archived sessions leave the list but stay in Hermes's database (the dashboard can restore them).
    private func archive(_ session: HermesSessionsAPI.SessionSummary) {
        ledger.removeAll { $0.id == session.id }
        housekeeping(session) {
            try await SessionBackend.owning(session, conversation)?.archive(session.id)
            if session.id == conversation.serverSessionID { conversation.reset() }
        }
    }

    /// Fork copies the transcript into a new session and opens it.
    private func fork(_ session: HermesSessionsAPI.SessionSummary) {
        let title = "\(session.displayTitle) (fork)"
        housekeeping(session) {
            if let forked = try await SessionBackend.owning(session, conversation)?.fork(session.id, title: title) {
                try await conversation.loadLedgerSession(forked)
                opened()
            }
        }
    }

    private func delete(_ session: HermesSessionsAPI.SessionSummary) {
        ledger.removeAll { $0.id == session.id }
        housekeeping(session) {
            try await SessionBackend.owning(session, conversation)?.delete(session.id)
            if let local = store.summaries.first(where: { $0.serverSessionID == session.id }) { conversation.delete(id: local.id) }
        }
    }

    /// Swaps the transcript to this session. Throws, so callers can show what went wrong.
    private func load(_ session: HermesSessionsAPI.SessionSummary) async throws {
        // Another server's: the app moves to that server, and opens it there as one of its own.
        if let server = session.otherServer {
            guard settings.servers.contains(where: { $0.id == server.id }) else { throw AllServers.Gone(name: server.name) }
            ServerSwitcher.switchTo(server.id, conversation: conversation)
            var own = session
            own.otherServer = nil
            return try await load(own)
        }
        // Another profile's opens in that profile, by the way it was listed.
        if let route = session.elsewhere {
            if route.viaAPI {
                try await conversation.loadLedgerSession(session, elsewhere: route)
            } else {
                try await conversation.loadServeSession(session, elsewhere: route)
            }
        } else if viaServe {
            try await conversation.loadServeSession(session)
        } else {
            try await conversation.loadLedgerSession(session)
        }
        opened()
    }

    /// Opens a conversation; `find` opens Find in it on those words once it is on screen.
    private func open(_ session: HermesSessionsAPI.SessionSummary, find: String? = nil) {
        opening = session.id
        Task {
            do {
                try await load(session)
                if let find { conversation.findRequest = find }
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
        guard !selecting else { return }
        Task {
            guard let full = await store.loadRecord(id: copy.id) else { return }
            conversation.load(full)
            savedCopyOffered = nil
            opened()
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
            let isOpen = isDateGroupOpen(group.title)
            Section {
                if isOpen { ForEach(group.items) { localButton($0) } }
            } header: {
                dateGroupHeader(group.title, count: group.items.count)
            }
        }
    }

    private func localButton(_ record: ConversationSummary) -> some View {
            Button {
                if selecting { return }
                // Decoded off the main actor (a long transcript is a big file), and opened once it
                // is, so the conversation before doesn't show in the meantime.
                Task {
                    if let full = await store.loadRecord(id: record.id) { conversation.load(full) }
                    opened()
                }
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
    @Environment(Conversation.self) private var conversation
    @State private var activity = ChatActivity.shared

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
        let marks = ChatMarks(kind: activity.kind(of: session.id, open: conversation),
                              unread: activity.isUnread(session, open: conversation))
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.displayTitle).font(.body).lineLimit(1)
                Spacer()
                if opening == session.id || marks.kind == .working {
                    ProgressView().controlSize(.small)
                } else if session.id == currentID {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
            HStack(spacing: 6) {
                if marks.kind == .needsYou { NeedsYouTag() }
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
        .unreadDot(marks.unread)
        .accessibilityElement(children: .combine)
        .accessibilityValue(marks.spoken)
        .accessibilityHint("Opens this session")
    }
}

// MARK: - The rows' marks

/// The list looks at what the host is doing while it is on screen (`key` changes when that
/// starts or stops), and hears when the open conversation changes. A modifier of its own: the
/// list's chain of them was more than the type checker would take.
private struct WatchingActivity: ViewModifier {
    var key: String
    var openID: String?
    var watch: () async -> Void
    var opened: (String?, String?) -> Void

    func body(content: Content) -> some View {
        content
            .task(id: key) { await watch() }
            .onChange(of: openID) { old, new in opened(old, new) }
    }
}

/// What a conversation's row shows of it (`ChatActivity`): the agent working (a spinner where
/// the time goes), waiting on the person ("Needs you"), or a reply not yet seen (a dot).
struct ChatMarks: Equatable {
    var kind: ChatActivity.Kind?
    var unread: Bool
    /// A bot's chat or a group chat the person muted (`Mutes`).
    var muted = false

    /// Read out with the row.
    var spoken: String {
        [unread ? "Unread" : nil, muted ? "Muted" : nil,
         kind == .working ? "Agent working" : kind == .needsYou ? "Needs you" : nil].compactMap(\.self).joined(separator: ", ")
    }
}

/// "Needs you", in front of a row's second line: the agent waits on an answer, an approval or a
/// password.
struct NeedsYouTag: View {
    var body: some View {
        Text("Needs you")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.orange.opacity(0.15), in: .capsule)
            .fixedSize()
    }
}

extension View {
    /// A dot in the row's leading margin, as Messages marks an unread conversation. In the
    /// margin, so the titles of read and unread rows still line up.
    func unreadDot(_ shown: Bool) -> some View {
        overlay(alignment: .leading) {
            if shown {
                Circle()
                    .fill(Settings.shared.resolvedTheme.accent)
                    .frame(width: 9, height: 9)
                    .offset(x: -14)
                    .accessibilityHidden(true)
            }
        }
    }
}

#if DEBUG
extension ConversationsList {
    /// `-echo.openGroup` has opened its group chat.
    static var openedDemoGroup = false
    /// `-echo.topology` has opened the map.
    static var openedDemoTopology = false

    /// Another server's chats, for `-echo.demoAllServers`.
    static var demoOtherServer: [HermesSessionsAPI.SessionSummary] {
        let json = """
        [{"id":"workshop-1","title":"Garage door sensor","source":"desktop","started_at":1772998000,"last_active":1772999500,"message_count":8,"preview":"The sensor reads closed again."},
         {"id":"workshop-2","title":"Printer queue","source":"desktop","started_at":1772900000,"last_active":1772950000,"message_count":3}]
        """
        let tag = ServerTag(id: UUID(uuidString: "00000000-0000-4000-8000-00000000F00D")!, name: "Workshop")
        return ((try? JSONDecoder().decode([HermesSessionsAPI.SessionSummary].self, from: Data(json.utf8))) ?? []).map {
            var row = $0
            row.otherServer = tag
            return row
        }
    }

    /// One project Hermes found, with one lane and two sessions (enough to reach
    /// ProjectSessionsView and tap a row), and one someone made, still empty.
    static var demoBots: BotRoster {
        BotRoster(bots: [
            HermesBot(name: "default", isDefault: true, lastActive: .now.addingTimeInterval(-3_600), preview: "Done: the reminder is set for 4 pm."),
            HermesBot(name: "scout", title: "Scout", description: "Finds things out", lastActive: .now.addingTimeInterval(-600),
                      preview: "Three trails under two hours from you, all open."),
            HermesBot(name: "writer", displayName: "Quill", description: "Edits and drafts", lastActive: .now.addingTimeInterval(-120),
                      preview: "Want me to carry that through the next paragraph?"),
            HermesBot(name: "fixit", title: "Fix-it", description: "Looks after the home server"),
        ].map { bot in
            // `-echo.demoPicture`: Scout has a picture from Hermes Desktop.
            var bot = bot
            bot.hasPicture = bot.name == "scout" && DevHooks.has("-echo.demoPicture")
            // The models they run on, for the Topology map.
            bot.model = ["default": "qwen3.6-35b-a3b", "scout": "qwen3.6-35b-a3b", "writer": "anthropic/claude-sonnet-4.5",
                         "fixit": "gemma-4-12b"][bot.name]
            return bot
        } + extraDemoBots + claudeDemoBot)
    }

    /// `-echo.demoClaudeBot`: a coding bot that works through Claude Code, as the butler setup's (Topology).
    private static var claudeDemoBot: [HermesBot] {
        guard DevHooks.has("-echo.demoClaudeBot") else { return [] }
        return [HermesBot(name: "claude", title: "Claude", description: "Coding worker: does each card with Claude Code, never seeing a key.",
                          model: "qwen3.6-35b-a3b", lastActive: .now.addingTimeInterval(-900))]
    }

    /// `-echo.demoBotCount n`: the sample bots, and more up to n (for when they fold).
    private static var extraDemoBots: [HermesBot] {
        let names = ["Home", "Chef", "Coach", "Atlas", "Penny", "Tutor", "Ledger", "Nova"]
        let count = DevHooks.value("-echo.demoBotCount").flatMap(Int.init) ?? 0
        return names.prefix(max(0, count - 4)).map { HermesBot(name: $0.lowercased(), title: $0) }
    }

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

    /// Two runs of a scheduled job, in no project: they fold away under Scheduled runs.
    /// Two more for `-echo.demoMarks`: a reply not yet seen, and the agent waiting on an approval.
    static var demoMarkedRows: [HermesSessionsAPI.SessionSummary] {
        let json = """
        [{"id":"demo-marks-1","title":"Grocery list","source":"api_server","started_at":1772999800,"last_active":1773000300,"message_count":4,
          "preview":"Here's what I found for this week","unread":true},
         {"id":"demo-marks-2","title":"Server cleanup","source":"api_server","started_at":1772999700,"last_active":1772999900,"message_count":6,
          "preview":"Run rm -rf ~/old-backups?","unread":false}]
        """
        return (try? JSONDecoder().decode([HermesSessionsAPI.SessionSummary].self, from: Data(json.utf8))) ?? []
    }

    static var demoScheduledRuns: [HermesSessionsAPI.SessionSummary] {
        let json = """
        [{"id":"demo-cron-1","title":"Morning briefing","source":"cron","started_at":1772998000,"last_active":1772998100,"message_count":2},
         {"id":"demo-cron-2","title":"Morning briefing","source":"cron","started_at":1772911600,"last_active":1772911700,"message_count":2}]
        """
        return (try? JSONDecoder().decode([HermesSessionsAPI.SessionSummary].self, from: Data(json.utf8))) ?? []
    }
}
#endif

/// The other layout's list was searching (an iPhone Duo opened or closed): so is this one
/// (`LayoutCarry`).
private struct ListSearchCarry: ViewModifier {
    @Binding var query: String
    let wide: Bool

    func body(content: Content) -> some View {
        content
            .onAppear {
                if let carried = LayoutCarry.shared.listSearch, carried.wide != wide, query.isEmpty { query = carried.query }
                LayoutCarry.shared.listSearch = .init(wide: wide, query: query)
            }
            .onChange(of: query) { LayoutCarry.shared.listSearch = .init(wide: wide, query: query) }
    }
}
