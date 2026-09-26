import SwiftUI
import UIKit

/// A swipe to the right anywhere on the screen, reported as it moves (iPhone: pulls the
/// conversation list in from the left). Only a clearly sideways swipe counts, so the transcript
/// still scrolls; and a code block or table that can scroll back left gets the swipe instead.
struct SwipeRightGesture: UIGestureRecognizerRepresentable {
    var isEnabled = true
    /// How far right the finger has moved.
    var onChanged: (CGFloat) -> Void
    /// Final distance and horizontal speed; (0, 0) when the swipe was cancelled.
    var onEnded: (_ distance: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.isEnabled = isEnabled
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        pan.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .began, .changed:
            onChanged(max(0, pan.translation(in: pan.view).x))
        case .ended:
            onEnded(pan.translation(in: pan.view).x, pan.velocity(in: pan.view).x)
        case .cancelled, .failed:
            onEnded(0, 0)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
            let speed = pan.velocity(in: view)
            guard speed.x > 0, speed.x > abs(speed.y) * 2 else { return false }
            let point = pan.location(in: view)
            var hit = view.hitTest(point, with: nil)
            while let current = hit, current !== view {
                if let scroll = current as? UIScrollView,
                   scroll.contentSize.width > scroll.bounds.width + 1,
                   scroll.contentOffset.x > -scroll.adjustedContentInset.left + 1 {
                    return false
                }
                hit = current.superview
            }
            return true
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
