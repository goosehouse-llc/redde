import Foundation

/// US or metric units (asked 2026-10-29: "have a standard / metric toggle. I'm getting everything
/// in meters, but am in the US"): Settings → Agent → Units. Automatic follows the iPhone's region.
/// The agent is told with each message, as the reply language is (on the Hermes API in the
/// turn's instructions, on the Dashboard as a note on the message, which Redde hides), when it
/// is US, or metric chosen here: a model left alone writes metres. The weather the plugin and the
/// phone look up, and the distances on cards, follow it too.
nonisolated enum MeasureUnits: String, CaseIterable, Identifiable, Sendable {
    case automatic = ""
    case us
    case metric

    var id: String { rawValue }

    /// Settings' key; read straight from the defaults, so code off the main actor has it too.
    static let key = "measureUnits"

    static var chosen: MeasureUnits {
        MeasureUnits(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .automatic
    }

    /// US units, as chosen, or by the region.
    static func usesUS(_ chosen: MeasureUnits = chosen, locale: Locale = .current) -> Bool {
        switch chosen {
        case .us: true
        case .metric: false
        case .automatic: locale.measurementSystem == .us
        }
    }

    /// What the agent is told: US, or metric when chosen here; nothing for metric by the region.
    static func forAgent(_ chosen: MeasureUnits = chosen, locale: Locale = .current) -> MeasureUnits? {
        if usesUS(chosen, locale: locale) { return .us }
        return chosen == .metric ? .metric : nil
    }

    /// For the turn's instructions (the Hermes API, the fast lane).
    static func instruction(_ units: MeasureUnits) -> String {
        units == .us
            ? "Give measurements in US customary units (miles, feet, °F, mph, pounds, ounces), unless the user asks for others."
            : "Give measurements in metric units (kilometres, metres, °C, km/h, kilograms, grams), unless the user asks for others."
    }

    /// On the message itself (the Dashboard takes no instructions).
    static func note(_ units: MeasureUnits) -> String {
        units == .us ? usNote : metricNote
    }

    private static let usNote = "\n\n(Use US units.)"
    private static let metricNote = "\n\n(Use metric units.)"

    /// A message read back, without its note.
    static func strip(_ text: String) -> String {
        for note in [usNote, metricNote] where text.hasSuffix(note) {
            return String(text.dropLast(note.count))
        }
        return text
    }

    /// The temperature letter for weather lookups: "F" or "C".
    static var temperature: String { usesUS() ? "F" : "C" }

    /// A distance as the person reads it: miles (feet when short) or kilometres (metres).
    static func distance(_ meters: Double, us: Bool = usesUS()) -> String {
        let style = Measurement<UnitLength>.FormatStyle(width: .abbreviated, usage: .asProvided,
                                                        numberFormatStyle: .number.precision(.fractionLength(0 ... 1)))
        if us {
            // Feet, to the nearest ten, up to a fifth of a mile; miles after.
            let miles = meters / 1609.344
            return miles < 0.2 ? Measurement(value: (meters * 3.28084 / 10).rounded() * 10, unit: UnitLength.feet).formatted(style)
                : Measurement(value: miles, unit: UnitLength.miles).formatted(style)
        }
        return meters < 1000 ? Measurement(value: meters.rounded(), unit: UnitLength.meters).formatted(style)
            : Measurement(value: meters / 1000, unit: UnitLength.kilometers).formatted(style)
    }
}
