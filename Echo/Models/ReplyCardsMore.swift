import Foundation

// MARK: - Recipes, deliveries, flights, shows, conversions, stocks (asked 2026-10-31)
//
// Six more cards for `redde_show`, read as leniently as the others (`ReplyCards`): what the agent
// looked up, drawn by the app. None of them fetches anything by itself; their chips ask the agent.

nonisolated extension ReplyCard {
    nonisolated struct Recipe: Codable, Equatable, Sendable {
        var title: String
        /// A line on what it is ("Weeknight, one pan").
        var summary: String?
        /// Its picture, https only; shown only with Link previews on (`ProductImages`).
        var image: String?
        /// Where it's from ("Serious Eats"), and its page, http or https.
        var source: String?
        var url: String?
        var prep: TimeInterval?
        var cook: TimeInterval?
        var total: TimeInterval?
        /// How many it serves as written: the amounts are for this many.
        var servings: Int?
        var ingredients: [Ingredient]
        var steps: [String]
        var note: String?

        nonisolated struct Ingredient: Codable, Equatable, Sendable, Hashable {
            /// How much, for the recipe's servings ("2" of "2 cups flour"); nil: none to scale ("salt to taste").
            var amount: Double?
            /// The top of a range ("2–3 cloves").
            var upTo: Double?
            var unit: String?
            var name: String
            var section: String?
        }

        /// The time it takes in all: as given, else its prep and cook together.
        var allTime: TimeInterval? { total ?? (prep != nil || cook != nil ? (prep ?? 0) + (cook ?? 0) : nil) }

        /// An ingredient as a line ("1 1/2 cups flour", "2–3 cloves garlic, crushed", "½ tsp salt",
        /// "Salt to taste"): its amount, its unit where it is one of a kitchen's, and the rest.
        static func ingredient(_ line: String, section: String? = nil) -> Ingredient {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let found = quantity(text), !found.rest.isEmpty else { return .init(name: text, section: section) }
            let (unit, name) = unit(in: found.rest)
            return .init(amount: found.amount, upTo: found.upTo, unit: unit, name: name.isEmpty ? found.rest : name, section: section)
        }

        /// The amount a line starts with: "2", "1.5", "1,5", "1/2", "1 1/2", "1½", "½", "2-3", "2 to 3".
        static func quantity(_ text: String) -> (amount: Double, upTo: Double?, rest: String)? {
            let number = #"(?:\d+\s+\d+/\d+|\d+/\d+|\d*[½⅓⅔¼¾⅛⅜⅝⅞]|\d+(?:[.,]\d+)?)"#
            guard let match = text.range(of: "^" + number, options: .regularExpression), let amount = value(String(text[match])) else { return nil }
            var rest = text[match.upperBound...]
            var upTo: Double?
            if let range = rest.range(of: #"^\s*(?:-|–|—|to)\s*"# + number, options: .regularExpression) {
                let top = String(rest[range]).replacing(/^\s*(?:-|–|—|to)\s*/, with: "")
                if let top = value(top), top > amount { upTo = top }
                rest = rest[range.upperBound...]
            }
            return (amount, upTo, rest.trimmingCharacters(in: .whitespaces))
        }

        private static let fractions: [Character: Double] = ["½": 0.5, "⅓": 1.0 / 3, "⅔": 2.0 / 3, "¼": 0.25, "¾": 0.75, "⅛": 0.125,
                                                             "⅜": 0.375, "⅝": 0.625, "⅞": 0.875]

        private static func value(_ written: String) -> Double? {
            let s = written.trimmingCharacters(in: .whitespaces)
            if let last = s.last, let part = fractions[last] { return (Double(s.dropLast()) ?? 0) + part }
            let words = s.split(separator: " ")
            if words.count == 2, let whole = Double(words[0]), let part = value(String(words[1])) { return whole + part }
            if let slash = s.firstIndex(of: "/"), let a = Double(s[..<slash]), let b = Double(s[s.index(after: slash)...]), b > 0 { return a / b }
            return Double(s.replacingOccurrences(of: ",", with: ".")).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }

        /// A kitchen's unit, where a line's rest starts with one: the unit, and the rest ("of" dropped).
        private static func unit(in rest: String) -> (String?, String) {
            let words = rest.split(separator: " ").map(String.init)
            guard let first = words.first else { return (nil, rest) }
            func after(_ n: Int) -> String {
                var tail = words.dropFirst(n).joined(separator: " ")
                if tail.lowercased().hasPrefix("of ") { tail = String(tail.dropFirst(3)) }
                return tail
            }
            if words.count >= 2, ["fl", "fl.", "fluid"].contains(first.lowercased()), ["oz", "oz.", "ounce", "ounces"].contains(words[1].lowercased()) {
                return (first + " " + words[1], after(2))
            }
            return units.contains(plain(first)) && words.count > 1 ? (first, after(1)) : (nil, rest)
        }

        private static func plain(_ unit: String) -> String { unit.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }

        static let units: Set<String> = [
            "cup", "cups", "tbsp", "tbsps", "tablespoon", "tablespoons", "tbs", "tsp", "tsps", "teaspoon", "teaspoons",
            "g", "gram", "grams", "kg", "kilogram", "kilograms", "mg", "ml", "milliliter", "milliliters", "millilitre", "millilitres",
            "l", "liter", "liters", "litre", "litres", "dl", "cl", "oz", "ounce", "ounces", "lb", "lbs", "pound", "pounds",
            "pinch", "pinches", "dash", "dashes", "clove", "cloves", "can", "cans", "tin", "tins", "jar", "jars", "slice", "slices",
            "stick", "sticks", "sprig", "sprigs", "bunch", "bunches", "handful", "handfuls", "package", "packages", "pkg",
            "quart", "quarts", "qt", "pint", "pints", "pt", "gallon", "gallons", "piece", "pieces", "head", "heads",
            "stalk", "stalks", "fillet", "fillets", "sheet", "sheets", "knob", "knobs", "bag", "bags", "box", "boxes",
        ]
        /// Units that are weighed or measured in decimals ("250 g"), not in a cook's fractions.
        static let metric: Set<String> = ["g", "gram", "grams", "kg", "kilogram", "kilograms", "mg", "ml", "milliliter", "milliliters",
                                          "millilitre", "millilitres", "l", "liter", "liters", "litre", "litres", "dl", "cl"]

        /// An amount as a cook writes it: "1½", "¾", "⅓", "2"; in decimals for what is weighed
        /// ("250 g", "1.5 kg"), and where no fraction is near.
        static func quantity(_ x: Double, unit: String? = nil, locale: Locale = .current) -> String {
            if let unit, metric.contains(plain(unit)) {
                return x.formatted(.number.precision(.fractionLength(0 ... (x >= 10 ? 0 : 1))).locale(locale))
            }
            if x >= 10 { return x.rounded().formatted(.number.locale(locale)) }
            var whole = x.rounded(.down)
            let part = x - whole
            let glyphs: [(Double, String)] = [(0, ""), (0.125, "⅛"), (0.25, "¼"), (1.0 / 3, "⅓"), (0.375, "⅜"), (0.5, "½"), (0.625, "⅝"),
                                            (2.0 / 3, "⅔"), (0.75, "¾"), (0.875, "⅞"), (1, "")]
            guard let near = glyphs.min(by: { abs($0.0 - part) < abs($1.0 - part) }), abs(near.0 - part) <= 0.04 else {
                return x.formatted(.number.precision(.fractionLength(0 ... 2)).locale(locale))
            }
            if near.0 == 1 { whole += 1 }
            if whole == 0 { return near.1.isEmpty ? "0" : near.1 }
            return whole.formatted(.number.locale(locale)) + (near.0 == 1 ? "" : near.1)
        }

        /// An ingredient for `factor` times the recipe ("3 cups flour" for twice "1 1/2 cups"):
        /// its amount, and its unit and name, the unit made one or many to match.
        static func scaled(_ i: Ingredient, by factor: Double, locale: Locale = .current) -> (amount: String?, rest: String) {
            guard let amount = i.amount else { return (nil, i.name) }
            var shown = quantity(amount * factor, unit: i.unit, locale: locale)
            if let top = i.upTo { shown += "–" + quantity(top * factor, unit: i.unit, locale: locale) }
            guard var unit = i.unit else { return (shown, i.name) }
            let lower = unit.lowercased()
            // Short forms ("tbsp", "oz", "g") stay as they are.
            let short: Set<String> = ["tbsp", "tbsps", "tbs", "tsp", "tsps", "oz", "lb", "lbs", "g", "kg", "mg", "ml", "l", "dl", "cl", "qt", "pt", "pkg"]
            if short.contains(plain(lower)) {
                if lower == "tbsps" || lower == "tsps" { unit = String(unit.dropLast()) }
            } else if (i.upTo ?? amount) * factor > 1 {
                if !lower.hasSuffix("s"), units.contains(lower + "s") { unit += "s" }
                else if !lower.hasSuffix("s"), units.contains(lower + "es") { unit += "es" }
            } else if lower.hasSuffix("es"), units.contains(String(lower.dropLast(2))), !units.contains(String(lower.dropLast())) {
                unit = String(unit.dropLast(2))
            } else if lower.hasSuffix("s"), lower.count > 2, units.contains(String(lower.dropLast())) {
                unit = String(unit.dropLast())
            }
            return (shown, unit + " " + i.name)
        }
    }

    nonisolated struct Delivery: Codable, Equatable, Sendable {
        enum Stage: String, Codable, Sendable, CaseIterable { case ordered, shipped, outForDelivery = "out_for_delivery", delivered }
        /// What is in it ("AirPods Pro"), and where it's from ("Apple").
        var title: String?
        var from: String?
        var carrier: String?
        var tracking: String?
        /// The carrier's page for it, http or https.
        var url: String?
        var stage: Stage
        /// The carrier's words for where it stands ("In transit", "Delivery attempted").
        var status: String?
        /// Held up: a failed attempt, a delay, customs, a return.
        var problem = false
        /// When it should come: a day, or a time.
        var expected: Date?
        var expectedAllDay = true
        /// The same in the agent's words, where it gave no date ("Monday or Tuesday").
        var expectedWords: String?
        /// "By 8 PM", "10 AM – 2 PM".
        var window: String?
        var deliveredAt: Date?
        /// The newest scan first.
        var events: [Scan]
        var note: String?

        nonisolated struct Scan: Codable, Equatable, Sendable, Hashable {
            var text: String
            var place: String?
            var at: Date?
        }

        /// Where it stands, from the carrier's words, and whether it is held up.
        static func stage(_ words: String?) -> (stage: Stage, problem: Bool)? {
            guard let said = words?.lowercased().replacingOccurrences(of: "_", with: " "), !said.isEmpty else { return nil }
            if said.contains("delivered"), !said.contains("not delivered"), !said.contains("undelivered") { return (.delivered, false) }
            let problem = ["exception", "delay", "failed", "attempt", "held", "customs", "return", "lost", "damaged", "problem",
                           "issue", "undeliverable", "missed"].contains(where: said.contains)
            if said.contains("out for delivery") || said.contains("with courier") || said.contains("with driver") { return (.outForDelivery, problem) }
            if problem || ["transit", "shipped", "on the way", "on its way", "departed", "arrived", "picked up", "moving", "dispatched",
                           "sent", "en route", "processed at", "sorting"].contains(where: said.contains) {
                return (.shipped, problem)
            }
            if ["order", "label", "pre", "processing", "info", "created", "preparing", "confirmed", "pending", "not yet", "placed",
                "awaiting"].contains(where: said.contains) {
                return (.ordered, false)
            }
            return (.shipped, false)
        }

        /// The carrier's own tracking page for a number, for the carriers whose pages take one; else nil.
        static func trackingPage(carrier: String?, number: String?) -> URL? {
            guard let number = number?.filter({ !$0.isWhitespace }), number.count >= 6,
                  number.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
            let said = (carrier ?? "").lowercased()
            let page = if said.contains("ups") { "https://www.ups.com/track?tracknum=" }
                else if said.contains("usps") || said.contains("postal service") { "https://tools.usps.com/go/TrackConfirmAction?tLabels=" }
                else if said.contains("fedex") { "https://www.fedex.com/fedextrack/?trknbr=" }
                else if said.contains("dhl") { "https://www.dhl.com/global-en/home/tracking/tracking-express.html?submit=1&tracking-id=" }
                else { "" }
            return page.isEmpty ? nil : URL(string: page + number)
        }
    }

    nonisolated struct Trip: Codable, Equatable, Sendable {
        var title: String?
        /// Its flights, in order.
        var legs: [Flight]
        /// The booking's code ("ABC123").
        var confirmation: String?
        var note: String?

        nonisolated struct Flight: Codable, Equatable, Sendable, Hashable {
            enum Status: String, Codable, Sendable, CaseIterable {
                case scheduled, onTime = "on_time", delayed, boarding, departed, landed, cancelled, diverted
            }
            var airline: String?
            /// "TP 238".
            var number: String?
            var from: Airport
            var to: Airport
            /// When it leaves and lands, as scheduled, each in its airport's own time.
            var departs: Time?
            var arrives: Time?
            /// As estimated now, or as it happened, where it differs.
            var departsNew: Time?
            var arrivesNew: Time?
            var status: Status
            /// The airline's words, where they say more ("Gate closing").
            var statusWords: String?
            var seat: String?
            var duration: TimeInterval?
            var aircraft: String?

            /// How long in the air: as given, else from its times.
            var flightTime: TimeInterval? {
                if let duration { return duration }
                guard let off = (departsNew ?? departs)?.date, let on = (arrivesNew ?? arrives)?.date, on > off else { return nil }
                return on.timeIntervalSince(off)
            }
        }

        nonisolated struct Airport: Codable, Equatable, Sendable, Hashable {
            /// Its IATA code ("LIS").
            var code: String?
            var city: String?
            var name: String?
            var terminal: String?
            var gate: String?
            var latitude: Double?
            var longitude: Double?

            /// What Maps opens it by, only where it is a real place: its coordinates, or a real
            /// code with its name or city. Else nil, and it isn't a link.
            var mapsQuery: String? {
                if let latitude, let longitude, (-90 ... 90).contains(latitude), (-180 ... 180).contains(longitude) { return "\(latitude),\(longitude)" }
                guard let code, code.wholeMatch(of: /[A-Z]{3}/) != nil, let named = name ?? city else { return nil }
                return named.lowercased().contains("airport") ? "\(named) (\(code))" : "\(named) Airport (\(code))"
            }
        }

        /// A moment and the time it was written in: the airport's own.
        nonisolated struct Time: Codable, Equatable, Sendable, Hashable {
            var date: Date
            /// Seconds from GMT as written; nil: in `zone`, or the phone's.
            var offset: Int?
            var zone: String?

            var timeZone: TimeZone {
                zone.flatMap(TimeZone.init(identifier:)) ?? offset.flatMap(TimeZone.init(secondsFromGMT:)) ?? .current
            }
        }
    }

    nonisolated struct Shows: Codable, Equatable, Sendable {
        var title: String?
        var items: [Title]
        var note: String?

        /// The one shown first and larger: the agent's pick, else the first.
        var lead: Int { items.firstIndex(where: \.pick) ?? 0 }

        nonisolated struct Title: Codable, Equatable, Sendable, Hashable {
            enum Format: String, Codable, Sendable { case movie, series }
            var name: String
            var year: Int?
            /// A series' last year: with `year`, "2019–2023".
            var endYear: Int?
            var format: Format?
            /// Its poster, https only; shown only with Link previews on.
            var poster: String?
            var ratings: [Rating] = []
            var runtime: TimeInterval?
            var seasons: Int?
            var genres: [String] = []
            var overview: String?
            /// Where to watch it: services' names, in words.
            var watch: [String] = []
            /// Its page, and its trailer, http or https.
            var url: String?
            var trailer: String?
            /// Its director or creator.
            var by: String?
            var cast: [String] = []
            var pick = false
        }

        nonisolated struct Rating: Codable, Equatable, Sendable, Hashable {
            /// "IMDb", "Rotten Tomatoes"; nil where the agent didn't say.
            var source: String?
            var value: String
        }
    }

    nonisolated struct Conversion: Codable, Equatable, Sendable {
        var title: String?
        var amount: Double
        /// What from and to: a unit as written ("mi", "°F", "cups"), or a currency's ISO code.
        var from: String
        var to: String
        /// The agent's answer, for units the phone doesn't know.
        var result: Double?
        /// A currency's: one `from` in `to`, as the agent found it, and when.
        var rate: Double?
        var asOf: Date?
        var asOfWords: String?
        var source: String?
        /// Other values the agent gave ("1 cup: 240 ml").
        var rows: [Row] = []
        var note: String?

        nonisolated struct Row: Codable, Equatable, Sendable, Hashable {
            var label: String
            var value: String
        }

        var isCurrency: Bool { ReplyCards.currencyCode(from) != nil && ReplyCards.currencyCode(to) != nil }

        /// Both units known to the phone and of one kind: worked out here, again as the amount changes.
        var units: (from: Dimension, to: Dimension, fromSymbol: String, toSymbol: String)? {
            // Of one kind: the same base unit (the classes themselves differ, a static unit's being a private subclass).
            guard !isCurrency, let a = Self.unit(from), let b = Self.unit(to),
                  type(of: a.unit).baseUnit().symbol == type(of: b.unit).baseUnit().symbol else { return nil }
            return (a.unit, b.unit, a.symbol, b.symbol)
        }

        /// `amount` in `to`: worked out by the phone for units it knows, at the agent's rate for
        /// a currency, else the agent's answer scaled.
        func convert(_ amount: Double) -> Double? {
            if isCurrency { return rate.map { amount * $0 } }
            if let units { return Self.convert(amount, from: units.from, to: units.to) }
            guard let result, self.amount != 0 else { return nil }
            return result / self.amount * amount
        }

        static func convert(_ value: Double, from: Dimension, to: Dimension) -> Double {
            to.converter.value(fromBaseUnitValue: from.converter.baseUnitValue(fromValue: value))
        }

        /// A unit as people write it ("mi", "miles", "°F", "km/h", "fl oz"), and how the card writes it.
        static func unit(_ written: String) -> (unit: Dimension, symbol: String)? {
            let key = written.lowercased().replacingOccurrences(of: "degrees ", with: "°").replacingOccurrences(of: "degree ", with: "°")
                .replacingOccurrences(of: "square ", with: "sq ").replacingOccurrences(of: "²", with: "2").replacingOccurrences(of: "³", with: "3")
                .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
            switch key {
            case "m", "meter", "meters", "metre", "metres": return (UnitLength.meters, "m")
            case "km", "kms", "kilometer", "kilometers", "kilometre", "kilometres": return (UnitLength.kilometers, "km")
            case "cm", "centimeter", "centimeters", "centimetre", "centimetres": return (UnitLength.centimeters, "cm")
            case "mm", "millimeter", "millimeters", "millimetre", "millimetres": return (UnitLength.millimeters, "mm")
            case "mi", "mile", "miles": return (UnitLength.miles, "mi")
            case "yd", "yds", "yard", "yards": return (UnitLength.yards, "yd")
            case "ft", "foot", "feet", "'": return (UnitLength.feet, "ft")
            case "in", "inch", "inches", "\"": return (UnitLength.inches, "in")
            case "nmi", "nautical mile", "nautical miles": return (UnitLength.nauticalMiles, "nmi")
            case "g", "gram", "grams", "gramme", "grammes": return (UnitMass.grams, "g")
            case "kg", "kgs", "kilo", "kilos", "kilogram", "kilograms": return (UnitMass.kilograms, "kg")
            case "mg", "milligram", "milligrams": return (UnitMass.milligrams, "mg")
            case "lb", "lbs", "pound", "pounds": return (UnitMass.pounds, "lb")
            case "oz", "ounce", "ounces": return (UnitMass.ounces, "oz")
            case "st", "stone", "stones": return (UnitMass.stones, "st")
            case "t", "tonne", "tonnes", "metric ton", "metric tons": return (UnitMass.metricTons, "t")
            case "ton", "tons", "short ton", "short tons": return (UnitMass.shortTons, "tons")
            case "ml", "milliliter", "milliliters", "millilitre", "millilitres": return (UnitVolume.milliliters, "ml")
            case "l", "liter", "liters", "litre", "litres": return (UnitVolume.liters, "L")
            case "cl", "centiliter", "centiliters", "centilitre", "centilitres": return (UnitVolume.centiliters, "cl")
            case "dl", "deciliter", "deciliters", "decilitre", "decilitres": return (UnitVolume.deciliters, "dl")
            case "cup", "cups": return (UnitVolume.cups, "cups")
            case "tbsp", "tablespoon", "tablespoons": return (UnitVolume.tablespoons, "tbsp")
            case "tsp", "teaspoon", "teaspoons": return (UnitVolume.teaspoons, "tsp")
            case "fl oz", "floz", "fluid ounce", "fluid ounces": return (UnitVolume.fluidOunces, "fl oz")
            case "pt", "pint", "pints": return (UnitVolume.pints, "pt")
            case "qt", "quart", "quarts": return (UnitVolume.quarts, "qt")
            case "gal", "gallon", "gallons", "us gallon", "us gallons": return (UnitVolume.gallons, "gal")
            case "imperial gallon", "imperial gallons", "uk gallon", "uk gallons": return (UnitVolume.imperialGallons, "imp gal")
            case "m3", "cubic meter", "cubic meters", "cubic metre", "cubic metres": return (UnitVolume.cubicMeters, "m³")
            case "c", "°c", "celsius", "°celsius", "centigrade": return (UnitTemperature.celsius, "°C")
            case "f", "°f", "fahrenheit", "°fahrenheit": return (UnitTemperature.fahrenheit, "°F")
            case "k", "kelvin", "kelvins": return (UnitTemperature.kelvin, "K")
            case "km/h", "kmh", "kph", "kmph", "kilometers per hour", "kilometres per hour": return (UnitSpeed.kilometersPerHour, "km/h")
            case "mph", "mi/h", "miles per hour": return (UnitSpeed.milesPerHour, "mph")
            case "m/s", "meters per second", "metres per second": return (UnitSpeed.metersPerSecond, "m/s")
            case "kn", "kt", "kts", "knot", "knots": return (UnitSpeed.knots, "kn")
            case "m2", "sq m", "sqm", "sq meters", "sq metres": return (UnitArea.squareMeters, "m²")
            case "km2", "sq km", "sq kilometers", "sq kilometres": return (UnitArea.squareKilometers, "km²")
            case "ft2", "sq ft", "sqft", "sq feet", "sq foot": return (UnitArea.squareFeet, "sq ft")
            case "mi2", "sq mi", "sq miles": return (UnitArea.squareMiles, "sq mi")
            case "acre", "acres", "ac": return (UnitArea.acres, "acres")
            case "ha", "hectare", "hectares": return (UnitArea.hectares, "ha")
            case "s", "sec", "secs", "second", "seconds": return (UnitDuration.seconds, "s")
            case "min", "mins", "minute", "minutes": return (UnitDuration.minutes, "min")
            case "h", "hr", "hrs", "hour", "hours": return (UnitDuration.hours, "h")
            case "kcal", "calorie", "calories", "cal", "kilocalorie", "kilocalories": return (UnitEnergy.kilocalories, "kcal")
            case "kj", "kilojoule", "kilojoules": return (UnitEnergy.kilojoules, "kJ")
            case "j", "joule", "joules": return (UnitEnergy.joules, "J")
            case "kwh", "kilowatt hour", "kilowatt hours", "kilowatt-hour", "kilowatt-hours": return (UnitEnergy.kilowattHours, "kWh")
            case "psi": return (UnitPressure.poundsForcePerSquareInch, "psi")
            case "bar", "bars": return (UnitPressure.bars, "bar")
            case "kpa", "kilopascal", "kilopascals": return (UnitPressure.kilopascals, "kPa")
            case "hpa", "hectopascal", "hectopascals", "mbar", "millibar", "millibars": return (UnitPressure.hectopascals, "hPa")
            case "inhg", "in hg", "inches of mercury": return (UnitPressure.inchesOfMercury, "inHg")
            case "mmhg", "mm hg": return (UnitPressure.millimetersOfMercury, "mmHg")
            case "mpg", "miles per gallon", "mpg us": return (UnitFuelEfficiency.milesPerGallon, "mpg")
            case "mpg uk", "mpg imperial", "miles per imperial gallon": return (UnitFuelEfficiency.milesPerImperialGallon, "mpg (UK)")
            case "l/100km", "l/100 km", "liters per 100 km", "litres per 100 km", "liters per 100 kilometers", "litres per 100 kilometres":
                return (UnitFuelEfficiency.litersPer100Kilometers, "L/100 km")
            case "kb", "kilobyte", "kilobytes": return (UnitInformationStorage.kilobytes, "KB")
            case "mb", "megabyte", "megabytes": return (UnitInformationStorage.megabytes, "MB")
            case "gb", "gigabyte", "gigabytes": return (UnitInformationStorage.gigabytes, "GB")
            case "tb", "terabyte", "terabytes": return (UnitInformationStorage.terabytes, "TB")
            case "kib", "kibibyte", "kibibytes": return (UnitInformationStorage.kibibytes, "KiB")
            case "mib", "mebibyte", "mebibytes": return (UnitInformationStorage.mebibytes, "MiB")
            case "gib", "gibibyte", "gibibytes": return (UnitInformationStorage.gibibytes, "GiB")
            default: return nil
            }
        }
    }

    nonisolated struct Quotes: Codable, Equatable, Sendable {
        var items: [Quote]
        var note: String?

        nonisolated struct Quote: Codable, Equatable, Sendable, Hashable {
            var symbol: String
            var name: String?
            var exchange: String?
            var price: Double
            /// An ISO code; nil, the person's own.
            var currency: String?
            /// Since the last close, and as a percentage (1.2 is 1.2 %).
            var change: Double?
            var percent: Double?
            var open: Double?
            var low: Double?
            var high: Double?
            var yearLow: Double?
            var yearHigh: Double?
            var marketCap: Double?
            var volume: Double?
            /// When the price was read, and whether it is delayed.
            var asOf: Date?
            var asOfWords: String?
            var delayed: Bool?
            /// "Closed", "After hours", "Pre-market".
            var market: String?
            /// The day's prices in order, for its line.
            var points: [Double] = []
            /// A page for it, http or https.
            var url: String?

            /// Up (1), down (-1) or flat (0) since the last close.
            var direction: Int {
                let moved = change ?? percent ?? 0
                return moved > 0 ? 1 : moved < 0 ? -1 : 0
            }
        }
    }
}

nonisolated extension ReplyCards {
    static let maxIngredients = 40
    static let maxSteps = 30

    /// A recipe: its title, and ingredients or steps (lines, or objects with an amount, a unit
    /// and a name); its times as "25 min", "PT1H30M" or minutes; the servings its amounts are for.
    static func recipe(_ value: JSONValue) -> ReplyCard.Recipe? {
        guard let title = text(value["title"] ?? value["name"]) else { return nil }
        var ingredients: [ReplyCard.Recipe.Ingredient] = []
        func add(_ list: [JSONValue], section: String?) {
            for i in list where ingredients.count < maxIngredients {
                if let line = i.string?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                    ingredients.append(ReplyCard.Recipe.ingredient(String(line.prefix(160)), section: section))
                    continue
                }
                guard let name = text(i["name"] ?? i["item"] ?? i["ingredient"] ?? i["text"]) else { continue }
                let shelf = text(i["section"] ?? i["group"]).map { String($0.prefix(60)) } ?? section
                var made = ReplyCard.Recipe.Ingredient(name: String(name.prefix(120)), section: shelf)
                if let n = i["amount"]?.number ?? i["quantity"]?.number ?? i["qty"]?.number {
                    if n.isFinite, n >= 0 { made.amount = n }
                } else if let said = text(i["amount"] ?? i["quantity"] ?? i["qty"]) {
                    if let found = ReplyCard.Recipe.quantity(said), found.rest.isEmpty { made.amount = found.amount; made.upTo = found.upTo }
                    else { made.name = String((said + " " + made.name).prefix(140)) }
                }
                made.unit = text(i["unit"]).map { String($0.prefix(16)) }
                if let note = text(i["note"] ?? i["prep"] ?? i["preparation"]) { made.name += ", " + String(note.prefix(60)) }
                ingredients.append(made)
            }
        }
        if let list = (value["ingredients"] ?? value["items"])?.array { add(list, section: nil) }
        for group in value["sections"]?.array ?? value["groups"]?.array ?? [] {
            add(group["ingredients"]?.array ?? group["items"]?.array ?? [], section: text(group["title"] ?? group["name"]).map { String($0.prefix(60)) })
        }
        let written = value["steps"] ?? value["instructions"] ?? value["method"] ?? value["directions"]
        var steps = (written?.array ?? []).compactMap { text($0) ?? text($0["text"] ?? $0["step"] ?? $0["description"]) }
        if steps.isEmpty, let one = text(written) { steps = one.split(whereSeparator: \.isNewline).map(String.init) }
        steps = steps.map { $0.replacing(/^\s*(?:step\s*)?\d+\s*[.):-]\s*/.ignoresCase(), with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.prefix(maxSteps).map { String($0.prefix(600)) }
        guard !ingredients.isEmpty || !steps.isEmpty else { return nil }
        let serves = value["servings"] ?? value["serves"] ?? value["yield"]
        let servings = (serves?.number.map { Int($0.rounded()) } ?? text(serves).flatMap { $0.firstMatch(of: /\d+/).flatMap { Int($0.0) } })
            .flatMap { (1 ... 100).contains($0) ? $0 : nil }
        return .init(title: String(title.prefix(120)), summary: text(value["summary"] ?? value["description"]).map { String($0.prefix(200)) },
                     image: https(value["image"] ?? value["picture"] ?? value["photo"]),
                     source: text(value["source"] ?? value["site"] ?? value["author"]).map { String($0.prefix(40)) },
                     url: web(value["url"] ?? value["link"]),
                     prep: minutes(value["prep"] ?? value["prep_time"] ?? value["prepTime"]),
                     cook: minutes(value["cook"] ?? value["cook_time"] ?? value["cookTime"]),
                     total: minutes(value["total"] ?? value["total_time"] ?? value["totalTime"] ?? value["time"]),
                     servings: servings, ingredients: ingredients, steps: steps, note: text(value["note"]).map { String($0.prefix(200)) })
    }

    /// A length of time where a bare number is minutes: 25, "25", "25 min", "1h 30m", "PT1H30M".
    static func minutes(_ value: JSONValue?) -> TimeInterval? {
        if let n = value?.number { return n > 0 && n.isFinite ? n * 60 : nil }
        guard let said = text(value) else { return nil }
        if let n = Double(said) { return n > 0 && n.isFinite ? n * 60 : nil }
        return duration(.string(said.uppercased().hasPrefix("PT") ? String(said.dropFirst(2)) : said))
    }

    /// An address to open in the browser: http or https.
    static func web(_ value: JSONValue?) -> String? {
        text(value).flatMap { URL(string: $0)?.scheme.map { ["http", "https"].contains($0.lowercased()) } == true ? $0 : nil }
    }

    /// A picture's address: https only.
    static func https(_ value: JSONValue?) -> String? {
        text(value).flatMap { URL(string: $0)?.scheme?.lowercased() == "https" ? $0 : nil }
    }

    static let maxScans = 6

    /// A package: something to name it by (what's in it, the carrier, the number), and where it
    /// stands (the carrier's words) or when it should come.
    static func delivery(_ value: JSONValue, timeZone: TimeZone = .current) -> ReplyCard.Delivery? {
        let title = text(value["title"] ?? value["item"] ?? value["what"] ?? value["contents"]).map { String($0.prefix(120)) }
        let carrier = text(value["carrier"] ?? value["shipper"] ?? value["courier"]).map { String($0.prefix(40)) }
        let tracking = text(value["tracking"] ?? value["tracking_number"] ?? value["trackingNumber"] ?? value["number"]).map { String($0.prefix(40)) }
        let status = text(value["status"] ?? value["state"]).map { String($0.prefix(60)) }
        let expectedText = text(value["expected"] ?? value["eta"] ?? value["arrives"] ?? value["estimated_delivery"] ?? value["delivery_date"])
        let expected = expectedText.flatMap { ReplyCard.Agenda.when($0, timeZone: timeZone) }
        guard title != nil || carrier != nil || tracking != nil, status != nil || expectedText != nil || value["stage"] != nil else { return nil }
        var events: [ReplyCard.Delivery.Scan] = (value["events"]?.array ?? value["history"]?.array ?? value["scans"]?.array ?? [])
            .compactMap { scan($0, timeZone: timeZone) }
        if let last = (value["last"] ?? value["last_scan"] ?? value["latest"]).flatMap({ scan($0, timeZone: timeZone) }), !events.contains(last) {
            events.insert(last, at: 0)
        }
        if events.allSatisfy({ $0.at != nil }) { events.sort { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) } }
        let given = text(value["stage"]).flatMap { ReplyCard.Delivery.Stage(rawValue: $0.lowercased().replacingOccurrences(of: " ", with: "_")) }
        let read = ReplyCard.Delivery.stage(status) ?? ReplyCard.Delivery.stage(text(value["stage"]))
        var delivery = ReplyCard.Delivery(
            title: title, from: text(value["from"] ?? value["merchant"] ?? value["store"] ?? value["retailer"]).map { String($0.prefix(40)) },
            carrier: carrier, tracking: tracking, url: web(value["url"] ?? value["link"]),
            stage: given ?? read?.stage ?? .shipped, status: status, problem: read?.problem ?? false,
            expected: expected?.date, expectedAllDay: expected?.allDay ?? true,
            expectedWords: expected == nil ? expectedText.map { String($0.prefix(40)) } : nil,
            window: text(value["window"]).map { String($0.prefix(30)) },
            deliveredAt: text(value["delivered"] ?? value["delivered_at"]).flatMap { ReplyCard.Agenda.when($0, timeZone: timeZone) }.flatMap { $0.allDay ? nil : $0.date },
            events: Array(events.prefix(maxScans)), note: text(value["note"]).map { String($0.prefix(200)) })
        if delivery.stage == .delivered, delivery.deliveredAt == nil, let newest = events.first, newest.text.lowercased().contains("deliver") {
            delivery.deliveredAt = newest.at
        }
        return delivery
    }

    private static func scan(_ value: JSONValue, timeZone: TimeZone) -> ReplyCard.Delivery.Scan? {
        if let line = value.string?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty { return .init(text: String(line.prefix(80))) }
        guard let words = text(value["text"] ?? value["status"] ?? value["description"] ?? value["event"]) else { return nil }
        return .init(text: String(words.prefix(80)), place: text(value["place"] ?? value["location"] ?? value["where"]).map { String($0.prefix(60)) },
                     at: text(value["at"] ?? value["time"] ?? value["when"] ?? value["date"]).flatMap { ReplyCard.Agenda.when($0, timeZone: timeZone) }.map(\.date))
    }

    static let maxLegs = 6

    /// A flight, or a trip's flights ('legs'), each from one airport to another.
    static func trip(_ value: JSONValue) -> ReplyCard.Trip? {
        let listed = value["legs"]?.array ?? value["flights"]?.array ?? (value["from"] != nil || value["origin"] != nil ? [value] : [])
        let legs = listed.prefix(maxLegs).compactMap(flight)
        guard !legs.isEmpty else { return nil }
        return .init(title: text(value["title"]).map { String($0.prefix(80)) }, legs: Array(legs),
                     confirmation: text(value["confirmation"] ?? value["booking"] ?? value["pnr"] ?? value["record_locator"]).map { String($0.prefix(12)) },
                     note: text(value["note"]).map { String($0.prefix(200)) })
    }

    static func flight(_ value: JSONValue) -> ReplyCard.Trip.Flight? {
        let fromValue = value["from"] ?? value["origin"] ?? (value["departure"]?.object != nil ? value["departure"] : nil)
        let toValue = value["to"] ?? value["destination"] ?? (value["arrival"]?.object != nil ? value["arrival"] : nil)
        guard let from = airport(fromValue), let to = airport(toValue) else { return nil }
        let fromZone = text(fromValue?["timezone"] ?? fromValue?["tz"]), toZone = text(toValue?["timezone"] ?? toValue?["tz"])
        func time(_ v: JSONValue?, zone: String?) -> ReplyCard.Trip.Time? { text(v).flatMap { moment($0, zone: zone) } }
        let departs = time(fromValue?["time"] ?? fromValue?["scheduled"] ?? value["departs"] ?? value["departure_time"] ?? value["depart"]
                           ?? (value["departure"]?.string != nil ? value["departure"] : nil), zone: fromZone)
        let arrives = time(toValue?["time"] ?? toValue?["scheduled"] ?? value["arrives"] ?? value["arrival_time"] ?? value["arrive"]
                           ?? (value["arrival"]?.string != nil ? value["arrival"] : nil), zone: toZone)
        var departsNew = time(fromValue?["new_time"] ?? fromValue?["estimated"] ?? fromValue?["actual"] ?? value["departs_new"]
                              ?? value["estimated_departure"] ?? value["actual_departure"], zone: fromZone)
        var arrivesNew = time(toValue?["new_time"] ?? toValue?["estimated"] ?? toValue?["actual"] ?? value["arrives_new"]
                              ?? value["estimated_arrival"] ?? value["actual_arrival"], zone: toZone)
        if departsNew?.date == departs?.date { departsNew = nil }
        if arrivesNew?.date == arrives?.date { arrivesNew = nil }
        let words = text(value["status"]).map { String($0.prefix(40)) }
        func late(_ new: ReplyCard.Trip.Time?, _ old: ReplyCard.Trip.Time?) -> Bool {
            guard let new, let old else { return false }
            return new.date.timeIntervalSince(old.date) >= 5 * 60
        }
        let status = flightStatus(words) ?? (late(departsNew, departs) || late(arrivesNew, arrives) ? .delayed : .scheduled)
        var airline = text(value["airline"] ?? value["carrier"]).map { String($0.prefix(40)) }
        var number = text(value["number"] ?? value["flight"] ?? value["flight_number"]).map { String($0.prefix(12)) }
        // "TP238" as "TP 238".
        if let n = number?.uppercased(), let m = n.wholeMatch(of: /([A-Z][A-Z0-9]|[0-9][A-Z]|[A-Z]{3})\s*(\d{1,4}[A-Z]?)/) { number = "\(m.1) \(m.2)" }
        if airline == number { airline = nil }
        return .init(airline: airline, number: number, from: from, to: to, departs: departs, arrives: arrives,
                     departsNew: departsNew, arrivesNew: arrivesNew, status: status,
                     statusWords: words.flatMap { flightStatus($0) == nil ? $0 : nil },
                     seat: text(value["seat"]).map { String($0.prefix(8)) }, duration: minutes(value["duration"]),
                     aircraft: text(value["aircraft"] ?? value["plane"]).map { String($0.prefix(40)) })
    }

    /// A flight's status from the airline's words.
    static func flightStatus(_ words: String?) -> ReplyCard.Trip.Flight.Status? {
        guard let said = words?.lowercased().replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces), !said.isEmpty else { return nil }
        if said.contains("cancel") { return .cancelled }
        if said.contains("divert") { return .diverted }
        if said.contains("delay") || said.contains("late") { return .delayed }
        if said.contains("board") || said.contains("gate open") || said.contains("final call") || said.contains("gate closing") { return .boarding }
        if said.contains("landed") || said.contains("arrived") { return .landed }
        if ["departed", "en route", "en-route", "in air", "in flight", "airborne", "took off", "active", "in the air"].contains(where: said.contains) {
            return .departed
        }
        if said.contains("on time") || said == "ontime" || said.contains("on schedule") { return .onTime }
        if said.contains("scheduled") { return .scheduled }
        return nil
    }

    /// An airport: "LIS", "Lisbon (LIS)", or {code, city, name, terminal, gate}. A time isn't one.
    static func airport(_ value: JSONValue?) -> ReplyCard.Trip.Airport? {
        guard let value else { return nil }
        if let said = value.string?.trimmingCharacters(in: .whitespaces), !said.isEmpty {
            if said.firstMatch(of: /^\d{4}-\d{2}/) != nil { return nil }
            if said.wholeMatch(of: /[A-Za-z]{3}/) != nil { return .init(code: said.uppercased()) }
            if let m = said.wholeMatch(of: /(.+?)\s*\(([A-Za-z]{3})\)/) { return .init(code: String(m.2).uppercased(), city: String(m.1.prefix(40))) }
            return .init(city: String(said.prefix(40)))
        }
        let code = text(value["code"] ?? value["iata"] ?? value["airport_code"]).flatMap { $0.wholeMatch(of: /[A-Za-z]{3,4}/) != nil ? $0.uppercased() : nil }
        let city = text(value["city"]).map { String($0.prefix(40)) }
        let name = text(value["name"] ?? value["airport"]).map { String($0.prefix(60)) }
        guard code != nil || city != nil || name != nil else { return nil }
        var airport = ReplyCard.Trip.Airport(code: code, city: city, name: name, terminal: text(value["terminal"]).map { String($0.prefix(8)) },
                                             gate: text(value["gate"]).map { String($0.prefix(8)) })
        airport.latitude = number(value["latitude"] ?? value["lat"])
        airport.longitude = number(value["longitude"] ?? value["lon"] ?? value["lng"])
        return airport
    }

    /// A time and the zone it was written in: its offset ("…-04:00"), else `zone`'s (an IANA
    /// name), else the phone's. A day alone isn't one.
    static func moment(_ written: String, zone: String? = nil) -> ReplyCard.Trip.Time? {
        let named = zone.flatMap(TimeZone.init(identifier:))
        guard let found = ReplyCard.Agenda.when(written, timeZone: named ?? .current), !found.allDay else { return nil }
        let said = written.trimmingCharacters(in: .whitespaces)
        var offset: Int?
        if said.count > 16, let m = said.firstMatch(of: /(?:[Zz]|([+-])(\d{2}):?(\d{2}))$/) {
            if let sign = m.1, let hours = m.2.flatMap({ Int($0) }), let minutes = m.3.flatMap({ Int($0) }) {
                offset = (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
            } else {
                offset = 0
            }
        }
        return .init(date: found.date, offset: offset, zone: named?.identifier)
    }

    static let maxTitles = 6

    /// A film or a series, or a list of them ('items'); each with its name, the rest as found.
    static func shows(_ value: JSONValue) -> ReplyCard.Shows? {
        let list = value["items"]?.array ?? value["titles"]?.array ?? value["shows"]?.array ?? value["movies"]?.array
        var items = (list ?? [value]).prefix(maxTitles).compactMap(title)
        guard !items.isEmpty else { return nil }
        if let first = items.firstIndex(where: \.pick) { for i in items.indices where i != first { items[i].pick = false } }
        return .init(title: list == nil ? nil : text(value["title"]).map { String($0.prefix(80)) }, items: Array(items),
                     note: text(value["note"]).map { String($0.prefix(200)) })
    }

    static func title(_ value: JSONValue) -> ReplyCard.Shows.Title? {
        if let name = value.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return .init(name: String(name.prefix(100))) }
        guard let name = text(value["title"] ?? value["name"]) else { return nil }
        var title = ReplyCard.Shows.Title(name: String(name.prefix(100)))
        if let years = text(value["year"] ?? value["years"] ?? value["released"]), let m = years.firstMatch(of: /(\d{4})(?:\s*[–—-]\s*(\d{4})?)?/) {
            let first = Int(m.1)
            title.year = first
            title.endYear = m.2.flatMap { Int($0) }.flatMap { $0 > (first ?? 0) ? $0 : nil }
        }
        let format = (text(value["format"] ?? value["kind"] ?? value["media_type"] ?? value["media"]) ?? "").lowercased()
        title.seasons = (value["seasons"]?.number.map { Int($0.rounded()) } ?? text(value["seasons"]).flatMap { $0.firstMatch(of: /\d+/).flatMap { Int($0.0) } })
            .flatMap { $0 > 0 ? $0 : nil }
        title.runtime = minutes(value["runtime"] ?? value["length"] ?? value["duration"])
        title.format = ["movie", "film"].contains(where: format.contains) ? .movie
            : ["series", "tv", "show", "season"].contains(where: format.contains) ? .series
            : title.seasons != nil ? .series : title.runtime != nil ? .movie : nil
        title.poster = https(value["poster"] ?? value["image"] ?? value["picture"])
        title.ratings = ratings(value)
        title.genres = names(value["genres"] ?? value["genre"]).prefix(4).map { String($0.prefix(24)) }
        title.overview = text(value["overview"] ?? value["summary"] ?? value["plot"] ?? value["description"] ?? value["why"]).map { String($0.prefix(400)) }
        title.watch = names(value["watch"] ?? value["where"] ?? value["streaming"] ?? value["services"] ?? value["providers"]).prefix(6).map { String($0.prefix(30)) }
        title.url = web(value["url"] ?? value["link"] ?? value["info"])
        title.trailer = web(value["trailer"])
        title.by = text(value["director"] ?? value["creator"] ?? value["by"]).map { String($0.prefix(60)) }
        title.cast = names(value["cast"] ?? value["starring"]).prefix(4).map { String($0.prefix(40)) }
        title.pick = (value["pick"] ?? value["best"] ?? value["recommended"])?.bool == true
        return title
    }

    /// Names as a list, or a line split at its commas ("Netflix, Max"), or each as {name}.
    private static func names(_ value: JSONValue?) -> [String] {
        if let list = value?.array { return list.compactMap { text($0) ?? text($0["name"] ?? $0["service"] ?? $0["title"]) } }
        return text(value).map { $0.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } ?? []
    }

    /// Ratings as [{source, value}], {"IMDb": 8.7}, ["IMDb 8.7/10"], or a 'rating' alone.
    private static func ratings(_ value: JSONValue) -> [ReplyCard.Shows.Rating] {
        var out: [ReplyCard.Shows.Rating] = []
        if let list = value["ratings"]?.array {
            for r in list {
                if let line = text(r) {
                    if let m = line.wholeMatch(of: /(.*?[A-Za-z].*?)[:\s]+(\d[\d.,]*\s*(?:\/\s*\d+|%)?)/) { out.append(.init(source: String(m.1), value: String(m.2))) }
                    else { out.append(.init(value: line)) }
                } else if let said = text(r["value"] ?? r["score"] ?? r["rating"]) {
                    out.append(.init(source: text(r["source"] ?? r["name"] ?? r["site"]), value: said))
                }
            }
        } else if let object = value["ratings"]?.object {
            for key in object.keys.sorted() { if let said = text(object[key]) { out.append(.init(source: key, value: said)) } }
        }
        if out.isEmpty, let said = text(value["rating"] ?? value["score"]) { out.append(.init(source: text(value["rating_source"]), value: said)) }
        return out.prefix(3).map { .init(source: $0.source.map { String($0.prefix(20)) }, value: String($0.value.prefix(12))) }
    }

    /// A conversion: an amount from one unit or currency to another. A currency needs the rate
    /// (or the answer) the agent found; units the phone doesn't know need the answer.
    static func conversion(_ value: JSONValue) -> ReplyCard.Conversion? {
        var amount = number(value["amount"] ?? value["value"] ?? value["quantity"])
        var from = text(value["from"] ?? value["from_unit"] ?? value["unit"])
        var to = text(value["to"] ?? value["to_unit"])
        var result = number(value["result"] ?? value["answer"] ?? value["converted"])
        // "from": "5 mi", "to": "8.05 km".
        if let f = from, let m = f.wholeMatch(of: /\s*(\d[\d,.]*)\s*(.+)/) {
            if amount == nil { amount = self.amount(String(m.1)) }
            from = String(m.2)
        }
        if let t = to, let m = t.wholeMatch(of: /\s*(\d[\d,.]*)\s*(.+)/) {
            if result == nil { result = self.amount(String(m.1)) }
            to = String(m.2)
        }
        guard let from = from?.trimmingCharacters(in: .whitespaces), !from.isEmpty,
              let to = to?.trimmingCharacters(in: .whitespaces), !to.isEmpty else { return nil }
        let given = amount ?? 1
        guard given.isFinite, abs(given) < 1e15 else { return nil }
        var card = ReplyCard.Conversion(title: text(value["title"]).map { String($0.prefix(80)) }, amount: given,
                                        from: currencyCode(from) ?? String(from.prefix(24)), to: currencyCode(to) ?? String(to.prefix(24)),
                                        result: result.flatMap { $0.isFinite ? $0 : nil })
        if card.isCurrency {
            card.rate = number(value["rate"]).flatMap { $0 > 0 && $0.isFinite ? $0 : nil } ?? card.result.flatMap { given != 0 && $0 > 0 ? $0 / given : nil }
            guard card.rate != nil else { return nil }
            card.result = nil
        } else if card.units == nil, card.result == nil {
            return nil
        }
        let when = text(value["as_of"] ?? value["asOf"] ?? value["updated"] ?? value["time"] ?? value["date"])
        card.asOf = when.flatMap { ReplyCard.Agenda.when($0) }.map(\.date)
        card.asOfWords = card.asOf == nil ? when.map { String($0.prefix(40)) } : nil
        card.source = text(value["source"]).map { String($0.prefix(40)) }
        card.rows = (value["rows"]?.array ?? value["related"]?.array ?? []).prefix(8).compactMap { r in
            if let line = text(r), let mark = line.firstIndex(where: { $0 == ":" || $0 == "=" }) {
                let label = line[..<mark].trimmingCharacters(in: .whitespaces), said = line[line.index(after: mark)...].trimmingCharacters(in: .whitespaces)
                return label.isEmpty || said.isEmpty ? nil : .init(label: String(label.prefix(30)), value: String(said.prefix(40)))
            }
            guard let label = text(r["label"] ?? r["name"] ?? r["from"]), let said = text(r["value"] ?? r["to"]) else { return nil }
            return .init(label: String(label.prefix(30)), value: String(said.prefix(40)))
        }
        card.note = text(value["note"]).map { String($0.prefix(200)) }
        return card
    }

    static let maxQuotes = 4
    static let maxPoints = 120

    /// A share's quote, or a few ('items'): each a symbol and a price, the rest as found.
    static func quotes(_ value: JSONValue) -> ReplyCard.Quotes? {
        let listed = value["items"]?.array ?? value["quotes"]?.array ?? value["stocks"]?.array
            ?? (value["symbol"] != nil || value["ticker"] != nil ? [value] : [])
        let items = listed.prefix(maxQuotes).compactMap(quote)
        guard !items.isEmpty else { return nil }
        return .init(items: Array(items), note: text(value["note"]).map { String($0.prefix(200)) })
    }

    static func quote(_ value: JSONValue) -> ReplyCard.Quotes.Quote? {
        guard let symbol = text(value["symbol"] ?? value["ticker"]) else { return nil }
        let price = money(value["price"] ?? value["last"])
        guard let amount = price.amount else { return nil }
        var q = ReplyCard.Quotes.Quote(symbol: String(symbol.prefix(12)).uppercased(), price: amount)
        q.name = text(value["name"] ?? value["company"]).map { String($0.prefix(60)) }
        q.exchange = text(value["exchange"]).map { String($0.prefix(20)) }
        q.currency = currencyCode(text(value["currency"])) ?? price.currency
        q.change = signed(value["change"])
        q.percent = signed(value["percent"] ?? value["change_percent"] ?? value["changePercent"] ?? value["percent_change"])
        if let change = q.change, q.percent == nil, amount - change > 0 { q.percent = change / (amount - change) * 100 }
        if let percent = q.percent, q.change == nil, percent > -100 { q.change = amount - amount / (1 + percent / 100) }
        q.open = number(value["open"])
        q.low = number(value["low"] ?? value["day_low"])
        q.high = number(value["high"] ?? value["day_high"])
        if q.low == nil, let range = pair(value["day_range"] ?? value["range"]) { q.low = range.0; q.high = range.1 }
        if let low = q.low, let high = q.high, low > high { q.low = high; q.high = low }
        q.yearLow = number(value["year_low"] ?? value["52w_low"])
        q.yearHigh = number(value["year_high"] ?? value["52w_high"])
        if q.yearLow == nil, let range = pair(value["year_range"] ?? value["52w_range"] ?? value["52_week_range"]) { q.yearLow = range.0; q.yearHigh = range.1 }
        q.marketCap = big(value["market_cap"] ?? value["marketCap"] ?? value["cap"])
        q.volume = big(value["volume"])
        let when = text(value["as_of"] ?? value["asOf"] ?? value["time"] ?? value["updated"])
        q.asOf = when.flatMap { ReplyCard.Agenda.when($0) }.flatMap { $0.allDay ? nil : $0.date }
        q.asOfWords = q.asOf == nil ? when.map { String($0.prefix(40)) } : nil
        if let flag = value["delayed"]?.bool { q.delayed = flag }
        else if let said = text(value["delayed"]) { q.delayed = !["false", "no", "0", "real-time", "realtime"].contains(said.lowercased()) }
        q.market = text(value["market"] ?? value["session"]).map { String($0.prefix(24)) }
        var points = ((value["points"] ?? value["history"] ?? value["chart"] ?? value["prices"])?.array ?? []).compactMap { p in
            (p.number ?? number(p["price"] ?? p["close"] ?? p["value"])).flatMap { $0.isFinite ? $0 : nil }
        }
        if points.count > maxPoints {
            let step = Double(points.count - 1) / Double(maxPoints - 1)
            points = (0 ..< maxPoints).map { points[Int((Double($0) * step).rounded())] }
        }
        q.points = points.count >= 2 ? points : []
        q.url = web(value["url"] ?? value["link"])
        return q
    }

    /// A change with its sign: -1.23, "+1.23", "−0.5", "+1.2%", "(0.4%)".
    static func signed(_ value: JSONValue?) -> Double? {
        if let n = value?.number { return n.isFinite ? n : nil }
        guard var said = text(value) else { return nil }
        said = said.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "–", with: "-")
        let negative = said.contains("-") || (said.hasPrefix("(") && said.hasSuffix(")"))
        guard let m = said.firstMatch(of: /\d[\d,]*(?:\.\d+)?/), let n = Double(m.0.replacingOccurrences(of: ",", with: "")) else { return nil }
        return negative ? -n : n
    }

    /// Two numbers, as "187.20 - 191.05" or [187.2, 191.05].
    private static func pair(_ value: JSONValue?) -> (Double, Double)? {
        if let list = value?.array, list.count == 2, let a = number(list[0]), let b = number(list[1]) { return (a, b) }
        guard let said = text(value) else { return nil }
        let found = said.matches(of: /\d[\d,]*(?:\.\d+)?/).compactMap { Double($0.0.replacingOccurrences(of: ",", with: "")) }
        return found.count == 2 ? (found[0], found[1]) : nil
    }

    /// A large number as written: 2.71e12, "2.71T", "$512.3B", "45.2M", "1,234,567".
    static func big(_ value: JSONValue?) -> Double? {
        if let n = value?.number { return n.isFinite && n >= 0 ? n : nil }
        guard let said = text(value)?.lowercased(),
              let m = said.firstMatch(of: /(\d[\d,]*(?:\.\d+)?)\s*(trillion|billion|million|thousand|bn|mn|t|b|m|k)?\b/),
              let n = Double(m.1.replacingOccurrences(of: ",", with: "")) else { return nil }
        let scale: Double = switch m.2.map(String.init) ?? "" {
        case "t", "trillion": 1e12
        case "b", "bn", "billion": 1e9
        case "m", "mn", "million": 1e6
        case "k", "thousand": 1e3
        default: 1
        }
        return n * scale
    }
}
