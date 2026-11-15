#if DEBUG && os(iOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// `-echo.showTouches`: a ring wherever the screen is touched, drawn in the app so a screen
/// recording shows what was tapped and held (the agents video, design/video/make_agents.py; the
/// Simulator's own touch dots aren't in a recording). A ring shows while the finger is down and
/// fades as it lifts. Every window gets a watcher (menus open in windows of their own), which
/// never takes a touch from the app.
@MainActor
enum DemoTouches {
    private static var watching: NSObjectProtocol?

    static func install() {
        guard DevHooks.has("-echo.showTouches"), watching == nil else { return }
        watching = NotificationCenter.default.addObserver(forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main) { note in
            let window = note.object as? UIWindow
            MainActor.assumeIsolated { attach(window) }
        }
        Task {
            // The scene's windows, once they're up.
            for _ in 0 ..< 10 {
                for scene in UIApplication.shared.connectedScenes {
                    for window in (scene as? UIWindowScene)?.windows ?? [] { attach(window) }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func attach(_ window: UIWindow?) {
        guard let window, window.gestureRecognizers?.contains(where: { $0 is Watcher }) != true else { return }
        window.addGestureRecognizer(Watcher())
    }

    /// Sees every touch in its window and draws its ring, and never recognizes anything.
    private final class Watcher: UIGestureRecognizer {
        private var rings: [ObjectIdentifier: CAShapeLayer] = [:]

        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let window = view as? UIWindow else { return }
            for touch in touches {
                let ring = CAShapeLayer()
                let size: CGFloat = 46
                ring.bounds = CGRect(x: 0, y: 0, width: size, height: size)
                ring.path = UIBezierPath(ovalIn: ring.bounds.insetBy(dx: 2, dy: 2)).cgPath
                ring.fillColor = UIColor.white.withAlphaComponent(0.35).cgColor
                ring.strokeColor = UIColor.white.withAlphaComponent(0.95).cgColor
                ring.lineWidth = 3
                ring.shadowColor = UIColor.black.cgColor
                ring.shadowOpacity = 0.45
                ring.shadowRadius = 4
                ring.shadowOffset = .zero
                ring.zPosition = 100_000
                ring.position = touch.location(in: window)
                window.layer.addSublayer(ring)
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = 0.5
                grow.toValue = 1
                grow.duration = 0.12
                ring.add(grow, forKey: "grow")
                rings[ObjectIdentifier(touch)] = ring
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let window = view as? UIWindow else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for touch in touches { rings[ObjectIdentifier(touch)]?.position = touch.location(in: window) }
            CATransaction.commit()
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }

        private func lift(_ touches: Set<UITouch>) {
            for touch in touches {
                guard let ring = rings.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
                CATransaction.begin()
                CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = 1
                grow.toValue = 1.7
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                let both = CAAnimationGroup()
                both.animations = [grow, fade]
                both.duration = 0.45
                both.fillMode = .forwards
                both.isRemovedOnCompletion = false
                ring.add(both, forKey: "lift")
                CATransaction.commit()
            }
            if rings.isEmpty { state = .failed }
        }
    }
}
#endif
