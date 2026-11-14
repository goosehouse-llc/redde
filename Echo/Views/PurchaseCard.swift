import SwiftUI

/// Things to buy (`ReplyCard.purchase`, asked 2026-10-30: "a 'purchase' card for when asking for
/// purchase recommendations"), in the family of the day's answer cards. Laid out as the design he
/// picked on 2026-11-13 ("F"): the pick's picture and name, its price large and where, a deal
/// meter against what it usually sells for (or its store's old price), why, and View at the store
/// as a filled button; then every store or product folded into one row ("5 stores checked") that
/// opens to rows that open in place to their pros, cons and specs; then when the prices were
/// checked, and Watch price. Held, a product's link is copied, shared or opened. Chips under it ask
/// the agent for more (Cheaper options, Compare the top two, Why this one?), as an answer card's
/// buttons do. Nothing on it buys anything: a store's page opens in the browser.
///
/// A product's picture comes from the store's servers, which see the visit: only with Settings →
/// Appearance → Link previews on (`ProductImages`); else a drawing of what it is. What it shows is
/// worked out once, as the card is made (`Shown`), never as it draws.
struct PurchaseCard: View {
    let card: ReplyCard.Purchase
    let whole: ReplyCard
    private let shown: Shown
    @State private var open: Set<Int> = []
    /// The other stores (or products), folded under the pick until tapped.
    @State private var showsAll = false
    @State private var answers = CardAnswers.shared
    @Environment(\.answerCard) private var answerer
    @Environment(\.pinnedCard) private var pinned
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var appScheme
    /// The card's own appearance, not the app's (Card Appearance can differ): `ColorScheme.onCard`.
    private var scheme: ColorScheme { appScheme.onCard }
    @Environment(\.openURL) private var openURL

    init(card: ReplyCard.Purchase, whole: ReplyCard) {
        self.card = card
        self.whole = whole
        shown = Shown(card)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardBox(spacing: 16) {
                let pick = shown.items[shown.lead]
                heading(pick)
                verdict(pick)
                if let meter = shown.meter { DealMeter(meter: meter) }
                if let why = pick.product.why {
                    Text(why).chatFont(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let url = pick.url { ListingLink(url: url, named: pick.view, prominent: true) }
                if shown.items.count > 1 { everyOne }
                footer(pick)
            }
            followUps
        }
        .animation(.snappy(duration: 0.25), value: open)
        .animation(.snappy(duration: 0.25), value: showsAll)
    }

    // MARK: The pick

    /// Its picture beside its name; one product at several stores, the card's title for it. Under
    /// the name, its brand and whether its store has it; several products, their title over it.
    private func heading(_ pick: Shown.Item) -> some View {
        HStack(spacing: 12) {
            ProductPicture(image: pick.image, page: pick.url, symbol: pick.symbol, side: 64)
            VStack(alignment: .leading, spacing: 3) {
                if !shown.byStore, let title = card.title {
                    Text(title).chatFont(.footnote, weight: .semibold).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(shown.byStore ? (card.title ?? pick.product.name) : pick.product.name)
                    .chatFont(.headline).fixedSize(horizontal: false, vertical: true)
                if let line = [pick.product.brand, pick.stock].compactMap(\.self).joined(separator: " · ").nilIfEmpty {
                    Text(verbatim: line).chatFont(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if !shown.byStore, pick.rating != nil { Stars(item: pick).padding(.top, 1) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The agent's word for it ("BEST PICK"), then its price, large, and where.
    @ViewBuilder
    private func verdict(_ pick: Shown.Item) -> some View {
        if let price = pick.price {
            VStack(alignment: .leading, spacing: 2) {
                if card.hasPick, let badge = pick.badge {
                    Text(badge).textCase(.uppercase).chatFont(.caption, weight: .bold).tracking(1).foregroundStyle(theme.accent).lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: price).chatFont(.largeTitle, weight: .bold).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    if let store = pick.product.retailer {
                        Text(String(localized: "at \(store)", comment: "Where a product is sold, read by VoiceOver: at Best Buy"))
                            .chatFont(.body).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                // A store's old price, when there's no meter to show it on.
                if shown.meter == nil, let was = pick.was {
                    HStack(spacing: 6) {
                        Text(verbatim: was).strikethrough().foregroundStyle(.secondary).monospacedDigit()
                        if let saving = pick.saving { Text(saving).fontWeight(.semibold).foregroundStyle(Self.good) }
                    }
                    .chatFont(.subheadline)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Every store (or product) folded into one row, "5 stores checked", the next best and how
    /// many weren't there under it (asked 2026-11-13: "too tall so make it come collapsed").
    /// Tapped, it opens to them all, the pick first and those with nothing to sell last, greyed.
    private var everyOne: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { showsAll.toggle() } label: {
                HStack(spacing: 12) {
                    Image(systemName: shown.byStore ? "storefront" : "square.stack")
                        .chatFont(.subheadline).foregroundStyle(.secondary).frame(width: 24).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shown.everyTitle).chatFont(.subheadline, weight: .semibold)
                        if let line = shown.everyLine { Text(verbatim: line).chatFont(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.down")
                        .chatFont(.caption, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsAll ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(showsAll ? Self.foldHint : Self.unfoldHint)
            .accessibilityIdentifier("purchase.every")
            if showsAll {
                Divider()
                ForEach(Array(shown.listed.enumerated()), id: \.element) { n, index in
                    if n > 0 { Divider().padding(.leading, 14) }
                    row(shown.items[index], isPick: index == shown.lead)
                }
                .transition(.opacity)
            }
        }
        .background(scheme.cardPanel, in: .rect(cornerRadius: 16))
        .clipShape(.rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5) }
    }

    /// When the prices were checked, and Watch Price, which asks the agent to keep an eye on it.
    @ViewBuilder
    private func footer(_ pick: Shown.Item) -> some View {
        let watcher = pick.product.price != nil && answers.said[whole.key] == nil && !pinned ? answerer : nil
        if shown.note != nil || watcher != nil {
            HStack(spacing: 10) {
                if let note = shown.note {
                    Text(note).chatFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let watcher {
                    Button { send(.watch, watcher) } label: {
                        Label(FollowUp.watch.title, systemImage: FollowUp.watch.symbol)
                            .chatFont(.subheadline, weight: .medium)
                            .foregroundStyle(watcher.busy ? Color.secondary : Color.primary)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1) }
                            .contentShape(.rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(watcher.busy)
                    .accessibilityHint(FollowUp.watch.hint)
                }
            }
        }
    }

    // MARK: The others

    /// A store's price (one product), or a product (several): the pick first, tinted and tagged.
    /// Tapped, it opens to its pros, cons, specs and its page.
    private func row(_ item: Shown.Item, isPick: Bool) -> some View {
        let isOpen = open.contains(item.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button { toggle(item.id) } label: {
                HStack(spacing: 12) {
                    if shown.byStore {
                        StoreMark(name: item.product.retailer ?? item.product.name, isPick: isPick)
                    } else {
                        ProductPicture(image: item.image, page: item.url, symbol: item.symbol, side: 48)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(shown.byStore ? (item.product.retailer ?? item.product.name) : item.product.name)
                                .chatFont(.subheadline, weight: .semibold).lineLimit(2)
                            if isPick, let badge = item.badge { BadgeTag(text: badge, tone: item.tone, small: true) }
                        }
                        if !isPick, let badge = item.badge { BadgeTag(text: badge, tone: item.tone, small: true) }
                        if let line = shown.byStore ? item.storeLine : item.facts {
                            HStack(spacing: 3) {
                                if item.rating != nil { Image(systemName: "star.fill").imageScale(.small).foregroundStyle(Self.star).accessibilityHidden(true) }
                                Text(verbatim: line).lineLimit(1)
                            }
                            .chatFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 1) {
                        if let price = item.price {
                            Text(verbatim: price).chatFont(isPick ? .headline : .subheadline, weight: isPick ? .bold : .semibold).monospacedDigit().lineLimit(1)
                        }
                        if let was = item.was { Text(verbatim: was).chatFont(.caption).strikethrough().foregroundStyle(.secondary).monospacedDigit() }
                        if isPick, let saving = item.saving {
                            Text(saving).chatFont(.caption2, weight: .semibold).foregroundStyle(Self.good).lineLimit(1)
                        }
                        if let stock = item.stock {
                            Text(stock).chatFont(.caption2, weight: .semibold).foregroundStyle(item.inStock ? Self.good : Self.bad).lineLimit(1)
                        }
                    }
                    Image(systemName: "chevron.down")
                        .chatFont(.caption, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .opacity(item.hasDetails || (item.url != nil && !isPick) ? 1 : 0)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
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
                details(item, inRow: !isPick)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .background(isPick ? theme.accent.opacity(0.09) : .clear)
        .opacity(item.available ? 1 : 0.55)
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
            if inRow, let url = item.url { ListingLink(url: url, named: item.view, prominent: false) }
        }
        .padding(.leading, shown.byStore ? 48 : 60)
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
        case why, cheaper, compare, watch

        var title: String {
            switch self {
            case .cheaper: String(localized: "Cheaper options", comment: "A chip under a purchase card: asks the agent for cheaper ones")
            case .compare: String(localized: "Compare the top two", comment: "A chip under a purchase card: asks the agent to compare its first two")
            case .why: String(localized: "Why this one?", comment: "A chip under a purchase card: asks the agent why it picked its pick")
            case .watch: String(localized: "Watch price", comment: "A purchase card's button, at its foot: asks the agent to keep an eye on the pick's price")
            }
        }

        var symbol: String {
            switch self {
            case .cheaper: "tag"
            case .compare: "square.split.2x1"
            case .why: "questionmark.bubble"
            case .watch: "bell"
            }
        }

        var hint: Text {
            switch self {
            case .cheaper: Text("Asks your agent for cheaper ones", comment: "VoiceOver hint: a purchase card's Cheaper options")
            case .compare: Text("Asks your agent to compare the first two", comment: "VoiceOver hint: a purchase card's Compare the top two")
            case .why: Text("Asks your agent why it picked this one", comment: "VoiceOver hint: a purchase card's Why this one?")
            case .watch: Text("Asks your agent to tell you when the price drops", comment: "VoiceOver hint: a purchase card's Watch price")
            }
        }

        /// How the note starts, which tells the chip again in a transcript read back.
        var marker: String {
            switch self {
            case .cheaper: "tapped \"Cheaper options\""
            case .compare: "tapped \"Compare the top two\""
            case .why: "tapped \"Why this one?\""
            case .watch: "tapped \"Watch price\""
            }
        }

        static func asked(in said: String) -> FollowUp? { allCases.first { said.contains($0.marker) } }
    }

    /// The chips a card has: Compare with two or more products, Why with a pick.
    static func followUps(_ card: ReplyCard.Purchase) -> [FollowUp] {
        FollowUp.allCases.filter { chip in
            switch chip {
            case .cheaper: true
            case .compare: card.items.count >= 2 && !Shown.oneProduct(card)   // one product at several stores: nothing to compare
            case .why: card.hasPick
            case .watch: false   // at the card's foot, not among the chips
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
        case .watch:
            let pick = ordered[0]
            let at = (pick.retailer.map { " at \($0)" } ?? "") + (pick.url.map { " (\($0))" } ?? "")
            return (String(localized: "Watch the price of the \(pick.name)", comment: "The message a purchase card's Watch price sends, with the pick's name"),
                    start + "keep an eye on the price of \(named(pick))\(at) with keep_an_eye_on (find it with tool_search if it isn't loaded), "
                        + "each morning for 30 days, and tell me only when it drops below what it is now or goes out of stock. Then answer in a line")
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

    private static var unfoldHint: Text { Text("Shows them all", comment: "VoiceOver hint: a purchase card's folded row of every store or product, closed") }
    private static var foldHint: Text { Text("Hides them", comment: "VoiceOver hint: a purchase card's row of every store or product, open") }
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
            /// A store's row, for one product at several: its rating, else the product's name there.
            var storeLine: String?
            var badge: String?
            var tone: Tone
            var symbol: String
            var url: URL?
            var image: URL?
            /// "View at Best Buy".
            var view: String
            var spoken: String
            /// "rated 4.5 out of 5, 12,480 reviews": the stars, to VoiceOver.
            var spokenStars: String?
            var hasDetails: Bool
            /// "In stock" or "Out of stock", as its store's page said (plugin 1.14.0).
            var stock: String?
            var inStock = false
            /// Something to sell: a price, and not out of stock. The others show greyed, last.
            var available: Bool { price != nil && product.availability != .outOfStock }
        }

        var items: [Item]
        var lead: Int
        /// The others, after the pick, in the agent's order.
        var others: [Int]
        /// The pick, then the others.
        var ordered: [Int] { [lead] + others }
        /// One product at several stores (a price check): rows are named by their store.
        var byStore: Bool
        /// "$199 – $379", with two or more priced alike.
        var range: String?
        /// What the card is of ("headphones"), else a bag.
        var symbol: String
        /// The line under it: the agent's (or the plugin's) note, else when its prices were checked.
        var note: String?
        /// Where the pick's price sits against what it usually sells for, or its store's old price.
        var meter: Meter?
        /// Every one, folded: the pick, those with something to sell, then those without.
        var listed: [Int] { [lead] + others.filter { items[$0].available } + others.filter { !items[$0].available } }
        /// "5 stores checked", "3 options": the folded row's name.
        var everyTitle: String {
            byStore ? String(localized: "\(items.count) stores checked", comment: "A price check's folded row of every store it looked at")
                : String(localized: "\(items.count) options", comment: "A purchase card's folded row of every product on it")
        }
        /// "Amazon $59.95 · 3 not available": under it, the next two and how many had nothing to sell.
        var everyLine: String? {
            let next = others.filter { items[$0].available }.prefix(2).map { i in
                [byStore ? (items[i].product.retailer ?? items[i].product.name) : items[i].product.name, items[i].price].compactMap(\.self).joined(separator: " ")
            }
            let missing = others.filter { !items[$0].available }.count
            let gone = missing > 0 ? [String(localized: "\(missing) not available", comment: "Under a purchase card's folded row: how many stores or products had no price or none in stock")] : []
            return (next + gone).joined(separator: " · ").nilIfEmpty
        }

        /// Every product is the same one at another store: each names a store, and all name the
        /// same thing or share a model number ("NV360", "WH-1000XM5").
        static func oneProduct(_ card: ReplyCard.Purchase) -> Bool {
            guard card.items.count >= 2, card.items.allSatisfy({ !($0.retailer ?? "").isEmpty }) else { return false }
            let names = card.items.map { $0.name.lowercased() }
            if Set(names).count == 1 { return true }
            func models(_ name: String) -> Set<String> {
                Set(name.split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init)
                    .filter { $0.count >= 3 && $0.contains(where: \.isNumber) && $0.contains(where: \.isLetter) })
            }
            return !names.dropFirst().reduce(models(names[0])) { $0.intersection(models($1)) }.isEmpty
        }

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
                let stock = p.availability.map(PurchaseCard.stock)
                let spoken = [badge, p.name, p.brand, price, spokenWas, stock, spokenRating, spokenReviews, spokenStore].compactMap(\.self).joined(separator: ", ")
                return Item(id: i, product: p, price: price, was: was, saving: saving, rating: p.rating, ratingText: ratingText,
                            facts: facts.isEmpty ? nil : facts.joined(separator: " · "), storeLine: ratingText ?? p.name, badge: badge, tone: Tone(badge ?? "", pick: p.pick),
                            symbol: PurchaseCard.symbol(for: [p.name, p.brand ?? ""].joined(separator: " "), else: title),
                            url: p.url.flatMap(URL.init(string:)), image: p.image.flatMap(URL.init(string:)), view: view, spoken: spoken,
                            spokenStars: [spokenRating, spokenReviews].compactMap(\.self).joined(separator: ", ").nilIfEmpty,
                            hasDetails: !p.pros.isEmpty || !p.cons.isEmpty || !p.specs.isEmpty,
                            stock: stock, inStock: p.availability == .inStock)
            }
            note = card.note ?? card.checked.map { PurchaseCard.checkedNote($0, locale: locale) }
            byStore = Self.oneProduct(card)
            lead = card.lead
            others = Self.order(card).dropFirst().map { $0 }
            let priced = card.items.compactMap { p in p.price.map { ($0, p.currency ?? home) } }
            if priced.count >= 2, Set(priced.map(\.1)).count == 1, let low = priced.map(\.0).min(), let high = priced.map(\.0).max(), low < high {
                range = ReplyCard.Purchase.money(low, currency: priced[0].1, locale: locale) + " – " + ReplyCard.Purchase.money(high, currency: priced[0].1, locale: locale)
            }
            let named = PurchaseCard.symbol(for: title)
            symbol = named != "bag" ? named : (items.first.map { $0.symbol } ?? "bag")
            let pick = card.items[card.lead]
            meter = pick.price.flatMap { PurchaseCard.meter(price: $0, usual: card.usual, was: pick.wasPrice, currency: pick.currency ?? home, locale: locale) }
        }
    }

    /// The deal meter (design F, 2026-11-13): a bar from a little under the price to past what it
    /// usually sells for, the price marked on it, and in words how good a price it is.
    struct Meter: Equatable {
        enum Verdict: Equatable { case great, good, usual, above, sale }
        var verdict: Verdict
        /// Where the price is on the bar, 0 to 1.
        var price: Double
        /// Where the usual price (or the old one) is: the bar past it is its zone.
        var usual: Double
        /// "$45": the bar's start.
        var low: String
        /// "Usual $80", "Was $219.99".
        var reference: String
        /// "About $20 under usual", "$71 off".
        var gap: String?

        var title: String {
            switch verdict {
            case .great: String(localized: "Great deal", comment: "A purchase card's deal meter: the price is well under what it usually sells for")
            case .good: String(localized: "Good deal", comment: "A purchase card's deal meter: the price is under what it usually sells for")
            case .usual: String(localized: "About usual", comment: "A purchase card's deal meter: the price is what it usually sells for")
            case .above: String(localized: "Above usual", comment: "A purchase card's deal meter: the price is over what it usually sells for")
            case .sale: String(localized: "On sale", comment: "A purchase card's deal meter: the store's price is under its own old price")
            }
        }
    }

    /// The meter for a price against what it usually sells for (the agent's 'usual_price'), else
    /// against its store's old price when that is higher; nil with neither.
    static func meter(price: Double, usual: Double?, was: Double?, currency: String, locale: Locale = .current) -> Meter? {
        guard price > 0, let reference = usual ?? was, reference > 0, usual != nil || reference > price else { return nil }
        let start = min(price * 0.85, reference * 0.6)
        let step = pow(10, log10(start).rounded(.down)) / 2
        let low = max(0, (start / step).rounded(.down) * step)
        let high = max(reference, price) * 1.15
        func at(_ x: Double) -> Double { min(1, max(0, (x - low) / (high - low))) }
        let off = abs(reference - price)
        let gap = ReplyCard.Purchase.money(off >= 10 ? off.rounded() : (off * 100).rounded() / 100, currency: currency, locale: locale)
        let money = ReplyCard.Purchase.money(reference, currency: currency, locale: locale)
        let ratio = price / reference
        var meter = Meter(verdict: .sale, price: at(price), usual: at(reference),
                          low: ReplyCard.Purchase.money(low, currency: currency, locale: locale),
                          reference: String(localized: "Was \(money)", comment: "A purchase card's deal meter: the store's old price, e.g. Was $219.99"),
                          gap: String(localized: "\(gap) off", comment: "A purchase card's deal meter: how much under the store's old price, e.g. $71 off"))
        guard usual != nil else { return meter }
        meter.reference = String(localized: "Usual \(money)", comment: "A purchase card's deal meter: what it usually sells for, e.g. Usual $80")
        meter.verdict = ratio < 0.7 ? .great : ratio < 0.95 ? .good : ratio <= 1.02 ? .usual : .above
        meter.gap = switch meter.verdict {
        case .great, .good: String(localized: "About \(gap) under usual", comment: "A purchase card's deal meter: how much under what it usually sells for, e.g. About $20 under usual")
        case .above: String(localized: "About \(gap) over usual", comment: "A purchase card's deal meter: how much over what it usually sells for, e.g. About $5 over usual")
        case .usual, .sale: nil
        }
        return meter
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

    /// "In stock", "Out of stock".
    static func stock(_ availability: ReplyCard.Purchase.Availability) -> String {
        switch availability {
        case .inStock: String(localized: "In stock", comment: "A product on a purchase card: its store has it now, as the store's page said")
        case .outOfStock: String(localized: "Out of stock", comment: "A product on a purchase card: its store doesn't have it now, as the store's page said")
        }
    }

    /// "Prices checked 3:42 PM" (today), "Prices checked Oct 30, 2026 at 3:42 PM": when the store
    /// pages were read, for a card whose note doesn't say.
    static func checkedNote(_ date: Date, now: Date = .now, locale: Locale = .current) -> String {
        var calendar = Calendar.current
        calendar.locale = locale
        let when = calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
            : date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
        return String(localized: "Prices checked \(when)", comment: "A purchase card's note: when its products' store pages were read, e.g. Prices checked 3:42 PM")
    }

    /// A product's picture: its own; else, with Link previews on and its store page read
    /// (`LinkPreviews`, the same read as its listing's), that page's own picture, never the
    /// site's icon (a logo is no photo of the product); else none, and the card draws what it is.
    enum Picture: Equatable {
        case own(URL), listing(Data), drawn
    }

    static func picture(image: URL?, page: URL?, preview: LinkPreview?, linkPreviews: Bool) -> Picture {
        if let image { return .own(image) }
        guard linkPreviews, let page, let preview, preview.url == page, let photo = preview.pagePicture else { return .drawn }
        return .listing(photo)
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

/// A product's page at its store, as the card shows it (asked 2026-10-31: "show the actual site
/// listing … clickable to go to the site listing"): the page's own title and picture once read,
/// only with Settings → Appearance → Link previews on (`LinkPreviews`; the store sees the visit),
/// else what the card calls it ("View at Best Buy"). Always the link's real address under it, so a
/// link that isn't at the store the agent named shows as what it is. Tapped, the page opens in the
/// browser; held, it is opened, copied or shared.
struct ListingLink: View {
    let url: URL
    /// "View at Best Buy": the button's name, and its title until the page has been read.
    let named: String
    /// The pick's, filled with the accent; an opened row's, quieter.
    let prominent: Bool
    @State private var previews = LinkPreviews.shared
    @State private var settings = Settings.shared
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .subheadline) private var side: CGFloat = 44

    var body: some View {
        let preview = settings.linkPreviews ? previews.preview(for: url) : nil
        let address = Self.address(url)
        Button { openURL(url) } label: {
            HStack(spacing: 12) {
                // The pick's, a filled button (design F): the card's picture is already at its top.
                if !prominent {
                    picture(preview)
                        .frame(width: side, height: side)
                        .clipShape(.rect(cornerRadius: 8))
                }
                VStack(alignment: prominent ? .center : .leading, spacing: 2) {
                    Text(prominent ? named : preview?.title ?? named)
                        .chatFont(prominent ? .body : .subheadline, weight: .semibold)
                        .foregroundStyle(prominent ? theme.userText : theme.textColor)
                        .lineLimit(2)
                        .multilineTextAlignment(prominent ? .center : .leading)
                    Text(verbatim: address)
                        .chatFont(.caption)
                        .foregroundStyle(prominent ? theme.userText.opacity(0.75) : theme.accent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: prominent ? .infinity : nil)
                if !prominent { Spacer(minLength: 4) }
                Image(systemName: "arrow.up.right")
                    .chatFont(.subheadline, weight: .bold)
                    .foregroundStyle(prominent ? theme.userText : theme.accent)
                    .frame(width: 30, height: 30)
                    .background(prominent ? AnyShapeStyle(.clear) : AnyShapeStyle(theme.accent.opacity(0.14)), in: .circle)
                    .accessibilityHidden(true)
            }
            .padding(prominent ? 12 : 10)
            .frame(maxWidth: .infinity, minHeight: prominent ? 52 : 44, alignment: .leading)
            .background(prominent ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.accent.opacity(0.06)), in: .rect(cornerRadius: prominent ? 14 : 12))
            .overlay(RoundedRectangle(cornerRadius: prominent ? 14 : 12).strokeBorder(theme.accent.opacity(prominent ? 0 : 0.2), lineWidth: 0.75))
            .contentShape(.rect(cornerRadius: prominent ? 14 : 12))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(named, systemImage: "safari") { openURL(url) }
            Button("Copy Link", systemImage: "doc.on.doc") { UIPasteboard.general.url = url }
            ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
        }
        .task(id: settings.linkPreviews) { if settings.linkPreviews { await previews.request(url) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(named)
        .accessibilityValue([preview?.title, address].compactMap(\.self).joined(separator: ", "))
        .accessibilityHint(Text("Opens the store's page in your browser", comment: "VoiceOver hint: a purchase card's View at <store>"))
    }

    @ViewBuilder private func picture(_ preview: LinkPreview?) -> some View {
        if let data = preview?.image, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Image(systemName: "bag")
                .chatFont(.body, weight: .semibold)
                .foregroundStyle(theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.accent.opacity(0.12))
        }
    }

    /// The link as it reads: its site and path, no "www.", query or fragment ("bestbuy.com/site/
    /// aurora-q5/6501234.p").
    static func address(_ url: URL) -> String {
        let site = LinkPreviews.site(url.host(percentEncoded: false) ?? "")
        let path = url.path(percentEncoded: false)
        guard !site.isEmpty else { return url.absoluteString }
        return path.isEmpty || path == "/" ? site : site + (path.hasSuffix("/") ? String(path.dropLast()) : path)
    }
}

/// A product's picture (`PurchaseCard.picture`): its own; else its store page's, read for its
/// listing with Link previews on. Nothing is read with them off.
private struct ProductPicture: View {
    let image: URL?
    let page: URL?
    let symbol: String
    /// Nil: as wide as there is room (the card's picture at its top).
    var width: CGFloat?
    var height: CGFloat
    @State private var previews = LinkPreviews.shared
    @State private var settings = Settings.shared

    init(image: URL?, page: URL?, symbol: String, side: CGFloat) {
        self.init(image: image, page: page, symbol: symbol, width: side, height: side)
    }

    init(image: URL?, page: URL?, symbol: String, width: CGFloat?, height: CGFloat) {
        self.image = image
        self.page = page
        self.symbol = symbol
        self.width = width
        self.height = height
    }

    var body: some View {
        let preview = page.flatMap { previews.preview(for: $0) }
        let still: UIImage? = if case let .listing(data) = PurchaseCard.picture(image: image, page: page, preview: preview, linkPreviews: settings.linkPreviews) {
            UIImage(data: data)
        } else {
            nil
        }
        Group {
            if let width {
                CardPicture(url: image, symbol: symbol, side: width, still: still)
            } else {
                CardPicture(url: image, symbol: symbol, width: nil, height: height, corner: 14, pixels: 900, still: still)
            }
        }
        .task(id: settings.linkPreviews) {
            if settings.linkPreviews, image == nil, let page { await previews.request(page) }
        }
    }
}

/// The deal meter (`PurchaseCard.Meter`): how good a price it is in words, then the bar, the
/// price's mark on it, and the usual price's zone at its end.
private struct DealMeter: View {
    let meter: PurchaseCard.Meter
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .caption2) private var labels: CGFloat = 16

    private var tone: Color {
        switch meter.verdict {
        case .great, .good, .sale: theme.accent
        case .usual: .secondary
        case .above: PurchaseCard.bad
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(meter.title).chatFont(.subheadline, weight: .semibold)
                Spacer(minLength: 0)
                if let gap = meter.gap {
                    Text(gap).chatFont(.footnote, weight: .semibold).foregroundStyle(tone).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.fill.tertiary)
                    Rectangle().fill(Color.purple.opacity(0.3))
                        .frame(width: width * (1 - meter.usual))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Rectangle().fill(tone.opacity(0.35)).frame(width: width * meter.price)
                }
                .frame(height: 10)
                .clipShape(.capsule)
                .overlay(alignment: .leading) {
                    Circle().fill(tone)
                        .overlay { Circle().strokeBorder(.white, lineWidth: 2.5) }
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                        .frame(width: 18, height: 18)
                        .offset(x: min(max(0, width * meter.price - 9), width - 18))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 18)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Text(verbatim: meter.low).frame(width: max(0, geo.size.width * meter.usual - 4), alignment: .leading)
                    Text(meter.reference).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                .chatFont(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .frame(height: labels)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([meter.title, meter.gap, meter.reference].compactMap(\.self).joined(separator: ", "))
    }
}

/// A store, as its row on a price check shows it: its first letter in a circle, the pick's in the accent.
private struct StoreMark: View {
    let name: String
    let isPick: Bool
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .subheadline) private var side: CGFloat = 36

    var body: some View {
        Text(verbatim: name.first.map { String($0).uppercased() } ?? "?")
            .chatFont(.subheadline, weight: .bold)
            .foregroundStyle(isPick ? theme.userText : .primary)
            .frame(width: side, height: side)
            .background(isPick ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.fill.tertiary), in: .circle)
            .accessibilityHidden(true)
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
                    Image(systemName: Self.symbol(item.rating ?? 0, i)).accessibilityHidden(true)
                }
            }
            .chatFont(.caption2)
            .foregroundStyle(PurchaseCard.star)
            if let text = item.ratingText {
                Text(verbatim: text).chatFont(.footnote).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        // One line to VoiceOver (UAT 2.3.1: each star read as "Favorite", a half one as "Star With
        // The Leading Half Filled").
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.spokenStars ?? "")
    }

    /// The `index`th star of a rating: full, half or empty.
    static func symbol(_ rating: Double, _ index: Int) -> String {
        let left = rating - Double(index)
        return left >= 0.75 ? "star.fill" : left >= 0.25 ? "star.leadinghalf.filled" : "star"
    }
}
