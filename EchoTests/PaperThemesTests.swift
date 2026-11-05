import SwiftUI
import Testing
import UIKit
@testable import Echo

/// Paper White (from Nous's Hermes Mobile, 2026-11-02), Paper redone the same day, and
/// Settings → Appearance → Font.
@MainActor
struct PaperThemesTests {
    private func rgb(_ color: Color, _ style: UIUserInterfaceStyle) -> (Double, Double, Double) {
        let ui = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private func contrast(_ x: Color, _ y: Color, _ style: UIUserInterfaceStyle) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func lum(_ c: (Double, Double, Double)) -> Double { 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2) }
        let (a, b) = (lum(rgb(x, style)), lum(rgb(y, style)))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// CIE L*a*b* distance (ΔE 1976) between two colours in one appearance.
    private func deltaE(_ x: Color, _ y: Color, _ style: UIUserInterfaceStyle) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func lab(_ c: (Double, Double, Double)) -> (Double, Double, Double) {
            let (r, g, b) = (lin(c.0), lin(c.1), lin(c.2))
            let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
            func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
            return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
        }
        let (a, b) = (lab(rgb(x, style)), lab(rgb(y, style)))
        return ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)).squareRoot()
    }

    /// "Paper, Paper White, Slate and Code all look really similar" (2026-11-03): their pages are
    /// apart by at least ΔE 5 in each appearance, and the other themes with a page of their own
    /// keep at least ΔE 3 from all four.
    @Test func theFourPagesCanBeToldApart() throws {
        let four: [Theme] = [.paper, .paperWhite, .slate, .claudeCode]
        let others: [Theme] = [.githubDark, .terminal, .amber]
        for style in [UIUserInterfaceStyle.light, .dark] {
            let look = style == .dark ? "dark" : "light"
            for (i, a) in four.enumerated() {
                let pageA = try #require(a.palette.background)
                for b in four[(i + 1)...] {
                    let d = deltaE(pageA, try #require(b.palette.background), style)
                    #expect(d >= 5, "\(a.rawValue)/\(b.rawValue) \(look): ΔE \(String(format: "%.1f", d))")
                }
                for b in others {
                    let d = deltaE(pageA, try #require(b.palette.background), style)
                    #expect(d >= 3, "\(a.rawValue)/\(b.rawValue) \(look): ΔE \(String(format: "%.1f", d))")
                }
            }
        }
    }

    @Test func eachOfTheFourHasItsOwnShapeAndFace() {
        let paper = Theme.paper.palette, white = Theme.paperWhite.palette
        let slate = Theme.slate.palette, code = Theme.claudeCode.palette
        #expect(paper.flatReplies && paper.replyDesign == .serif)          // flat serif on parchment
        #expect(!white.flatReplies && white.bodyFontName == "Georgia")     // grey bubbles in Georgia
        #expect(!slate.flatReplies && slate.replyDesign == .default)       // white cards, the sans
        #expect(code.replyDesign == .default && code.headingDesign == .monospaced && code.monoTables)
    }

    @Test(arguments: [Theme.paper, .paperWhite, .slate, .claudeCode, .githubDark])
    func everyPairReads(_ theme: Theme) throws {
        let p = theme.palette
        let page = try #require(p.background), surface = try #require(p.surface), text = try #require(p.text)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let name = "\(theme.rawValue) \(style == .dark ? "dark" : "light")"
            #expect(contrast(text, page, style) >= 4.5, "\(name): text on the page")
            #expect(contrast(text, surface, style) >= 4.5, "\(name): text on a raised row")
            #expect(contrast(p.accent, page, style) >= 4.5, "\(name): links on the page")
            if let link = p.linkColor {
                #expect(contrast(link, page, style) >= 4.5, "\(name): its own link colour on the page")
            }
            let bubble = p.userBubble ?? p.accent
            #expect(contrast(p.userBubbleTextColor ?? p.userText, bubble, style) >= 4.5, "\(name): your words on your bubble")
            if let tint = p.actionTint, let glyph = p.actionGlyph {
                #expect(contrast(glyph, tint, style) >= 3, "\(name): the Send glyph")
            }
        }
    }

    @Test func paperHasItsOwnPageNow() {
        #expect(Theme.paper.palette.background != nil)
        #expect(Theme.paper.palette.headingDesign == .serif)
    }

    @Test func paperWhiteLooksLikeTheirs() {
        let p = Theme.paperWhite.palette
        #expect(!p.flatReplies)
        #expect(p.bodyFontName == "Georgia")
        #expect(p.userBubble != nil && p.actionTint != nil)
        let order = Theme.allCases
        #expect(order.firstIndex(of: .paperWhite) == order.firstIndex(of: .paper).map { $0 + 1 })
    }

    @Test func theThemesFontByDefault() {
        for theme in Theme.allCases {
            #expect(theme.resolved(with: nil, font: .theme) == theme.resolved(with: nil))
        }
        #expect(Theme.terminal.resolved(with: nil).proseFontName == "SourceCodePro-Medium")
    }

    @Test func aPickedFaceReplacesTheProseFaceNotTheCode() {
        let charter = Theme.terminal.resolved(with: nil, font: .charter)
        #expect(charter.proseFontName == "Charter-Roman")
        #expect(charter.palette.monoFontName == "SourceCodePro-Medium")   // code blocks keep it
        #expect(!charter.palette.monoTables)
        let system = Theme.paperWhite.resolved(with: nil, font: .system)
        #expect(system.proseFontName == nil)
        #expect(system.palette.replyDesign == .default)
        #expect(Theme.standard.resolved(with: nil, font: .mono).palette.monoTables)
        #expect(Theme.paper.resolved(with: nil, font: .rounded).palette.replyDesign == .rounded)
    }

    @Test(arguments: ChatFont.allCases)
    func everyNamedFaceIsInstalled(_ font: ChatFont) {
        guard let name = font.fontName else { return }
        #expect(UIFont(name: name, size: 17) != nil, "\(name)")
    }

    @Test func theFontIsSynced() {
        #expect(Settings.syncedKeys.contains("chatFont"))
    }
}
