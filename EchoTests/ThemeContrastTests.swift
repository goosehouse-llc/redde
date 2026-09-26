import SwiftUI
import Testing
import UIKit
@testable import Echo

/// Filled buttons draw the theme's accent with `userText` on it (send, Continue, Add key, the
/// question cards, selected chips). That pair must stay readable in every theme and appearance.
@MainActor
struct ThemeContrastTests {
    private func rgb(_ color: Color, _ style: UIUserInterfaceStyle) -> (Double, Double, Double) {
        let ui = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    /// WCAG relative luminance and contrast ratio.
    private func contrast(_ x: (Double, Double, Double), _ y: (Double, Double, Double)) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func lum(_ c: (Double, Double, Double)) -> Double { 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2) }
        let (a, b) = (lum(x), lum(y))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    @Test(arguments: Theme.allCases)
    func buttonTextIsReadableOnTheAccent(_ theme: Theme) {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let palette = theme.palette
            let ratio = contrast(rgb(palette.accent, style), rgb(palette.userText, style))
            // 3:1 is WCAG's minimum for large or bold text and UI controls, which button labels are.
            #expect(ratio >= 3, "\(theme.rawValue) \(style == .dark ? "dark" : "light"): \(String(format: "%.2f", ratio)):1")
        }
    }
}
