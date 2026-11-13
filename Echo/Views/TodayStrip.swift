import SwiftUI

/// "Today", at the top of the chat list (asked 2026-11-06, his pick of the mockups, "A today
/// strip"): the Inbox, the briefings not read yet and the goals as small tiles in one row that
/// scrolls sideways, in place of a row, a deck and a card each, which stacked until the chats
/// were off the screen. A tap opens what a tile is; a briefing's hold menu has Done and Later, as
/// its deck card had. Each kind still follows Settings → Appearance → Top of the Chat List, and
/// the row folds away to a count. The person's lists (2026-11-09, `TodayLists`) come right after
/// the Inbox, one tile each, and stay until a list is deleted. Up Next (2026-11-12, when turned
/// on) is the next event on the calendar. The tiles go in the order the person arranged them
/// (2026-11-12: Move Left / Right on a tile's hold menu, or Arrange Tiles…).
struct TodayStrip: View {
    let openGoal: (GoalReport) -> Void
    /// `.strip`: one row that scrolls sideways at the top of the classic list. `.page`: the new
    /// drawer's Today page (2026-11-13), with room for a header and the tiles in a grid, each
    /// showing what it is (the unread count, a list's items, a goal's ring, the next event).
    var layout: Layout = .strip
    enum Layout { case strip, page }
    @State private var mail = MailCenter.shared
    @State private var goals = GoalsInbox.shared
    @State private var briefings = BriefingsInbox.shared
    @State private var lists = TodayLists.shared
    @State private var upNext = CalendarUpNext.shared
    @State private var settings = Settings.shared
    @State private var arranging = false
    @Environment(\.openURL) private var openURL
    @AppStorage("chatList.open.today") private var isOpen = true
    /// The Today page's tiles wiggling to be dragged into order (asked 2026-11-13), and the one
    /// being dragged.
    @State private var arrangingInPlace = false
    @State private var dragging: String?
    /// A briefing whose job's time is being changed (asked 2026-11-11).
    @State private var retiming: AgentBriefing?
    @Environment(\.theme) private var theme

    static let tileWidth: CGFloat = 150
    static let tileHeight: CGFloat = 124

    /// A tile, by its key (`TodayTile.key`), with what Arrange Tiles… calls it.
    private struct Entry: Identifiable {
        let key: String
        let name: String
        let symbol: String
        let view: AnyView
        var id: String { key }
    }

    var body: some View {
        let account = ChatListCard.inbox.isShown && mail.isSetUp ? mail.inbox : nil
        let deck = ChatListCard.briefings.isShown ? briefings.deck : []
        let goalList = ChatListCard.goals.isShown ? goals.onList : []
        let todayLists = ChatListCard.lists.isShown ? lists.lists : []
        let event = settings.todayUpNext ? upNext.next : nil
        // The keys first, in the person's order, so each tile's menu knows where it stands.
        var natural: [String] = []
        if event != nil { natural.append("upnext") }
        if account != nil { natural.append("inbox") }
        natural += todayLists.map { "list:" + $0.id } + deck.map { "brief:" + $0.jobKey } + goalList.map { "goal:" + $0.id }
        let keys = Self.arranged(natural, order: settings.todayTileOrder)
        var entries: [Entry] = []
        if let event {
            entries.append(Entry(key: "upnext", name: String(localized: "Up Next", comment: "Today strip: the tile with the next event on the calendar"),
                                 symbol: "calendar", view: AnyView(upNextTile(event, keys: keys))))
        }
        if let account {
            entries.append(Entry(key: "inbox", name: String(localized: "Inbox", comment: "The chat list's row for email"),
                                 symbol: "envelope", view: AnyView(inboxTile(account, keys: keys))))
        }
        for list in todayLists {
            entries.append(Entry(key: "list:" + list.id, name: list.title, symbol: "checklist", view: AnyView(listTile(list, keys: keys))))
        }
        for briefing in deck {
            entries.append(Entry(key: "brief:" + briefing.jobKey, name: briefing.heading, symbol: briefing.symbol, view: AnyView(briefingTile(briefing, keys: keys))))
        }
        for goal in goalList {
            entries.append(Entry(key: "goal:" + goal.id, name: goal.title, symbol: "flag.checkered", view: AnyView(goalTile(goal, keys: keys))))
        }
        let byKey = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let shown = keys.compactMap { byKey[$0] }
        let count = shown.count
        if layout == .page {
            let todo = todayLists.reduce(0) { $0 + $1.open.count }
            return AnyView(page(shown, todo: todo, unread: account?.unread ?? 0, briefs: deck.count))
        }
        return AnyView(Group {
            if count > 0 {
                Section {
                    if isOpen {
                        ScrollView(.horizontal) {
                            HStack(spacing: 10) {
                                ForEach(shown) { $0.view }
                            }
                            .padding(.horizontal, 16)
                        }
                        .scrollIndicators(.hidden)
                        .scrollClipDisabled()
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 10, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                        .sheet(item: $retiming) { BriefingTimeSheet(briefing: $0) }
                        .sheet(isPresented: $arranging) {
                            ArrangeTilesSheet(tiles: shown.map { ($0.key, $0.name, $0.symbol) })
                        }
                    }
                } header: {
                    FoldingHeader(title: String(localized: "Today", comment: "The chat list's row of tiles: the inbox, briefings and goals"),
                                  count: count, isOpen: $isOpen)
                }
            }
        })
    }

    /// The Today page: the day in its colour with three counts, the next event across the page,
    /// then the rest two to a row. Nothing scrolls sideways.
    @ViewBuilder
    private func page(_ shown: [Entry], todo: Int, unread: Int, briefs: Int) -> some View {
        let tone = DrawerTone(theme)
        let wide = shown.first { $0.key == "upnext" }
        let rest = shown.filter { $0.key != "upnext" }
        Section {
            TodayPageHero(tone: tone, todo: todo, unread: unread, briefs: briefs)
                .todayPageRow(top: 4, bottom: 12)
                // On the one row, not the section: on the section every row brought its own copy.
                .sheet(item: $retiming) { BriefingTimeSheet(briefing: $0) }
                .sheet(isPresented: $arranging) {
                    ArrangeTilesSheet(tiles: shown.map { ($0.key, $0.name, $0.symbol) })
                }
                .toolbar {
                    if rest.count > 1 {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                withAnimation(.snappy) { arrangingInPlace.toggle() }
                                dragging = nil
                            } label: {
                                if arrangingInPlace {
                                    Text("Done")
                                } else {
                                    Label { Text("Arrange Tiles", comment: "Title of the sheet that puts the Today tiles in order") } icon: { Image(systemName: "rectangle.2.swap") }
                                }
                            }
                        }
                    }
                }
                .onDisappear { arrangingInPlace = false }
            #if DEBUG
                // `-echo.arrangeToday`: the page opens with its tiles being arranged (screenshots).
                .task { if DevHooks.has("-echo.arrangeToday") { arrangingInPlace = true } }
            #endif
            if let wide {
                wide.view.todayPageRow(top: 0, bottom: 12)
            }
            if !rest.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(Array(rest.enumerated()), id: \.element.key) { index, entry in
                        if arrangingInPlace {
                            arrangeable(entry, index: index, keys: shown.map(\.key), tone: tone)
                        } else {
                            entry.view
                        }
                    }
                }
                .sensoryFeedback(.selection, trigger: settings.todayTileOrder)
                .todayPageRow(top: 0, bottom: 14)
            }
            if shown.isEmpty {
                TodayPageEmpty(tone: tone).todayPageRow(top: 0, bottom: 14)
            }
        }
    }

    /// A tile while the page is being arranged: it wiggles, its taps and menu are off, and it
    /// can be picked up and dropped on another tile's place; the others make way as it passes.
    private func arrangeable(_ entry: Entry, index: Int, keys: [String], tone: DrawerTone) -> some View {
        entry.view
            .allowsHitTesting(false)
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(tone.places[0], style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tone.page)
                    .frame(width: 26, height: 26)
                    .background(tone.places[0], in: .circle)
                    .offset(x: 6, y: -6)
            }
            .opacity(dragging == entry.key ? 0.35 : 1)
            .modifier(Wiggle(phase: index))
            .contentShape(.rect(cornerRadius: 22))
            .onDrag {
                dragging = entry.key
                return NSItemProvider(object: entry.key as NSString)
            }
            .onDrop(of: [.text], delegate: TileDrop(target: entry.key, dragging: $dragging) { moved, target in
                withAnimation(.snappy) {
                    settings.todayTileOrder = Self.placing(moved, at: target, in: keys, order: settings.todayTileOrder)
                }
            })
            .accessibilityAction(named: Text("Move Left", comment: "A Today tile's hold menu: swap it with the tile before it")) { move(entry.key, by: -1, in: keys) }
            .accessibilityAction(named: Text("Move Right", comment: "A Today tile's hold menu: swap it with the tile after it")) { move(entry.key, by: 1, in: keys) }
    }

    /// The order after `key` is dragged onto `target`'s place: it takes that place and the tiles
    /// between shift one along; what's kept for tiles not shown stays after them.
    static func placing(_ key: String, at target: String, in keys: [String], order: [String]) -> [String] {
        guard key != target, let from = keys.firstIndex(of: key), let to = keys.firstIndex(of: target) else { return order }
        var keys = keys
        keys.remove(at: from)
        keys.insert(key, at: to)
        return keys + order.filter { !keys.contains($0) }
    }

    private var big: Bool { layout == .page }

    /// `keys` in the person's order: those they placed as they placed them, then the rest as the
    /// strip has them.
    static func arranged(_ keys: [String], order: [String]) -> [String] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let placed = keys.filter { rank[$0] != nil }.sorted { rank[$0]! < rank[$1]! }
        return placed + keys.filter { rank[$0] == nil }
    }

    /// The order after a tile moves one place: what's shown, then what was kept for tiles that
    /// aren't (a briefing read today comes back where it was).
    static func moving(_ key: String, by step: Int, in keys: [String], order: [String]) -> [String] {
        var keys = keys
        guard let at = keys.firstIndex(of: key), keys.indices.contains(at + step) else { return order }
        keys.swapAt(at, at + step)
        return keys + order.filter { !keys.contains($0) }
    }

    // MARK: Tiles

    private func inboxTile(_ account: MailAccount, keys: [String]) -> some View {
        let important = account.count(.important), reply = account.count(.needsReply)
        let line = important == 0 && reply == 0
            ? String(localized: "Nothing needs you", comment: "The chat list's Inbox row: nothing important")
            : [important > 0 ? String(localized: "\(important) important", comment: "The chat list's Inbox row") : nil,
               reply > 0 ? String(localized: "\(reply) to answer", comment: "The chat list's Inbox row") : nil]
                .compactMap(\.self).joined(separator: " · ")
        let title = account.unread > 0 ? String(localized: "\(account.unread) new", comment: "Today strip: unread emails") : String(localized: "All read", comment: "Today strip: no unread email")
        var tile = TodayTile(key: "inbox", kind: Text("Inbox", comment: "The chat list's row for email"), symbol: "envelope.fill", tint: theme.accent, wash: theme.accent,
                             title: big ? "" : title, detail: line)
        if big {
            tile.big = true
            tile.watermark = "envelope.fill"
            tile.feature = AnyView(TodayBigNumber(count: account.unread, label: account.unread > 0 ? String(localized: "Unread", comment: "A conversation not yet read; also the swipe action that marks it so") : title,
                                                  tint: theme.accent, design: DrawerTone(theme).design))
        }
        return tileButton(tile, keys: keys, open: { mail.showingInbox = true }) { TileColorMenu(key: tile.key) }
        .accessibilityHint(Text("Opens your email", comment: "VoiceOver hint: the chat list's Inbox row"))
    }

    private func listTile(_ list: TodayList, keys: [String]) -> some View {
        let open = list.open
        let kind = list.items.isEmpty ? Text("List", comment: "Today strip: a to-do list's tile, with nothing on it yet")
            : open.isEmpty ? Text("All done", comment: "Today strip: a to-do list with every item checked off")
            : Text("\(open.count) to do", comment: "Today strip: how many items on a to-do list aren't checked off")
        let detail = open.isEmpty
            ? (list.items.isEmpty ? String(localized: "Nothing on it yet", comment: "Today strip: an empty to-do list") : "")
            : open.prefix(4).map(\.text).formatted(.list(type: .and, width: .narrow))
        var tile = TodayTile(key: "list:" + list.id, kind: kind, symbol: open.isEmpty && !list.items.isEmpty ? "checkmark.circle.fill" : "checklist",
                             tint: .green, wash: .green, title: list.title, detail: big && !open.isEmpty ? "" : detail)
        if big {
            tile.big = true
            tile.watermark = "checklist"
            if !list.items.isEmpty { tile.feature = AnyView(TodayListItems(list: list)) }
        }
        return tileButton(tile, keys: keys, open: { lists.shownID = list.id }) {
            if !list.finished.isEmpty {
                Button { lists.clearDone(in: list) } label: {
                    Label { Text("Clear Done", comment: "A to-do list: remove the items checked off") } icon: { Image(systemName: "checkmark.circle.badge.xmark") }
                }
            }
            Button(role: .destructive) { lists.delete(list) } label: {
                Label { Text("Delete List", comment: "A to-do list: delete the whole list") } icon: { Image(systemName: "trash") }
            }
            TileColorMenu(key: tile.key)
        }
        .accessibilityHint(Text("Opens the list", comment: "VoiceOver hint: a to-do list's tile on the chat list"))
    }

    private func briefingTile(_ briefing: AgentBriefing, keys: [String]) -> some View {
        let when = briefing.at.formatted(date: .omitted, time: .shortened)
        let detail: String = {
            if let day = briefing.dayBrief {
                return String(localized: "\(day.rows.count) events", comment: "Today strip: a daily brief's tile, how many events")
            }
            return briefing.plainText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        }()
        var tile = TodayTile(key: "brief:" + briefing.jobKey, kind: Text(verbatim: when), symbol: briefing.failed ? "exclamationmark.triangle.fill" : briefing.symbol,
                             tint: briefing.failed ? .red : .yellow, wash: briefing.failed ? .red : .yellow, title: briefing.heading, detail: detail,
                             forecast: briefing.forecastPlace)
        if big {
            tile.big = true
            tile.watermark = briefing.symbol
            if briefing.forecastPlace == nil, briefing.dayBrief == nil {
                // The briefing's opening lines, where the strip had room for one.
                tile.detail = ""
                tile.feature = AnyView(Text(briefing.plainText.split(whereSeparator: \.isNewline).prefix(3).joined(separator: " "))
                    .chatFont(.caption).foregroundStyle(.secondary).lineLimit(4))
            }
        }
        return tileButton(tile, keys: keys, open: { briefings.show(briefing) }) {
            Button { briefings.markJobRead(briefing) } label: {
                Label { Text("Done") } icon: { Image(systemName: "checkmark") }
            }
            Button { briefings.later(briefing, until: Later.soon()) } label: {
                Label { Text("Later") } icon: { Image(systemName: "clock") }
            }
            if briefings.briefings.count > 1 {
                Button { briefings.showingAll = true } label: {
                    Label { Text("All Briefings") } icon: { Image(systemName: "list.bullet") }
                }
            }
            if briefing.job != nil {
                Button { retiming = briefing } label: {
                    Label { Text("Change Time…", comment: "A briefing's menu: pick when its job runs") } icon: { Image(systemName: "clock.arrow.circlepath") }
                }
            }
            TileColorMenu(key: tile.key)
        }
    }

    /// A tile that opens on a tap and holds up its own menu on a press. A menu button, not a
    /// context menu: the strip is one row of the list, and a row keeps one context menu, so a
    /// press on any tile lifted the whole row (2026-11-11) and then, with a menu on each tile,
    /// brought up the first tile's menu whichever was pressed.
    private func tileButton<Items: View>(_ tile: TodayTile, keys: [String], open: @escaping () -> Void,
                                         @ViewBuilder menu: () -> Items) -> some View {
        Menu {
            menu()
            Section { arrangeItems(tile.key, keys: keys) }
        } label: { tile } primaryAction: { open() }
            .menuStyle(.button)
            .buttonStyle(.plain)
    }

    /// Moving a tile: a place left or right, or the whole row in a sheet.
    @ViewBuilder
    private func arrangeItems(_ key: String, keys: [String]) -> some View {
        if keys.count > 1 {
            if keys.first != key {
                Button { move(key, by: -1, in: keys) } label: {
                    Label { Text("Move Left", comment: "A Today tile's hold menu: swap it with the tile before it") } icon: { Image(systemName: "arrow.left") }
                }
            }
            if keys.last != key {
                Button { move(key, by: 1, in: keys) } label: {
                    Label { Text("Move Right", comment: "A Today tile's hold menu: swap it with the tile after it") } icon: { Image(systemName: "arrow.right") }
                }
            }
            Button { arranging = true } label: {
                Label { Text("Arrange Tiles…", comment: "A Today tile's hold menu: put the tiles in order in a list") } icon: { Image(systemName: "arrow.left.arrow.right") }
            }
        }
    }

    private func move(_ key: String, by step: Int, in keys: [String]) {
        withAnimation(.snappy) { settings.todayTileOrder = Self.moving(key, by: step, in: keys, order: settings.todayTileOrder) }
    }

    /// The next event on the calendar, ticking to the minute.
    private func upNextTile(_ event: CalendarUpNext.Event, keys: [String]) -> some View {
        TimelineView(.everyMinute) { context in
            let tile = upNextModel(event, now: context.date)
            tileButton(tile, keys: keys, open: { AgendaCard.calendarURL(at: event.start).map { openURL($0) } }) {
                Button { settings.todayUpNext = false } label: {
                    Label { Text("Hide Up Next", comment: "The Up Next tile's hold menu: turn the tile off (Settings › Appearance › Top of the Chat List turns it back on)") } icon: { Image(systemName: "eye.slash") }
                }
                TileColorMenu(key: tile.key)
            }
            .accessibilityHint(Text("Opens Calendar", comment: "VoiceOver hint: the Up Next tile on the chat list"))
        }
    }

    private func upNextModel(_ event: CalendarUpNext.Event, now: Date) -> TodayTile {
        let on = event.isOn(at: now)
        let place = event.location?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var tile = TodayTile(key: "upnext", kind: on ? Text("Now") : Text("Up Next", comment: "Today strip: the tile with the next event on the calendar"),
                             symbol: "calendar", tint: event.color ?? .red, wash: event.color ?? .red, title: event.title,
                             detail: [CalendarUpNext.when(event, now: now), place].filter { !$0.isEmpty }.joined(separator: " · "))
        if big {
            tile.big = true
            tile.height = 128
            tile.title = ""
            tile.detail = ""
            tile.watermark = "calendar"
            tile.feature = AnyView(TodayUpNextFeature(event: event, place: place, now: now, tone: DrawerTone(theme)))
        }
        return tile
    }

    private func goalTile(_ goal: GoalReport, keys: [String]) -> some View {
        let face = DeckCard.face(profile: goal.profile)
        let color = BotAvatar.colors(of: face, theme: theme).deep
        var tile = TodayTile(key: "goal:" + goal.id, kind: goal.total > 0 ? Text("\(goal.done) of \(goal.total) steps", comment: "Today strip: a goal's progress")
                                           : Text("Goal", comment: "Today strip: a goal's tile"),
                      ring: (goal.done, goal.total, color), wash: color,
                      title: goal.title,
                      detail: goal.next.map { String(localized: "Next: \($0)", comment: "Today strip: a goal's next step") }
                          ?? GoalReport.plain(goal.headline))
        if big {
            tile.big = true
            tile.watermark = "flag.checkered"
            if goal.total > 0 {
                // The ring beside the next step, so the title keeps its two lines.
                tile.feature = AnyView(HStack(alignment: .center, spacing: 10) {
                    GoalRing(done: goal.done, total: goal.total, color: color, size: 40)
                    Text(tile.detail).chatFont(.caption).foregroundStyle(.secondary).lineLimit(3)
                })
                tile.detail = ""
            }
        }
        return tileButton(tile, keys: keys, open: { openGoal(goal) }) { TileColorMenu(key: tile.key) }
    }
}

/// One tile of the Today strip: what it is (a symbol or a goal's ring, and a word), a line in bold
/// and a line under it, on the theme's surface, in the colour Settings → Appearance → Today Tiles
/// gives it (`wash` its kind's own).
private struct TodayTile: View {
    /// Which tile it is, for its own colour (`Settings.todayTileColors`).
    let key: String
    let kind: Text
    var symbol: String?
    var tint: Color = .accentColor
    var ring: (done: Int, total: Int, color: Color)?
    var wash: Color = .accentColor
    var title: String
    var detail: String
    /// A weather briefing's place: its reading now, in a line over the words.
    var forecast: String?
    /// The Today page's tile (`TodayStrip.Layout.page`): as wide as its column, taller, with
    /// `feature` (what the tile is about, drawn big) under the title and its symbol large and
    /// faint in the corner.
    var big = false
    var feature: AnyView?
    var watermark: String?
    var height: CGFloat = 188
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let choice = Settings.shared.todayColor(forTile: key)
        let solid: (color: Color, scheme: ColorScheme)? = if case let .color(card) = choice, let drawn = card.solid, let color = card.color(in: theme) {
            (color, drawn)
        } else { nil }
        let tinted: Color? = switch choice {
        case .plain: nil
        case .byKind: wash
        case let .color(card): solid == nil ? card.color(in: theme) : nil
        }
        let radius: CGFloat = big ? 22 : 16
        Group { if big { bigContent } else { content } }
            .environment(\.colorScheme, solid?.scheme ?? scheme)
            .background {
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                if let solid {
                    shape.fill(solid.color)
                } else {
                    shape.fill(theme.surfaceColor)
                    if let tinted { shape.fill(tinted.opacity(scheme == .dark ? 0.3 : 0.2)) }
                }
            }
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) }
            .contentShape(.rect(cornerRadius: radius))
            .accessibilityElement(children: .combine)
    }

    private var bigContent: some View {
        let design = DrawerTone(theme).design
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let ring, feature == nil {
                    GoalRing(done: ring.done, total: ring.total, color: ring.color, size: 16, showsCount: false)
                } else if let symbol {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
                kind.lineLimit(1)
            }
            .font(.system(.caption, design: design, weight: .bold))
            .foregroundStyle(.secondary)
            if !title.isEmpty {
                Text(title).font(.system(.headline, design: design, weight: .bold)).lineLimit(2)
            }
            if let forecast { BriefingForecast(place: forecast, line: true).chatFont(.subheadline, weight: .semibold) }
            if let feature { feature }
            Spacer(minLength: 0)
            if !detail.isEmpty {
                Text(detail).chatFont(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(alignment: .bottomTrailing) {
            if let watermark {
                Image(systemName: watermark)
                    .font(.system(size: 58, weight: .bold))
                    .foregroundStyle(tint.opacity(0.08))
                    .offset(x: 14, y: 14)
                    .accessibilityHidden(true)
            }
        }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let ring {
                    GoalRing(done: ring.done, total: ring.total, color: ring.color, size: 16, showsCount: false)
                } else if let symbol {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
                kind.lineLimit(1)
            }
            .chatFont(.caption, weight: .semibold)
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(title).chatFont(.subheadline, weight: .semibold).lineLimit(forecast == nil ? 2 : 1)
            if let forecast { BriefingForecast(place: forecast, line: true).chatFont(.subheadline, weight: .semibold) }
            if !detail.isEmpty {
                Text(detail).chatFont(.caption).foregroundStyle(.secondary).lineLimit(forecast == nil ? 2 : 1)
            }
        }
        .padding(12)
        .frame(width: TodayStrip.tileWidth, height: TodayStrip.tileHeight, alignment: .topLeading)
    }
}

/// A Today tile's own colour, on its hold menu (asked 2026-11-11): like the others (Settings →
/// Appearance → Today Tiles), plain, or one of the colours.
private struct TileColorMenu: View {
    let key: String
    @State private var settings = Settings.shared
    @Environment(\.theme) private var theme

    var body: some View {
        Picker(selection: Binding(get: { settings.todayTileColors[key] ?? "" },
                                  set: { settings.todayTileColors[key] = $0.isEmpty ? nil : $0 })) {
            Text("Like the Other Tiles", comment: "A Today tile's colour menu: follow Settings → Appearance → Today Tiles").tag("")
            ForEach(Settings.TodayColor.allCases.filter { $0 != .byKind }) { choice in
                if case let .color(card) = choice, let color = card.color(in: theme) {
                    Label { Text(choice.label) } icon: { Image(systemName: "circle.fill").foregroundStyle(color) }.tag(choice.rawValue)
                } else {
                    Text(choice.label).tag(choice.rawValue)
                }
            }
        } label: {
            Label { Text("Tile Color", comment: "A Today tile's hold menu: the colour of this one tile") } icon: { Image(systemName: "paintpalette") }
        }
        .pickerStyle(.menu)
    }
}

/// Arrange Tiles… (asked 2026-11-12): the Today tiles as a list to drag into order. The order is
/// kept by tile key (`Settings.todayTileOrder`), synced like the tiles' colours.
private struct ArrangeTilesSheet: View {
    @State var tiles: [(key: String, name: String, symbol: String)]
    @State private var settings = Settings.shared
    @Environment(\.dismiss) private var dismiss

    init(tiles: [(String, String, String)]) {
        _tiles = State(initialValue: tiles.map { (key: $0.0, name: $0.1, symbol: $0.2) })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(tiles, id: \.key) { tile in
                        Label { Text(tile.name).lineLimit(1) } icon: { Image(systemName: tile.symbol) }
                    }
                    .onMove { from, to in
                        tiles.move(fromOffsets: from, toOffset: to)
                        let keys = tiles.map(\.key)
                        settings.todayTileOrder = keys + settings.todayTileOrder.filter { !keys.contains($0) }
                    }
                } footer: {
                    Text("Drag the tiles into the order you want them in the Today row.", comment: "Arrange Tiles: under the list of Today tiles")
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle(Text("Arrange Tiles", comment: "Title of the sheet that puts the Today tiles in order"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "Original Order", comment: "Arrange Tiles: forget the order and go back to the strip's own")) {
                        settings.todayTileOrder = []
                        dismiss()
                    }
                    .disabled(settings.todayTileOrder.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - The Today page (2026-11-13)

/// The Today page's head: the day, large, beside its sun in the drawer's Today colour, and three
/// counts (to do on the lists, unread mail, briefings) in chips like the drawer's.
private struct TodayPageHero: View {
    let tone: DrawerTone
    let todo: Int
    let unread: Int
    let briefs: Int

    var body: some View {
        let now = Date.now
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(tone.page)
                    .symbolEffect(.bounce, value: todo)
                    .frame(width: 58, height: 58)
                    .background(tone.places[0], in: .rect(cornerRadius: 18, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(now.formatted(.dateTime.weekday(.wide)))
                        .font(.system(.title, design: tone.design, weight: .heavy))
                        .foregroundStyle(tone.ink)
                    Text(now.formatted(.dateTime.month(.wide).day()))
                        .font(.system(.subheadline, design: tone.design, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                DrawerStatChip(count: todo, label: String(localized: "To Do", comment: "The Today page: a count of the open items on your lists (shown in capitals)"),
                               color: tone.places[2], tone: tone)
                DrawerStatChip(count: unread, label: String(localized: "Unread", comment: "A conversation not yet read; also the swipe action that marks it so"),
                               color: tone.accent, tone: tone)
                DrawerStatChip(count: briefs, label: String(localized: "Briefings", comment: "The chat list's deck of briefings"),
                               color: tone.places[0], tone: tone)
            }
        }
    }
}

/// A count and its label in a chip, the drawer's look: the number in its colour when there is one.
struct DrawerStatChip: View {
    let count: Int
    let label: String
    let color: Color
    let tone: DrawerTone

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "\(count)")
                .font(.system(size: 24, weight: .heavy, design: tone.design))
                .monospacedDigit()
                .foregroundStyle(count > 0 ? color : Color.secondary)
                .contentTransition(.numericText())
            Text(verbatim: label.localizedUppercase)
                .font(.system(size: 10, weight: .bold, design: tone.design))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(tone.surface, in: shape)
        .overlay { shape.strokeBorder(color.opacity(count > 0 ? 0.35 : 0.1), lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }
}

/// A count drawn big with a word beside it: the Inbox tile's unread mail.
private struct TodayBigNumber: View {
    let count: Int
    let label: String
    let tint: Color
    let design: Font.Design

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if count > 0 {
                Text(verbatim: "\(count)")
                    .font(.system(size: 44, weight: .heavy, design: design))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(tint)
            }
            Text(label).font(.system(.subheadline, design: design, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// A list's open items, three of them, under a bar of how much of it is done.
private struct TodayListItems: View {
    let list: TodayList

    var body: some View {
        let open = list.open
        VStack(alignment: .leading, spacing: 5) {
            ProgressView(value: Double(list.finished.count), total: Double(max(1, list.items.count)))
                .tint(.green)
                .accessibilityHidden(true)
            ForEach(open.prefix(3)) { item in
                HStack(spacing: 6) {
                    Image(systemName: "circle").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                    Text(item.text).chatFont(.caption).lineLimit(1)
                }
            }
            if open.count > 3 {
                Text(verbatim: "+\(open.count - 3)").chatFont(.caption2, weight: .semibold).foregroundStyle(.secondary)
            }
        }
    }
}

/// The next event across the page: its day in a block of the calendar's colour, the time large,
/// what and where, and how long until it in a pill.
private struct TodayUpNextFeature: View {
    let event: CalendarUpNext.Event
    let place: String
    let now: Date
    let tone: DrawerTone

    var body: some View {
        let color = event.color ?? tone.places[0]
        let on = event.isOn(at: now)
        HStack(alignment: .center, spacing: 14) {
            VStack(spacing: 0) {
                Text(event.start.formatted(.dateTime.weekday(.abbreviated)).localizedUppercase)
                    .font(.system(size: 11, weight: .heavy, design: tone.design))
                Text(event.start.formatted(.dateTime.day()))
                    .font(.system(size: 26, weight: .heavy, design: tone.design))
                    .monospacedDigit()
            }
            .foregroundStyle(tone.page)
            .frame(width: 58, height: 62)
            .background(color, in: .rect(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(event.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(.title2, design: tone.design, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(color)
                Text(event.title).font(.system(.headline, design: tone.design, weight: .bold)).lineLimit(1)
                if !place.isEmpty {
                    Text(place).chatFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(on ? String(localized: "Now", comment: "A weather card's reading, and its first hour: now") : CalendarUpNext.when(event, now: now))
                .font(.system(.caption, design: tone.design, weight: .bold))
                .foregroundStyle(color)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(color.opacity(0.16), in: .capsule)
                .lineLimit(1)
        }
    }
}

/// Nothing on the page yet: what comes here, in the page's own colour.
private struct TodayPageEmpty: View {
    let tone: DrawerTone

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sun.horizon.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(tone.places[0])
            Text("Nothing for Today Yet", comment: "The Today page with no tiles")
                .font(.system(.headline, design: tone.design, weight: .bold))
            Text("Your inbox, to-do lists, briefings, goals and the next event on your calendar show here as they come. Settings › Top of the Chat List picks which.",
                 comment: "The Today page with no tiles: what shows there")
                .chatFont(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(tone.surface, in: .rect(cornerRadius: 22, style: .continuous))
    }
}

private extension View {
    /// A row of the Today page that draws its own look.
    func todayPageRow(top: CGFloat, bottom: CGFloat) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 16, bottom: bottom, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .selectionDisabled()
    }
}

/// A tile being dragged over another: it takes that tile's place as it passes.
private struct TileDrop: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let place: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        place(dragging, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// A small rock back and forth while the tiles are being arranged, each a little out of step.
private struct Wiggle: ViewModifier {
    let phase: Int
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(reduceMotion ? 0 : on ? 1.2 : -1.2))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.13).repeatForever(autoreverses: true).delay(Double(phase % 3) * 0.05), value: on)
            .onAppear { on = true }
    }
}
