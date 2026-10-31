import SwiftUI

/// An amount in other units, or another currency (`ReplyCard.conversion`, asked 2026-10-31): the
/// answer large ("5 mi = 8.05 km"), how one unit goes into the other, and a few amounts around it.
/// The amount can be changed on the card: units are worked out again on the phone (Foundation's
/// `UnitConverter`); a currency only at the rate the agent found, with when it was found, never a
/// live one. Nothing on it is fetched.
struct ConversionCard: View {
    let card: ReplyCard.Conversion
    private let shown: Shown
    @State private var input: String
    @State private var typedWidth: CGFloat = 28
    @FocusState private var focused: Bool
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    init(card: ReplyCard.Conversion) {
        self.card = card
        shown = Shown(card)
        _input = State(initialValue: Self.figure(card.amount, plain: true))
    }

    /// The amount typed, read leniently ("1,5", "-40"); else the agent's.
    private var amount: Double {
        let typed = input.trimmingCharacters(in: .whitespaces)
        let negative = typed.hasPrefix("-") || typed.hasPrefix("−")
        guard let found = ReplyCards.amount(String(typed.drop { $0 == "-" || $0 == "−" })), typed.contains(where: \.isNumber) else { return card.amount }
        return negative ? -found : found
    }

    var body: some View {
        let amount = self.amount
        let result = card.convert(amount)
        CardBox(spacing: 14) {
            CardTitle(symbol: card.isCurrency ? "banknote" : "arrow.left.arrow.right",
                      title: card.title ?? shown.title, subtitle: shown.subtitle)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField(String(localized: "Amount", comment: "A conversion card's field for the amount to convert"), text: $input)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                        .focused($focused)
                        .chatFont(.title3, weight: .semibold)
                        .monospacedDigit()
                        .textFieldStyle(.plain)
                        .submitLabel(.done)
                        // As wide as what is typed, so its unit sits right after it.
                        .frame(width: min(220, max(28, typedWidth + 6)), alignment: .leading)
                        .background {
                            Text(verbatim: input.isEmpty ? "0" : input).chatFont(.title3, weight: .semibold).monospacedDigit()
                                .fixedSize().hidden()
                                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { typedWidth = $0 }
                        }
                        .accessibilityIdentifier("conversion.amount")
                        .accessibilityLabel(Text("Amount in \(shown.fromName)", comment: "VoiceOver: a conversion card's amount field, e.g. Amount in miles"))
                        .accessibilityHint(card.isCurrency ? Text("Changes the amount; worked out at the rate shown", comment: "VoiceOver hint: a currency card's amount field")
                                                           : Text("Changes the amount; the answer is worked out again", comment: "VoiceOver hint: a conversion card's amount field"))
                    Text(verbatim: shown.fromSymbol).chatFont(.title3).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "pencil").foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(scheme.cardPanel, in: .rect(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(focused ? theme.accent : Color.secondary.opacity(0.25), lineWidth: focused ? 1.5 : 0.5) }
                .contentShape(.rect)
                .onTapGesture { focused = true }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "=").chatFont(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(verbatim: result.map { shown.money($0, in: card.to) ?? Self.figure($0) } ?? "–")
                        .chatFont(size: 34, weight: .bold).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .contentTransition(.numericText())
                    if !card.isCurrency { Text(verbatim: shown.toSymbol).chatFont(.title3, weight: .semibold).foregroundStyle(.secondary) }
                }
                .padding(.leading, 4)
                .accessibilityElement(children: .combine)
                .animation(.snappy(duration: 0.2), value: result)
            }
            if let formula = shown.formula {
                Text(verbatim: formula).chatFont(.footnote).foregroundStyle(.secondary).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            }
            table(amount)
            if let rate = shown.rate {
                Label { Text(verbatim: rate) } icon: { Image(systemName: "clock") }
                    .chatFont(.caption).foregroundStyle(.secondary)
            }
            if let note = card.note { Text(note).chatFont(.caption).foregroundStyle(.secondary) }
        }
    }

    /// A few amounts around the one asked, each converted; then the agent's own rows.
    private func table(_ amount: Double) -> some View {
        let values = Self.nearby(amount, temperature: card.units?.from is UnitTemperature)
        let rows: [(String, String)] = values.compactMap { v in
            card.convert(v).map { (shown.money(v, in: card.from) ?? (Self.figure(v) + " " + shown.fromSymbol),
                                   shown.money($0, in: card.to) ?? (Self.figure($0) + " " + shown.toSymbol)) }
        } + card.rows.map { ($0.label, $0.value) }
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { n, row in
                if n > 0 { Divider() }
                HStack {
                    Text(verbatim: row.0).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(verbatim: row.1).fontWeight(.medium)
                }
                .chatFont(.subheadline).monospacedDigit()
                .padding(.horizontal, 12).padding(.vertical, 9)
                .accessibilityElement(children: .combine)
            }
        }
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 12))
    }

    // MARK: Figures

    /// "8.05", "26,400", "0.0311": as many figures as are worth reading.
    static func figure(_ x: Double, plain: Bool = false, locale: Locale = .current) -> String {
        guard x.isFinite else { return "–" }
        let size = abs(x)
        let style: FloatingPointFormatStyle<Double> = size >= 1_000 ? .number.precision(.fractionLength(0))
            : size >= 100 ? .number.precision(.fractionLength(0 ... 1))
            : size >= 1 || size == 0 ? .number.precision(.fractionLength(0 ... 2))
            : .number.precision(.significantDigits(1 ... 3))
        return x.formatted((plain ? style.grouping(.never) : style).locale(locale))
    }

    /// Amounts either side of the one asked: 1, 2, 5, 10, 20, 50… (temperatures by tens), two
    /// below and two above.
    static func nearby(_ amount: Double, temperature: Bool) -> [Double] {
        if temperature {
            let base = (amount / 10).rounded(.down) * 10
            return [base - 10, base, base + 10, base + 20].filter { $0 != amount }.prefix(4).map(\.self)
        }
        let nice = (-3 ... 9).flatMap { k in [1.0, 2, 5].map { $0 * pow(10, Double(k)) } }
        guard amount > 0 else { return [1, 2, 5, 10] }
        let below = nice.filter { $0 < amount * 0.999 }.suffix(2)
        let above = nice.filter { $0 > amount * 1.001 }.prefix(4 - below.count)
        return Array(below) + Array(above)
    }
}

extension ConversionCard {
    /// What the card says besides the amounts, worked out once.
    struct Shown {
        var title: String
        var subtitle: String?
        var fromSymbol: String
        var toSymbol: String
        /// "miles", "US dollars": for VoiceOver.
        var fromName: String
        var formula: String?
        /// "Rate from 9:00 AM, Oct 31 · ECB".
        var rate: String?
        /// A currency's way of writing money, where it is one.
        let currency: Bool
        let locale: Locale

        init(_ card: ReplyCard.Conversion, locale: Locale = .current) {
            self.locale = locale
            currency = card.isCurrency
            if card.isCurrency {
                fromSymbol = card.from
                toSymbol = card.to
                let a = locale.localizedString(forCurrencyCode: card.from) ?? card.from, b = locale.localizedString(forCurrencyCode: card.to) ?? card.to
                fromName = a
                title = String(localized: "conversion.title", defaultValue: "\(a) to \(b)", comment: "A conversion card's title: what from and to, e.g. US Dollar to Euro")
                subtitle = "\(card.from) → \(card.to)"
                if let rate = card.rate {
                    let one = rate.formatted(.number.precision(.significantDigits(1 ... 5)).locale(locale))
                    let back = (1 / rate).formatted(.number.precision(.significantDigits(1 ... 5)).locale(locale))
                    formula = "1 \(card.from) = \(one) \(card.to) · 1 \(card.to) = \(back) \(card.from)"
                }
                let when = card.asOf.map { $0.formatted(.dateTime.month(.abbreviated).day().hour().minute()) } ?? card.asOfWords
                rate = [when.map { String(localized: "Rate from \($0)", comment: "A currency card: when the rate it uses was found, e.g. Rate from Oct 31, 9:00 AM") }
                            ?? String(localized: "At the rate your agent found", comment: "A currency card whose rate came with no time"),
                        card.source].compactMap(\.self).joined(separator: " · ")
            } else {
                let units = card.units
                fromSymbol = units?.fromSymbol ?? card.from
                toSymbol = units?.toSymbol ?? card.to
                let names = MeasurementFormatter()
                names.unitStyle = .long
                names.locale = locale
                let a = units.map { names.string(from: $0.from) } ?? card.from, b = units.map { names.string(from: $0.to) } ?? card.to
                fromName = a
                title = String(localized: "conversion.title", defaultValue: "\(a.prefix(1).uppercased() + a.dropFirst()) to \(b)", comment: "A conversion card's title: what from and to, e.g. US Dollar to Euro")
                subtitle = units == nil ? String(localized: "As your agent worked it out", comment: "A conversion card for units Redde doesn't know: the agent's own answer") : nil
                if let units {
                    formula = Self.formula(units.from, units.to, fromSymbol, toSymbol, locale: locale)
                }
                if let words = card.asOfWords ?? card.source { rate = words }
            }
        }

        /// A currency amount in its own way ("€92.14"); nil for units.
        func money(_ x: Double, in code: String) -> String? {
            guard currency, x.isFinite else { return nil }
            return x.formatted(.currency(code: code).locale(locale))
        }

        /// "1 mi = 1.609 km · 1 km = 0.6214 mi", "°F = °C × 9/5 + 32", "L/100 km = 235.2 ÷ mpg".
        static func formula(_ from: Dimension, _ to: Dimension, _ a: String, _ b: String, locale: Locale) -> String? {
            let style = FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1 ... 4)).locale(locale)
            if from is UnitTemperature {
                let known: [String: String] = [
                    "°C°F": "°F = °C × 9/5 + 32", "°F°C": "°C = (°F − 32) × 5/9", "°CK": "K = °C + 273.15",
                    "K°C": "°C = K − 273.15", "°FK": "K = (°F − 32) × 5/9 + 273.15", "K°F": "°F = (K − 273.15) × 9/5 + 32",
                ]
                return known[a + b]
            }
            // Litres per 100 km go down as miles per gallon go up: one is a number divided by the other.
            if from is UnitFuelEfficiency, (from == UnitFuelEfficiency.litersPer100Kilometers) != (to == UnitFuelEfficiency.litersPer100Kilometers) {
                let k = ReplyCard.Conversion.convert(1, from: from, to: to)
                return "\(b) = \(k.formatted(style)) ÷ \(a)"
            }
            guard from != to else { return nil }
            let one = ReplyCard.Conversion.convert(1, from: from, to: to), back = ReplyCard.Conversion.convert(1, from: to, to: from)
            return "1 \(a) = \(one.formatted(style)) \(b) · 1 \(b) = \(back.formatted(style)) \(a)"
        }
    }
}
