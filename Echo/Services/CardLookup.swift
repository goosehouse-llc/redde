import Foundation
import MapKit

/// Weather and time cards filled in on the phone, where the plugin's answer didn't fill them: a
/// plugin older than 1.7.0, or an answer that can't be read while the reply comes in. The place is
/// found with MapKit (on the phone, as the map cards' places are), its forecast asked of Open-Meteo
/// by coordinates only, the same service the plugin asks, so the card and what the agent said agree.
/// Only for a reply coming in (`Conversation.fillCards`): a card read back later stays as it was
/// saved, its weather being that day's.
@MainActor
@Observable
final class CardLookup {
    static let shared = CardLookup()

    /// A place as MapKit finds it: where it is and its time zone.
    struct Found: Sendable {
        var coordinate: CLLocationCoordinate2D
        var timeZone: String?
    }

    /// The places being looked up now: their cards say so instead of drawing nothing.
    private(set) var looking: Set<String> = []
    @ObservationIgnored private var forecasts: [String: (at: Date, weather: ReplyCard.Weather)] = [:]
    @ObservationIgnored private var zones: [String: String] = [:]
    @ObservationIgnored private let find: (String) async -> Found?
    @ObservationIgnored private let fetch: (URL) async -> Data?

    /// MapKit and the network; a test passes its own.
    init(find: @escaping (String) async -> Found? = CardLookup.mapKit, fetch: @escaping (URL) async -> Data? = CardLookup.network) {
        self.find = find
        self.fetch = fetch
    }

    func isLooking(_ place: String) -> Bool { looking.contains(Self.key(place)) }

    static func needsLookup(_ card: ReplyCard) -> Bool {
        switch card {
        case let .weather(weather): weather.source != ReplyCards.lookedUpSource
        case let .time(clock): clock.timeZone == nil && clock.place != nil
        case .map, .places, .review, .choice, .checklist, .form: false
        }
    }

    /// The cards with each weather and time card filled in where it can be; the rest as they were.
    func fill(_ cards: [ReplyCard]) async -> [ReplyCard] {
        var out = cards
        for i in out.indices where Self.needsLookup(out[i]) {
            switch out[i] {
            case let .weather(weather):
                if let found = await forecast(weather) { out[i] = .weather(found) }
            case let .time(clock):
                if let place = clock.place, let zone = await zone(of: place) { out[i] = .time(.init(place: place, timeZone: zone)) }
            case .map, .places, .review, .choice, .checklist, .form:
                break
            }
        }
        return out
    }

    private func forecast(_ card: ReplyCard.Weather) async -> ReplyCard.Weather? {
        let key = Self.key(card.place) + "|" + card.units
        if let kept = forecasts[key], kept.at.timeIntervalSinceNow > -600 { return kept.weather }
        looking.insert(Self.key(card.place))
        defer { looking.remove(Self.key(card.place)) }
        guard let found = await find(card.place),
              let data = await fetch(OpenMeteo.url(at: found.coordinate, units: card.units)),
              let json = try? JSONValue.parse(data),
              let weather = OpenMeteo.weather(json, place: card.place, units: card.units) else { return nil }
        forecasts[key] = (.now, weather)
        return weather
    }

    private func zone(of place: String) async -> String? {
        if let kept = zones[Self.key(place)] { return kept }
        looking.insert(Self.key(place))
        defer { looking.remove(Self.key(place)) }
        guard let zone = await find(place)?.timeZone else { return nil }
        zones[Self.key(place)] = zone
        return zone
    }

    static func mapKit(_ place: String) async -> Found? {
        guard let request = MKGeocodingRequest(addressString: place), let item = try? await request.mapItems.first else { return nil }
        return Found(coordinate: item.location.coordinate, timeZone: item.timeZone?.identifier)
    }

    static func network(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private static func key(_ place: String) -> String { place.lowercased().split(separator: " ").joined(separator: " ") }
}

/// Open-Meteo's forecast (api.open-meteo.com, free without a key; data under CC BY 4.0) as a
/// weather card: now, the next 12 hours, 7 days. The plugin's `forecast.py` reads it the same way.
nonisolated enum OpenMeteo {
    static func url(at coordinate: CLLocationCoordinate2D, units: String) -> URL {
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        let round = { (value: Double) in String(format: "%.3f", value) }
        parts.queryItems = [
            .init(name: "latitude", value: round(coordinate.latitude)), .init(name: "longitude", value: round(coordinate.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,wind_direction_10m,is_day"),
            .init(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability,is_day"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "temperature_unit", value: units == "F" ? "fahrenheit" : "celsius"),
            .init(name: "wind_speed_unit", value: units == "F" ? "mph" : "kmh"),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "7"), .init(name: "forecast_hours", value: "12"),
        ]
        return parts.url!
    }

    static func weather(_ json: JSONValue, place: String, units: String) -> ReplyCard.Weather? {
        let now = json["current"], hourly = json["hourly"], daily = json["daily"]
        guard let temperature = now?["temperature_2m"]?.number else { return nil }
        func at(_ list: JSONValue?, _ i: Int) -> JSONValue? {
            guard let list = list?.array, i < list.count else { return nil }
            return list[i]
        }
        let wind = now?["wind_speed_10m"]?.number.map { speed in
            let measured = Measurement(value: speed.rounded(), unit: units == "F" ? UnitSpeed.milesPerHour : UnitSpeed.kilometersPerHour)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
            return [measured, compass(now?["wind_direction_10m"]?.number)].filter { !$0.isEmpty }.joined(separator: " ")
        }
        let reading = ReplyCard.Weather.Now(
            temperature: temperature, condition: condition(now?["weather_code"]?.number),
            feelsLike: now?["apparent_temperature"]?.number,
            high: at(daily?["temperature_2m_max"], 0)?.number, low: at(daily?["temperature_2m_min"], 0)?.number,
            wind: wind, humidity: now?["relative_humidity_2m"]?.number.map { Int($0.rounded()) },
            precipitation: at(hourly?["precipitation_probability"], 0)?.number.map { Int($0.rounded()) },
            summary: nil, night: now?["is_day"]?.number.map { $0 == 0 })
        let hours: [ReplyCard.Weather.Hour] = (hourly?["time"]?.array ?? []).prefix(12).enumerated().compactMap { i, time in
            guard let time = time.string, let temperature = at(hourly?["temperature_2m"], i)?.number else { return nil }
            return .init(time: time, temperature: temperature, condition: condition(at(hourly?["weather_code"], i)?.number),
                         precipitation: at(hourly?["precipitation_probability"], i)?.number.map { Int($0.rounded()) },
                         night: at(hourly?["is_day"], i)?.number.map { $0 == 0 })
        }
        let days: [ReplyCard.Weather.Day] = (daily?["time"]?.array ?? []).prefix(7).enumerated().compactMap { i, date in
            guard let date = date.string, let high = at(daily?["temperature_2m_max"], i)?.number,
                  let low = at(daily?["temperature_2m_min"], i)?.number else { return nil }
            return .init(date: date, high: high, low: low, condition: condition(at(daily?["weather_code"], i)?.number),
                         precipitation: at(daily?["precipitation_probability_max"], i)?.number.map { Int($0.rounded()) })
        }
        return .init(place: place, units: units, now: reading, hours: hours, days: days, source: ReplyCards.lookedUpSource)
    }

    /// A WMO weather code as the card's condition.
    static func condition(_ code: Double?) -> ReplyCard.Condition {
        switch code.map({ Int($0) }) ?? -1 {
        case 0, 1: .clear
        case 2: .partlyCloudy
        case 3: .cloudy
        case 45, 48: .fog
        case 51, 53, 55: .drizzle
        case 56, 57, 66, 67: .sleet
        case 61, 63, 80, 81: .rain
        case 65, 82: .heavyRain
        case 71, 73, 75, 77, 85, 86: .snow
        case 95, 96, 99: .thunderstorm
        default: .cloudy
        }
    }

    private static func compass(_ degrees: Double?) -> String {
        guard let degrees else { return "" }
        let points = [
            String(localized: "N", comment: "Compass point, for the wind's direction: north"),
            String(localized: "NE", comment: "Compass point, for the wind's direction: north-east"),
            String(localized: "E", comment: "Compass point, for the wind's direction: east"),
            String(localized: "SE", comment: "Compass point, for the wind's direction: south-east"),
            String(localized: "S", comment: "Compass point, for the wind's direction: south"),
            String(localized: "SW", comment: "Compass point, for the wind's direction: south-west"),
            String(localized: "W", comment: "Compass point, for the wind's direction: west"),
            String(localized: "NW", comment: "Compass point, for the wind's direction: north-west"),
        ]
        return points[Int((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 45 + 0.5) % 8]
    }
}
