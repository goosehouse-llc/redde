import SwiftUI

/// What's on the calendar, under the reply that read it (`ReplyCard.agenda`, asked 2026-10-29):
/// each day as Today, Tomorrow or its weekday and date, then its events, a time column (or All
/// day), a bar in its calendar's colour, what and where. A day asked about with nothing on it
/// says so. Tapping an event opens its details in place: how long, which calendar, its notes,
/// and its place in Maps and its day in Calendar. Drawn like the Week Ahead's calendar.
struct AgendaCard: View {
    let card: ReplyCard.Agenda
    @State private var open: Set<ReplyCard.Agenda.Event> = []

    var body: some View {
        let days = card.byDay
        CardBox {
            Label(card.title ?? (days.count == 1 ? Self.dayName(days[0].day) : String(localized: "Calendar", comment: "An agenda card's title")),
                  systemImage: "calendar")
                .chatFont(.subheadline, weight: .semibold)
                .foregroundStyle(.tint)
            ForEach(Array(days.enumerated()), id: \.element.day) { index, group in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 8) {
                    // A single day under a title ("Tomorrow") gets its date alone, not its name again.
                    if days.count > 1 || card.title != nil {
                        Text(days.count == 1 ? Self.dateName(group.day) : Self.dayName(group.day, withDate: true))
                            .chatFont(.footnote, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    if group.events.isEmpty {
                        Text("Nothing on your calendar", comment: "An agenda card: a day with no events")
                            .chatFont(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(group.events, id: \.self) { event in
                            row(event)
                        }
                    }
                }
            }
        }
    }

    private func row(_ event: ReplyCard.Agenda.Event) -> some View {
        let isOpen = open.contains(event)
        let over = !event.allDay && (event.end ?? event.start) < .now
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if isOpen { open.remove(event) } else { open.insert(event) }
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        if event.allDay {
                            Text("All day", comment: "An agenda card: an event without a time").chatFont(.footnote, weight: .medium)
                        } else {
                            Text(event.start.formatted(date: .omitted, time: .shortened)).chatFont(.footnote, weight: .medium)
                            if let end = event.end {
                                Text(end.formatted(date: .omitted, time: .shortened)).chatFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .monospacedDigit()
                    .frame(minWidth: 62, alignment: .leading)
                    .fixedSize()
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Self.color(of: event.calendar))
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title).chatFont(.subheadline, weight: .semibold).multilineTextAlignment(.leading)
                        if let location = event.location {
                            Label(location, systemImage: "mappin.and.ellipse")
                                .chatFont(.footnote).foregroundStyle(.secondary).lineLimit(isOpen ? 3 : 1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .opacity(over ? 0.55 : 1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.spoken(event))
            .accessibilityHint(Text(isOpen ? "Hides the details" : "Shows the details", comment: "An agenda card's event, as VoiceOver hints it"))
            if isOpen { details(event) }
        }
    }

    private func details(_ event: ReplyCard.Agenda.Event) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !event.allDay, let end = event.end {
                Label(Duration.seconds(end.timeIntervalSince(event.start)).formatted(.units(allowed: [.hours, .minutes], width: .wide)),
                      systemImage: "clock")
            }
            if let calendar = event.calendar {
                Label(calendar, systemImage: "calendar")
            }
            if let notes = event.notes {
                Text(notes).lineLimit(8).textSelection(.enabled)
            }
            HStack(spacing: 16) {
                if let location = event.location, let maps = Self.mapsURL(location) {
                    Link(destination: maps) { Label("Open in Maps", systemImage: "map") }
                }
                #if os(iOS)
                if let calendar = EventDetails.calendarURL(for: event.start) {
                    Link(destination: calendar) { Label("Open in Calendar", systemImage: "calendar") }
                }
                #endif
            }
            .chatFont(.footnote, weight: .semibold)
        }
        .chatFont(.footnote)
        .foregroundStyle(.secondary)
        .padding(.leading, 75)
        .transition(.opacity)
    }

    // MARK: Words

    /// "Today", "Tomorrow", "Yesterday", or "Friday, Oct 30"; `withDate` adds the date to the
    /// near ones too ("Tomorrow · Fri, Oct 30").
    static func dayName(_ day: String, withDate: Bool = false, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let date = date(of: day, calendar: calendar) else { return day }
        let near: String? = if calendar.isDate(date, inSameDayAs: now) {
            String(localized: "Today", comment: "An agenda card's day")
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            String(localized: "Tomorrow", comment: "An agenda card's day")
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            String(localized: "Yesterday", comment: "An agenda card's day")
        } else {
            nil
        }
        guard let near else { return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) }
        return withDate ? "\(near) · \(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))" : near
    }

    /// "Fri, Oct 30".
    static func dateName(_ day: String, calendar: Calendar = .current) -> String {
        date(of: day, calendar: calendar).map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? day
    }

    static func date(of day: String, calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// What VoiceOver says for an event: when, what, where, which calendar.
    static func spoken(_ event: ReplyCard.Agenda.Event) -> String {
        var parts: [String] = []
        if event.allDay {
            parts.append(String(localized: "All day", comment: "An agenda card: an event without a time"))
        } else if let end = event.end {
            parts.append(String(localized: "\(event.start.formatted(date: .omitted, time: .shortened)) to \(end.formatted(date: .omitted, time: .shortened))",
                                comment: "An agenda card's event, as VoiceOver reads its time"))
        } else {
            parts.append(event.start.formatted(date: .omitted, time: .shortened))
        }
        parts.append(event.title)
        if let location = event.location { parts.append(location) }
        if let calendar = event.calendar { parts.append(calendar) }
        return parts.joined(separator: ", ")
    }

    /// Each calendar's own colour, the same every time it is named; the theme's tint with no name.
    static func color(of calendar: String?) -> AnyShapeStyle {
        guard let calendar, !calendar.isEmpty else { return AnyShapeStyle(.tint) }
        let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .red, .indigo, .brown, .mint]
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in calendar.lowercased().utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return AnyShapeStyle(colors[Int(hash % UInt64(colors.count))])
    }

    static func mapsURL(_ place: String) -> URL? {
        var parts = URLComponents(string: "https://maps.apple.com/")
        parts?.queryItems = [URLQueryItem(name: "q", value: place)]
        return parts?.url
    }
}
