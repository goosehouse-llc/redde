import XCTest

/// App Store screenshots that need the screen moved first (design/screenshots, README "2.3 slots").
/// Skipped unless the runner sets PROMO_VIDEO=1; SHOT_DIR is where the pictures go.
@MainActor
final class StoreShotsUITests: XCTestCase {
    /// 2.3.1's answers slot (`ph-purchase`): the purchase card scrolled to its own header, its top edge
    /// at the bar's, so its title and the pick's tag show (the chat opens at the end of the reply).
    func testPurchaseFromItsHeader() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PROMO_VIDEO"] == "1")
        let dir = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["SHOT_DIR"]))
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat
            + ["-echo.demoHosts", "-transport", "chatCompletions", "-echo.demoCards", "purchase", "-theme", "standard", "-appearance", "dark"]
        app.launch()
        let header = app.staticTexts["Noise-cancelling headphones under $300"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 30))
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        let window = app.windows.firstMatch
        let wanted: CGFloat = 133   // points from the top: the card's edge at the bar's
        // One drag, in the left margin (no link under it, or a held press opens the link's menu); a
        // drag gives up about 10 points before it moves the list.
        let y = header.frame.minY
        print("SHOT header at \(y)")
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.025, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: wanted - y + 10)), withVelocity: .slow, thenHoldForDuration: 0.4)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        print("SHOT header finally at \(header.frame.minY)")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appending(path: "ph-purchase.png"))
    }

    /// 2.6's agents slot (`ph-agent`, `pad-agent`): the demo agent built into Redde at work on "Fix
    /// the notes", stopped at its approval, with the file it changed above. No computer, no AI.
    func testAgentAtWork() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PROMO_VIDEO"] == "1")
        let dir = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["SHOT_DIR"]))
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat
            + ["-echo.clearDrafts", "-transport", "acp", "-acpURL", "demo", "-acpAgent", "", "-acpFolder", "", "-acpAllAgents", "NO",
               "-theme", "claudeCode", "-appearance", "dark"]
        app.launch()
        let composer = app.composerField
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "No message field")
        app.buttons["New conversation"].firstMatch.tap()
        composer.tap()
        composer.typeText("Fix the notes")
        app.buttons.matching(identifier: "Send").allElementsBoundByIndex.last { $0.isHittable }?.tap()
        let allow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow'")).firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 60), "The demo agent didn't ask")
        // The keyboard down, the approval settled. On iPad the chat alone: the sidebar has nothing
        // of the demo agent's to show.
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        if app.keyboards.firstMatch.exists {
            let hide = app.keyboards.buttons["Hide keyboard"]
            if hide.exists { hide.tap() } else { app.swipeDown() }
        }
        if pad {
            let sidebar = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'")).firstMatch
            if sidebar.exists { sidebar.tap() }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        let name = pad ? "pad-agent.png" : "ph-agent.png"
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appending(path: name))
    }
}
