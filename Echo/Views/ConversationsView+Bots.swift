import SwiftUI

// The chat list's Bots: the grid, the rows, their menus and the sections they are filed in.

extension ConversationsList {
    // MARK: - Bots (Hermes's Bot Mode, on the Dashboard)

    /// The bots the list shows: none with the setting off; the main profile alone while it is the only one.
    var listedBots: [HermesBot] {
        guard settings.showBots, botDirectory.key == settings.connectionKey || awayBots != nil else { return [] }
        return botDirectory.roster?.inChatList ?? []
    }

    /// The server's bots as last read, with the setting on: nil before they are (or can't be) read.
    var serverBots: [HermesBot]? {
        guard settings.showBots, botDirectory.key == settings.connectionKey || awayBots != nil else { return nil }
        return botDirectory.roster?.bots
    }

    /// With All Servers on and the app on a connection with no bots (an agent bridge), the Hermes
    /// server whose bots the list still shows: they stayed, and a tap on one goes back to that
    /// server (asked 2026-11-14: "When I select a chat with a codex agent my bots disappear").
    var awayBots: HermesServer? {
        guard allServers, !botsHere, botDirectory.roster != nil, botDirectory.key != settings.connectionKey,
              let id = botDirectory.key.split(separator: "|").first.flatMap({ UUID(uuidString: String($0)) }),
              id != settings.activeServerID else { return nil }
        return settings.servers.first { $0.id == id && $0.transport.isHermes }
    }

    /// The main agent's name among the bots: the Hermes's, also while the app is on a bridge
    /// (`awayBots`), where the header's name is the bridge agent's.
    var botsMainName: String {
        awayBots == nil ? settings.headerTitle : settings.displayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Redde"
    }

    /// A Hermes server's bots read for the list while the app is on a bridge (`awayBots`): the
    /// one they were last read from, else the first Hermes server with a Dashboard.
    func readAwayBots() async {
        guard allServers, !botsHere, settings.showBots, awayBots == nil else { return }
        let hermes = settings.servers.filter { $0.transport.isHermes && !$0.serveURL.isEmpty }
        let last = botDirectory.key.split(separator: "|").first.flatMap { UUID(uuidString: String($0)) }
        guard let server = hermes.first(where: { $0.id == last }) ?? hermes.first,
              let roster = try? await AllServers.client(for: server).bots(), !botsHere else { return }
        botDirectory.set(roster, key: "\(server.id.uuidString)|\(server.hermesProfile)")
    }

    /// The Bots section: once the server's bots are read, even with none yet but the main
    /// profile, for New Bot.
    @ViewBuilder
    var botsSection: some View {
        if let all = serverBots {
            let bots = listedBots
            let hidden = all.filter { $0.isHidden && !$0.isDefault }
            let faces = botDirectory.roster?.faces ?? [:]
            // Group chats and bots messaging each other need a bot besides the main one.
            let others = botDirectory.roster?.hasOthers == true
            // (Group chats are the Dashboard's: none on the Hermes API alone, whatever was read before.)
            // (Not another server's, with All Servers on: those open on their own server.)
            let hasRooms = !apiBotsOnly && others && groups.key == settings.connectionKey && groups.supported && awayBots == nil
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
                    // In sections when there are any (Hermes Desktop's, asked 2026-11-05): each a
                    // folding row with its bots and group chats under it, those in none after.
                    ForEach(BotSectioning.blocks(items, in: settings.botSectionsHere), id: \.key) { block in
                        if let section = block.section {
                            sectionRow(section, count: block.items.count)
                            if !foldedSections.contains(section.id) {
                                if !block.bots.isEmpty { botGrid(block.bots, faces: faces, hidden: 0, actions: false) }
                                ForEach(block.rooms) { room in groupRow(room, faces: faces) }
                            }
                        } else {
                            botGrid(block.bots, faces: faces, hidden: hidden.count, actions: awayBots == nil)
                            ForEach(block.rooms) { room in groupRow(room, faces: faces) }
                        }
                    }
                    if hasRooms, groups.writable {
                        sectionAction(String(localized: "New Group Chat"), systemImage: "person.3",
                                      hint: String(localized: "Starts a chat with several bots at once")) { makingGroup = true }
                    }
                    if !apiBotsOnly, others, awayBots == nil, botDirectory.roster?.messagingIsOn == false {
                        sectionAction(String(localized: "Let bots message each other"), systemImage: "bubble.left.and.text.bubble.right",
                                      hint: String(localized: "Sets your main profile up as a bot on the server, as Hermes Desktop does")) { askingBotMessaging = true }
                    }
                }
            } header: {
                if arrangingBots { Text("Bots") } else { foldingHeader(String(localized: "Bots"), count: bots.count, isOpen: $showBotRows) }
            } footer: {
                if arrangingBots {
                    Text("Drag bots and group chats by their handles into the order you want.")
                        .chatFont(.footnote).foregroundStyle(.secondary)
                } else if apiBotsOnly, showBotRows, !others {
                    Text("Bots are your server's other profiles. On the Hermes API, add each by its name and its own API key; with the Dashboard login saved in Settings, Redde lists them and has group chats too.")
                        .chatFont(.footnote).foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $addingAPIBot) {
                APIBotEditor { Task { _ = await botDirectory.refreshAPI() } }
            }
            // Sections made in Hermes Desktop, taken in as the bots carrying them are read.
            .onChange(of: botDirectory.roster, initial: true) { adoptBotSections() }
            .alert(namingSection?.title ?? "", isPresented: Binding(get: { namingSection != nil }, set: { if !$0 { namingSection = nil } })) {
                TextField(String(localized: "Name", comment: "A bot section's name field"), text: $sectionNameText)
                Button(namingSection?.isNew == false ? String(localized: "Save") : String(localized: "Create", comment: "Button: makes a new section of the bots")) {
                    if let naming = namingSection { nameSection(naming, sectionNameText) }
                }
                Button("Cancel", role: .cancel) { namingSection = nil }
            } message: {
                if namingSection?.isNew == true {
                    Text("Bots in a section are grouped in the chat list, here and in Hermes Desktop.", comment: "New Section alert")
                }
            }
            .confirmationDialog(deletingSection.map { String(localized: "Delete \u{201C}\($0.name)\u{201D}?", comment: "Asks before deleting a section of the bots") } ?? "",
                                isPresented: Binding(get: { deletingSection != nil }, set: { if !$0 { deletingSection = nil } }), titleVisibility: .visible) {
                Button("Delete Section", role: .destructive) { if let section = deletingSection { deleteSection(section) } }
            } message: {
                Text("Its bots and group chats stay, out of any section.", comment: "Deleting a section of the bots")
            }
            .confirmationDialog("Let bots message each other?", isPresented: $askingBotMessaging, titleVisibility: .visible) {
                Button("Let Them") { letBotsMessageEachOther() }
            } message: {
                Text("Hermes gives each bot's chat a tool to message the other bots, so you can say \u{201C}@scout, what do you think?\u{201D} in one bot's chat and have it ask. Redde turns this on the way Hermes Desktop does, by setting your main profile up as a bot on the server. Chats with your agent stay as they are.")
            }
        }
    }

    /// The order the Bots section's rows were put in on this server; empty, none.
    var botOrder: [String] { settings.botOrderHere }

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
                Text(title).chatFont(.body)
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
    private func botGrid(_ bots: [HermesBot], faces: [String: BotFace], hidden: Int, actions: Bool = true) -> some View {
        // A section's bots (`actions` off): all of them, nothing after them; the section folds instead.
        let folds = actions && bots.count > Self.foldsAfter
        let shown = folds && !botsExpanded ? Array(bots.prefix(Self.gridColumns - 1)) : bots
        return VStack(spacing: 2) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2, alignment: .top), count: Self.gridColumns), spacing: 6) {
                ForEach(shown, id: \.name) { bot in
                    botTile(bot, face: faces[bot.name] ?? BotFace(seed: bot.name))
                }
                if folds, !botsExpanded {
                    gridAction(String(localized: "\(bots.count - shown.count) more", comment: "A tile after the bots shown: how many more there are"),
                               systemImage: "chevron.down", hint: String(localized: "Shows all your bots")) {
                        withAnimation { botsExpanded = true }
                    }
                } else if !actions {
                    EmptyView()
                } else if !botActionsShown {
                    // Folded away, one tile for them all, so they aren't always on screen.
                    gridAction(String(localized: "More"), systemImage: "ellipsis",
                               hint: String(localized: "Shows New Bot, Topology and the hidden bots")) {
                        withAnimation { botActionsShown = true }
                    }
                } else {
                    if apiBotsOnly {
                        // No Dashboard to make or list them: a profile on the server, by its own key.
                        gridAction(String(localized: "Add Bot"), systemImage: "plus",
                                   hint: String(localized: "Adds one of your server's profiles as a bot, with its own API key")) { addingAPIBot = true }
                    } else {
                        gridAction(String(localized: "New Bot"), systemImage: "plus",
                                   hint: String(localized: "Makes a bot on your server, with a chat of its own")) { editingBot = .new }
                    }
                    // Beside New Bot, the same size (his ask 2026-10-22).
                    gridAction(String(localized: "Topology", comment: "A tile that opens the map of the bots"), systemImage: "point.3.connected.trianglepath.dotted",
                               hint: String(localized: "Shows your bots, your group chats and the models they run on")) { showingTopology = true }
                    if hidden > 0 {
                        gridAction(String(localized: "Hidden", comment: "A tile that shows the hidden bots"), systemImage: "eye.slash",
                                   hint: String(localized: "Shows the \(hidden) bots hidden from this list")) { showingHiddenBots = true }
                    }
                    gridAction(String(localized: "Less", comment: "A tile that folds New Bot, Topology and the hidden bots away"), systemImage: "chevron.left",
                               hint: String(localized: "Folds New Bot, Topology and the hidden bots into one tile")) {
                        withAnimation { botActionsShown = false }
                    }
                }
            }
            // Under them, small: a whole row of its own for it was a row of nothing.
            if folds, botsExpanded {
                Button { withAnimation { botsExpanded = false } } label: {
                    Label("Fewer", systemImage: "chevron.up")
                        .chatFont(.caption, weight: .medium)
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
        let name = bot.label(mainName: botsMainName)
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
                                .chatFont(.caption).foregroundStyle(.orange)
                                .background(.background, in: .circle)
                                .offset(x: 6, y: -4)
                        } else if marks.unread {
                            Circle().fill(accent).frame(width: 9, height: 9).offset(x: 4, y: -2)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if muted {
                            Image(systemName: "bell.slash.fill")
                                .chatFont(size: 9).foregroundStyle(.secondary)
                                .padding(2)
                                .background(.background, in: .circle)
                                .offset(x: 5, y: 3)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if let engine = settings.liveEngine(for: bot.name) {
                            Image(systemName: "phone.fill")
                                .chatFont(size: 9).foregroundStyle(.secondary)
                                .padding(2)
                                .background(.background, in: .circle)
                                .offset(x: -5, y: 3)
                                .accessibilityLabel("\(engine.name) calls")
                        }
                    }
                Text(name).lineLimit(1).truncationMode(.tail)
                    .chatFont(.caption, weight: isOpen ? .semibold : .regular)
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
                    .chatFont(size: 24, weight: .medium)
                    .foregroundStyle(Settings.shared.resolvedTheme.accent)
                    .frame(width: Self.tileFace, height: Self.tileFace)
                Text(title).chatFont(.caption).lineLimit(1)
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
    /// Another server's bot (`awayBots`): only Open, which goes back to its server.
    @ViewBuilder
    func botMenu(_ bot: HermesBot, unread: Bool, isOpen: Bool) -> some View {
        if awayBots != nil {
            Button("Open Chat", systemImage: "bubble.left.and.bubble.right") { openBot(bot) }
        } else {
            homeBotMenu(bot, unread: unread, isOpen: isOpen)
        }
    }

    @ViewBuilder
    private func homeBotMenu(_ bot: HermesBot, unread: Bool, isOpen: Bool) -> some View {
        if bot.chatID != nil, !isOpen {
            if unread {
                Button("Mark as Read", systemImage: "envelope.open") { activity.botSeen(bot.name) }
            } else {
                Button("Mark as Unread", systemImage: "envelope.badge") { activity.markUnread(bot: bot.name) }
            }
        }
        if bot.isDefault {
            Button("Voice…", systemImage: "waveform") { voicingMain = true }
        } else {
            Button("Voice…", systemImage: "waveform") { voicing = bot }
        }
        MuteMenu(item: "bot:" + bot.name)
        Button("Earlier Chats…", systemImage: "clock.arrow.circlepath") { earlierFor = bot }
        // Its schedules are kept on the server through the Dashboard, delivered into its Bot Chat.
        if !bot.viaAPI {
            Button("Schedules…", systemImage: "clock") { scheduling = bot }
        }
        if bot.viaAPI {
            // Added here for the Hermes API: its settings and face are the Dashboard's.
            Button("Models & Providers…", systemImage: "cpu") { modelsFor = bot }
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
        sectionMenu(.bot(bot))
        Divider()
        orderingBots
    }

    /// A bot's row while the bots are put in order: its creature, its name and its chat's last
    /// line, marked as a conversation's row is (at work, waiting on the person, or something not
    /// yet seen).
    /// `labelled`: among the conversations, marked as a bot's chat.
    func botRow(_ bot: HermesBot, face: BotFace, labelled: Bool = false) -> some View {
        let name = bot.label(mainName: botsMainName)
        let isOpen = groups.open == nil && conversation.bot?.profile == bot.name
        // Muted: no unread dot (at work, or waiting on the person, still shows).
        let muted = Mutes.isMuted("bot:" + bot.name, settings: settings)
        let marks = ChatMarks(kind: activity.kind(of: bot, open: conversation), unread: !muted && activity.isUnread(bot, open: conversation),
                              muted: muted)
        let roster = botDirectory.roster?.bots ?? []
        let tag = "@" + BotMentions.shownTag(profile: bot.name, handle: bot.handle, roster: botDirectory.roster)
        return Button { openBot(bot) } label: {
            HStack(spacing: 12) {
                BotAvatar(face: face, name: name)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name).chatFont(.body, weight: .semibold).lineLimit(1)
                        if let engine = settings.liveEngine(for: bot.name) { LiveCallMark(engine: engine) }
                        if muted { MutedMark() }
                        Spacer(minLength: 8)
                        if openingBot == bot.name || marks.kind == .working {
                            ProgressView().controlSize(.small)
                        } else if let when = bot.lastActive {
                            Text(DateGroup.rowTime(when)).chatFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 6) {
                        if marks.kind == .needsYou { NeedsYouTag() }
                        if labelled { BotChatLabel(face: face) }
                        Text(BotMessages.rowPreview(bot.preview, roster: roster, mainName: botsMainName)
                             ?? bot.description.nilIfEmpty ?? tag)
                            .lineLimit(1)
                    }
                    .chatFont(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .unreadDot(marks.unread)
        .opensConversation()
        .listRowBackground(isOpen ? Settings.shared.resolvedTheme.accent.opacity(0.08) : Settings.shared.theme.listPage)
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
                        Text(room.name).chatFont(.body, weight: .semibold).lineLimit(1)
                        if muted { MutedMark() }
                        Spacer(minLength: 8)
                        if marks.kind == .working {
                            ProgressView().controlSize(.small)
                        } else if let when = room.updatedAt {
                            Text(DateGroup.rowTime(when)).chatFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 5) {
                        if marks.kind == .needsYou { NeedsYouTag() }
                        if room.inDesktop {
                            Image(systemName: "desktopcomputer").accessibilityLabel("Runs in Hermes Desktop")
                        }
                        Text(room.members.map(\.label).formatted(.list(type: .and)))
                    }
                    .chatFont(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .unreadDot(marks.unread)
        .listRowBackground(isOpen ? Settings.shared.resolvedTheme.accent.opacity(0.08) : Settings.shared.theme.listPage)
        .contextMenu {
            if !isOpen, room.activityMark != nil {
                if marks.unread {
                    Button("Mark as Read", systemImage: "envelope.open") { activity.roomSeen(room.id, upTo: room.activityMark) }
                } else {
                    Button("Mark as Unread", systemImage: "envelope.badge") { activity.markUnread(room: room.id) }
                }
            }
            // Hermes Desktop's group chats are its own to name, and never notify: nothing to mute.
            if !room.inDesktop {
                Button("Rename", systemImage: "pencil") { roomRenameText = room.name; renamingRoom = room }
                MuteMenu(item: "room:" + room.id)
            }
            sectionMenu(.room(room))
            Divider()
            orderingBots
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(marks.spoken)
        .accessibilityHint(room.inDesktop ? String(localized: "Shows this Hermes Desktop group chat's last messages") : String(localized: "Opens this group chat"))
    }

    /// A group chat's new name, on the server: the room is Hermes's, on either connection.
    func rename(_ room: GroupRoom, to text: String) {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingRoom = nil
        guard !name.isEmpty, name != room.name else { return }
        Task {
            do {
                try await HermesServeClient.shared.renameGroup(room.id, to: name)
                groups.renamed(room.id, to: name)
            } catch {
                ledgerError = String(localized: "Couldn't rename “\(room.name)”: \(error.localizedDescription)")
            }
        }
    }

    /// An earlier chat of a bot's, opened to read (or carry on in): in the bot's profile, by the
    /// connection the bot goes by.
    func readEarlier(_ chat: HermesSessionsAPI.SessionSummary, of bot: HermesBot) {
        earlierFor = nil
        var row = chat
        if bot.name != (settings.profileName ?? ProfileCatalog.defaultID) {
            row.elsewhere = ProfileRoute(profile: bot.name, viaAPI: bot.viaAPI)
        }
        if !bot.viaAPI { HermesServeClient.shared.noteProfile(bot.name, forStored: chat.id) }
        open(row)
    }

    /// An earlier chat made the bot's chat again, and opened.
    func bringBackEarlier(_ chat: HermesSessionsAPI.SessionSummary, as bot: HermesBot) {
        earlierFor = nil
        openingBot = bot.name
        Task {
            do {
                try await conversation.bringBack(chat, as: bot, mainName: settings.headerTitle)
                opened()
            } catch {
                ledgerError = String(localized: "Couldn't bring that chat back: \(error.localizedDescription)")
            }
            openingBot = nil
        }
    }

    func openBot(_ bot: HermesBot) {
        // Another server's bot (All Servers, the app on a bridge): back to that server first.
        if let server = awayBots { ServerSwitcher.switchTo(server.id, conversation: conversation) }
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
    func botEdited(_ outcome: BotEditor.Outcome) {
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

    // MARK: - Sections of the Bots

    /// A section being named: a new one (filing the bot or group chat whose menu asked), or one renamed.
    enum SectionNaming {
        case new(BotListItem?)
        case rename(BotSection)

        var isNew: Bool { if case .new = self { true } else { false } }
        var title: String {
            switch self {
            case .new: String(localized: "New Section", comment: "Alert title: makes a section of the bots")
            case .rename: String(localized: "Rename Section", comment: "Alert title: renames a section of the bots")
            }
        }
    }

    private var foldedSections: Set<String> { Set(foldedSectionsRaw.split(separator: ",").map(String.init)) }

    /// Every bot and group chat on the server, hidden ones too: what a rename or a delete goes through.
    private var allBotItems: [BotListItem] {
        (botDirectory.roster?.bots ?? []).map(BotListItem.bot) + (groups.key == settings.connectionKey ? groups.rooms.map(BotListItem.room) : [])
    }

    /// A section's row: its name, how many are in it while folded, and a tap to fold it; its menu
    /// renames, moves or deletes it.
    private func sectionRow(_ section: BotSection, count: Int) -> some View {
        let folded = foldedSections.contains(section.id)
        let sections = settings.botSectionsHere.sections
        return Button {
            withAnimation(.easeOut(duration: 0.2)) {
                var set = foldedSections
                if folded { set.remove(section.id) } else { set.insert(section.id) }
                foldedSectionsRaw = set.sorted().joined(separator: ",")
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(section.name).chatFont(.subheadline, weight: .semibold).lineLimit(1)
                if folded {
                    Text("\(count)").chatFont(.caption2, weight: .semibold).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .chatFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(folded ? 0 : 90))
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…", systemImage: "pencil") { sectionNameText = section.name; namingSection = .rename(section) }
            if sections.first != section {
                Button("Move Up", systemImage: "arrow.up") { withAnimation { BotSectionActions.move(section, by: -1) } }
            }
            if sections.last != section {
                Button("Move Down", systemImage: "arrow.down") { withAnimation { BotSectionActions.move(section, by: 1) } }
            }
            Button("Delete Section…", systemImage: "trash", role: .destructive) { deletingSection = section }
        }
        .accessibilityLabel(section.name)
        .accessibilityValue(folded ? String(localized: "Folded, \(count) in it", comment: "VoiceOver: a folded section of the bots") : "")
        .accessibilityHint(folded ? String(localized: "Shows this section's bots") : String(localized: "Folds this section's bots away"))
        .accessibilityAddTraits(.isHeader)
    }

    /// In a bot's or group chat's menu: the sections to put it in, a new one, or out of its own.
    @ViewBuilder
    private func sectionMenu(_ item: BotListItem) -> some View {
        let here = settings.botSectionsHere
        let current = BotSectioning.section(of: item, in: here)
        Menu {
            ForEach(here.sections) { section in
                Button { fileBotItems([item], in: section) } label: {
                    if current == section.id { Label(section.name, systemImage: "checkmark") } else { Text(section.name) }
                }
            }
            if !here.sections.isEmpty { Divider() }
            Button("New Section…", systemImage: "folder.badge.plus") { sectionNameText = ""; namingSection = .new(item) }
            if current != nil {
                Button("Remove from Section", systemImage: "folder.badge.minus") { fileBotItems([item], in: nil) }
            }
        } label: {
            Label(String(localized: "Section", comment: "A bot's menu: the submenu that puts it in a section"), systemImage: "folder")
        }
    }

    private func adoptBotSections() {
        guard botDirectory.key == settings.connectionKey else { return }
        BotSectionActions.adopt(botDirectory.roster)
    }

    /// After a write: the roster again, for the bots' own sections (nothing to read on the API alone).
    private func sectionsChanged() async {
        if !apiBotsOnly { _ = try? await botDirectory.refresh() }
    }

    private func fileBotItems(_ items: [BotListItem], in section: BotSection?) {
        Task {
            do {
                try await BotSectionActions.file(items, in: section, roster: botDirectory.roster)
            } catch {
                ledgerError = String(localized: "Couldn't change the section: \(error.localizedDescription)", comment: "A bot's section couldn't be written")
            }
            await sectionsChanged()
        }
    }

    private func nameSection(_ naming: SectionNaming, _ name: String) {
        namingSection = nil
        Task {
            do {
                switch naming {
                case .new(let item):
                    try await BotSectionActions.make(name, filing: item.map { [$0] } ?? [], roster: botDirectory.roster)
                case .rename(let section):
                    try await BotSectionActions.rename(section, to: name, items: allBotItems, roster: botDirectory.roster)
                }
            } catch {
                ledgerError = String(localized: "Couldn't change the section: \(error.localizedDescription)", comment: "A bot's section couldn't be written")
            }
            await sectionsChanged()
        }
    }

    private func deleteSection(_ section: BotSection) {
        deletingSection = nil
        Task {
            do {
                try await BotSectionActions.delete(section, items: allBotItems, roster: botDirectory.roster)
            } catch {
                ledgerError = String(localized: "Couldn't change the section: \(error.localizedDescription)", comment: "A bot's section couldn't be written")
            }
            await sectionsChanged()
        }
    }

    private func hide(_ bot: HermesBot) {
        Task {
            do {
                _ = try await HermesServeClient.shared.changeBot(bot, BotChange(hidden: true))
                try await botDirectory.refresh()
            } catch {
                ledgerError = String(localized: "Couldn't hide \(bot.label(mainName: settings.headerTitle)): \(error.localizedDescription)")
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
                ledgerError = String(localized: "Couldn't set that up: \(error.localizedDescription)")
            }
        }
    }
}
