import SwiftUI

/// The briefings on this phone (`AgentBriefing`), for the chat list: read again when Redde comes to
/// the front and when one arrives with it open; opened from a briefing's notification.
@MainActor
@Observable
final class BriefingsInbox {
    static let shared = BriefingsInbox()
    private(set) var briefings: [AgentBriefing] = []
    /// The one open over the chat list, or all of them (`showingAll`).
    var open: AgentBriefing?
    var showingAll = false

    init() {
        #if DEBUG
        // `-echo.demoDay`: the day's video's, by its scene (`DemoDay`).
        if DemoDay.on {
            briefings = DemoDay.briefings
            return
        }
        // `-echo.demoBriefings`: a wrap-up and a heads-up, for screenshots.
        if DevHooks.has("-echo.demoBriefings") {
            briefings = [
                AgentBriefing(id: "demo/2", title: "Week ahead", agent: "Sol",
                              text: "A heavy Friday, then a quiet weekend.\n\n## Friday, Oct 30\n> Payday\n- 9:00 AM Morning blocks\n- 11:30 AM Planning session\n- 12:30 PM DataOps stand-up\n- 5:00 PM Architecture committee\n\n## Saturday, Oct 31\n- Halloween\n\n## Sunday, Nov 1\n> Clocks go back\n- 1:00 PM Vikings vs. Lions\n\n## Monday, Nov 2\n- 10:00 AM Dentist\n- 2:00 PM Quarterly review\n\n## Wednesday, Nov 4\n- 7:00 PM Dinner at Lucia's\n\nGet ready: costumes for Saturday night",
                              at: .now.addingTimeInterval(-120), failed: false),
                AgentBriefing(id: "demo/1", title: "Heads-up: Dentist", agent: "Sol",
                              text: "At Dr. Lee's on Main St in 30 minutes. Bring your insurance card; parking is behind the building.",
                              at: .now.addingTimeInterval(-300), failed: false),
                AgentBriefing(id: "demo/0", title: "Evening wrap-up", agent: "Sol",
                              text: "**Done:** the vet booked for Thursday, the PR merged.\n\n**Waiting on you:** one approval from Coder.\n\n**Tomorrow:** call the plumber; it comes back as an idea at 9.",
                              at: .now.addingTimeInterval(-3600 * 14), failed: false)]
            // `-echo.demoBriefings day`: a daily brief first, as an agent's own job writes one,
            // narration and all (`DayBrief`); its calendar from its own rows, never the phone's.
            if DevHooks.value("-echo.demoBriefings") == "day" { briefings.insert(Self.demoDayBrief, at: 0) }
            // `-echo.openBriefing`: the first one open, a moment after launch.
            if DevHooks.has("-echo.openBriefing") {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    self?.open = self?.briefings.first
                }
            }
            return
        }
        #endif
        briefings = Self.showing()
        wakeForNextBack()
    }

    /// The ones not put off, newest first, one back from Later as if it had just come.
    private static func showing() -> [AgentBriefing] {
        AgentBriefing.all().filter { $0.showing() }.sorted { $0.shownAt > $1.shownAt }
    }

    private var waking: Task<Void, Never>?

    /// With Redde open, one put off comes back when its time comes.
    private func wakeForNextBack() {
        waking?.cancel()
        guard let back = AgentBriefing.nextBack() else { return }
        waking = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, back.timeIntervalSinceNow + 1)))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    var unread: [AgentBriefing] { briefings.filter { !$0.read } }

    /// The deck: each job once, its newest run not read yet, less the ones over (2026-11-05).
    var deck: [AgentBriefing] { AgentBriefing.deck(briefings).map(\.briefing) }
    /// How many earlier runs of each card's job are unread under it, by the card's id.
    var earlierUnread: [String: Int] {
        Dictionary(AgentBriefing.deck(briefings).map { ($0.briefing.id, $0.earlier) }, uniquingKeysWith: { a, _ in a })
    }

    /// The same job's other runs kept here, newest first.
    func earlier(than briefing: AgentBriefing) -> [AgentBriefing] {
        AgentBriefing.all().filter { $0.jobKey == briefing.jobKey && $0.id != briefing.id && $0.at <= briefing.at }
            .sorted { $0.at > $1.at }
    }

    /// The list's rows: each job once, its newest run, with how many it has.
    var byJob: [(briefing: AgentBriefing, runs: Int)] {
        var at: [String: Int] = [:]
        var out: [(briefing: AgentBriefing, runs: Int)] = []
        for briefing in briefings {
            if let i = at[briefing.jobKey] { out[i].runs += 1 } else { at[briefing.jobKey] = out.count; out.append((briefing, 1)) }
        }
        return out
    }

    /// How this job's runs reach the person, and the plugin told of a hidden one.
    func notice(_ briefing: AgentBriefing) -> JobNotices.Choice { JobNotices.choice(for: briefing.jobKey) }

    func setNotice(_ choice: JobNotices.Choice, for briefing: AgentBriefing) {
        JobNotices.set(choice, for: briefing.jobKey, title: briefing.heading)
        if choice == .hidden { AgentBriefing.markJobRead(briefing.jobKey) }
        Mutes.publish()
        reload()
    }

    /// A hidden job shown again (the list's Hidden Jobs).
    func showAgain(_ jobKey: String) {
        JobNotices.set(.notify, for: jobKey, title: "")
        Mutes.publish()
        reload()
    }

    #if DEBUG
    /// A made-up daily brief for today, in the shape the first real one came in: the model's
    /// working line, a rule, then tables, one event in two of them.
    static var demoDayBrief: AgentBriefing {
        let today = Date.now.formatted(Date.FormatStyle(locale: Locale(identifier: "en_US")).weekday(.wide).month(.wide).day().year())
        let text = """
            No place or video link on the Climbing event. Now let me put together the morning meeting brief.

            ---

            ## Morning Meeting Brief — \(today)

            ### Meetings from 9:00 AM onwards:

            | Time | Title | Attendees | Zoom Link |
            |---|---|---|---|
            | All day | Priya out of office (through Nov 3) | 3 | — |
            | All day | Halloween | — | — |
            | 9:30 – 10:00 | Design sync | 4 | [Join](https://zoom.us/j/5550100200) |
            | 10:00 – 11:00 | Climbing gym | — | — |
            | 1:00 – 1:45 PM | Lunch with Dana | 2 | — |

            **Scheduling conflicts:** None. The design sync ends as climbing starts.

            ### Zoom Links

            | Time | Title | Zoom Link |
            |---|---|---|
            | 9:30 – 10:00 | Design sync | [Join](https://zoom.us/j/5550100200) |

            Have a good weekend.
            """
        var briefing = AgentBriefing(id: "demo/day", title: "Daily meeting brief", agent: "Sol", text: text,
                                     at: Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: .now) ?? .now, failed: false)
        briefing.profile = "default"
        return briefing
    }

    /// `-echo.demoDay morning`: a heads-up arriving, as one does with Redde open.
    func arriveForDemo(_ briefing: AgentBriefing) {
        withAnimation(.snappy) { briefings.insert(briefing, at: 0) }
    }
    #endif

    func reload() {
        #if DEBUG
        if DevHooks.has("-echo.demoBriefings") || DemoDay.on { return }
        #endif
        let now = Self.showing()
        if now != briefings { withAnimation(.snappy) { briefings = now } }
        wakeForNextBack()
    }

    /// Put off until `until`: out of the list, back unread then, with a quiet notification.
    func later(_ briefing: AgentBriefing, until: Date) {
        if open?.id == briefing.id { open = nil }
        #if DEBUG
        if DevHooks.has("-echo.demoBriefings") || DemoDay.on { briefings.removeAll { $0.id == briefing.id }; return }
        #endif
        // The job's earlier runs go with it: the card comes back as one.
        for run in earlier(than: briefing) where !run.read { AgentBriefing.markRead(run.id) }
        AgentBriefing.snooze(briefing.id, until: until)
        LaterReminder.briefing(briefing, at: until)
        reload()
    }

    func show(_ briefing: AgentBriefing) {
        AgentBriefing.markRead(briefing.id)
        AgentBriefing.markJobRead(briefing.jobKey)   // (its earlier runs are in its sheet)
        reload()
        open = briefings.first { $0.id == briefing.id } ?? briefing
    }

    /// A briefing's notification, tapped: the newest one, opened.
    func showNewest() {
        reload()
        if let newest = briefings.first { show(newest) } else { showingAll = true }
    }

    func markRead(_ briefing: AgentBriefing) {
        AgentBriefing.markRead(briefing.id)
        reload()
    }

    /// Done with a card: every run of its job read.
    func markJobRead(_ briefing: AgentBriefing) {
        AgentBriefing.markJobRead(briefing.jobKey)
        reload()
    }

    func remove(_ briefing: AgentBriefing) {
        AgentBriefing.remove(briefing.id)
        LaterReminder.cancel(briefing.id)
        reload()
    }

    /// Every run of a job, gone (the list's Delete on a job's row).
    func removeJob(_ briefing: AgentBriefing) {
        for run in AgentBriefing.all() where run.jobKey == briefing.jobKey {
            AgentBriefing.remove(run.id)
            LaterReminder.cancel(run.id)
        }
        reload()
    }
}

extension AgentBriefing {
    var symbol: String {
        if isHeadsUp { return "bell.badge" }
        if title == EveningWrapUp.title { return "moon.stars" }
        if dayBrief != nil { return "calendar" }
        return "doc.text"
    }

    /// About the person's day (Today in the deck): a heads-up, a daily brief, the wrap-up, the week
    /// ahead, or a job named for a day's look; anything else (a check, a monitor, a goal's) is
    /// one of the Updates (2026-11-05).
    var isAboutTheDay: Bool {
        if isHeadsUp || dayBrief != nil || week != nil || [EveningWrapUp.title, WeekAhead.title].contains(title) { return true }
        let words = Set(title.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        return !words.isDisjoint(with: ["brief", "briefing", "morning", "evening", "daily", "today", "tonight", "agenda", "wrap", "schedule", "calendar"])
    }

    /// What the person's word on it is about, for the jobs that make them (`AgentFeedback`): a
    /// heads-up's event, or the wrap-up and the week ahead; nil for another job's answer.
    var feedback: (topic: AgentFeedback.Topic, title: String)? {
        if isHeadsUp { return (.headsUp, heading) }
        if [EveningWrapUp.title, WeekAhead.title].contains(title) { return (.briefing, title) }
        return nil
    }
}

/// A briefing held, or its sheet's menu: Later, and the person's word on it.
struct BriefingMenu: View {
    let briefing: AgentBriefing
    var noted: () -> Void = {}
    @State private var inbox = BriefingsInbox.shared

    var body: some View {
        Section {
            Picker(selection: Binding(get: { inbox.notice(briefing) }, set: { inbox.setNotice($0, for: briefing); noted() })) {
                Label("Notify Me", systemImage: "bell").tag(JobNotices.Choice.notify)
                Label("Drawer Only", systemImage: "tray").tag(JobNotices.Choice.drawerOnly)
                Label("Don't Show", systemImage: "eye.slash").tag(JobNotices.Choice.hidden)
            } label: {
                Label { Text("Notifications", comment: "A briefing's menu: how this job's runs reach the person (Notify Me, Drawer Only, Don't Show)") } icon: { Image(systemName: "bell.badge") }
            }
            .pickerStyle(.menu)
        }
        Section("Later") {
            ForEach(Later.choices(), id: \.0) { choice, when in
                Button { inbox.later(briefing, until: when) } label: { Label { Text(choice.label) } icon: { Image(systemName: choice.symbol) } }
            }
        }
        if let feedback = briefing.feedback {
            Section("Tell Your Agent") {
                let (yes, no): (LocalizedStringKey, LocalizedStringKey) = feedback.topic == .headsUp
                    ? ("More Like This", "Fewer Like This") : ("Useful", "Not Useful")
                Button(yes, systemImage: "hand.thumbsup") {
                    FeedbackFold.said(feedback.topic, title: feedback.title, agent: briefing.agent, liked: true); noted()
                }
                Button(no, systemImage: "hand.thumbsdown") {
                    FeedbackFold.said(feedback.topic, title: feedback.title, agent: briefing.agent, liked: false); noted()
                }
            }
        }
    }
}

/// "Briefings", at the top of the chat list under the ideas: the ones not read yet, as a deck like
/// the ideas' (asked 2026-10-29). A tap or a swipe right opens the whole of one; left, or Done, and
/// it is read. Read, they leave the deck and stay in All Briefings.
struct BriefingsSection: View {
    @State private var inbox = BriefingsInbox.shared
    @State private var mail = MailCenter.shared
    @State private var noted = 0
    /// Bumped when the email page is put away, so the deck reads again.
    @State private var mailDone = 0
    @AppStorage(ChatListCard.briefings.foldKey) private var isOpen = true
    @Environment(\.theme) private var theme

    /// Today or Updates (2026-11-05), when there are both.
    @State private var showing: Shelf = .today
    enum Shelf: Hashable { case today, updates }

    /// The briefings not read yet, each job once, with the email page first while something waits
    /// on him (2.4), in Today.
    private var all: (today: [AgentBriefing], updates: [AgentBriefing]) {
        _ = mailDone
        let cards = inbox.deck
        return ((MailBriefPage.item(mail.brief).map { [$0] } ?? []) + cards.filter(\.isAboutTheDay), cards.filter { !$0.isAboutTheDay })
    }

    private var deck: [AgentBriefing] {
        let all = all
        if all.today.isEmpty { return all.updates }
        if all.updates.isEmpty { return all.today }
        return showing == .today ? all.today : all.updates
    }

    private func read(_ briefing: AgentBriefing) {
        if MailBriefPage.isMail(briefing) { MailBriefPage.open(); mailDone += 1 } else { inbox.show(briefing) }
    }

    private func done(_ briefing: AgentBriefing) {
        if MailBriefPage.isMail(briefing) { MailBriefPage.done(); mailDone += 1 } else { inbox.markJobRead(briefing) }
    }

    private func later(_ briefing: AgentBriefing) {
        if MailBriefPage.isMail(briefing) { MailBriefPage.done(); mailDone += 1 } else { inbox.later(briefing, until: Later.soon()) }
    }

    /// "Read" as a thing to do (open it to read), not "Read" as done, which the catalog's own is.
    private var readIt: String {
        String(localized: "action.read", defaultValue: "Read", comment: "Button and swipe stamp: opens a briefing (or an earlier chat) to read it. A verb, not 'has been read'.")
    }

    var body: some View {
        let deck = deck
        let all = all
        let earlier = inbox.earlierUnread
        if !deck.isEmpty {
            Section {
                if isOpen {
                if !all.today.isEmpty, !all.updates.isEmpty {
                    Picker("Briefings", selection: $showing) {
                        Text("Today · \(all.today.count)", comment: "The briefings deck's tab for the day's (heads-ups, daily brief, wrap-up), with how many").tag(Shelf.today)
                        Text("Updates · \(all.updates.count)", comment: "The briefings deck's tab for other jobs' answers (checks, monitors), with how many").tag(Shelf.updates)
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                SwipeDeck(
                    items: deck,
                    height: 214,
                    right: .init(stamp: readIt, color: .green, act: { read($0) }),
                    left: .init(stamp: String(localized: "Done"), color: .blue, act: { done($0) }),
                    buttons: [.init(symbol: "checkmark", label: String(localized: "Done"), color: .blue, fly: -1, act: { done($0) }),
                              .init(symbol: "book.fill", label: readIt, color: .green, size: 64, fly: 1, act: { read($0) }),
                              .init(symbol: "clock", label: String(localized: "Later"), color: .indigo, fly: -1, act: { later($0) })],
                    tap: { read($0) },
                    face: { briefing, isTop, moved in
                        if MailBriefPage.isMail(briefing), let brief = mail.brief {
                            MailBriefCard(brief: brief, isTop: isTop, moved: moved).deckCard(DeckCard.face(profile: "default"), theme: theme)
                        } else {
                            BriefingCard(briefing: briefing, isTop: isTop, moved: moved, earlier: earlier[briefing.id] ?? 0)
                                .deckCard(DeckCard.face(profile: briefing.profile), theme: theme)
                        }
                    },
                    menu: { briefing in
                        if !MailBriefPage.isMail(briefing) { BriefingMenu(briefing: briefing, noted: { noted += 1 }) }
                    },
                    footer: {
                        HStack(spacing: 6) {
                            if deck.count > 1 {
                                Text("\(1) of \(deck.count) · Tap to read, hold for more").monospacedDigit()
                            } else {
                                Text("Tap to read, hold for more")
                            }
                            if inbox.briefings.count > 1 {
                                Text(verbatim: "·")
                                Button("All Briefings") { inbox.showingAll = true }.buttonStyle(.borderless)
                            }
                        }
                    })
                .id(all.today.isEmpty || all.updates.isEmpty ? nil : showing)
                .sensoryFeedback(.success, trigger: noted)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                }
            } header: {
                FoldingHeader(title: ChatListCard.briefings.title, count: all.today.count + all.updates.count, isOpen: $isOpen)
            }
        }
    }
}

/// A briefing on its card: the week ahead as a strip of days, a heads-up's when and where, any
/// other's first lines.
struct BriefingCard: View {
    let briefing: AgentBriefing
    var isTop = true
    var moved: CGFloat = 0
    /// Earlier runs of its job not read yet, under it (2026-11-05).
    var earlier = 0

    var body: some View {
        let week = briefing.week
        VStack(alignment: .leading, spacing: 8) {
            DeckCardHeader(face: DeckCard.face(profile: briefing.profile), name: briefing.agent, subtitle: subtitle,
                           symbol: briefing.failed ? "exclamationmark.triangle.fill" : briefing.cardSymbol,
                           symbolColor: briefing.failed ? .red : .yellow, isTop: isTop, moved: moved, bounce: briefing.id)
            Text(briefing.heading)
                .chatFont(.title3, weight: .bold, design: .rounded)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            if let week {
                if !week.intro.isEmpty { Text(week.intro).chatFont(.subheadline).opacity(0.75).lineLimit(2) }
                Spacer(minLength: 0)
                WeekStrip(plan: week)
            } else if let day = briefing.dayBrief {
                Spacer(minLength: 0)
                DayStrip(brief: day)
            } else {
                if let starts = briefing.startsAt {
                    Label {
                        Text(briefing.leaveAt.map { "\(starts.formatted(date: .omitted, time: .shortened)) · " + String(localized: "Leave by \($0.formatted(date: .omitted, time: .shortened))") }
                             ?? starts.formatted(date: .omitted, time: .shortened))
                    } icon: { Image(systemName: "clock") }
                    .chatFont(.subheadline, weight: .semibold).lineLimit(1)
                }
                if let found = briefing.mapPlace {
                    Label(found.address, systemImage: "mappin.and.ellipse").chatFont(.footnote, weight: .medium).lineLimit(1)
                }
                Text(briefing.plainText).chatFont(.subheadline).opacity(0.75)
                    .lineLimit(briefing.startsAt == nil && briefing.mapPlace == nil ? 4 : 2)
                Spacer(minLength: 0)
            }
        }
    }

    private var subtitle: Text {
        guard earlier > 0 else { return kind }
        return Text("\(kind) · \(earlier) earlier", comment: "On a briefing's card: what it is and when, then how many earlier runs of the same job wait under it (\"briefing · 9:00 AM · 2 earlier\")")
    }

    private var kind: Text {
        let when = briefing.at.formatted(date: .omitted, time: .shortened)
        if briefing.isHeadsUp { return Text("heads-up · \(when)", comment: "Under an agent's name on a heads-up's card") }
        if briefing.week != nil || briefing.title == WeekAhead.title { return Text("your week ahead · \(when)", comment: "Under an agent's name on the Week Ahead's card") }
        if briefing.title == EveningWrapUp.title { return Text("your wrap-up · \(when)", comment: "Under an agent's name on the Evening Wrap-up's card") }
        if briefing.dayBrief != nil { return Text("your day · \(when)", comment: "Under an agent's name on a daily brief's card, one about a day's calendar (\"your day · 7:00 AM\")") }
        return Text("briefing · \(when)", comment: "Under an agent's name on a briefing's card")
    }
}

/// The week on a card: a column a day, its weekday, its date and a dot for each thing on it.
struct WeekStrip: View {
    let plan: WeekPlan

    var body: some View {
        HStack(spacing: 4) {
            ForEach(plan.days.prefix(7)) { day in
                VStack(spacing: 2) {
                    Text(day.weekday).chatFont(size: 10, weight: .bold).opacity(0.65)
                    Text(day.number ?? "·").chatFont(.headline, weight: .bold, design: .rounded).monospacedDigit()
                    HStack(spacing: 2) {
                        ForEach(0..<min(day.items.count, 4), id: \.self) { _ in Circle().frame(width: 4, height: 4) }
                    }
                    .frame(height: 5)
                    .opacity(0.55)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.white.opacity(day.items.count >= 4 ? 0.7 : 0.4), in: .rect(cornerRadius: 10))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(plan.days.map(\.title).joined(separator: ", "))
    }
}

/// The week ahead, whole, as a calendar: a row a day, its date in a badge, what's on it by time.
struct WeekCalendarView: View {
    let plan: WeekPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !plan.intro.isEmpty {
                Text(plan.intro).chatFont(.headline)
            }
            VStack(spacing: 0) {
                // By place, as the lists below (UAT 2.3.1, 2026-10-31): an agent can write a day, a note or a line twice.
                ForEach(Array(plan.days.enumerated()), id: \.offset) { i, day in
                    if i > 0 { Divider().padding(.leading, 64) }
                    row(day)
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 16))
            if !plan.after.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(plan.after.enumerated()), id: \.offset) { _, line in
                        Label(line, systemImage: "checklist").chatFont(.subheadline)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    private func row(_ day: WeekPlan.Day) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Text(day.weekday).chatFont(.caption, weight: .bold).foregroundStyle(.tint)
                Text(day.number ?? "").chatFont(.title2, weight: .semibold, design: .rounded).monospacedDigit()
            }
            .frame(width: 40)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(day.title)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(day.notes.enumerated()), id: \.offset) { _, note in
                    Text(note).chatFont(.footnote, weight: .medium).foregroundStyle(.secondary)
                }
                ForEach(Array(day.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.time ?? "").chatFont(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 74, alignment: .leading)
                        Text(item.what).chatFont(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(12)
    }
}

extension AgentBriefing {
    /// The week ahead as a calendar, when it reads as one: read once, not at each frame of a drag.
    var week: WeekPlan? {
        guard title == WeekAhead.title else { return nil }
        if let kept = Self.weeks[id], kept.text == text { return kept.plan }
        let plan = WeekPlan.parse(text)
        Self.weeks[id] = (text, plan)
        return plan
    }

    private static var weeks: [String: (text: String, plan: WeekPlan?)] = [:]

    /// Where a briefing's map is (`AddressMaps`): a heads-up's place as the plugin sent it, else
    /// the first street address in its words; none for the week ahead, or with maps turned off.
    var mapPlace: AddressMaps.Found? {
        guard Settings.shared.addressMaps, title != WeekAhead.title else { return nil }
        let name = isHeadsUp ? heading : nil
        // The event's place only when it's an address: a room or a meeting link gets no map.
        if let place = place?.trimmingCharacters(in: .whitespacesAndNewlines), EventPlace.isAddress(place) {
            return AddressMaps.Found(name: name ?? place, address: place)
        }
        if isHeadsUp, place?.isEmpty == false { return nil }
        guard var found = AddressMaps.first(in: text) else { return nil }
        if let name { found.name = name }
        return found
    }

    /// A card's symbol, filled.
    var cardSymbol: String {
        if isHeadsUp { return "bell.badge.fill" }
        if title == EveningWrapUp.title { return "moon.stars.fill" }
        if title == WeekAhead.title || dayBrief != nil { return "calendar" }
        return "doc.text.fill"
    }
}

struct BriefingRow: View {
    let briefing: AgentBriefing
    var lines = 3
    /// How many runs of its job are kept (the list's), and whether they come to the drawer only.
    var runs = 1
    var quiet = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: briefing.symbol)
                .chatFont(.title3)
                .foregroundStyle(briefing.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(briefing.heading).chatFont(.body, weight: briefing.read ? .regular : .semibold).lineLimit(1)
                    if quiet { Image(systemName: "tray").chatFont(.caption).foregroundStyle(.secondary).accessibilityLabel(Text("Drawer only")) }
                    if runs > 1 {
                        Text(verbatim: "\(runs)").chatFont(.caption2, weight: .semibold).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: .capsule)
                            .accessibilityLabel(Text("\(runs) runs", comment: "All Briefings: how many runs of a job are kept"))
                    }
                    Spacer(minLength: 6)
                    Text(briefing.at, format: .dateTime.hour().minute()).chatFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(briefing.plainText).chatFont(.subheadline).foregroundStyle(.secondary).lineLimit(lines)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }
}

/// One briefing, whole.
struct BriefingSheet: View {
    let briefing: AgentBriefing
    @Environment(\.dismiss) private var dismiss
    @State private var noted = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label {
                        let when = briefing.at.formatted(.dateTime.weekday().hour().minute())
                        Text(briefing.agent.isEmpty ? when : "\(briefing.agent) · \(when)")
                    } icon: {
                        Image(systemName: briefing.symbol)
                    }
                    .chatFont(.subheadline).foregroundStyle(.secondary)
                    if let week = briefing.week {
                        WeekCalendarView(plan: week)
                    } else {
                        if let day = briefing.dayBrief { DayBriefAgenda(brief: day) }
                        if let starts = briefing.startsAt { EventCard(briefing: briefing, starts: starts) }
                        // Under the day's card, only what it doesn't show already.
                        let words = briefing.dayBrief == nil ? briefing.shownText : DayBrief.withoutSchedule(briefing.shownText)
                        if !words.isEmpty { MarkdownView(text: words, selectable: true) }
                        if let found = briefing.mapPlace { AddressMapCard(found: found) }
                    }
                    let earlier = BriefingsInbox.shared.earlier(than: briefing)
                    if !earlier.isEmpty {
                        Text("Earlier", comment: "In a briefing's sheet: the same job's earlier runs, under the newest").chatFont(.headline).padding(.top, 8)
                        ForEach(earlier) { run in
                            DisclosureGroup {
                                MarkdownView(text: run.shownText, selectable: true).padding(.top, 4)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(run.at.formatted(.dateTime.weekday().hour().minute())).chatFont(.subheadline, weight: .semibold)
                                    Text(run.plainText).chatFont(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(briefing.heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = briefing.text }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        BriefingMenu(briefing: briefing, noted: { noted += 1 })
                    } label: {
                        Label("Later, or Tell Your Agent", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sensoryFeedback(.success, trigger: noted)
        }
    }
}

/// All the briefings on this phone, the last week's: in a sheet over the chat list, or in Settings.
struct BriefingsListView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BriefingsList()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct BriefingsList: View {
    @State private var inbox = BriefingsInbox.shared
    @State private var open: AgentBriefing?

    var body: some View {
            List {
                if inbox.briefings.isEmpty {
                    Text("Your agent's briefings come here: the Evening Wrap-up, heads-ups before events, and any daily brief you ask it for. Set them up in Settings, Agent.")
                        .chatFont(.footnote).foregroundStyle(.secondary)
                }
                // Each job once, its newest run; the earlier ones in its sheet (2026-11-05).
                ForEach(inbox.byJob, id: \.briefing.id) { briefing, runs in
                    Button { inbox.markJobRead(briefing); open = briefing } label: { BriefingRow(briefing: briefing, lines: 2, runs: runs, quiet: inbox.notice(briefing) == .drawerOnly) }
                        .buttonStyle(.plain)
                        .swipeActions { Button("Delete", systemImage: "trash", role: .destructive) { inbox.removeJob(briefing) } }
                        .contextMenu { BriefingMenu(briefing: briefing) }
                }
                let hidden = JobNotices.hidden().sorted { $0.value.title < $1.value.title }
                if !hidden.isEmpty {
                    Section {
                        ForEach(hidden, id: \.key) { key, entry in
                            HStack {
                                Text(entry.title.isEmpty ? String(localized: "A scheduled job") : entry.title).lineLimit(1)
                                Spacer()
                                Button("Show Again") { inbox.showAgain(key) }.buttonStyle(.borderless)
                            }
                        }
                    } header: {
                        Text("Hidden Jobs", comment: "All Briefings: jobs whose runs the person chose Don't Show for")
                    } footer: {
                        Text("Their runs aren't kept or shown, and your Hermes is asked not to send them.")
                    }
                }
            }
            .navigationTitle("Briefings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $open) { BriefingSheet(briefing: $0) }
            .onAppear { inbox.reload() }
    }
}

/// The briefing sheets over the chat list.
struct BriefingSheets: ViewModifier {
    @State private var inbox = BriefingsInbox.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { inbox.showingAll ? nil : inbox.open }, set: { inbox.open = $0 })) { BriefingSheet(briefing: $0) }
            .sheet(isPresented: $inbox.showingAll) { BriefingsListView() }
    }
}
