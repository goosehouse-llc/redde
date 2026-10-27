import SwiftUI

/// How CarPlay's Bots tab draws each bot's card. The pictures are drawn in code by
/// `CarPlayArtwork.botCard`, the face in the mood the bot is in; the car writes its name and
/// what it is doing under it.
enum CarPlayBotLook: String, CaseIterable, Identifiable {
    case sticker, stage, peek, wide, glow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sticker: String(localized: "Sticker", comment: "A look for CarPlay's bot cards")
        case .stage: String(localized: "Stage", comment: "A look for CarPlay's bot cards: each bot in a spotlight")
        case .peek: String(localized: "Peek", comment: "A look for CarPlay's bot cards: a face peeking in")
        case .wide: String(localized: "Wide", comment: "A look for CarPlay's bot cards: wider cards")
        case .glow: String(localized: "Glow")
        }
    }

    var blurb: String {
        switch self {
        case .sticker: String(localized: "Bright, in each bot's colors, its face a sticker")
        case .stage: String(localized: "Each bot in a spotlight of its color")
        case .peek: String(localized: "A face too big for its card, peeking in")
        case .wide: String(localized: "Wider cards, three across, each face in a soft light")
        case .glow: String(localized: "Dark, each face in a soft light of its color")
        }
    }
}

/// The CarPlay bot cards row of the Appearance section: collapsed to the current look, it opens
/// on all five, each shown as four cards in the four moods (your own bots, once Redde has read
/// them).
struct CarPlayBotSettings: View {
    @State private var settings = Settings.shared
    @State private var directory = BotDirectory.shared
    @State private var expanded = false

    private static let moods: [CarPlayArtwork.BotMood] = [.ready, .working, .needsYou, .asleep]

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text("How each bot's card looks on your car's Bots tab. Its face shows what the bot is doing: working, waiting on you, or asleep after a quiet day. The car adds its name.")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(CarPlayBotLook.allCases) { look in
                Button { settings.carPlayBots = look } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(look.label).foregroundStyle(.primary)
                                Text(look.blurb).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if settings.carPlayBots == look {
                                Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                            }
                        }
                        HStack(spacing: 6) {
                            ForEach(Array(zip(samples, Self.moods).enumerated()), id: \.offset) { _, pair in
                                card(pair.0, pair.1, look)
                            }
                        }
                        .frame(height: look == .wide ? 40 : 56)
                        .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(settings.carPlayBots == look ? .isSelected : [])
            }
        } label: {
            DisclosureSummary(title: String(localized: "CarPlay bot cards")) {
                HStack(spacing: 8) {
                    Text(settings.carPlayBots.label)
                    if let first = samples.first {
                        card(first, .ready, settings.carPlayBots)
                            .frame(height: 20)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    /// Four bots to show the looks with: the first four of the server's, or four made up.
    private var samples: [(face: BotFace, name: String)] {
        if directory.key == settings.connectionKey, let roster = directory.roster, roster.listed.count >= 4 {
            let faces = roster.faces
            return roster.listed(in: settings.botOrderHere).prefix(4).map { bot in
                (faces[bot.name] ?? BotFace(seed: bot.name), bot.label(mainName: settings.headerTitle))
            }
        }
        return [(directory.mainFace, settings.headerTitle)] + ["scout", "quill", "fixit"].map { (BotFace(seed: $0), $0.capitalized) }
    }

    private func card(_ sample: (face: BotFace, name: String), _ mood: CarPlayArtwork.BotMood, _ look: CarPlayBotLook) -> some View {
        let size = CarPlayArtwork.botCardSize(look)
        return Image(uiImage: CarPlayArtwork.botCard(sample.face, named: sample.name, mood: mood, look: look))
            .resizable()
            .aspectRatio(size.width / size.height, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
