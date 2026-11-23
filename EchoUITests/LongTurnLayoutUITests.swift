import XCTest

/// A reply of many tool calls folds them into one "Used 32 tools" line. The calls' empty rows used
/// to keep the transcript's spacing each: half a screen of nothing above it (Reddit, 2026-11-23).
@MainActor
final class LongTurnLayoutUITests: XCTestCase {
    func testManyToolCallsLeaveNoBlankSpace() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoLongTurn"] + XCUIApplication.straightToChat
        app.launch()
        // (the chat's title has the same words)
        let asked = app.scrollViews.firstMatch.staticTexts["Make packages for episodes 47 and 48."].firstMatch
        XCTAssertTrue(asked.waitForExistence(timeout: 15), "The demo didn't open")
        let fold = app.buttons["Show turn activity"].firstMatch
        XCTAssertTrue(fold.waitForExistence(timeout: 5), "No fold of the turn's steps")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "long turn"
        shot.lifetime = .keepAlways
        add(shot)
        let gap = fold.frame.minY - asked.frame.maxY
        print("LIVE gap between the question and the fold:", Int(gap))
        XCTAssertLessThan(gap, 80, "Blank space above the turn's steps")
    }
}
