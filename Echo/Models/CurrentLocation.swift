import CoreLocation
import Foundation

/// Where the person is, for the agent (asked 2026-10-30: "can we build in a Current Location toggle,
/// so it knows where we are for maps"): Settings → Agent → Current Location, off until turned on,
/// this device's own (not synced: the permission is the device's). On, the agent hears roughly
/// where the person is, the neighbourhood and town in words and the coordinates to three places
/// (about 100 m), never the fix itself, and only with a question about places, directions, maps
/// or the weather: on the Hermes API in the turn's instructions, on the Dashboard as a note on the
/// message, which Redde hides (`strip`). Sending never waits for it: the place is kept from the
/// last fix (`CurrentLocationService`), and one older than `freshFor` isn't sent.
nonisolated enum CurrentLocation {
    /// Settings' key; read straight from the defaults, so a transport off the main actor has it too.
    static let key = "currentLocation"
    /// Where the last fix was, in words and rounded: the place the agent is told.
    static let keptKey = "currentLocationKept"
    /// How old a kept place may be and still be sent.
    static let freshFor: TimeInterval = 30 * 60
    /// The least time between two fixes asked for (each one asked at reduced accuracy, once).
    static let askEvery: TimeInterval = 3 * 60
    /// How far the phone moves before its place is put in words again.
    static let movedFar: CLLocationDistance = 250

    /// A place as the agent hears it.
    struct Here: Codable, Equatable, Sendable {
        /// "Thornton Park, Orlando, FL"; nil where it couldn't be put in words (offline).
        var words: String?
        /// Rounded to three places (`rounded`).
        var latitude: Double
        var longitude: Double
        /// When the fix was taken.
        var at: Date

        init(words: String?, latitude: Double, longitude: Double, at: Date) {
            self.words = words.map(CurrentLocation.tidy).flatMap { $0.isEmpty ? nil : $0 }
            self.latitude = CurrentLocation.rounded(latitude)
            self.longitude = CurrentLocation.rounded(longitude)
            self.at = at
        }

        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }

    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    // MARK: Kept

    static func kept(in defaults: UserDefaults = .standard) -> Here? {
        defaults.data(forKey: keptKey).flatMap { try? JSONDecoder().decode(Here.self, from: $0) }
    }

    static func keep(_ here: Here, in defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(here), forKey: keptKey)
    }

    /// Turned off: the place isn't kept either.
    static func forget(in defaults: UserDefaults = .standard) { defaults.removeObject(forKey: keptKey) }

    /// The kept place, when it is recent enough to send.
    static func fresh(_ here: Here?, now: Date = .now) -> Here? {
        guard let here, now.timeIntervalSince(here.at) < freshFor, now.timeIntervalSince(here.at) > -60 else { return nil }
        return here
    }

    // MARK: Rounding and words

    /// Three decimal places: about 110 m north–south, less east–west.
    static func rounded(_ degrees: Double) -> Double { (degrees * 1000).rounded() / 1000 }

    /// The place in words: the neighbourhood, then the town with its state or country, as Apple's
    /// maps name them ("Thornton Park" and "Orlando, FL"); the neighbourhood left out where it is the town.
    static func words(neighbourhood: String?, town: String?) -> String? {
        let town = town.map(tidy).flatMap { $0.isEmpty ? nil : $0 }
        guard let neighbourhood = neighbourhood.map(tidy), !neighbourhood.isEmpty,
              town?.localizedCaseInsensitiveContains(neighbourhood) != true else { return town }
        return [neighbourhood, town].compactMap(\.self).joined(separator: ", ")
    }

    /// One line, not too long: what goes in a note must not break it.
    static func tidy(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces).prefix(120))
    }

    // MARK: Telling the agent

    /// A question about places, directions, maps or the weather, in English, as the plugin's own
    /// tests are: "coffee near me", "how far is the airport", "will it rain".
    static func asksPlace(_ text: String) -> Bool {
        text.range(of: asks, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The place to tell the agent with this message: on a place question, with the setting on and
    /// a recent place kept; nothing otherwise, so every other prompt stays as short as it was.
    static func forAgent(asked text: String, on: Bool = isOn, kept: Here? = kept(), now: Date = .now) -> Here? {
        guard on, let here = fresh(kept, now: now), asksPlace(text) else { return nil }
        return here
    }

    /// "The user is near Thornton Park, Orlando, FL (28.542, -81.367). Use it for …"
    static func instruction(_ here: Here) -> String {
        let at = String(format: "%.3f, %.3f", here.latitude, here.longitude)
        let place = here.words.map { "\($0) (\(at))" } ?? at
        return opening + place + "." + closing
    }

    /// On the message itself (the Dashboard takes no instructions).
    static func note(_ here: Here) -> String { "\n\n(" + instruction(here) + ")" }

    private static let opening = "The user is near "
    private static let closing = " Use it for places, directions and weather unless they name somewhere else."

    /// A message read back, without its note.
    static func strip(_ text: String) -> String {
        guard text.hasSuffix(closing + ")"), let range = text.range(of: "\n\n(" + opening, options: .backwards),
              !text[range.upperBound...].contains("\n") else { return text }
        return String(text[..<range.lowerBound])
    }

    // MARK: Cards

    /// A weather card's place that means where the person is: none, "here", "my location".
    static func meansHere(_ place: String) -> Bool {
        let place = place.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return place.isEmpty || ["here", "near me", "nearby", "my location", "current location", "my current location",
                                 "where i am", "where you are", "your location", "user's location", "the user's location"].contains(place)
    }

    /// Where a weather card is for, from the kept place, without asking Apple's maps: with the setting
    /// on, a recent place, and a card for here (or for the very place the agent was told).
    static func standIn(for place: String, on: Bool = isOn, kept: Here? = kept(), now: Date = .now) -> CLLocationCoordinate2D? {
        guard on, let here = fresh(kept, now: now) else { return nil }
        let named = place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard meansHere(named) || here.words.map({ $0.caseInsensitiveCompare(named) == .orderedSame }) == true else { return nil }
        return here.coordinate
    }

    // Places, ways there, maps and the weather, in English. "Near me", "nearest", "how far";
    // things to find nearby by their names alone where they are seldom anything else
    // ("restaurants", "pharmacy"), with a word of looking for where they may be ("a good bar",
    // "where can I get coffee"); the plugin's weather words (`cards.py`'s `_ASKS_WEATHER`, less a bare "temp":
    // a temp file is no question about the weather).
    private static let asks = #"\bnear (?:me|here|us|by)\b|\bnearby\b|\bnearest\b|\bclosest\b|\baround here\b"#
        + #"|\bclose (?:to|by) (?:me|here|us)\b|\bin (?:the|this|my|our) (?:area|neighbou?rhood)\b|\bwhere am i\b|\bwhere are we\b"#
        + #"|\bdirections?\b|\bhow (?:far|long (?:is it|does it take|will it take|would it take) to (?:get|drive|walk))\b"#
        + #"|\bhow do (?:i|we) get (?:to|there|home)\b|\b(?:drive|walk|commute|route) (?:to|there|home)\b|\bmaps?\b"#
        + #"|\b(?:restaurants?|caf[eé]s|coffee shops?|pharmac(?:y|ies)|drugstores?|gas stations?|petrol stations?"#
        + #"|charging stations?|ev chargers?|supermarkets?|grocery stores?|urgent care|takeout|take-away|places to eat"#
        + #"|somewhere to eat|things to do)\b"#
        + #"|\b(?:where|find|any|good|best|recommend|open now|go for)\b[^.?!]*\b(?:coffee|caf[eé]|bars?|pubs?|brunch|lunch|dinner"#
        + #"|food|pizza|sushi|tacos|gas|groceries|stores?|shops?|atms?|banks?|parks?|gyms?|hotels?|museums?|cinemas?|movies"#
        + #"|baker(?:y|ies)|parking|hospital|vet|dentist|doctor)\b"#
        + #"|\bweather\b|\bforecast\b|\btemperatures?\b|\bdegrees\b|\bumbrella\b|\bsun(?:rise|set)\b"#
        + #"|\b(?:rain(?:ing|y)?|snow(?:ing)?|sunny|humid(?:ity)?|windy)\b"#
}
