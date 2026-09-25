import SwiftUI

/// The orb at the centre of voice mode. Each is an image under VoiceOrbs/ in the asset catalog,
/// rendered from design/icons/orbs/<rawValue>.svg with a transparent background.
enum VoiceOrb: String, CaseIterable, Identifiable {
    case softGlass, glass, matte, flat, bubble, bubbleMatte, navyGlass, navyMatte, steelGlass, ink, tide, honey, spark, goldMatte
    case waveform, glassWave, matteWave, flatWave, bubbleWave, bubbleMatteWave, navyGlassWave, navyMatteWave, steelGlassWave, inkWave, goldWave

    var id: String { rawValue }

    var label: String {
        switch self {
        case .softGlass: "Softer Glass"
        case .glass: "Glass"
        case .matte: "Matte"
        case .flat: "Flat"
        case .bubble: "Bubble"
        case .bubbleMatte: "Matte Bubble"
        case .navyGlass: "Navy Glass"
        case .navyMatte: "Navy Matte"
        case .steelGlass: "Steel Glass"
        case .ink: "Ink"
        case .tide: "Tide"
        case .honey: "Honey"
        case .spark: "Spark"
        case .goldMatte: "Gold"
        case .waveform: "Softer Glass"
        case .glassWave: "Glass"
        case .matteWave: "Matte"
        case .flatWave: "Flat"
        case .bubbleWave: "Bubble"
        case .bubbleMatteWave: "Matte Bubble"
        case .navyGlassWave: "Navy Glass"
        case .navyMatteWave: "Navy Matte"
        case .steelGlassWave: "Steel Glass"
        case .inkWave: "Ink"
        case .goldWave: "Gold"
        }
    }

    /// The still picture: the picker, and voice mode for every orb but Waveform.
    var image: Image { Image("VoiceOrbs/\(rawValue)") }

    /// The Waveform orbs draw their bars live over an empty copy of the orb (`<name>Blank`),
    /// so they can move with the mic.
    var hasLiveWaveform: Bool { Self.waveforms.contains(self) }
    var voiceImage: Image { hasLiveWaveform ? Image("VoiceOrbs/\(rawValue)Blank") : image }
    static let waveforms: [VoiceOrb] = [.waveform, .glassWave, .matteWave, .flatWave, .bubbleWave, .bubbleMatteWave,
                                        .navyGlassWave, .navyMatteWave, .steelGlassWave, .inkWave, .goldWave]
    static let stills: [VoiceOrb] = allCases.filter { !waveforms.contains($0) }
    /// Dark bars on the gold orb, light on the rest.
    var waveColor: Color {
        self == .goldWave ? Color(red: 0.106, green: 0.133, blue: 0.188) : Color(red: 0.863, green: 0.890, blue: 0.933)
    }
    /// Where the bars sit: a bubble's body is a little above and right of the image's centre.
    var waveOffset: CGSize { isRound ? .zero : CGSize(width: 1.5, height: -3) }

    /// The speech-bubble orbs have a tail, so voice mode lights their outline instead of
    /// drawing a round ring around them.
    var isRound: Bool { ![.bubble, .bubbleMatte, .bubbleWave, .bubbleMatteWave].contains(self) }
}

/// The Voice orb row of the Appearance section: collapsed to the current orb, expands to the grid.
struct VoiceOrbSettings: View {
    @State private var settings = Settings.shared
    @State private var expanded = false

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 12, alignment: .top)]

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            grid("Still", VoiceOrb.stills)
            grid("Waveform · moves when you speak", VoiceOrb.waveforms)
        } label: {
            DisclosureSummary(title: "Voice orb") {
                HStack(spacing: 8) {
                    Text(settings.voiceOrb.label)
                    settings.voiceOrb.image
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func grid(_ title: String, _ orbs: [VoiceOrb]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(orbs) { orb in
                    Button { settings.voiceOrb = orb } label: {
                        VStack(spacing: 6) {
                            orb.image
                                .resizable()
                                .scaledToFit()
                                .frame(width: 58, height: 58)
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
                    .accessibilityLabel(orb.hasLiveWaveform ? "\(orb.label) waveform" : orb.label)
                    .accessibilityAddTraits(settings.voiceOrb == orb ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 6)
    }
}
