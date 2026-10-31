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

/// A card's picture (a product's, from 2026-10-31 a recipe's and a poster): the site's, with
/// Link previews on and once it has come through `ProductImages`; else a drawing of what it is
/// (an SF Symbol) on a wash of the theme's colour. Always the same size, so nothing in the chat
/// moves when it comes.
struct CardPicture: View {
    let url: URL?
    let symbol: String
    /// Nil: as wide as there is room.
    var width: CGFloat?
    var height: CGFloat
    /// A photo or a poster fills its frame; a product sits whole on white.
    var fill = false
    var corner: CGFloat
    /// The picture's pixels across at most.
    var pixels: CGFloat
    @State private var settings = Settings.shared
    @State private var image: UIImage?
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    init(url: URL?, symbol: String, width: CGFloat?, height: CGFloat, fill: Bool = false, corner: CGFloat? = nil, pixels: CGFloat = ProductImages.side) {
        self.url = url
        self.symbol = symbol
        self.width = width
        self.height = height
        self.fill = fill
        self.corner = corner ?? min(width ?? height, height) * 0.2
        self.pixels = pixels
        _image = State(initialValue: ProductImages.shared.cached(url, side: pixels))
    }

    /// A product's square.
    init(url: URL?, symbol: String, side: CGFloat) {
        self.init(url: url, symbol: symbol, width: side, height: side)
    }

    var body: some View {
        let allowed = ProductImages.allowed(url, settings: settings)
        ZStack {
            if allowed != nil, let image {
                if fill {
                    Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill() }
                } else {
                    Color.white
                    Image(uiImage: image).resizable().scaledToFit().padding(min(width ?? height, height) * 0.07)
                }
            } else {
                LinearGradient(colors: [theme.accent.opacity(scheme == .dark ? 0.30 : 0.20), theme.accent.opacity(scheme == .dark ? 0.12 : 0.06)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: symbol)
                    .font(.system(size: min(width ?? height, height) * 0.42, weight: .light))
                    .foregroundStyle(theme.accent)
            }
        }
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .clipShape(.rect(cornerRadius: corner))
        .overlay { RoundedRectangle(cornerRadius: corner).strokeBorder(.separator.opacity(0.4), lineWidth: 0.5) }
        .accessibilityHidden(true)
        .task(id: allowed) {
            guard let url = allowed, image == nil else { return }
            let found = await ProductImages.shared.image(url, side: pixels)
            withAnimation(.easeOut(duration: 0.2)) { image = found }
        }
    }
}

/// A small fact on a card, its name over its value ("Prep" / "15 min", "Open" / "$188.10").
struct CardFact: View {
    let name: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).chatFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(verbatim: value).chatFont(.footnote, weight: .semibold).monospacedDigit().lineLimit(2)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// A wide button that opens a page in the browser ("Track at UPS ↗"): the theme's colour, or a
/// wash of it.
struct LinkCapsule: View {
    let title: String
    var filled = true
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1)
            Image(systemName: "arrow.up.right").imageScale(.small).accessibilityHidden(true)
        }
        .chatFont(.subheadline, weight: .semibold)
        .foregroundStyle(filled ? theme.userText : theme.accent)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(filled ? theme.accent : theme.accent.opacity(0.12), in: .capsule)
        .contentShape(.capsule)
    }
}

/// The chips under a card that ask the agent for more, or what was asked once one was tapped:
/// the purchase card's way, for the cards after it.
struct CardChips<Chip: Hashable>: View {
    let chips: [Chip]
    let whole: ReplyCard
    let title: (Chip) -> String
    let symbol: (Chip) -> String
    let hint: (Chip) -> Text
    /// The chip a note tells, in a transcript read back.
    let asked: (String) -> Chip?
    let send: (Chip) -> (shown: String, said: String)
    @State private var answers = CardAnswers.shared
    @Environment(\.answerCard) private var answerer
    @Environment(\.pinnedCard) private var pinned

    var body: some View {
        if let said = answers.said[whole.key] {
            AnsweredLine(text: asked(said).map { String(localized: "Asked: \(title($0))", comment: "Under a purchase card once a chip was tapped, e.g. Asked: Cheaper options") }
                ?? String(localized: "Asked", comment: "Under a purchase card once a chip was tapped"))
                .padding(.leading, 6)
        } else if let answerer, !pinned, !chips.isEmpty {
            PillFlow(spacing: 6) {
                ForEach(chips, id: \.self) { chip in
                    Button {
                        let message = send(chip)
                        answerer.answer(whole, message.shown, message.said)
                    } label: {
                        CardChip(title: title(chip), symbol: symbol(chip), busy: answerer.busy)
                    }
                    .buttonStyle(.plain)
                    .disabled(answerer.busy)
                    .accessibilityHint(hint(chip))
                }
            }
            .padding(.horizontal, 2)
        }
    }
}
