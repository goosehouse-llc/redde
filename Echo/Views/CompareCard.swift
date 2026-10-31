import SwiftUI

/// Two to four things side by side (`ReplyCard.compare`, asked 2026-10-30: "which is better, A or
/// B?"; things to buy are a purchase card): the agent's verdict on top, then each criterion with
/// the options' values in columns, a check on the better one where the agent says. With three or
/// four, the columns scroll sideways on a phone. An option's name opens its pros and cons under
/// the table.
struct CompareCard: View {
    let card: ReplyCard.Comparison
    /// The option whose pros and cons are open.
    @State private var open: Int?
    @Environment(\.theme) private var theme

    /// How wide the card's inside is, measured: three or four columns narrower than `column`
    /// each scroll sideways at that width instead.
    @State private var width: CGFloat = 1_000
    static let column: CGFloat = 104
    private var wide: Bool { card.options.count > 2 && width < CGFloat(card.options.count) * (Self.column + 8) - 8 }

    var body: some View {
        CardBox(spacing: 14) {
            CardTitle(symbol: "square.split.2x1", title: card.title ?? String(localized: "Comparison", comment: "A comparison card's title when the agent gave none"),
                      subtitle: card.options.map(\.name).joined(separator: " · "))
            if let verdict = card.verdict {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(theme.accent).accessibilityHidden(true)
                    Text(verdict).chatFont(.subheadline, weight: .semibold).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(theme.accent.opacity(0.1), in: .rect(cornerRadius: 14))
                .accessibilityElement(children: .combine)
            }
            if wide {
                ScrollView(.horizontal, showsIndicators: false) {
                    table.frame(width: Self.column * CGFloat(card.options.count) + 8 * CGFloat(card.options.count - 1))
                }
            } else {
                table
            }
            if let open, card.options.indices.contains(open) {
                let option = card.options[open]
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(option.name).chatFont(.subheadline, weight: .semibold)
                        Spacer(minLength: 0)
                        Button { withAnimation(.snappy) { self.open = nil } } label: {
                            Image(systemName: "xmark").chatFont(.caption, weight: .bold).foregroundStyle(.secondary)
                                .frame(width: 44, height: 44).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, -12)
                        .accessibilityLabel(Text("Close", comment: "VoiceOver: closes an option's pros and cons on a comparison card"))
                    }
                    ProsCons(pros: option.pros, cons: option.cons)
                }
                .padding(12)
                .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 14))
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.25), value: open)
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 32 } action: { width = $0 }
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(card.options.enumerated()), id: \.offset) { index, option in
                    head(option, index: index).frame(width: wide ? Self.column : nil).frame(maxWidth: wide ? nil : .infinity)
                }
            }
            .padding(.bottom, 4)
            ForEach(Array(card.rows.enumerated()), id: \.offset) { _, row in
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.criterion).textCase(.uppercase).tracking(0.4).chatFont(.caption2, weight: .semibold).foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(row.values.enumerated()), id: \.offset) { index, value in
                            cell(value, best: row.best == index)
                                .padding(.horizontal, 10)
                                .frame(width: wide ? Self.column : nil, alignment: .leading)
                                .frame(maxWidth: wide ? nil : .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.vertical, 10)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.spoken(row, options: card.options))
            }
        }
    }

    private func head(_ option: ReplyCard.Comparison.Option, index: Int) -> some View {
        let picked = card.pick == index
        let more = !option.pros.isEmpty || !option.cons.isEmpty
        return Button { if more { withAnimation(.snappy) { open = open == index ? nil : index } } } label: {
            VStack(alignment: .leading, spacing: 3) {
                if picked {
                    Text(String(localized: "card.pick", defaultValue: "Pick", comment: "A tag on the agent's pick: the place, product or option it recommends"))
                        .textCase(.uppercase).tracking(0.4).chatFont(.caption2, weight: .bold).foregroundStyle(theme.accent)
                }
                Text(option.name).chatFont(.subheadline, weight: .bold).lineLimit(2).multilineTextAlignment(.leading)
                if more {
                    HStack(spacing: 3) {
                        Text("Pros and cons", comment: "Under an option of a comparison card: opens its pros and cons")
                        Image(systemName: open == index ? "chevron.up" : "chevron.down").imageScale(.small)
                    }
                    .chatFont(.caption, weight: .medium).foregroundStyle(theme.accent)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .background(picked ? theme.accent.opacity(0.12) : Color.primary.opacity(0.05), in: .rect(cornerRadius: 12))
            .overlay { if open == index { RoundedRectangle(cornerRadius: 12).strokeBorder(theme.accent, lineWidth: 1.5) } }
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!more)
        .accessibilityLabel(picked ? Text("\(option.name), the pick", comment: "VoiceOver: the agent's pick of a comparison card") : Text(option.name))
        .accessibilityHint(more ? Text("Shows its pros and cons", comment: "VoiceOver hint: an option of a comparison card") : Text(verbatim: ""))
    }

    private func cell(_ value: String, best: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if best { Image(systemName: "checkmark.circle.fill").foregroundStyle(PurchaseCard.good).imageScale(.small) }
            Text(value.isEmpty ? "–" : value)
                .chatFont(.footnote, weight: best ? .semibold : .regular)
                .foregroundStyle(value.isEmpty ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Battery: Aurora 30 h, Tidal 40 h, better: Tidal".
    static func spoken(_ row: ReplyCard.Comparison.Row, options: [ReplyCard.Comparison.Option]) -> String {
        let values = options.indices.map { "\(options[$0].name) \(row.values[$0].isEmpty ? "–" : row.values[$0])" }.joined(separator: ", ")
        let best = row.best.map { String(localized: "better: \(options[$0].name)", comment: "VoiceOver: which option of a comparison card is better on a row") }
        return [row.criterion + ": " + values, best].compactMap(\.self).joined(separator: ", ")
    }
}
