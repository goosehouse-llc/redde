import XCTest

/// Settings search (2026-11-25): a setting found by its name opens its page scrolled to its row,
/// and one of the first screen's puts the search away and scrolls there. Needs no server.
@MainActor
final class SettingsSearchUITests: XCTestCase {
    private func openSettings() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.screen", "settings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20), "Settings didn't open")
        return app
    }

    private func search(_ app: XCUIApplication, for text: String) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "No search field on Settings")
        field.tap()
        field.typeText(text)
    }

    func testAResultOpensItsPageOnTheRow() {
        let app = openSettings()
        search(app, for: "stop phrases")
        let hit = app.buttons["settings-hit-stopPhrases"]
        XCTAssertTrue(hit.waitForExistence(timeout: 5), "Stop phrases wasn't found")
        hit.tap()
        XCTAssertTrue(app.navigationBars["Voice"].waitForExistence(timeout: 5), "Voice didn't open")
        // Halfway down Voice, under the voices and languages: scrolled to.
        let row = app.staticTexts["Stop phrases"]
        let there = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: row)
        wait(for: [there], timeout: 4)
    }

    func testARowOfTheFirstScreenIsScrolledTo() {
        let app = openSettings()
        search(app, for: "acknowledg")
        let hit = app.buttons["settings-hit-acknowledgements"]
        XCTAssertTrue(hit.waitForExistence(timeout: 5), "Acknowledgements wasn't found")
        hit.tap()
        XCTAssertFalse(app.buttons["settings-hit-acknowledgements"].waitForExistence(timeout: 1), "The results stayed")
        let row = app.buttons["Acknowledgements"]
        let there = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: row)
        wait(for: [there], timeout: 4)
    }

    func testWordsBehindAScreenFindIt() {
        let app = openSettings()
        search(app, for: "keep calls on")
        XCTAssertTrue(app.buttons["settings-hit-voiceMode.0"].waitForExistence(timeout: 5),
                      "Keep Calls On When Locked, behind Voice mode, wasn't found")
    }
}
