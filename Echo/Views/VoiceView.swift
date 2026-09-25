import SwiftUI

/// Full-screen voice mode. The orb near the top is the one control that matters: the phase
/// under it says what a tap does. Your words and the reply sit right beneath it; typing,
/// replay/stop and ending the call wait at the bottom.
struct VoiceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Conversation.self) private var conversation
    @Environment(\.theme) private var theme
    @Bindable var session: VoiceSession
    /// The keyboard button: leave voice mode with the composer focused, ready to type. (The red
    /// ✕ just ends voice mode.)
    var onSwitchToTyping: () -> Void = {}

    /// Dev hook: `-echo.voiceDemo` shows voice mode mid-listen — raised waveform, the Listening
    /// label, a spoken caption — for store screenshots, where the simulator has no microphone.
    #if DEBUG
    private static let demo = CommandLine.arguments.contains("-echo.voiceDemo")
    #else
    private static let demo = false
    #endif
    private var phase: VoiceSession.Phase { Self.demo ? .listening : session.phase }

    var body: some View {
        VStack(spacing: 0) {
            header
            orb
                .padding(.top, 28)
            Text(phaseTitle)
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(phaseColor)
                .contentTransition(.opacity)
                .accessibilityLabel(phaseTitle)   // read in normal case, not letter by letter
                .padding(.top, 18)
            captionArea
                .padding(.top, 14)
                .frame(maxHeight: .infinity, alignment: .top)
            if let pending = conversation.pendingInterrupt {
                InterruptCard(interrupt: pending.interrupt)
            }
            footer
            controls
                .padding(.top, 14)
                .padding(.bottom, 12)
        }
        .padding(.horizontal)
        .background(theme.background ?? Color(.systemBackground))
        .foregroundStyle(theme.text ?? Color.primary)
        .onAppear { session.attachHeadsetControls() }
        .onDisappear { session.detachHeadsetControls(); session.cancel() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $session.continuous) {
                Label("Hands-free", systemImage: "waveform")
            }
            .toggleStyle(.button)
            .buttonStyle(.glass)
            Spacer(minLength: 0)
            if !conversation.messages.isEmpty {
                Text(conversation.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 170, alignment: .trailing)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - The orb

    private var orb: some View {
        Button(action: session.primaryAction) {
            // Its own view: the mic level ticks ten times a second while listening, and only the
            // face should re-evaluate for it, not this whole screen.
            OrbFace(session: session, phase: phase, phaseColor: phaseColor, demo: Self.demo)
                // Fixed footprint; the aura spills past it without pushing the text below around
                // with each syllable.
                .frame(width: 212, height: 212)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel(phaseTitle)
        .accessibilityHint(orbHint)
        .sensoryFeedback(.impact, trigger: session.phase)
    }

    // MARK: - Words

    /// While listening: what you're saying, large. Otherwise: the last exchange, rendered like
    /// the text screen, scrolling as it streams.
    @ViewBuilder
    private var captionArea: some View {
        switch phase {
        case .listening:
            let words = Self.demo ? "Okay, prune anything older than thirty days and try the media share again" : session.liveTranscript
            Text(words.isEmpty ? "Go ahead." : words)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(words.isEmpty ? .tertiary : .primary)
                .frame(maxWidth: .infinity)
                .animation(.default, value: words)
        case let .error(message):
            Text(message).font(.title3).multilineTextAlignment(.center).foregroundStyle(.red)
        case .idle, .thinking, .speaking:
            if lastExchange.isEmpty {
                Text("Tap the orb and talk.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                exchangeView
            }
        }
    }

    /// The most recent user turn and its reply.
    private var lastExchange: [Message] {
        guard let lastUser = conversation.messages.lastIndex(where: { $0.role == .user }) else { return [] }
        return Array(conversation.messages[lastUser...])
    }

    private var exchangeView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(lastExchange) { message in
                        MessageRow(message: message,
                                   isLive: conversation.isStreaming && message.id == conversation.messages.last?.id,
                                   showActions: false)
                            .id(message.id)
                    }
                    if let tool = session.activeTool, session.phase == .thinking {
                        Label(tool, systemImage: "wrench.adjustable")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.orange)
                            .symbolEffect(.pulse)
                            .padding(.leading, 6)
                    }
                    Color.clear.frame(height: 1).id("voice-bottom")
                }
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.hidden)
            .onChange(of: conversation.messages.last?.text) { proxy.scrollTo("voice-bottom", anchor: .bottom) }
            .onChange(of: conversation.messages.last?.reasoning.count) { proxy.scrollTo("voice-bottom", anchor: .bottom) }
        }
    }

    // MARK: - Bottom

    private var footer: some View {
        VStack(spacing: 6) {
            if session.continuous {
                Text("Say “stop listening” or “that's all” to end hands-free.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let m = session.lastMetrics {
                Text(m.summary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// Type instead, replay or stop the reading, and end.
    private var controls: some View {
        HStack(spacing: 28) {
            roundButton("Switch to typing", "keyboard") {
                session.cancel()
                dismiss()
                onSwitchToTyping()
            }
            .accessibilityHint("Closes voice mode and opens the keyboard")
            if session.phase == .speaking {
                // Pause holds the reply where it is; Play carries on. The red square still ends it.
                if session.isPaused {
                    roundButton("Resume", "play.fill") { session.resumeSpeaking() }
                } else {
                    roundButton("Pause", "pause.fill") { session.pauseSpeaking() }
                }
            } else {
                roundButton("Replay the last answer", "arrow.counterclockwise") { session.replayLastReply() }
                    .disabled(!canReplay || session.lastReplyText == nil)
            }
            // While something is running (listening, thinking, reading the reply) the button is a
            // red square that only stops it; once nothing runs it's the ✕ that leaves voice mode.
            Button {
                let wasWorking = solIsWorking   // cancel() idles the phase synchronously
                session.cancel()
                if !wasWorking { dismiss() }
            } label: {
                Image(systemName: solIsWorking ? "stop.fill" : "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 60, height: 60)
                    .background(Color.red, in: .circle)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel(solIsWorking ? "Stop" : "End voice mode")
            .accessibilityHint(solIsWorking ? "Stops it. Press again to leave voice mode" : "Returns to the conversation")
        }
    }

    private func roundButton(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.medium))
                .frame(width: 60, height: 60)
                .background(theme.surface ?? Color(.secondarySystemBackground), in: .circle)
                .overlay(Circle().strokeBorder(.quaternary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Something is running: Sol listening, thinking or reading its reply aloud (or the reply
    /// is still streaming).
    private var solIsWorking: Bool {
        phase == .listening || phase == .thinking || phase == .speaking || conversation.isStreaming
    }

    private var canReplay: Bool {
        if case .error = session.phase { return true }
        return session.phase == .idle
    }

    private var orbHint: String {
        switch session.phase {
        case .idle, .error: "Double tap to start listening"
        case .listening: "Double tap to stop listening and send"
        case .thinking: "Double tap to cancel"
        case .speaking: "Double tap to interrupt and speak"
        }
    }

    private var phaseTitle: String {
        switch phase {
        case .idle: "Ready"
        case .listening: "Listening"
        case .thinking: "\(Settings.shared.headerTitle) is thinking"
        case .speaking: "Speaking"
        case .error: "Something went wrong"
        }
    }

    private var phaseColor: Color {
        switch phase {
        case .listening: theme.accent
        case .thinking: .orange
        case .speaking: .green
        case .error: .red
        case .idle: .secondary
        }
    }
}

/// The aura and the orb image, the only part of the voice screen that follows the mic level.
private struct OrbFace: View {
    let session: VoiceSession
    let phase: VoiceSession.Phase
    let phaseColor: Color
    let demo: Bool

    var body: some View {
        let listening = phase == .listening
        let level = demo ? 0.6 : CGFloat(session.recognizer.level)
        ZStack {
            // The aura: wide and bright while listening, swelling with your voice; a faint
            // halo otherwise.
            Circle()
                .fill(RadialGradient(colors: [phaseColor.opacity(listening ? 0.45 : 0.16), phaseColor.opacity(0)],
                                     center: .center, startRadius: 60, endRadius: listening ? 130 + level * 40 : 100))
                .frame(width: listening ? 270 + level * 50 : 196, height: listening ? 270 + level * 50 : 196)
                .animation(.easeOut(duration: 0.3), value: listening)
            // The orb picked in Settings → Appearance (design/icons/orbs/): a round one is ringed
            // in the phase color; a speech bubble glows in it along its own outline instead.
            let orb = Settings.shared.voiceOrb
            orb.voiceImage
                .resizable()
                .scaledToFit()
                .frame(width: 156, height: 156)
                .overlay {
                    if orb.hasLiveWaveform {
                        LiveWaveform(phase: phase,
                                     level: { demo ? 0.55 : session.phase == .speaking ? session.output.meterLevel : session.recognizer.meterLevel },
                                     color: orb.waveColor)
                            .offset(orb.waveOffset)
                    }
                }
                .overlay {
                    if orb.isRound {
                        Circle().strokeBorder(phaseColor.opacity(phase == .idle ? 0 : 0.8), lineWidth: 3).padding(-4)
                    }
                }
                .shadow(color: orb.isRound || phase == .idle ? .clear : phaseColor.opacity(0.9), radius: 10)
                .shadow(color: .black.opacity(0.35), radius: 22, y: 12)
                .scaleEffect(listening ? 1 + level * 0.06 : 1)
                .accessibilityHidden(true)
        }
        // One animation for everything the level drives (aura size and orb scale).
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

/// Waveform orb's bars, a KITT-style voice box: seven bars, all the same height and perfectly
/// still until your voice registers. Then they rise together with its level — one value drives
/// every bar, so the shape moves as a unit — the centre highest and each bar outward a step
/// lower, mirrored on both sides. While the reply is spoken they follow its voice the same way
/// (Kokoro's measured level, or a pulse per word from the built-in voice). Still under Reduce Motion.
private struct LiveWaveform: View {
    let phase: VoiceSession.Phase
    /// Read every frame: your voice (the mic meter) while listening, the reply's while speaking.
    let level: () -> Float
    var color = Color(red: 0.863, green: 0.890, blue: 0.933)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far each bar rises with sound: centre most, each step outward less, sides equal. The
    /// falloff is halfway to the spark's own profile — its arms curve in, so height drops as
    /// (1 − √(d/D))² away from the centre — giving a sharp centre peak with short outer bars.
    private static let weights: [CGFloat] = [0.13, 0.27, 0.51, 1.0, 0.51, 0.27, 0.13]
    /// Every bar's height at rest: a flat line.
    private static let rest: CGFloat = 10
    private static let tallest: CGFloat = 80
    /// The meter is already measured above the room's noise floor; this ignores what's left of
    /// soft sounds so only speech moves the bars.
    private static let gate: Float = 0.06
    /// How much louder than the raw level the bars read, so normal speech reaches near full height.
    private static let gain: Float = 1.4

    var body: some View {
        // The meter is polled, not observed: nothing re-evaluates this body when the room gets
        // loud, so the gate is applied per frame inside the timeline, which runs whenever the
        // mic or the reply is live.
        let live = !reduceMotion && (phase == .listening || phase == .speaking)
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !live)) { context in
            let l = live ? level() : 0
            let moving = phase == .speaking || l > Self.gate
            let drive = moving ? loudness(l) : nil
            HStack(spacing: 5) {
                ForEach(Self.weights.indices, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 9, height: height(i, drive))
                }
            }
        }
        .frame(height: Self.tallest)
    }

    /// How loud, 0…1, for this frame. The reply's meter isn't measured against room noise, so
    /// it gets its own floor: quiet gaps between words read as rest.
    private func loudness(_ l: Float) -> CGFloat {
        if phase == .speaking {
            return CGFloat(min(max((l - 0.2) / 0.6, 0), 1)).squareRoot()
        }
        return CGFloat(min(max((l - Self.gate) / (1 - Self.gate) * Self.gain, 0), 1)).squareRoot()
    }

    /// nil drive = at rest.
    private func height(_ i: Int, _ drive: CGFloat?) -> CGFloat {
        guard let drive else { return Self.rest }
        return Self.rest + (Self.tallest - Self.rest) * Self.weights[i] * drive
    }
}
