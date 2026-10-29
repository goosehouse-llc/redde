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

    #if DEBUG
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
        AgentBriefing.snooze(briefing.id, until: until)
        LaterReminder.briefing(briefing, at: until)
        reload()
    }

    func show(_ briefing: AgentBriefing) {
        AgentBriefing.markRead(briefing.id)
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

    func remove(_ briefing: AgentBriefing) {
        AgentBriefing.remove(briefing.id)
        LaterReminder.cancel(briefing.id)
        reload()
    }
}

extension AgentBriefing {
    var symbol: String {
        if isHeadsUp { return "bell.badge" }
        if title == EveningWrapUp.title { return "moon.stars" }
        return "doc.text"
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
    @State private var noted = 0
    @Environment(\.theme) private var theme

    /// "Read" as a thing to do (open it to read), not "Read" as done, which the catalog's own is.
    private var readIt: String {
        String(localized: "action.read", defaultValue: "Read", comment: "Button and swipe stamp: opens a briefing (or an earlier chat) to read it. A verb, not 'has been read'.")
    }

    var body: some View {
        if !inbox.unread.isEmpty {
            Section {
                SwipeDeck(
                    items: inbox.unread,
                    height: 214,
                    right: .init(stamp: readIt, color: .green, act: { inbox.show($0) }),
                    left: .init(stamp: String(localized: "Done"), color: .blue, act: { inbox.markRead($0) }),
                    buttons: [.init(symbol: "checkmark", label: String(localized: "Done"), color: .blue, fly: -1, act: { inbox.markRead($0) }),
                              .init(symbol: "book.fill", label: readIt, color: .green, size: 64, fly: 1, act: { inbox.show($0) }),
                              .init(symbol: "clock", label: String(localized: "Later"), color: .indigo, fly: -1, act: { inbox.later($0, until: Later.soon()) })],
                    tap: { inbox.show($0) },
                    face: { briefing, isTop, moved in
                        BriefingCard(briefing: briefing, isTop: isTop, moved: moved).deckCard(DeckCard.face(profile: briefing.profile), theme: theme)
                    },
                    menu: { BriefingMenu(briefing: $0, noted: { noted += 1 }) },
                    footer: {
                        HStack(spacing: 6) {
                            if inbox.unread.count > 1 {
                                Text("\(1) of \(inbox.unread.count) · Tap to read, hold for more").monospacedDigit()
                            } else {
                                Text("Tap to read, hold for more")
                            }
                            if inbox.briefings.count > 1 {
                                Text(verbatim: "·")
                                Button("All Briefings") { inbox.showingAll = true }.buttonStyle(.borderless)
                            }
                        }
                    })
                .sensoryFeedback(.success, trigger: noted)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } header: {
                Text("Briefings")
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

    var body: some View {
        let week = briefing.week
        VStack(alignment: .leading, spacing: 8) {
            DeckCardHeader(face: DeckCard.face(profile: briefing.profile), name: briefing.agent, subtitle: subtitle,
                           symbol: briefing.failed ? "exclamationmark.triangle.fill" : briefing.cardSymbol,
                           symbolColor: briefing.failed ? .red : .yellow, isTop: isTop, moved: moved, bounce: briefing.id)
            Text(briefing.heading)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            if let week {
                if !week.intro.isEmpty { Text(week.intro).font(.subheadline).opacity(0.75).lineLimit(2) }
                Spacer(minLength: 0)
                WeekStrip(plan: week)
            } else {
                if let starts = briefing.eventAt {
                    Label {
                        Text(briefing.leaveAt.map { "\(starts.formatted(date: .omitted, time: .shortened)) · " + String(localized: "Leave by \($0.formatted(date: .omitted, time: .shortened))") }
                             ?? starts.formatted(date: .omitted, time: .shortened))
                    } icon: { Image(systemName: "clock") }
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                if let found = briefing.mapPlace {
                    Label(found.address, systemImage: "mappin.and.ellipse").font(.footnote.weight(.medium)).lineLimit(1)
                }
                Text(PlainText.display(briefing.text)).font(.subheadline).opacity(0.75)
                    .lineLimit(briefing.eventAt == nil && briefing.mapPlace == nil ? 4 : 2)
                Spacer(minLength: 0)
            }
        }
    }

    private var subtitle: Text {
        let when = briefing.at.formatted(date: .omitted, time: .shortened)
        if briefing.isHeadsUp { return Text("heads-up · \(when)", comment: "Under an agent's name on a heads-up's card") }
        if briefing.week != nil || briefing.title == WeekAhead.title { return Text("your week ahead · \(when)", comment: "Under an agent's name on the Week Ahead's card") }
        if briefing.title == EveningWrapUp.title { return Text("your wrap-up · \(when)", comment: "Under an agent's name on the Evening Wrap-up's card") }
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
                    Text(day.weekday).font(.system(size: 10, weight: .bold)).opacity(0.65)
                    Text(day.number ?? "·").font(.system(.headline, design: .rounded, weight: .bold)).monospacedDigit()
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
                Text(plan.intro).font(.headline)
            }
            VStack(spacing: 0) {
                ForEach(Array(plan.days.enumerated()), id: \.element.id) { i, day in
                    if i > 0 { Divider().padding(.leading, 64) }
                    row(day)
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 16))
            if !plan.after.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(plan.after, id: \.self) { line in
                        Label(line, systemImage: "checklist").font(.subheadline)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    private func row(_ day: WeekPlan.Day) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Text(day.weekday).font(.caption.weight(.bold)).foregroundStyle(.tint)
                Text(day.number ?? "").font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
            }
            .frame(width: 40)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(day.title)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(day.notes, id: \.self) { note in
                    Text(note).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                }
                ForEach(Array(day.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.time ?? "").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 74, alignment: .leading)
                        Text(item.what).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
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
        if let place = place?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
            return AddressMaps.Found(name: name ?? place, address: place)
        }
        guard var found = AddressMaps.first(in: text) else { return nil }
        if let name { found.name = name }
        return found
    }

    /// A card's symbol, filled.
    var cardSymbol: String {
        if isHeadsUp { return "bell.badge.fill" }
        if title == EveningWrapUp.title { return "moon.stars.fill" }
        if title == WeekAhead.title { return "calendar" }
        return "doc.text.fill"
    }
}

struct BriefingRow: View {
    let briefing: AgentBriefing
    var lines = 3

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: briefing.symbol)
                .font(.title3)
                .foregroundStyle(briefing.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(briefing.heading).font(.body.weight(briefing.read ? .regular : .semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(briefing.at, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(PlainText.display(briefing.text)).font(.subheadline).foregroundStyle(.secondary).lineLimit(lines)
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
                    .font(.subheadline).foregroundStyle(.secondary)
                    if let week = briefing.week {
                        WeekCalendarView(plan: week)
                    } else {
                        MarkdownView(text: briefing.text, selectable: true)
                        if let found = briefing.mapPlace { AddressMapCard(found: found) }
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
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(inbox.briefings) { briefing in
                    Button { inbox.markRead(briefing); open = briefing } label: { BriefingRow(briefing: briefing, lines: 2) }
                        .buttonStyle(.plain)
                        .swipeActions { Button("Delete", systemImage: "trash", role: .destructive) { inbox.remove(briefing) } }
                        .contextMenu { BriefingMenu(briefing: briefing) }
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
