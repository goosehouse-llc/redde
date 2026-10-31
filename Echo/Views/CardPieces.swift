import SwiftUI

/// A card's title (the purchase, home, reminder, comparison and score cards, 2026-10-30): its mark
/// on a wash of the theme's colour, its title and a line under it, as the answer cards' header.
struct CardTitle: View {
    var symbol: String
    var title: String
    var subtitle: String? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .chatFont(.subheadline, weight: .semibold)
                .foregroundStyle(theme.accent)
                .frame(width: 30, height: 30)
                .background(theme.accent.opacity(0.14), in: .rect(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).chatFont(.subheadline, weight: .semibold)
                if let subtitle {
                    Text(verbatim: subtitle).chatFont(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A chip under a card that asks the agent for more ("Cheaper options", "Refresh"): a capsule as
/// wide as its words, a finger's height to tap.
struct CardChip: View {
    let title: String
    let symbol: String
    var busy = false
    @Environment(\.theme) private var theme

    var body: some View {
        Label(title, systemImage: symbol)
            .chatFont(.subheadline, weight: .medium)
            .foregroundStyle(busy ? Color.secondary : theme.accent)
            .lineLimit(1)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(theme.surfaceColor, in: .capsule)
            .overlay { Capsule().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) }
            .frame(minHeight: 44)
            .contentShape(.capsule)
    }
}

/// What is good and less good about something: green checks, then orange minuses.
struct ProsCons: View {
    let pros: [String]
    let cons: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(pros.enumerated()), id: \.offset) { _, pro in
                point(pro, symbol: "checkmark.circle.fill", colour: PurchaseCard.good,
                      spoken: String(localized: "Pro: \(pro)", comment: "VoiceOver: a good point of a product on a purchase card"))
            }
            ForEach(Array(cons.enumerated()), id: \.offset) { _, con in
                point(con, symbol: "minus.circle.fill", colour: PurchaseCard.bad,
                      spoken: String(localized: "Con: \(con)", comment: "VoiceOver: a weak point of a product on a purchase card"))
            }
        }
    }

    private func point(_ text: String, symbol: String, colour: Color, spoken: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(colour).imageScale(.small)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .chatFont(.footnote)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}

/// A card's quieter wide button: the theme's colour on a wash of it.
struct TintedCapsule: View {
    let title: String
    var symbol: String? = nil
    var role: ButtonRole? = nil
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let colour = role == .destructive ? Color.red : theme.accent
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).imageScale(.small).accessibilityHidden(true) }
            Text(title).lineLimit(1)
        }
        .chatFont(.subheadline, weight: .semibold)
        .foregroundStyle(colour)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(colour.opacity(0.12), in: .capsule)
        .opacity(isEnabled ? 1 : 0.5)
        .contentShape(.capsule)
    }
}
