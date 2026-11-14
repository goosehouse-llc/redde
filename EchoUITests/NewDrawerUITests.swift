import XCTest

/// The drawer laid out from scratch (2026-11-13): no tabs, and Today, Planned, Board and Made
/// open their pages from round buttons.
@MainActor
final class NewDrawerUITests: XCTestCase {
    func testPlannedOpensItsPage() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // `straightToChat` ends with the classic drawer for the older tests; this one wants the new.
        app.launchArguments = XCUIApplication.straightToChat
            + ["-echo.demo", "-transport", "chatCompletions"]
        app.launch()
        try XCTSkipIf(app.windows.firstMatch.frame.width > 600, "iPad keeps the list in the sidebar")
        XCTAssertTrue(app.buttons["Conversations"].waitForExistence(timeout: 15), "The chat never appeared")
        app.buttons["Conversations"].tap()
        let planned = app.buttons["drawer.place.planned"]
        XCTAssertTrue(planned.waitForExistence(timeout: 5), "The drawer has no Planned button")
        XCTAssertFalse(app.segmentedControls.firstMatch.exists, "The new drawer still shows the tabs")
        planned.tap()
        XCTAssertTrue(app.navigationBars["Planned"].waitForExistence(timeout: 5), "Planned didn't open its page")
    }
}
