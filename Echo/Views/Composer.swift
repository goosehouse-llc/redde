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
struct WaveformPulse: View {
    var color: Color
    var barCount = 5
    var height: CGFloat = 20
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 4) {
                ForEach(0 ..< barCount, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 4, height: barHeight(index: i, time: t))
                }
            }
            .frame(height: height)
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        // Resting shape mirrors the icon (tall middle), then each bar breathes with its own phase.
        let rest: [CGFloat] = [0.45, 0.75, 1.0, 0.75, 0.45]
        let base = rest[index % rest.count]
        guard !reduceMotion else { return height * base }
        let phase = Double(index) * 0.9
        let wobble = 0.5 + 0.5 * sin(time * 5.0 + phase)   // 0…1
        let scaled = base * (0.35 + 0.65 * wobble)
        return max(4, height * CGFloat(scaled))
    }
}
