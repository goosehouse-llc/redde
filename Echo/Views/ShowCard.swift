import SwiftUI

/// A film or a series, or a few (`ReplyCard.show`, asked 2026-10-31): the agent's pick (else the
/// first) larger, with its poster (only with Link previews on: `CardPicture`), its year, what it
/// is and how long, its genres, its ratings as the agent found them, a few lines on it, where to
/// watch it (the services' names, no logos), and its trailer and page; the others as rows that
/// open in place, as the purchase card's do. Chips ask the agent for more (Similar picks, Where can
/// I watch it?). What it shows is worked out as the card is made (`Shown`).
struct ShowCard: View {
    let card: ReplyCard.Shows
    let whole: ReplyCard
    private let shown: [Shown]
    @State private var open: Set<Int> = []
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    init(card: ReplyCard.Shows, whole: ReplyCard) {
        self.card = card
        self.whole = whole
        shown = card.items.map { Shown($0) }
    }

    private var others: [Int] { card.items.indices.filter { $0 != card.lead } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardBox(spacing: 14) {
                if let title = card.title {
                    CardTitle(symbol: Self.symbol(card.items[card.lead]), title: title)
                }
                hero(card.lead)
                if !others.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(others.enumerated()), id: \.element) { n, index in
                            if n > 0 { Divider() }
                            row(index)
                        }
                    }
                    .padding(.top, -6)
                }
                if let note = card.note { Text(note).chatFont(.caption).foregroundStyle(.secondary) }
            }
            CardChips(chips: FollowUp.allCases, whole: whole, title: \.title, symbol: \.symbol, hint: \.hint,
                      asked: FollowUp.asked(in:), send: { Self.ask($0, card) })
        }
        .animation(.snappy(duration: 0.25), value: open)
    }

    // MARK: The lead

    private func hero(_ index: Int) -> some View {
        let item = card.items[index], s = shown[index]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                CardPicture(url: s.poster, symbol: Self.symbol(item), width: 92, height: 138, fill: true, corner: 10, pixels: 420)
                VStack(alignment: .leading, spacing: 5) {
                    if item.pick && card.items.count > 1 {
                        Text(String(localized: "card.pick", defaultValue: "Pick", comment: "A tag on the agent's pick: the place, product or option it recommends"))
                            .textCase(.uppercase).tracking(0.4).chatFont(.caption2, weight: .bold).foregroundStyle(theme.accent)
                    }
                    Text(item.name).chatFont(.title3, weight: .bold).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    if let facts = s.facts { Text(verbatim: facts).chatFont(.footnote).foregroundStyle(.secondary).monospacedDigit() }
                    if !item.genres.isEmpty {
                        Text(verbatim: item.genres.joined(separator: " · ")).chatFont(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if !item.ratings.isEmpty { Ratings(ratings: item.ratings).padding(.top, 2) }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: s.spoken))
            details(index, inRow: false)
        }
    }

    /// Its overview, who made it, where to watch it, and its links.
    private func details(_ index: Int, inRow: Bool) -> some View {
        let item = card.items[index], s = shown[index]
        return VStack(alignment: .leading, spacing: 12) {
            if inRow, let more = ([s.facts] + [item.genres.isEmpty ? nil : item.genres.joined(separator: " · ")]).compactMap(\.self).joined(separator: " · ").nilIfEmpty {
                Text(verbatim: more).chatFont(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let overview = item.overview { Text(overview).chatFont(.subheadline).fixedSize(horizontal: false, vertical: true) }
            if let people = s.people { Text(verbatim: people).chatFont(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if !item.watch.isEmpty { watch(item.watch) }
            if s.trailer != nil || s.url != nil {
                HStack(spacing: 10) {
                    if let trailer = s.trailer {
                        Button { openURL(trailer) } label: { LinkCapsule(title: String(localized: "Trailer", comment: "A show card's button: opens its trailer in the browser"), filled: !inRow) }
                            .accessibilityHint(Text("Opens the trailer in your browser", comment: "VoiceOver hint: a show card's Trailer"))
                    }
                    if let url = s.url {
                        Button { openURL(url) } label: { LinkCapsule(title: String(localized: "More Info", comment: "A show card's button: opens its page in the browser"), filled: false) }
                            .accessibilityHint(Text("Opens its page in your browser", comment: "VoiceOver hint: a show card's More Info"))
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func watch(_ services: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where to watch", comment: "A show card: over the services it is on").chatFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            PillFlow(spacing: 6) {
                ForEach(services, id: \.self) { service in
                    Label(service, systemImage: "play.tv")
                        .chatFont(.footnote, weight: .medium)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(scheme.cardPanel, in: .capsule)
                        .overlay { Capsule().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Where to watch: \(services.formatted(.list(type: .and)))", comment: "VoiceOver: the services a show is on, e.g. Where to watch: Netflix and Max"))
    }

    // MARK: The others

    private func row(_ index: Int) -> some View {
        let item = card.items[index], s = shown[index]
        let isOpen = open.contains(index)
        return VStack(alignment: .leading, spacing: 0) {
            Button { if open.contains(index) { open.remove(index) } else { open.insert(index) } } label: {
                HStack(spacing: 12) {
                    CardPicture(url: s.poster, symbol: Self.symbol(item), width: 40, height: 60, fill: true, corner: 6, pixels: 180)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).chatFont(.subheadline, weight: .semibold).lineLimit(2)
                        if let line = s.line { Text(verbatim: line).chatFont(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.down")
                        .chatFont(.caption, weight: .semibold).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: s.spoken))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isOpen ? Text("Hides its details", comment: "VoiceOver hint: a product on a purchase card, open")
                                      : Text("Shows more about it", comment: "VoiceOver hint: a title on a show card, closed"))
            if isOpen {
                details(index, inRow: true).padding(.leading, 52).padding(.bottom, 12).transition(.opacity)
            }
        }
    }

    // MARK: Asking for more

    enum FollowUp: CaseIterable, Hashable {
        case similar, watch

        var title: String {
            switch self {
            case .similar: String(localized: "Similar picks", comment: "A chip under a show card: asks the agent for more like it")
            case .watch: String(localized: "Where can I watch it?", comment: "A chip under a show card: asks the agent where it streams")
            }
        }

        var symbol: String {
            switch self {
            case .similar: "sparkles.tv"
            case .watch: "play.tv"
            }
        }

        var hint: Text {
            switch self {
            case .similar: Text("Asks your agent for more like it", comment: "VoiceOver hint: a show card's Similar picks")
            case .watch: Text("Asks your agent where it's streaming", comment: "VoiceOver hint: a show card's Where can I watch it?")
            }
        }

        var marker: String {
            switch self {
            case .similar: "tapped \"Similar picks\""
            case .watch: "tapped \"Where can I watch it?\""
            }
        }

        static func asked(in said: String) -> FollowUp? { allCases.first { said.contains($0.marker) } }
    }

    /// The person's message and the note to the agent for a chip, about the lead.
    static func ask(_ chip: FollowUp, _ card: ReplyCard.Shows) -> (shown: String, said: String) {
        let lead = card.items[card.lead]
        let named = "\"\(lead.name)\"" + (lead.year.map { " (\($0))" } ?? "")
        let start = "the user \(chip.marker) under the show card: "
        switch chip {
        case .similar:
            let seen = card.items.map(\.name).joined(separator: ", ")
            return (String(localized: "More like \(lead.name)", comment: "The message a show card's Similar picks sends, with the title's name"),
                    start + "suggest a few titles like \(named), not these (\(seen)); look them up with your tools and show them as a new 'show' "
                        + "card, your pick first; never make up a rating, a year or a link. Then answer in a line")
        case .watch:
            return (String(localized: "Where can I watch \(lead.name)?", comment: "The message a show card's Where can I watch it? sends, with the title's name"),
                    start + "look up where \(named) is streaming, to rent or to buy now, in the person's country, with your tools, and show it "
                        + "as a 'show' card with 'watch'; never guess a service. Then answer in a line")
        }
    }

    static func symbol(_ item: ReplyCard.Shows.Title) -> String { item.format == .series ? "tv" : "film" }
}

extension ShowCard {
    /// A title as drawn, worked out once.
    struct Shown {
        /// "2022– · Series · 2 seasons", "2014 · Film · 2h 49m".
        var facts: String?
        /// A row's line: "2014 · Film · IMDb 8.7".
        var line: String?
        /// "Created by Dan Erickson · With Adam Scott, Britt Lower".
        var people: String?
        var poster: URL?
        var url: URL?
        var trailer: URL?
        var spoken: String

        init(_ item: ReplyCard.Shows.Title) {
            let years = item.year.map { year in item.endYear.map { "\(year)–\($0)" } ?? (item.format == .series ? "\(year)–" : "\(year)") }
            let kind: String? = switch item.format {
            case .movie: String(localized: "Film", comment: "A show card: what it is, a film")
            case .series: String(localized: "Series", comment: "A show card: what it is, a TV series")
            case nil: nil
            }
            let length = item.seasons.map { $0 == 1 ? String(localized: "1 season", comment: "A show card: a series of one season")
                                                    : String(localized: "\($0) seasons", comment: "A show card: how many seasons a series has, e.g. 2 seasons") }
                ?? item.runtime.map { Duration.seconds($0.rounded()).formatted(.units(allowed: [.hours, .minutes], width: .narrow)) }
            facts = [years, kind, length].compactMap(\.self).joined(separator: " · ").nilIfEmpty
            let rating = item.ratings.first.map { [$0.source, $0.value].compactMap(\.self).joined(separator: " ") }
            line = [years, kind, rating].compactMap(\.self).joined(separator: " · ").nilIfEmpty
            let by = item.by.map { item.format == .series ? String(localized: "Created by \($0)", comment: "A show card: who made a series")
                                                          : String(localized: "Directed by \($0)", comment: "A show card: who directed a film") }
            let cast = item.cast.isEmpty ? nil : String(localized: "With \(item.cast.formatted(.list(type: .and)))", comment: "A show card: who is in it, e.g. With Adam Scott and Britt Lower")
            people = [by, cast].compactMap(\.self).joined(separator: " · ").nilIfEmpty
            poster = item.poster.flatMap(URL.init(string:))
            url = item.url.flatMap(URL.init(string:))
            trailer = item.trailer.flatMap(URL.init(string:))
            let ratings = item.ratings.map { [$0.source, $0.value].compactMap(\.self).joined(separator: " ") }
            spoken = ([item.name, facts] + ratings + [item.genres.isEmpty ? nil : item.genres.joined(separator: ", ")]).compactMap(\.self).joined(separator: ", ")
        }
    }
}

/// A title's ratings, each as its source and its value ("IMDb 8.7", "Rotten Tomatoes 97%").
private struct Ratings: View {
    let ratings: [ReplyCard.Shows.Rating]

    var body: some View {
        PillFlow(spacing: 6) {
            ForEach(Array(ratings.enumerated()), id: \.offset) { _, rating in
                HStack(spacing: 4) {
                    Image(systemName: "star.fill").foregroundStyle(PurchaseCard.star).imageScale(.small)
                    if let source = rating.source { Text(source).foregroundStyle(.secondary) }
                    Text(verbatim: rating.value).fontWeight(.semibold).monospacedDigit()
                }
                .chatFont(.caption)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: .capsule)
            }
        }
    }
}
