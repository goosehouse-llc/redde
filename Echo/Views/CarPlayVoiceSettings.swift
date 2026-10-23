import SwiftUI

/// How CarPlay's voice screen shows what Redde is doing: listening, thinking, speaking. The
/// pictures are drawn in code by `CarPlayArtwork.voiceStateImage`; the car places them and writes
/// the words under them.
enum CarPlayVoiceLook: String, CaseIterable, Identifiable {
    case bars, lamps, kitt, orb, redde

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bars: "Bars"
        case .lamps: "Lamps"
        case .kitt: "KITT"
        case .orb: "Orb"
        case .redde: "Redde"
        }
    }

    var blurb: String {
        switch self {
        case .bars: "Three solid bars of light, and one that glides"
        case .lamps: "The bars as stacks of small lamps, and a scanner"
        case .kitt: "The lamps in red, on black"
        case .orb: "A ring of light around Redde's spark"
        case .redde: "Redde's face: it looks at you, looks up to think, and talks"
        }
    }
}

/// The CarPlay voice screen row of the Appearance section: collapsed to the current look, it
/// opens on all four, each shown as its Listening, Thinking and Speaking pictures. The chosen
/// look's pictures move as they do on the car, unless Reduce Motion is on; the others stand
/// still until they are picked.
struct CarPlayVoiceSettings: View {
    @State private var settings = Settings.shared
    @State private var expanded = false
    /// The chosen look's loops, drawn once the row is open and let go when it shuts.
    @State private var loops: [CarPlayArtwork.VoiceState: UIImage] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let shown: [CarPlayArtwork.VoiceState] = [.listening, .thinking, .speaking]
    private static let side: CGFloat = 60

    /// The look whose pictures move, if any do.
    private var playing: CarPlayVoiceLook? { expanded && !reduceMotion ? settings.carPlayVoice : nil }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text("What your car's screen shows while Redde listens, thinks and speaks, in that order.")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(CarPlayVoiceLook.allCases) { look in
                Button { settings.carPlayVoice = look } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(look.label).foregroundStyle(.primary)
                                Text(look.blurb).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if settings.carPlayVoice == look {
                                Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                            }
                        }
                        HStack(spacing: 10) {
                            ForEach(Self.shown, id: \.self) { state in
                                picture(state, look)
                            }
                        }
                        .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(settings.carPlayVoice == look ? .isSelected : [])
                .accessibilityIdentifier("carplay-voice-\(look.rawValue)")
            }
        } label: {
            DisclosureSummary(title: "CarPlay voice screen") {
                HStack(spacing: 8) {
                    Text(settings.carPlayVoice.label)
                    Image(uiImage: CarPlayArtwork.voiceStateImage(.speaking, look: settings.carPlayVoice, side: Self.side))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                }
            }
        }
        .task(id: playing) {
            loops = [:]
            guard let playing else { return }
            // Once the row has opened, or the checkmark has moved: a look's loops are about a
            // hundred pictures, and drawing them takes a moment.
            try? await Task.sleep(for: .milliseconds(350))
            for state in Self.shown where !Task.isCancelled {
                loops[state] = CarPlayArtwork.voicePicture(state, look: playing, side: Self.side, movingAt: 2)
                await Task.yield()
            }
        }
    }

    @ViewBuilder private func picture(_ state: CarPlayArtwork.VoiceState, _ look: CarPlayVoiceLook) -> some View {
        if look == playing, let loop = loops[state] {
            LoopingPicture(image: loop).frame(width: Self.side, height: Self.side)
        } else {
            Image(uiImage: CarPlayArtwork.voiceStateImage(state, look: look, side: Self.side))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: Self.side, height: Self.side)
        }
    }
}

/// A picture that plays its loop, as the car's card does: SwiftUI's own `Image` shows only the
/// first picture of one.
private struct LoopingPicture: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        // The frame SwiftUI gives it, not the picture's own size.
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            view.setContentHuggingPriority(.defaultLow, for: axis)
            view.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        if view.image !== image { view.image = image }
    }
}
