import SwiftUI

/// Things to buy (`ReplyCard.purchase`, asked 2026-10-30: "a 'purchase' card for when asking for
/// purchase recommendations"), in the family of the day's answer cards: the agent's pick first and
/// larger (its picture, its price with the old one struck through, its stars, why, and View at the
/// store), then the others as rows that open in place to their pros, cons and specs. Held, a
/// product's link is copied, shared or opened. Chips under it ask the agent for more (Cheaper
/// options, Compare the top two, Why this one?), as an answer card's buttons do. Nothing on it
/// buys anything: a store's page opens in the browser.
///
/// A product's picture comes from the store's servers, which see the visit: only with Settings →
/// Appearance → Link previews on (`ProductImages`); else a drawing of what it is. What it shows is
/// worked out once, as the card is made (`Shown`), never as it draws.
struct PurchaseCard: View {
    let card: ReplyCard.Purchase
    let whole: ReplyCard
    private let shown: Shown
    @State private var open: Set<Int> = []
    @State private var answers = CardAnswers.shared
    @Environment(\.answerCard) private var answerer
    @Environment(\.pinnedCard) private var pinned
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    init(card: ReplyCard.Purchase, whole: ReplyCard) {
        self.card = card
        self.whole = whole
        shown = Shown(card)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardBox(spacing: 14) {
                header
                hero(shown.items[shown.lead])
                if !shown.others.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shown.others.enumerated()), id: \.element) { n, index in
                            if n > 0 { Divider() }
                            row(shown.items[index])
                        }
                    }
                    .padding(.top, -6)
                }
                if let note = card.note {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "info.circle").accessibilityHidden(true)
                        Text(note)
                    }
                    .chatFont(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            followUps
        }
        .animation(.snappy(duration: 0.25), value: open)
    }

    // MARK: Header

    private var header: some View {
        CardTitle(symbol: shown.symbol, title: card.title ?? String(localized: "Recommendations", comment: "A purchase card's title when the agent gave none"),
                  subtitle: shown.range)
    }

    // MARK: The pick

    private func hero(_ item: Shown.Item) -> some View {
        let isOpen = open.contains(item.id)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    ProductPicture(url: item.image, symbol: item.symbol, side: 96)
                    VStack(alignment: .leading, spacing: 4) {
                        if let badge = item.badge { BadgeTag(text: badge, tone: item.tone) }
                        Text(item.product.name).chatFont(.headline).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        if let brand = item.product.brand { Text(brand).chatFont(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                        if item.rating != nil { Stars(item: item).padding(.top, 2) }
                    }
                    Spacer(minLength: 0)
                }
                if let price = item.price {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: price).chatFont(.title2, weight: .bold).monospacedDigit()
                        if let was = item.was {
                            Text(verbatim: was).chatFont(.subheadline).strikethrough().foregroundStyle(.secondary).monospacedDigit()
                        }
                        if let saving = item.saving {
                            Text(saving).chatFont(.caption, weight: .semibold)
                                .foregroundStyle(Self.good)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Self.good.opacity(0.14), in: .capsule)
                        }
                    }
                }
                if let why = item.product.why { Text(why).chatFont(.subheadline).fixedSize(horizontal: false, vertical: true) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.spoken)
            .accessibilityActions { spokenActions(item) }
            if isOpen { details(item, inRow: false).transition(.opacity) }
            HStack(spacing: 10) {
                if let url = item.url {
                    Button { openURL(url) } label: {
                        HStack(spacing: 6) {
                            Text(item.view).lineLimit(1)
                            Image(systemName: "arrow.up.right").imageScale(.small).accessibilityHidden(true)
                        }
                        .chatFont(.subheadline, weight: .semibold)
                        .foregroundStyle(theme.userText)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(theme.accent, in: .capsule)
                        .contentShape(.capsule)
                    }
                    .accessibilityHint(Text("Opens the store's page in your browser", comment: "VoiceOver hint: a purchase card's View at <store>"))
                }
                if item.hasDetails {
                    Button { toggle(item.id) } label: {
                        Text(isOpen ? String(localized: "Less", comment: "Hides a purchase card's pros, cons and specs") : String(localized: "Details", comment: "Shows a purchase card's pros, cons and specs"))
                            .chatFont(.subheadline, weight: .semibold)
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 18)
                            .frame(maxWidth: item.url == nil ? .infinity : nil, minHeight: 44)
                            .background(theme.accent.opacity(0.12), in: .capsule)
                            .contentShape(.capsule)
                    }
                    .accessibilityHint(isOpen ? Self.hideHint : Self.showHint)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(scheme.cardPanel, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5) }
        #if os(iOS)
        .contentShape(.contextMenuPreview, .rect(cornerRadius: 16))
        #endif
        .contextMenu { actions(item) }
    }

    // MARK: The others

    private func row(_ item: Shown.Item) -> some View {
        let isOpen = open.contains(item.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button { toggle(item.id) } label: {
                HStack(spacing: 12) {
                    ProductPicture(url: item.image, symbol: item.symbol, side: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        if let badge = item.badge { BadgeTag(text: badge, tone: item.tone, small: true) }
                        Text(item.product.name).chatFont(.subheadline, weight: .semibold).lineLimit(2)
                        if let facts = item.facts {
                            HStack(spacing: 3) {
                                if item.rating != nil { Image(systemName: "star.fill").imageScale(.small).foregroundStyle(Self.star) }
                                Text(verbatim: facts).lineLimit(1)
                            }
                            .chatFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 1) {
                        if let price = item.price { Text(verbatim: price).chatFont(.subheadline, weight: .semibold).monospacedDigit().lineLimit(1) }
                        if let was = item.was { Text(verbatim: was).chatFont(.caption).strikethrough().foregroundStyle(.secondary).monospacedDigit() }
                    }
                    Image(systemName: "chevron.down")
                        .chatFont(.caption, weight: .semibold)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .opacity(item.hasDetails || item.url != nil ? 1 : 0)
                }
                .padding(.vertical, 12)
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.spoken)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isOpen ? Self.hideHint : Self.showHint)
            .accessibilityActions { spokenActions(item) }
            .contextMenu { actions(item) }
            if isOpen {
                details(item, inRow: true)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
    }

    // MARK: Opened

    private func details(_ item: Shown.Item, inRow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if inRow, let why = item.product.why { Text(why).chatFont(.subheadline).fixedSize(horizontal: false, vertical: true) }
            if !item.product.pros.isEmpty || !item.product.cons.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(item.product.pros.enumerated()), id: \.offset) { _, pro in
                        point(pro, symbol: "checkmark.circle.fill", colour: Self.good,
                              spoken: String(localized: "Pro: \(pro)", comment: "VoiceOver: a good point of a product on a purchase card"))
                    }
                    ForEach(Array(item.product.cons.enumerated()), id: \.offset) { _, con in
                        point(con, symbol: "minus.circle.fill", colour: Self.bad,
                              spoken: String(localized: "Con: \(con)", comment: "VoiceOver: a weak point of a product on a purchase card"))
                    }
                }
            }
            if !item.product.specs.isEmpty { specs(item.product.specs) }
            if inRow, let url = item.url {
                Button { openURL(url) } label: {
                    HStack(spacing: 6) {
                        Text(item.view).lineLimit(1)
                        Image(systemName: "arrow.up.right").imageScale(.small).accessibilityHidden(true)
                    }
                    .chatFont(.subheadline, weight: .semibold)
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(theme.accent.opacity(0.12), in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens the store's page in your browser", comment: "VoiceOver hint: a purchase card's View at <store>"))
            }
        }
        .padding(.leading, inRow ? 60 : 0)
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

    /// A few specs, two to a line, each its name over its value.
    private func specs(_ specs: [ReplyCard.Purchase.Spec]) -> some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(Array(stride(from: 0, to: specs.count, by: 2)), id: \.self) { start in
                GridRow {
                    ForEach(start ..< min(start + 2, specs.count), id: \.self) { i in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(specs[i].name).chatFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Text(specs[i].value).chatFont(.footnote, weight: .semibold).lineLimit(2)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.fill.quaternary, in: .rect(cornerRadius: 10))
                        .accessibilityElement(children: .combine)
                        .gridCellColumns(start + 1 == specs.count && specs.count.isMultiple(of: 2) == false ? 2 : 1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ item: Shown.Item) -> some View {
        if let url = item.url {
            Button(item.view, systemImage: "safari") { openURL(url) }
            Button("Copy Link", systemImage: "doc.on.doc") { UIPasteboard.general.url = url }
            ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
        }
    }

    /// The same for VoiceOver, which has no share sheet among its actions.
    @ViewBuilder
    private func spokenActions(_ item: Shown.Item) -> some View {
        if let url = item.url {
            Button(item.view) { openURL(url) }
            Button("Copy Link") { UIPasteboard.general.url = url }
        }
    }

    private func toggle(_ id: Int) {
        if open.contains(id) { open.remove(id) } else { open.insert(id) }
    }

    // MARK: Asking for more

    /// What a chip asks the agent: the English words it is known by in the note, and what it says.
    enum FollowUp: CaseIterable {
        case why, cheaper, compare

        var title: String {
            switch self {
            case .cheaper: String(localized: "Cheaper options", comment: "A chip under a purchase card: asks the agent for cheaper ones")
            case .compare: String(localized: "Compare the top two", comment: "A chip under a purchase card: asks the agent to compare its first two")
            case .why: String(localized: "Why this one?", comment: "A chip under a purchase card: asks the agent why it picked its pick")
            }
        }

        var symbol: String {
            switch self {
            case .cheaper: "tag"
            case .compare: "square.split.2x1"
            case .why: "questionmark.bubble"
            }
        }

        var hint: Text {
            switch self {
            case .cheaper: Text("Asks your agent for cheaper ones", comment: "VoiceOver hint: a purchase card's Cheaper options")
            case .compare: Text("Asks your agent to compare the first two", comment: "VoiceOver hint: a purchase card's Compare the top two")
            case .why: Text("Asks your agent why it picked this one", comment: "VoiceOver hint: a purchase card's Why this one?")
            }
        }

        /// How the note starts, which tells the chip again in a transcript read back.
        var marker: String {
            switch self {
            case .cheaper: "tapped \"Cheaper options\""
            case .compare: "tapped \"Compare the top two\""
            case .why: "tapped \"Why this one?\""
            }
        }

        static func asked(in said: String) -> FollowUp? { allCases.first { said.contains($0.marker) } }
    }

    /// The chips a card has: Compare with two or more, Why with a pick.
    static func followUps(_ card: ReplyCard.Purchase) -> [FollowUp] {
        FollowUp.allCases.filter { chip in
            switch chip {
            case .cheaper: true
            case .compare: card.items.count >= 2
            case .why: card.hasPick
            }
        }
    }

    /// The person's message and the note to the agent for a chip, in the card's order (the pick first).
    static func ask(_ chip: FollowUp, _ card: ReplyCard.Purchase) -> (shown: String, said: String) {
        let ordered = Shown.order(card).map { card.items[$0] }
        let title = card.title ?? "the recommendations"
        func named(_ p: ReplyCard.Purchase.Product) -> String {
            "\"\(p.name)\"" + (p.price.map { " (\($0.formatted(.number.precision(.fractionLength(0 ... 2)))) \(p.currency ?? ReplyCard.Purchase.homeCurrency()))" } ?? "")
        }
        let start = "the user \(chip.marker) under the purchase card \"\(title)\": "
        switch chip {
        case .cheaper:
            return (String(localized: "Show me cheaper options", comment: "The message a purchase card's Cheaper options sends"),
                    start + "look up cheaper ones than these (\(ordered.map(named).joined(separator: ", "))) with your tools and show them as a "
                        + "new 'purchase' card, the pick first; never make up prices, ratings or links. Then answer in a line")
        case .compare:
            let a = ordered[0], b = ordered[min(1, ordered.count - 1)]
            return (String(localized: "Compare the \(a.name) and the \(b.name)", comment: "The message a purchase card's Compare the top two sends, with the two products' names"),
                    start + "compare \(named(a)) and \(named(b)) side by side in a few lines: the price, what each does better, who each suits, "
                        + "and which to get")
        case .why:
            let pick = ordered[0]
            return (String(localized: "Why the \(pick.name)?", comment: "The message a purchase card's Why this one? sends, with the pick's name"),
                    start + "say in a few lines why you picked \(named(pick)) over the others, and what would make another one the better buy")
        }
    }

    @ViewBuilder
    private var followUps: some View {
        if let said = answers.said[whole.key] {
            let chip = FollowUp.asked(in: said)
            AnsweredLine(text: chip.map { String(localized: "Asked: \($0.title)", comment: "Under a purchase card once a chip was tapped, e.g. Asked: Cheaper options") }
                ?? String(localized: "Asked", comment: "Under a purchase card once a chip was tapped"))
                .padding(.leading, 6)
        } else if let answerer, !pinned {
            PillFlow(spacing: 6) {
                ForEach(Self.followUps(card), id: \.self) { chip in
                    Button { send(chip, answerer) } label: {
                        CardChip(title: chip.title, symbol: chip.symbol, busy: answerer.busy)
                    }
                    .buttonStyle(.plain)
                    .disabled(answerer.busy)
                    .accessibilityHint(chip.hint)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func send(_ chip: FollowUp, _ answerer: CardAnswerer) {
        let asked = Self.ask(chip, card)
        answerer.answer(whole, asked.shown, asked.said)
    }

    // MARK: Colours

    /// Pros, and a saving: green. Cons: orange. Both as the places card's open and closing.
    static let good = shade(light: (0.118, 0.541, 0.235), dark: (0.298, 0.761, 0.420))
    static let bad = shade(light: (0.698, 0.369, 0), dark: (0.941, 0.627, 0.251))
    static let star = Color(red: 1, green: 0.62, blue: 0.04)

    private static var showHint: Text { Text("Shows its pros, cons and details", comment: "VoiceOver hint: a product on a purchase card, closed") }
    private static var hideHint: Text { Text("Hides its details", comment: "VoiceOver hint: a product on a purchase card, open") }
}

// MARK: - What it shows

extension PurchaseCard {
    /// A badge's colour, by what it says.
    enum Tone: Equatable {
        case pick, value, budget, premium, other
        init(_ badge: String, pick: Bool) {
            let said = badge.lowercased()
            if pick { self = .pick }
            else if said.contains("value") { self = .value }
            else if ["budget", "cheap", "under", "afford"].contains(where: said.contains) { self = .budget }
            else if ["premium", "splurge", "luxury", "upgrade"].contains(where: said.contains) || said.split(separator: " ").contains("pro") { self = .premium }
            else { self = .other }
        }
    }

    /// The card's products as drawn, worked out once: prices in the person's way of writing money,
    /// stars, what VoiceOver reads.
    struct Shown {
        struct Item: Identifiable {
            var id: Int
            var product: ReplyCard.Purchase.Product
            var price: String?
            var was: String?
            /// "Save 20%".
            var saving: String?
            var rating: Double?
            /// "4.6 (12,480)": for the stars.
            var ratingText: String?
            /// "4.4 (3,201) · Amazon": a row's line under its name.
            var facts: String?
            var badge: String?
            var tone: Tone
            var symbol: String
            var url: URL?
            var image: URL?
            /// "View at Best Buy".
            var view: String
            var spoken: String
            var hasDetails: Bool
        }

        var items: [Item]
        var lead: Int
        /// The others, after the pick, in the agent's order.
        var others: [Int]
        /// "$199 – $379", with two or more priced alike.
        var range: String?
        /// What the card is of ("headphones"), else a bag.
        var symbol: String

        /// The pick first, then the rest as the agent gave them.
        static func order(_ card: ReplyCard.Purchase) -> [Int] {
            [card.lead] + card.items.indices.filter { $0 != card.lead }
        }

        init(_ card: ReplyCard.Purchase, locale: Locale = .current) {
            let home = ReplyCard.Purchase.homeCurrency(locale)
            let title = card.title ?? ""
            items = card.items.enumerated().map { i, p in
                let currency = p.currency ?? home
                let price = p.price.map { ReplyCard.Purchase.money($0, currency: currency, locale: locale) } ?? p.priceWords
                let was = p.wasPrice.map { ReplyCard.Purchase.money($0, currency: currency, locale: locale) }
                var saving: String?
                if let now = p.price, let before = p.wasPrice, before > 0 {
                    let off = Int(((before - now) / before * 100).rounded())
                    if off >= 1 { saving = String(localized: "Save \((Double(off) / 100).formatted(.percent.locale(locale)))", comment: "A product's discount on a purchase card, e.g. Save 20%") }
                }
                let reviews = p.reviews.map { $0 >= 10_000 ? $0.formatted(.number.notation(.compactName).locale(locale)) : $0.formatted(.number.locale(locale)) }
                let stars = p.rating.map { $0.formatted(.number.precision(.fractionLength(1)).locale(locale)) }
                let ratingText = stars.map { s in reviews.map { "\(s) (\($0))" } ?? s }
                let facts = [ratingText, p.retailer].compactMap(\.self)
                let badge = p.badge ?? (p.pick ? String(localized: "card.pick", defaultValue: "Pick", comment: "A tag on the agent's pick: the place, product or option it recommends") : nil)
                let view = p.retailer.map { String(localized: "View at \($0)", comment: "A purchase card's button: opens the product's page at a store, e.g. View at Best Buy") }
                    ?? String(localized: "View Product", comment: "A purchase card's button: opens the product's page, its store not named")
                let spokenRating = p.rating.map { String(localized: "rated \($0.formatted(.number.precision(.fractionLength(1)).locale(locale))) out of 5", comment: "A product's rating, read by VoiceOver") }
                let spokenReviews = p.reviews.map { String(localized: "\($0.formatted(.number.locale(locale))) reviews", comment: "How many reviews a product has, read by VoiceOver") }
                let spokenWas = was.map { String(localized: "was \($0)", comment: "A product's price before a sale, read by VoiceOver") }
                let spokenStore = p.retailer.map { String(localized: "at \($0)", comment: "Where a product is sold, read by VoiceOver: at Best Buy") }
                let spoken = [badge, p.name, p.brand, price, spokenWas, spokenRating, spokenReviews, spokenStore].compactMap(\.self).joined(separator: ", ")
                return Item(id: i, product: p, price: price, was: was, saving: saving, rating: p.rating, ratingText: ratingText,
                            facts: facts.isEmpty ? nil : facts.joined(separator: " · "), badge: badge, tone: Tone(badge ?? "", pick: p.pick),
                            symbol: PurchaseCard.symbol(for: [p.name, p.brand ?? ""].joined(separator: " "), else: title),
                            url: p.url.flatMap(URL.init(string:)), image: p.image.flatMap(URL.init(string:)), view: view, spoken: spoken,
                            hasDetails: !p.pros.isEmpty || !p.cons.isEmpty || !p.specs.isEmpty)
            }
            lead = card.lead
            others = Self.order(card).dropFirst().map { $0 }
            let priced = card.items.compactMap { p in p.price.map { ($0, p.currency ?? home) } }
            if priced.count >= 2, Set(priced.map(\.1)).count == 1, let low = priced.map(\.0).min(), let high = priced.map(\.0).max(), low < high {
                range = ReplyCard.Purchase.money(low, currency: priced[0].1, locale: locale) + " – " + ReplyCard.Purchase.money(high, currency: priced[0].1, locale: locale)
            }
            let named = PurchaseCard.symbol(for: title)
            symbol = named != "bag" ? named : (items.first.map { $0.symbol } ?? "bag")
        }
    }

    /// The symbol for what a product is, by a word in its name ("headphones", "laptop"), else in the
    /// card's title; else a bag.
    static func symbol(for text: String, else fallback: String = "") -> String {
        for said in [text, fallback] {
            let words = said.lowercased().split { !$0.isLetter && $0 != "-" }.map(String.init)
            for (word, symbol) in symbols where words.contains(where: { $0 == word || $0 == word + "s" || $0 == word + "es" }) {
                return symbol
            }
        }
        return "bag"
    }

    /// Words, and what they're drawn as: the first that a name has wins, so "headphone" comes
    /// before "phone".
    static let symbols: [(String, String)] = [
        ("earbud", "earbuds"), ("airpods", "earbuds"), ("headphone", "headphones"), ("headset", "headphones"),
        ("laptop", "laptopcomputer"), ("macbook", "laptopcomputer"), ("chromebook", "laptopcomputer"), ("notebook", "laptopcomputer"),
        ("tablet", "ipad"), ("ipad", "ipad"), ("smartphone", "iphone"), ("phone", "iphone"), ("iphone", "iphone"),
        ("smartwatch", "applewatch"), ("watch", "applewatch"), ("monitor", "display"), ("tv", "tv"), ("television", "tv"),
        ("speaker", "hifispeaker"), ("soundbar", "hifispeaker"), ("camera", "camera"), ("keyboard", "keyboard"),
        ("mouse", "computermouse"), ("printer", "printer"), ("router", "wifi.router"), ("console", "gamecontroller"),
        ("controller", "gamecontroller"), ("game", "gamecontroller"), ("coffee", "cup.and.saucer"), ("espresso", "cup.and.saucer"),
        ("shoe", "shoe"), ("sneaker", "shoe"), ("bike", "bicycle"), ("bicycle", "bicycle"), ("mattress", "bed.double"),
        ("bed", "bed.double"), ("chair", "chair"), ("sofa", "sofa"), ("couch", "sofa"), ("lamp", "lamp.desk"), ("tent", "tent"),
        ("backpack", "backpack"), ("suitcase", "suitcase"), ("luggage", "suitcase"), ("book", "book"), ("kindle", "book"),
        ("e-reader", "book"), ("stroller", "stroller"), ("toy", "teddybear"), ("gift", "gift"), ("shirt", "tshirt"),
        ("jacket", "tshirt"), ("dumbbell", "dumbbell"), ("fridge", "refrigerator"), ("refrigerator", "refrigerator"),
        ("dishwasher", "dishwasher"), ("washer", "washer"), ("oven", "oven"), ("microwave", "microwave"), ("pan", "frying.pan"),
        ("guitar", "guitars"), ("piano", "pianokeys"), ("sunglasses", "sunglasses"), ("glasses", "eyeglasses"),
    ]
}

// MARK: - Pieces

/// A product's picture: the store's, with Link previews on and once it has come; else a drawing
/// of what it is, on a wash of the theme's colour.
private struct ProductPicture: View {
    let url: URL?
    let symbol: String
    let side: CGFloat
    @State private var settings = Settings.shared
    @State private var image: UIImage?
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    init(url: URL?, symbol: String, side: CGFloat) {
        self.url = url
        self.symbol = symbol
        self.side = side
        _image = State(initialValue: ProductImages.shared.cached(url))
    }

    var body: some View {
        let allowed = ProductImages.allowed(url, settings: settings)
        ZStack {
            if allowed != nil, let image {
                Color.white
                Image(uiImage: image).resizable().scaledToFit().padding(side * 0.07)
            } else {
                LinearGradient(colors: [theme.accent.opacity(scheme == .dark ? 0.30 : 0.20), theme.accent.opacity(scheme == .dark ? 0.12 : 0.06)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: symbol)
                    .font(.system(size: side * 0.42, weight: .light))
                    .foregroundStyle(theme.accent)
            }
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: side * 0.2))
        .overlay { RoundedRectangle(cornerRadius: side * 0.2).strokeBorder(.separator.opacity(0.4), lineWidth: 0.5) }
        .accessibilityHidden(true)
        .task(id: allowed) {
            guard let url = allowed, image == nil else { return }
            let found = await ProductImages.shared.image(url)
            withAnimation(.easeOut(duration: 0.2)) { image = found }
        }
    }
}

/// A product's badge ("Best overall"), in its colour.
private struct BadgeTag: View {
    let text: String
    let tone: PurchaseCard.Tone
    var small = false
    @Environment(\.theme) private var theme

    var body: some View {
        let colour: Color = switch tone {
        case .pick: theme.accent
        case .value: PurchaseCard.good
        case .budget: .teal
        case .premium: .purple
        case .other: .indigo
        }
        Text(text)
            .textCase(.uppercase)
            .chatFont(small ? .caption2 : .caption2, weight: .bold).tracking(0.4)
            .lineLimit(1)
            .foregroundStyle(colour)
            .padding(.horizontal, small ? 5 : 6).padding(.vertical, small ? 1.5 : 2)
            .background(colour.opacity(0.14), in: .rect(cornerRadius: 6))
    }
}

/// Five stars to the half, the rating and how many reviews.
private struct Stars: View {
    let item: PurchaseCard.Shown.Item

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 1) {
                ForEach(0 ..< 5, id: \.self) { i in
                    Image(systemName: Self.symbol(item.rating ?? 0, i))
                }
            }
            .chatFont(.caption2)
            .foregroundStyle(PurchaseCard.star)
            if let text = item.ratingText {
                Text(verbatim: text).chatFont(.footnote).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    /// The `index`th star of a rating: full, half or empty.
    static func symbol(_ rating: Double, _ index: Int) -> String {
        let left = rating - Double(index)
        return left >= 0.75 ? "star.fill" : left >= 0.25 ? "star.leadinghalf.filled" : "star"
    }
}
