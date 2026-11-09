import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Visual themes. Each theme is one `Palette` value — every colour, font and shape decision
/// in one place — with light and dark variants inside the colours themselves; Settings →
/// Appearance chooses light, dark or system for whichever theme is active.
nonisolated enum Theme: String, CaseIterable, Identifiable, Codable {
    // Declaration order is the Settings list order.
    case githubDark, standard, paper, paperWhite, slate, terminal, amber, claudeCode

    var id: String { rawValue }

    /// Everything a theme decides. Optional fields derive from `accent` (noted on each), so a
    /// palette only states where it diverges from the plain accent-tinted look.
    struct Palette: Equatable, Sendable {
        var label: String
        var blurb: String
        var accent: Color
        /// Page ground. nil = system background.
        var background: Color?
        /// Slightly lifted surface for assistant bubbles, sheets' rows, etc. nil = system secondary.
        var surface: Color?
        /// Your own bubble. nil = the accent.
        var userBubble: Color?
        /// Text on your own bubble, and the glyph on accent circles (send, mic).
        var userText: Color = .white
        /// Replies sit straight on the page with no bubble, under the agent's name. Every
        /// shipped theme does this now; the flag stays so a palette can box its replies again.
        var flatReplies = false
        /// Body text override. nil = system primary.
        var text: Color?
        // Semantic markdown colors ("IDE Cool") — hues per element the way an editor theme
        // colors token kinds. nil = derived from the accent.
        var linkColor: Color?                 // nil → accent
        var checkboxColor: Color?             // nil → accent
        var quoteBarColor: Color?             // nil → accent.opacity(0.6)
        var tableHeaderTint: Color?           // nil → accent.opacity(0.10)
        /// Shell-style input: your messages render as `❯ text` instead of a bubble.
        var promptPrefix: String?
        /// The whole prompt row — prefix and your words. nil → accent.
        var promptColor: Color?
        /// Typeface family for reply text (paragraphs, lists).
        var replyDesign: Font.Design = .default
        /// Headings in replies. The CRTs keep SF Mono (a terminal has one face); Code its serif.
        var headingDesign: Font.Design = .default
        /// Table cells in SF Mono (the CRTs); everything else keeps the sans.
        var monoTables = false
        /// Bundled monospace face for reply/table/code text (PostScript name);
        /// nil = the system face for `replyDesign`. Weight is baked into the face.
        var monoFontName: String?
        /// Bundled proportional face for reply/heading/table/user text; code blocks
        /// keep the mono. nil = the system face for `replyDesign`.
        var bodyFontName: String?
        /// Your own messages in the system sans against styled replies (Code).
        var sansUserFont = false
        /// Code-block syntax hues per appearance.
        var syntaxDark: SyntaxHighlighter.Palette = .dark
        var syntaxLight: SyntaxHighlighter.Palette = .light
        var usesGlass = false
        /// Terminal-flavoured themes use tighter bubble corners.
        var bubbleRadius: CGFloat = 18
        /// Monospaced lines carry generous leading, so those bubbles sit tighter.
        var bubbleVerticalPadding: CGFloat = 10
        /// Text on your bubble when it isn't the glyph colour (`userText`): a palette with a pale
        /// bubble of its own (Paper White), or your recolored bubble (set by `resolved(with:)`).
        var userBubbleTextColor: Color? = nil
        /// The Send and Talk circles beside the message field, and their glyph. nil → the accent and
        /// `userText`. Paper White keeps its accent an ink you can read links in, and its circles pale.
        var actionTint: Color? = nil
        var actionGlyph: Color? = nil
        /// Settings → Appearance → Font picked a face: replies and your messages take `bodyFontName`
        /// (or the system face for `replyDesign`), never the theme's mono. Set by `resolved`.
        var pickedFont = false
        /// Light or dark, fixed by a wallpaper the reader picked, so that the text on it, and the
        /// system's own greys, read on it whatever Settings → Appearance says. Set by
        /// `resolved(with:)`, never by a palette.
        var scheme: ColorScheme? = nil
    }

    /// A colour with one value in light mode and another in dark.
    private static func dyn(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
    }

    var palette: Palette {
        switch self {
        case .standard: Self.standardPalette
        case .paper: Self.paperPalette
        case .paperWhite: Self.paperWhitePalette
        case .slate: Self.slatePalette
        case .terminal: Self.terminalPalette
        case .amber: Self.amberPalette
        case .githubDark: Self.githubDarkPalette
        case .claudeCode: Self.claudeCodePalette
        }
    }

    private static let standardPalette = Palette(
        label: String(localized: "Messages", comment: "Name of a color theme in Settings → Appearance"),
        blurb: String(localized: "Redde blue on the system greys."),
        accent: Color(red: 0.180, green: 0.545, blue: 0.961),
        background: nil, surface: nil, userBubble: nil, flatReplies: true, text: nil,
        usesGlass: true)

    /// Real paper (redone 2026-11-02, given its own look 11-03 when four themes looked alike):
    /// parchment, sepia ink and a burnt-sienna pen, flat serif replies; after dark a lamp-lit
    /// study: a brown page, cream ink and an ochre accent, warmer and lighter than near-black.
    private static let paperPalette = Palette(
        label: String(localized: "Paper", comment: "Name of a color theme in Settings → Appearance, and a bot face's shape: a sheet of paper"),
        blurb: String(localized: "Parchment, sepia ink and a burnt-sienna pen; a lamp-lit study after dark."),
        accent: dyn((0.541, 0.231, 0.071), (0.878, 0.643, 0.345)),          // burnt sienna / ochre
        background: dyn((0.945, 0.902, 0.808), (0.165, 0.129, 0.094)),     // parchment / lamp-lit brown
        surface: dyn((0.906, 0.851, 0.737), (0.216, 0.169, 0.122)),
        userBubble: nil,
        userText: dyn((0.984, 0.957, 0.902), (0.165, 0.129, 0.094)),       // on the pen colour
        flatReplies: true,
        text: dyn((0.200, 0.157, 0.110), (0.937, 0.890, 0.800)),           // sepia / cream
        quoteBarColor: dyn((0.545, 0.427, 0.290), (0.698, 0.600, 0.373)).opacity(0.7),   // sepia rule
        tableHeaderTint: dyn((0.545, 0.427, 0.290), (0.698, 0.600, 0.373)).opacity(0.16),
        replyDesign: .serif, headingDesign: .serif)

    /// An e-reader's page, from a screenshot of Nous's Hermes Mobile he sent 2026-11-02: a warm
    /// off-white page everywhere, replies in a soft grey bubble, yours pale blue-grey, all in
    /// Georgia, and pale blue Send and Talk circles with dark glyphs. After dark "dim paper"
    /// (11-03): a warm mid-dark grey, not near-black and not brown, with the same grey bubbles.
    private static let paperWhitePalette = Palette(
        label: String(localized: "Paper White", comment: "Name of a color theme in Settings → Appearance"),
        blurb: String(localized: "An e-reader's page: warm white, soft grey bubbles, Georgia throughout; dim paper after dark."),
        accent: dyn((0.184, 0.337, 0.529), (0.663, 0.745, 0.855)),          // ink blue
        background: dyn((0.980, 0.969, 0.949), (0.173, 0.169, 0.161)),     // his screenshot / dim paper
        surface: dyn((0.914, 0.906, 0.890), (0.231, 0.227, 0.216)),
        userBubble: dyn((0.906, 0.929, 0.949), (0.239, 0.263, 0.298)),
        userText: dyn((1.000, 1.000, 1.000), (0.173, 0.169, 0.161)),       // on the ink accent
        flatReplies: false,
        text: dyn((0.110, 0.106, 0.098), (0.929, 0.918, 0.894)),
        quoteBarColor: dyn((0.184, 0.337, 0.529), (0.663, 0.745, 0.855)).opacity(0.45),
        tableHeaderTint: dyn((0.110, 0.106, 0.098), (0.929, 0.918, 0.894)).opacity(0.06),
        bodyFontName: "Georgia",
        usesGlass: true,
        userBubbleTextColor: dyn((0.110, 0.106, 0.098), (0.929, 0.918, 0.894)),
        actionTint: dyn((0.847, 0.902, 0.969), (0.263, 0.325, 0.416)),
        actionGlyph: dyn((0.110, 0.106, 0.098), (0.929, 0.918, 0.894)))

    /// The office option, made unmistakably blue (11-03): a blue-grey page with white cards by day,
    /// navy slate by night, a steel-blue accent, the system sans, replies on cards.
    private static let slatePalette = Palette(
        label: String(localized: "Slate", comment: "Name of a color theme in Settings → Appearance"),
        blurb: String(localized: "Blue-grey with white cards and a steel accent; navy slate after dark. The office option."),
        accent: dyn((0.173, 0.322, 0.510), (0.498, 0.655, 0.851)),          // steel blue
        background: dyn((0.835, 0.863, 0.902), (0.094, 0.125, 0.169)),     // blue-grey / navy slate
        surface: dyn((1.000, 1.000, 1.000), (0.137, 0.184, 0.243)),        // the cards replies sit on
        userBubble: nil,
        userText: dyn((1.000, 1.000, 1.000), (0.094, 0.125, 0.169)),
        flatReplies: false,
        text: dyn((0.090, 0.125, 0.169), (0.890, 0.914, 0.945)),
        usesGlass: true)

    /// A real Mac terminal: Apple Terminal's Homebrew profile — its green (muted for
    /// OLED), its dark grey, SF Mono throughout, and the syntax hues Claude Code paints there.
    /// The prompt row takes the profile's pure-green bold, hotter than the reply green.
    private static let terminalPalette = Palette(
        label: String(localized: "Terminal", comment: "Name of a color theme in Settings → Appearance"),
        blurb: String(localized: "Green phosphor on the Mac terminal's grey; your messages become shell prompts."),
        accent: dyn((0.106, 0.541, 0.243), (0.180, 0.830, 0.440)),
        background: dyn((0.933, 0.953, 0.933), (0.113, 0.113, 0.113)),
        surface: dyn((0.875, 0.910, 0.875), (0.155, 0.170, 0.155)),
        userBubble: nil,
        userText: dyn((1, 1, 1), (0, 0, 0)),
        flatReplies: true,
        text: dyn((0.063, 0.141, 0.059), (0.180, 0.830, 0.440)),
        linkColor: dyn((0.250, 0.400, 0.750), (0.600, 0.710, 1.000)),      // ANSI periwinkle
        quoteBarColor: dyn((0.480, 0.400, 0.750), (0.710, 0.660, 0.930)).opacity(0.8),   // ANSI purple
        tableHeaderTint: dyn((0.250, 0.400, 0.750), (0.600, 0.710, 1.000)).opacity(0.14),
        promptPrefix: "❯ ",
        promptColor: dyn((0.063, 0.141, 0.059), (0.000, 0.880, 0.000)),
        replyDesign: .monospaced, headingDesign: .monospaced, monoTables: true,
        monoFontName: "SourceCodePro-Medium",   // bundled; Bold ships too for headings/prompt
        syntaxDark: .terminalDark, syntaxLight: .terminalLight,
        bubbleRadius: 12, bubbleVerticalPadding: 5)

    private static let amberPalette = Palette(
        label: String(localized: "Amber CRT", comment: "Name of a color theme in Settings → Appearance"),
        blurb: String(localized: "Amber phosphor on warm black; your messages become shell prompts."),
        accent: dyn((0.720, 0.450, 0.000), (0.780, 0.530, 0.000)),   // softened Wyse amber
        background: dyn((0.965, 0.945, 0.900), (0.030, 0.015, 0.000)),
        surface: dyn((0.925, 0.895, 0.830), (0.090, 0.055, 0.010)),
        userBubble: nil,
        userText: dyn((1, 1, 1), (0.050, 0.025, 0.000)),
        flatReplies: true,
        text: dyn((0.250, 0.160, 0.040), (0.780, 0.530, 0.000)),
        promptPrefix: "❯ ",
        promptColor: dyn((0.250, 0.160, 0.040), (1.000, 0.690, 0.000)),   // full-brightness prompt
        replyDesign: .monospaced, headingDesign: .monospaced, monoTables: true,
        monoFontName: "SourceCodePro-Medium",
        bubbleRadius: 12, bubbleVerticalPadding: 5)

    /// The Hermes docs site, sampled from a screenshot: pure gold on near-black,
    /// warm off-white text, gold "button" user bubbles with dark text, Source Code Pro.
    private static let githubDarkPalette = Palette(
        label: String(localized: "Hermes", comment: "Name of a color theme in Settings → Appearance"),
        blurb: String(localized: "Hermes gold on near-black, set in Inter; the docs-site look."),
        accent: dyn((0.478, 0.388, 0.000), (1.000, 0.843, 0.000)),   // #FFD700; deep gold by day
        background: dyn((0.992, 0.973, 0.894), (0.106, 0.106, 0.114)),   // gold-cream / #1b1b1d
        surface: dyn((0.953, 0.922, 0.796), (0.145, 0.145, 0.157)),
        userBubble: nil,
        userText: dyn((1, 1, 1), (0.106, 0.106, 0.114)),   // dark text on the gold bubble
        flatReplies: true,   // replies print straight on the page, like the docs site
        text: dyn((0.106, 0.106, 0.114), (0.878, 0.878, 0.816)),     // #E0E0D0 warm white
        bodyFontName: "Inter-Regular",   // the docs site's face; code blocks stay mono
        syntaxDark: .hermesDark, syntaxLight: .hermesLight,
        bubbleRadius: 12)

    /// An editor (11-03; it had shared Hermes's warm near-black and Paper's serif): a crisp cool
    /// white or GitHub's #0D1117, the system sans with monospaced headings and tables, GitHub's
    /// blue, green and purple for links, checkboxes and quotes, and your messages in pale sky.
    private static let claudeCodePalette = Palette(
        label: String(localized: "Code", comment: "Name of a color theme in Settings → Appearance"),
        blurb: String(localized: "An editor: crisp white or GitHub dark, monospaced headings and tables, your messages in pale sky."),
        accent: dyn((0.035, 0.412, 0.855), (0.345, 0.651, 1.000)),          // GitHub blue
        background: dyn((0.953, 0.965, 0.984), (0.051, 0.067, 0.090)),
        surface: dyn((1.000, 1.000, 1.000), (0.086, 0.106, 0.133)),
        userBubble: dyn((0.867, 0.957, 1.000), (0.796, 0.941, 1.000)),     // pale sky
        userText: dyn((1.000, 1.000, 1.000), (0.051, 0.067, 0.090)),       // the glyph on the blue
        flatReplies: true,
        text: dyn((0.122, 0.137, 0.157), (0.902, 0.929, 0.953)),
        linkColor: dyn((0.035, 0.412, 0.855), (0.345, 0.651, 1.000)),
        checkboxColor: dyn((0.102, 0.498, 0.216), (0.247, 0.725, 0.314)),  // green
        quoteBarColor: dyn((0.510, 0.314, 0.875), (0.639, 0.443, 0.969)).opacity(0.8),   // purple
        tableHeaderTint: dyn((0.035, 0.412, 0.855), (0.345, 0.651, 1.000)).opacity(0.12),
        headingDesign: .monospaced, monoTables: true,
        userBubbleTextColor: dyn((0.122, 0.137, 0.157), (0.051, 0.067, 0.090)))

    /// This theme with the reader's color picks applied. The picks replace palette values
    /// before anything derives from them, so links, checkboxes and the rest follow a custom
    /// accent exactly as they follow the theme's own.
    func resolved(with colors: ThemeColors?, font: ChatFont = .theme) -> ResolvedTheme {
        var p = palette
        font.apply(to: &p)
        if let accent = colors?.accent {
            p.accent = accent.color
            p.userText = accent.contrastingText   // the glyph on accent buttons
            p.actionTint = nil; p.actionGlyph = nil   // your accent fills Send and Talk too
            if p.userBubble == nil { p.userBubbleTextColor = nil }   // a bubble in the accent takes its glyph colour
        }
        if let bubble = colors?.bubble {
            if p.promptPrefix != nil {
                p.promptColor = bubble.color      // prompt themes have no bubble; your line takes the color
            } else {
                p.userBubble = bubble.color
                p.userBubbleTextColor = bubble.contrastingText
            }
        }
        // The wallpaper: the page, and what stands on it. Replies print straight on the page, so
        // its text is near-black or near-white by the wallpaper's own lightness, the lifted
        // surface a step toward that ink, and the app light or dark to match.
        if let wallpaper = colors?.wallpaper {
            let dark = wallpaper.wantsLightText
            let ink = dark ? ThemeColors.RGB(red: 0.941, green: 0.937, blue: 0.925) : ThemeColors.RGB(red: 0.106, green: 0.106, blue: 0.114)
            p.background = wallpaper.color
            p.surface = wallpaper.mixed(with: ink, 0.08).color
            p.text = ink.color
            p.scheme = dark ? .dark : .light
        }
        #if os(macOS)
        return ResolvedTheme(base: self, palette: p, textScale: TextZoom.current.withLock { $0 })
        #else
        return ResolvedTheme(base: self, palette: p)
        #endif
    }
}

/// A theme as the app renders it: the base theme plus the reader's color picks. This is what
/// views get from the environment; the accessors are shared with `Theme` through `ThemeStyle`.
/// Equatable so the root can rebuild the value without every theme reader re-rendering.
nonisolated struct ResolvedTheme: ThemeStyle, Equatable, Sendable {
    let base: Theme
    let palette: Theme.Palette
    #if os(macOS)
    /// View → Zoom In and Out on the Mac (`TextZoom`): the conversation's fonts at this scale.
    var textScale: CGFloat = 1
    #endif
    var rawValue: String { base.rawValue }
}

/// The reader's color picks for one theme. nil fields keep the theme's own color.
nonisolated struct ThemeColors: Codable, Equatable, Sendable {
    var accent: RGB?
    var bubble: RGB?
    /// The page behind the chat, voice mode and group chats.
    var wallpaper: RGB?
    var isEmpty: Bool { accent == nil && bubble == nil && wallpaper == nil }

    /// An sRGB color that survives a round trip through UserDefaults. Picks are one color in
    /// both appearances; the theme's own colors keep their light and dark variants.
    struct RGB: Codable, Equatable, Sendable {
        var red: Double, green: Double, blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = red; self.green = green; self.blue = blue
        }

        init(_ color: Color) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            #if canImport(UIKit)
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            #else
            (NSColor(color).usingColorSpace(.sRGB) ?? .black).getRed(&r, green: &g, blue: &b, alpha: &a)
            #endif
            // Extended-range pickers can report slightly past 0...1; clamp to plain sRGB.
            red = min(max(Double(r), 0), 1); green = min(max(Double(g), 0), 1); blue = min(max(Double(b), 0), 1)
        }

        var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

        /// Near-black or white, whichever reads better on this color (WCAG relative luminance).
        var contrastingText: Color {
            wantsLightText ? .white : Color(red: 0.106, green: 0.106, blue: 0.114)
        }

        /// White reads better on it than near-black does: a dark color.
        var wantsLightText: Bool {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
            let againstWhite = 1.05 / (luminance + 0.05)
            let againstDark = (luminance + 0.05) / 0.0569   // #1B1B1D's luminance + 0.05
            return againstWhite >= againstDark
        }

        /// `amount` of the way to `other`.
        func mixed(with other: RGB, _ amount: Double) -> RGB {
            RGB(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
                blue: blue + (other.blue - blue) * amount)
        }
    }
}

/// Everything views read from a theme. Derivations from the accent live here, once, so the
/// base theme and the reader's resolved copy of it answer identically.
nonisolated protocol ThemeStyle {
    var palette: Theme.Palette { get }
    #if os(macOS)
    /// The Mac's text zoom (`TextZoom`), 1 at Actual Size.
    var textScale: CGFloat { get }
    #endif
}

#if os(macOS)
extension ThemeStyle {
    var textScale: CGFloat { 1 }

    /// A font of the conversation at the Mac's zoom: the Mac's size for `style` (or a custom
    /// face's own size), times it. Nil at Actual Size, where the font is as it always was.
    func zoomed(_ style: NSFont.TextStyle, custom size: CGFloat, design: Font.Design?) -> Font? {
        guard textScale != 1 else { return nil }
        if let name = proseFontName { return .custom(name, fixedSize: size * textScale) }
        return .system(size: TextZoom.points(style) * textScale, design: design)
    }
}
#endif

extension ThemeStyle {
    var label: String { palette.label }
    var blurb: String { palette.blurb }
    var accent: Color { palette.accent }
    var background: Color? { palette.background }
    var surface: Color? { palette.surface }
    var userBubble: Color { palette.userBubble ?? accent }
    var userBubbleText: Color { palette.userBubbleTextColor ?? userText }
    /// Behind a reply. Flat themes show replies straight on the page.
    var assistantBubble: Color? { palette.flatReplies ? background : surface }
    var userText: Color { palette.userText }
    /// The Send and Talk circles beside the message field, and the glyph on them.
    var actionTint: Color { palette.actionTint ?? accent }
    var actionGlyph: Color { palette.actionGlyph ?? userText }
    /// The face of replies, headings, tables and your messages: a face picked in Settings, else
    /// the theme's mono (the CRTs) or its own proportional face. nil = the system face.
    var proseFontName: String? { palette.pickedFont ? palette.bodyFontName : (palette.monoFontName ?? palette.bodyFontName) }
    var text: Color? { palette.text }
    /// The page, a raised surface and the text as colours to draw with. A theme may leave any of
    /// the three to the system (nil above, for the places that want the system's own material);
    /// these fall back to the system's colour, so a view doesn't spell the fallback out each time.
    #if canImport(UIKit)
    var pageColor: Color { background ?? Color(.systemBackground) }
    var surfaceColor: Color { surface ?? Color(.secondarySystemBackground) }
    #else
    var pageColor: Color { background ?? Color(nsColor: .windowBackgroundColor) }
    var surfaceColor: Color { surface ?? Color(nsColor: .controlBackgroundColor) }
    #endif
    var textColor: Color { text ?? .primary }
    var linkColor: Color { palette.linkColor ?? accent }
    var checkboxColor: Color { palette.checkboxColor ?? accent }
    var quoteBarColor: Color { palette.quoteBarColor ?? accent.opacity(0.6) }
    var tableHeaderTint: Color { palette.tableHeaderTint ?? accent.opacity(0.10) }
    var promptPrefix: String? { palette.promptPrefix }
    var promptColor: Color { palette.promptColor ?? accent }
    /// Reply text.
    var messageFont: Font {
        #if os(macOS)
        if let zoomed = zoomed(.body, custom: 17, design: palette.replyDesign) { return zoomed }
        #endif
        if let name = proseFontName { return .custom(name, size: 17, relativeTo: .body) }
        return .system(.body, design: palette.replyDesign)
    }
    /// Headings in replies.
    func headingFont(_ level: Int) -> Font {
        // Prompt-prefix (CRT) themes keep headings at body size in bold — one type size.
        if palette.promptPrefix != nil { return messageFont.weight(level <= 2 ? .bold : .semibold) }
        #if os(macOS)
        switch level {
        case 1: if let zoomed = zoomed(.title3, custom: 20, design: palette.headingDesign) { return zoomed.weight(proseFontName == nil ? .semibold : .bold) }
        case 2: if let zoomed = zoomed(.headline, custom: 17, design: palette.headingDesign) { return zoomed.weight(.bold) }
        default: if let zoomed = zoomed(.subheadline, custom: 15, design: palette.headingDesign) { return zoomed.weight(.semibold) }
        }
        #endif
        if let name = proseFontName {
            // Custom-face theme without the CRT constraint: scaled headings, same face.
            switch level {
            case 1: return .custom(name, size: 20, relativeTo: .title3).weight(.bold)
            case 2: return .custom(name, size: 17, relativeTo: .headline).weight(.bold)
            default: return .custom(name, size: 15, relativeTo: .subheadline).weight(.semibold)
            }
        }
        switch level {
        case 1: return .system(.title3, design: palette.headingDesign).weight(.semibold)
        case 2: return .system(.headline, design: palette.headingDesign)
        default: return .system(.subheadline, design: palette.headingDesign).weight(.semibold)
        }
    }
    var tableFont: Font {
        #if os(macOS)
        if let zoomed = zoomed(.footnote, custom: 13, design: palette.monoTables ? .monospaced : .default) { return zoomed }
        #endif
        if let name = proseFontName { return .custom(name, size: 13, relativeTo: .footnote) }
        return palette.monoTables ? .system(.footnote, design: .monospaced) : .system(.footnote)
    }
    /// Your own messages.
    var userFont: Font {
        #if os(macOS)
        if palette.sansUserFont, textScale != 1 { return .system(size: TextZoom.points(.body) * textScale) }
        #endif
        return palette.sansUserFont ? .body : messageFont
    }
    /// Font for code blocks.
    var codeFont: Font {
        #if os(macOS)
        if textScale != 1 {
            if let name = palette.monoFontName { return .custom(name, fixedSize: 13 * textScale) }
            return .system(size: TextZoom.points(.footnote) * textScale, design: .monospaced)
        }
        #endif
        if let name = palette.monoFontName { return .custom(name, size: 13, relativeTo: .footnote) }
        return .system(.footnote, design: .monospaced)
    }
    /// Code-block syntax palette per appearance.
    func syntaxPalette(dark: Bool) -> SyntaxHighlighter.Palette { dark ? palette.syntaxDark : palette.syntaxLight }
    var usesGlass: Bool { palette.usesGlass }
    var bubbleRadius: CGFloat { palette.bubbleRadius }
    /// Your bubble: the theme's corners, with the bottom one on your side tucked in.
    var userBubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: bubbleRadius, bottomLeadingRadius: bubbleRadius,
                               bottomTrailingRadius: min(5, bubbleRadius), topTrailingRadius: bubbleRadius)
    }
    var bubbleVerticalPadding: CGFloat { palette.bubbleVerticalPadding }
}

extension Theme: ThemeStyle {}

extension EnvironmentValues {
    @Entry var theme: ResolvedTheme = Theme.standard.resolved(with: nil)
}

/// Settings → Appearance → Font (asked 2026-11-02): the face of replies, headings, tables and
/// your messages, or the theme's own. Only faces iOS and macOS ship with; code keeps its mono.
nonisolated enum ChatFont: String, CaseIterable, Identifiable, Codable, Sendable {
    case theme, system, rounded, newYork, georgia, charter, iowan, palatino, avenir, mono

    var id: String { rawValue }

    var label: String {
        switch self {
        case .theme: String(localized: "Theme's Font", comment: "Settings → Appearance → Font: the theme's own face")
        case .system: String(localized: "System", comment: "Settings → Appearance → Font: San Francisco")
        case .rounded: String(localized: "Rounded", comment: "Settings → Appearance → Font: SF Rounded")
        case .newYork: "New York"
        case .georgia: "Georgia"
        case .charter: "Charter"
        case .iowan: "Iowan Old Style"
        case .palatino: "Palatino"
        case .avenir: "Avenir Next"
        case .mono: String(localized: "Monospaced", comment: "Settings → Appearance → Font: SF Mono")
        }
    }

    /// An installed face, by PostScript name; nil for the system's own designs.
    var fontName: String? {
        switch self {
        case .georgia: "Georgia"
        case .charter: "Charter-Roman"
        case .iowan: "IowanOldStyle-Roman"
        case .palatino: "Palatino-Roman"
        case .avenir: "AvenirNext-Regular"
        default: nil
        }
    }

    /// The system design for the system faces.
    var design: Font.Design {
        switch self {
        case .rounded: .rounded
        case .newYork: .serif
        case .mono: .monospaced
        default: .default
        }
    }

    /// The row's own preview in Settings, at body size.
    var preview: Font {
        if let fontName { return .custom(fontName, size: 17, relativeTo: .body) }
        return .system(.body, design: design)
    }

    /// The palette with this face for its prose. The theme's own colours and code face stay.
    func apply(to p: inout Theme.Palette) {
        guard self != .theme else { return }
        p.pickedFont = true
        p.bodyFontName = fontName
        p.replyDesign = design
        p.headingDesign = design
        p.monoTables = self == .mono
        p.sansUserFont = false
    }
}
