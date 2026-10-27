import Foundation

// The looks of CarPlay's screens (Settings → Voice → CarPlay), kept in Settings; their pickers
// are the iPhone's (`CarPlayCardSettings`, `CarPlayVoiceSettings`, `CarPlayBotSettings`).

/// How CarPlay's Ask tab draws its three cards (Ask, Talk, New Chat). The pictures are drawn in
/// code by `CarPlayArtwork.startCard`; the car decides the cards' size and writes their words.
enum CarPlayCardLook: String, CaseIterable, Identifiable {
    case color, glow, orb, gold, graphite, marks

    var id: String { rawValue }

    var label: String {
        switch self {
        case .color: String(localized: "Color", comment: "A look for CarPlay's cards: one color each")
        case .glow: String(localized: "Glow")
        case .orb: String(localized: "Orb")
        case .gold: String(localized: "Gold")
        case .graphite: String(localized: "Graphite")
        case .marks: String(localized: "Marks", comment: "A look for CarPlay's cards: Redde's own marks")
        }
    }

    var blurb: String {
        switch self {
        case .color: String(localized: "A color for each: blue, gold and green")
        case .glow: String(localized: "Nearly black, with a light behind each symbol")
        case .orb: String(localized: "The voice orb, ringed in each card's color")
        case .gold: String(localized: "Graphite, with the symbols in gold")
        case .graphite: String(localized: "Graphite and plain light symbols")
        case .marks: String(localized: "Redde's own marks: voice bars and the gold spark")
        }
    }
}

/// How CarPlay's voice screen shows what Redde is doing: listening, thinking, speaking. The
/// pictures are drawn in code by `CarPlayArtwork.voiceStateImage`; the car places them and writes
/// the words under them.
enum CarPlayVoiceLook: String, CaseIterable, Identifiable {
    case bars, lamps, kitt, orb, redde

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bars: String(localized: "Bars", comment: "A look for CarPlay's voice screen: bars of light")
        case .lamps: String(localized: "Lamps", comment: "A look for CarPlay's voice screen: stacks of small lamps")
        case .kitt: "KITT"
        case .orb: String(localized: "Orb")
        case .redde: "Redde"
        }
    }

    var blurb: String {
        switch self {
        case .bars: String(localized: "Three solid bars of light, and one that glides")
        case .lamps: String(localized: "The bars as stacks of small lamps, and a scanner")
        case .kitt: String(localized: "The lamps in red, on black")
        case .orb: String(localized: "A ring of light around Redde's spark")
        case .redde: String(localized: "Redde's face: it looks at you, looks up to think, and talks")
        }
    }
}

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
