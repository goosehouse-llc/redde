import Testing
import SwiftUI
import UIKit
@testable import Echo

/// Your accent and bubble picks: they apply per theme, flow into every color derived from the
/// accent, keep the text on them readable, and survive a relaunch.
@MainActor
struct ThemeColorsTests {
    private typealias RGB = ThemeColors.RGB

    private func components(_ color: Color) -> RGB { RGB(color) }
    private func same(_ a: Color, _ b: Color) -> Bool {
        let x = components(a), y = components(b)
        return abs(x.red - y.red) < 0.005 && abs(x.green - y.green) < 0.005 && abs(x.blue - y.blue) < 0.005
    }
    private let white = Color.white
    private let nearBlack = Color(red: 0.106, green: 0.106, blue: 0.114)

    @Test func textOnAPickStaysReadable() {
        #expect(same(RGB(red: 1, green: 0.843, blue: 0).contrastingText, nearBlack))   // Hermes gold
        #expect(same(RGB(red: 1, green: 1, blue: 1).contrastingText, nearBlack))
        #expect(same(RGB(red: 0.10, green: 0.15, blue: 0.40).contrastingText, white))  // navy
        #expect(same(RGB(red: 0, green: 0, blue: 0).contrastingText, white))
    }

    @Test func noPicksLeavesTheThemeAlone() {
        for theme in Theme.allCases {
            let resolved = theme.resolved(with: nil)
            #expect(same(resolved.accent, theme.accent))
            #expect(same(resolved.userBubble, theme.userBubble))
            #expect(resolved.rawValue == theme.rawValue)
        }
    }

    @Test func accentPickFlowsIntoEverythingDerivedFromIt() {
        let teal = RGB(red: 0.10, green: 0.55, blue: 0.55)
        let resolved = Theme.standard.resolved(with: ThemeColors(accent: teal))
        #expect(same(resolved.accent, teal.color))
        #expect(same(resolved.linkColor, teal.color))
        #expect(same(resolved.checkboxColor, teal.color))
        // Messages' bubble is the accent, so it follows, with readable text on it.
        #expect(same(resolved.userBubble, teal.color))
        #expect(same(resolved.userBubbleText, teal.contrastingText))
        #expect(same(resolved.userText, teal.contrastingText))
    }

    @Test func accentPickKeepsAThemesOwnBubble() {
        // Code sets its bubble itself (#CBF0FF), so an accent pick leaves it alone.
        let red = RGB(red: 0.8, green: 0.1, blue: 0.1)
        let base = Theme.claudeCode
        let resolved = base.resolved(with: ThemeColors(accent: red))
        #expect(same(resolved.accent, red.color))
        #expect(same(resolved.userBubble, base.userBubble))
    }

    @Test func bubblePickRecolorsOnlyTheBubble() {
        let pale = RGB(red: 0.85, green: 0.92, blue: 1.0)
        let base = Theme.githubDark
        let resolved = base.resolved(with: ThemeColors(bubble: pale))
        #expect(same(resolved.userBubble, pale.color))
        #expect(same(resolved.userBubbleText, nearBlack))
        #expect(same(resolved.accent, base.accent))
        #expect(same(resolved.userText, base.userText))   // accent buttons keep their glyph
    }

    @Test func promptThemesPutTheBubblePickOnYourPromptLine() {
        let cyan = RGB(red: 0.2, green: 0.9, blue: 0.9)
        let resolved = Theme.terminal.resolved(with: ThemeColors(bubble: cyan))
        #expect(same(resolved.promptColor, cyan.color))
    }

    @Test func picksAreKeptPerThemeAndSurviveARelaunch() throws {
        let suiteName = "theme-colors-\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: suite)
        let teal = RGB(red: 0.10, green: 0.55, blue: 0.55)
        settings.theme = .githubDark
        settings.themeColors[Theme.githubDark.rawValue] = ThemeColors(accent: teal)
        #expect(same(settings.resolvedTheme.accent, teal.color))
        #expect(same(settings.resolved(.slate).accent, Theme.slate.accent))   // other themes untouched

        let relaunched = Settings(defaults: suite)
        #expect(relaunched.themeColors[Theme.githubDark.rawValue] == ThemeColors(accent: teal))
        #expect(same(relaunched.resolvedTheme.accent, teal.color))

        relaunched.reset()
        #expect(relaunched.themeColors.isEmpty)
    }
}
