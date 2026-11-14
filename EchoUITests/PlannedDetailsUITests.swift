import XCTest

/// A long press on something Planned holds up its details (asked 2026-11-07), and Details opens the
/// job's full page.
@MainActor
final class PlannedDetailsUITests: XCTestCase {
    func testALongPressShowsTheDetails() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoPlanned", "-echo.screen", "sessions", "-echo.drawerPage", "planned"]
            + XCUIApplication.straightToChat
        app.launch()
        let row = app.text(containing: "The price of the blue kettle")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Planned didn't show the demo week")
        row.press(forDuration: 1.0)
        // (a context menu's preview reads as plain elements, not static texts)
        let prompt = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "below $120")).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "The long press didn't show the job's prompt")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "planned-details"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["Details"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForExistence(timeout: 5), "Details didn't open the job's page")
        let page = XCTAttachment(screenshot: app.screenshot())
        page.name = "job-page"
        page.lifetime = .keepAlways
        add(page)
    }
}
