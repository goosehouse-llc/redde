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
    private static let demo = DevHooks.voiceDemo
    #else
    private static let demo = false
    #endif
    private var phase: VoiceSession.Phase { Self.demo ? .listening : session.phase }

    var body: some View {
        VStack(spacing: 0) {
            header
            orb
                .padding(.top, 28)
            // The state word pushes the last one up and out, in its own colour.
            ZStack {
                Text(phaseTitle)
                    .foregroundStyle(phaseColor)
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1.2)
                .id(phaseTitle)
                .transition(.push(from: .bottom).combined(with: .opacity))
            }
            .clipped()
            .animation(.snappy(duration: 0.35), value: phaseTitle)
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
                .frame(width: 233, height: 233)
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
            if words.isEmpty {
                Text("Go ahead.")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            } else {
                RisingCaption(text: words)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
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
    @Environment(\.theme) private var theme

    /// The `-echo.voiceDemo` pose: a level that moves like speech (two beating waves, never
    /// quite silent), so screenshots and the promo video show a live waveform.
    static func demoLevel() -> Float {
        let t = Date.now.timeIntervalSinceReferenceDate
        return Float(0.3 + 0.45 * abs(sin(t * 5.1) * sin(t * 1.7 + 0.8)))
    }

    var body: some View {
        let listening = phase == .listening
        let level = demo ? 0.6 : CGFloat(session.recognizer.level)
        ZStack {
            // The aura: wide and bright while listening, swelling with your voice; a faint
            // halo otherwise.
            Circle()
                .fill(RadialGradient(colors: [phaseColor.opacity(listening ? 0.45 : 0.16), phaseColor.opacity(0)],
                                     center: .center, startRadius: 66, endRadius: listening ? 143 + level * 44 : 110))
                .frame(width: listening ? 297 + level * 55 : 216, height: listening ? 297 + level * 55 : 216)
                .animation(.easeOut(duration: 0.3), value: listening)
            // The orb picked in Settings → Appearance (design/icons/orbs/): a round one is ringed
            // in the phase color; a speech bubble glows in it along its own outline instead.
            let orb = Settings.shared.voiceOrb
            let meter: () -> Float = { demo ? Self.demoLevel() : session.phase == .speaking ? session.output.meterLevel : session.recognizer.meterLevel }
            if listening || phase == .speaking {
                Halos(color: phaseColor, diameter: orb.isDrawn ? GlassOrb.haloDiameter : 198)
            } else if phase == .idle {
                // At rest: one faint, slow ring now and then, so it never looks switched off.
                Halos(color: phaseColor, subtle: true, diameter: orb.isDrawn ? GlassOrb.haloDiameter : 198)
            }
            if orb.isDrawn {
                GlassOrb(light: Settings.shared.orbLight, phase: phase, phaseColor: phaseColor, accent: theme.accent)
                    .overlay { LiveWaveform(phase: phase, level: meter, color: orb.waveColor, shadowed: false) }
                    // The same ring outside the face as the picture orbs wear, in the phase
                    // colour and gone at rest, and the thinking arc on it.
                    .overlay {
                        Circle().strokeBorder(phaseColor.opacity(phase == .idle ? 0 : 0.8), lineWidth: 3).padding(-GlassOrb.ringOutset)
                    }
                    .overlay {
                        if phase == .thinking { ThinkingArc(color: phaseColor).padding(-GlassOrb.ringOutset) }
                    }
                    .scaleEffect(listening ? 1 + level * 0.06 : 1)
                    .accessibilityHidden(true)
            } else {
            orb.voiceImage
                .resizable()
                .scaledToFit()
                .frame(width: 172, height: 172)
                .overlay {
                    // Colour moving inside the orb, under the bars, so it looks liquid rather than
                    // printed. Masked by the orb's own picture, so it fills a bubble's shape, tail
                    // and all, as well as a circle. Brighter while live, swelling with your voice
                    // (or the reply's).
                    let live = phase == .listening || phase == .speaking
                    // The light is the mood, the bars are the signal. Three patches added together
                    // went near-white exactly where the bars sit, so the light eases off toward
                    // the middle: gently and smoothly, about half strength behind the bars. A
                    // deeper cut read as a hole, a ring of light round a dark disc, not an orb.
                    let strength: CGFloat = live ? 0.8 + level * 0.35 : phase == .idle ? 0.42 : 0.62
                    Group {
                        switch Settings.shared.orbLight {
                        case .nebula: DriftingBlobs(color: phaseColor, strength: strength, swirling: phase == .thinking)
                        case .aurora: AuroraLight(color: phaseColor, strength: strength, swirling: phase == .thinking)
                        case .core: CoreLight(color: phaseColor, strength: strength, swirling: phase == .thinking)
                        }
                    }
                    .offset(orb.waveOffset)
                    .mask {
                        RadialGradient(stops: [.init(color: .black.opacity(0.48), location: 0),
                                               .init(color: .black.opacity(0.56), location: 0.3),
                                               .init(color: .black.opacity(0.76), location: 0.62),
                                               .init(color: .black, location: 1)],
                                       center: .center, startRadius: 0, endRadius: 88)
                            .offset(orb.waveOffset)
                    }
                    .mask { orb.voiceImage.resizable().scaledToFit().padding(orb.isRound ? 6 : 3) }
                }
                .overlay {
                    LiveWaveform(phase: phase, level: meter, color: orb.waveColor)
                        .offset(orb.waveOffset)
                }
                .overlay {
                    if orb.isRound {
                        Circle().strokeBorder(phaseColor.opacity(phase == .idle ? 0 : 0.8), lineWidth: 3).padding(-4)
                    }
                }
                .overlay {
                    // Thinking: a short arc chasing round the rim.
                    if phase == .thinking { ThinkingArc(color: phaseColor).padding(-4) }
                }
                .shadow(color: orb.isRound || phase == .idle ? .clear : phaseColor.opacity(0.9), radius: 10)
                .shadow(color: .black.opacity(0.35), radius: 22, y: 12)
                .scaleEffect(listening ? 1 + level * 0.06 : 1)
                .accessibilityHidden(true)
            }
        }
        // One animation for everything the level drives (aura size and orb scale).
        .animation(.easeOut(duration: 0.12), value: level)
        .animation(.easeOut(duration: 0.3), value: listening)
    }
}

/// Colour alive inside the orb: three patches of light, the phase colour and hues beside it,
/// each wandering on its own rhythm so they cross and merge rather than swing together, the
/// whole slowly turning and its hue drifting; brighter while you or the reply are talking, and
/// spinning while the model thinks. Animated offsets, scales, a rotation and a hue shift only,
/// so nothing re-evaluates per frame; still under Reduce Motion.
private struct DriftingBlobs: View {
    let color: Color
    /// 1 while thinking, more while live, less at rest.
    var strength: CGFloat
    var swirling: Bool
    @State private var a = false
    @State private var b = false
    @State private var c = false
    @State private var hue = false
    @State private var turn = false
    @State private var spin = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            blob(size: 187, opacity: min(0.95, 0.75 * strength), tint: color)
                .offset(x: a ? 42 : -46, y: a ? 29 : -26)
                .scaleEffect(a ? 1.2 : 0.85)
            blob(size: 154, opacity: min(0.85, 0.55 * strength), tint: color.mix(with: .white, by: 0.12))
                .offset(x: b ? -40 : 37, y: b ? -37 : 24)
                .scaleEffect(b ? 0.8 : 1.25)
            blob(size: 143, opacity: min(0.85, 0.6 * strength), tint: color.mix(with: .purple, by: 0.5))
                .offset(x: c ? 15 : -20, y: c ? 44 : -44)
                .scaleEffect(c ? 1.15 : 0.85)
        }
        .hueRotation(.degrees(hue ? 28 : -18))
        .rotationEffect(.degrees(turn ? 360 : 0))
        .rotationEffect(.degrees(spin ? 360 : 0))
        .frame(width: 172, height: 172)
        .blendMode(.plusLighter)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) { a = true }
            withAnimation(.easeInOut(duration: 3.9).repeatForever(autoreverses: true)) { b = true }
            withAnimation(.easeInOut(duration: 2.3).repeatForever(autoreverses: true)) { c = true }
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) { hue = true }
            withAnimation(.linear(duration: 16).repeatForever(autoreverses: false)) { turn = true }
        }
        .onChange(of: swirling, initial: true) { _, swirling in
            guard !reduceMotion else { return }
            if swirling {
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { spin = true }
            } else {
                withAnimation(.easeOut(duration: 0.8)) { spin = false }
            }
        }
        .animation(.easeOut(duration: 0.25), value: strength)
        .accessibilityHidden(true)
    }

    private func blob(size: CGFloat, opacity: Double, tint: Color) -> some View {
        Circle()
            .fill(RadialGradient(colors: [tint.opacity(opacity), tint.opacity(opacity * 0.55), tint.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
    }
}

/// Aurora: three ribbons of light sweeping across the face on their own rhythms, like a curtain
/// behind the bars; faster while the model thinks. Animated offsets only; still under Reduce
/// Motion.
private struct AuroraLight: View {
    let color: Color
    var strength: CGFloat
    var swirling: Bool
    @State private var a = false
    @State private var b = false
    @State private var c = false
    @State private var tilt = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ribbon(width: 300, height: 56, y: -36, opacity: min(0.85, 0.65 * strength), from: color, to: color.mix(with: .white, by: 0.12))
                .offset(x: a ? 70 : -70)
            ribbon(width: 300, height: 50, y: 6, opacity: min(0.9, 0.7 * strength), from: color.mix(with: .purple, by: 0.5), to: color)
                .offset(x: b ? -62 : 62)
            ribbon(width: 300, height: 42, y: 44, opacity: min(0.8, 0.55 * strength), from: color.mix(with: .mint, by: 0.45), to: color)
                .offset(x: c ? 54 : -54)
        }
        .rotationEffect(.degrees(tilt ? -10 : 10))
        .frame(width: 172, height: 172)
        .blendMode(.plusLighter)
        .onAppear { start() }
        .onChange(of: swirling) { start() }
        .animation(.easeOut(duration: 0.25), value: strength)
        .accessibilityHidden(true)
    }

    private func start() {
        guard !reduceMotion else { return }
        let speed = swirling ? 0.45 : 1.0
        withAnimation(.easeInOut(duration: 4.0 * speed).repeatForever(autoreverses: true)) { a.toggle() }
        withAnimation(.easeInOut(duration: 5.5 * speed).repeatForever(autoreverses: true)) { b.toggle() }
        withAnimation(.easeInOut(duration: 3.2 * speed).repeatForever(autoreverses: true)) { c.toggle() }
        withAnimation(.easeInOut(duration: 7 * speed).repeatForever(autoreverses: true)) { tilt.toggle() }
    }

    private func ribbon(width: CGFloat, height: CGFloat, y: CGFloat, opacity: Double, from: Color, to: Color) -> some View {
        Capsule()
            .fill(LinearGradient(colors: [from.opacity(0), from.opacity(opacity), to.opacity(opacity), from.opacity(0)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: width, height: height)
            .blur(radius: 9)
            .offset(y: y)
    }
}

/// Core: a pulsing nucleus of the phase colour with sparks orbiting it two ways and motes rising
/// through, like something breathing in a jar; the sparks race while the model thinks. Animated
/// scale, rotation and offsets only; still under Reduce Motion.
private struct CoreLight: View {
    let color: Color
    var strength: CGFloat
    var swirling: Bool
    @State private var pulse = false
    @State private var orbit = false
    @State private var rise = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [color.mix(with: .white, by: 0.2).opacity(min(1, 0.95 * strength)),
                                              color.opacity(min(0.9, 0.6 * strength)), color.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: 62))
                .frame(width: 124, height: 124)
                .scaleEffect(pulse ? 1.18 : 0.94)
            sparks(angles: [0, 120, 240], radius: 66, tint: color.mix(with: .white, by: 0.6))
                .rotationEffect(.degrees(orbit ? 360 : 0))
            sparks(angles: [60, 180, 300], radius: 54, tint: color.mix(with: .purple, by: 0.5))
                .rotationEffect(.degrees(orbit ? -360 : 0))
            ForEach(0 ..< 3, id: \.self) { i in
                Circle()
                    .fill(color.mix(with: .white, by: 0.5).opacity(min(0.9, 0.7 * strength)))
                    .frame(width: CGFloat(5 + i), height: CGFloat(5 + i))
                    .offset(x: CGFloat(i - 1) * 30, y: rise ? -70 : 60)
                    .opacity(rise ? 0 : 0.9)
                    .animation(reduceMotion ? nil : .easeIn(duration: 3.4).repeatForever(autoreverses: false).delay(Double(i) * 1.1), value: rise)
            }
        }
        .frame(width: 172, height: 172)
        .blendMode(.plusLighter)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { pulse = true }
            rise = true
            spinSparks()
        }
        .onChange(of: swirling) { spinSparks() }
        .animation(.easeOut(duration: 0.25), value: strength)
        .accessibilityHidden(true)
    }

    private func spinSparks() {
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: swirling ? 2.2 : 9).repeatForever(autoreverses: false)) { orbit.toggle() }
    }

    private func sparks(angles: [Double], radius: CGFloat, tint: Color) -> some View {
        ZStack {
            ForEach(angles, id: \.self) { angle in
                Circle()
                    .fill(tint.opacity(min(1, 0.9 * strength)))
                    .frame(width: 5, height: 5)
                    .shadow(color: tint.opacity(0.9), radius: 4)
                    .offset(x: radius * cos(angle * .pi / 180), y: radius * sin(angle * .pi / 180))
            }
        }
    }
}

/// Dark Glass: the one orb drawn in code instead of from a picture, built to the three examples
/// on the design canvas (Nebula, Aurora, Core): a dark face whose shade goes with the light, a
/// faint rim at its edge, the light over that at full strength and blended normally (never added
/// up to white), and a soft glow underneath. The canvas's blue ring is worn outside the face, the
/// same ring and ripples as the picture orbs (`OrbFace`). Sizes, colours and timings are the
/// canvas's, point for pixel, on a 190 pt face. The canvas drew it listening, in the accent blue;
/// thinking and speaking turn the whole palette by the hue between that blue and the phase colour,
/// and at rest the light is the accent's, dimmed.
private struct GlassOrb: View {
    let light: OrbLight
    let phase: VoiceSession.Phase
    let phaseColor: Color
    let accent: Color

    static let diameter: CGFloat = 190
    /// What sits outside the face matches the picture orbs, in proportion. Their disc is 46/48 of
    /// a 172 pt picture; their ring's outer edge is 7.6 pt beyond it, and the ripples start from a
    /// 198 pt circle.
    private static let pictureDisc: CGFloat = 172 * 46 / 48
    static let ringOutset: CGFloat = (172 + 8 - pictureDisc) / 2
    static let haloDiameter: CGFloat = diameter * 198 / pictureDisc
    /// The hue the canvas palette is built on (46, 139, 245).
    private static let baseHue: Double = 212

    private var face: Color {
        switch light {
        case .nebula: rgb(26, 34, 48)
        case .aurora: rgb(13, 20, 32)
        case .core: rgb(10, 15, 24)
        }
    }

    /// How far to turn the palette so its blue lands on `color`; none for a grey.
    private static func hueShift(to color: Color) -> Angle {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha), saturation > 0.08 else { return .zero }
        return .degrees(Double(hue) * 360 - baseHue)
    }

    var body: some View {
        let idle = phase == .idle
        let tint = idle ? accent : phaseColor
        Circle()
            .fill(face)
            // A faint rim to give the glass an edge, under the light. The canvas drew a blue
            // ring here; in the app that ring is the one outside the face, as on every orb.
            .overlay { Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1.5) }
            .overlay {
                Group {
                    switch light {
                    case .nebula: GlassNebula()
                    case .aurora: GlassAurora()
                    case .core: GlassCore()
                    }
                }
                .hueRotation(Self.hueShift(to: tint))
                .opacity(idle ? 0.55 : 1)
                .clipShape(Circle())
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .shadow(color: tint.opacity(0.25), radius: 30, y: 20)
            .animation(.easeOut(duration: 0.4), value: phase)
    }
}

private func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r / 255, green: g / 255, blue: b / 255) }

/// The canvas's Nebula: three patches (blue, pale blue, violet) each sliding and swelling between
/// two poses on its own period, the group turning once in 16 s with its hue swinging −18°…28°.
private struct GlassNebula: View {
    @State private var a = false
    @State private var b = false
    @State private var c = false
    @State private var hue = false
    @State private var turn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            patch(170, rgb(46, 139, 245), 0.85, 0.45)
                .scaleEffect(a ? 1.25 : 1)
                .offset(x: a ? 26 : -30, y: a ? 18 : -22)
            patch(140, rgb(150, 200, 255), 0.7, 0.35)
                .scaleEffect(b ? 0.85 : 1.15)
                .offset(x: 10 + (b ? -24 : 28), y: 10 + (b ? -26 : 14))
            patch(130, rgb(140, 90, 230), 0.75, 0.4)
                .scaleEffect(c ? 1.15 : 0.9)
                .offset(x: c ? -8 : 4, y: c ? -30 : 30)
        }
        .frame(width: GlassOrb.diameter, height: GlassOrb.diameter)
        .rotationEffect(.degrees(turn ? 360 : 0))
        .hueRotation(.degrees(hue ? 28 : -18))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { a = true }
            withAnimation(.easeInOut(duration: 1.95).repeatForever(autoreverses: true)) { b = true }
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) { c = true }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { hue = true }
            withAnimation(.linear(duration: 16).repeatForever(autoreverses: false)) { turn = true }
        }
    }

    /// A round patch: `near` at its centre, `mid` halfway out, gone at 70% of the way to its
    /// box's corner (which is just inside its own edge).
    private func patch(_ size: CGFloat, _ color: Color, _ near: Double, _ mid: Double) -> some View {
        Circle()
            .fill(RadialGradient(stops: [.init(color: color.opacity(near), location: 0),
                                         .init(color: color.opacity(mid), location: 0.5),
                                         .init(color: color.opacity(0), location: 0.7)],
                                 center: .center, startRadius: 0, endRadius: size / 2 * 2.0.squareRoot()))
            .frame(width: size, height: size)
    }
}

/// The canvas's Aurora: three blurred ribbons, tilted, sweeping from side to side on periods of
/// 4, 5.5 and 6 seconds.
private struct GlassAurora: View {
    @State private var a = false
    @State private var b = false
    @State private var c = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ribbon(60, [rgb(46, 139, 245).opacity(0), rgb(46, 139, 245).opacity(0.8), rgb(120, 220, 255).opacity(0.9), rgb(46, 139, 245).opacity(0)])
                .rotationEffect(.degrees(-12))
                .offset(x: a ? 60 : -60, y: -25)
            ribbon(50, [rgb(140, 90, 230).opacity(0), rgb(140, 90, 230).opacity(0.8), rgb(90, 165, 255).opacity(0.8), rgb(140, 90, 230).opacity(0)])
                .rotationEffect(.degrees(10))
                .offset(x: b ? -50 : 50, y: 25)
            ribbon(40, [rgb(60, 220, 190).opacity(0), rgb(60, 220, 190).opacity(0.7), rgb(46, 139, 245).opacity(0)])
                .rotationEffect(.degrees(-12))
                .offset(x: c ? 60 : -60, y: 65)
        }
        .frame(width: GlassOrb.diameter, height: GlassOrb.diameter)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) { a = true }
            withAnimation(.easeInOut(duration: 5.5).repeatForever(autoreverses: true)) { b = true }
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) { c = true }
        }
    }

    private func ribbon(_ height: CGFloat, _ colors: [Color]) -> some View {
        Capsule()
            .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
            .frame(width: 270, height: height)
            .blur(radius: 10)
    }
}

/// The canvas's Core: a nucleus pulsing every 2.4 s, three sparks orbiting one way in 7 s and
/// three the other in 11, each twinkling, and three motes rising through and fading.
private struct GlassCore: View {
    @State private var pulse = false
    @State private var orbit = false
    @State private var twinkle = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let pale = rgb(207, 230, 255), paleGlow = rgb(90, 165, 255)
    private static let lilac = rgb(224, 204, 255), lilacGlow = rgb(160, 124, 255)

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(stops: [.init(color: rgb(120, 200, 255).opacity(0.95), location: 0),
                                             .init(color: rgb(46, 139, 245).opacity(0.6), location: 0.4),
                                             .init(color: rgb(46, 139, 245).opacity(0), location: 0.7)],
                                     center: .center, startRadius: 0, endRadius: 60 * 2.0.squareRoot()))
                .frame(width: 120, height: 120)
                .scaleEffect(pulse ? 1.18 : 1)
                .opacity(pulse ? 1 : 0.9)
            ZStack {
                spark(5, Self.pale, Self.paleGlow, 4, x: 2.5, y: -74.5, delay: 0)
                spark(4, Self.pale, Self.paleGlow, 4, x: 67, y: 17, delay: 0.7)
                spark(6, Self.lilac, Self.lilacGlow, 5, x: -52, y: 58, delay: 1.3)
            }
            .rotationEffect(.degrees(orbit ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 7).repeatForever(autoreverses: false), value: orbit)
            ZStack {
                spark(4, Self.pale, Self.paleGlow, 4, x: -67, y: -23, delay: 0.4)
                spark(5, Self.lilac, Self.lilacGlow, 5, x: 57.5, y: -52.5, delay: 1)
                spark(4, Self.pale, Self.paleGlow, 4, x: 17, y: 72, delay: 1.6)
            }
            .rotationEffect(.degrees(orbit ? -360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 11).repeatForever(autoreverses: false), value: orbit)
            // The motes fade in and out partway through their climb, which needs the clock.
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    mote(8, rgb(120, 200, 255), x: -31, y: 51, delay: 0, t)
                    mote(6, rgb(160, 124, 255), x: 33, y: 52, delay: 1.4, t)
                    mote(5, rgb(120, 200, 255), x: -0.5, y: 52.5, delay: 2.5, t)
                }
            }
        }
        .frame(width: GlassOrb.diameter, height: GlassOrb.diameter)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
            orbit = true
            twinkle = true
        }
    }

    private func spark(_ size: CGFloat, _ color: Color, _ glow: Color, _ radius: CGFloat, x: CGFloat, y: CGFloat, delay: Double) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: glow, radius: radius)
            .opacity(twinkle ? 1 : 0.2)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1).repeatForever(autoreverses: true).delay(delay), value: twinkle)
            .offset(x: x, y: y)
    }

    /// One mote at time `t`: every 3.6 s it climbs 130 pt from 60 below its place, growing from
    /// 60% to full size, easing in; it fades up over the first fifth of the climb and out over
    /// the rest.
    private func mote(_ size: CGFloat, _ color: Color, x: CGFloat, y: CGFloat, delay: Double, _ t: TimeInterval) -> some View {
        let cycle = (t - delay).truncatingRemainder(dividingBy: 3.6)
        let p = (cycle < 0 ? cycle + 3.6 : cycle) / 3.6
        let eased = p * p
        let fadeIn = p / 0.2, fadeOut = (p - 0.2) / 0.8
        let opacity = p < 0.2 ? 0.9 * fadeIn * fadeIn : 0.9 * (1 - fadeOut * fadeOut)
        return Circle()
            .fill(color.opacity(0.8))
            .frame(width: size, height: size)
            .scaleEffect(0.6 + 0.4 * eased)
            .offset(x: x, y: y + 60 - 130 * eased)
            .opacity(reduceMotion ? 0 : opacity)
    }
}

/// A short bright arc running round the orb's rim while the model thinks.
private struct ThinkingArc: View {
    let color: Color
    @State private var spin = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.22)
            .stroke(AngularGradient(colors: [color.opacity(0), color, color.mix(with: .white, by: 0.5)],
                                    center: .center, startAngle: .degrees(0), endAngle: .degrees(80)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { spin = true }
            }
            .transition(.opacity)
            .accessibilityHidden(true)
    }
}

/// Rings widening out from the orb's edge and fading, one after another, while listening or
/// speaking; `subtle` is the resting version: one ring, slower, fainter, not as far.
private struct Halos: View {
    let color: Color
    var subtle = false
    /// The ring's size at rest: a little outside the orb's face.
    var diameter: CGFloat = 198
    @State private var expand = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var period: Double { subtle ? 4.5 : 2.6 }

    var body: some View {
        ZStack {
            ring(delay: 0)
            if !subtle { ring(delay: 1.3) }
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: period).repeatForever(autoreverses: false)) { expand = true }
        }
        .transition(.opacity)
        .accessibilityHidden(true)
    }

    private func ring(delay: Double) -> some View {
        Circle()
            .strokeBorder(color.opacity(expand ? 0 : (subtle ? 0.22 : 0.45)), lineWidth: subtle ? 1 : 1.5)
            .scaleEffect(expand ? (subtle ? 1.25 : 1.6) : 0.95)
            .animation(reduceMotion ? nil : .easeOut(duration: period).repeatForever(autoreverses: false).delay(delay), value: expand)
    }
}

/// What you're saying, word by word: each new word rises in while the rest hold still, which
/// `Text` alone can't do. Centred rows, wrapping, like the plain caption it replaces.
private struct RisingCaption: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let words = text.split(separator: " ").map(String.init)
        CenteredFlow(spacing: 6, lineSpacing: 2) {
            ForEach(words.indices, id: \.self) { i in
                Text(words[i])
                    .transition(reduceMotion ? .opacity : .offset(y: 8).combined(with: .opacity))
            }
        }
        .multilineTextAlignment(.center)
        .animation(.easeOut(duration: 0.25), value: words.count)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Lays subviews out in rows, each row centred, like centred text.
private struct CenteredFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var x: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let w = view.sizeThatFits(.unspecified).width
            if x > 0, x + w > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append(i)
            x += w + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let lines = rows(subviews, width: width)
        let height = lines.reduce(CGFloat(0)) { total, row in
            total + (row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0)
        } + CGFloat(max(0, lines.count - 1)) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let sizes = row.map { subviews[$0].sizeThatFits(.unspecified) }
            let rowWidth = sizes.reduce(CGFloat(0)) { $0 + $1.width } + CGFloat(max(0, row.count - 1)) * spacing
            let rowHeight = sizes.map(\.height).max() ?? 0
            var x = bounds.minX + (bounds.width - rowWidth) / 2
            for (j, i) in row.enumerated() {
                subviews[i].place(at: CGPoint(x: x, y: y + (rowHeight - sizes[j].height) / 2), proposal: .unspecified)
                x += sizes[j].width + spacing
            }
            y += rowHeight + lineSpacing
        }
    }
}

/// Waveform orb's bars, a KITT-style voice box: seven bars, all the same height with the
/// slightest wave running across them until your voice registers. Then they rise together with its level — one value drives
/// every bar, so the shape moves as a unit — the centre highest and each bar outward a step
/// lower, mirrored on both sides. While the reply is spoken they follow its voice the same way
/// (Kokoro's measured level, or a pulse per word from the built-in voice). Still under Reduce Motion.
private struct LiveWaveform: View {
    let phase: VoiceSession.Phase
    /// Read every frame: your voice (the mic meter) while listening, the reply's while speaking.
    let level: () -> Float
    var color = Color(red: 0.863, green: 0.890, blue: 0.933)
    /// A soft dark edge, for bars that sit over light added to a picture.
    var shadowed = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far each bar rises with sound: centre most, each step outward less, sides equal. The
    /// falloff is halfway to the spark's own profile — its arms curve in, so height drops as
    /// (1 − √(d/D))² away from the centre — giving a sharp centre peak with short outer bars.
    private static let weights: [CGFloat] = [0.13, 0.27, 0.51, 1.0, 0.51, 0.27, 0.13]
    /// Every bar's height at rest: a row of dashes, a flat line.
    private static let rest: CGFloat = 6
    private static let tallest: CGFloat = 88
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
        // At rest the timeline still ticks, slowly, for the ripple; off under Reduce Motion.
        TimelineView(.animation(minimumInterval: live ? 1 / 60 : 1 / 30, paused: reduceMotion)) { context in
            let l = live ? level() : 0
            let moving = phase == .speaking || l > Self.gate
            let drive = moving ? loudness(l) : nil
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5.5) {
                ForEach(Self.weights.indices, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .shadow(color: .black.opacity(shadowed ? 0.45 : 0), radius: 3, y: 1)
                        .frame(width: 10, height: height(i, drive) + (drive == nil && !reduceMotion ? ripple(i, t) : 0))
                }
            }
        }
        .frame(height: Self.tallest)
    }

    /// The resting wave: once every five seconds a single crest, 3 pt high, runs across the
    /// seven bars left to right in about a second; flat in between.
    private func ripple(_ i: Int, _ t: TimeInterval) -> CGFloat {
        let phase = t.truncatingRemainder(dividingBy: 5)
        let crest = 0.3 + Double(i) * 0.12          // when the crest reaches this bar
        let d = (phase - crest) / 0.16
        return 3 * CGFloat(exp(-d * d))
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
