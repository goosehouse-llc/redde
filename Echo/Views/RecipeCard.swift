import SwiftUI

/// A recipe (`ReplyCard.recipe`, asked 2026-10-31: "a recipe card"): its picture (only with Link
/// previews on: `CardPicture`), its times, its servings with − and + that work the amounts out
/// again on the phone, the ingredients to tick off as they go in, and the steps, numbered. Its page
/// opens in the browser. Chips under it ask the agent (Make it vegetarian, Shopping list), as the
/// purchase card's do; the card itself looks nothing up.
///
/// What it shows is worked out as the card is made (`Shown`), and the amounts again only when the
/// servings change.
struct RecipeCard: View {
    let card: ReplyCard.Recipe
    let whole: ReplyCard
    private let shown: Shown
    @State private var servings: Int
    @State private var lines: [Line]
    @State private var tab: Tab = .ingredients
    @State private var answers = CardAnswers.shared
    @State private var settings = Settings.shared
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    enum Tab: Hashable { case ingredients, steps }

    /// An ingredient as drawn: its amount for the servings chosen, and the rest.
    struct Line: Equatable {
        var amount: String?
        var rest: String
        var spoken: String { [amount, rest].compactMap(\.self).joined(separator: " ") }
        /// The amount in bold, then the rest.
        var shown: AttributedString {
            var out = AttributedString(amount.map { $0 + " " } ?? "")
            out.inlinePresentationIntent = .stronglyEmphasized
            return out + AttributedString(rest)
        }
    }

    init(card: ReplyCard.Recipe, whole: ReplyCard) {
        self.card = card
        self.whole = whole
        shown = Shown(card)
        _servings = State(initialValue: card.servings ?? 1)
        _lines = State(initialValue: Self.lines(card, servings: card.servings ?? 1))
    }

    /// The ingredients for `servings`, worked out from the recipe's own.
    static func lines(_ card: ReplyCard.Recipe, servings: Int, locale: Locale = .current) -> [Line] {
        let factor = card.servings.map { Double(servings) / Double($0) } ?? 1
        return card.ingredients.map { i in
            let scaled = ReplyCard.Recipe.scaled(i, by: factor, locale: locale)
            return Line(amount: scaled.amount, rest: scaled.rest)
        }
    }

    private var done: Set<Int> { Set(answers.ticks[whole.key] ?? []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardBox(spacing: 14) {
                if ProductImages.allowed(shown.image, settings: settings) != nil {
                    CardPicture(url: shown.image, symbol: "fork.knife", width: nil, height: 170, fill: true, corner: 14, pixels: 1_000)
                }
                CardTitle(symbol: "fork.knife", title: card.title, subtitle: card.source)
                if let summary = card.summary {
                    Text(summary).chatFont(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !shown.times.isEmpty { facts }
                if !card.ingredients.isEmpty && !card.steps.isEmpty { tabs }
                if tab == .ingredients && !card.ingredients.isEmpty || card.steps.isEmpty {
                    if card.servings != nil, lines.contains(where: { $0.amount != nil }) {
                        HStack {
                            Text("Amounts for", comment: "On a recipe card, before its servings control: the amounts are for this many servings")
                                .chatFont(.subheadline).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            servingsControl
                        }
                    }
                    ingredients
                } else {
                    steps
                }
                if let note = card.note {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "info.circle").accessibilityHidden(true)
                        Text(note)
                    }
                    .chatFont(.caption).foregroundStyle(.secondary)
                }
                if let url = shown.url {
                    Button { openURL(url) } label: { LinkCapsule(title: shown.view, filled: false) }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Opens the recipe's page in your browser", comment: "VoiceOver hint: a recipe card's View Recipe button"))
                }
            }
            CardChips(chips: FollowUp.allCases, whole: whole, title: \.title, symbol: \.symbol, hint: \.hint,
                      asked: FollowUp.asked(in:), send: { Self.ask($0, card, servings: servings, lines: lines) })
        }
        .animation(.snappy(duration: 0.25), value: tab)
        .onChange(of: servings) { _, now in lines = Self.lines(card, servings: now) }
    }

    // MARK: Times and servings

    private var facts: some View {
        HStack(alignment: .center, spacing: 8) {
            ForEach(Array(shown.times.enumerated()), id: \.offset) { _, time in
                CardFact(name: time.name, value: time.value)
            }
        }
    }

    /// − 4 +: the servings, and the amounts with them.
    private var servingsControl: some View {
        HStack(spacing: 0) {
            Button { if servings > 1 { servings -= 1 } } label: {
                Image(systemName: "minus").chatFont(.footnote, weight: .bold).frame(width: 36, height: 44).contentShape(.rect)
            }
            .disabled(servings <= 1)
            VStack(spacing: 0) {
                Text(servings, format: .number).chatFont(.subheadline, weight: .bold).monospacedDigit()
                    .contentTransition(.numericText(value: Double(servings)))
                Text("servings", comment: "Under the number of servings on a recipe card").chatFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 52)
            Button { if servings < 99 { servings += 1 } } label: {
                Image(systemName: "plus").chatFont(.footnote, weight: .bold).frame(width: 36, height: 44).contentShape(.rect)
            }
            .disabled(servings >= 99)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.accent)
        .background(theme.accent.opacity(0.1), in: .capsule)
        .fixedSize()
        .animation(.snappy(duration: 0.2), value: servings)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Servings", comment: "VoiceOver: a recipe card's servings control"))
        .accessibilityValue(Text(servings, format: .number))
        .accessibilityHint(Text("Swipe up or down to change it; the amounts change with it", comment: "VoiceOver hint: a recipe card's servings"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if servings < 99 { servings += 1 }
            case .decrement: if servings > 1 { servings -= 1 }
            @unknown default: break
            }
        }
    }

    // MARK: Ingredients and steps

    private var tabs: some View {
        HStack(spacing: 4) {
            tabButton(.ingredients, String(localized: "Ingredients (\(card.ingredients.count))", comment: "A recipe card's tab: its ingredients, with how many"))
            tabButton(.steps, String(localized: "Steps (\(card.steps.count))", comment: "A recipe card's tab: its steps, with how many"))
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: .capsule)
    }

    private func tabButton(_ which: Tab, _ title: String) -> some View {
        Button { tab = which } label: {
            Text(title)
                .chatFont(.subheadline, weight: .semibold)
                .foregroundStyle(tab == which ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background { if tab == which { Capsule().fill(scheme.cardPanel).shadow(color: .black.opacity(0.08), radius: 2, y: 1) } }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityAddTraits(tab == which ? [.isSelected, .isButton] : .isButton)
    }

    private var ingredients: some View {
        let done = self.done
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.sections.enumerated()), id: \.offset) { _, section in
                if let title = section.title {
                    Text(title).tracking(0.6).textCase(.uppercase).chatFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                        .padding(.leading, 2).padding(.top, 10).padding(.bottom, 6)
                        .accessibilityAddTraits(.isHeader)
                }
                VStack(spacing: 0) {
                    ForEach(Array(section.items.enumerated()), id: \.element) { n, index in
                        if n > 0 { Divider().padding(.leading, 46) }
                        ingredient(index, on: done.contains(index))
                    }
                }
                .background(scheme.cardPanel, in: .rect(cornerRadius: 14))
            }
        }
    }

    private func ingredient(_ index: Int, on: Bool) -> some View {
        let line = lines.indices.contains(index) ? lines[index] : Line(rest: card.ingredients[index].name)
        return Button { toggle(index) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ZStack {
                    if on {
                        Circle().fill(theme.accent)
                        Image(systemName: "checkmark").chatFont(size: 11, weight: .heavy).foregroundStyle(theme.userText)
                    } else {
                        Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.5)
                    }
                }
                .frame(width: 22, height: 22)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                Text(line.shown)
            }
            .chatFont(.subheadline)
            .strikethrough(on, color: .secondary)
            .foregroundStyle(on ? Color.secondary : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: line.spoken))
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(on ? Text("Done") : Text("Not done"))
        .accessibilityHint(on ? Text("Marks it not done", comment: "VoiceOver hint: a ticked item of a checklist card")
                              : Text("Marks it done", comment: "VoiceOver hint: an item of a checklist card not ticked yet"))
    }

    private func toggle(_ index: Int) {
        var done = self.done
        if done.contains(index) { done.remove(index) } else { done.insert(index) }
        answers.setTicks(whole.key, done.sorted())
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(card.steps.enumerated()), id: \.offset) { n, step in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(n + 1, format: .number)
                        .chatFont(.caption, weight: .bold).monospacedDigit()
                        .foregroundStyle(theme.accent)
                        .frame(width: 26, height: 26)
                        .background(theme.accent.opacity(0.14), in: .circle)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                    Text(step).chatFont(.subheadline).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Step \(n + 1): \(step)", comment: "VoiceOver: a step of a recipe card, with its number and its words"))
            }
        }
    }

    // MARK: Asking for more

    enum FollowUp: CaseIterable, Hashable {
        case vegetarian, shopping

        var title: String {
            switch self {
            case .vegetarian: String(localized: "Make it vegetarian", comment: "A chip under a recipe card: asks the agent for a vegetarian version")
            case .shopping: String(localized: "Shopping list", comment: "A chip under a recipe card: asks the agent for a shopping list of its ingredients")
            }
        }

        var symbol: String {
            switch self {
            case .vegetarian: "leaf"
            case .shopping: "cart"
            }
        }

        var hint: Text {
            switch self {
            case .vegetarian: Text("Asks your agent for a vegetarian version", comment: "VoiceOver hint: a recipe card's Make it vegetarian")
            case .shopping: Text("Asks your agent for a list of what to buy", comment: "VoiceOver hint: a recipe card's Shopping list")
            }
        }

        var marker: String {
            switch self {
            case .vegetarian: "tapped \"Make it vegetarian\""
            case .shopping: "tapped \"Shopping list\""
            }
        }

        static func asked(in said: String) -> FollowUp? { allCases.first { said.contains($0.marker) } }
    }

    /// The person's message and the note to the agent for a chip, with the servings chosen.
    static func ask(_ chip: FollowUp, _ card: ReplyCard.Recipe, servings: Int, lines: [Line]) -> (shown: String, said: String) {
        let start = "the user \(chip.marker) under the recipe card \"\(card.title)\""
            + (card.url.map { " (\($0))" } ?? "") + (card.servings != nil ? ", set to \(servings) servings: " : ": ")
        switch chip {
        case .vegetarian:
            return (String(localized: "Make the \(card.title) vegetarian", comment: "The message a recipe card's Make it vegetarian sends, with the recipe's name"),
                    start + "give a vegetarian version, swapping out the meat and fish (and fish sauce, gelatin, meat stock) for what works best "
                        + "in this dish, as a new 'recipe' card with the same servings; say in a line what you swapped. If a real vegetarian "
                        + "recipe for it exists, look it up with your tools and use it; never make up a source or a link")
        case .shopping:
            let list = lines.map(\.spoken).joined(separator: "; ")
            return (String(localized: "Make a shopping list for the \(card.title)", comment: "The message a recipe card's Shopping list sends, with the recipe's name"),
                    start + "show what to buy as a 'checklist' card (its 'items' grouped by the store's 'section', e.g. Produce, Dairy, "
                        + "Pantry, each with its amount as a 'note'; leave out salt, pepper, oil and water unless they matter). The "
                        + "ingredients for these servings: \(list). Then answer in a line")
        }
    }
}

// MARK: - What it shows

extension RecipeCard {
    struct Shown {
        /// Prep, Cook and Total, where given: each its name and how long.
        var times: [(name: String, value: String)]
        var sections: [(title: String?, items: [Int])]
        var url: URL?
        var image: URL?
        /// "View Recipe at Serious Eats".
        var view: String

        init(_ card: ReplyCard.Recipe) {
            var times: [(String, String)] = []
            if let prep = card.prep { times.append((String(localized: "Prep", comment: "A recipe card's preparation time"), Self.time(prep))) }
            if let cook = card.cook { times.append((String(localized: "Cook", comment: "A recipe card's cooking time"), Self.time(cook))) }
            if let all = card.allTime, card.total != nil || times.count == 2 {
                times.append((String(localized: "Total", comment: "A recipe card's total time"), Self.time(all)))
            }
            self.times = Array(times.prefix(3)).map { (name: $0.0, value: $0.1) }
            var sections: [(title: String?, items: [Int])] = []
            for (index, item) in card.ingredients.enumerated() {
                if let found = sections.firstIndex(where: { $0.title == item.section }) { sections[found].items.append(index) }
                else { sections.append((item.section, [index])) }
            }
            self.sections = sections
            url = card.url.flatMap(URL.init(string:))
            image = card.image.flatMap(URL.init(string:))
            view = card.source.map { String(localized: "View Recipe at \($0)", comment: "A recipe card's button: opens its page, e.g. View Recipe at Serious Eats") }
                ?? String(localized: "View Recipe", comment: "A recipe card's button: opens its page, its site not named")
        }

        /// "25 min", "1 hr 30 min".
        static func time(_ seconds: TimeInterval) -> String {
            Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        }
    }
}
