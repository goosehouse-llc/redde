import SwiftUI

/// Round glass button sized exactly to the composer's single-line text field.
struct ComposerButton: View {
    let symbol: String
    let label: String
    let tint: Color
    let size: CGFloat
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(theme.userText)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(tint).interactive(), in: .circle)
        .accessibilityLabel(label)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Bars(color: UIColor(color), barCount: barCount, height: height, still: reduceMotion)
            .frame(width: WaveformBarsView.width(barCount: barCount), height: height)
    }

    private struct Bars: UIViewRepresentable {
        var color: UIColor
        var barCount: Int
        var height: CGFloat
        var still: Bool

        func makeUIView(context: Context) -> WaveformBarsView { WaveformBarsView() }

        func updateUIView(_ view: WaveformBarsView, context: Context) {
            view.configure(color: color, barCount: barCount, height: height, still: still)
        }
    }
}

final class WaveformBarsView: UIView {
    private static let barWidth: CGFloat = 4
    private static let spacing: CGFloat = 4
    /// Resting shape mirrors the icon (tall middle); each bar breathes down to 35% of it.
    private static let rest: [CGFloat] = [0.45, 0.75, 1.0, 0.75, 0.45]
    private static let animationKey = "breathe"

    static func width(barCount: Int) -> CGFloat { max(0, CGFloat(barCount) * (barWidth + spacing) - spacing) }

    private var bars: [CALayer] = []
    private var color = UIColor.tintColor
    private var barHeight: CGFloat = 20
    private var still = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: WaveformBarsView, _: UITraitCollection) in view.applyColor() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    func configure(color: UIColor, barCount: Int, height: CGFloat, still: Bool) {
        let changed = barCount != bars.count || height != barHeight || still != self.still
        self.color = color
        barHeight = height
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

    private func restHeight(_ index: Int) -> CGFloat { barHeight * Self.rest[index % Self.rest.count] }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: restHeight(i))
            bar.position = CGPoint(x: CGFloat(i) * (Self.barWidth + Self.spacing) + Self.barWidth / 2, y: bounds.midY)
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
