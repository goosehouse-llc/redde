import SwiftUI

/// The soft edge on a reply that is still arriving: its newest characters are drawn faint,
/// slightly low and, at the very end, blurred, coming up to full strength as more text lands
/// behind them, with a dot after the last one. So words breathe in rather than appear in blocks.
///
/// It is drawn, not animated. Each chunk of text already redraws the paragraph, and the edge
/// simply sits further along each time; nothing runs between chunks. A running animation here
/// would cost a frame's pass through the whole transcript sixty times a second for as long as
/// the reply streams (see "Rendering" in docs/ARCHITECTURE.md).
///
/// With one exception. When text stops arriving for a moment (the model has gone off to think
/// or to use a tool), the edge would leave the last word faint and blurred for as long as the
/// pause lasts, which can be minutes. So after a short quiet the edge comes up to full strength
/// (`settle`), over a quarter of a second, once; the dot stays, since the reply isn't over, and
/// the edge is back with the next chunk.
struct StreamingTail: TextRenderer {
    /// The dot after the last character.
    var dot: Color
    /// 0 while text is arriving; 1 once it has been quiet and every glyph is at full strength.
    var settle: Double = 0

    var animatableData: Double {
        get { settle }
        set { settle = newValue }
    }

    /// How many of the newest glyphs are still coming up, and how many of those are blurred.
    static let length = 18
    private static let blurred = 5

    /// How far a glyph has come up, 0 (just landed) to 1 (as the rest of the text): by how far
    /// it is from the end, and by how far the whole edge has settled.
    static func strength(fromEnd remaining: Int, settle: Double) -> Double {
        guard remaining < length else { return 1 }
        let arrived = Double(remaining + 1) / Double(length + 1)
        return arrived + (1 - arrived) * min(max(settle, 0), 1)
    }

    /// Room for the dot past the end of a full line.
    var displayPadding: EdgeInsets { EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 14) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // Glyphs still to draw, this one included: a glyph's distance from the end is that less one.
        var remaining = layout.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
        var last: CGRect?
        for line in layout {
            let count = line.reduce(0) { $0 + $1.count }
            // A line the edge hasn't reached, or any line once the edge has settled, is drawn
            // whole, as the system would.
            if remaining - count >= Self.length || settle >= 1 {
                context.draw(line)
                remaining -= count
                if let glyph = line.last?.last { last = glyph.typographicBounds.rect }
                continue
            }
            for run in line {
                for glyph in run {
                    remaining -= 1
                    last = glyph.typographicBounds.rect
                    let strength = Self.strength(fromEnd: remaining, settle: settle)
                    guard strength < 1 else { context.draw(glyph); continue }
                    var soft = context
                    soft.opacity = 0.12 + 0.88 * strength
                    soft.translateBy(x: 0, y: (1 - strength) * 3)
                    if remaining < Self.blurred { soft.addFilter(.blur(radius: (1 - strength) * 2)) }
                    soft.draw(glyph)
                }
            }
        }
        if let last {
            let size = 7.0
            context.fill(Path(ellipseIn: CGRect(x: last.maxX + 5, y: last.midY - size / 2, width: size, height: size)), with: .color(dot))
        }
    }
}

extension View {
    /// The streaming edge on the text of a reply's last block while it arrives; plain text
    /// otherwise, and under Reduce Motion. `revision` is anything that changes when the text
    /// does (its length): the edge settles once that has stood still for a moment.
    func streamingTail(_ active: Bool, dot: Color, revision: Int) -> some View {
        modifier(StreamingTailModifier(active: active, dot: dot, revision: revision))
    }
}

private struct StreamingTailModifier: ViewModifier {
    let active: Bool
    let dot: Color
    let revision: Int
    /// The text as it was when it had been quiet long enough to settle. New text is a new
    /// revision, so the edge is back with it and no state has to be reset.
    @State private var settledAt: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long without new text before the edge settles. Longer than the gap between the
    /// words of a slow model, so the edge doesn't come and go with each one.
    static let quiet: Duration = .milliseconds(700)

    func body(content: Content) -> some View {
        if active, !reduceMotion {
            content.textRenderer(StreamingTail(dot: dot, settle: settledAt == revision ? 1 : 0))
                .task(id: revision) {
                    try? await Task.sleep(for: Self.quiet)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.25)) { settledAt = revision }
                }
        } else {
            content
        }
    }
}

/// A dot with a ring widening off it: beside the agent's name while its reply is being made.
/// Scale and opacity only, which the render server animates without a pass through the views.
struct LiveMark: View {
    let color: Color
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(color, lineWidth: 1.5)
                .scaleEffect(pulse ? 1.9 : 0.6)
                .opacity(pulse ? 0 : 0.7)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .scaleEffect(pulse ? 1.15 : 0.9)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityHidden(true)
    }
}
