import MapKit
import SwiftUI

/// A reply's cards under its words (`ReplyCards`): a map, a list of places, the weather. Drawn
/// here with MapKit and the system's weather symbols; a map or a place opens in Apple Maps.
struct ReplyCardsView: View {
    let cards: [ReplyCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                switch card {
                case let .map(map): MapCard(card: map)
                case let .places(places): PlacesCard(card: places)
                case let .weather(weather): WeatherCard(card: weather)
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}

/// The frame every card sits in.
private struct CardBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) }
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
            if let title = card.title { Text(title).font(.subheadline.weight(.semibold)) }
            MapPicture(places: pins, route: route)
                .frame(height: 190)
                .clipShape(.rect(cornerRadius: 12))
                .contentShape(.rect)
                .onTapGesture { open() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(card.title ?? "Map of \(pins.map(\.name).formatted())")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(card.route == nil ? "Opens it in Maps" : "Opens the directions in Maps")
            HStack(spacing: 10) {
                if let r = card.route {
                    Label(Self.modeName(r.mode), systemImage: Self.modeSymbol(r.mode)).font(.footnote.weight(.medium))
                    if let route {
                        Text("\(Self.duration(route.expectedTravelTime)) · \(Self.distance(route.distance))").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("\(r.from?.name ?? "From here") to \(r.to.name)").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill", action: open)
                        .font(.footnote.weight(.semibold)).buttonStyle(.borderless)
                } else {
                    Text(pins.map(\.name).formatted()).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Open in Maps", systemImage: "map", action: open).font(.footnote.weight(.semibold)).buttonStyle(.borderless)
                }
            }
        }
        .task(id: pins) {
            await lookup.look(up: pins)
            await findRoute()
        }
    }

    /// Between two named places, the route itself on the map; from where the person is, Maps
    /// works it out when it opens (the app never asks for the phone's location).
    private func findRoute() async {
        guard let r = card.route, let from = r.from, let a = lookup.mapItem(from), let b = lookup.mapItem(r.to) else { return }
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

    static func modeName(_ mode: ReplyCard.Route.Mode) -> String {
        switch mode { case .driving: "Drive"; case .walking: "Walk"; case .transit: "Transit"; case .cycling: "Cycle" }
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
        Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

/// The map itself: still (it sits in a scrolling chat), the pins, and the route when there is one.
private struct MapPicture: View {
    let places: [ReplyCard.Place]
    let route: MKRoute?
    /// The pins numbered as the list under them is.
    var numbered = false
    @State private var lookup = PlaceLookup.shared

    var body: some View {
        let shown = places.compactMap { place in lookup.coordinate(of: place).map { (place, $0) } }
        Map(initialPosition: .automatic, interactionModes: []) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
                if numbered, let number = places.firstIndex(of: item.0) {
                    Marker(item.0.name, monogram: Text("\(number + 1)"), coordinate: item.1)
                } else {
                    Marker(item.0.name, systemImage: index == shown.count - 1 && route != nil ? "flag.fill" : "mappin", coordinate: item.1)
                }
            }
            if let route { MapPolyline(route.polyline).stroke(.blue, lineWidth: 5) }
        }
        .id(shown.count + (route == nil ? 0 : 100))   // framed again once looked-up places arrive
        .overlay {
            if shown.isEmpty { ProgressView().controlSize(.small) }
        }
    }
}

// MARK: - Places

private struct PlacesCard: View {
    let card: ReplyCard.Places
    @State private var lookup = PlaceLookup.shared

    var body: some View {
        CardBox {
            if let title = card.title { Text(title).font(.subheadline.weight(.semibold)) }
            if card.places.count > 1 {
                MapPicture(places: card.places, route: nil, numbered: true)
                    .frame(height: 140)
                    .clipShape(.rect(cornerRadius: 12))
                    .onTapGesture { MKMapItem.openMaps(with: card.places.compactMap(lookup.mapItem)) }
                    .accessibilityHidden(true)
            }
            ForEach(Array(card.places.enumerated()), id: \.offset) { index, place in
                if index > 0 { Divider() }
                row(place, index: index)
            }
        }
        .task(id: card.places) { await lookup.look(up: card.places) }
    }

    private func row(_ place: ReplyCard.Place, index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.red, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).font(.subheadline.weight(.semibold))
                let line = [place.category, place.rating.map { String(format: "★ %.1f", $0) }].compactMap(\.self)
                if !line.isEmpty { Text(line.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                if let address = place.address { Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if let note = place.note { Text(note).font(.caption).lineLimit(3) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                if let phone = place.phone, let url = URL(string: "tel:" + phone.filter { "+0123456789".contains($0) }) {
                    Link(destination: url) { Image(systemName: "phone.fill") }.accessibilityLabel("Call \(place.name)")
                }
                if let site = place.url, let url = URL(string: site) {
                    Link(destination: url) { Image(systemName: "safari") }.accessibilityLabel("\(place.name)'s website")
                }
                Button { lookup.mapItem(place)?.openInMaps() } label: { Image(systemName: "map") }
                    .buttonStyle(.borderless)
                    .disabled(lookup.coordinate(of: place) == nil)
                    .accessibilityLabel("Open \(place.name) in Maps")
            }
            .font(.callout)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Weather

private struct WeatherCard: View {
    let card: ReplyCard.Weather

    var body: some View {
        CardBox {
            if let now = card.now {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: Self.symbol(now.condition)).symbolRenderingMode(.multicolor).font(.system(size: 40))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(card.place).font(.subheadline.weight(.semibold))
                        Text(now.summary ?? Self.name(now.condition)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(degrees(now.temperature)).font(.system(size: 34, weight: .semibold)).monospacedDigit()
                        if let high = now.high, let low = now.low {
                            Text("H \(degrees(high))  L \(degrees(low))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                let details = [now.feelsLike.map { "Feels like \(degrees($0))" }, now.wind.map { "Wind \($0)" },
                               now.humidity.map { "Humidity \($0)%" }, now.precipitation.map { "Rain \($0)%" }].compactMap(\.self)
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(card.place).font(.subheadline.weight(.semibold))
            }
            if !card.hours.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(Array(card.hours.enumerated()), id: \.offset) { _, hour in
                            VStack(spacing: 4) {
                                Text(Self.hourLabel(hour.time)).font(.caption2).foregroundStyle(.secondary)
                                Image(systemName: Self.symbol(hour.condition)).symbolRenderingMode(.multicolor).font(.callout).frame(height: 22)
                                Text(degrees(hour.temperature)).font(.caption.weight(.medium)).monospacedDigit()
                                if let rain = hour.precipitation, rain > 0 { Text("\(rain)%").font(.caption2).foregroundStyle(.blue) }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            if !card.days.isEmpty {
                Divider()
                let low = card.days.map(\.low).min() ?? 0, high = card.days.map(\.high).max() ?? 1
                ForEach(Array(card.days.enumerated()), id: \.offset) { _, day in
                    HStack(spacing: 10) {
                        Text(Self.dayLabel(day.date)).font(.caption.weight(.medium)).frame(width: 44, alignment: .leading)
                        Image(systemName: Self.symbol(day.condition)).symbolRenderingMode(.multicolor).frame(width: 24)
                        Text(day.precipitation.map { $0 > 0 ? "\($0)%" : "" } ?? "").font(.caption2).foregroundStyle(.blue).frame(width: 32, alignment: .leading)
                        Text(degrees(day.low)).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 34, alignment: .trailing)
                        TemperatureBar(low: day.low, high: day.high, from: low, to: high)
                        Text(degrees(day.high)).font(.caption.weight(.medium)).monospacedDigit().frame(width: 34, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let source = card.source { Text(source).font(.caption2).foregroundStyle(.tertiary) }
        }
    }

    private func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°" }

    static func symbol(_ condition: ReplyCard.Condition) -> String {
        switch condition {
        case .clear: "sun.max.fill"
        case .partlyCloudy: "cloud.sun.fill"
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
        case .clear: "Clear"
        case .partlyCloudy: "Partly cloudy"
        case .cloudy: "Cloudy"
        case .fog: "Fog"
        case .drizzle: "Drizzle"
        case .rain: "Rain"
        case .heavyRain: "Heavy rain"
        case .thunderstorm: "Thunderstorms"
        case .snow: "Snow"
        case .sleet: "Sleet"
        case .hail: "Hail"
        case .wind: "Windy"
        case .unknown: ""
        }
    }

    /// "14:00", "2026-10-22T14:00" or "2 PM" as the phone writes an hour; else as it came.
    static func hourLabel(_ text: String) -> String {
        let clock = text.split(separator: "T").last.map(String.init) ?? text
        let parts = clock.split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]), (0 ... 23).contains(hour) else { return text }
        var components = DateComponents()
        components.hour = hour
        components.minute = Int(parts[1].prefix(2)) ?? 0
        guard let date = Calendar.current.date(from: components) else { return text }
        return date.formatted(.dateTime.hour())
    }

    /// "2026-10-23" as a weekday ("Thu"), today as "Today"; else as it came.
    static func dayLabel(_ text: String) -> String {
        guard let date = try? Date(String(text.prefix(10)), strategy: .iso8601.year().month().day()) else { return text }
        return Calendar.current.isDateInToday(date) ? "Today" : date.formatted(.dateTime.weekday(.abbreviated))
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
                    Capsule().fill(LinearGradient(colors: [.cyan, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                        .frame(width: width).offset(x: start)
                }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}
