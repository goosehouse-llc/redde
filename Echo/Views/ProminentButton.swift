import SwiftUI

/// A filled button whose words read on its fill (asked 2026-11-21: "Contrast in the unblock
/// bubbles hard to read"). `.borderedProminent` writes white on any tint, and a theme with a pale
/// accent (a light blue, a lime) left its buttons white on pale. On the theme's accent the label
/// takes the theme's text for it (`userText`, the glyph on Send); on a tint of its own (red, for
/// something that can't be undone), white.
struct ProminentButton: ViewModifier {
    let tint: Color?
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        if let tint {
            content.buttonStyle(.borderedProminent).tint(tint).foregroundStyle(.white)
        } else {
            // Fill and words from one theme, so they always go together.
            content.buttonStyle(.borderedProminent).tint(theme.accent).foregroundStyle(theme.userText)
        }
    }
}

extension View {
    /// `.borderedProminent`, its label readable on its fill (`ProminentButton`).
    func prominentButton(tint: Color? = nil) -> some View { modifier(ProminentButton(tint: tint)) }
}
