import SwiftUI

/// The Shelf layout of a watch list (2026-11-25, "add shelf as well", the movie list mockups' B):
/// one large poster at a time, swiped through, the next ones peeking either side; its name, year
/// and night under it, then a few lines of what it's about (2026-11-26, plugin 1.52), Plan a Night
/// and Watched for the one in the middle, and dots for where you are. Picked per list in Change
/// Look (`Settings.FilmLayout.shelf`).
struct FilmShelf<Actions: ViewModifier>: View {
    let items: [TodayList.Item]
    let mark: Color
    let plan: (TodayList.Item) -> Void
    let watched: (TodayList.Item) -> Void
    /// The long press and the VoiceOver actions every item has (`ListItemActions`).
    let actions: (TodayList.Item) -> Actions
    @State private var current: String?
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    @Environment(\.self) private var environment

    private var size: CGFloat { min(max(scale, 1), 1.3) }
    private var shown: TodayList.Item? { items.first { $0.id == current } ?? items.first }

    var body: some View {
        let width = 230 * size, height = 345 * size
        VStack(spacing: 0) {
            GeometryReader { space in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 18) {
                        ForEach(items) { item in
                            CardPicture(url: item.poster.flatMap(URL.init(string:)), symbol: "film", width: width, height: height,
                                        fill: true, corner: 18, pixels: 700)
                                .shadow(color: .black.opacity(0.35), radius: 14, y: 10)
                                .scrollTransition(.interactive, axis: .horizontal) { poster, phase in
                                    poster.scaleEffect(phase.isIdentity ? 1 : 0.74).opacity(phase.isIdentity ? 1 : 0.6)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text(verbatim: [item.name, item.year.map(String.init), item.plan].compactMap { $0 }.joined(separator: ", ")))
                                .accessibilityAction { watch(item) }
                                .modifier(actions(item))
                                .id(item.id)
                        }
                    }
                    .scrollTargetLayout()
                    .frame(height: height + 24)
                }
                .contentMargins(.horizontal, max(0, (space.size.width - width) / 2), for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $current, anchor: .center)
            }
            .frame(height: height + 24)

            if let item = shown {
                VStack(spacing: 3) {
                    Text(item.name)
                        .chatFont(.title2, weight: .heavy)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    let details = [item.year.map(String.init), item.plan].compactMap { $0 }.joined(separator: " · ")
                    if !details.isEmpty {
                        Text(verbatim: details)
                            .chatFont(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    // What it's about: room for three lines whenever any film has a plot, so the
                    // buttons stay put as the shelf is swiped.
                    if items.contains(where: { $0.plot != nil }) {
                        Text(verbatim: item.plot ?? "")
                            .chatFont(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3, reservesSpace: true)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .accessibilityElement(children: .combine)
                .contentTransition(.opacity)
                .animation(.snappy(duration: 0.2), value: item.id)

                dots(at: items.firstIndex { $0.id == item.id } ?? 0)
                    .padding(.top, 12)

                let card = FilledCard(mark, in: environment)
                HStack(spacing: 10) {
                    Button { plan(item) } label: {
                        Group {
                            if item.when == nil {
                                Text("Plan a Night", comment: "Shelf: picks the night to watch the film in the middle")
                            } else {
                                Text("Change Night", comment: "Shelf: moves the night planned for the film in the middle")
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.primary.opacity(0.1), in: .rect(cornerRadius: 14))
                        .contentShape(.rect(cornerRadius: 14))
                    }
                    .accessibilityIdentifier("shelf-plan")
                    Button { watch(item) } label: {
                        Text("Watched", comment: "A watch list: the stamp on a film or series already seen")
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(card.ink)
                            .background(card.fill, in: .rect(cornerRadius: 14))
                            .contentShape(.rect(cornerRadius: 14))
                    }
                    .accessibilityIdentifier("shelf-watched")
                }
                .buttonStyle(.plain)
                .chatFont(.body, weight: .bold)
                .padding(.horizontal, 4)
                .padding(.top, 14)
            }
        }
    }

    /// Where the one in the middle is: a dot each, its own long. Past a dozen, "3 of 20".
    @ViewBuilder
    private func dots(at index: Int) -> some View {
        Group {
            if items.count > 12 {
                Text("\(index + 1) of \(items.count)", comment: "How many of a bot's skills or tools it has, e.g. “3 of 12”")
                    .chatFont(.footnote, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if items.count > 1 {
                HStack(spacing: 7) {
                    ForEach(items.indices, id: \.self) { n in
                        Capsule()
                            .fill(n == index ? CardInk.readable(mark, drawnIn: environment.colorScheme) : Color.secondary.opacity(0.45))
                            .frame(width: n == index ? 18 : 7, height: 7)
                    }
                }
                .animation(.snappy(duration: 0.2), value: index)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(index + 1) of \(items.count)", comment: "How many of a bot's skills or tools it has, e.g. “3 of 12”"))
            }
        }
    }

    /// Watched: it leaves the shelf, and the next one comes to the middle.
    private func watch(_ item: TodayList.Item) {
        if let at = items.firstIndex(where: { $0.id == item.id }) {
            let next = items.indices.contains(at + 1) ? items[at + 1] : at > 0 ? items[at - 1] : nil
            current = next?.id
        }
        watched(item)
    }
}

/// The films watched, under a shelf: small faded posters in a row.
struct WatchedRow: View {
    let items: [TodayList.Item]
    @ScaledMetric(relativeTo: .caption) private var scale: CGFloat = 1

    var body: some View {
        let width = 62 * min(max(scale, 1), 1.4)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(items) { item in
                    CardPicture(url: item.poster.flatMap(URL.init(string:)), symbol: "film", width: width, height: width * 1.5,
                                fill: true, corner: 8, pixels: 200)
                        .saturation(0.2)
                        .brightness(-0.12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: items.map(\.name).joined(separator: ", ")))
    }
}
