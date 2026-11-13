import SwiftUI

// MARK: - The drawer (2026-11-13)

/// The drawer laid out from scratch, from the Arcade mockup: a hello, three counters, what needs
/// you as a stack, Today, Planned, Board and Made as round buttons that open pages, the bots in a
/// row, then projects and the chats, in one list that never swaps away. Built from the list's own
/// rows and pages, so it is as quick as the list is. Its colours come from the theme (`DrawerTone`).
enum NewDrawer {
    static let key = "drawer.new"

    enum Page: Hashable, Identifiable {
        case today, planned, board, made, bots
        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .today: LocalizedStringResource("Today", comment: "An agenda card's day")
            case .planned: LocalizedStringResource("Planned", comment: "The list's section of what the agents will do: scheduled jobs, reminders, alarms and the rest")
            case .board: LocalizedStringResource("Board")
            case .made: LocalizedStringResource("Made", comment: "The list's section with the pages, pictures and files the agents made")
            case .bots: LocalizedStringResource("Bots", comment: "CarPlay: the tab with your bots")
            }
        }
    }

    /// What a bot waits on the person for (Coder's server steps, a finished change, a card's
    /// commands), as the server lists it: `/redde-push waiting`, plugin 1.28. The same on every
    /// device, and gone from all of them once it's answered (asked 2026-11-13: the phone showed
    /// Coder's wait from its notification, and the iPad, never sent one, didn't).
    struct BotWait: Hashable, Identifiable {
        var id: String
        var profile: String
        var title: String
        var detail: String
        /// What saying it in the bot's chat brings back: "go", or "put it in".
        var word: String
        var at: Date

        private struct Reply: Decodable {
            struct Item: Decodable {
                var id, profile, title: String
                var detail, word: String?
                var at: Double
            }
            var waiting: [Item]
        }

        /// The plugin's answer, or nil when it isn't one (a plugin older than 1.28).
        static func parse(_ output: String) -> [BotWait]? {
            guard let data = PluginReply.data(output, "waiting"), let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
            return reply.waiting.map {
                BotWait(id: $0.id, profile: $0.profile, title: $0.title, detail: $0.detail ?? "", word: $0.word ?? "go",
                        at: Date(timeIntervalSince1970: $0.at))
            }
        }
    }

    /// Put away with ✕ on this device (its id names what waits, so the next steps show again).
    static var dismissed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key + ".dismissed") ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(50)), forKey: key + ".dismissed") }
    }
}

extension ConversationsList {
    /// The person's waits, read again each 20 s while the list is up (they live in the app
    /// group, so this costs no network). The bots' come from the server in `watchActivity`'s
    /// loop: `lookForBotWaits`.
    func watchDrawerWaits() async {
        guard newDrawer, isShowing, scenePhase == .active, pace.onScreen else { return }
        #if DEBUG
        // `-echo.drawerPage today|planned|board|made|bots`: that page open (screenshots).
        if let name = DevHooks.value("-echo.drawerPage"), drawerPage == nil {
            try? await Task.sleep(for: .seconds(1))
            drawerPage = ["today": .today, "planned": .planned, "board": .board, "made": .made, "bots": .bots][name]
        }
        // `-echo.demoBotWait`: Quill waiting on server steps from a card (screenshots).
        if DevHooks.has("-echo.demoBotWait") {
            drawerBotWaits = [NewDrawer.BotWait(id: "demo-wait", profile: "writer", title: "Waiting on your approval",
                                                detail: "Server steps: systemctl restart hermes-gateway\nSay \"go\" to see the card.",
                                                word: "go", at: .now.addingTimeInterval(-240))]
        }
        #endif
        while !Task.isCancelled {
            let waits = NeedsYou.waiting()
            if waits != drawerWaits { drawerWaits = waits }
            try? await Task.sleep(for: .seconds(20))
        }
    }

    /// What the bots wait on the person for, from the server (`/redde-push waiting`). Asked from
    /// `watchActivity`, so it rides the radio wake the list's own look already makes.
    /// Unreachable for a moment: what was shown stays; an older plugin: none.
    func lookForBotWaits() async {
        guard newDrawer else { return }
        #if DEBUG
        if DevHooks.has("-echo.demoBotWait") { return }
        #endif
        var bots = drawerBotWaits
        if settings.transport != .acp, botsHere {
            do {
                bots = NewDrawer.BotWait.parse(try await PushService.command(over: settings)("waiting")) ?? []
            } catch PushError.noPlugin {
                bots = []
            } catch {}
        } else {
            bots = []
        }
        guard !Task.isCancelled else { return }
        let shown = bots.filter { !NewDrawer.dismissed.contains($0.id) }
        if shown != drawerBotWaits { drawerBotWaits = shown }
    }

    @ViewBuilder
    var drawerRows: some View {
        if query.isEmpty {
            let tone = DrawerTone(settings.resolvedTheme)
            let needs = drawerItems(drawerNeeds())
            AnyView(drawerHeader(tone))
            AnyView(drawerStats(tone, needs: needs.count))
            if !needs.isEmpty { AnyView(drawerStack(needs, tone: tone)) }
            AnyView(drawerPlaces(tone))
            if usesLedger, botsHere, let bots = serverBots, !bots.isEmpty { AnyView(drawerTeam(tone)) }
            if usesLedger, viaServe || settings.transport == .acp, settings.projectsInChatList, !projects.isEmpty || viaServe { projectsSection }
            waitingNotesSection
        }
        if usesLedger {
            ledgerSection
            if searchesMessages { messageHitsSection }
        } else {
            localSection
        }
    }

    /// A hello for the time of day, what's up next under it, and the server and profile menus.
    private func drawerHeader(_ tone: DrawerTone) -> some View {
        let servers = settings.servers.count > 1 && settings.transport != .chatCompletions
        let profiles = showsProfileMenu && !pickerInTitle
        let line = CalendarUpNext.shared.next.map {
            String(localized: "Up next: \("\($0.title) · \(CalendarUpNext.when($0, now: .now))")",
                   comment: "The drawer, under the hello: the next event on the calendar and when, as Up next: Lunch with Ana · 12:30")
        }
            ?? Date.now.formatted(.dateTime.weekday(.wide).month().day())
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: Self.drawerHello(at: .now))
                .font(.system(.title, design: tone.design, weight: .heavy))
                .foregroundStyle(tone.ink)
            Text(verbatim: line)
                .font(.system(.subheadline, design: tone.design, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if servers || profiles {
                HStack(spacing: 8) {
                    if servers { serverMenu }
                    if profiles { profileMenu }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .drawerRow(top: 4, bottom: 8)
    }

    static func drawerHello(at now: Date) -> String {
        switch Calendar.current.component(.hour, from: now) {
        case 5..<12: String(localized: "Good morning", comment: "The drawer's hello, before noon")
        case 12..<17: String(localized: "Good afternoon", comment: "The drawer's hello, noon to five")
        case 17..<22: String(localized: "Good evening", comment: "The drawer's hello, five to ten")
        default: String(localized: "Hello, night owl", comment: "The drawer's hello, late at night")
        }
    }

    // Three counters: what needs you, the bots at work, the unread chats.
    private func drawerStats(_ tone: DrawerTone, needs: Int) -> some View {
        let roster = serverBots ?? []
        let working = roster.filter { activity.kind(of: $0, open: conversation) == .working }.count
        // The chats, the bots' own chats and the group chats, as the rows below mark them; a bot's
        // chat listed among the chats counts once, as its bot (it said 0 with two bots Unread).
        let chats = visibleLedger.lazy.filter { botChatRows[$0.id] == nil && activity.isUnread($0, open: self.conversation) }.count
        let bots = roster.filter { !Mutes.isMuted("bot:" + $0.name, settings: settings) && activity.isUnread($0, open: conversation) }.count
        let rooms = groups.key == settings.connectionKey
            ? groups.rooms.filter { !Mutes.isMuted("room:" + $0.id, settings: settings) && activity.isUnread($0, isOpen: groups.open?.id == $0.id) }.count : 0
        let unread = chats + bots + rooms
        return HStack(spacing: 8) {
            drawerStat(needs, String(localized: "Waiting", comment: "The drawer: a counter's label, how many things wait on you (shown in capitals)"), tone.warm, tone)
            drawerStat(working, String(localized: "Working", comment: "A workstream's status"), tone.accent, tone)
            drawerStat(unread, String(localized: "Unread", comment: "A conversation not yet read; also the swipe action that marks it so"), tone.ink, tone)
        }
        .drawerRow(top: 2, bottom: 10)
    }

    private func drawerStat(_ count: Int, _ label: String, _ color: Color, _ tone: DrawerTone) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "\(count)")
                .font(.system(size: 26, weight: .heavy, design: tone.design))
                .monospacedDigit()
                .foregroundStyle(count > 0 ? color : Color.secondary)
                .contentTransition(.numericText())
            Text(verbatim: label.localizedUppercase)
                .font(.system(size: 10, weight: .bold, design: tone.design))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(tone.surface, in: shape)
        .overlay { shape.strokeBorder(color.opacity(count > 0 ? 0.35 : 0.1), lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }

    struct DrawerNeeds {
        var waits: [WaitingRequest] = []
        var botWaits: [(NewDrawer.BotWait, HermesBot)] = []
        var bots: [HermesBot] = []
        var rooms: [GroupRoom] = []
        var chats: [HermesSessionsAPI.SessionSummary] = []
    }

    func drawerNeeds() -> DrawerNeeds {
        var needs = DrawerNeeds()
        needs.waits = drawerWaits
        let waitingSessions = Set(drawerWaits.compactMap(\.session))
        needs.chats = visibleLedger.filter { !waitingSessions.contains($0.id) && botChatRows[$0.id] == nil
            && activity.kind(of: $0.id, open: conversation) == .needsYou }
        let roster = serverBots ?? []
        needs.bots = roster.filter { activity.kind(of: $0, open: conversation) == .needsYou }
        needs.botWaits = drawerBotWaits.compactMap { wait in
            guard !needs.bots.contains(where: { $0.name == wait.profile }), let bot = roster.first(where: { $0.name == wait.profile }) else { return nil }
            return (wait, bot)
        }
        needs.rooms = groups.key == settings.connectionKey ? groups.rooms.filter { activity.kind(of: $0) == .needsYou } : []
        return needs
    }

    /// One thing waiting on the person, whatever it is, as the stack shows it.
    struct DrawerNeed: Identifiable {
        enum Icon { case face(BotFace), faces([(BotFace, String)]), symbol(String) }
        var id: String
        var icon: Icon
        var title: String
        var detail: String
        /// The command or steps, shown in a monospaced box on the top card.
        var command: String?
        var pill: String
        var busy = false
        var enabled = true
        var act: () -> Void
        /// Only a bot's wait can be put away for good; the rest go when they're answered.
        var dismiss: (() -> Void)?
    }

    func drawerItems(_ needs: DrawerNeeds) -> [DrawerNeed] {
        let faces = botDirectory.roster?.faces ?? [:]
        var items: [DrawerNeed] = []
        for wait in needs.waits {
            let session = wait.session.flatMap { id in ledger.first { $0.id == id } }
            let shows = wait.kind == .approval || wait.kind == .sudo
            let what = switch wait.kind {
            case .approval: String(localized: "Wants to run a command", comment: "The drawer: an approval waiting on you")
            case .sudo: String(localized: "Needs your password to run", comment: "The drawer: a sudo password request waiting on you")
            case .question: wait.text
            case .secret: String(localized: "Needs a key: \(wait.text)", comment: "The drawer: a request for a secret, with the key's name")
            }
            items.append(DrawerNeed(id: "wait:" + wait.id, icon: .symbol(drawerSymbol(wait.kind)),
                                     title: wait.title ?? session?.title ?? String(localized: "Conversation", comment: "Title of an exported conversation that has none"),
                                     detail: what + " · " + DateGroup.rowTime(wait.since),
                                     command: shows ? wait.text : nil,
                                     pill: wait.kind == .question ? Self.answerWord : Self.lookWord, enabled: session != nil) {
                guard let session else { return }
                if let bot = botChatRows[session.id] { openBot(bot) } else { open(session) }
            })
        }
        for (wait, bot) in needs.botWaits {
            let name = bot.label(mainName: settings.headerTitle)
            let line = wait.detail.components(separatedBy: "\n").first ?? ""
            let steps = Self.drawerSteps(line)
            let title = steps == nil ? "\(name): \(wait.title)"
                : String(localized: "\(name) wants to run steps on the server", comment: "The drawer: a bot (Coder) waiting for your OK on server steps; its name")
            items.append(DrawerNeed(id: "bot-wait:" + wait.id, icon: .face(faces[bot.name] ?? BotFace(seed: bot.name)), title: title,
                                     detail: (steps == nil ? line : String(localized: "From a card or another bot", comment: "The drawer: where a bot's waiting turn came from, so nobody saw its card"))
                                        + " · " + DateGroup.rowTime(wait.at),
                                     command: steps?.joined(separator: "\n"), pill: Self.lookWord, busy: openingBot == bot.name,
                                     act: { reviewBotWait(wait, bot: bot) },
                                     dismiss: {
                                         NewDrawer.dismissed.insert(wait.id)
                                         drawerBotWaits.removeAll { $0.id == wait.id }
                                     }))
        }
        for bot in needs.bots {
            items.append(DrawerNeed(id: "bot:" + bot.name, icon: .face(faces[bot.name] ?? BotFace(seed: bot.name)),
                                     title: bot.label(mainName: settings.headerTitle),
                                     detail: String(localized: "Waiting on you in its chat", comment: "The drawer: a bot marked Needs you"),
                                     pill: Self.openWord) { openBot(bot) })
        }
        for room in needs.rooms {
            items.append(DrawerNeed(id: "room:" + room.id,
                                     icon: .faces(room.members.prefix(2).map { (faces[$0.profile] ?? BotFace(seed: $0.profile), $0.label) }),
                                     title: room.name, detail: String(localized: "A group chat is waiting on you", comment: "The drawer: a group chat marked Needs you"),
                                     pill: Self.openWord) { opened(room: room) })
        }
        for chat in needs.chats {
            items.append(DrawerNeed(id: "chat:" + chat.id, icon: .symbol("bubble.left.and.exclamationmark.bubble.right.fill"),
                                     title: chat.title ?? String(localized: "Conversation", comment: "Title of an exported conversation that has none"),
                                     detail: chat.preview ?? String(localized: "Waiting on you"),
                                     pill: Self.openWord) { open(chat) })
        }
        // Put off with Later: to the back, in the order they were put off.
        let later = Set(drawerLater)
        return items.filter { !later.contains($0.id) } + drawerLater.compactMap { id in items.first { $0.id == id } }
    }

    static var lookWord: String { String(localized: "Take a Look", comment: "The drawer: a button that opens what's waiting on you (an approval, a bot's steps)") }
    static var answerWord: String { String(localized: "Answer", comment: "The Work sheet: opens a workstream that waits for approval, to answer it") }
    static var openWord: String { String(localized: "Open", comment: "The Work sheet: opens a workstream's own chat") }

    /// The steps in Coder's note ("Server steps: a; b", "…wants to run on the server: a; b").
    static func drawerSteps(_ line: String) -> [String]? {
        for marker in ["Server steps: ", "on the server: "] {
            guard let range = line.range(of: marker) else { continue }
            let steps = line[range.upperBound...].components(separatedBy: "; ")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return steps.isEmpty ? nil : steps
        }
        return nil
    }

    private func drawerSymbol(_ kind: WaitingRequest.Kind) -> String {
        switch kind {
        case .approval: "checkmark.shield"
        case .question: "questionmark.bubble"
        case .sudo: "lock"
        case .secret: "key"
        }
    }

    /// A bot waiting on a turn from another bot or a card: Take a Look opens its chat and says the
    /// word that brings the card ("go", or "put it in"). The server takes the wait off every
    /// device once it's answered; until then the next look brings it back.
    private func reviewBotWait(_ wait: NewDrawer.BotWait, bot: HermesBot) {
        drawerBotWaits.removeAll { $0.id == wait.id }
        openingBot = bot.name
        Task {
            do {
                try await conversation.openBot(bot, mainName: settings.headerTitle)
                conversation.send(wait.word)
                opened()
            } catch {
                ledgerError = error.localizedDescription
            }
            openingBot = nil
        }
    }

    // What needs you, as a stack: the first on top with its buttons, the next peeking out under
    // it, and the rest a tap away.
    @ViewBuilder
    private func drawerStack(_ items: [DrawerNeed], tone: DrawerTone) -> some View {
        let rest = items.count - 1
        drawerHero(items[0], behind: rest > 0, tone: tone)
            .drawerRow(top: 0, bottom: rest > 0 ? 6 : 10)
        if rest > 0 {
            if drawerNeedsOpen {
                ForEach(items.dropFirst()) { drawerSmallCard($0, tone: tone) }
            }
            Button {
                withAnimation(.snappy) { drawerNeedsOpen.toggle() }
            } label: {
                HStack(spacing: 4) {
                    if drawerNeedsOpen {
                        Text("Show Less", comment: "Watches: folds a watch's report back to a few lines")
                    } else {
                        Text("\(rest) more", comment: "A tile after the bots shown: how many more there are")
                    }
                    Image(systemName: "chevron.down").rotationEffect(.degrees(drawerNeedsOpen ? 180 : 0))
                }
                .font(.system(.footnote, design: tone.design, weight: .bold))
                .foregroundStyle(tone.warm)
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .drawerRow(top: 2, bottom: 10)
        }
    }

    private func drawerHero(_ item: DrawerNeed, behind: Bool, tone: DrawerTone) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                drawerIcon(item.icon, size: 40, tone: tone)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.title)
                        .font(.system(.headline, design: tone.design, weight: .bold))
                        .foregroundStyle(tone.ink)
                        .lineLimit(2)
                    Text(verbatim: item.detail)
                        .font(.system(.caption, design: tone.design, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            if let command = item.command {
                Text(verbatim: command)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(tone.ink.opacity(0.85))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(tone.page.opacity(0.75), in: .rect(cornerRadius: 12, style: .continuous))
            }
            HStack(spacing: 8) {
                Button(action: item.act) {
                    ZStack {
                        if item.busy { ProgressView().tint(tone.page) } else { Text(verbatim: item.pill) }
                    }
                    .font(.system(.subheadline, design: tone.design, weight: .bold))
                    .foregroundStyle(tone.page)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(tone.warm, in: .rect(cornerRadius: 14, style: .continuous))
                }
                .disabled(!item.enabled)
                Button {
                    withAnimation(.snappy) {
                        drawerLater.removeAll { $0 == item.id }
                        drawerLater.append(item.id)
                    }
                } label: {
                    Text("Later")
                        .font(.system(.subheadline, design: tone.design, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 40)
                        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.secondary.opacity(0.35)) }
                        .contentShape(.rect)
                }
            }
            .buttonStyle(DrawerSquish())
        }
        .padding(14)
        .background { shape.fill(tone.surface); shape.fill(tone.warm.opacity(0.1)) }
        .overlay { shape.strokeBorder(tone.warm.opacity(0.4), lineWidth: 1) }
        .padding(.bottom, behind ? 8 : 0)
        .background {
            // The next one, peeking out under it.
            if behind {
                shape.fill(tone.surface)
                    .overlay { shape.strokeBorder(tone.warm.opacity(0.22), lineWidth: 1) }
                    .padding(.horizontal, 14).padding(.top, 16)
            }
        }
        .contextMenu {
            if let dismiss = item.dismiss {
                Button(role: .destructive, action: dismiss) { Text("Dismiss", comment: "Email: never suggest this again") }
            }
        }
    }

    private func drawerSmallCard(_ item: DrawerNeed, tone: DrawerTone) -> some View {
        Button(action: item.act) {
            HStack(spacing: 12) {
                drawerIcon(item.icon, size: 30, tone: tone)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.title).lineLimit(1)
                        .font(.system(.subheadline, design: tone.design, weight: .semibold))
                        .foregroundStyle(tone.ink)
                    Text(verbatim: item.detail).lineLimit(2).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if item.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Text(verbatim: item.pill)
                        .font(.system(.footnote, design: tone.design, weight: .bold))
                        .foregroundStyle(tone.warm)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(tone.warm.opacity(0.15), in: .capsule)
                }
            }
            .padding(12)
            .background(tone.surface, in: .rect(cornerRadius: 16, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(DrawerSquish())
        .disabled(!item.enabled)
        .drawerRow(top: 3, bottom: 3)
        .swipeActions {
            if let dismiss = item.dismiss {
                Button(role: .destructive, action: dismiss) { Text("Dismiss", comment: "Email: never suggest this again") }
            }
        }
    }

    @ViewBuilder
    private func drawerIcon(_ icon: DrawerNeed.Icon, size: CGFloat, tone: DrawerTone) -> some View {
        switch icon {
        case .face(let face):
            BotAvatar(face: face, size: size)
        case .faces(let faces):
            FaceStack(faces: faces, size: size * 0.7)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(tone.warm)
                .frame(width: size, height: size)
                .background(tone.warm.opacity(0.16), in: .rect(cornerRadius: size * 0.32, style: .continuous))
        }
    }

    // Places: Today, Planned, Board and Made as four round buttons that open pages, so the chats
    // stay put. Flat fills, no blur or shadow: cheap to scroll.
    private func drawerPlaces(_ tone: DrawerTone) -> some View {
        HStack(spacing: 0) {
            drawerPlace(.today, .today, "sun.max.fill", tone.places[0], tone)
            drawerPlace(.planned, .planned, "alarm.fill", tone.places[1], tone)
            drawerPlace(.board, .board, "square.grid.3x2.fill", tone.places[2], tone)
            drawerPlace(.made, .made, "sparkles", tone.places[3], tone)
        }
        .drawerRow(top: 4, bottom: 10, side: 8)
        .sensoryFeedback(.impact(weight: .light), trigger: drawerPage)
    }

    private func drawerPlace(_ page: NewDrawer.Page, _ title: NewDrawer.Page, _ symbol: String, _ color: Color, _ tone: DrawerTone) -> some View {
        Button { drawerPage = page } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tone.page)
                    .symbolEffect(.bounce, value: drawerPage == page)
                    .frame(width: 58, height: 58)
                    .background(color, in: .circle)
                Text(title.title)
                    .font(.system(.caption, design: tone.design, weight: .semibold))
                    .foregroundStyle(tone.ink)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(DrawerSquish())
        .accessibilityLabel(Text(title.title))
        .accessibilityIdentifier("drawer.place.\(page)")
    }

    // The team: every bot's face in one row that scrolls sideways, each with what it's doing;
    // All opens the Bots section as it is now.
    @ViewBuilder
    private func drawerTeam(_ tone: DrawerTone) -> some View {
        let faces = botDirectory.roster?.faces ?? [:]
        let items = BotListItem.arranged(bots: listedBots, rooms: [], order: botOrder)
        let bots: [HermesBot] = items.compactMap { if case .bot(let bot) = $0 { bot } else { nil } }
        HStack {
            Text(String(localized: "Team", comment: "The drawer: the heading over your bots' faces (shown in capitals)").localizedUppercase)
                .font(.system(size: 12, weight: .heavy, design: tone.design))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Spacer()
            Button { drawerPage = .bots } label: {
                Text("All \(bots.count)", comment: "All of a bot's skills or tools, e.g. “All 12”")
                    .font(.system(.footnote, design: tone.design, weight: .bold))
                    .foregroundStyle(tone.accent)
            }
            .buttonStyle(.plain)
        }
        .drawerRow(top: 6, bottom: 0)
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 0) {
                ForEach(bots, id: \.name) { bot in
                    drawerMember(bot, face: faces[bot.name] ?? BotFace(seed: bot.name), tone: tone)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .drawerRow(top: 0, bottom: 8, side: 0)
    }

    private func drawerMember(_ bot: HermesBot, face: BotFace, tone: DrawerTone) -> some View {
        let name = bot.label(mainName: settings.headerTitle)
        let isOpen = groups.open == nil && conversation.bot?.profile == bot.name
        let kind = activity.kind(of: bot, open: conversation)
        let unread = !Mutes.isMuted("bot:" + bot.name, settings: settings) && activity.isUnread(bot, open: conversation)
        let busy = kind == .working || openingBot == bot.name
        let (status, color): (String, Color) = switch kind {
        case .needsYou?: (String(localized: "Needs you", comment: "A workstream's status: it waits for the person's approval"), tone.warm)
        case .working?: (String(localized: "Working", comment: "A workstream's status"), tone.accent)
        default: unread ? (String(localized: "Unread", comment: "A conversation not yet read; also the swipe action that marks it so"), tone.ink)
            : (String(localized: "Idle", comment: "A bot doing nothing now"), Color.secondary)
        }
        return Menu {
            botMenu(bot, unread: unread, isOpen: isOpen)
        } label: {
            VStack(spacing: 3) {
                BotAvatar(face: face, size: 58)
                    .padding(3)
                    .overlay {
                        if kind == .needsYou {
                            Circle().strokeBorder(tone.warm, lineWidth: 2.5)
                        } else if busy {
                            Circle().trim(from: 0, to: 0.7)
                                .stroke(tone.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .padding(1.25)
                        } else if unread {
                            Circle().strokeBorder(tone.accent.opacity(0.5), lineWidth: 1.5)
                        }
                    }
                Text(verbatim: name)
                    .font(.system(.caption, design: tone.design, weight: isOpen ? .bold : .semibold))
                    .foregroundStyle(isOpen ? tone.accent : tone.ink)
                    .lineLimit(1)
                Text(verbatim: status)
                    .font(.system(size: 10, weight: .semibold, design: tone.design))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            .frame(width: 72)
            .contentShape(.rect)
        } primaryAction: {
            openBot(bot)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .opensConversation()
        .disabled(opening != nil || openingBot != nil)
        .accessibilityLabel(name)
        .accessibilityValue(status)
    }

    @ViewBuilder
    func drawerDestination(_ page: NewDrawer.Page) -> some View {
        switch page {
        case .today:
            List {
                TodayStrip(openGoal: { shownGoal = $0 }, layout: .page)
                PinnedCardsSection()
                IdeasSection(take: takeIdea)
            }
            .listStyle(.plain)
            .themedPage(settings.theme.listPage)
            .navigationTitle(NewDrawer.Page.today.title)
        case .planned:
            ComingUpList(planned: true, topRow: AnyView(EmptyView()), isShowing: isShowing).id(settings.connectionKey)
                .navigationTitle(NewDrawer.Page.planned.title)
        case .board:
            KanbanView(topRow: AnyView(EmptyView())).id(settings.connectionKey)
                .navigationTitle(NewDrawer.Page.board.title)
        case .made:
            MadeView(topRow: AnyView(EmptyView()), openChat: openMadeIn)
                .navigationTitle(NewDrawer.Page.made.title)
        case .bots:
            List { botsSection }
                .listStyle(.plain)
                .themedPage(settings.theme.listPage)
                .navigationTitle(NewDrawer.Page.bots.title)
        }
    }
}

/// The drawer's colours, all from the theme: its accent, page, surface and ink, and soft
/// companion hues (a warm one for what needs you, four for the places) mixed toward the
/// theme's accent and surface, so Paper gets sepia-ish tones, Terminal greenish ones.
struct DrawerTone {
    let accent, page, surface, ink: Color
    var warm: Color
    var places: [Color]
    let design: Font.Design

    init(_ theme: ResolvedTheme) {
        accent = theme.accent
        page = theme.pageColor
        surface = theme.surfaceColor
        ink = theme.textColor
        func muted(_ red: Double, _ green: Double, _ blue: Double, toward: Double = 0.3) -> Color {
            Color(red: red, green: green, blue: blue).mix(with: theme.accent, by: toward).mix(with: theme.surfaceColor, by: 0.18)
        }
        // A step toward the ink: darker by day and lighter after dark, so the page-coloured
        // words and glyphs on these fills read in both.
        let ink = theme.textColor
        warm = muted(0.86, 0.52, 0.26, toward: 0.12).mix(with: ink, by: 0.3)
        places = [muted(0.86, 0.60, 0.32), muted(0.38, 0.52, 0.80), muted(0.34, 0.62, 0.50), muted(0.60, 0.47, 0.76)]
            .map { $0.mix(with: ink, by: 0.14) }
        design = theme.palette.headingDesign == .default ? .rounded : theme.palette.headingDesign
        // The Arcade theme gets the neon itself, not the muted mix.
        if theme.base == .arcade {
            warm = Theme.arcadeHues[1]
            places = [Theme.arcadeHues[0], Theme.arcadeHues[3], Theme.arcadeHues[2], Theme.arcadeHues[1]]
        }
    }
}

private extension View {
    /// A row of the drawer that draws its own look: no separator, no row background.
    func drawerRow(top: CGFloat, bottom: CGFloat, side: CGFloat = 16) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: side, bottom: bottom, trailing: side))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .selectionDisabled()
    }
}

/// A tile that squishes a little under a finger and springs back.
struct DrawerSquish: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
