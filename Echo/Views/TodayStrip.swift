import SwiftUI

/// "Today", at the top of the chat list (asked 2026-11-06, his pick of the mockups, "A today
/// strip"): the Inbox, the briefings not read yet and the goals as small tiles in one row that
/// scrolls sideways, in place of a row, a deck and a card each, which stacked until the chats
/// were off the screen. A tap opens what a tile is; a briefing's hold menu has Done and Later, as
/// its deck card had. Each kind still follows Settings → Appearance → Top of the Chat List, and
/// the row folds away to a count.
struct TodayStrip: View {
    let openGoal: (GoalReport) -> Void
    @State private var mail = MailCenter.shared
    @State private var goals = GoalsInbox.shared
    @State private var briefings = BriefingsInbox.shared
    @AppStorage("chatList.open.today") private var isOpen = true
    @Environment(\.theme) private var theme

    static let tileWidth: CGFloat = 150
    static let tileHeight: CGFloat = 124

    var body: some View {
        let account = ChatListCard.inbox.isShown && mail.isSetUp ? mail.account : nil
        let deck = ChatListCard.briefings.isShown ? briefings.deck : []
        let goalList = ChatListCard.goals.isShown ? goals.onList : []
        let count = (account == nil ? 0 : 1) + deck.count + goalList.count
        if count > 0 {
            Section {
                if isOpen {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            if let account { inboxTile(account) }
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
        return Button { mail.showingInbox = true } label: {
            TodayTile(kind: Text("Inbox", comment: "The chat list's row for email"), symbol: "envelope.fill", tint: theme.accent,
                      title: account.unread > 0 ? String(localized: "\(account.unread) new", comment: "Today strip: unread emails") : String(localized: "All read", comment: "Today strip: no unread email"),
                      detail: line)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens your email", comment: "VoiceOver hint: the chat list's Inbox row"))
    }

    private func briefingTile(_ briefing: AgentBriefing) -> some View {
        let when = briefing.at.formatted(date: .omitted, time: .shortened)
        let detail: String = {
            if let day = briefing.dayBrief {
                return String(localized: "\(day.rows.count) events", comment: "Today strip: a daily brief's tile, how many events")
            }
            return briefing.plainText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        }()
        return Button { briefings.show(briefing) } label: {
            TodayTile(kind: Text(verbatim: when), symbol: briefing.failed ? "exclamationmark.triangle.fill" : briefing.symbol,
                      tint: briefing.failed ? .red : .yellow, title: briefing.heading, detail: detail)
        }
        .buttonStyle(.plain)
        .contextMenu {
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
        }
    }

    private func goalTile(_ goal: GoalReport) -> some View {
        let face = DeckCard.face(profile: goal.profile)
        let color = BotAvatar.colors(of: face, theme: theme).deep
        return Button { openGoal(goal) } label: {
            TodayTile(kind: goal.total > 0 ? Text("\(goal.done) of \(goal.total) steps", comment: "Today strip: a goal's progress")
                                           : Text("Goal", comment: "Today strip: a goal's tile"),
                      ring: (goal.done, goal.total, color),
                      title: goal.title,
                      detail: goal.next.map { String(localized: "Next: \($0)", comment: "Today strip: a goal's next step") }
                          ?? GoalReport.plain(goal.headline))
        }
        .buttonStyle(.plain)
    }
}

/// One tile of the Today strip: what it is (a symbol or a goal's ring, and a word), a line in bold
/// and a line under it, on the theme's surface.
private struct TodayTile: View {
    let kind: Text
    var symbol: String?
    var tint: Color = .accentColor
    var ring: (done: Int, total: Int, color: Color)?
    let title: String
    let detail: String
    @Environment(\.theme) private var theme

    var body: some View {
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
            Text(title).chatFont(.subheadline, weight: .semibold).lineLimit(2)
            if !detail.isEmpty {
                Text(detail).chatFont(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(12)
        .frame(width: TodayStrip.tileWidth, height: TodayStrip.tileHeight, alignment: .topLeading)
        .background(theme.surfaceColor, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) }
        .contentShape(.rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}
