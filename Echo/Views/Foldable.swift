import SwiftUI

/// Whether Redde runs on a foldable (an iPhone Duo): the device has a hinge, as iOS 27.1 says
/// (`onHingeChange`). There is no other way to tell a Duo from an iPhone, and on any other
/// phone, or before iOS 27.1, there is none.
///
/// It decides the iPhone's orientations: portrait, as Redde has always been, unless the device
/// folds. Closed, a Duo can stand on its side like a tent, and Apple asks for landscape on its
/// outer screen for that (asked for here 2026-10-23). Its inner screen turns whatever an app
/// says. An iPad turns every way, as before.
@MainActor enum Foldable {
    static var hasHinge = false {
        didSet {
            guard hasHinge != oldValue else { return }
            // Asked again of every window, so the new answer counts at once.
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for window in scene.windows { window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
            }
        }
    }

    static var orientations: UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        return hasHinge ? .allButUpsideDown : .portrait
    }
}

/// Listens for the hinge, from the app's root (`Foldable`).
struct HingeWatch: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, now in Foldable.hasHinge = now.hinge != nil }
        } else {
            content
        }
    }
}
