import XCTest

/// Settings → Connection details → Custom headers: a header is added with its value hidden, shows
/// by name with a way to remove it, and is gone once removed. Needs no server.
@MainActor
final class CustomHeadersUITests: XCTestCase {
    func testAddingAndRemovingAHeader() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.screen", "settings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20), "Settings didn't open")
        let details = app.buttons["Connection details"]
        for _ in 0 ..< 8 where !(details.exists && details.isHittable) { app.swipeUp() }
        details.tap()

        let name = app.textFields["Header name"]
        for _ in 0 ..< 8 where !(name.exists && name.isHittable) { app.swipeUp() }
        XCTAssertTrue(name.exists, "No custom headers section")
        let row = app.staticTexts["X-Redde-UI-Test"]
        XCTAssertFalse(row.exists, "A header from an earlier run is still there")

        // A name that can't be a header is turned down, and says why.
        name.tap()
        name.typeText("Host")
        let value = app.secureTextFields["Value"]
        value.tap()
        value.typeText("elsewhere")
        app.buttons["Add header"].tap()
        XCTAssertTrue(app.text(containing: "set by the connection itself").waitForExistence(timeout: 5))

        name.tap()
        name.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 3) { app.menuItems["Select All"].tap() }
        name.typeText("X-Redde-UI-Test")
        app.buttons["Add header"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The header wasn't added")
        XCTAssertFalse(app.text(containing: "elsewhere").exists, "The value is on screen")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "custom header added"
        shot.lifetime = .keepAlways
        add(shot)

        app.buttons["Remove"].firstMatch.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "The header wasn't removed")
    }
}
