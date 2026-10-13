import SwiftUI

/// How CarPlay's Ask tab draws its three cards (Ask, Talk, New Chat). The pictures are drawn in
/// code by `CarPlayArtwork.startCard`; the car decides the cards' size and writes their words.
enum CarPlayCardLook: String, CaseIterable, Identifiable {
    case color, glow, orb, gold, graphite, marks

    var id: String { rawValue }

    var label: String {
        switch self {
        case .color: "Color"
        case .glow: "Glow"
        case .orb: "Orb"
        case .gold: "Gold"
        case .graphite: "Graphite"
        case .marks: "Marks"
        }
    }

    var blurb: String {
        switch self {
        case .color: "A color for each: blue, gold and green"
        case .glow: "Nearly black, with a light behind each symbol"
        case .orb: "The voice orb, ringed in each card's color"
        case .gold: "Graphite, with the symbols in gold"
        case .graphite: "Graphite and plain light symbols"
        case .marks: "Redde's own marks: voice bars and the gold spark"
        }
    }
}

/// The CarPlay cards row of the Appearance section: collapsed to the current look, it opens on
/// all six, each shown as the three pictures the car is given.
struct CarPlayCardSettings: View {
    @State private var settings = Settings.shared
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text("How the Ask, Talk and New Chat cards look on your car's screen. The car adds their names.")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(CarPlayCardLook.allCases) { look in
                Button { settings.carPlayCards = look } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(look.label).foregroundStyle(.primary)
                                Text(look.blurb).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if settings.carPlayCards == look {
                                Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                            }
                        }
                        HStack(spacing: 6) {
                            ForEach(CarPlayArtwork.Start.allCases, id: \.self) { start in
                                card(start, look)
                            }
                        }
                        .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(settings.carPlayCards == look ? .isSelected : [])
            }
        } label: {
            DisclosureSummary(title: "CarPlay cards") {
                HStack(spacing: 8) {
                    Text(settings.carPlayCards.label)
                    card(.ask, settings.carPlayCards)
                        .frame(height: 20)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func card(_ start: CarPlayArtwork.Start, _ look: CarPlayCardLook) -> some View {
        Image(uiImage: CarPlayArtwork.startCard(start, look: look))
            .resizable()
            .aspectRatio(CarPlayArtwork.wideCard.width / CarPlayArtwork.wideCard.height, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
