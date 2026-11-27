import SwiftUI

// The chat list's page: its sheets, the menus in its title, its toolbar and the work it does while it shows.

extension ConversationsList {
    /// What the list's menus and rows bring up, and its keyboard tabs.
    func listSheets(_ content: some View) -> some View {
        content
        .sheet(isPresented: $showSettings) { SettingsView() }
        // Group chats, from the Bots section: here, not on the section, which a list builds lazily.
        .sheet(isPresented: $makingGroup) {
            NewGroupChatView(bots: listedBots, mainName: settings.headerTitle) { room in
                Task { await groups.refresh() }
                opened(room: room)
            }
        }
        .sheet(item: $voicing) { BotVoicePicker(bot: $0, mainName: settings.headerTitle) }
        .sheet(isPresented: $voicingMain, onDismiss: { WatchLink.shared.push() }) {
            NavigationStack {
                // Its sections, in a form as Settings has them: alone, each was laid out apart and each
                // took the Done (2026-10-26, from Sol's ••• menu).
                Form { VoiceSettings() }
                    .navigationTitle("\(settings.headerTitle)'s Voice")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { voicingMain = false } } }
            }
            .holdsWakePhrases(.voicePicker)
        }
        .sheet(item: $scheduling) { BotSchedulesView(bot: $0, mainName: settings.headerTitle) }
        .sheet(item: $modelsFor) { bot in
            NavigationStack {
                ModelsProvidersView(profile: bot.name, owner: bot.label(mainName: settings.headerTitle))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { modelsFor = nil } } }
            }
        }
        .sheet(item: $earlierFor) { bot in
            EarlierChatsView(bot: bot, mainName: settings.headerTitle,
                             read: { readEarlier($0, of: bot) }, bringBack: { bringBackEarlier($0, as: bot) })
        }
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
                // The drawer's places, from a keyboard (they were the classic list's tabs).
                Button("Chats") { drawerPage = nil }.keyboardShortcut("1", modifiers: .command)
                Button("Planned") { drawerPage = .planned }.keyboardShortcut("2", modifiers: .command)
                Button("Board") { drawerPage = .board }.keyboardShortcut("3", modifiers: .command)
                Button("Made") { drawerPage = .made }.keyboardShortcut("4", modifiers: .command)
            }
            .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }

    /// Switch servers without going through Settings.
    /// The server the app is on, or All Servers: every saved server's chats in the list, the one
    /// the app is on still the one new chats start on (a Reddit request, 2026-10-21).
    var serverMenu: some View {
        let title = allServers ? String(localized: "All Servers") : settings.activeServer?.title ?? ""
        return Menu {
            Button { allServers = true } label: {
                Label("All Servers", systemImage: allServers ? "checkmark" : "square.stack.3d.up")
            }
            Divider()
            // Grouped by the kind of agent, once there is more than one kind.
            let groups = ServersView.grouped(settings.servers)
            ForEach(groups, id: \.kind) { group in
                Section(groups.count > 1 ? group.kind.title : "") {
                    ForEach(group.servers) { server in
                        Button {
                            allServers = false
                            ServerSwitcher.switchTo(server.id, conversation: conversation)
                        } label: {
                            if !allServers, server.id == settings.activeServerID { Label(server.title, systemImage: "checkmark") } else { Text(server.title) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: allServers ? "square.stack.3d.up" : "server.rack")
                Text(title).lineLimit(1)
                if allServers, let here = settings.activeServer?.title {
                    Text("· new chats on \(here)").foregroundStyle(.secondary).lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down").chatFont(.caption2, weight: .semibold)
            }
            .chatFont(.subheadline, weight: .medium)
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
    /// The agent picker as the chat list's title, on the iPhone's Chats (2026-11-06).
    var pickerInTitle: Bool {
        #if os(iOS)
        !wideDetail && showsProfileMenu
        #else
        false
        #endif
    }

    var showsProfileMenu: Bool { settings.transport.isHermes && (allProfiles || menuProfiles.count > 1) || showsAgentMenu }

    /// On a bridge with more than one agent, the title's menu is its agents', as a Hermes's is its
    /// profiles' (asked 2026-11-14: All Agents was out of sight in the connection's setup).
    var showsAgentMenu: Bool {
        settings.transport == .acp && (bridgeAgents.count > 1 || !bridgeAgents.isEmpty && settings.servers.contains { $0.transport.kind == .hermes })
    }

    var profileMenu: some View { profileMenu(inTitle: false) }

    @ViewBuilder
    func profileMenu(inTitle: Bool) -> some View {
        if settings.transport == .acp { agentMenu(inTitle: inTitle) } else { hermesProfileMenu(inTitle: inTitle) }
    }

    /// All Agents, then each of the bridge's: every agent's chats in one list, or one agent's.
    private func agentMenu(inTitle: Bool) -> some View {
        let all = settings.acpAllAgents
        let title = all ? String(localized: "All Agents", comment: "The chat list's agent menu on a bridge: every agent's chats in one list")
            : bridgeAgents.first { $0.id == settings.acpAgent }?.name ?? settings.headerTitle
        return Menu {
            Button { settings.acpAllAgents = true } label: {
                Label { Text("All Agents", comment: "The chat list's agent menu on a bridge: every agent's chats in one list") }
                    icon: { Image(systemName: all ? "checkmark" : "rectangle.stack") }
            }
            Divider()
            ForEach(bridgeAgents) { agent in
                Button {
                    let moved = agent.id != settings.acpAgent
                    settings.acpAllAgents = false
                    settings.acpAgent = agent.id
                    // The chat open is another agent's: a new one with this agent.
                    if moved, conversation.serverSessionID != nil || conversation.hasMessages { conversation.reset() }
                } label: {
                    if !all, agent.id == settings.acpAgent { Label(agent.name, systemImage: "checkmark") } else { Text(agent.name) }
                }
            }
            // And the Hermes servers, one tap away (2026-11-27, on the iPad: "the agents selection
            // does not list Hermes, only the Other agents").
            let hermes = settings.servers.filter { $0.transport.kind == .hermes }
            if !hermes.isEmpty {
                Section(Transport.Kind.hermes.title) {
                    ForEach(hermes) { server in
                        Button {
                            allServers = false
                            ServerSwitcher.switchTo(server.id, conversation: conversation)
                        } label: {
                            Label(server.title, systemImage: Transport.Kind.hermes.symbol)
                        }
                    }
                }
            }
        } label: {
            if inTitle {
                HStack(spacing: 4) {
                    Text(title).lineLimit(1).font(.headline)
                    Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: all ? "rectangle.stack" : "terminal")
                    Text(title).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").chatFont(.caption2, weight: .semibold)
                }
                .chatFont(.subheadline, weight: .medium)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("agent-menu")
        .accessibilityLabel(Text("Agent", comment: "ACP connection field: which of the bridge's agents"))
        .accessibilityValue(title)
    }

    private func hermesProfileMenu(inTitle: Bool) -> some View {
        let current = settings.profileName ?? ProfileCatalog.defaultID
        // With All Profiles on, where new chats start still shows when it isn't the main agent:
        // the app was left on another profile once and nothing said so (2026-10-29).
        let title = !allProfiles ? profileLabel(current)
            : current == ProfileCatalog.defaultID ? String(localized: "All Profiles")
            : String(localized: "All Profiles · new in \(profileLabel(current))", comment: "The chat list's profile menu: every profile's chats shown; new chats start on this one")
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
            if inTitle {
                HStack(spacing: 4) {
                    Text(title).lineLimit(1).font(.headline)
                    Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: allProfiles ? "rectangle.stack" : "person.crop.circle")
                    Text(title).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").chatFont(.caption2, weight: .semibold)
                }
                .chatFont(.subheadline, weight: .medium)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityLabel("Profile")
        .accessibilityValue(title)
    }

    /// What a profile is called in the list: its bot's name, the name the Dashboard gave it, or its
    /// own.
    func profileLabel(_ name: String) -> String {
        if let bot = botDirectory.roster?.named(name), !bot.isDefault { return bot.label(mainName: settings.headerTitle) }
        if name == ProfileCatalog.defaultID { return settings.headerTitle }
        return knownProfiles.first { $0.name == name }?.title ?? name
    }

    /// `-echo.demoDay`: no Projects in the day's video (`DemoDay`).
    var hidesProjectsForDemo: Bool {
        #if DEBUG
        DemoDay.on || DemoAgents.on
        #else
        false
        #endif
    }

    var sessionsList: some View {
        // In stages, the list behind AnyView, as `body` is (see ContentView.body): in one chain an
        // unoptimized build kept 300 KB on the stack here, and Debug builds overflowed the phone's
        // 1 MB main-thread stack at launch (2026-11-13).
        listWork(listChrome(AnyView(listPage)))
    }

    var listPage: some View {
        // The selection binding belongs to "Select" mode only. A sidebar List that always has
        // one treats a row tap as selection and swallows the NavigationLink, so project folders
        // never push on iPad.
        List(selection: selecting ? $selected : nil) {
            Group {
            if arrangingBots {
                botsSection
            } else if !selecting {
                // Type-erased: its view type inside this list's overflowed the main thread's
                // stack at launch on the phone (Release, 11-13), demangling the list's type.
                AnyView(drawerRows)
            } else if usesLedger {
                ledgerSection
            } else {
                localSection
            }
            }
            // Every row on the theme's page (nil: the system's rows, as before).
            .listRowBackground(settings.theme.listPage)
        }
        #if os(macOS)
        .listStyle(.sidebar)   // the Mac's sidebar: its translucent material, its rows
        #else
        .listStyle(.plain)
        #endif
        // The theme's page behind the chats (2.4: Paper and Paper White looked half done on the
        // system's white); a theme that leaves the page to the system keeps the list as it was.
        .themedPage(settings.theme.listPage)
        .navigationDestination(item: $drawerPage) { drawerDestination($0).sidebarPage(Text($0.title)) }
        .task(id: "\(isShowing)|\(scenePhase == .active && pace.onScreen)") { await watchDrawerWaits() }
        .navigationDestination(for: ProjectRoute.self) { route in
            if let project = projects.first(where: { $0.id == route.id }) {
                ProjectSessionsView(project: project, open: load, currentID: conversation.serverSessionID,
                                    startNew: { startNew(in: $0) }, refreshes: viaServe)
                    .sidebarPage(Text(project.label))
            }
        }
        .environment(\.editMode, .constant(selecting || arrangingBots ? .active : .inactive))
    }

    /// The list's toolbar, its search, and the sheets its rows open.
    private func listChrome(_ content: some View) -> some View {
        content
        .toolbar {
            #if os(iOS)
            if pickerInTitle, !selecting, !arrangingBots {
                ToolbarItem(placement: .principal) { profileMenu(inTitle: true).tint(.primary) }
            }
            #endif
            ToolbarItem(placement: .topBarLeading) {
                if selecting {
                    Button("Cancel") { selecting = false; selected = [] }
                } else if !arrangingBots {
                    // (On the Mac, Settings is the app menu's, and New Conversation the chat's toolbar's.)
                    #if os(iOS)
                    Button("Settings", systemImage: "gearshape") { openSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                        .accessibilityIdentifier("list.settings")
                    #endif
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if arrangingBots {
                    Button("Done") { withAnimation { arrangingBots = false } }
                        .fontWeight(.semibold)
                } else if selecting {
                    Button(selected.count == visibleIDs.count ? String(localized: "Deselect all") : String(localized: "Select all")) {
                        selected = selected.count == visibleIDs.count ? [] : visibleIDs
                    }
                } else {
                    if !visibleIDs.isEmpty {
                        Button("Select", systemImage: "checkmark.circle") { selecting = true }
                    }
                    #if os(iOS)
                    // Held: New Goal (2.4) too.
                    if AcpAgentChoices.asks(settings) {
                        // Every agent on the bridge in one list: New Chat asks which.
                        Menu {
                            AcpAgentChoices(settings: settings) {
                                conversation.reset()
                                opened()
                            }
                            NewChatElsewhere(settings: settings, conversation: conversation) { opened() }
                            Divider()
                            Button { addingGoal = true } label: {
                                Label { Text("New Goal", comment: "Button: opens the sheet to set a new goal") } icon: { Image(systemName: "flag.checkered") }
                            }
                        } label: {
                            Label("New conversation", systemImage: "square.and.pencil")
                        }
                        .accessibilityIdentifier("new-chat-agents")
                    } else {
                        Menu {
                            // Held: a chat on another connection too (Claude Code from Hermes).
                            NewChatElsewhere(settings: settings, conversation: conversation) { opened() }
                            Divider()
                            Button { addingGoal = true } label: {
                                Label { Text("New Goal", comment: "Button: opens the sheet to set a new goal") } icon: { Image(systemName: "flag.checkered") }
                            }
                        } label: {
                            Label("New conversation", systemImage: "square.and.pencil")
                        } primaryAction: {
                            conversation.reset()
                            opened()
                        }
                    }
                    #endif
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
        .confirmationDialog(String(localized: "Delete \(selected.count) conversations?"), isPresented: $confirmBulkDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { bulkDelete() }
        } message: {
            usesLedger ? Text("They are removed from the Redde ledger for every client.") : Text("This only removes them from this phone.")
        }
        .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
        .sheet(isPresented: $addingGoal) { NewGoalSheet().macSheetSize() }
        // A list's tile on the Today row (`TodayStrip`): the list, to check off and add to.
        .sheet(isPresented: Binding(get: { TodayLists.shared.shownID != nil }, set: { if !$0 { TodayLists.shared.shownID = nil } })) {
            NavigationStack {
                // A help line tapped (Agent Can Help): a new conversation with the agent, open.
                TodayListView(ask: { words in
                    TodayLists.shared.shownID = nil
                    if conversation.hasMessages || !conversation.outbox.isEmpty { conversation.reset() }
                    conversation.send(words)
                    opened()
                })
            }
            .macSheetSize()
        }
        // The person's lists, when the chat list shows and when Redde comes back to the front; and
        // what the calendar says of their appointments, at most every six hours (plugin 1.54).
        .task(id: "\(settings.connectionKey)|\(scenePhase == .active)") {
            if scenePhase == .active {
                await TodayLists.shared.refresh()
                await Appointments.send()
            }
        }
        .onChange(of: GoalsInbox.shared.opening, initial: true) { _, id in
            guard let id else { return }
            GoalsInbox.shared.opening = nil
            shownGoal = GoalsInbox.shared.goals.first { $0.id == id }
                ?? GoalReport(id: id, title: "", agent: "", done: 0, total: 0, headline: "", at: .now, failed: false)
        }
        .sheet(item: $shownGoal) { goal in
            NavigationStack {
                GoalView(goalID: goal.id)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { shownGoal = nil } } }
            }
            .macSheetSize(width: 600, height: 760)
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search conversations")
        .modifier(ListSearchCarry(query: $query, wide: wide))
    }

    /// Loading, filtering and watching the list, and its prompts.
    private func listWork(_ content: some View) -> some View {
        content
        // Keyed on the server and profile: a switch reloads the list (and the iPad sidebar,
        // which stays up).
        // Not while the iPhone's panel is closed: it loads when it opens (isShowing below).
        // (All Profiles turned on or off loads the list again too.)
        .task(id: listKey) { if usesLedger, isShowing { await refresh() } }
        // All Servers off: the other servers' chats go at once, as their bots do.
        .onChange(of: allServers) { dropOtherServers() }
        // With All Servers on, a Hermes server's bots stay in the list while the app is on a bridge.
        .task(id: "\(allServers)|\(settings.activeServerID)|\(settings.showBots)") { await readAwayBots() }
        // A bridge's agents, for the title's agent menu.
        .task(id: "\(settings.transport == .acp)|\(settings.acpURL)") {
            bridgeAgents = settings.transport == .acp ? await AcpAgents.refresh(settings) : []
        }
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
        // The calendar's next event, kept to the minute while the list is on screen and shows it:
        // the strip's Up Next tile, or the Today page's calendar tile. The only such loop (the
        // Today page had its own too, and this one ran with a chat open over the list).
        .task(id: "\(settings.todayUpNext)|\(isShowing)|\(scenePhase == .active && pace.onScreen)") {
            let onPage = !UserDefaults.standard.bool(forKey: TodayStrip.calendarHiddenKey)
            guard settings.todayUpNext || onPage, isShowing, scenePhase == .active, pace.onScreen else { return }
            while !Task.isCancelled {
                CalendarUpNext.shared.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: isShowing) { _, showing in
            if showing, usesLedger { Task { await refresh() } }
        }
        .modifier(WatchingActivity(key: "\(settings.connectionKey)|\(isShowing)|\(scenePhase == .active && pace.onScreen)",
                                   openID: conversation.serverSessionID, watch: watchActivity, opened: openChanged))
        .onChange(of: query, initial: true) { filterLedger() }
        .task(id: "\(query)|\(settings.connectionKey)") { await searchMessages() }
        .onChange(of: ledgerInputs) { filterLedger() }
        .sheet(item: $usageFor) { SessionUsageView(session: $0) }
        .modifier(GroupRenameAlert(room: $renamingRoom, text: $roomRenameText, save: rename))
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

    /// What the list of conversations is made from: the server's, and the bots' chats.
    private struct LedgerInputs: Equatable {
        let ledger: [HermesSessionsAPI.SessionSummary]
        let bots: [HermesBot]
    }
    private var ledgerInputs: LedgerInputs { LedgerInputs(ledger: ledger, bots: listedBots) }

    private func filterLedger() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        // Incognito chats aren't listed, here or (hidden on the Dashboard) by any app, until they go.
        let incognito = Incognito.sessions(on: settings.activeServerID.uuidString)
            .union(conversation.isIncognito ? [conversation.serverSessionID].compactMap(\.self) : [])
        // A bot's chat is its bot's, in the Bots section, never a row: on the Dashboard it is hidden,
        // and one made over the Hermes API before 2026-10-29 isn't.
        var listed = ledger.filter { !incognito.contains($0.id) && $0.title != BotChat.title }
        // The bots' chats come in among them too, by when they were last used, labelled (asked
        // 2026-11-04): from the roster, which has each one's last line and time.
        var bots: [String: HermesBot] = [:]
        let seen = Set(listed.map(\.id))
        for bot in listedBots where !bot.isDefault {
            guard let chat = bot.chatID, let when = bot.lastActive, !seen.contains(chat), !incognito.contains(chat) else { continue }
            var row = HermesSessionsAPI.SessionSummary(id: chat)
            row.title = bot.label(mainName: settings.headerTitle)
            row.preview = bot.preview
            row.last_active = when.timeIntervalSince1970
            bots[chat] = bot
            listed.append(row)
        }
        botChatRows = bots
        let filtered = q.isEmpty ? listed : listed.filter {
            $0.displayTitle.lowercased().contains(q) || ($0.shownPreview ?? "").lowercased().contains(q) || $0.sourceLabel.lowercased().contains(q)
        }
        visibleLedger = filtered.sorted { a, b in
            if (a.pinned ?? false) != (b.pinned ?? false) { return a.pinned ?? false }
            return (a.lastActiveDate ?? .distantPast) > (b.lastActiveDate ?? .distantPast)
        }
    }
}

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

/// "Rename group chat", from a group chat's row: its own modifier, the list's chain being long.
private struct GroupRenameAlert: ViewModifier {
    @Binding var room: GroupRoom?
    @Binding var text: String
    let save: (GroupRoom, String) -> Void

    func body(content: Content) -> some View {
        content.alert("Rename group chat", isPresented: Binding(get: { room != nil }, set: { if !$0 { room = nil } })) {
            TextField("Name", text: $text)
            Button("Save") { if let room { save(room, text) } }
            Button("Cancel", role: .cancel) { room = nil }
        }
    }
}
