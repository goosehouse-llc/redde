import SwiftUI

/// A flight, or a trip's flights stacked (`ReplyCard.flight`, asked 2026-10-31): the airline and
/// the number, where it stands (on time, delayed with the new time, boarding, in the air, landed,
/// cancelled: in words and a mark, not by colour alone), from and to with each time in its
/// airport's own zone, terminal, gate and seat, how long, and the layover between flights. An
/// airport opens in Maps only where it is a real place (`Airport.mapsQuery`). It shows what the
/// agent looked up and never checks again by itself: Refresh asks the agent. Nothing on it books.
struct FlightCard: View {
    let card: ReplyCard.Trip
    let whole: ReplyCard
    private let legs: [Leg]
    @Environment(\.theme) private var theme

    init(card: ReplyCard.Trip, whole: ReplyCard) {
        self.card = card
        self.whole = whole
        legs = card.legs.indices.map { Leg(card, $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardBox(spacing: 14) {
                if legs.count > 1 || card.title != nil || card.confirmation != nil {
                    CardTitle(symbol: "airplane", title: card.title ?? Self.route(card), subtitle: card.confirmation.map {
                        String(localized: "Confirmation \($0)", comment: "A flight card: the booking's code, e.g. Confirmation ABC123")
                    })
                }
                ForEach(Array(legs.enumerated()), id: \.offset) { n, leg in
                    if n > 0 {
                        if let layover = leg.layover { LayoverLine(text: layover) } else { Divider() }
                    }
                    LegView(leg: leg, titled: legs.count > 1 || card.title != nil || card.confirmation != nil)
                }
                if let note = card.note { Text(note).chatFont(.caption).foregroundStyle(.secondary) }
            }
            CardChips(chips: card.legs.allSatisfy({ [.landed, .cancelled].contains($0.status) }) ? [] : [Refresh.refresh], whole: whole,
                      title: { _ in String(localized: "Refresh", comment: "A chip under a score card: asks the agent for the latest score") },
                      symbol: { _ in "arrow.clockwise" },
                      hint: { _ in Text("Asks your agent for the latest on the flight", comment: "VoiceOver hint: a flight card's Refresh") },
                      asked: { $0.contains("tapped Refresh") ? .refresh : nil }, send: { _ in Self.refresh(card) })
        }
    }

    enum Refresh: Hashable { case refresh }

    /// "LIS → JFK → DEN".
    static func route(_ card: ReplyCard.Trip) -> String {
        let stops = [card.legs.first.map(\.from)].compactMap(\.self) + card.legs.map(\.to)
        return stops.map { $0.code ?? $0.city ?? $0.name ?? "?" }.joined(separator: " → ")
    }

    static func refresh(_ card: ReplyCard.Trip) -> (shown: String, said: String) {
        let flights = card.legs.map { leg in
            let named = [leg.airline, leg.number].compactMap(\.self).joined(separator: " ")
            let route = "\(leg.from.code ?? leg.from.city ?? "?")→\(leg.to.code ?? leg.to.city ?? "?")"
            let when = leg.departs.map { " departing \(ISO8601DateFormatter.string(from: $0.date, timeZone: $0.timeZone, formatOptions: [.withInternetDateTime]))" } ?? ""
            return (named.isEmpty ? route : "\(named) (\(route))") + when
        }.joined(separator: "; ")
        return (card.legs.count > 1 ? String(localized: "Check on my flights", comment: "The message a flight card's Refresh sends, for a trip of several flights")
                                    : String(localized: "Check on my flight", comment: "The message a flight card's Refresh sends"),
                "the user tapped Refresh on the flight card: look up \(flights) again with your tools and show a fresh 'flight' card; "
                    + "never guess a time, a gate or a status")
    }

    // MARK: Status

    static func name(_ status: ReplyCard.Trip.Flight.Status) -> String {
        switch status {
        case .scheduled: String(localized: "flight.scheduled", defaultValue: "Scheduled", comment: "A flight card's status: not departed, nothing known against it")
        case .onTime: String(localized: "On time", comment: "A flight card's status")
        case .delayed: String(localized: "Delayed", comment: "A flight card's status")
        case .boarding: String(localized: "Boarding", comment: "A flight card's status")
        case .departed: String(localized: "In the air", comment: "A flight card's status: it has taken off")
        case .landed: String(localized: "Landed", comment: "A flight card's status")
        case .cancelled: String(localized: "flight.cancelled", defaultValue: "Cancelled", comment: "A flight card's status: the flight is cancelled")
        case .diverted: String(localized: "Diverted", comment: "A flight card's status: it is landing somewhere else")
        }
    }

    static func symbol(_ status: ReplyCard.Trip.Flight.Status) -> String {
        switch status {
        case .scheduled: "calendar"
        case .onTime: "checkmark.circle.fill"
        case .delayed: "clock.badge.exclamationmark"
        case .boarding: "figure.walk"
        case .departed: "airplane"
        case .landed: "airplane.arrival"
        case .cancelled: "xmark.octagon.fill"
        case .diverted: "arrow.triangle.branch"
        }
    }

    static func colour(_ status: ReplyCard.Trip.Flight.Status, accent: Color) -> Color {
        switch status {
        case .onTime, .landed: PurchaseCard.good
        case .delayed, .diverted: DeliveryCard.warning
        case .cancelled: StockCard.down
        case .boarding, .departed: accent
        case .scheduled: .secondary
        }
    }

    /// "1:20 PM" in the airport's own time.
    static func clock(_ time: ReplyCard.Trip.Time, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = time.timeZone
        return time.date.formatted(style.locale(locale))
    }

    /// "Thu, Nov 5" in the airport's own time.
    static func day(_ time: ReplyCard.Trip.Time, locale: Locale = .current) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        style.timeZone = time.timeZone
        return time.date.formatted(style.locale(locale))
    }

    /// How many days later it lands, each in its own airport's time ("+1").
    static func dayShift(_ from: ReplyCard.Trip.Time, _ to: ReplyCard.Trip.Time) -> Int {
        func day(_ t: ReplyCard.Trip.Time) -> Date? {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = t.timeZone
            let parts = calendar.dateComponents([.year, .month, .day], from: t.date)
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = .gmt
            return utc.date(from: parts)
        }
        guard let a = day(from), let b = day(to) else { return 0 }
        return Int((b.timeIntervalSince(a) / 86_400).rounded())
    }

    /// "7h 45m".
    static func length(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}

extension FlightCard {
    /// One flight as drawn, worked out once.
    struct Leg {
        var flight: ReplyCard.Trip.Flight
        /// "TAP Air Portugal TP 238".
        var title: String
        var day: String?
        var departs: String?
        var departsWas: String?
        var arrives: String?
        var arrivesWas: String?
        /// "+1" where it lands on a later day there.
        var shift: String?
        var fromZone: String?
        var toZone: String?
        var length: String?
        /// "Seat 23A · Airbus A330neo".
        var extra: String?
        /// "Layover in Newark · 2h 10m", before this flight.
        var layover: String?
        var spoken: String

        init(_ card: ReplyCard.Trip, _ index: Int) {
            let f = card.legs[index]
            flight = f
            title = [f.airline, f.number].compactMap(\.self).joined(separator: " ").nilIfEmpty
                ?? String(localized: "Flight", comment: "A flight card's title when the agent named neither the airline nor the number")
            let leave = f.departsNew ?? f.departs, land = f.arrivesNew ?? f.arrives
            day = leave.map { FlightCard.day($0) }
            departs = leave.map { FlightCard.clock($0) }
            departsWas = f.departsNew != nil ? f.departs.map { FlightCard.clock($0) } : nil
            arrives = land.map { FlightCard.clock($0) }
            arrivesWas = f.arrivesNew != nil ? f.arrives.map { FlightCard.clock($0) } : nil
            if let leave, let land {
                let days = FlightCard.dayShift(leave, land)
                shift = days != 0 ? (days > 0 ? "+\(days)" : "\(days)") : nil
            }
            fromZone = leave.flatMap { $0.timeZone.abbreviation(for: $0.date) }
            toZone = land.flatMap { $0.timeZone.abbreviation(for: $0.date) }
            length = f.flightTime.map { FlightCard.length($0) }
            extra = [f.seat.map { String(localized: "Seat \($0)", comment: "A flight card: the person's seat, e.g. Seat 23A") }, f.aircraft]
                .compactMap(\.self).joined(separator: " · ").nilIfEmpty
            if index > 0, let landed = (card.legs[index - 1].arrivesNew ?? card.legs[index - 1].arrives)?.date, let off = leave?.date, off > landed {
                let place = card.legs[index - 1].to.city ?? f.from.city ?? f.from.code ?? ""
                layover = String(localized: "Layover in \(place) · \(FlightCard.length(off.timeIntervalSince(landed)))",
                                 comment: "Between two flights on a flight card: where and how long, e.g. Layover in Newark · 2h 10m")
            }
            func airport(_ a: ReplyCard.Trip.Airport) -> String { [a.city ?? a.name, a.code].compactMap(\.self).joined(separator: " ") }
            var said = [title, FlightCard.name(f.status), f.statusWords].compactMap(\.self)
            said.append(String(localized: "from \(airport(f.from)) at \(departs ?? "–") to \(airport(f.to)) at \(arrives ?? "–")",
                               comment: "VoiceOver: a flight on a flight card, its airports and times, each in its own time"))
            if let departsWas { said.append(String(localized: "flight.was", defaultValue: "was \(departsWas)", comment: "VoiceOver: a delayed flight's departure time as first scheduled")) }
            if let terminal = f.from.terminal { said.append(String(localized: "Terminal \(terminal)", comment: "A flight card: an airport's terminal, e.g. Terminal 1")) }
            if let gate = f.from.gate { said.append(String(localized: "Gate \(gate)", comment: "A flight card: the gate, e.g. Gate 14")) }
            if let extra { said.append(extra) }
            if let length { said.append(length) }
            spoken = said.joined(separator: ", ")
        }
    }
}

/// One flight: its title and status, then from and to.
private struct LegView: View {
    let leg: FlightCard.Leg
    /// Under a card's title (a trip), it is smaller.
    let titled: Bool
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        let f = leg.flight
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                if !titled {
                    Image(systemName: "airplane")
                        .chatFont(.subheadline, weight: .semibold)
                        .foregroundStyle(theme.accent)
                        .frame(width: 30, height: 30)
                        .background(theme.accent.opacity(0.14), in: .rect(cornerRadius: 9))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: leg.title).chatFont(.subheadline, weight: .semibold).lineLimit(1)
                    if let day = leg.day { Text(verbatim: day).chatFont(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 6)
                StatusTag(status: f.status)
            }
            if let words = f.statusWords {
                Text(words).chatFont(.footnote).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 8) {
                end(f.from, time: leg.departs, was: leg.departsWas, zone: leg.fromZone, shift: nil, alignment: .leading)
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Circle().fill(.secondary).frame(width: 4, height: 4)
                        DashedLine().stroke(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3])).frame(height: 1)
                        Image(systemName: "airplane").chatFont(.caption).foregroundStyle(FlightCard.colour(f.status, accent: theme.accent))
                        DashedLine().stroke(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3])).frame(height: 1)
                        Circle().fill(.secondary).frame(width: 4, height: 4)
                    }
                    .frame(height: 30)
                    if let length = leg.length { Text(verbatim: length).chatFont(.caption2).foregroundStyle(.secondary).monospacedDigit() }
                }
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
                end(f.to, time: leg.arrives, was: leg.arrivesWas, zone: leg.toZone, shift: leg.shift, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: leg.spoken))
            .accessibilityActions {
                ForEach(Array([f.from, f.to].enumerated()), id: \.offset) { _, airport in
                    if let link = airport.mapsQuery.flatMap(Self.maps) {
                        Button(String(localized: "\(airport.name ?? airport.city ?? airport.code ?? "") in Maps",
                                      comment: "VoiceOver: a flight card's action that opens an airport in Maps, e.g. Lisbon in Maps")) { openURL(link) }
                    }
                }
            }
            if let extra = leg.extra {
                Label { Text(verbatim: extra) } icon: { Image(systemName: "carseat.right") }
                    .chatFont(.footnote).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
    }

    /// The airport's code, large, and its city: in Maps with a tap where it is a real place,
    /// marked with a pin.
    @ViewBuilder
    private func name(_ airport: ReplyCard.Trip.Airport, alignment: HorizontalAlignment) -> some View {
        let link = airport.mapsQuery.flatMap(Self.maps)
        let label = VStack(alignment: alignment, spacing: 2) {
            Text(verbatim: airport.code ?? "—").chatFont(size: 30, weight: .bold).monospaced().lineLimit(1).minimumScaleFactor(0.6)
            if let city = airport.city ?? airport.name {
                HStack(spacing: 3) {
                    if link != nil { Image(systemName: "mappin.and.ellipse").foregroundStyle(theme.accent).imageScale(.small) }
                    Text(city).foregroundStyle(link != nil ? theme.accent : Color.secondary).lineLimit(1)
                }
                .chatFont(.caption, weight: link != nil ? .medium : .regular)
            }
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        if let link {
            Button { openURL(link) } label: { label }.buttonStyle(.plain)
        } else {
            label
        }
    }

    /// One end: the airport's code, large (in Maps with a tap where it is a real place), its
    /// city, the time there, the zone, and the terminal and gate.
    private func end(_ airport: ReplyCard.Trip.Airport, time: String?, was: String?, zone: String?, shift: String?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            name(airport, alignment: alignment)
            if let time {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(verbatim: time).chatFont(.headline).monospacedDigit()
                        .foregroundStyle(was != nil ? DeliveryCard.warning : Color.primary)
                    if let shift { Text(verbatim: shift).chatFont(.caption2, weight: .bold).foregroundStyle(.secondary).baselineOffset(6) }
                }
                .padding(.top, 4)
            }
            if let was { Text(verbatim: was).chatFont(.caption).strikethrough().foregroundStyle(.secondary).monospacedDigit() }
            if let zone { Text(verbatim: zone).chatFont(.caption2).foregroundStyle(.tertiary) }
            let place = [airport.terminal.map { String(localized: "Terminal \($0)", comment: "A flight card: an airport's terminal, e.g. Terminal 1") },
                         airport.gate.map { String(localized: "Gate \($0)", comment: "A flight card: the gate, e.g. Gate 14") }].compactMap(\.self)
            if !place.isEmpty {
                Text(verbatim: place.joined(separator: " · ")).chatFont(.caption, weight: .semibold).foregroundStyle(theme.accent)
                    .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                    .padding(.top, 2)
            }
        }
        .frame(minWidth: 84, alignment: alignment == .leading ? .leading : .trailing)
    }

    /// Apple Maps at an airport: its coordinates, or its name and code.
    static func maps(_ query: String) -> URL? {
        var parts = URLComponents(string: "https://maps.apple.com/")
        let coordinates = query.wholeMatch(of: /-?\d+(?:\.\d+)?,-?\d+(?:\.\d+)?/) != nil
        parts?.queryItems = [URLQueryItem(name: coordinates ? "ll" : "q", value: query)]
        return parts?.url
    }
}

/// Between two flights: where, and how long.
private struct LayoverLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.separator).frame(height: 0.5)
            Label(text, systemImage: "hourglass").chatFont(.caption, weight: .medium).foregroundStyle(.secondary).fixedSize()
            Rectangle().fill(.separator).frame(height: 0.5)
        }
        .padding(.vertical, 2)
    }
}

/// The flight's status: its mark and its word, in its colour.
private struct StatusTag: View {
    let status: ReplyCard.Trip.Flight.Status
    @Environment(\.theme) private var theme

    var body: some View {
        let colour = FlightCard.colour(status, accent: theme.accent)
        Label(FlightCard.name(status), systemImage: FlightCard.symbol(status))
            .chatFont(.caption, weight: .bold)
            .foregroundStyle(colour)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(colour.opacity(0.14), in: .capsule)
            .fixedSize()
    }
}

private nonisolated struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { $0.move(to: CGPoint(x: rect.minX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
    }
}
