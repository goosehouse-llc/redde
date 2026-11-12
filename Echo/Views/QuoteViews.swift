import SwiftUI

/// What the next message quotes, above the composer's field (`QuotedText`): who said it, the
/// start of it, and a button to take it away.
struct QuoteStrip: View {
    let quote: QuotedText
    let remove: () -> Void
    @Environment(\.theme) private var theme

    private var heading: String {
        if quote.mine { return String(localized: "Quoting yourself", comment: "Above the message field: the next message quotes one of the person's own") }
        if let speaker = quote.speaker { return String(localized: "Quoting \(speaker)", comment: "Above the message field: whose words the next message quotes (an agent's or bot's name)") }
        return String(localized: "Quoting", comment: "Above the message field: the next message quotes this")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(theme.accent).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(heading)
                    .chatFont(.caption, weight: .semibold)
                    .foregroundStyle(theme.accent)
                Text(quote.text)
                    .chatFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.vertical, -6)
            .accessibilityLabel(String(localized: "Remove quote"))
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12).padding(.vertical, 8)
        // As the field is drawn: the chat scrolls on under it.
        .background(theme.usesGlass ? AnyShapeStyle(.clear) : AnyShapeStyle(theme.surfaceColor), in: .rect(cornerRadius: 18))
        .glassEffect(theme.usesGlass ? .regular : .identity, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quoteStrip")
    }
}

/// The quote a message of the person's opens with (`Quote.split`), over its bubble; a tap brings
/// the quoted message on screen.
struct QuoteBlock: View {
    let quote: String
    var alignment: HorizontalAlignment = .trailing
    let open: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(theme.accent.opacity(0.7)).frame(width: 3)
                Text(quote)
                    .chatFont(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: min(theme.bubbleRadius, 12)))
        }
        .buttonStyle(.plain)
        .padding(alignment == .trailing ? .leading : .trailing, 48)
        .accessibilityLabel(String(localized: "Quoting: \(quote)", comment: "VoiceOver: the quote a message of the person's opens with"))
        .accessibilityHint(String(localized: "Shows the quoted message", comment: "VoiceOver: what a tap on a quote does"))
    }
}
