import SwiftUI
#if os(iOS)
import EventKit
import EventKitUI
#endif

/// What's on the calendar, under the reply that read it (`ReplyCard.agenda`, asked 2026-10-29),
/// drawn as a day timeline (the "Calendar A" design, approved 2026-10-30): each day headed by a
/// Calendar-style date badge, its name and how full it is; all-day events above an hour rail; each
/// event a block in its calendar's colour, placed and sized by its times, events that overlap side
/// by side, two free hours or more marked, and today a red line at the time. A day asked about with
/// nothing on it says so. Tapping an event opens its details in place: how long, its place (in
/// Maps), which calendar, its notes, and Calendar at its time; a day's header and the button under
/// the card open the day in Calendar. Everything tapped is 44 pt to tap, and says what it does.
///
/// Only the calendars chosen in Settings → Agent → Calendars show (`CalendarChoice`, asked
/// 2026-10-30), and a tap on a free spot of the rail, or on a free stretch, adds an event there
/// (asked 2026-10-30: "tap a spot on the card to add an appointment"): Apple's editor on the iPhone
/// and iPad, a line to finish in the message field on the Mac (`DaySection.add`).
struct AgendaCard: View {
    let card: ReplyCard.Agenda
    /// Each day as drawn, its timeline worked out once for the card, not on every pass of its body.
    private let days: [Day]

    /// `calendars`: the ones to show, by title (Settings' choice); empty for all.
    init(card: ReplyCard.Agenda, calendars: [String] = Settings.shared.agendaCalendars) {
        self.card = card
        days = card.byDay(showing: calendars).map { Day(day: $0.day, events: $0.events, now: Self.now()) }
    }

    /// The clock the card reads: the phone's, or the story's in the day's video (`DemoDay`).
    static func now(_ clock: Date = .now) -> Date {
        #if DEBUG
        if let story = DemoDay.storyNow { return story }
        #endif
        return clock
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if days.count == 1 {
                DaySection(day: days[0], kicker: days[0].near ?? card.title, large: true)
            } else {
                Label(card.title ?? String(localized: "Calendar", comment: "An agenda card's title"), systemImage: "calendar")
                    .chatFont(.subheadline, weight: .semibold)
                    .foregroundStyle(.tint)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    if index > 0 { Divider().opacity(0.6) }
                    DaySection(day: day, kicker: day.near, large: false)
                }
            }
            if let first = days.first, let calendar = Self.calendarURL(for: first) {
                Link(destination: calendar) {
                    Text("Open in Calendar")
                        .chatFont(.subheadline, weight: .semibold)
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(.background.tertiary, in: .capsule)
                        .contentShape(.capsule)
                }
                .accessibilityHint(Self.dayHint)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        // The calendars it names, for Settings → Agent → Calendars to offer.
        .onAppear { CalendarChoice.saw(card.events.compactMap(\.calendar)) }
    }
}

/// One day of the card: its header, its all-day events, its timeline. Which events are open lives
/// here, so a tap redraws its own day only.
private struct DaySection: View {
    typealias Event = ReplyCard.Agenda.Event
    let day: AgendaCard.Day
    /// "Tomorrow" over the date, or the card's own title for a day further off.
    let kicker: String?
    /// The card's one day: the full-size header.
    let large: Bool
    @State private var open: Set<Event> = []
    /// What an open event's block measures with its details, to make room for them.
    @State private var grown: [Event: CGFloat] = [:]
    #if os(iOS)
    /// The new event being added in Apple's editor.
    @State private var adding: AgendaCard.Slot?
    #endif
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !day.allDay.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(day.allDay, id: \.self) { allDay($0) }
                }
            }
            if let timeline = day.timeline {
                rail(timeline)
            }
        }
        #if os(iOS)
        .sheet(item: $adding) { slot in
            NewEventEditor(slot: slot) { adding = nil }
                .ignoresSafeArea()
        }
        #endif
        #if DEBUG
        .task { if let slot = await DevHooks.demoNewEvent(day.timeline) { add(slot) } }
        #endif
    }

    // MARK: Header

    /// The day's badge and name; on the iPhone and iPad a tap opens the day in Calendar (asked
    /// 2026-10-30: "the card must be fully interactive"). Calendar has no such link on the Mac.
    /// With VoiceOver, the day also adds an event, at the next whole hour.
    private var header: some View {
        Group {
            if let calendar = AgendaCard.calendarURL(for: day) {
                Button { openURL(calendar) } label: { title }
                    .buttonStyle(Roomy(extra: 0))
                    .accessibilityHint(AgendaCard.dayHint)
            } else {
                title
            }
        }
        .accessibilityAction(named: Text("Add an event…", comment: "An agenda card's day: the VoiceOver action that adds an event at the next whole hour")) {
            if let date = day.date, let slot = AgendaCard.Slot.nextHour(on: date) { add(slot) }
        }
    }

    private var title: some View {
        HStack(alignment: large ? .top : .center, spacing: large ? 12 : 10) {
            if let date = day.date {
                DayBadge(date: date, large: large)
            }
            VStack(alignment: .leading, spacing: large ? 2 : 1) {
                if let kicker {
                    Text(kicker)
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .chatFont(.caption, weight: .semibold)
                        .foregroundStyle(.tint)
                }
                Text(day.dateLine)
                    .chatFont(large ? .title3 : .subheadline, weight: .bold)
                Text(day.summary)
                    .chatFont(large ? .footnote : .caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: All day

    private func allDay(_ event: Event) -> some View {
        let isOpen = open.contains(event)
        return VStack(alignment: .leading, spacing: 6) {
            Button { toggle(event) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .foregroundStyle(AgendaCard.color(of: event.calendar))
                    Text("All day", comment: "An agenda card: an event without a time")
                        .fontWeight(.semibold)
                    Text(event.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(isOpen ? 4 : 1)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .chatFont(.footnote)
            }
            .buttonStyle(Roomy(extra: 13))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(AgendaCard.spoken(event))
            .accessibilityHint(hint(isOpen))
            if isOpen {
                details(event)
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(.background.tertiary, in: .rect(cornerRadius: 12))
    }

    // MARK: Timeline

    /// The hour rail and what's on it. Plain stacks: each line, block and free stretch is offset
    /// to its place from the timeline worked out with the card, moved down by whatever an open
    /// event above it grew (`Shift`); only the line at the time redraws each minute.
    private func rail(_ timeline: AgendaCard.Timeline) -> some View {
        let shift = AgendaCard.Shift(timeline, grown: grown)
        let height = shift.top(timeline.height)
        return HStack(alignment: .top, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ForEach(Array(zip(timeline.hours, day.hourLabels)), id: \.0) { hour, label in
                    Text(label)
                        .chatFont(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .frame(height: 0)
                        .offset(y: shift.top(timeline.y(ofHour: hour)))
                }
            }
            .frame(minWidth: 32, alignment: .trailing)
            .frame(height: height, alignment: .top)
            ZStack(alignment: .topLeading) {
                ForEach(timeline.ruled, id: \.self) { hour in
                    Rectangle()
                        .fill(.separator)
                        .frame(height: 0.5)
                        .offset(y: shift.top(timeline.y(ofHour: hour)) - 0.25)
                }
                ForEach(Array(timeline.free.enumerated()), id: \.offset) { _, free in
                    let top = shift.top(free.y)
                    Button { if let slot = timeline.slot(for: free) { add(slot) } } label: { FreeStretch(minutes: free.minutes) }
                        .buttonStyle(Roomy(extra: 0))
                        .accessibilityHint(Text("Adds an event at this time", comment: "An agenda card's free stretch, as VoiceOver hints it"))
                        .frame(height: max(0, shift.bottom(free.y + free.height) - top))
                        .offset(y: top)
                }
                ForEach(Array(timeline.clusters.enumerated()), id: \.offset) { _, cluster in
                    columns(cluster, shift: shift)
                }
                if day.isToday {
                    TimelineView(.everyMinute) { context in
                        if let now = timeline.y(of: AgendaCard.now(context.date)) {
                            NowLine().offset(y: shift.top(now))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: height, alignment: .top)
            // A free spot (the events and free stretches are buttons, and take their own taps): a
            // new event there, at the quarter hour nearest the tap.
            .contentShape(.rect)
            .onTapGesture(coordinateSpace: .local) { point in
                if let slot = timeline.slot(atY: shift.unshift(point.y)) { add(slot) }
            }
        }
        .padding(.vertical, 8)
    }

    /// Events that overlap, side by side: a column each, every block offset within it.
    private func columns(_ cluster: AgendaCard.Timeline.Cluster, shift: AgendaCard.Shift) -> some View {
        let frames = cluster.blocks.map { shift.frame(of: $0) }
        let top = frames.map(\.y).min() ?? 0
        let bottom = frames.map { $0.y + $0.height }.max() ?? 0
        return HStack(alignment: .top, spacing: 3) {
            ForEach(0..<cluster.columns, id: \.self) { column in
                ZStack(alignment: .top) {
                    ForEach(Array(cluster.blocks.enumerated()), id: \.offset) { index, block in
                        if block.column == column {
                            self.block(block.event, height: frames[index].height - 2)
                                .offset(y: frames[index].y - top)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(height: bottom - top, alignment: .top)
        .offset(y: top)
    }

    private func block(_ event: Event, height: CGFloat) -> some View {
        let isOpen = open.contains(event)
        let over = (event.end ?? event.start) < AgendaCard.now()
        let color = AgendaCard.color(of: event.calendar)
        let shape = RoundedRectangle(cornerRadius: 10)
        return VStack(alignment: .leading, spacing: 2) {
            Button { toggle(event) } label: {
                Group {
                    if isOpen {
                        lines(event, color: color, notes: false, open: true)
                    } else {
                        // As much as fits its time: with its notes, then its time and place, then one line.
                        ViewThatFits(in: .vertical) {
                            lines(event, color: color, notes: true, open: false)
                            lines(event, color: color, notes: false, open: false)
                            oneLine(event, color: color)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, isOpen || height >= 44 ? 6 : 3)
                // Past: its words dimmed, its colour paler, the block still hiding the lines behind it.
                .opacity(over && !isOpen ? 0.55 : 1)
                .frame(maxWidth: .infinity, minHeight: isOpen ? nil : height, maxHeight: isOpen ? nil : height,
                       alignment: isOpen || height >= 60 ? .topLeading : .leading)
            }
            // A short block is tapped over 44 pt, reaching past its edges.
            .buttonStyle(Roomy(extra: isOpen ? 0 : max(0, (44 - height) / 2)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(AgendaCard.spoken(event))
            .accessibilityHint(hint(isOpen))
            if isOpen {
                details(event)
                    .padding(.leading, 24)
                    .padding(.trailing, 10)
                    .padding(.bottom, 8)
            }
        }
        .modifier(Measured(on: isOpen) { natural in
            guard abs((grown[event] ?? 0) - natural) > 0.5 else { return }
            withAnimation(.snappy(duration: 0.25)) { grown[event] = natural }
        })
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: max(height, 0), alignment: .top)
        .background {
            ZStack {
                shape.fill(.background.secondary)
                shape.fill(color.opacity(over && !isOpen ? 0.09 : 0.18))
                if isOpen { shape.strokeBorder(color.opacity(0.55), lineWidth: 1) }
            }
        }
    }

    /// An event's title by its calendar's dot, its time and place (open, its time alone: the place
    /// is a link under it), and its notes if asked.
    private func lines(_ event: Event, color: AnyShapeStyle, notes: Bool, open: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(event.title)
                    .chatFont(.footnote, weight: .semibold)
                    .lineLimit(open ? 4 : 1)
                    .multilineTextAlignment(.leading)
            }
            Text(open ? AgendaCard.time(event) : AgendaCard.when(event))
                .chatFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(open ? 2 : 1)
            if notes, let note = event.notes {
                Text(note)
                    .chatFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// A short event on one line: its title and when it starts.
    private func oneLine(_ event: Event, color: AnyShapeStyle) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(event.title)
                .chatFont(.footnote, weight: .semibold)
                .lineLimit(1)
            Text(event.start.formatted(date: .omitted, time: .shortened))
                .chatFont(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    /// An open event: how long, where (in Maps), which calendar, its notes, and its links.
    private func details(_ event: Event) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !event.allDay, let end = event.end {
                Label(Duration.seconds(end.timeIntervalSince(event.start)).formatted(.units(allowed: [.hours, .minutes], width: .wide)),
                      systemImage: "clock")
                    .allowsHitTesting(false)
            }
            if let location = event.location, let maps = AgendaCard.mapsURL(location) {
                Button { openURL(maps) } label: {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(Roomy(extra: 14))
                .accessibilityHint(placeHint)
            } else if let location = event.location {
                // A room, a meeting link, an app: no map, its links tappable (asked 2026-10-30).
                Label { Text(EventPlace.linked(location)).textSelection(.enabled) } icon: {
                    Image(systemName: EventDetails.online(in: location) != nil ? "video" : "mappin.and.ellipse")
                }
            }
            if let calendar = event.calendar {
                Label(calendar, systemImage: "calendar")
                    .allowsHitTesting(false)
            }
            if let notes = event.notes {
                Text(EventPlace.linked(notes)).lineLimit(8).textSelection(.enabled)
            }
            // Side by side when they fit; in a narrow column, one under the other.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { links(event, stacked: false) }
                VStack(alignment: .leading, spacing: 0) { links(event, stacked: true) }
            }
            .chatFont(.caption, weight: .semibold)
            .foregroundStyle(.tint)
        }
        .chatFont(.caption)
        .foregroundStyle(.secondary)
        .transition(.opacity)
    }

    /// Open in Maps and Open in Calendar (at the event's time), each 44 pt to tap: side by side
    /// reaching above and below their line, stacked a full 44 pt each.
    @ViewBuilder private func links(_ event: Event, stacked: Bool) -> some View {
        // An online meeting's own link, from its place or its notes: Join.
        if let join = EventDetails.online(in: [event.location, event.notes].compactMap(\.self).joined(separator: "\n"))?.link {
            Button { openURL(join) } label: {
                Label("Join", systemImage: "video.fill").frame(minHeight: stacked ? 44 : nil)
            }
            .buttonStyle(Roomy(extra: stacked ? 0 : 14))
            .accessibilityHint(Text("Opens the meeting's link", comment: "An agenda card's event: its Join button, as VoiceOver hints it"))
        }
        if let location = event.location, let maps = AgendaCard.mapsURL(location) {
            Button { openURL(maps) } label: {
                Label("Open in Maps", systemImage: "map").frame(minHeight: stacked ? 44 : nil)
            }
            .buttonStyle(Roomy(extra: stacked ? 0 : 14))
            .accessibilityHint(placeHint)
        }
        if let calendar = AgendaCard.calendarURL(at: event.start) {
            Button { openURL(calendar) } label: {
                Label("Open in Calendar", systemImage: "calendar").frame(minHeight: stacked ? 44 : nil)
            }
            .buttonStyle(Roomy(extra: stacked ? 0 : 14))
            .accessibilityHint(Text("Opens Calendar at this event's time", comment: "An agenda card's event: its Open in Calendar button, as VoiceOver hints it"))
        }
    }

    private var placeHint: Text {
        Text("Opens the place in Maps", comment: "An agenda card's event: its place and its Open in Maps button, as VoiceOver hints them")
    }

    private func hint(_ isOpen: Bool) -> Text {
        Text(isOpen ? "Hides the details" : "Shows the details", comment: "An agenda card's event, as VoiceOver hints it")
    }

    /// A new event at `slot`: Apple's editor on the iPhone and iPad, which needs no access to the
    /// calendar (from iOS 17 it runs outside Redde when Redde has none, so nothing is asked for); on
    /// the Mac, which has no such editor, a line in the message field for the person to finish.
    private func add(_ slot: AgendaCard.Slot) {
        #if os(iOS)
        adding = slot
        #else
        LaunchRouter.shared.requestDraft(text: AgendaCard.addLine(slot), attachments: [])
        #endif
    }

    private func toggle(_ event: Event) {
        withAnimation(.snappy(duration: 0.25)) {
            if open.remove(event) == nil {
                open.insert(event)
            } else {
                grown[event] = nil
            }
        }
    }
}

/// A plain button tapped over `extra` more above and below than it shows, its layout unchanged:
/// how a short block or a line of caption gets its 44 pt to tap.
private struct Roomy: ButtonStyle {
    let extra: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, extra)
            .contentShape(.rect)
            .padding(.vertical, -extra)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// An open event's natural height, measured to make room for its details; nothing for a closed one.
private struct Measured: ViewModifier {
    let on: Bool
    let changed: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if on {
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { changed($0) }
        } else {
            content
        }
    }
}

/// The date as Calendar's icon shows it: the weekday on a red strip over the day's number.
private struct DayBadge: View {
    let date: Date
    let large: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)))
                .tracking(0.6)
                .textCase(.uppercase)
                .chatFont(size: large ? 10 : 9, weight: .bold)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.vertical, large ? 3 : 2)
                .frame(maxWidth: .infinity)
                .background(.red)
            Text(date.formatted(.dateTime.day()))
                .chatFont(size: large ? 22 : 17, weight: .semibold)
                .monospacedDigit()
                .padding(.vertical, large ? 2 : 1)
        }
        .padding(.bottom, large ? 2 : 1)
        .frame(width: large ? 46 : 38)
        .background(.background.tertiary)
        .clipShape(.rect(cornerRadius: large ? 11 : 9))
        .overlay { RoundedRectangle(cornerRadius: large ? 11 : 9).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) }
        .accessibilityHidden(true)
    }
}

/// Two hours or more with nothing on: a dashed outline that says how long.
private struct FreeStretch: View {
    let minutes: Int

    var body: some View {
        Label(String(localized: "Free for \(AgendaCard.span(minutes: minutes))",
                     comment: "An agenda card: a free stretch between two events (\"Free for 2½ hours\")"),
              systemImage: "plus")
            .chatFont(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.separator, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .accessibilityElement(children: .combine)
    }
}

/// The time, today: a red line across the rail with a dot at its start.
private struct NowLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(.red).frame(width: 7, height: 7)
            Rectangle().fill(.red).frame(height: 1.5)
        }
        .offset(x: -3.5)
        .frame(height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - The day, worked out

extension AgendaCard {
    /// A day as the card draws it, everything in it worked out when the card is made.
    nonisolated struct Day: Identifiable, Sendable {
        typealias Event = ReplyCard.Agenda.Event
        var id: String { day }
        let day: String
        let date: Date?
        /// "Today", "Tomorrow" or "Yesterday"; nothing for a day further off.
        let near: String?
        let isToday: Bool
        /// "Saturday, October 31".
        let dateLine: String
        /// "5 events · 9:00 AM to 8:00 PM", or that there's nothing on.
        let summary: String
        let allDay: [Event]
        let timed: [Event]
        let timeline: Timeline?
        /// The rail's hours as it labels them: "9 AM", "10", "11", "Noon", "1 PM".
        let hourLabels: [String]

        init(day: String, events: [Event], now: Date = .now, calendar: Calendar = .current) {
            self.day = day
            date = AgendaCard.date(of: day, calendar: calendar)
            near = date.flatMap { AgendaCard.nearName($0, now: now, calendar: calendar) }
            isToday = date.map { calendar.isDate($0, inSameDayAs: now) } ?? false
            dateLine = date.map { $0.formatted(.dateTime.weekday(.wide).month(.wide).day()) } ?? day
            allDay = events.filter(\.allDay)
            timed = events.filter { !$0.allDay }.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
            timeline = Timeline.make(events, on: day, calendar: calendar)
            hourLabels = timeline.map { AgendaCard.hourLabels($0.hours, on: $0.dayStart, calendar: calendar) } ?? []
            if events.isEmpty {
                summary = String(localized: "Nothing on your calendar", comment: "An agenda card: a day with no events")
            } else {
                var parts = [String(localized: "\(events.count) events", comment: "An agenda card: how many events a day has (\"5 events\")")]
                if let first = timed.first?.start, let last = timed.map({ $0.end ?? $0.start }).max() {
                    parts.append(last > first ? AgendaCard.span(first, last) : first.formatted(date: .omitted, time: .shortened))
                }
                summary = parts.joined(separator: " · ")
            }
        }
    }

    /// A day's timed events on an hour rail: the rail from the first event's hour to the hour the
    /// last one ends (not the whole day), `hourHeight` a hour; each event a block placed and sized
    /// by its times, never shorter than `shortest`; blocks that would overlap side by side in
    /// columns; and free stretches of `freeAfter` minutes or more. No views in it, so it is worked
    /// out once per card and tested on its own.
    nonisolated struct Timeline: Equatable, Sendable {
        typealias Event = ReplyCard.Agenda.Event
        static let hourHeight: CGFloat = 44
        static let shortest: CGFloat = 30
        static let freeAfter = 120
        /// An event without an end takes this long, in minutes.
        static let untilEnd = 30

        struct Block: Equatable, Sendable {
            var event: Event
            var y: CGFloat
            var height: CGFloat
            var column: Int
        }

        /// Blocks that overlap one another, directly or through others, drawn in `columns` columns.
        struct Cluster: Equatable, Sendable {
            var blocks: [Block]
            var columns: Int
        }

        struct Free: Equatable, Sendable {
            var y: CGFloat
            var height: CGFloat
            var minutes: Int
            /// The clock's minute of the day it starts.
            var start: Int
        }

        var dayStart: Date
        var calendar: Calendar
        var firstHour: Int
        var lastHour: Int
        /// The rail's height: to the last hour, or the foot of the last block if lower.
        var height: CGFloat
        var clusters: [Cluster]
        var free: [Free]

        var hours: [Int] { Array(firstHour...lastHour) }
        /// The hours with a line across: all but those inside a free stretch, which stays empty.
        var ruled: [Int] {
            hours.filter { hour in !free.contains { $0.y < y(ofHour: hour) && y(ofHour: hour) < $0.y + $0.height } }
        }
        var blocks: [Block] { clusters.flatMap(\.blocks) }

        func y(ofHour hour: Int) -> CGFloat { CGFloat(hour - firstHour) * Self.hourHeight }

        /// Where a moment falls on the rail; nothing outside it, or on another day.
        func y(of date: Date) -> CGFloat? {
            guard date >= dayStart, let next = calendar.date(byAdding: .day, value: 1, to: dayStart), date < next else { return nil }
            let minute = Self.minute(of: date, from: dayStart, calendar: calendar)
            guard minute >= firstHour * 60, minute <= lastHour * 60 else { return nil }
            return CGFloat(minute - firstHour * 60) / 60 * Self.hourHeight
        }

        /// The clock's minute of the day (so a day the clocks change keeps its hours); 24:00 for
        /// the next day or later, 0 for before it.
        static func minute(of date: Date, from dayStart: Date, calendar: Calendar) -> Int {
            if date < dayStart { return 0 }
            if let next = calendar.date(byAdding: .day, value: 1, to: dayStart), date >= next { return 24 * 60 }
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }

        static func make(_ events: [Event], on day: String, calendar: Calendar = .current) -> Timeline? {
            guard let dayStart = AgendaCard.date(of: day, calendar: calendar) else { return nil }
            let spans: [(event: Event, start: Int, end: Int)] = events.filter { !$0.allDay }
                .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
                .map { event in
                    let start = minute(of: event.start, from: dayStart, calendar: calendar)
                    let end = event.end.map { minute(of: $0, from: dayStart, calendar: calendar) } ?? start + untilEnd
                    return (event, start, min(24 * 60, max(end, start)))
                }
            guard let earliest = spans.map(\.start).min(), let latest = spans.map(\.end).max() else { return nil }
            let firstHour = min(23, earliest / 60)
            let lastHour = max(firstHour + 1, min(24, (latest + 59) / 60))
            func y(_ minute: Int) -> CGFloat { CGFloat(minute - firstHour * 60) / 60 * hourHeight }

            // Side by side: the first column free at a block's top, a new one when none is; a
            // cluster ends where nothing drawn reaches the next block.
            var clusters: [Cluster] = []
            var current: [Block] = []
            var columnFeet: [CGFloat] = []
            var reach = -CGFloat.infinity
            let blocks = spans.map { Block(event: $0.event, y: y($0.start), height: max(shortest, y($0.end) - y($0.start)), column: 0) }
                .sorted { ($0.y, -$0.height) < ($1.y, -$1.height) }
            for var block in blocks {
                if !current.isEmpty, block.y >= reach - 0.01 {
                    clusters.append(Cluster(blocks: current, columns: columnFeet.count))
                    current = []
                    columnFeet = []
                }
                if let free = columnFeet.firstIndex(where: { $0 <= block.y + 0.01 }) {
                    block.column = free
                    columnFeet[free] = block.y + block.height
                } else {
                    block.column = columnFeet.count
                    columnFeet.append(block.y + block.height)
                }
                current.append(block)
                reach = max(reach, block.y + block.height)
            }
            if !current.isEmpty { clusters.append(Cluster(blocks: current, columns: columnFeet.count)) }

            // Free: from the end of everything so far to the next start, drawn between the blocks.
            var free: [Free] = []
            var busyUntil = spans[0].end
            var foot = y(spans[0].start) + max(shortest, y(spans[0].end) - y(spans[0].start))
            for span in spans.dropFirst() {
                let top = foot + 4, bottom = y(span.start) - 4
                if span.start - busyUntil >= freeAfter, bottom - top >= shortest {
                    free.append(Free(y: top, height: bottom - top, minutes: span.start - busyUntil, start: busyUntil))
                }
                busyUntil = max(busyUntil, span.end)
                foot = max(foot, y(span.start) + max(shortest, y(span.end) - y(span.start)))
            }

            let height = max(CGFloat(lastHour - firstHour) * hourHeight, blocks.map { $0.y + $0.height }.max() ?? 0)
            return Timeline(dayStart: dayStart, calendar: calendar, firstHour: firstHour, lastHour: lastHour,
                            height: height, clusters: clusters, free: free)
        }

        /// A new event where the rail was tapped: at the quarter hour nearest `y` (no earlier than
        /// the rail's start), an hour long.
        func slot(atY y: CGFloat) -> Slot? {
            let minute = Double(firstHour * 60) + Double(max(0, y) / Self.hourHeight) * 60
            let start = min(24 * 60 - 15, max(firstHour * 60, Int((minute / 15).rounded()) * 15))
            return slot(minute: start, minutes: 60)
        }

        /// A new event in a free stretch: from its start, for its length up to an hour.
        func slot(for free: Free) -> Slot? {
            slot(minute: free.start, minutes: min(60, free.minutes))
        }

        private func slot(minute: Int, minutes: Int) -> Slot? {
            guard let start = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: dayStart) else { return nil }
            return Slot(start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)))
        }
    }

    /// The times of an event being added from the card.
    nonisolated struct Slot: Identifiable, Equatable, Sendable {
        var start: Date
        var end: Date
        var id: Date { start }

        /// The next whole hour on `day`, by the clock now (VoiceOver's "Add an event…"): at 2:20 PM,
        /// 3 PM that day; no later than 11 PM.
        static func nextHour(on day: Date, now: Date = .now, calendar: Calendar = .current) -> Slot? {
            let hour = min(23, calendar.component(.hour, from: now) + 1)
            guard let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: calendar.startOfDay(for: day)) else { return nil }
            return Slot(start: start, end: start.addingTimeInterval(3600))
        }
    }

    /// The timeline with its open events grown to fit their details: whatever starts at or below
    /// a grown block's foot moves down by what it grew; whatever runs across that foot stretches.
    nonisolated struct Shift: Sendable {
        typealias Event = ReplyCard.Agenda.Event
        private var steps: [(at: CGFloat, by: CGFloat)] = []
        private var grown: [Event: CGFloat] = [:]

        /// `grown`: an open event's block's natural height, as measured.
        init(_ timeline: Timeline, grown: [Event: CGFloat]) {
            var byFoot: [CGFloat: CGFloat] = [:]
            for block in timeline.blocks {
                guard let natural = grown[block.event], natural > block.height else { continue }
                self.grown[block.event] = natural - block.height
                byFoot[block.y + block.height] = max(byFoot[block.y + block.height] ?? 0, natural - block.height)
            }
            steps = byFoot.map { ($0.key, $0.value) }
        }

        /// Where something that starts at `y` now starts.
        func top(_ y: CGFloat) -> CGFloat {
            y + steps.reduce(0) { $1.at <= y + 0.01 ? $0 + $1.by : $0 }
        }

        /// Where something that ends at `y` now ends (a block's own growth aside).
        func bottom(_ y: CGFloat) -> CGFloat {
            y + steps.reduce(0) { $1.at < y - 0.01 ? $0 + $1.by : $0 }
        }

        /// Where on the timeline as worked out a point drawn at `y` is (`top` the other way round);
        /// in what an open event grew, at that event's foot.
        func unshift(_ y: CGFloat) -> CGFloat {
            var moved: CGFloat = 0
            for step in steps.sorted(by: { $0.at < $1.at }) {
                let drawn = step.at + moved
                if y < drawn - 0.01 { break }
                if y < drawn + step.by { return step.at }
                moved += step.by
            }
            return y - moved
        }

        func frame(of block: Timeline.Block) -> (y: CGFloat, height: CGFloat) {
            let top = top(block.y)
            return (top, bottom(block.y + block.height) - top + (grown[block.event] ?? 0))
        }
    }

    // MARK: Words

    /// "Today", "Tomorrow", "Yesterday", or "Friday, Oct 30"; `withDate` adds the date to the
    /// near ones too ("Tomorrow · Fri, Oct 30").
    static func dayName(_ day: String, withDate: Bool = false, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let date = date(of: day, calendar: calendar) else { return day }
        guard let near = nearName(date, now: now, calendar: calendar) else { return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) }
        return withDate ? "\(near) · \(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))" : near
    }

    /// "Today", "Tomorrow" or "Yesterday"; nothing for a day further off.
    nonisolated static func nearName(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String? {
        if calendar.isDate(date, inSameDayAs: now) {
            String(localized: "Today", comment: "An agenda card's day")
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            String(localized: "Tomorrow", comment: "An agenda card's day")
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            String(localized: "Yesterday", comment: "An agenda card's day")
        } else {
            nil
        }
    }

    /// "Fri, Oct 30".
    static func dateName(_ day: String, calendar: Calendar = .current) -> String {
        date(of: day, calendar: calendar).map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? day
    }

    nonisolated static func date(of day: String, calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// "9:00 AM to 8:00 PM".
    nonisolated static func span(_ start: Date, _ end: Date) -> String {
        String(localized: "\(start.formatted(date: .omitted, time: .shortened)) to \(end.formatted(date: .omitted, time: .shortened))",
               comment: "An agenda card's event, as VoiceOver reads its time")
    }

    /// A free stretch's length to the half hour: "2½ hours", "3 hours".
    nonisolated static func span(minutes: Int, locale: Locale = .current) -> String {
        let hours = (Double(minutes) / 30).rounded() / 2
        let text = Measurement(value: hours, unit: UnitDuration.hours)
            .formatted(.measurement(width: .wide, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1)))
                .locale(locale))
        return text.replacingOccurrences(of: "\(locale.decimalSeparator ?? ".")5", with: "½")
    }

    /// The rail's labels: on a 12-hour clock "9 AM", "10", "11", "Noon", "1 PM", "2" (the half of
    /// the day named where it starts); on a 24-hour one "09:00", "10:00".
    nonisolated static func hourLabels(_ hours: [Int], on dayStart: Date, calendar: Calendar = .current) -> [String] {
        let locale = calendar.locale ?? .current
        let twelve = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale)?.contains("a") ?? true
        var full = Date.FormatStyle.dateTime.hour().locale(locale)
        full.timeZone = calendar.timeZone
        var bare = Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted)).locale(locale)
        bare.timeZone = calendar.timeZone
        var clock = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute().locale(locale)
        clock.timeZone = calendar.timeZone
        return hours.enumerated().map { index, hour in
            let date = hour >= 24 ? calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
                : calendar.date(bySettingHour: hour, minute: 0, second: 0, of: dayStart) ?? dayStart
            guard twelve else { return date.formatted(clock) }
            if hour == 12 { return String(localized: "Noon", comment: "An agenda card's hour rail: 12 PM") }
            let named = index == 0 || hour == 13 || hour % 24 == 0 || (hour > 12 && hours[index - 1] < 12)
            return date.formatted(named ? full : bare)
        }
    }

    /// An event's time and place on its block: "9:00 – 10:15 AM · Lake Eola Park".
    nonisolated static func when(_ event: ReplyCard.Agenda.Event) -> String {
        [time(event), event.location].compactMap { $0 }.joined(separator: " · ")
    }

    /// "9:00 – 10:15 AM", or "6:30 PM" with no end.
    nonisolated static func time(_ event: ReplyCard.Agenda.Event) -> String {
        event.end.map { (event.start..<$0).formatted(date: .omitted, time: .shortened) }
            ?? event.start.formatted(date: .omitted, time: .shortened)
    }

    /// What VoiceOver says for an event, as one: what, when, where ("Lunch with Dana, 12:30 PM to
    /// 1:30 PM, Rossio Roasters").
    static func spoken(_ event: ReplyCard.Agenda.Event) -> String {
        var parts = [event.title]
        if event.allDay {
            parts.append(String(localized: "All day", comment: "An agenda card: an event without a time"))
        } else if let end = event.end {
            parts.append(span(event.start, end))
        } else {
            parts.append(event.start.formatted(date: .omitted, time: .shortened))
        }
        if let location = event.location { parts.append(location) }
        return parts.joined(separator: ", ")
    }

    /// Each calendar's own colour, the same every time it is named; the theme's tint with no name.
    /// Or every event in the one colour picked in Settings (Calendar Events).
    static func color(of calendar: String?) -> AnyShapeStyle {
        if let picked = Settings.shared.eventColor.color { return AnyShapeStyle(picked) }
        guard let calendar, !calendar.isEmpty else { return AnyShapeStyle(.tint) }
        let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .red, .indigo, .brown, .mint]
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in calendar.lowercased().utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return AnyShapeStyle(colors[Int(hash % UInt64(colors.count))])
    }

    /// Calendar opened on the day (`calshow:` at its start), on the iPhone and iPad; on the Mac,
    /// Calendar itself (`ical:`, the one link it takes: it opens on no date of ours).
    static func calendarURL(for day: Day) -> URL? {
        #if os(iOS)
        day.date.flatMap { EventDetails.calendarURL(for: $0) }
        #else
        URL(string: "ical://")
        #endif
    }

    /// An event's Open in Calendar: at its time on the iPhone and iPad, Calendar on the Mac.
    static func calendarURL(at date: Date) -> URL? {
        #if os(iOS)
        EventDetails.calendarURL(for: date)
        #else
        URL(string: "ical://")
        #endif
    }

    /// On the Mac, the line a tap puts in the message field: "Add to my calendar Saturday,
    /// October 31 at 2:00 PM: ", for the person to say what.
    nonisolated static func addLine(_ slot: Slot) -> String {
        String(localized: "Add to my calendar \(slot.start.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute())): ",
               comment: "On the Mac, what tapping a free time on an agenda card puts in the message field, for the person to finish (\"Add to my calendar Saturday, October 31 at 2:00 PM: \")")
    }

    static var dayHint: Text {
        Text("Opens this day in Calendar", comment: "An agenda card's day header and its Open in Calendar button, as VoiceOver hints them")
    }

    /// Maps for an event's place, only when it is an address (`EventPlace`): a room ("Office ·
    /// Room 4"), a meeting link or an app's name gets none, where Maps found somewhere by its name.
    static func mapsURL(_ place: String) -> URL? {
        guard EventPlace.isAddress(place) else { return nil }
        var parts = URLComponents(string: "https://maps.apple.com/")
        parts?.queryItems = [URLQueryItem(name: "q", value: place)]
        return parts?.url
    }
}

#if os(iOS)
/// Apple's new-event editor with the times filled in, and nothing else. From iOS 17 it is drawn
/// outside Redde when Redde has no access to the calendar, and saves without any: nothing is asked
/// for here. With full access (Phone tools, the start screen's card), it is drawn in Redde.
private struct NewEventEditor: UIViewControllerRepresentable {
    let slot: AgendaCard.Slot
    let done: () -> Void

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        var done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }

        // EventKitUI calls it on a thread of its choosing: back on the main actor by hand.
        nonisolated func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            Task { @MainActor in self.done() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.startDate = slot.start
        event.endDate = slot.end
        let editor = EKEventEditViewController()
        editor.eventStore = store
        editor.event = event
        editor.editViewDelegate = context.coordinator
        return editor
    }

    func updateUIViewController(_ editor: EKEventEditViewController, context: Context) {
        context.coordinator.done = done
    }
}
#endif
