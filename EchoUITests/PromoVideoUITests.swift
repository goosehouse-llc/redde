import XCTest

/// Drives the App Store preview's shots while the simulator records (see design/video). Skipped
/// unless the runner sets PROMO_VIDEO=1 (`TEST_RUNNER_PROMO_VIDEO=1 xcodebuild test …`). Each shot
/// prints when it starts and ends, so the recording can be cut to exactly that span.
@MainActor
final class PromoVideoUITests: XCTestCase {
    private func launch(_ extra: [String]) throws -> XCUIApplication {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PROMO_VIDEO"] == "1", "Promo video shots run on request")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-setupDone", "YES", "-openToVoiceScreen", "NO", "-listenOnOpen", "NO", "-requireBiometrics", "NO",
                               "-echo.demoHosts", "-transport", "chatCompletions"] + extra
        app.launch()
        return app
    }

    private func mark(_ what: String) { print("PROMO \(what) \(Date().timeIntervalSince1970)") }
    private func hold(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func drag(_ app: XCUIApplication, from: CGVector, to: CGVector, velocity: XCUIGestureVelocity = .slow) {
        let w = app.windows.firstMatch
        w.coordinate(withNormalizedOffset: from)
            .press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: to), withVelocity: velocity, thenHoldForDuration: 0.1)
    }

    /// Answers with substance: read up through the checklist, table, diagram and math.
    func testRichAnswers() throws {
        let app = try launch(["-echo.demo", "-echo.demoLibrary", "-theme", "claudeCode", "-appearance", "dark"])
        XCTAssertTrue(app.staticTexts["Where are we on the kitchen project?"].waitForExistence(timeout: 20))
        // On iPad the transcript is the right-hand column, beside the sidebar.
        let x: CGFloat = app.windows.firstMatch.frame.width > 600 ? 0.66 : 0.5
        // Diagrams and math draw when they first scroll into view: pass over them all once, then
        // start the take from the top of the transcript.
        for _ in 0..<4 { drag(app, from: CGVector(dx: x, dy: 0.8), to: CGVector(dx: x, dy: 0.2), velocity: .fast); hold(0.8) }
        hold(1.5)
        for _ in 0..<5 { drag(app, from: CGVector(dx: x, dy: 0.25), to: CGVector(dx: x, dy: 0.85), velocity: .fast) }
        hold(1.5)
        mark("start")
        hold(0.8)
        for _ in 0..<3 {
            drag(app, from: CGVector(dx: x, dy: 0.78), to: CGVector(dx: x, dy: 0.38), velocity: 250)
            hold(0.5)
        }
        hold(0.8)
        mark("end")
    }

    /// Every chat, cron job and board: swipe the conversations in, then open the Kanban board.
    func testConversationsAndKanban() throws {
        let app = try launch(["-echo.demo", "-echo.demoLibrary", "-echo.demoKanban", "-theme", "claudeCode", "-appearance", "dark"])
        XCTAssertTrue(app.buttons["Conversations"].waitForExistence(timeout: 20))
        hold(2.5)
        mark("start")
        hold(0.7)
        drag(app, from: CGVector(dx: 0.08, dy: 0.5), to: CGVector(dx: 0.85, dy: 0.52), velocity: 700)
        hold(1.6)
        // By position: the Kanban segment in the panel's first row. (Accessibility lookups found
        // the hidden ⌘3 shortcut button of the same name, or nothing.)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.69, dy: 0.262)).tap()
        hold(2.4)
        mark("end")
    }

    /// Make it yours: Settings with the app icons open, scrolled gently.
    func testMakeItYours() throws {
        let app = try launch(["-echo.demo", "-echo.screen", "settings", "-echo.expandAppIcons", "-theme", "standard", "-appearance", "light"])
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20))
        hold(2)
        mark("start")
        hold(1.2)
        drag(app, from: CGVector(dx: 0.5, dy: 0.75), to: CGVector(dx: 0.5, dy: 0.5), velocity: 180)
        hold(2)
        mark("end")
    }
}
