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
    /// What's on the calendar (asked 2026-10-29: "when I ask what's on my calendar for tomorrow or
    /// what's on my calendar in general, make it appear in a calendar card"): the events the agent
    /// read with its calendar tool, by day, and the days asked about, which show even when free.
    case agenda(Agenda)
    /// Cards the person answers with a tap (asked 2026-10-28, after Meta's Muse, whose app, not
    /// its model, shows what it is about to do): drawn by the app from the call; the answer goes to
    /// the agent as the person's next message, with a note of exactly what was picked or left in
    /// the fields (`CardNote`).
    case review(Review)
    case choice(Choice)
    case checklist(Checklist)
    case form(Form)
    /// A key a bot asked for (`request_secret`, `KeyRequests`): which, for which profile, why. It
    /// opens the card the key is pasted into; nothing of the key is in the chat.
    case key(KeyAsk)

    nonisolated struct KeyAsk: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var profile: String
        var why: String
    }

    nonisolated struct Agenda: Codable, Equatable, Sendable {
        var title: String?
        var events: [Event]
        /// The days asked about ("2026-10-30"), shown even with nothing on them.
        var days: [String]

        nonisolated struct Event: Codable, Equatable, Sendable, Hashable {
            var title: String
            var start: Date
            var end: Date?
            var allDay: Bool
            /// Its day on this phone ("2026-10-30"); an all-day event's as the calendar gave it.
            var day: String
            var location: String?
            var calendar: String?
            var notes: String?
        }

        /// The days to draw in order, each with its events: all-day ones first, then by start.
        var byDay: [(day: String, events: [Event])] {
            let all = Set(days).union(events.map(\.day)).sorted()
            return all.map { day in
                (day, events.filter { $0.day == day }.sorted { a, b in
                    a.allDay != b.allDay ? a.allDay : (a.start, a.title) < (b.start, b.title)
                })
            }
        }

        /// The days to draw, each with only the chosen calendars' events (`CalendarChoice`): a day
        /// whose events are all hidden is still drawn, with nothing on it.
        func byDay(showing calendars: [String]) -> [(day: String, events: [Event])] {
            guard !calendars.isEmpty else { return byDay }
            return byDay.map { ($0.day, $0.events.filter { CalendarChoice.shows($0.calendar, among: calendars) }) }
        }

        /// A start or an end as an agent writes it: "2026-10-30T09:30:00-04:00" (or with Z, or
        /// seconds' fractions), "2026-10-30T09:30" or "2026-10-30 09:30" (this phone's time), or
        /// "2026-10-30", all day. The day is the phone's, for a time given in another zone.
        static func when(_ written: String, timeZone: TimeZone = .current) -> (date: Date, day: String, allDay: Bool)? {
            let text = written.trimmingCharacters(in: .whitespaces)
            guard text.count >= 10, text.prefix(10).wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let dayOnly = String(text.prefix(10))
            if text.count == 10 {
                let parts = dayOnly.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
                return (date, dayOnly, true)
            }
            let iso = text.replacingOccurrences(of: " ", with: "T", options: [], range: text.index(text.startIndex, offsetBy: 10)..<text.index(text.startIndex, offsetBy: 11))
            var date: Date?
            if iso.range(of: #"(Z|[+-]\d{2}:?\d{2})$"#, options: .regularExpression) != nil {
                for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds],
                                                              [.withFullDate, .withTime, .withColonSeparatorInTime, .withTimeZone]] {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = options
                    if let found = formatter.date(from: iso) { date = found; break }
                }
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = timeZone
                for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss.SSS"] {
                    formatter.dateFormat = format
                    if let found = formatter.date(from: iso) { date = found; break }
                }
            }
            guard let date else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
            return (date, String(format: "%04d-%02d-%02d", year, month, day), false)
        }
    }

    /// What the agent has made ready to send, buy, book or change: its details, which the person
    /// can change, and the button that lets it go ahead ("Send").
    nonisolated struct Review: Codable, Equatable, Sendable {
        var title: String
        var action: String
        var fields: [Field]
        var note: String?
        /// What it is, when the agent says (asked 2026-10-30, with the card drawn as the thing
        /// itself: an email as an email); else told by its fields (`shownKind`).
        var kind: Kind? = nil
        /// A line under its title, when the agent gives one ("From your Gmail · as you").
        var subtitle: String? = nil

        nonisolated enum Kind: String, Codable, Sendable, CaseIterable {
            case email, message, event, purchase, other

            /// Read leniently: "Email", "e-mail", "text", "booking"; nil for what it can't place.
            init?(lenient text: String?) {
                let key = (text ?? "").lowercased().trimmingCharacters(in: .whitespaces)
                if let exact = Kind(rawValue: key) { self = exact; return }
                switch key {
                case "e-mail", "mail", "gmail": self = .email
                case "text", "sms", "imessage", "chat", "dm": self = .message
                case "calendar", "meeting", "appointment", "invite", "invitation": self = .event
                case "booking", "reservation", "order", "payment", "buy": self = .purchase
                default: return nil
                }
            }
        }

        /// Where a message's parts are among the fields: who it's to, its subject, its body; and
        /// the rest, as rows, in their order. Anything else is all rows.
        nonisolated struct Layout: Equatable, Sendable {
            var to: Int?
            var subject: Int?
            var body: Int?
            var rows: [Int]
        }

        /// Its kind as the agent said, else by its fields' labels (To and Subject: an email; To
        /// and a Message: a message, an email when it's to an address).
        var shownKind: Kind {
            if let kind { return kind }
            let labels = fields.map { Self.plain($0.label) }
            let to = labels.firstIndex { Self.toLabels.contains($0) }
            if labels.contains(where: Self.subjectLabels.contains) || labels.contains(where: ["cc", "bcc"].contains) { return .email }
            if to != nil, labels.contains(where: Self.bodyLabels.contains) {
                return to.map { fields[$0].value.contains("@") } == true ? .email : .message
            }
            if labels.contains(where: Self.purchaseLabels.contains) { return .purchase }
            if labels.contains(where: Self.eventLabels.contains) { return .event }
            return .other
        }

        var layout: Layout {
            let all = Array(fields.indices)
            guard [.email, .message].contains(shownKind) else { return .init(rows: all) }
            let labels = fields.map { Self.plain($0.label) }
            let to = labels.firstIndex { Self.toLabels.contains($0) }
            let subject = labels.firstIndex { Self.subjectLabels.contains($0) }
            let body = labels.firstIndex { Self.bodyLabels.contains($0) }
                ?? all.last { $0 != to && $0 != subject && fields[$0].long }
            return .init(to: to, subject: subject, body: body, rows: all.filter { ![to, subject, body].contains($0) })
        }

        /// A person's initials for their mark ("Ana Okafor" AO, "ana@example.com" A): the first
        /// of several, and the name before an address.
        static func initials(_ to: String) -> String {
            var name = to.split(separator: ",").first.map(String.init) ?? to
            if let open = name.firstIndex(of: "<") { name = String(name[..<open]) }
            if !name.contains(" "), let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
            let words = name.split { !$0.isLetter }
            let letters = [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
            return String(letters).uppercased()
        }

        private static func plain(_ label: String) -> String {
            label.lowercased().trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        }
        private static let toLabels: Set = ["to", "recipient", "recipients", "send to"]
        private static let subjectLabels: Set = ["subject", "re"]
        private static let bodyLabels: Set = ["body", "message", "text", "content"]
        private static let eventLabels: Set = ["when", "date", "time", "start", "starts", "where", "location", "attendees", "invitees"]
        private static let purchaseLabels: Set = ["price", "total", "cost", "amount", "payment", "pay with", "card", "quantity"]
    }

    nonisolated struct Field: Codable, Equatable, Sendable {
        var label: String
        var value: String
        /// A message's body: several lines.
        var long: Bool
    }

    /// Things to pick from: one, or several.
    nonisolated struct Choice: Codable, Equatable, Sendable {
        var title: String?
        var options: [Option]
        var multiple: Bool
    }

    nonisolated struct Option: Codable, Equatable, Sendable, Hashable {
        var title: String
        var detail: String?
        /// A picture of it, by https.
        var image: String?
    }

    /// A list to tick off (a packing or a shopping list), in sections when the agent groups it.
    nonisolated struct Checklist: Codable, Equatable, Sendable {
        var title: String
        var items: [Item]
        /// One emoji for its header ("🏕️").
        var emoji: String?
        /// A line under its title ("Nov 7 – 8"), and what doing an item is ("packed": "3 of 8
        /// packed"), when the agent gives them (asked 2026-10-30).
        var subtitle: String? = nil
        var verb: String? = nil
        nonisolated struct Item: Codable, Equatable, Sendable {
            var text: String
            var done: Bool
            var section: String?
            /// A word beside it ("×2", "SPF 50").
            var note: String? = nil
        }

        /// Its sections in order, each with its items' places in `items`.
        var sections: [(title: String?, items: [Int])] {
            var out: [(title: String?, items: [Int])] = []
            for (index, item) in items.enumerated() {
                if let last = out.indices.last, out[last].title == item.section { out[last].items.append(index) }
                else if let found = out.firstIndex(where: { $0.title == item.section }) { out[found].items.append(index) }
                else { out.append((item.section, [index])) }
            }
            return out
        }
    }

    /// A few details the agent needs at once.
    nonisolated struct Form: Codable, Equatable, Sendable {
        var title: String
        var action: String
        var fields: [Entry]
        nonisolated struct Entry: Codable, Equatable, Sendable {
            enum Kind: String, Codable, Sendable { case text, long, number, date, time, toggle, choice }
            var label: String
            var kind: Kind
            var value: String
            var options: [String]
            var required: Bool
        }
    }

    /// A card that is answered, and so has a key its answer goes by.
    var answerable: Bool {
        switch self {
        case .review, .choice, .checklist, .form: true
        case .map, .places, .weather, .time, .agenda, .key: false
        }
    }

    /// Its key: the same live and when the conversation is read back (from what it says), so an
    /// answer, here or in the transcript's note, finds it.
    var key: String {
        let said: String
        switch self {
        case let .review(r): said = "review|" + r.title + "|" + r.fields.map(\.label).joined(separator: "|")
        case let .choice(c): said = "choice|" + (c.title ?? "") + "|" + c.options.map(\.title).joined(separator: "|")
        case let .checklist(c): said = "checklist|" + c.title + "|" + c.items.map(\.text).joined(separator: "|")
        case let .form(f): said = "form|" + f.title + "|" + f.fields.map(\.label).joined(separator: "|")
        default: return ""
        }
        // FNV-1a: short, and the same on every run (Hasher isn't).
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in said.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 36)
    }

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

        /// The one Directions goes to: the agent's pick, else the first.
        var lead: Place? { places.first { $0.pick == true } ?? places.first }
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
        /// How dear, as the agent found it: "$$" (asked 2026-10-30, with the places card's new look).
        var price: String?
        /// Whether it is open, in the agent's words ("Open until 9 PM", "Closes at 5 PM", "Closed").
        var hours: String?
        /// Open now, where the agent said so without words.
        var open: Bool?
        /// The agent's pick of the list.
        var pick: Bool?

        var hasCoordinate: Bool {
            guard let latitude, let longitude else { return false }
            return (-90 ... 90).contains(latitude) && (-180 ... 180).contains(longitude)
        }

        enum Opening: Equatable, Sendable { case open, closing, closed }

        /// Open, closing soon or closed, read from its words ("Closes at 5 PM" is closing soon: a
        /// place open late says "Open until"); else from `open`. Nil when neither says.
        var opening: Opening? {
            let said = (hours ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            if said.hasPrefix("closed") || said.contains("closed now") { return .closed }
            if said.hasPrefix("closes") || said.hasPrefix("closing") { return .closing }
            if said.hasPrefix("open") || said.contains("open now") || said.contains("24 hours") { return .open }
            return open.map { $0 ? .open : .closed }
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
        /// When the reading was taken, in the place's time with its offset ("2026-10-23T17:45:00-04:00"),
        /// as the plugin and the phone write it from the forecast.
        var updated: String?

        /// Whether there is anything to draw: a card with only its place is waiting for its forecast.
        var hasReading: Bool { now != nil || !hours.isEmpty || !days.isEmpty }

        /// When the reading was taken, where `updated` says with its offset ("2026-10-23T17:45:00-04:00").
        var updatedAt: Date? { updated.flatMap { ISO8601DateFormatter().date(from: $0) } }

        /// Rain (or storms, or snow) likely in the hours ahead (asked 2026-10-30, with the weather
        /// card's hour-by-hour strip): the first run of hours at 50 % or more, and its likeliest hour.
        /// Read from the hours alone; nil when none reach it, or they don't say.
        var spell: Spell? {
            let ahead = Array(hours.prefix(12))
            guard let first = ahead.firstIndex(where: { ($0.precipitation ?? 0) >= Spell.likely }) else { return nil }
            var last = first
            while last + 1 < ahead.count, (ahead[last + 1].precipitation ?? 0) >= Spell.likely { last += 1 }
            let run = ahead[first ... last]
            let peak = run.indices.max { (ahead[$0].precipitation ?? 0) < (ahead[$1].precipitation ?? 0) } ?? first
            let kind: Spell.Kind = run.contains { $0.condition == .thunderstorm } ? .storms
                : run.contains { [.snow, .sleet, .hail].contains($0.condition) } ? .snow : .rain
            return Spell(first: first, last: last, peak: peak, chance: ahead[peak].precipitation ?? 0, kind: kind,
                         gusts: run.compactMap(\.gusts).max(), open: last == ahead.count - 1)
        }

        nonisolated struct Spell: Equatable, Sendable {
            /// How likely an hour's rain must be to count.
            static let likely = 50
            enum Kind: Equatable, Sendable { case rain, storms, snow }
            /// Its hours, as places in `hours`.
            var first: Int
            var last: Int
            var peak: Int
            var chance: Int
            var kind: Kind
            /// The strongest gust in it, where the hours give gusts.
            var gusts: Double?
            /// It runs to the last hour there is: when it ends isn't known.
            var open: Bool
        }

        /// An hour as the forecast or an agent writes it ("2026-10-23T14:00", "14:00", "2 PM",
        /// "2pm", "2026-10-23T17:45:00-04:00"), as the hour and minute of the day there. Nil for anything else.
        static func clock(_ text: String) -> (hour: Int, minute: Int)? {
            let time = (text.split(separator: "T").last.map(String.init) ?? text).trimmingCharacters(in: .whitespaces).lowercased()
            guard let match = time.wholeMatch(of: /(\d{1,2})(?::(\d{2}))?(?::\d{2}(?:\.\d+)?)?\s*(?:([ap])\.?\s*m\.?)?(?:z|[+-]\d{2}:?\d{2})?/),
                  var hour = Int(match.1), let minute = Int(match.2 ?? "0"), minute < 60 else { return nil }
            if let half = match.3 {
                guard (1 ... 12).contains(hour) else { return nil }
                hour = hour % 12 + (half == "p" ? 12 : 0)
            } else if match.2 == nil {
                return nil   // a bare number isn't an hour
            }
            return (0 ... 23).contains(hour) ? (hour, minute) : nil
        }

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
            /// Wind gusts, in the card's speed: mph with °F, km/h with °C.
            var gusts: Double?
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
    /// Its tool a bot asks for a key with: its answer becomes the card the key is pasted into.
    static let keyTool = "request_secret"

    /// Whether a step's call is one cards come from.
    static func carriesCards(_ name: String) -> Bool { name == tool || name == keyTool }
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
        if step.name == keyTool { return keyCard(from: step) }
        guard step.name == tool, step.status != .failed else { return nil }
        if let output = step.output, let answer = try? JSONValue.parse(Data(output.utf8)), answer["cards"]?.array != nil {
            return parse(answer)
        }
        guard let text = step.args, let args = try? JSONValue.parse(Data(text.utf8)) else { return nil }
        return parse(args)
    }

    /// A key request's card, from the plugin's answer to the call: only a request it took (one
    /// with an id) has one. The answer holds no key: there is none yet.
    static func keyCard(from step: ToolActivity) -> [ReplyCard]? {
        guard step.status != .failed, let output = step.output,
              let answer = try? JSONValue.parse(Data(output.utf8)),
              let id = answer["id"]?.string, !id.isEmpty, let name = answer["name"]?.string, !name.isEmpty else { return nil }
        return [.key(.init(id: id, name: name, profile: answer["profile"]?.string ?? "default", why: answer["why"]?.string ?? ""))]
    }

    /// Where the forecasts the plugin and the phone look up come from, credited on the card.
    static let lookedUpSource = "Open-Meteo.com"

    /// The temperature units this phone's person reads: "F" or "C".
    static var preferredUnits: String { MeasureUnits.temperature }

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
        case "agenda", "calendar", "events", "schedule":
            return agenda(value).map(ReplyCard.agenda)
        case "review", "confirm":
            let fields: [ReplyCard.Field] = (value["fields"]?.array ?? []).prefix(maxFields).compactMap { f in
                guard let label = text(f["label"] ?? f["name"]) else { return nil }
                let value = text(f["value"]) ?? ""
                return .init(label: String(label.prefix(60)), value: String(value.prefix(4000)),
                             long: f["long"]?.bool ?? (value.count > 60 || value.contains("\n")))
            }
            guard let title = text(value["title"]), !fields.isEmpty else { return nil }
            return .review(.init(title: String(title.prefix(120)), action: text(value["action"]).map { String($0.prefix(24)) } ?? String(localized: "Do It"),
                                 fields: fields, note: text(value["note"]).map { String($0.prefix(300)) },
                                 kind: .init(lenient: text(value["kind"])), subtitle: text(value["subtitle"]).map { String($0.prefix(80)) }))
        case "choice", "choose", "options":
            let options: [ReplyCard.Option] = (value["options"]?.array ?? []).prefix(maxOptions).compactMap { o in
                if let plain = o.string?.nilIfEmpty { return .init(title: String(plain.prefix(120))) }
                guard let title = text(o["title"] ?? o["name"] ?? o["label"]) else { return nil }
                let image = text(o["image"]).flatMap { URL(string: $0)?.scheme == "https" ? $0 : nil }
                return .init(title: String(title.prefix(120)), detail: text(o["detail"] ?? o["description"]).map { String($0.prefix(200)) }, image: image)
            }
            guard options.count >= 2 else { return nil }
            return .choice(.init(title: text(value["title"]).map { String($0.prefix(120)) }, options: options, multiple: value["multiple"]?.bool ?? false))
        case "checklist", "list":
            func item(_ i: JSONValue, in section: String?) -> ReplyCard.Checklist.Item? {
                if let plain = i.string?.nilIfEmpty { return .init(text: String(plain.prefix(200)), done: false, section: section) }
                guard let text = text(i["text"] ?? i["title"]) else { return nil }
                return .init(text: String(text.prefix(200)), done: i["done"]?.bool ?? false,
                             section: self.text(i["section"] ?? i["group"]).map { String($0.prefix(60)) } ?? section,
                             note: self.text(i["note"]).map { String($0.prefix(40)) })
            }
            // Items with their 'section' (or 'group'), or 'sections' (or 'groups') each with its items.
            var items: [ReplyCard.Checklist.Item] = (value["items"]?.array ?? []).compactMap { item($0, in: nil) }
            for group in value["sections"]?.array ?? value["groups"]?.array ?? [] {
                let title = text(group["title"] ?? group["name"]).map { String($0.prefix(60)) }
                items += (group["items"]?.array ?? []).compactMap { item($0, in: title) }
            }
            items = Array(items.prefix(maxItems))
            guard !items.isEmpty else { return nil }
            let emoji = text(value["emoji"]).flatMap { $0.first.map(String.init) }.flatMap { $0.unicodeScalars.first?.properties.isEmoji == true ? $0 : nil }
            return .checklist(.init(title: text(value["title"]).map { String($0.prefix(120)) } ?? String(localized: "List"), items: items, emoji: emoji,
                                    subtitle: text(value["subtitle"]).map { String($0.prefix(80)) }, verb: text(value["verb"]).map { String($0.prefix(24)) }))
        case "form":
            let fields: [ReplyCard.Form.Entry] = (value["fields"]?.array ?? []).prefix(maxFields).compactMap { f in
                guard let label = text(f["label"] ?? f["name"]) else { return nil }
                let options = (f["options"]?.array ?? []).compactMap { text($0) }.prefix(maxOptions).map { String($0.prefix(80)) }
                var kind = ReplyCard.Form.Entry.Kind(rawValue: text(f["kind"] ?? f["type"])?.lowercased() ?? "") ?? .text
                if kind == .choice, options.isEmpty { kind = .text }
                return .init(label: String(label.prefix(60)), kind: kind, value: text(f["value"]).map { String($0.prefix(2000)) } ?? "",
                             options: Array(options), required: f["required"]?.bool ?? false)
            }
            guard let title = text(value["title"]), !fields.isEmpty else { return nil }
            return .form(.init(title: String(title.prefix(120)), action: text(value["action"]).map { String($0.prefix(24)) } ?? String(localized: "Send"),
                               fields: fields))
        default:
            return nil
        }
    }

    static let maxEvents = 50

    /// An agenda: its events (each a title and a start with its date; the rest as given), and the
    /// days asked about. With neither, and no title, there is nothing to draw.
    static func agenda(_ value: JSONValue, timeZone: TimeZone = .current) -> ReplyCard.Agenda? {
        let events: [ReplyCard.Agenda.Event] = (value["events"]?.array ?? value["items"]?.array ?? []).prefix(maxEvents).compactMap { e in
            guard let title = text(e["title"] ?? e["summary"] ?? e["name"]),
                  let written = text(e["start"] ?? e["starts"] ?? e["start_time"] ?? e["when"] ?? e["date"]),
                  let start = ReplyCard.Agenda.when(written, timeZone: timeZone) else { return nil }
            let allDay = e["all_day"]?.bool ?? e["allDay"]?.bool ?? start.allDay
            let end = text(e["end"] ?? e["ends"] ?? e["end_time"]).flatMap { ReplyCard.Agenda.when($0, timeZone: timeZone)?.date }
            return .init(title: String(title.prefix(160)), start: start.date, end: end.flatMap { $0 > start.date ? $0 : nil }, allDay: allDay,
                         day: start.day, location: text(e["location"] ?? e["where"] ?? e["place"]).map { String($0.prefix(200)) },
                         calendar: text(e["calendar"] ?? e["calendar_name"]).map { String($0.prefix(60)) },
                         notes: text(e["notes"] ?? e["description"]).map { String($0.prefix(600)) })
        }
        var days: [String] = []
        for written in [value["date"]].compactMap({ $0 }) + (value["dates"]?.array ?? []) {
            if let day = text(written).flatMap({ ReplyCard.Agenda.when(String($0.prefix(10)), timeZone: timeZone)?.day }), !days.contains(day) {
                days.append(day)
            }
        }
        let title = text(value["title"]).map { String($0.prefix(80)) }
        guard !events.isEmpty || !days.isEmpty || title != nil else { return nil }
        return .init(title: title, events: events, days: Array(days.prefix(14)))
    }

    static let maxFields = 8
    static let maxOptions = 8
    static let maxItems = 100

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
        place.price = price(value["price"] ?? value["price_level"] ?? value["priceLevel"])
        place.open = (value["open_now"] ?? value["openNow"] ?? value["open"])?.bool
        place.hours = hours(value)
        place.pick = (value["pick"] ?? value["best"] ?? value["recommended"])?.bool == true ? true : nil
        return place
    }

    /// "$$" as given, or a level of 1 to 4 as that many dollar signs.
    static func price(_ value: JSONValue?) -> String? {
        if let level = value?.number ?? value?.string.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) {
            let whole = Int(level.rounded())
            return (1 ... 4).contains(whole) ? String(repeating: "$", count: whole) : nil
        }
        return text(value).flatMap { $0.count <= 5 ? $0 : nil }
    }

    /// Whether a place is open, in words: as the agent wrote them ("Open until 9 PM"), or made from
    /// the time it closes ("open_until": "9 PM", "closes": "5 PM").
    static func hours(_ value: JSONValue) -> String? {
        if let said = text(value["hours"] ?? value["status"] ?? value["opening_hours"]) ?? value["open"]?.string?.nilIfEmpty {
            return String(said.prefix(60))
        }
        if let until = text(value["open_until"] ?? value["openUntil"]) {
            return String((until.lowercased().hasPrefix("open") ? until
                : String(localized: "Open until \(until)", comment: "A place on a places card is open until a time, e.g. 9 PM")).prefix(60))
        }
        if let closes = text(value["closes"] ?? value["closes_at"] ?? value["closesAt"]) {
            return String((closes.lowercased().hasPrefix("close") ? closes
                : String(localized: "Closes at \(closes)", comment: "A place on a places card closes soon, at a time, e.g. 5 PM")).prefix(60))
        }
        return nil
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
                         precipitation: number(h["precipitation"] ?? h["chance_of_rain"]).map { min(100, max(0, Int($0.rounded()))) },
                         night: h["night"]?.bool, gusts: number(h["gusts"] ?? h["wind_gusts"]).flatMap { $0 >= 0 ? $0 : nil })
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
                     source: text(value["source"]), updated: text(value["updated"]).map { String($0.prefix(40)) })
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
