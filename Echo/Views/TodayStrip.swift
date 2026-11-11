import SwiftUI

/// "Today", at the top of the chat list (asked 2026-11-06, his pick of the mockups, "A today
/// strip"): the Inbox, the briefings not read yet and the goals as small tiles in one row that
/// scrolls sideways, in place of a row, a deck and a card each, which stacked until the chats
/// were off the screen. A tap opens what a tile is; a briefing's hold menu has Done and Later, as
/// its deck card had. Each kind still follows Settings → Appearance → Top of the Chat List, and
/// the row folds away to a count. The person's lists (2026-11-09, `TodayLists`) come right after
/// the Inbox, one tile each, and stay until a list is deleted.
struct TodayStrip: View {
    let openGoal: (GoalReport) -> Void
    @State private var mail = MailCenter.shared
    @State private var goals = GoalsInbox.shared
    @State private var briefings = BriefingsInbox.shared
    @State private var lists = TodayLists.shared
    @AppStorage("chatList.open.today") private var isOpen = true
    /// A briefing whose job's time is being changed (asked 2026-11-11).
    @State private var retiming: AgentBriefing?
    @Environment(\.theme) private var theme

    static let tileWidth: CGFloat = 150
    static let tileHeight: CGFloat = 124

    var body: some View {
        let account = ChatListCard.inbox.isShown && mail.isSetUp ? mail.inbox : nil
        let deck = ChatListCard.briefings.isShown ? briefings.deck : []
        let goalList = ChatListCard.goals.isShown ? goals.onList : []
        let todayLists = ChatListCard.lists.isShown ? lists.lists : []
        let count = (account == nil ? 0 : 1) + todayLists.count + deck.count + goalList.count
        if count > 0 {
            Section {
                if isOpen {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            if let account { inboxTile(account) }
                            ForEach(todayLists) { listTile($0) }
                            ForEach(deck) { briefingTile($0) }
                            ForEach(goalList) { goalTile($0) }
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
                }
            } header: {
                FoldingHeader(title: String(localized: "Today", comment: "The chat list's row of tiles: the inbox, briefings and goals"),
                              count: count, isOpen: $isOpen)
            }
        }
    }

    // MARK: Tiles

    private func inboxTile(_ account: MailAccount) -> some View {
        let important = account.count(.important), reply = account.count(.needsReply)
        let line = important == 0 && reply == 0
            ? String(localized: "Nothing needs you", comment: "The chat list's Inbox row: nothing important")
            : [important > 0 ? String(localized: "\(important) important", comment: "The chat list's Inbox row") : nil,
               reply > 0 ? String(localized: "\(reply) to answer", comment: "The chat list's Inbox row") : nil]
                .compactMap(\.self).joined(separator: " · ")
        let tile = TodayTile(key: "inbox", kind: Text("Inbox", comment: "The chat list's row for email"), symbol: "envelope.fill", tint: theme.accent, wash: theme.accent,
                             title: account.unread > 0 ? String(localized: "\(account.unread) new", comment: "Today strip: unread emails") : String(localized: "All read", comment: "Today strip: no unread email"),
                             detail: line)
        return tileButton(tile, open: { mail.showingInbox = true }) { TileColorMenu(key: tile.key) }
        .accessibilityHint(Text("Opens your email", comment: "VoiceOver hint: the chat list's Inbox row"))
    }

    private func listTile(_ list: TodayList) -> some View {
        let open = list.open
        let kind = list.items.isEmpty ? Text("List", comment: "Today strip: a to-do list's tile, with nothing on it yet")
            : open.isEmpty ? Text("All done", comment: "Today strip: a to-do list with every item checked off")
            : Text("\(open.count) to do", comment: "Today strip: how many items on a to-do list aren't checked off")
        let detail = open.isEmpty
            ? (list.items.isEmpty ? String(localized: "Nothing on it yet", comment: "Today strip: an empty to-do list") : "")
            : open.prefix(4).map(\.text).formatted(.list(type: .and, width: .narrow))
        let tile = TodayTile(key: "list:" + list.id, kind: kind, symbol: open.isEmpty && !list.items.isEmpty ? "checkmark.circle.fill" : "checklist",
                             tint: .green, wash: .green, title: list.title, detail: detail)
        return tileButton(tile, open: { lists.shownID = list.id }) {
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

    private func briefingTile(_ briefing: AgentBriefing) -> some View {
        let when = briefing.at.formatted(date: .omitted, time: .shortened)
        let detail: String = {
            if let day = briefing.dayBrief {
                return String(localized: "\(day.rows.count) events", comment: "Today strip: a daily brief's tile, how many events")
            }
            return briefing.plainText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        }()
        let tile = TodayTile(key: "brief:" + briefing.jobKey, kind: Text(verbatim: when), symbol: briefing.failed ? "exclamationmark.triangle.fill" : briefing.symbol,
                             tint: briefing.failed ? .red : .yellow, wash: briefing.failed ? .red : .yellow, title: briefing.heading, detail: detail,
                             forecast: briefing.forecastPlace)
        return tileButton(tile, open: { briefings.show(briefing) }) {
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
    private func tileButton<Items: View>(_ tile: TodayTile, open: @escaping () -> Void,
                                         @ViewBuilder menu: () -> Items) -> some View {
        Menu { menu() } label: { tile } primaryAction: { open() }
            .menuStyle(.button)
            .buttonStyle(.plain)
    }

    private func goalTile(_ goal: GoalReport) -> some View {
        let face = DeckCard.face(profile: goal.profile)
        let color = BotAvatar.colors(of: face, theme: theme).deep
        let tile = TodayTile(key: "goal:" + goal.id, kind: goal.total > 0 ? Text("\(goal.done) of \(goal.total) steps", comment: "Today strip: a goal's progress")
                                           : Text("Goal", comment: "Today strip: a goal's tile"),
                      ring: (goal.done, goal.total, color), wash: color,
                      title: goal.title,
                      detail: goal.next.map { String(localized: "Next: \($0)", comment: "Today strip: a goal's next step") }
                          ?? GoalReport.plain(goal.headline))
        return tileButton(tile, open: { openGoal(goal) }) { TileColorMenu(key: tile.key) }
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
    let title: String
    let detail: String
    /// A weather briefing's place: its reading now, in a line over the words.
    var forecast: String?
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
        content
            .environment(\.colorScheme, solid?.scheme ?? scheme)
            .background {
                let shape = RoundedRectangle(cornerRadius: 16)
                if let solid {
                    shape.fill(solid.color)
                } else {
                    shape.fill(theme.surfaceColor)
                    if let tinted { shape.fill(tinted.opacity(scheme == .dark ? 0.3 : 0.2)) }
                }
            }
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) }
            .contentShape(.rect(cornerRadius: 16))
            .accessibilityElement(children: .combine)
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
