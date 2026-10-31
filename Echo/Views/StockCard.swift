import SwiftUI

/// A share's price, or a few (`ReplyCard.stock`, asked 2026-10-31): the symbol and the company,
/// the price, how far it moved since the last close (green and up, red and down, with an arrow, so
/// not by colour alone), the day's line where the agent gave its prices (drawn here, nothing
/// fetched), the day's range, the market's worth, and when the price was read and whether it is
/// delayed. Several: the first large, the rest as rows. Refresh asks the agent; nothing on it buys
/// or sells. What it shows is worked out as the card is made (`Shown`).
struct StockCard: View {
    let card: ReplyCard.Quotes
    let whole: ReplyCard
    private let shown: [Shown]

    init(card: ReplyCard.Quotes, whole: ReplyCard) {
        self.card = card
        self.whole = whole
        shown = card.items.map { Shown($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardBox(spacing: 14) {
                lead(shown[0])
                if shown.count > 1 {
                    VStack(spacing: 0) {
                        ForEach(Array(shown.dropFirst().enumerated()), id: \.offset) { n, quote in
                            if n > 0 { Divider() }
                            QuoteRow(quote: quote)
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 14))
                }
                if let asOf = Self.asOf(card.items[0]) {
                    Label { Text(verbatim: asOf) } icon: { Image(systemName: "clock") }
                        .chatFont(.caption).foregroundStyle(.secondary)
                }
                if let note = card.note { Text(note).chatFont(.caption).foregroundStyle(.secondary) }
            }
            CardChips(chips: [Refresh.refresh], whole: whole,
                      title: { _ in String(localized: "Refresh", comment: "A chip under a score card: asks the agent for the latest score") },
                      symbol: { _ in "arrow.clockwise" },
                      hint: { _ in Text("Asks your agent for the latest price", comment: "VoiceOver hint: a stock card's Refresh") },
                      asked: { $0.contains("tapped Refresh") ? .refresh : nil }, send: { _ in Self.refresh(card) })
        }
    }

    enum Refresh: Hashable { case refresh }

    private func lead(_ quote: Shown) -> some View {
        let q = quote.quote
        return VStack(alignment: .leading, spacing: 12) {
            CardTitle(symbol: q.direction < 0 ? "chart.line.downtrend.xyaxis" : "chart.line.uptrend.xyaxis", title: q.name ?? q.symbol, subtitle: q.name != nil ? quote.symbolLine : q.exchange)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: quote.price).chatFont(size: 34, weight: .bold).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                if let move = quote.move {
                    HStack(spacing: 8) {
                        ChangeTag(text: move, direction: q.direction)
                        if let market = q.market { Text(market).chatFont(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: quote.spoken))
            if !quote.line.isEmpty {
                Sparkline(points: quote.line, base: quote.base, direction: q.direction)
                    .frame(height: 72)
                    .accessibilityElement()
                    .accessibilityLabel(Text("The day's prices", comment: "VoiceOver: a stock card's line of the day's prices"))
                    .accessibilityValue(Text(verbatim: quote.lineSpoken))
            }
            if let range = quote.dayRange { DayRange(range: range, price: q.price) }
            if !quote.facts.isEmpty {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(Array(stride(from: 0, to: quote.facts.count, by: 2)), id: \.self) { start in
                        GridRow {
                            ForEach(start ..< min(start + 2, quote.facts.count), id: \.self) { i in
                                CardFact(name: quote.facts[i].name, value: quote.facts[i].value)
                                    .gridCellColumns(start + 1 == quote.facts.count && quote.facts.count.isMultiple(of: 2) == false ? 2 : 1)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Words

    static func refresh(_ card: ReplyCard.Quotes) -> (shown: String, said: String) {
        let symbols = card.items.map(\.symbol).joined(separator: ", ")
        return (String(localized: "Update \(symbols)", comment: "The message a stock card's Refresh sends, with the symbols, e.g. Update AAPL"),
                "the user tapped Refresh on the stock card: look up \(symbols) again with your tools and show a fresh 'stock' card with its "
                    + "'as_of' time; never guess a price, and never buy or sell anything")
    }

    /// "As of 4:00 PM · Delayed": when the price was read.
    static func asOf(_ q: ReplyCard.Quotes.Quote, now: Date = .now) -> String? {
        let when = q.asOf.map { date in
            Calendar.current.isDate(date, inSameDayAs: now) ? date.formatted(date: .omitted, time: .shortened)
                : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        } ?? q.asOfWords
        let parts = [when.map { String(localized: "As of \($0)", comment: "A stock card: when the price was read, e.g. As of 4:00 PM") },
                     q.delayed == true ? String(localized: "stock.delayed", defaultValue: "Delayed", comment: "A stock card: the price is not real-time (a delayed quote)") : nil].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static let down = shade(light: (0.80, 0.16, 0.13), dark: (1.0, 0.43, 0.39))
    static func colour(_ direction: Int) -> Color { direction > 0 ? PurchaseCard.good : direction < 0 ? down : .secondary }
    static func arrow(_ direction: Int) -> String { direction > 0 ? "arrow.up.right" : direction < 0 ? "arrow.down.right" : "arrow.right" }
}

extension StockCard {
    /// A quote as drawn, worked out once.
    struct Shown {
        var quote: ReplyCard.Quotes.Quote
        var price: String
        /// "+2.34 (+1.25%)".
        var move: String?
        var symbolLine: String
        /// Its prices, from 0 to 1 between their lowest and highest, and the last close in the same.
        var line: [Double]
        var base: Double?
        var lineSpoken: String
        var dayRange: (low: String, high: String, at: Double)?
        var facts: [(name: String, value: String)]
        var spoken: String

        init(_ q: ReplyCard.Quotes.Quote, locale: Locale = .current) {
            quote = q
            let code = q.currency ?? ReplyCard.Purchase.homeCurrency(locale)
            func money(_ x: Double) -> String { x.formatted(.currency(code: code).locale(locale).precision(.fractionLength(x < 1 ? 2 ... 4 : 2 ... 2))) }
            price = money(q.price)
            if let change = q.change {
                let sign = change > 0 ? "+" : change < 0 ? "−" : ""
                let figures = abs(change).formatted(.number.precision(.fractionLength(2)).locale(locale))
                let percent = q.percent.map { " (" + sign + (abs($0) / 100).formatted(.percent.precision(.fractionLength(2)).locale(locale)) + ")" } ?? ""
                move = sign + figures + percent
            }
            symbolLine = [q.symbol, q.exchange].compactMap(\.self).joined(separator: " · ")
            if q.points.count >= 2, let low = q.points.min(), let high = q.points.max() {
                let close = q.change.map { q.price - $0 }
                let floor = min(low, close ?? low), ceiling = max(high, close ?? high)
                let span = ceiling - floor
                line = q.points.map { span > 0 ? ($0 - floor) / span : 0.5 }
                base = close.map { span > 0 ? ($0 - floor) / span : 0.5 }
                lineSpoken = String(localized: "from \(money(q.points[0])) to \(money(q.points[q.points.count - 1])), low \(money(low)), high \(money(high))",
                                    comment: "VoiceOver: a stock card's line of the day's prices, where it started and ended, its low and high")
            } else {
                line = []
                lineSpoken = ""
            }
            if let low = q.low, let high = q.high, high > low {
                dayRange = (money(low), money(high), min(1, max(0, (q.price - low) / (high - low))))
            }
            var facts: [(String, String)] = []
            if let open = q.open { facts.append((String(localized: "stock.open", defaultValue: "Open", comment: "A stock card: the day's opening price (a noun)"), money(open))) }
            if let cap = q.marketCap {
                facts.append((String(localized: "Market cap", comment: "A stock card: the company's worth on the market"),
                              cap.formatted(.currency(code: code).locale(locale).notation(.compactName).precision(.significantDigits(1 ... 3)))))
            }
            if let volume = q.volume {
                facts.append((String(localized: "stock.volume", defaultValue: "Volume", comment: "A stock card: how many shares changed hands today"),
                              volume.formatted(.number.notation(.compactName).precision(.significantDigits(1 ... 3)).locale(locale))))
            }
            if let low = q.yearLow, let high = q.yearHigh {
                facts.append((String(localized: "52-week range", comment: "A stock card: its lowest and highest price over a year"), money(low) + " – " + money(high)))
            }
            self.facts = facts.map { (name: $0.0, value: $0.1) }
            let direction = q.direction > 0 ? String(localized: "up", comment: "VoiceOver: a stock card's price went up, e.g. up 2.34")
                : q.direction < 0 ? String(localized: "down", comment: "VoiceOver: a stock card's price went down, e.g. down 2.34") : nil
            let moved = q.change.map { abs($0).formatted(.number.precision(.fractionLength(2)).locale(locale)) }
            let percent = q.percent.map { (abs($0) / 100).formatted(.percent.precision(.fractionLength(2)).locale(locale)) }
            spoken = [q.name, q.symbol, price, [direction, moved, percent.map { "(\($0))" }].compactMap(\.self).joined(separator: " ").nilIfEmpty, q.market]
                .compactMap(\.self).joined(separator: ", ")
        }
    }
}

/// "▲ +2.34 (+1.25%)": the move, its arrow and its colour.
private struct ChangeTag: View {
    let text: String
    let direction: Int

    var body: some View {
        let colour = StockCard.colour(direction)
        HStack(spacing: 4) {
            Image(systemName: StockCard.arrow(direction)).fontWeight(.bold)
            Text(verbatim: text).monospacedDigit()
        }
        .chatFont(.subheadline, weight: .semibold)
        .foregroundStyle(colour)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(colour.opacity(0.13), in: .capsule)
    }
}

/// The day's prices as a line over a wash of its colour, the last close dashed.
private struct Sparkline: View {
    /// From 0 to 1.
    let points: [Double]
    let base: Double?
    let direction: Int

    var body: some View {
        let colour = StockCard.colour(direction)
        ZStack {
            Line(points: points, closed: true)
                .fill(LinearGradient(colors: [colour.opacity(0.22), colour.opacity(0)], startPoint: .top, endPoint: .bottom))
            if let base {
                BaseLine(level: base).stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            Line(points: points, closed: false).stroke(colour, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .padding(.vertical, 2)
    }

    nonisolated struct Line: Shape {
        let points: [Double]
        let closed: Bool

        func path(in rect: CGRect) -> Path {
            Path { path in
                guard points.count >= 2 else { return }
                let step = rect.width / CGFloat(points.count - 1)
                func at(_ i: Int) -> CGPoint { CGPoint(x: rect.minX + CGFloat(i) * step, y: rect.maxY - CGFloat(points[i]) * rect.height) }
                path.move(to: at(0))
                for i in 1 ..< points.count { path.addLine(to: at(i)) }
                if closed {
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                    path.closeSubpath()
                }
            }
        }
    }

    nonisolated struct BaseLine: Shape {
        let level: Double
        func path(in rect: CGRect) -> Path {
            let y = rect.maxY - CGFloat(level) * rect.height
            return Path { $0.move(to: CGPoint(x: rect.minX, y: y)); $0.addLine(to: CGPoint(x: rect.maxX, y: y)) }
        }
    }
}

/// The day's low and high, and where the price sits between them.
private struct DayRange: View {
    let range: (low: String, high: String, at: Double)
    let price: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Day's range", comment: "A stock card: the day's lowest and highest price").chatFont(.caption2).foregroundStyle(.secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1)).frame(height: 4)
                    Circle().fill(Color.primary).frame(width: 10, height: 10)
                        .offset(x: max(0, min(geometry.size.width - 10, geometry.size.width * range.at - 5)))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 10)
            HStack {
                Text(verbatim: range.low)
                Spacer()
                Text(verbatim: range.high)
            }
            .chatFont(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Day's range", comment: "A stock card: the day's lowest and highest price"))
        .accessibilityValue(Text(verbatim: range.low + " – " + range.high))
    }
}

/// Another quote: its symbol and name, a small line, its price and its move.
private struct QuoteRow: View {
    let quote: StockCard.Shown

    var body: some View {
        let q = quote.quote
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: q.symbol).chatFont(.subheadline, weight: .bold)
                if let name = q.name { Text(name).chatFont(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 6)
            if !quote.line.isEmpty {
                Sparkline(points: quote.line, base: quote.base, direction: q.direction).frame(width: 56, height: 24).accessibilityHidden(true)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: quote.price).chatFont(.subheadline, weight: .semibold).monospacedDigit()
                if let move = quote.move {
                    HStack(spacing: 2) {
                        Image(systemName: StockCard.arrow(q.direction)).imageScale(.small)
                        Text(verbatim: move).monospacedDigit()
                    }
                    .chatFont(.caption, weight: .semibold).foregroundStyle(StockCard.colour(q.direction)).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: quote.spoken))
    }
}
