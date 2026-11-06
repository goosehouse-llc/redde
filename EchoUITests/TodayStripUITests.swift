import XCTest

/// The chat list's Today strip (2026-11-06): the inbox, briefings and goals as tiles; a tap opens one.
@MainActor
final class TodayStripUITests: XCTestCase {
    private func openDrawer() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoGoals", "-echo.demoBriefings", "day"]
            + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        app.launch()
        let chat = app.scrollViews.firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 15))
        chat.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: chat.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        return app
    }

    private func tile(_ app: XCUIApplication, _ words: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    /// Swiped along the strip until the tile is on screen.
    private func reach(_ app: XCUIApplication, _ tile: XCUIElement) {
        let row = tile.frame.midY / app.frame.height
        for _ in 0 ..< 4 where tile.frame.maxX > app.frame.width * 0.85 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: row))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: row)))
        }
    }

    func testAGoalTileOpensTheGoal() {
        let app = openDrawer()
        let goal = tile(app, "Run a 10K by March")
        XCTAssertTrue(goal.waitForExistence(timeout: 5), "No goal tile")
        reach(app, goal)
        goal.tap()
        XCTAssertTrue(app.staticTexts["Last Check-in"].waitForExistence(timeout: 5), "The goal didn't open")
    }

    func testABriefingTileOpensTheBriefing() {
        let app = openDrawer()
        // A briefing's tile starts with its time (one opened in an earlier run is read, and gone).
        let brief = app.buttons.matching(NSPredicate(format: "label MATCHES %@", #"^\d{1,2}:\d{2}\s?[AP]M.*"#)).firstMatch
        XCTAssertTrue(brief.waitForExistence(timeout: 5), "No briefing tile")
        brief.tap()
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForExistence(timeout: 5), "The briefing didn't open")
    }
}
