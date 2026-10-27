import SwiftUI

/// Round glass button sized exactly to the composer's single-line text field.
struct ComposerButton: View {
    let symbol: String
    let label: String
    let tint: Color
    let size: CGFloat
    /// The app's own waveform in its resting shape, still, instead of a symbol (the Talk button).
    var waveform = false
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Group {
                if waveform {
                    WaveformPulse(color: theme.userText, height: size * 0.56, spacing: 2.5, shape: [0.38, 0.66, 1.0, 0.66, 0.38], still: true)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(theme.userText)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(tint).interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

/// The microphone in both composers (a chat's and a group chat's): the draft is written as it
/// is heard, nothing sent.
struct DictateButton: View {
    let dictation: Dictation
    let toggle: () -> Void

    var body: some View {
        Button(dictation.isActive ? String(localized: "Stop dictating") : String(localized: "Dictate"),
               systemImage: dictation.isActive ? "waveform" : "mic", action: toggle)
            .labelStyle(.iconOnly)
            .font(.body.weight(.medium))
            .symbolEffect(.variableColor.iterative, isActive: dictation.phase == .listening)
            .foregroundStyle(dictation.isActive ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .frame(width: 34, height: 38)
            .contentShape(.rect)
            .buttonStyle(.plain)
            .accessibilityHint(dictation.isActive ? String(localized: "Ends dictation; what was said stays in the message")
                                                  : String(localized: "Speak your message; it is written here, not sent"))
    }
}

extension View {
    /// A composer's draft following `dictation`: what it hears goes after `base` (the draft as it
    /// was when it began), a problem goes to `problem`, and it stops when the composer goes.
    func dictating(_ dictation: Dictation, base: Binding<String?>, draft: Binding<String>, problem: Binding<String?>) -> some View {
        onChange(of: dictation.heard) { _, heard in
            if let start = base.wrappedValue { draft.wrappedValue = Dictation.joined(start, heard) }
        }
        .onChange(of: dictation.phase) { _, phase in
            guard phase == .idle, let start = base.wrappedValue else { return }
            draft.wrappedValue = Dictation.joined(start, dictation.heard)
            base.wrappedValue = nil
        }
        .onChange(of: dictation.problem) { _, new in
            if let new { problem.wrappedValue = new }
        }
        .onDisappear {
            base.wrappedValue = nil
            dictation.cancel()
        }
        .sensoryFeedback(.selection, trigger: dictation.isActive)
    }
}

/// Five bars rising and falling out of phase, like the icon come to life. Sits still under
/// Reduce Motion.
///
/// Core Animation runs it, in the render server. As a SwiftUI animation it redrew thirty times a
/// second, and every one of those frames walks the whole transcript's view tree: in a long
/// conversation, waiting for a reply cost a third of a core. This costs nothing per frame.
struct WaveformPulse: View {
    var color: Color
    var barCount = 5
    var height: CGFloat = 20
    /// Gap between the bars.
    var spacing: CGFloat = 4
    /// Each bar's resting height as a share of `height`; the icon's shape by default.
    var shape = WaveformBarsView.iconShape
    /// Hold the resting shape; also what Reduce Motion gets.
    var still = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Bars(color: PlatformColor(color), barCount: barCount, height: height, spacing: spacing, shape: shape, still: still || reduceMotion)
            .frame(width: WaveformBarsView.width(barCount: barCount, spacing: spacing), height: height)
    }

    #if os(iOS)
    private struct Bars: UIViewRepresentable {
        var color: UIColor
        var barCount: Int
        var height: CGFloat
        var spacing: CGFloat
        var shape: [CGFloat]
        var still: Bool

        func makeUIView(context: Context) -> WaveformBarsView { WaveformBarsView() }

        func updateUIView(_ view: WaveformBarsView, context: Context) {
            view.configure(color: color, barCount: barCount, height: height, spacing: spacing, shape: shape, still: still)
        }
    }
    #else
    private struct Bars: NSViewRepresentable {
        var color: NSColor
        var barCount: Int
        var height: CGFloat
        var spacing: CGFloat
        var shape: [CGFloat]
        var still: Bool

        func makeNSView(context: Context) -> WaveformBarsView { WaveformBarsView() }

        func updateNSView(_ view: WaveformBarsView, context: Context) {
            view.configure(color: color, barCount: barCount, height: height, spacing: spacing, shape: shape, still: still)
        }
    }
    #endif
}

#if os(iOS)
final class WaveformBarsView: UIView {
    private static let barWidth: CGFloat = 4
    /// Resting shape mirrors the icon (tall middle); each bar breathes down to 35% of it.
    static let iconShape: [CGFloat] = [0.45, 0.75, 1.0, 0.75, 0.45]
    private static let animationKey = "breathe"

    static func width(barCount: Int, spacing: CGFloat) -> CGFloat { max(0, CGFloat(barCount) * (barWidth + spacing) - spacing) }

    private var bars: [CALayer] = []
    private var color = UIColor.tintColor
    private var barHeight: CGFloat = 20
    private var spacing: CGFloat = 4
    private var rest = WaveformBarsView.iconShape
    private var still = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: WaveformBarsView, _: UITraitCollection) in view.applyColor() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    func configure(color: UIColor, barCount: Int, height: CGFloat, spacing: CGFloat, shape: [CGFloat], still: Bool) {
        let changed = barCount != bars.count || height != barHeight || spacing != self.spacing || shape != rest || still != self.still
        self.color = color
        barHeight = height
        self.spacing = spacing
        rest = shape.isEmpty ? Self.iconShape : shape
        self.still = still
        if barCount != bars.count {
            bars.forEach { $0.removeFromSuperlayer() }
            bars = (0 ..< barCount).map { _ in
                let bar = CALayer()
                bar.cornerRadius = Self.barWidth / 2
                layer.addSublayer(bar)
                return bar
            }
        }
        applyColor()
        if changed { setNeedsLayout() }
    }

    private func applyColor() {
        let resolved = color.resolvedColor(with: traitCollection).cgColor
        bars.forEach { $0.backgroundColor = resolved }
    }

    private func restHeight(_ index: Int) -> CGFloat { barHeight * rest[index % rest.count] }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: restHeight(i))
            bar.position = CGPoint(x: CGFloat(i) * (Self.barWidth + spacing) + Self.barWidth / 2, y: bounds.midY)
        }
        CATransaction.commit()
        animate()
    }

    /// Core Animation drops running animations when the view leaves its window and when the app
    /// goes to the background; start them again on the way back.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        guard window != nil else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(animate), name: UIApplication.willEnterForegroundNotification, object: nil)
        animate()
    }

    @objc private func animate() {
        for (i, bar) in bars.enumerated() {
            bar.removeAnimation(forKey: Self.animationKey)
            guard !still, window != nil else { continue }
            // The same motion as before: height = rest × (0.35 + 0.65 × (½ + ½ sin(5t + 0.9i))),
            // never under 4 pt. Easing in and out between the two ends is that sine.
            let breathe = CABasicAnimation(keyPath: "bounds.size.height")
            breathe.fromValue = max(4, restHeight(i) * 0.35)
            breathe.toValue = max(4, restHeight(i))
            breathe.duration = .pi / 5
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breathe.beginTime = bar.convertTime(CACurrentMediaTime(), from: nil) - Double(i) * 0.18
            bar.add(breathe, forKey: Self.animationKey)
        }
    }
}
#else
/// The same bars on the Mac: layers in a layer-backed view, Core Animation running them.
final class WaveformBarsView: NSView {
    private static let barWidth: CGFloat = 4
    /// Resting shape mirrors the icon (tall middle); each bar breathes down to 35% of it.
    static let iconShape: [CGFloat] = [0.45, 0.75, 1.0, 0.75, 0.45]
    private static let animationKey = "breathe"

    static func width(barCount: Int, spacing: CGFloat) -> CGFloat { max(0, CGFloat(barCount) * (barWidth + spacing) - spacing) }

    private var bars: [CALayer] = []
    private var color = NSColor.controlAccentColor
    private var barHeight: CGFloat = 20
    private var spacing: CGFloat = 4
    private var rest = WaveformBarsView.iconShape
    private var still = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(color: NSColor, barCount: Int, height: CGFloat, spacing: CGFloat, shape: [CGFloat], still: Bool) {
        let changed = barCount != bars.count || height != barHeight || spacing != self.spacing || shape != rest || still != self.still
        self.color = color
        barHeight = height
        self.spacing = spacing
        rest = shape.isEmpty ? Self.iconShape : shape
        self.still = still
        if barCount != bars.count {
            bars.forEach { $0.removeFromSuperlayer() }
            bars = (0 ..< barCount).map { _ in
                let bar = CALayer()
                bar.cornerRadius = Self.barWidth / 2
                layer?.addSublayer(bar)
                return bar
            }
        }
        applyColor()
        if changed { needsLayout = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func applyColor() {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        bars.forEach { $0.backgroundColor = resolved }
    }

    private func restHeight(_ index: Int) -> CGFloat { barHeight * rest[index % rest.count] }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: restHeight(i))
            bar.position = CGPoint(x: CGFloat(i) * (Self.barWidth + spacing) + Self.barWidth / 2, y: bounds.midY)
        }
        CATransaction.commit()
        animate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animate()
    }

    private func animate() {
        for (i, bar) in bars.enumerated() {
            bar.removeAnimation(forKey: Self.animationKey)
            guard !still, window != nil else { continue }
            let breathe = CABasicAnimation(keyPath: "bounds.size.height")
            breathe.fromValue = max(4, restHeight(i) * 0.35)
            breathe.toValue = max(4, restHeight(i))
            breathe.duration = .pi / 5
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breathe.beginTime = bar.convertTime(CACurrentMediaTime(), from: nil) - Double(i) * 0.18
            bar.add(breathe, forKey: Self.animationKey)
        }
    }
}
#endif

/// Settings → Return key, for a message field: with Return set to send, Return sends and a
/// keyboard's Shift-Return is the line break; otherwise Return is a line break and ⌘Return sends.
/// Both composers have it: a conversation's, and a group chat's.
struct ReturnSends: ViewModifier {
    @Binding var draft: String
    /// Whether there is something to send (asked after the line break comes out again).
    let canSend: () -> Bool
    let send: () -> Void
    @State private var settings = Settings.shared
    /// Shift-Return on a keyboard while Return is set to send: this one line break is meant.
    @State private var lineBreakMeant = false

    func body(content: Content) -> some View {
        content
            .submitLabel(settings.returnSends ? .send : .return)
            // A keyboard's Return, with Return set to send: sends, and Shift-Return is the line break.
            .onKeyPress(.return, phases: .down) { press in
                guard settings.returnSends else { return .ignored }
                if press.modifiers.contains(.shift) {
                    lineBreakMeant = true
                    return .ignored
                }
                if canSend() { send() }
                return .handled
            }
            // The on-screen keyboard's Return types a line break the field keeps: it comes out
            // again and the message goes.
            .onChange(of: draft) { old, new in
                guard settings.returnSends, Self.isReturn(from: old, to: new) else { return }
                if lineBreakMeant {
                    lineBreakMeant = false
                    return
                }
                draft = old
                if canSend() { send() }
            }
    }

    /// A draft that grew by exactly one line break: Return was pressed. (A paste or a deletion
    /// changes it some other way.)
    nonisolated static func isReturn(from old: String, to new: String) -> Bool {
        guard new.utf16.count == old.utf16.count + 1 else { return false }
        let shared = new.commonPrefix(with: old)
        let rest = new.dropFirst(shared.count)
        return rest.first == "\n" && rest.dropFirst() == old.dropFirst(shared.count)
    }
}
