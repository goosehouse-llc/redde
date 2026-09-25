import SwiftUI
import UIKit

/// Visual themes. Each theme is one `Palette` value — every colour, font and shape decision
/// in one place — with light and dark variants inside the colours themselves; Settings →
/// Appearance chooses light, dark or system for whichever theme is active.
nonisolated enum Theme: String, CaseIterable, Identifiable, Codable {
    // Declaration order is the Settings list order.
    case githubDark, standard, paper, slate, terminal, amber, claudeCode

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
        /// Text on your bubble when it's been recolored; set by `resolved(with:)`, never by a palette.
        var userBubbleTextColor: Color? = nil
    }

    /// A colour with one value in light mode and another in dark.
    private static func dyn(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    var palette: Palette {
        switch self {
        case .standard: Self.standardPalette
        case .paper: Self.paperPalette
        case .slate: Self.slatePalette
        case .terminal: Self.terminalPalette
        case .amber: Self.amberPalette
        case .githubDark: Self.githubDarkPalette
        case .claudeCode: Self.claudeCodePalette
        }
    }

    private static let standardPalette = Palette(
        label: "Messages",
        blurb: "Redde blue on the system greys.",
        accent: Color(red: 0.180, green: 0.545, blue: 0.961),
        background: nil, surface: nil, userBubble: nil, flatReplies: true, text: nil,
        usesGlass: true)

    private static let paperPalette = Palette(
        label: "Paper",
        blurb: "Warm paper and ink; dark ink and parchment after dark.",
        accent: dyn((0.106, 0.114, 0.227), (0.847, 0.784, 0.651)),
        background: nil,
        surface: dyn((0.910, 0.894, 0.855), (0.169, 0.149, 0.122)),
        userBubble: nil,
        userText: dyn((0.953, 0.945, 0.925), (0.122, 0.106, 0.086)),
        flatReplies: true,
        text: dyn((0.106, 0.114, 0.227), (0.929, 0.902, 0.847)),
        replyDesign: .serif)

    private static let slatePalette = Palette(
        label: "Slate",
        blurb: "Cool grey-blue with a steel accent. The office option.",
        accent: dyn((0.239, 0.353, 0.502), (0.541, 0.651, 0.788)),
        background: dyn((0.855, 0.875, 0.905), (0.043, 0.055, 0.075)),
        surface: dyn((1, 1, 1), (0.122, 0.153, 0.200)),
        userBubble: nil,
        userText: dyn((1, 1, 1), (0.059, 0.078, 0.106)),
        flatReplies: true,
        text: dyn((0.114, 0.141, 0.188), (0.890, 0.910, 0.937)),
        usesGlass: true)

    /// A real Mac terminal: Apple Terminal's Homebrew profile — its green (muted for
    /// OLED), its dark grey, SF Mono throughout, and the syntax hues Claude Code paints there.
    /// The prompt row takes the profile's pure-green bold, hotter than the reply green.
    private static let terminalPalette = Palette(
        label: "Terminal",
        blurb: "Green phosphor on the Mac terminal's grey; your messages become shell prompts.",
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
        label: "Amber CRT",
        blurb: "Amber phosphor on warm black; your messages become shell prompts.",
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
        label: "Hermes",
        blurb: "Hermes gold on near-black, set in Inter; the docs-site look.",
        accent: dyn((0.604, 0.494, 0.000), (1.000, 0.843, 0.000)),   // #FFD700; deep gold by day
        background: dyn((0.973, 0.969, 0.949), (0.106, 0.106, 0.114)),   // #1b1b1d
        surface: dyn((0.933, 0.929, 0.902), (0.145, 0.145, 0.157)),
        userBubble: nil,
        userText: dyn((1, 1, 1), (0.106, 0.106, 0.114)),   // dark text on the gold bubble
        flatReplies: true,   // replies print straight on the page, like the docs site
        text: dyn((0.106, 0.106, 0.114), (0.878, 0.878, 0.816)),     // #E0E0D0 warm white
        bodyFontName: "Inter-Regular",   // the docs site's face; code blocks stay mono
        syntaxDark: .hermesDark, syntaxLight: .hermesLight,
        bubbleRadius: 12)

    private static let claudeCodePalette = Palette(
        label: "Code",
        blurb: "Warm near-black and bone with a pale sky accent; serif replies, sans questions, monospaced code.",
        accent: Color(red: 0.796, green: 0.941, blue: 1.0),   // #CBF0FF, both appearances
        background: dyn((0.973, 0.969, 0.949), (0.106, 0.106, 0.114)),   // same ground as Hermes
        surface: dyn((0.933, 0.929, 0.902), (0.145, 0.145, 0.157)),
        userBubble: Color(red: 0.796, green: 0.941, blue: 1.0),   // #CBF0FF, the accent
        // Near-black on the pale sky: your bubble's text and the glyph on accent circles.
        userText: Color(red: 0.106, green: 0.106, blue: 0.114),
        flatReplies: true,
        text: dyn((0.122, 0.118, 0.114), (0.941, 0.933, 0.906)),
        linkColor: dyn((0.290, 0.420, 0.580), (0.561, 0.659, 0.800)),    // dusty blue
        checkboxColor: dyn((0.240, 0.480, 0.420), (0.450, 0.720, 0.620)),   // teal
        quoteBarColor: dyn((0.480, 0.380, 0.520), (0.698, 0.580, 0.733)).opacity(0.8),   // muted purple
        tableHeaderTint: dyn((0.290, 0.420, 0.580), (0.561, 0.659, 0.800)).opacity(0.16),   // dusty blue, like the links
        replyDesign: .serif, headingDesign: .serif, sansUserFont: true,
        bubbleRadius: 12)

    /// This theme with the reader's color picks applied. The picks replace palette values
    /// before anything derives from them, so links, checkboxes and the rest follow a custom
    /// accent exactly as they follow the theme's own.
    func resolved(with colors: ThemeColors?) -> ResolvedTheme {
        var p = palette
        if let accent = colors?.accent {
            p.accent = accent.color
            p.userText = accent.contrastingText   // the glyph on accent buttons
        }
        if let bubble = colors?.bubble {
            if p.promptPrefix != nil {
                p.promptColor = bubble.color      // prompt themes have no bubble; your line takes the color
            } else {
                p.userBubble = bubble.color
                p.userBubbleTextColor = bubble.contrastingText
            }
        }
        return ResolvedTheme(base: self, palette: p)
    }
}

/// A theme as the app renders it: the base theme plus the reader's color picks. This is what
/// views get from the environment; the accessors are shared with `Theme` through `ThemeStyle`.
/// Equatable so the root can rebuild the value without every theme reader re-rendering.
nonisolated struct ResolvedTheme: ThemeStyle, Equatable, Sendable {
    let base: Theme
    let palette: Theme.Palette
    var rawValue: String { base.rawValue }
}

/// The reader's color picks for one theme. nil fields keep the theme's own color.
nonisolated struct ThemeColors: Codable, Equatable, Sendable {
    var accent: RGB?
    var bubble: RGB?
    var isEmpty: Bool { accent == nil && bubble == nil }

    /// An sRGB color that survives a round trip through UserDefaults. Picks are one color in
    /// both appearances; the theme's own colors keep their light and dark variants.
    struct RGB: Codable, Equatable, Sendable {
        var red: Double, green: Double, blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = red; self.green = green; self.blue = blue
        }

        init(_ color: Color) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            // Extended-range pickers can report slightly past 0...1; clamp to plain sRGB.
            red = min(max(Double(r), 0), 1); green = min(max(Double(g), 0), 1); blue = min(max(Double(b), 0), 1)
        }

        var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

        /// Near-black or white, whichever reads better on this color (WCAG relative luminance).
        var contrastingText: Color {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
            let againstWhite = 1.05 / (luminance + 0.05)
            let againstDark = (luminance + 0.05) / 0.0569   // #1B1B1D's luminance + 0.05
            return againstWhite >= againstDark ? .white : Color(red: 0.106, green: 0.106, blue: 0.114)
        }
    }
}

/// Everything views read from a theme. Derivations from the accent live here, once, so the
/// base theme and the reader's resolved copy of it answer identically.
nonisolated protocol ThemeStyle {
    var palette: Theme.Palette { get }
}

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
    var text: Color? { palette.text }
    var linkColor: Color { palette.linkColor ?? accent }
    var checkboxColor: Color { palette.checkboxColor ?? accent }
    var quoteBarColor: Color { palette.quoteBarColor ?? accent.opacity(0.6) }
    var tableHeaderTint: Color { palette.tableHeaderTint ?? accent.opacity(0.10) }
    var promptPrefix: String? { palette.promptPrefix }
    var promptColor: Color { palette.promptColor ?? accent }
    /// Reply text.
    var messageFont: Font {
        if let name = palette.monoFontName ?? palette.bodyFontName { return .custom(name, size: 17, relativeTo: .body) }
        return .system(.body, design: palette.replyDesign)
    }
    /// Headings in replies.
    func headingFont(_ level: Int) -> Font {
        // Prompt-prefix (CRT) themes keep headings at body size in bold — one type size.
        if palette.promptPrefix != nil { return messageFont.weight(level <= 2 ? .bold : .semibold) }
        if let name = palette.monoFontName ?? palette.bodyFontName {
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
        if let name = palette.monoFontName ?? palette.bodyFontName { return .custom(name, size: 13, relativeTo: .footnote) }
        return palette.monoTables ? .system(.footnote, design: .monospaced) : .system(.footnote)
    }
    /// Your own messages.
    var userFont: Font { palette.sansUserFont ? .body : messageFont }
    /// Font for code blocks.
    var codeFont: Font {
        if let name = palette.monoFontName { return .custom(name, size: 13, relativeTo: .footnote) }
        return .system(.footnote, design: .monospaced)
    }
    /// Code-block syntax palette per appearance.
    func syntaxPalette(dark: Bool) -> SyntaxHighlighter.Palette { dark ? palette.syntaxDark : palette.syntaxLight }
    var usesGlass: Bool { palette.usesGlass }
    var bubbleRadius: CGFloat { palette.bubbleRadius }
    var bubbleVerticalPadding: CGFloat { palette.bubbleVerticalPadding }
}

extension Theme: ThemeStyle {}

extension EnvironmentValues {
    @Entry var theme: ResolvedTheme = Theme.standard.resolved(with: nil)
}
