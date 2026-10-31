import MapKit
import SwiftUI

/// A reply's cards under its words (`ReplyCards`): a map, a list of places, the weather, the time.
/// Drawn here with MapKit and the system's weather symbols; a map or a place opens in Apple Maps.
struct ReplyCardsView: View {
    let cards: [ReplyCard]
    /// The reply is still coming in: a weather or a time card still being looked up says so.
    var pending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                switch card {
                case let .map(map): MapCard(card: map)
                case let .places(places): PlacesCard(card: places)
                case let .weather(weather): WeatherCard(card: weather, pending: pending)
                case let .time(clock): TimeCard(card: clock, pending: pending)
                case let .agenda(agenda): AgendaCard(card: agenda)
                case let .review(review): ReviewCard(card: review, whole: card)
                case let .choice(choice): ChoiceCard(card: choice, whole: card)
                case let .checklist(list): ChecklistCard(card: list, whole: card)
                case let .form(form): FormCard(card: form, whole: card)
                case let .key(ask): KeyAskCard(card: ask)
                case let .purchase(purchase): PurchaseCard(card: purchase, whole: card)
                case let .home(home): HomeCard(card: home, whole: card)
                case let .reminder(reminder): ReminderCard(card: reminder, whole: card)
                case let .compare(comparison): CompareCard(card: comparison)
                case let .score(scores): ScoreCard(card: scores, whole: card)
                case let .recipe(recipe): RecipeCard(card: recipe, whole: card)
                case let .delivery(delivery): DeliveryCard(card: delivery, whole: card)
                case let .flight(trip): FlightCard(card: trip, whole: card)
                case let .show(shows): ShowCard(card: shows, whole: card)
                case let .conversion(conversion): ConversionCard(card: conversion)
                case let .stock(quotes): StockCard(card: quotes, whole: card)
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}

/// The frame every card sits in: the newer cards' (the agent's questions, approvals), from
/// 2026-10-30 with the weather and places cards' new look.
struct CardBox<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardGround()
    }
}

extension View {
    /// A card's ground, edge and shadow, for a card drawn to its edges too (the places card's map).
    /// The shadow is the ground's alone, not cast again by everything on it, which a scrolling
    /// chat would pay for.
    func cardGround() -> some View {
        background {
            RoundedRectangle(cornerRadius: 20).fill(.background.secondary)
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        }
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5) }
    }
}

// MARK: - Places, found

/// Coordinates for places the agent named without them: looked up once each on the phone
/// (MapKit's search), kept for the run of the app, misses too.
@MainActor
@Observable
final class PlaceLookup {
    static let shared = PlaceLookup()
    private(set) var found: [ReplyCard.Place: CLLocationCoordinate2D] = [:]
    private var asked: Set<ReplyCard.Place> = []

    func coordinate(of place: ReplyCard.Place) -> CLLocationCoordinate2D? {
        if let latitude = place.latitude, let longitude = place.longitude {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        return found[place]
    }

    func look(up places: [ReplyCard.Place]) async {
        for place in places where !place.hasCoordinate && !asked.contains(place) {
            asked.insert(place)
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = [place.name, place.address].compactMap(\.self).joined(separator: ", ")
            if let item = try? await MKLocalSearch(request: request).start().mapItems.first {
                found[place] = item.location.coordinate
            }
        }
    }

    // MARK: How far

    /// How far a place is from the person: on foot by Apple Maps where it is close enough to walk
    /// to, else as the crow flies.
    enum Away: Equatable {
        case walk(TimeInterval)
        case distance(CLLocationDistance)
    }

    /// How far each place is (asked 2026-10-30, the places card's walk times), where Redde already
    /// knows where the phone is (Places, heads-ups: `LeaveTime.here`); it never asks for it.
    private(set) var away: [ReplyCard.Place: Away] = [:]
    /// Where the phone was when they were measured.
    private(set) var here: CLLocation?
    @ObservationIgnored private var measuring: Set<ReplyCard.Place> = []

    /// Walked to, up to this far; a place further than `farthest` is too far to say.
    static let walkable: CLLocationDistance = 2_000
    static let farthest: CLLocationDistance = 50_000

    /// Where a demo says the person is (`-echo.demoCards`), in place of the phone's; never kept.
    @ObservationIgnored private var pretended: CLLocation?

    func pretend(latitude: Double, longitude: Double) {
        pretended = CLLocation(latitude: latitude, longitude: longitude)
        away = [:]
    }

    /// Measures the places not measured yet (the first eight), once each while the phone stays put.
    func measure(_ places: [ReplyCard.Place]) async {
        guard var fix = pretended ?? LeaveTime.here() else { return }
        if let here, here.distance(from: fix) <= 200 { fix = here } else { away = [:]; here = fix }   // moved: measured afresh
        for place in places.prefix(8) where away[place] == nil && !measuring.contains(place) {
            guard let at = coordinate(of: place) else { continue }
            let meters = fix.distance(from: CLLocation(latitude: at.latitude, longitude: at.longitude))
            guard meters <= Self.farthest else { continue }
            measuring.insert(place)
            defer { measuring.remove(place) }
            var found = Away.distance(meters)
            if meters <= Self.walkable, let item = mapItem(place) {
                let request = MKDirections.Request()
                request.source = MKMapItem(location: fix, address: nil)
                request.destination = item
                request.transportType = .walking
                if let eta = try? await MKDirections(request: request).calculateETA() { found = .walk(eta.expectedTravelTime) }
            }
            away[place] = found
        }
    }

    /// Where the person is, for a map of places near them (one within 5 km); else nil.
    func nearby(_ places: [ReplyCard.Place]) -> CLLocationCoordinate2D? {
        guard let here else { return nil }
        let near = places.contains { place in
            switch away[place] {
            case .walk: true
            case let .distance(meters): meters <= 5_000
            case nil: false
            }
        }
        return near ? here.coordinate : nil
    }

    /// The place as Apple Maps should open it.
    func mapItem(_ place: ReplyCard.Place) -> MKMapItem? {
        guard let coordinate = coordinate(of: place) else { return nil }
        let item = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
        item.name = place.name
        if let phone = place.phone { item.phoneNumber = phone }
        if let url = place.url { item.url = URL(string: url) }
        return item
    }
}

// MARK: - Map

private struct MapCard: View {
    let card: ReplyCard.Map
    @State private var lookup = PlaceLookup.shared
    @State private var route: MKRoute?
    /// Where a route from here starts, with Current Location on: a dot on the map.
    @State private var start: CLLocationCoordinate2D?

    private var pins: [ReplyCard.Place] {
        var all = card.places
        if let r = card.route {
            if let from = r.from, !all.contains(from) { all.append(from) }
            if !all.contains(r.to) { all.append(r.to) }
        }
        return all
    }

    var body: some View {
        CardBox {
            if let title = card.title { Text(title).chatFont(.subheadline, weight: .semibold) }
            MapPicture(places: pins, route: route, here: start)
                .frame(height: 190)
                .clipShape(.rect(cornerRadius: 12))
                .contentShape(.rect)
                .onTapGesture { open() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(card.title ?? String(localized: "Map of \(pins.map(\.name).formatted())"))
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(card.route == nil ? String(localized: "Opens it in Maps") : String(localized: "Opens the directions in Maps"))
            HStack(spacing: 10) {
                if let r = card.route {
                    Label(Self.modeName(r.mode), systemImage: Self.modeSymbol(r.mode)).chatFont(.footnote, weight: .medium)
                    if let route {
                        Text("\(Self.duration(route.expectedTravelTime)) · \(Self.distance(route.distance))").chatFont(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("\(r.from?.name ?? String(localized: "From here")) to \(r.to.name)").chatFont(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill", action: open)
                        .chatFont(.footnote, weight: .semibold).buttonStyle(.borderless)
                        .frame(minHeight: 44).contentShape(.rect)
                        .accessibilityHint(String(localized: "Opens the directions in Maps"))
                } else {
                    Text(pins.map(\.name).formatted()).chatFont(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Open in Maps", systemImage: "map", action: open).chatFont(.footnote, weight: .semibold).buttonStyle(.borderless)
                        .frame(minHeight: 44).contentShape(.rect)
                        .accessibilityHint(String(localized: "Opens it in Maps"))
                }
            }
        }
        .task(id: pins) {
            await lookup.look(up: pins)
            await findRoute()
        }
        // A fresher fix while the card is up: the way from here again.
        .onChange(of: CurrentLocationService.fixedAt) { if card.route?.from == nil { Task { await findRoute() } } }
    }

    /// Between two named places, the route itself on the map. From where the person is, with
    /// Current Location on (asked 2026-10-30), from the phone's recent fix; else Maps works it
    /// out when it opens (Redde doesn't ask for the phone's location).
    private func findRoute() async {
        guard let r = card.route, let b = lookup.mapItem(r.to) else { return }
        let a: MKMapItem
        if let from = r.from {
            guard let item = lookup.mapItem(from) else { return }
            a = item
        } else {
            guard let fix = Self.here() else { return }
            a = MKMapItem(location: fix, address: nil)
            start = fix.coordinate
        }
        let request = MKDirections.Request()
        request.source = a
        request.destination = b
        request.transportType = switch r.mode {
        case .walking: .walking
        case .transit: .transit
        default: .automobile
        }
        route = try? await MKDirections(request: request).calculate().routes.first
    }

    private func open() {
        if let r = card.route, let to = lookup.mapItem(r.to) {
            let from = r.from.flatMap(lookup.mapItem) ?? MKMapItem.forCurrentLocation()
            MKMapItem.openMaps(with: [from, to], launchOptions: [MKLaunchOptionsDirectionsModeKey: Self.launchMode(r.mode)])
        } else {
            let items = pins.compactMap(lookup.mapItem)
            if items.count == 1 { items[0].openInMaps() } else if !items.isEmpty { MKMapItem.openMaps(with: items) }
        }
    }

    /// Where the person is, for a route from here: only with Current Location on, and a fix of the
    /// last half hour (`CurrentLocation.freshFor`); a fresh one is asked for meanwhile.
    private static func here() -> CLLocation? {
        guard CurrentLocation.isOn else { return nil }
        CurrentLocationService.shared.refresh()
        guard let fix = LeaveTime.here(), Date.now.timeIntervalSince(fix.timestamp) < CurrentLocation.freshFor else { return nil }
        return fix
    }

    static func modeName(_ mode: ReplyCard.Route.Mode) -> String {
        switch mode {
        case .driving: String(localized: "Drive", comment: "A way to travel, on a map card")
        case .walking: String(localized: "Walk", comment: "A way to travel, on a map card")
        case .transit: String(localized: "Transit", comment: "A way to travel, on a map card")
        case .cycling: String(localized: "Cycle", comment: "A way to travel, on a map card")
        }
    }

    static func modeSymbol(_ mode: ReplyCard.Route.Mode) -> String {
        switch mode { case .driving: "car.fill"; case .walking: "figure.walk"; case .transit: "tram.fill"; case .cycling: "bicycle" }
    }

    static func launchMode(_ mode: ReplyCard.Route.Mode) -> String {
        switch mode {
        case .driving: MKLaunchOptionsDirectionsModeDriving
        case .walking: MKLaunchOptionsDirectionsModeWalking
        case .transit: MKLaunchOptionsDirectionsModeTransit
        case .cycling: MKLaunchOptionsDirectionsModeCycling
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    static func distance(_ meters: CLLocationDistance) -> String {
        MeasureUnits.distance(meters)
    }
}

/// The map itself: still (it sits in a scrolling chat), the pins, and the route when there is one.
private struct MapPicture: View {
    let places: [ReplyCard.Place]
    let route: MKRoute?
    /// The pins numbered as the list under them is, each in its colour; none: plain pins.
    var tints: [Color] = []
    /// Where the person is, when they are near the places.
    var here: CLLocationCoordinate2D?
    /// A numbered pin tapped: its place (asked 2026-10-30: every card fully interactive).
    var onPin: ((ReplyCard.Place) -> Void)?
    @State private var lookup = PlaceLookup.shared

    var body: some View {
        let shown = places.compactMap { place in lookup.coordinate(of: place).map { (place, $0) } }
        Map(initialPosition: .automatic, interactionModes: []) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
                if !tints.isEmpty, let number = places.firstIndex(of: item.0) {
                    Annotation(item.0.name, coordinate: item.1) {
                        NumberedPin(number: number + 1, tint: tints[number % tints.count]) { onPin?(item.0) }
                    }
                    .annotationTitles(.hidden)
                } else {
                    Marker(item.0.name, systemImage: index == shown.count - 1 && route != nil ? "flag.fill" : "mappin", coordinate: item.1)
                }
            }
            if let here {
                Annotation(coordinate: here) { HereDot() } label: { EmptyView() }
            }
            if let route { MapPolyline(route.polyline).stroke(.blue, lineWidth: 5) }
        }
        // Numbered pins on a map of their own: the shops and stations round them would crowd them.
        .mapStyle(.standard(pointsOfInterest: tints.isEmpty ? .all : .excludingAll))
        .id(shown.count + (route == nil ? 0 : 100) + (here == nil ? 0 : 1000))   // framed again once looked-up places arrive
        .overlay {
            if shown.isEmpty { ProgressView().controlSize(.small) }
        }
    }
}

// MARK: - Places

/// A numbered pin in its place's colour, as the list under the map numbers it. Tapped (44 pt
/// round it), its place opens in Maps.
private struct NumberedPin: View {
    let number: Int
    let tint: Color
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold)).monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint, in: .circle)
                .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
    }
}

/// Where the person is, on a map of places near them.
private struct HereDot: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Circle().fill(theme.accent)
            .frame(width: 16, height: 16)
            .overlay { Circle().strokeBorder(.white, lineWidth: 3) }
            .background { Circle().fill(theme.accent.opacity(0.22)).frame(width: 28, height: 28) }
            .accessibilityHidden(true)
    }
}

/// A list of places (its look approved 2026-10-30): a map across the top, each place's pin
/// numbered in its own colour and the person on it where Redde knows where they are; then the
/// places with what the agent found (its pick, the price, the rating, whether open) and how far
/// each is; Directions to the pick, and all of them in Maps.
private struct PlacesCard: View {
    let card: ReplyCard.Places
    @State private var lookup = PlaceLookup.shared
    @Environment(\.theme) private var theme

    var body: some View {
        let mapped = card.places.count > 1
        let tints = card.places.indices.map { Self.tint($0, accent: theme.accent) }
        VStack(alignment: .leading, spacing: 0) {
            if mapped {
                MapPicture(places: card.places, route: nil, tints: tints, here: lookup.nearby(card.places)) { lookup.mapItem($0)?.openInMaps() }
                    .frame(height: 180)
                    .contentShape(.rect)
                    .onTapGesture(perform: openAll)
                    .accessibilityHidden(true)
                    .overlay(alignment: .bottomLeading) {
                        if let title = card.title {
                            Text(title).chatFont(.caption2, weight: .semibold).lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.regularMaterial, in: .rect(cornerRadius: 8))
                                .padding(10)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
            }
            VStack(alignment: .leading, spacing: 0) {
                if !mapped, let title = card.title {
                    Text(title).chatFont(.subheadline, weight: .semibold).padding(.top, 10).accessibilityAddTraits(.isHeader)
                }
                ForEach(Array(card.places.enumerated()), id: \.offset) { index, place in
                    if index > 0 { Divider() }
                    PlaceRow(place: place, number: index + 1, tint: tints[index], away: lookup.away[place])
                }
                if let lead = card.lead { buttons(lead) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(.rect(cornerRadius: 20))
        .cardGround()
        .task(id: card.places) {
            // With Current Location on, a fresh fix if the last is a few minutes old (asked 2026-10-30).
            if CurrentLocation.isOn { CurrentLocationService.shared.refresh() }
            await lookup.look(up: card.places)
            await lookup.measure(card.places)
        }
        // It came: the walks measured from there (`measure` keeps them while the phone stays put).
        .onChange(of: CurrentLocationService.fixedAt) { Task { await lookup.measure(card.places) } }
    }

    private func buttons(_ lead: ReplyCard.Place) -> some View {
        let ready = lookup.coordinate(of: lead) != nil
        return HStack(spacing: 10) {
            Button { directions(to: lead) } label: {
                Text("Directions to \(lead.name)", comment: "The wide button under a places card: directions to the agent's pick")
                    .chatFont(.subheadline, weight: .semibold).lineLimit(1)
                    .foregroundStyle(theme.userText)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(theme.accent, in: .capsule)
                    .contentShape(.capsule)
            }
            .disabled(!ready)
            .opacity(ready ? 1 : 0.5)
            .accessibilityHint(String(localized: "Opens the directions in Maps"))
            Button(action: openAll) {
                Text("Maps", comment: "The button under a places card that opens them all in Apple Maps")
                    .chatFont(.subheadline, weight: .semibold)
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(.background.tertiary, in: .capsule)
                    .contentShape(.capsule)
            }
            .accessibilityHint(String(localized: "Opens it in Maps"))
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
    }

    /// On foot (asked 2026-10-30), or by car where it is known to be further than a walk.
    private func directions(to place: ReplyCard.Place) {
        guard let item = lookup.mapItem(place) else { return }
        let far = if case let .distance(meters) = lookup.away[place] { meters > PlaceLookup.walkable } else { false }
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: far ? MKLaunchOptionsDirectionsModeDriving : MKLaunchOptionsDirectionsModeWalking])
    }

    private func openAll() {
        let items = card.places.compactMap(lookup.mapItem)
        if items.count == 1 { items[0].openInMaps() } else if !items.isEmpty { MKMapItem.openMaps(with: items) }
    }

    /// Each place's colour, its pin's and its number's: the accent, a red and a purple as
    /// designed, then the system's.
    static func tint(_ index: Int, accent: Color) -> Color {
        let rest: [Color] = [Color(red: 0.898, green: 0.282, blue: 0.231), Color(red: 0.545, green: 0.361, blue: 0.965),
                             .orange, .teal, .pink, .indigo, .brown]
        return index == 0 ? accent : rest[(index - 1) % rest.count]
    }
}

/// One place on a places card. Tapped, it opens in Maps; held, it can be called or its site opened.
private struct PlaceRow: View {
    let place: ReplyCard.Place
    let number: Int
    let tint: Color
    let away: PlaceLookup.Away?
    @State private var lookup = PlaceLookup.shared
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        let facts = Self.facts(place)
        let hours = Self.hours(place)
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                Text("\(number)")
                    .chatFont(.footnote, weight: .bold).monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(tint, in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(place.name).chatFont(.callout, weight: .semibold).lineLimit(2)
                        if place.pick == true {
                            Text(String(localized: "card.pick", defaultValue: "Pick", comment: "A tag on the agent's pick: the place, product or option it recommends"))
                                .textCase(.uppercase)
                                .chatFont(.caption2, weight: .bold).tracking(0.4)
                                .foregroundStyle(theme.accent)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(theme.accent.opacity(0.14), in: .rect(cornerRadius: 6))
                        }
                    }
                    if let facts { Text(facts).chatFont(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                    if let hours { Text(hours).chatFont(.footnote, weight: .medium).foregroundStyle(Self.colour(place.opening)).lineLimit(1) }
                    if let note = place.note { Text(note).chatFont(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 0)
                if let away {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(away.amount).chatFont(.subheadline, weight: .semibold).monospacedDigit().lineLimit(1)
                        Text(away.kind).chatFont(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { actions }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(hours: hours))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(String(localized: "Opens it in Maps"))
        .accessibilityActions { actions }
    }

    @ViewBuilder private var actions: some View {
        Button("Open in Maps", systemImage: "map", action: open)
        if let phone = place.phone, let url = URL(string: "tel:" + phone.filter { "+0123456789".contains($0) }) {
            Button("Call \(place.name)", systemImage: "phone") { openURL(url) }
        }
        if let site = place.url, let url = URL(string: site) {
            Button("\(place.name)'s website", systemImage: "safari") { openURL(url) }
        }
    }

    private func open() { lookup.mapItem(place)?.openInMaps() }

    /// "Coffee · $$ · ★ 4.7"; with none of those, its address.
    static func facts(_ place: ReplyCard.Place) -> String? {
        let said = [place.category, place.price, place.rating.map { "★ " + $0.formatted(.number.precision(.fractionLength(1))) }].compactMap(\.self)
        return said.isEmpty ? place.address : said.joined(separator: " · ")
    }

    static func hours(_ place: ReplyCard.Place) -> String? {
        place.hours ?? place.open.map {
            $0 ? String(localized: "Open now", comment: "A place on a places card is open") : String(localized: "Closed", comment: "A place on a places card is closed")
        }
    }

    /// Open green, closing soon orange, closed red.
    static func colour(_ opening: ReplyCard.Place.Opening?) -> Color {
        switch opening {
        case .open: shade(light: (0.118, 0.541, 0.235), dark: (0.298, 0.761, 0.420))
        case .closing: shade(light: (0.698, 0.369, 0), dark: (0.941, 0.627, 0.251))
        case .closed: .red
        case nil: .secondary
        }
    }

    /// "1, Rossio Roasters, Pick, Coffee, $$, rated 4.7, Open until 9 PM, 6 min walk".
    private func spoken(hours: String?) -> String {
        let rating = place.rating.map { String(localized: "rated \($0.formatted(.number.precision(.fractionLength(1))))", comment: "A place's rating out of five, read by VoiceOver") }
        let pick = place.pick == true ? String(localized: "card.pick", defaultValue: "Pick", comment: "A tag on the agent's pick: the place, product or option it recommends") : nil
        let parts: [String?] = ["\(number)", place.name, pick, place.category, place.price, rating, hours, place.note,
                                away.map { "\($0.amount) \($0.kind)" }]
        return parts.compactMap(\.self).joined(separator: ", ")
    }
}

extension PlaceLookup.Away {
    /// "6 min", "1.2 mi".
    var amount: String {
        switch self {
        case let .walk(seconds): Duration.seconds(max(60, seconds)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        case let .distance(meters): MeasureUnits.distance(meters)
        }
    }

    var kind: String {
        switch self {
        case .walk: String(localized: "walk", comment: "Under a walking time on a places card: 6 min / walk")
        case .distance: String(localized: "away", comment: "Under a distance on a places card: 4.2 mi / away")
        }
    }
}

/// A colour with one value in light mode and another in dark.
func shade(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
    #if canImport(UIKit)
    Color(uiColor: UIColor { traits in
        let c = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
    })
    #else
    Color(nsColor: NSColor(name: nil) { appearance in
        let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    })
    #endif
}

// MARK: - Weather

/// The weather somewhere (its look approved 2026-10-30): the reading now in large type; a callout
/// when rain is likely in the hours ahead; those hours, each with how likely rain is drawn to
/// scale; then the next days on the week's scale. What it shows is worked out once, as the card is
/// made (`Shown`), never as it draws; only what the forecast has is shown.
private struct WeatherCard: View {
    let card: ReplyCard.Weather
    var pending = false
    @State private var lookup = CardLookup.shared
    @State private var allDays = false
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    private let shown: Shown

    init(card: ReplyCard.Weather, pending: Bool = false) {
        self.card = card
        self.pending = pending
        shown = Shown(card, now: AgendaCard.now())
    }

    /// Days shown before "All 7 days".
    static let firstDays = 3

    var body: some View {
        if card.hasReading {
            reading
        } else if pending || lookup.isLooking(card.place) {
            // Only its place so far: the forecast is on its way, from the plugin or looked up here.
            CardBox { LookingUp(text: String(localized: "Looking up the weather in \(card.place)…")) }
        }
    }

    private var reading: some View {
        CardBox(spacing: 16) {
            header
            if let callout = shown.callout {
                HStack(spacing: 10) {
                    Image(systemName: callout.symbol).chatFont(.title3).foregroundStyle(theme.accent).frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(callout.title).chatFont(.subheadline, weight: .semibold)
                        Text(callout.detail).chatFont(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10).padding(.horizontal, 12)
                .background(Color.blue.opacity(0.14), in: .rect(cornerRadius: 14))
                .accessibilityElement(children: .combine)
            }
            if !shown.hours.isEmpty { strip }
            if !shown.days.isEmpty { days }
            footer
        }
        // Tapped anywhere but its buttons, the Weather app (asked 2026-10-30: every card fully
        // interactive). The Mac's Weather answers weather:// too.
        .contentShape(.rect(cornerRadius: 20))
        .onTapGesture(perform: openWeather)
    }

    private func openWeather() { openURL(URL(string: "weather://")!) }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "location.fill").imageScale(.small)
                    Text(shown.heading)
                }
                .chatFont(.footnote, weight: .semibold).foregroundStyle(.secondary)
                if let now = card.now {
                    HStack(alignment: .top, spacing: 2) {
                        Text(verbatim: "\(Int(now.temperature.rounded()))").chatFont(size: 56, weight: .light).monospacedDigit().tracking(-1.5)
                        Text(verbatim: "°").chatFont(size: 26, weight: .light).padding(.top, 8)
                    }
                    if !shown.sky.isEmpty { Text(shown.sky).chatFont(.subheadline).foregroundStyle(.secondary) }
                }
            }
            Spacer(minLength: 0)
            if let now = card.now {
                Image(systemName: Self.symbol(now.condition, night: now.night == true))
                    .symbolRenderingMode(.multicolor)
                    .chatFont(size: 50)
                    .frame(width: 72, height: 72)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(shown.details)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(String(localized: "Opens the Weather app", comment: "VoiceOver hint on a weather card"))
        .accessibilityAction(.default, openWeather)
    }

    /// The hours ahead, side by side: each one's hour, sky, temperature, and how likely rain is as
    /// a bar to scale (40 pt for certain) where the forecast says.
    private var strip: some View {
        HStack(alignment: .top, spacing: 2) {
            ForEach(shown.hours) { hour in
                VStack(spacing: 6) {
                    Text(hour.label).chatFont(.caption, weight: .semibold)
                        .foregroundStyle(hour.now ? theme.accent : Color.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Image(systemName: hour.symbol).symbolRenderingMode(.multicolor).chatFont(.title3).frame(height: 24)
                    Text(hour.temperature).chatFont(.subheadline, weight: .semibold).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    if shown.bars {
                        RainBar(chance: hour.chance)
                        Text(verbatim: hour.chance.map { $0.formatted(.percent) } ?? " ")
                            .chatFont(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(hour.spoken)
            }
        }
    }

    private var days: some View {
        let more = shown.days.count > Self.firstDays
        return VStack(alignment: .leading, spacing: 0) {
            Divider()
            ForEach(allDays ? shown.days : Array(shown.days.prefix(Self.firstDays))) { day in
                HStack(spacing: 12) {
                    Text(day.label).chatFont(.subheadline, weight: .semibold).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: 44, alignment: .leading)
                    HStack(spacing: 4) {
                        Text(day.sky).lineLimit(1)
                        if let chance = day.chance { Text(verbatim: chance.formatted(.percent)).foregroundStyle(.blue).monospacedDigit() }
                    }
                    .chatFont(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(degrees(day.low)).chatFont(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                    TemperatureBar(low: day.low, high: day.high, from: shown.coldest, to: shown.warmest).frame(width: 72)
                    Text(degrees(day.high)).chatFont(.subheadline, weight: .semibold).monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
                Divider()
            }
            if more {
                Button(allDays ? String(localized: "Fewer days", comment: "Shows only the first days of a weather card's forecast")
                       : String(localized: "All \(shown.days.count) days", comment: "Shows every day of a weather card's forecast")) {
                    withAnimation(.snappy) { allDays.toggle() }
                }
                .chatFont(.footnote, weight: .semibold).foregroundStyle(theme.accent).buttonStyle(.borderless)
                .frame(minHeight: 44).contentShape(.rect)
                .accessibilityHint(allDays ? String(localized: "Shows the next three days", comment: "VoiceOver hint on a weather card's Fewer days")
                                   : String(localized: "Shows every day of the forecast", comment: "VoiceOver hint on a weather card's All days"))
            }
        }
    }

    @ViewBuilder private var footer: some View {
        let updated = shown.updated.map { String(localized: "updated \($0)", comment: "When a weather card's forecast was read, e.g. updated 12:04 PM") }
        if card.source == ReplyCards.lookedUpSource {
            // Open-Meteo's data is under CC BY 4.0: credited, with a link.
            HStack(spacing: 4) {
                Link("Weather data by Open-Meteo.com", destination: URL(string: "https://open-meteo.com/")!)
                    .frame(minHeight: 44).contentShape(.rect)   // a finger's height, though the line is small
                    .accessibilityHint(String(localized: "Opens Open-Meteo's website", comment: "VoiceOver hint on the weather card's credit"))
                if let updated { Text(verbatim: "· " + updated) }
            }
            .chatFont(.caption2).foregroundStyle(.secondary).tint(Color.secondary)
            .padding(.vertical, -12)
        } else if let source = card.source {
            Text(verbatim: [source, updated].compactMap(\.self).joined(separator: " · ")).chatFont(.caption2).foregroundStyle(.secondary)
        }
    }

    private func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°" }

    /// What the card shows, worked out from its forecast once.
    struct Shown {
        struct Hour: Identifiable {
            var id: Int
            var label: String
            var spoken: String
            /// The hour the reading is from, labelled Now.
            var now: Bool
            var symbol: String
            var temperature: String
            var chance: Int?
        }

        struct Day: Identifiable {
            var id: Int
            var label: String
            var sky: String
            /// How likely rain is, where it is worth saying.
            var chance: Int?
            var low: Double
            var high: Double
        }

        /// "Orlando · Now": now only while the reading is fresh, the card read back later being that day's.
        var heading: String
        var sky = ""
        /// Feels like, the wind, the humidity: for VoiceOver.
        var details = ""
        var callout: (symbol: String, title: String, detail: String)?
        var hours: [Hour] = []
        /// Whether any hour says how likely rain is.
        var bars = false
        var days: [Day] = []
        var coldest = 0.0
        var warmest = 1.0
        var updated: String?

        /// How long a reading is still "now".
        static let freshFor: TimeInterval = 90 * 60
        /// Hours across the strip.
        static let stripHours = 8

        init(_ card: ReplyCard.Weather, now: Date = .now) {
            func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°" }
            let fresh = card.updatedAt.map { abs($0.timeIntervalSince(now)) < Self.freshFor } ?? false
            let nowWord = String(localized: "Now", comment: "A weather card's reading, and its first hour: now")
            heading = fresh ? card.place + " · " + nowWord : card.place
            if let reading = card.now {
                let range = reading.high.flatMap { high in reading.low.map { low in String(localized: "H \(degrees(high))  L \(degrees(low))") } }
                sky = [reading.summary ?? WeatherCard.name(reading.condition), range].compactMap { $0?.nilIfEmpty }.joined(separator: " · ")
                details = [reading.feelsLike.map { String(localized: "Feels like \(degrees($0))") }, reading.wind.map { String(localized: "Wind \($0)") },
                           reading.humidity.map { String(localized: "Humidity \($0.formatted(.percent))") }].compactMap(\.self).joined(separator: ", ")
            }
            let updatedClock = card.updated.flatMap(ReplyCard.Weather.clock)
            updated = updatedClock.flatMap(Self.date).map { $0.formatted(date: .omitted, time: .shortened) }

            // The strip: "Now", "1 PM", "2", "3", …: the half of the day said where it changes.
            let ahead = Array(card.hours.prefix(Self.stripHours))
            var half: Bool?
            for (i, hour) in ahead.enumerated() {
                let clock = ReplyCard.Weather.clock(hour.time)
                let at = clock.flatMap(Self.date)
                let style: Date.FormatStyle = clock?.minute == 0 ? .dateTime.hour() : .dateTime.hour().minute()
                let full = at.map { $0.formatted(style) } ?? hour.time
                let isNow = i == 0 && fresh && clock != nil && clock?.hour == updatedClock?.hour
                var label = full
                if isNow {
                    label = nowWord
                    half = nil
                } else if let clock, let at {
                    if half == (clock.hour >= 12), clock.minute == 0 { label = at.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted))) }
                    half = clock.hour >= 12
                }
                let spoken = [isNow ? nowWord : full, degrees(hour.temperature), WeatherCard.name(hour.condition).nilIfEmpty,
                              hour.precipitation.map { String(localized: "Rain \($0.formatted(.percent))", comment: "Chance of rain") }]
                hours.append(Hour(id: i, label: label, spoken: spoken.compactMap(\.self).joined(separator: ", "), now: isNow,
                                  symbol: WeatherCard.symbol(hour.condition, night: hour.night == true),
                                  temperature: degrees(hour.temperature), chance: hour.precipitation))
            }
            bars = ahead.contains { $0.precipitation != nil }
            callout = Self.callout(card)

            // The next days, today's left out when the reading has its high and low; on the scale of them all.
            var list = card.days
            if let first = list.first, WeatherCard.day(first.date).map(Calendar.current.isDateInToday) == true, card.now?.high != nil, card.now?.low != nil {
                list.removeFirst()
            }
            days = list.enumerated().map { i, day in
                Day(id: i, label: WeatherCard.dayLabel(day.date), sky: WeatherCard.name(day.condition),
                    chance: day.precipitation.flatMap { $0 >= 20 ? $0 : nil }, low: day.low, high: day.high)
            }
            coldest = card.days.map(\.low).min() ?? 0
            warmest = card.days.map(\.high).max() ?? 1
        }

        /// "Storms likely 2 – 5 PM", "80% at 3 PM · gusts to 30 mph".
        static func callout(_ card: ReplyCard.Weather) -> (symbol: String, title: String, detail: String)? {
            guard let spell = card.spell, let first = ReplyCard.Weather.clock(card.hours[spell.first].time).flatMap(date),
                  let peak = ReplyCard.Weather.clock(card.hours[spell.peak].time).flatMap(date) else { return nil }
            let start = first.formatted(.dateTime.hour())
            var range = start
            if !spell.open, var last = ReplyCard.Weather.clock(card.hours[spell.last].time).flatMap(date) {
                if last < first { last = last.addingTimeInterval(86_400) }   // past midnight
                range = (first ..< last.addingTimeInterval(3600)).formatted(.interval.hour())
            }
            let (symbol, title): (String, String) = switch (spell.kind, spell.open) {
            case (.storms, false): ("cloud.bolt.rain", String(localized: "Storms likely \(range)", comment: "A weather card's callout: storms likely between two hours, e.g. 2 – 5 PM"))
            case (.storms, true): ("cloud.bolt.rain", String(localized: "Storms likely from \(start)", comment: "A weather card's callout: storms likely from an hour on, e.g. 9 PM"))
            case (.snow, false): ("cloud.snow", String(localized: "Snow likely \(range)", comment: "A weather card's callout: snow likely between two hours, e.g. 2 – 5 PM"))
            case (.snow, true): ("cloud.snow", String(localized: "Snow likely from \(start)", comment: "A weather card's callout: snow likely from an hour on, e.g. 9 PM"))
            case (.rain, false): ("cloud.rain", String(localized: "Rain likely \(range)", comment: "A weather card's callout: rain likely between two hours, e.g. 2 – 5 PM"))
            case (.rain, true): ("cloud.rain", String(localized: "Rain likely from \(start)", comment: "A weather card's callout: rain likely from an hour on, e.g. 9 PM"))
            }
            var detail = [String(localized: "\(spell.chance.formatted(.percent)) at \(peak.formatted(.dateTime.hour()))",
                                 comment: "A weather card's callout: the likeliest hour for rain, e.g. 80% at 3 PM")]
            let fahrenheit = card.units == "F"
            if let gusts = spell.gusts, gusts >= (fahrenheit ? 25 : 40) {
                let speed = Measurement(value: gusts.rounded(), unit: fahrenheit ? UnitSpeed.milesPerHour : UnitSpeed.kilometersPerHour)
                    .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
                detail.append(String(localized: "gusts to \(speed)", comment: "A weather card's callout: the strongest wind gust, e.g. gusts to 30 mph"))
            }
            return (symbol, title, detail.joined(separator: " · "))
        }

        /// An hour of today, to be written in the phone's way ("2 PM", "14:00").
        static func date(_ clock: (hour: Int, minute: Int)) -> Date? {
            Calendar.current.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: .now)
        }
    }

    static func symbol(_ condition: ReplyCard.Condition, night: Bool = false) -> String {
        switch condition {
        case .clear: night ? "moon.stars.fill" : "sun.max.fill"
        case .partlyCloudy: night ? "cloud.moon.fill" : "cloud.sun.fill"
        case .cloudy: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .drizzle: "cloud.drizzle.fill"
        case .rain: "cloud.rain.fill"
        case .heavyRain: "cloud.heavyrain.fill"
        case .thunderstorm: "cloud.bolt.rain.fill"
        case .snow: "cloud.snow.fill"
        case .sleet: "cloud.sleet.fill"
        case .hail: "cloud.hail.fill"
        case .wind: "wind"
        case .unknown: "thermometer.medium"
        }
    }

    static func name(_ condition: ReplyCard.Condition) -> String {
        switch condition {
        case .clear: String(localized: "Clear", comment: "Weather")
        case .partlyCloudy: String(localized: "Partly cloudy", comment: "Weather")
        case .cloudy: String(localized: "Cloudy", comment: "Weather")
        case .fog: String(localized: "Fog", comment: "Weather")
        case .drizzle: String(localized: "Drizzle", comment: "Weather")
        case .rain: String(localized: "Rain", comment: "Weather")
        case .heavyRain: String(localized: "Heavy rain", comment: "Weather")
        case .thunderstorm: String(localized: "Thunderstorms", comment: "Weather")
        case .snow: String(localized: "Snow", comment: "Weather")
        case .sleet: String(localized: "Sleet", comment: "Weather")
        case .hail: String(localized: "Hail", comment: "Weather")
        case .wind: String(localized: "Windy", comment: "Weather")
        case .unknown: ""
        }
    }

    /// "2026-10-23" as a weekday ("Fri"), today as "Today"; else as it came. Read as that day on the
    /// phone's calendar: as an instant (midnight UTC) it was the day before anywhere west of Greenwich.
    static func dayLabel(_ text: String) -> String {
        guard let date = day(text) else { return text }
        return Calendar.current.isDateInToday(date) ? String(localized: "Today") : date.formatted(.dateTime.weekday(.abbreviated))
    }

    static func day(_ text: String) -> Date? {
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// A card still being looked up.
private struct LookingUp: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text).chatFont(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Time

/// The time somewhere, kept running: a place's (its zone given or looked up), or with no place the
/// phone's own. Drawn here from the phone's clock, never from what the agent believed the time was.
private struct TimeCard: View {
    let card: ReplyCard.Clock
    var pending = false
    @State private var lookup = CardLookup.shared

    private var zone: TimeZone? {
        if let id = card.timeZone { return TimeZone(identifier: id) }
        return card.place == nil ? .current : nil
    }

    var body: some View {
        if let zone {
            CardBox {
                TimelineView(.everyMinute) { context in
                    face(at: context.date, in: zone)
                }
            }
        } else if let place = card.place, pending || lookup.isLooking(place) {
            CardBox { LookingUp(text: String(localized: "Looking up the time in \(place)…")) }
        }
    }

    private func face(at date: Date, in zone: TimeZone) -> some View {
        var clock = Date.FormatStyle.dateTime.hour().minute()
        clock.timeZone = zone
        var day = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        day.timeZone = zone
        // Somewhere else: how far it is from here; here: the zone's name ("EDT").
        let away = card.place != nil && zone.identifier != TimeZone.current.identifier
        let second = away ? ReplyCard.Clock.difference(zone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date))
            : zone.abbreviation(for: date)
        return HStack(alignment: .center, spacing: 12) {
            ClockFace(date: date, zone: zone).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 0) {
                Text(card.place ?? String(localized: "Your time")).chatFont(.subheadline, weight: .semibold)
                Text(date.formatted(day)).chatFont(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 0) {
                Text(date.formatted(clock)).chatFont(size: 34, weight: .semibold).monospacedDigit()
                if let second { Text(second).chatFont(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension ReplyCard.Clock {
    /// "Same time", "4 hr behind", "5½ hr ahead": than here.
    static func difference(_ seconds: Int) -> String {
        guard seconds != 0 else { return String(localized: "Same time", comment: "A place's clock shows the same time as here") }
        let hours = Double(abs(seconds)) / 3600
        let whole = Int(hours)
        let part = hours - Double(whole)
        let fraction = [0.25: "¼", 0.5: "½", 0.75: "¾"][part]
        let amount = part == 0 ? "\(whole)" : fraction.map { (whole == 0 ? "" : "\(whole)") + $0 } ?? hours.formatted(.number.precision(.significantDigits(1 ... 2)))
        return seconds > 0 ? String(localized: "\(amount) hr ahead", comment: "Hours a place's clock is ahead of here") : String(localized: "\(amount) hr behind", comment: "Hours a place's clock is behind here")
    }
}

/// A small clock with hands, dark through the night there.
private struct ClockFace: View {
    let date: Date
    let zone: TimeZone

    var body: some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = Double(parts.hour ?? 0), minute = Double(parts.minute ?? 0)
        let night = hour < 6 || hour >= 19
        return Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            func hand(_ turn: Double, _ length: CGFloat, _ width: CGFloat) {
                let angle = turn * 2 * .pi - .pi / 2
                var path = Path()
                path.move(to: centre)
                path.addLine(to: CGPoint(x: centre.x + cos(angle) * radius * length, y: centre.y + sin(angle) * radius * length))
                context.stroke(path, with: .color(night ? .white : .primary), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            for tick in 0 ..< 12 {
                let angle = Double(tick) / 12 * 2 * .pi
                let point = CGPoint(x: centre.x + cos(angle) * radius * 0.8, y: centre.y + sin(angle) * radius * 0.8)
                context.fill(Path(ellipseIn: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)),
                             with: .color(night ? .white.opacity(0.6) : .secondary))
            }
            hand((hour.truncatingRemainder(dividingBy: 12) + minute / 60) / 12, 0.5, 2.5)
            hand(minute / 60, 0.72, 1.6)
        }
        .background(Circle().fill(night ? Color.indigo.opacity(0.85) : Color.secondary.opacity(0.12)))
        .accessibilityHidden(true)
    }
}

/// A day's range of temperatures, on the scale of the whole forecast.
private struct TemperatureBar: View {
    let low: Double, high: Double, from: Double, to: Double

    var body: some View {
        GeometryReader { proxy in
            let span = max(to - from, 1)
            let start = (low - from) / span * proxy.size.width
            let width = max((high - low) / span * proxy.size.width, 4)
            Capsule().fill(.quaternary)
                .overlay(alignment: .leading) {
                    Capsule().fill(Self.warming).frame(width: width).offset(x: start)
                }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    /// Cool blue to warm amber, as designed.
    private static let warming = LinearGradient(colors: [Color(red: 0.353, green: 0.690, blue: 0.941), Color(red: 0.961, green: 0.722, blue: 0.239)],
                                                startPoint: .leading, endPoint: .trailing)
}

/// How likely rain is in an hour, as a bar to scale: 40 pt for certain, blue once it is likely.
private struct RainBar: View {
    let chance: Int?

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 2, bottomTrailingRadius: 2, topTrailingRadius: 4)
            .fill((chance ?? 0) >= ReplyCard.Weather.Spell.likely ? Color.blue : Color.primary.opacity(0.2))
            .frame(width: 12, height: chance.map { max(3, CGFloat($0) * 0.4) } ?? 0)
            .frame(height: 40, alignment: .bottom)
            .accessibilityHidden(true)
    }
}
