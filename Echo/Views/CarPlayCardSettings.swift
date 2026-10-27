import SwiftUI

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
            DisclosureSummary(title: String(localized: "CarPlay cards")) {
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
