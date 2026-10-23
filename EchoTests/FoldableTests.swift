import Testing
import UIKit
@testable import Echo

/// An iPhone stays in portrait, as Redde always has, unless it folds: closed, an iPhone Duo can
/// stand on its side, and Apple asks for landscape on its outer screen (`Foldable`).
@MainActor
struct FoldableTests {
    @Test func portraitUnlessThePhoneFolds() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        let before = Foldable.hasHinge
        defer { Foldable.hasHinge = before }
        Foldable.hasHinge = false
        #expect(Foldable.orientations == .portrait)
        Foldable.hasHinge = true
        #expect(Foldable.orientations == .allButUpsideDown, "on its side, either way; not upside down")
    }
}
