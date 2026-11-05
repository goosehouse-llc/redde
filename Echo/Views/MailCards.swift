import SwiftUI

/// The inbox card in a chat (`redde_show`'s `inbox`): the piles with their counts and a few emails
/// each, as the plugin sorted them. A tap opens the email, read from the server then; the card
/// itself holds only what the list says.
struct InboxCardView: View {
    let card: ReplyCard.InboxCard
    @State private var open: MailThread?

    var body: some View {
        CardBox(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "tray.full")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                    .background(.tint.opacity(0.14), in: .rect(cornerRadius: 9))
                    .accessibilityHidden(true)
                Text(card.title ?? String(localized: "Your inbox", comment: "The inbox card's title when the agent gives none"))
                    .chatFont(.subheadline, weight: .semibold)
            }
            ForEach(card.buckets, id: \.bucket) { pile in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(pile.bucket.label, systemImage: pile.bucket.symbol).chatFont(.footnote, weight: .semibold)
                        Spacer()
                        Text(pile.count, format: .number).chatFont(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    ForEach(pile.threads, id: \.self) { row in
                        Button { open = thread(row, in: pile.bucket) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(row.unread ? Color.accentColor : .clear).frame(width: 6, height: 6).padding(.top, 6)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.from).chatFont(.caption, weight: .semibold).lineLimit(1)
                                    Text(row.summary ?? row.subject).chatFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text([row.unread ? String(localized: "Unread", comment: "VoiceOver: an unread email") : nil, row.from, row.subject, row.summary]
                            .compactMap { $0 }.joined(separator: ", ")))
                    }
                }
            }
        }
        .sheet(item: $open) { thread in
            NavigationStack { MailReaderView(thread: thread).doneButton() }
        }
    }

    /// What the card knows of an email, as the reader takes it.
    private func thread(_ row: ReplyCard.InboxCard.Row, in bucket: MailBucket) -> MailThread {
        MailThread(id: row.id, from: row.from, address: "", subject: row.subject, date: .now, unread: row.unread, bucket: bucket, summary: row.summary)
    }
}

/// Agent Activity's email: what rules, taps and the agent did to the mail lately, each with Undo.
/// Asked of the plugin when Agent Activity opens, and only once email is set up.
struct MailActivitySection: View {
    @State private var center = MailCenter.shared

    var body: some View {
        if center.isSetUp {
            Section {
                if center.log.isEmpty {
                    Text("Nothing done to your email lately.", comment: "Agent Activity: no email actions").foregroundStyle(.secondary).font(.subheadline)
                }
                ForEach(center.log.prefix(12)) { entry in MailLogRow(entry: entry) }
            } header: {
                Label { Text("Email", comment: "Agent Activity: the email section") } icon: { Image(systemName: "envelope") }
            }
            .task { await center.loadLog(30) }
        }
    }
}

/// The briefing deck's email page (plugin 1.16's `mail brief`): first in the deck once a day while
/// something waits on him, as a briefing would be. A tap opens the Inbox; Done puts it away until
/// tomorrow. Drawn from the brief kept in the app group, asked of the plugin at most hourly.
@MainActor
enum MailBriefPage {
    static let prefix = "mail/"
    private static let doneKey = "mailBriefDone"

    private static func day(_ date: Date = .now) -> String { date.formatted(.iso8601.year().month().day()) }

    /// The page, as a deck item, or nil when there's nothing waiting or he put today's away.
    static func item(_ brief: MailBrief?, now: Date = .now, defaults: UserDefaults = .standard) -> AgentBriefing? {
        guard let brief, brief.worthShowing, defaults.string(forKey: doneKey) != day(now) else { return nil }
        return AgentBriefing(id: prefix + day(now), title: String(localized: "Your Email", comment: "The briefing deck's email page"),
                             agent: "Redde", text: brief.headline, at: brief.asOf ?? now, failed: false)
    }

    static func isMail(_ briefing: AgentBriefing) -> Bool { briefing.id.hasPrefix(prefix) }

    static func done(now: Date = .now, defaults: UserDefaults = .standard) { defaults.set(day(now), forKey: doneKey) }

    static func open() {
        done()
        MailCenter.shared.showingInbox = true
    }
}

/// The email page on its card: the counts, then the few emails waiting most.
struct MailBriefCard: View {
    let brief: MailBrief
    var isTop = true
    var moved: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DeckCardHeader(face: DeckCard.face(profile: "default"), name: String(localized: "Your Email", comment: "The briefing deck's email page"),
                           subtitle: subtitle, symbol: "envelope.fill", symbolColor: .blue, isTop: isTop, moved: moved, bounce: "mail")
            Text(brief.headline)
                .chatFont(.title3, weight: .bold, design: .rounded)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            ForEach(brief.top.prefix(3)) { thread in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: thread.bucket.symbol).chatFont(.caption).opacity(0.7).accessibilityHidden(true)
                    Text("\(Text(thread.from).bold()) \(thread.line.isEmpty ? thread.subject : thread.line)")
                        .chatFont(.subheadline).opacity(0.8).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: Text {
        let when = (brief.asOf ?? .now).formatted(date: .omitted, time: .shortened)
        return Text("your inbox · \(when)", comment: "Under the name on the briefing deck's email page: when the inbox was sorted")
    }
}
