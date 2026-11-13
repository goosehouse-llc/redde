import XCTest

/// Removing a saved server asks first (2026-11-13): it deletes the server's keys and passwords too.
@MainActor
final class ServerRemoveUITests: XCTestCase {
    private let spare = "UITest Spare"

    func testRemovingAServerAsksFirst() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.demo", "-echo.spareServer", spare, "-echo.screen", "servers"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Servers"].waitForExistence(timeout: 15), "The Servers screen didn't open")
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", spare)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The spare server isn't listed")

        // Asked, and Cancel keeps it.
        row.swipeLeft()
        app.buttons["Remove"].firstMatch.tap()
        let question = app.staticTexts["Remove “\(spare)”?"]
        XCTAssertTrue(question.waitForExistence(timeout: 5), "Removing a server didn't ask first")
        XCTAssertTrue(app.text(containing: "keys and passwords are deleted").exists, "The question doesn't say what goes")
        // iOS 26 shows the question as a popover with no Cancel: a tap outside it cancels.
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists && cancel.isHittable { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap() }
        XCTAssertTrue(question.waitForNonExistence(timeout: 5))
        XCTAssertTrue(row.exists, "Cancel removed the server anyway")

        // Asked again, and Remove takes it out.
        row.swipeLeft()
        app.buttons["Remove"].firstMatch.tap()
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        let confirm = app.buttons.matching(identifier: "Remove").allElementsBoundByIndex.last { $0.isHittable }
        XCTAssertNotNil(confirm, "No Remove in the question")
        confirm?.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "Remove left the server behind")
    }
}
