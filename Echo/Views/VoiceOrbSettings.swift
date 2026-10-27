import SwiftUI

/// The orb at the centre of voice mode. Each is an image under VoiceOrbs/ in the asset catalog,
/// rendered from design/icons/orbs/<rawValue>.svg with a transparent background, and draws its
/// bars live over an empty copy (`<rawValue>Blank`) so they move with the mic. Dark Glass is the
/// exception: voice mode draws it in code (`GlassOrb`), and its picker picture comes from
/// design/icons/orbs/darkGlass.swift. Redde's own face has no picture either: it is Redde's bot
/// creature (`BotFace.main`), drawn live in voice mode (`ReddeVoiceFace`) and in the picker.
enum VoiceOrb: String, CaseIterable, Identifiable {
    // In the picker's order: Redde's own face first.
    case reddeFace
    case darkGlass
    case waveform, glassWave, matteWave, flatWave, bubbleWave, bubbleMatteWave, navyGlassWave, navyMatteWave, steelGlassWave, inkWave, goldWave

    var id: String { rawValue }

    /// The orb voice mode shows: the one picked, but with Settings → Appearance → Bot faces off,
    /// the Bubble in place of Redde's face (which is the default), so no face is shown there.
    static func shown(_ settings: Settings = .shared) -> VoiceOrb {
        settings.voiceOrb == .reddeFace && !settings.botFaces ? .bubbleWave : settings.voiceOrb
    }

    var label: String {
        switch self {
        case .darkGlass: String(localized: "Dark Glass", comment: "A look for the voice orb")
        case .reddeFace: "Redde"
        case .waveform: String(localized: "Softer Glass", comment: "A look for the voice orb")
        case .glassWave: String(localized: "Glass", comment: "A look for the voice orb")
        case .matteWave: String(localized: "Matte", comment: "A look for the voice orb")
        case .flatWave: String(localized: "Flat", comment: "A look for the voice orb")
        case .bubbleWave: String(localized: "Bubble", comment: "A look for the voice orb")
        case .bubbleMatteWave: String(localized: "Matte Bubble", comment: "A look for the voice orb")
        case .navyGlassWave: String(localized: "Navy Glass", comment: "A look for the voice orb")
        case .navyMatteWave: String(localized: "Navy Matte", comment: "A look for the voice orb")
        case .steelGlassWave: String(localized: "Steel Glass", comment: "A look for the voice orb")
        case .inkWave: String(localized: "Ink", comment: "A look for the voice orb")
        case .goldWave: String(localized: "Gold", comment: "A look for the voice orb")
        }
    }

    /// The picture with its bars drawn, for the picker.
    var image: Image { Image("VoiceOrbs/\(rawValue)") }
    /// Drawn in code in voice mode, with the light at full strength, instead of from a picture.
    var isDrawn: Bool { self == .darkGlass }
    /// The empty face voice mode draws the live bars and light over (a drawn orb has none).
    var voiceImage: Image { isDrawn ? image : Image("VoiceOrbs/\(rawValue)Blank") }
    /// Dark bars on the gold orb, light on the rest.
    var waveColor: Color {
        switch self {
        case .goldWave: Color(red: 0.106, green: 0.133, blue: 0.188)
        case .darkGlass: Color(red: 0.914, green: 0.945, blue: 1)
        default: Color(red: 0.863, green: 0.890, blue: 0.933)
        }
    }
    /// Where the bars sit: a bubble's body is a little above and right of the image's centre.
    var waveOffset: CGSize { isRound ? .zero : CGSize(width: 1.5, height: -3) }

    /// The speech-bubble orbs have a tail, so voice mode lights their outline instead of
    /// drawing a round ring around them.
    var isRound: Bool { ![.bubbleWave, .bubbleMatteWave, .reddeFace].contains(self) }
}

/// An orb as the picker shows it: its picture, or Redde's face drawn.
struct VoiceOrbPicture: View {
    let orb: VoiceOrb
    let size: CGFloat

    var body: some View {
        if orb == .reddeFace {
            BotAvatar(face: BotDirectory.shared.mainFace, size: size)
        } else {
            orb.image.resizable().scaledToFit().frame(width: size, height: size)
        }
    }
}

/// What moves inside a round orb's face, under the bars.
enum OrbLight: String, CaseIterable, Identifiable {
    /// Patches of colour drifting, turning, hue shifting.
    case nebula
    /// Ribbons of light sweeping across like a curtain.
    case aurora
    /// A pulsing nucleus with sparks orbiting and motes rising.
    case core

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nebula: String(localized: "Nebula", comment: "The light inside the voice orb")
        case .aurora: String(localized: "Aurora", comment: "The light inside the voice orb")
        case .core: String(localized: "Core", comment: "The light inside the voice orb")
        }
    }

    var detail: String {
        switch self {
        case .nebula: String(localized: "Colour drifting and turning")
        case .aurora: String(localized: "Ribbons of light sweeping across")
        case .core: String(localized: "A pulsing heart with sparks around it")
        }
    }
}

/// The Voice orb rows of the Appearance section: the face (collapsed to the current orb, expands
/// to the grid) and the light inside it.
struct VoiceOrbSettings: View {
    @State private var settings = Settings.shared
    @State private var expanded = false

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 12, alignment: .top)]

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            grid
        } label: {
            DisclosureSummary(title: String(localized: "Voice orb")) {
                HStack(spacing: 8) {
                    Text(settings.voiceOrb.label)
                    VoiceOrbPicture(orb: settings.voiceOrb, size: 24)
                        .accessibilityHidden(true)
                }
            }
        }
        Picker("Orb light", selection: $settings.orbLight) {
            ForEach(OrbLight.allCases) { light in
                Text(light.label).tag(light)
            }
        }
        .pickerStyle(.menu)
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The bars move when you speak; the light inside follows “Orb light”. Redde looks at you instead, and talks with the reply.")
                .font(.footnote).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(VoiceOrb.allCases) { orb in
                    Button { settings.voiceOrb = orb } label: {
                        VStack(spacing: 6) {
                            VoiceOrbPicture(orb: orb, size: 58)
                                .padding(4)
                                .overlay {
                                    RoundedRectangle(cornerRadius: orb.isRound ? 40 : 16, style: .continuous)
                                        .strokeBorder(.tint, lineWidth: settings.voiceOrb == orb ? 2.5 : 0)
                                }
                            Text(orb.label)
                                .font(.caption)
                                .foregroundStyle(settings.voiceOrb == orb ? .primary : .secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(orb.label)
                    .accessibilityAddTraits(settings.voiceOrb == orb ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 6)
    }
}
