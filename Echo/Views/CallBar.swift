import SwiftUI

/// A live call with the voice screen put away (its chevron, or a swipe down on the orb): the call
/// goes on while the chat is read, and this bar over the chat says how it is going. A tap opens
/// the voice screen again; its two buttons shut the microphone and hang up. Asked 2026-11-09
/// ("build the call bar").
struct CallBar: View {
    let session: VoiceSession
    /// Whose call it is: the bot's name in a bot's chat, the assistant's otherwise.
    let name: String
    let face: BotFace?
    /// Back to the voice screen.
    let open: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) {
                HStack(spacing: 10) {
                    if let face {
                        BotAvatar(face: face, name: name, size: 32)
                    } else {
                        Image(systemName: "waveform")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(stateColor)
                            .frame(width: 32, height: 32)
                            .background(stateColor.opacity(0.15), in: .circle)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text(state)
                                .foregroundStyle(stateColor)
                                .contentTransition(.opacity)
                            if let began = session.liveBegan, !session.liveConnecting {
                                // The system counts it: nothing here is redrawn for the seconds.
                                Text(began, style: .timer)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    CallBarMeter(session: session, color: stateColor)
                        .padding(.trailing, 6)
                }
                .padding(.leading, 8)
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name), \(state)")
            .accessibilityHint("Opens the call")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("callBar")
            Button {
                if session.isMuted { session.unmute() } else { session.mute() }
            } label: {
                Image(systemName: session.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(session.isMuted ? Color.white : theme.textColor)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .background(session.isMuted ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.quaternary), in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.isMuted ? String(localized: "Unmute") : String(localized: "Mute"))
            Button {
                session.cancel()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.red, in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hang Up")
        }
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .foregroundStyle(theme.textColor)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .frame(maxWidth: 560)   // on an iPad or a Mac it is a pill, not a stripe across the window
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.25), value: session.isMuted)
        .animation(.snappy(duration: 0.25), value: state)
    }

    /// The words the voice screen has under its orb, the name left out (it is the line above).
    private var state: String {
        if session.liveConnecting { return (session.liveEngine ?? .gptLive).calling }
        if session.isMuted { return String(localized: "Muted") }
        return switch session.phase {
        case .thinking: String(localized: "Thinking")
        case .speaking: String(localized: "Speaking")
        case .error: String(localized: "Something went wrong")
        case .idle, .listening: String(localized: "On a call")
        }
    }

    private var stateColor: Color {
        if session.isMuted { return .orange }
        return switch session.phase {
        case .thinking: .orange
        case .speaking: .green
        case .error: .red
        case .idle, .listening: theme.accent
        }
    }
}

/// Four small bars that follow the call's sound, whoever is talking: ten times a second, and still
/// under Reduce Motion (the bar sits over a chat being read and scrolled).
private struct CallBarMeter: View {
    let session: VoiceSession
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let shape: [CGFloat] = [0.55, 1, 0.75, 0.45]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let level = reduceMotion || session.isMuted ? 0 : CGFloat(session.phase == .speaking ? session.replyLevel : session.micLevel)
            HStack(spacing: 2.5) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: 4 + 14 * level * Self.shape[index])
                }
            }
            .frame(width: 20, height: 20)
            .animation(.linear(duration: 0.1), value: level)
        }
        .accessibilityHidden(true)
    }
}
