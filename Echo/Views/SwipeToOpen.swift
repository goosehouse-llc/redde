import SwiftUI
import UIKit

/// A swipe to the right anywhere on the screen (iPhone: opens the conversation list). Only a
/// clearly sideways swipe counts, so the transcript still scrolls; and a code block or table that
/// can scroll back left gets the swipe instead.
struct SwipeRightGesture: UIGestureRecognizerRepresentable {
    var action: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        guard pan.state == .ended else { return }
        let distance = pan.translation(in: pan.view), speed = pan.velocity(in: pan.view)
        // Far enough, or a quick flick that's still heading right when the finger lifts.
        if distance.x > 90 || (distance.x > 40 && speed.x > 500) { action() }
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
