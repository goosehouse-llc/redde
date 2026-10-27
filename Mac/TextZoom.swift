import AppKit
import Observation
import os

/// View → Zoom In, Zoom Out, Actual Size (⌘=, ⌘−, ⌘0): the conversation's text on this Mac, as a
/// browser zooms a page. The iPhone's chat text size moves Dynamic Type, which a Mac doesn't
/// scale its text styles by, so here the theme's own fonts take the scale (`ResolvedTheme`):
/// replies, headings, tables, code, your messages, and the formulas drawn beside them. Kept on
/// this Mac, not synced: a desk and a phone want their own.
@MainActor
@Observable
final class TextZoom {
    static let shared = TextZoom()

    /// The steps, Actual Size at 0.
    nonisolated static let scales: [CGFloat] = [0.8, 0.9, 1, 1.1, 1.2, 1.35, 1.5, 1.75, 2]
    private static let actual = 2
    private static let key = "mac.textZoom"

    /// Where the zoom is, as an index into `scales`.
    private(set) var step: Int {
        didSet {
            UserDefaults.standard.set(step - Self.actual, forKey: Self.key)
            let scale = Self.scales[step]
            Self.current.withLock { $0 = scale }
        }
    }

    var scale: CGFloat { Self.scales[step] }
    var canZoomIn: Bool { step < Self.scales.count - 1 }
    var canZoomOut: Bool { step > 0 }
    var isActualSize: Bool { step == Self.actual }

    func zoomIn() { if canZoomIn { step += 1 } }
    func zoomOut() { if canZoomOut { step -= 1 } }
    func actualSize() { step = Self.actual }

    /// The scale, for the fonts, which are worked out off the main actor too.
    nonisolated static let current = OSAllocatedUnfairLock<CGFloat>(initialState: 1)

    private init() {
        let saved = UserDefaults.standard.integer(forKey: Self.key)
        step = min(max(Self.actual + saved, 0), Self.scales.count - 1)
        let scale = Self.scales[step]
        Self.current.withLock { $0 = scale }
    }

    /// A text style's size on this Mac, at Actual Size.
    nonisolated static func points(_ style: NSFont.TextStyle) -> CGFloat {
        NSFont.preferredFont(forTextStyle: style).pointSize
    }
}
