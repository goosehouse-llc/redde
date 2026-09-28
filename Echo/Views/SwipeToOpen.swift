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
                // Text being edited or selected: the drag moves the cursor or a selection handle.
                if let text = current as? UITextView, text.isFirstResponder || text.selectedRange.length > 0 { return false }
                if let field = current as? UITextField, field.isFirstResponder { return false }
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

/// iPhone: `content`, with `panel` sliding in from the left over it: from a swipe to the right,
/// which it follows, or from `isOpen`. The content moves over and dims; tap it or drag it back to
/// close. Its own view, so a swipe's every frame redraws only this, not the chat inside.
struct SidePanel<Content: View, Panel: View>: View {
    @Binding var isOpen: Bool
    /// A swipe started opening it (the chat's keyboard should go).
    var onOpening: () -> Void = {}
    @ViewBuilder var content: Content
    @ViewBuilder var panel: Panel
    @Environment(\.theme) private var theme
    /// How far out a finger has the panel, while one is on the screen.
    @State private var drag: CGFloat?
    /// Closed and finished sliding out: transparent, and its screens hide their navigation bars.
    @State private var parked = true
    /// Bumped on every open and close; a park scheduled for an older one is dropped.
    @State private var parkGeneration = 0
    /// Whether this swipe has gone far enough to count, and `onOpening` was called.
    @State private var opening = false

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width * 0.86, 400)
            let shown = drag ?? (isOpen ? width : 0)
            let progress = shown / width
            ZStack(alignment: .leading) {
                content
                    .offset(x: shown)
                    .accessibilityHidden(isOpen)
                // Its own layer, not inside the content: hidden with it, VoiceOver couldn't reach it.
                // Only while the panel is out: a full-screen layer, even a transparent one, stood
                // in front of the chat for accessibility (and UI tests' hit checks).
                if shown > 0 || isOpen {
                    Color.black.opacity(0.3 * progress)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { settle(open: false, from: shown, width: width, velocity: 0) }
                    .gesture(closeDrag(width: width))
                    .offset(x: shown)
                    .allowsHitTesting(isOpen || drag != nil)
                    .accessibilityLabel("Close conversations")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { settle(open: false, from: shown, width: width, velocity: 0) }
                    .accessibilityHidden(!isOpen)
                }
                // Built once and kept, so it slides in without first building a list.
                panel
                    // Parked, no width: nothing is laid out, so nothing is left for VoiceOver to
                    // find. UIKit's lists and bars inside ignore accessibilityHidden and opacity.
                    .frame(width: parked ? 0 : width)
                    .clipped()
                    .background(theme.background ?? Color(.systemBackground))
                    .overlay(alignment: .trailing) { Rectangle().fill(.separator).frame(width: 0.5).ignoresSafeArea() }
                    .offset(x: shown - width)
                    .opacity(parked ? 0 : 1)
                    .environment(\.sidePanelParked, parked)
                    .allowsHitTesting(isOpen)
                    .disabled(!isOpen && drag == nil)   // its keyboard shortcuts too
                    .accessibilityHidden(!isOpen)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape) { settle(open: false, from: shown, width: width, velocity: 0) }
            }
            .onChange(of: isOpen, initial: true) { _, open in
                if open { parkGeneration += 1; parked = false } else { parkWhenSettled() }
            }
            .gesture(SwipeRightGesture(
                isEnabled: !isOpen,
                onChanged: { distance in
                    if drag == nil { parkGeneration += 1; parked = false }
                    // Only a real swipe takes the chat's keyboard away, not a nudge.
                    if !opening, distance > 24 { opening = true; onOpening() }
                    drag = min(distance, width)
                },
                onEnded: { distance, velocity in
                    let open = distance > width * 0.35 || (distance > 30 && velocity > 500)
                    settle(open: open, from: min(max(distance, 0), width), width: width, velocity: velocity)
                }))
        }
    }

    /// Dragging the dimmed content to the left takes the panel back with it. Measured in screen
    /// space: the content moves with the finger, so its own coordinates shift under the drag and
    /// the panel shook.
    private func closeDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { drag = max(0, width + min(0, $0.translation.width)) }
            .onEnded { value in
                let moved = -value.translation.width, flung = -value.predictedEndTranslation.width
                let open = !(moved > width * 0.35 || flung > width * 0.5)
                settle(open: open, from: drag ?? width, width: width, velocity: value.velocity.width)
            }
    }

    /// Finishes the move at the finger's speed (points per second, rightward positive), so the
    /// panel carries on from the swipe instead of starting over.
    private func settle(open: Bool, from shown: CGFloat, width: CGFloat, velocity: CGFloat) {
        let remaining = (open ? width : 0) - shown
        let animation: Animation
        if abs(remaining) < 1 || velocity == 0 {
            animation = .sidePanel
        } else {
            // The spring's initial velocity is in units of the whole distance left per second.
            let relative = min(max(velocity / remaining, 0), 12)
            animation = .interpolatingSpring(duration: 0.34, bounce: 0, initialVelocity: relative)
        }
        opening = false
        withAnimation(animation) {
            isOpen = open
            drag = nil
        }
        // A swipe that didn't open it leaves isOpen false, so onChange never parks it.
        if !open { parkWhenSettled() }
    }

    /// Parks the panel once it has slid out, unless it opened (or was pulled) again meanwhile.
    /// The button and a picked conversation close it from outside, so there's no animation
    /// completion to wait on.
    private func parkWhenSettled() {
        parkGeneration += 1
        let generation = parkGeneration
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            if generation == parkGeneration, !isOpen, drag == nil { parked = true }
        }
    }
}

extension EnvironmentValues {
    /// The side panel around this view is closed and settled. Its screens hide their navigation
    /// bar then: UIKit's bar ignores accessibilityHidden, and VoiceOver would find it off screen.
    @Entry var sidePanelParked = false
}

extension Animation {
    /// The side panel opening and closing without a finger: quick, no bounce.
    static var sidePanel: Animation { .smooth(duration: 0.32) }
}
