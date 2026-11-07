import SwiftUI

/// Swipe left in a chat to see when each message came (asked 2026-11-06: "Allow for a swipe left
/// to see the time on messages"), as Messages does: the rows slide left, each one's time shows
/// past its end, and they slide back when the finger lifts. Only the times redraw as the rows
/// slide (`MessageTime` reads `TimeReveal`), not the rows. On the iPhone and iPad; the Mac has no
/// swipe to give it.
@MainActor @Observable final class TimeReveal {
    /// How far the rows have slid, 0 to `width` + `SwipeForTimes.stretch`.
    var offset: CGFloat = 0
    /// The room the times take.
    static let width: CGFloat = 72

    init() {
        #if DEBUG
        // `-echo.showTimes`: the times out, as mid-swipe, for a screenshot.
        if DevHooks.has("-echo.showTimes") { offset = Self.width }
        #endif
    }
}

extension View {
    /// The rows of a chat: slid left by a sideways swipe to show their times.
    func swipeForTimes() -> some View { modifier(SwipeForTimes()) }
}

private struct SwipeForTimes: ViewModifier {
    @State private var reveal = TimeReveal()

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .environment(reveal)
            .offset(x: -reveal.offset)
            .gesture(SidewaysPan(reveal: reveal))
        #else
        content
        #endif
    }

    /// Follows the finger to the times' width, then gives only a little, and never more than
    /// `stretch` past it (11-07: the rows could slide 220 points, most of the screen).
    static func pulled(_ distance: CGFloat) -> CGFloat {
        let d = max(0, distance)
        return min(d, TimeReveal.width) + min(stretch, max(0, d - TimeReveal.width) * 0.15)
    }

    static let stretch: CGFloat = 24
}

#if os(iOS)
/// A pan that starts only for a swipe to the left, so a scroll stays the scroll view's: a
/// SwiftUI drag on the rows (tried first) held up the transcript's own scrolling.
private struct SidewaysPan: UIGestureRecognizerRepresentable {
    let reveal: TimeReveal

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .began, .changed:
            // Measured in the window: the view the pan sits on can be one that slides with
            // the rows, which counted the slide itself as more swipe.
            reveal.offset = SwipeForTimes.pulled(-pan.translation(in: nil).x)
        default:
            guard reveal.offset > 0 else { return }
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) { reveal.offset = 0 }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Leftward, and clearly more sideways than up or down.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            return v.x < 0 && abs(v.x) > abs(v.y) * 1.6
        }

        /// Alongside anything else (a scroll view's pan never starts for a sideways swipe on a
        /// chat that only scrolls up and down; a code block's own sideways scroll keeps going).
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
#endif

/// A message's time, just past its row's end, seen as the rows slide left.
struct MessageTime: View {
    let date: Date
    @Environment(TimeReveal.self) private var reveal: TimeReveal?

    var body: some View {
        if let reveal, reveal.offset > 0 {
            Text(date, format: .dateTime.hour().minute())
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(width: TimeReveal.width - 8, alignment: .trailing)
                .offset(x: TimeReveal.width)
                .opacity(min(1, reveal.offset / (TimeReveal.width * 0.7)))
                .padding(.top, 6)
                .accessibilityHidden(true)
        }
    }
}
