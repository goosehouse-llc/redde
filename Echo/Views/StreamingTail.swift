import SwiftUI

/// The soft edge on a reply that is still arriving: its newest characters are drawn faint,
/// slightly low and, at the very end, blurred, coming up to full strength as more text lands
/// behind them, with a dot after the last one. So words breathe in rather than appear in blocks.
///
/// It is drawn, not animated. Each chunk of text already redraws the paragraph, and the edge
/// simply sits further along each time; nothing runs between chunks. A running animation here
/// would cost a frame's pass through the whole transcript sixty times a second for as long as
/// the reply streams (see "Rendering" in docs/ARCHITECTURE.md).
struct StreamingTail: TextRenderer {
    /// The dot after the last character.
    var dot: Color

    /// How many of the newest glyphs are still coming up, and how many of those are blurred.
    private static let length = 18
    private static let blurred = 5

    /// Room for the dot past the end of a full line.
    var displayPadding: EdgeInsets { EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 14) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // Glyphs still to draw, this one included: a glyph's distance from the end is that less one.
        var remaining = layout.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
        var last: CGRect?
        for line in layout {
            let count = line.reduce(0) { $0 + $1.count }
            // A line the edge hasn't reached is drawn whole, as the system would.
            if remaining - count >= Self.length {
                context.draw(line)
                remaining -= count
                continue
            }
            for run in line {
                for glyph in run {
                    remaining -= 1
                    last = glyph.typographicBounds.rect
                    guard remaining < Self.length else { context.draw(glyph); continue }
                    let settled = Double(remaining + 1) / Double(Self.length + 1)   // 0 newest … 1 settled
                    var soft = context
                    soft.opacity = 0.12 + 0.88 * settled
                    soft.translateBy(x: 0, y: (1 - settled) * 3)
                    if remaining < Self.blurred { soft.addFilter(.blur(radius: (1 - settled) * 2)) }
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
    /// otherwise, and under Reduce Motion.
    func streamingTail(_ active: Bool, dot: Color) -> some View {
        modifier(StreamingTailModifier(active: active, dot: dot))
    }
}

private struct StreamingTailModifier: ViewModifier {
    let active: Bool
    let dot: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active, !reduceMotion {
            content.textRenderer(StreamingTail(dot: dot))
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
