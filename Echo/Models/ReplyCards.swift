import Foundation

/// Cards a reply shows beside its words (his ask 2026-10-22, after Conduit's rich cards): a map, a
/// list of places, the weather, the time. The agent asks for them with the Redde plugin's
/// `redde_show` tool, whose arguments are `{"cards": [...]}`; the app reads them from the call
/// itself, live and when a conversation is read back, on either connection. Our own format:
/// `ReplyCards.parse` is lenient (a number as text, a missing optional field, an unknown key) and
/// drops a card or a place it can't use rather than the whole call.
///
/// A weather or a time card names only its place (2026-10-23: agents guessed the weather, or read a
/// search result hours old, and told the time in another zone). The plugin, from 1.7.0, looks it up
/// and answers with the cards filled in, read from its answer where there is one; else the phone
/// looks it up itself (`CardLookup`), for a reply that is coming in only.
nonisolated enum ReplyCard: Codable, Equatable, Sendable {
    case map(Map)
    case places(Places)
    case weather(Weather)
    case time(Clock)

    /// The time somewhere, drawn live on the phone: a place's, or with none the phone's own.
    nonisolated struct Clock: Codable, Equatable, Sendable {
        var place: String?
        /// An IANA zone ("Europe/Lisbon"): given, or looked up from the place.
        var timeZone: String?
    }

    /// Places on a map, and a way between two of them.
    nonisolated struct Map: Codable, Equatable, Sendable {
        var title: String?
        var places: [Place]
        var route: Route?
    }

    nonisolated struct Route: Codable, Equatable, Sendable {
        enum Mode: String, Codable, Sendable, CaseIterable { case driving, walking, transit, cycling }
        /// Nil: from where the person is.
        var from: Place?
        var to: Place
        var mode: Mode
    }

    /// A list of places: what is near, what was found.
    nonisolated struct Places: Codable, Equatable, Sendable {
        var title: String?
        var places: [Place]
    }

    /// A place as the agent knows it. Without coordinates, the phone looks it up by its name and
    /// address (`PlaceLookup`).
    nonisolated struct Place: Codable, Equatable, Sendable, Hashable {
        var name: String
        var address: String?
        var latitude: Double?
        var longitude: Double?
        var category: String?
        /// Out of five.
        var rating: Double?
        var note: String?
        var phone: String?
        var url: String?

        var hasCoordinate: Bool {
            guard let latitude, let longitude else { return false }
            return (-90 ... 90).contains(latitude) && (-180 ... 180).contains(longitude)
        }
    }

    nonisolated struct Weather: Codable, Equatable, Sendable {
        var place: String
        /// "C" or "F": what the numbers are in.
        var units: String
        var now: Now?
        var hours: [Hour]
        var days: [Day]
        var source: String?

        /// Whether there is anything to draw: a card with only its place is waiting for its forecast.
        var hasReading: Bool { now != nil || !hours.isEmpty || !days.isEmpty }

        nonisolated struct Now: Codable, Equatable, Sendable {
            var temperature: Double
            var condition: Condition
            var feelsLike: Double?
            var high: Double?
            var low: Double?
            var wind: String?
            var humidity: Int?
            var precipitation: Int?
            var summary: String?
            /// After dark there: a clear sky is drawn with the moon.
            var night: Bool?
        }

        nonisolated struct Hour: Codable, Equatable, Sendable {
            var time: String
            var temperature: Double
            var condition: Condition
            var precipitation: Int?
            var night: Bool?
        }

        nonisolated struct Day: Codable, Equatable, Sendable {
            var date: String
            var high: Double
            var low: Double
            var condition: Condition
            var precipitation: Int?
        }
    }

    nonisolated enum Condition: String, Codable, Sendable, CaseIterable {
        case clear, partlyCloudy = "partly_cloudy", cloudy, fog, drizzle, rain, heavyRain = "heavy_rain", thunderstorm,
             snow, sleet, hail, wind, unknown

        /// Read leniently: "Partly cloudy", "partly-cloudy", "PARTLY_CLOUDY", "sunny", "storm".
        init(lenient text: String?) {
            let key = (text ?? "").lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
            if let exact = Condition(rawValue: key) { self = exact; return }
            switch key {
            case "sunny", "fair", "mostly_sunny": self = .clear
            case "mostly_cloudy", "partly_sunny": self = .partlyCloudy
            case "overcast": self = .cloudy
            case "mist", "haze", "smoke": self = .fog
            case "showers", "light_rain": self = .rain
            case "storm", "storms", "thunderstorms", "thunder": self = .thunderstorm
            case "light_snow", "heavy_snow", "flurries": self = .snow
            case "freezing_rain", "ice": self = .sleet
            case "windy", "breezy": self = .wind
            default: self = .unknown
            }
        }
    }
}

nonisolated enum ReplyCards {
    /// The Redde plugin's tool that shows them.
    static let tool = "redde_show"
    static let maxCards = 4
    static let maxPlaces = 12

    /// The cards a call asks for: nil when it isn't the tool's, empty when none of its cards can be used.
    static func cards(fromCall name: String, args: JSONValue?) -> [ReplyCard]? {
        guard name == tool else { return nil }
        return parse(args)
    }

    /// The same from a step whose arguments were kept as JSON text (`ToolActivity.args`). The
    /// plugin's answer, where it can be read, has the cards filled in (from 1.7.0: the weather and
    /// the time looked up), and wins over what the agent wrote.
    static func cards(from step: ToolActivity) -> [ReplyCard]? {
        guard step.name == tool, step.status != .failed else { return nil }
        if let output = step.output, let answer = try? JSONValue.parse(Data(output.utf8)), answer["cards"]?.array != nil {
            return parse(answer)
        }
        guard let text = step.args, let args = try? JSONValue.parse(Data(text.utf8)) else { return nil }
        return parse(args)
    }

    /// Where the forecasts the plugin and the phone look up come from, credited on the card.
    static let lookedUpSource = "Open-Meteo.com"

    /// The temperature units this phone's person reads: "F" or "C".
    static var preferredUnits: String {
        UnitTemperature(forLocale: .current, usage: .weather) == .fahrenheit ? "F" : "C"
    }

    static func parse(_ args: JSONValue?) -> [ReplyCard] {
        let list = args?["cards"]?.array ?? (args?["type"] != nil ? [args!] : [])
        return Array(list.compactMap(card).prefix(maxCards))
    }

    /// Every reply's cards from its steps, where it has none yet: a conversation read back.
    static func resolve(_ messages: inout [Message]) {
        for m in messages.indices where messages[m].role == .assistant && messages[m].cards == nil {
            let found = messages[m].tools.compactMap(cards(from:)).flatMap { $0 }
            if !found.isEmpty { messages[m].cards = found }
        }
    }

    // MARK: - Reading one card

    static func card(_ value: JSONValue) -> ReplyCard? {
        switch text(value["type"])?.lowercased() {
        case "map":
            let places = placeList(value["places"] ?? value["pins"])
            let route = route(value["route"])
            guard !places.isEmpty || route != nil else { return nil }
            return .map(.init(title: text(value["title"]), places: places, route: route))
        case "places", "place":
            var places = placeList(value["places"])
            if places.isEmpty, let one = place(value["place"] ?? value) { places = [one] }
            guard !places.isEmpty else { return nil }
            return .places(.init(title: text(value["title"]), places: places))
        case "weather":
            return weather(value).map(ReplyCard.weather)
        case "time", "clock":
            let zone = text(value["timezone"] ?? value["time_zone"] ?? value["timeZone"]).flatMap { TimeZone(identifier: $0)?.identifier }
            return .time(.init(place: text(value["place"] ?? value["location"]).map { String($0.prefix(80)) }, timeZone: zone))
        default:
            return nil
        }
    }

    static func placeList(_ value: JSONValue?) -> [ReplyCard.Place] {
        Array((value?.array ?? []).compactMap(place).prefix(maxPlaces))
    }

    static func place(_ value: JSONValue?) -> ReplyCard.Place? {
        guard let value else { return nil }
        if let name = value.string?.nilIfEmpty { return .init(name: String(name.prefix(120))) }   // just a name
        guard let name = text(value["name"] ?? value["title"]) else { return nil }
        var place = ReplyCard.Place(name: String(name.prefix(120)))
        place.address = text(value["address"])
        place.latitude = number(value["latitude"] ?? value["lat"])
        place.longitude = number(value["longitude"] ?? value["lon"] ?? value["lng"])
        if !place.hasCoordinate { place.latitude = nil; place.longitude = nil }
        place.category = text(value["category"])
        place.rating = number(value["rating"]).map { min(5, max(0, $0)) }
        place.note = text(value["note"] ?? value["description"]).map { String($0.prefix(300)) }
        place.phone = text(value["phone"])
        place.url = text(value["url"] ?? value["website"]).flatMap { URL(string: $0)?.scheme?.hasPrefix("http") == true ? $0 : nil }
        return place
    }

    static func route(_ value: JSONValue?) -> ReplyCard.Route? {
        guard let value, let to = place(value["to"]) else { return nil }
        let mode = ReplyCard.Route.Mode(rawValue: text(value["mode"])?.lowercased() ?? "") ?? .driving
        let from = text(value["from"])?.lowercased() == "here" ? nil : place(value["from"])
        return .init(from: from, to: to, mode: mode)
    }

    static func weather(_ value: JSONValue) -> ReplyCard.Weather? {
        guard let place = text(value["place"] ?? value["location"]) else { return nil }
        let units = text(value["units"]).map { $0.uppercased().hasPrefix("F") ? "F" : "C" } ?? preferredUnits
        var now: ReplyCard.Weather.Now?
        // A reading names its condition: a temperature with none is a placeholder (the agent once sent
        // 0 and "" while its reply said 85°F and clear), not drawn.
        if let n = value["now"] ?? value["current"], let temperature = number(n["temperature"] ?? n["temp"]), text(n["condition"]) != nil {
            now = .init(temperature: temperature, condition: .init(lenient: text(n["condition"])),
                        feelsLike: number(n["feels_like"] ?? n["feelsLike"]), high: number(n["high"]), low: number(n["low"]),
                        wind: text(n["wind"]), humidity: number(n["humidity"]).map { Int($0.rounded()) },
                        precipitation: number(n["precipitation"] ?? n["chance_of_rain"]).map { Int($0.rounded()) },
                        summary: text(n["summary"]).map { String($0.prefix(200)) }, night: n["night"]?.bool)
        }
        let hours: [ReplyCard.Weather.Hour] = (value["hours"]?.array ?? []).compactMap { h in
            guard let time = text(h["time"]), let temperature = number(h["temperature"] ?? h["temp"]), text(h["condition"]) != nil else { return nil }
            return .init(time: time, temperature: temperature, condition: .init(lenient: text(h["condition"])),
                         precipitation: number(h["precipitation"]).map { Int($0.rounded()) }, night: h["night"]?.bool)
        }
        let days: [ReplyCard.Weather.Day] = (value["days"]?.array ?? []).compactMap { d in
            guard let date = text(d["date"] ?? d["day"]), let high = number(d["high"]), let low = number(d["low"]), text(d["condition"]) != nil else { return nil }
            return .init(date: date, high: high, low: low, condition: .init(lenient: text(d["condition"])),
                         precipitation: number(d["precipitation"]).map { Int($0.rounded()) })
        }
        // Exactly 0 and nothing else read with it, on a card with nothing more: a placeholder too (the
        // agent once sent 0 and "clear" without looking the weather up). A real 0 comes with its other numbers.
        if let n = now, n.temperature == 0, n.high == nil, n.low == nil, n.feelsLike == nil, n.wind == nil, n.humidity == nil,
           n.precipitation == nil, n.summary == nil, hours.isEmpty, days.isEmpty { now = nil }
        // Nothing read is kept all the same: the place is all a card needs to be looked up. Drawn
        // only once it has a forecast (`hasReading`).
        return .init(place: String(place.prefix(80)), units: units, now: now, hours: Array(hours.prefix(24)), days: Array(days.prefix(10)),
                     source: text(value["source"]))
    }

    private static func text(_ value: JSONValue?) -> String? {
        if let s = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        if let n = value?.number { return n == n.rounded() ? String(Int(n)) : String(n) }
        return nil
    }

    private static func number(_ value: JSONValue?) -> Double? {
        if let n = value?.number, n.isFinite { return n }
        if let s = value?.string?.trimmingCharacters(in: .whitespaces) {
            return Double(s.replacingOccurrences(of: "°", with: "").replacingOccurrences(of: "%", with: "").trimmingCharacters(in: CharacterSet.letters.union(.whitespaces)))
        }
        return nil
    }
}
