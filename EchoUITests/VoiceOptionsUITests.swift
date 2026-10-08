import XCTest

/// Settings → Voice → Stop phrases, and voice mode asked for on a named Hermes profile, the way
/// Siri's "Ask Work in Redde" asks (`-echo.askProfile` stands in for Siri). Neither needs a server.
@MainActor
final class VoiceOptionsUITests: XCTestCase {
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func reach(_ element: XCUIElement, in app: XCUIApplication, _ what: String) {
        for _ in 0 ..< 14 where !(element.exists && element.isHittable) { app.swipeUp() }
        XCTAssertTrue(element.exists && element.isHittable, "\(what) isn't on the screen")
    }

    func testAStopPhraseOfYourOwnIsAddedAndRemoved() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.screen", "settings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20), "Settings didn't open")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Stop phrases'")).firstMatch
        reach(row, in: app, "The Stop phrases row")
        row.tap()
        XCTAssertTrue(app.navigationBars["Stop phrases"].waitForExistence(timeout: 10), "The Stop phrases screen didn't open")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'stop listening'")).firstMatch.exists,
                      "The built-in phrases aren't shown")

        let field = app.textFields["Add a phrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let add = app.buttons["Add phrase"]
        XCTAssertFalse(add.isEnabled, "Nothing typed, nothing to add")
        field.tap()
        field.typeText("Stop")
        XCTAssertFalse(add.isEnabled, "A built-in phrase can't be added again")
        field.typeText(" it right there")
        XCTAssertTrue(add.isEnabled)
        add.tap()
        let phrase = app.staticTexts["Stop it right there"]
        XCTAssertTrue(phrase.waitForExistence(timeout: 5), "The phrase isn't in the list")
        XCTAssertEqual(field.value as? String, "Add a phrase", "The field wasn't cleared for the next one")
        shot("stop phrases")

        // The Voice section counts it.
        app.navigationBars["Stop phrases"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Stop phrases' AND (label CONTAINS '+1' OR value CONTAINS '+1')")).firstMatch
            .waitForExistence(timeout: 5), "The row doesn't say a phrase was added")

        // And off again, so the next run starts from none.
        row.tap()
        XCTAssertTrue(phrase.waitForExistence(timeout: 5))
        phrase.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(phrase.waitForNonExistence(timeout: 5), "The phrase wasn't removed")
    }

    func testAskingForAProfileOpensVoiceModeOnIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // The profile in use at the start: the main one.
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.askProfile", "default"]
        app.launch()
        // On the voice screen whatever it is doing (its close button is "Stop" while it listens).
        let end = app.buttons["Switch to typing"]
        XCTAssertTrue(end.waitForExistence(timeout: 60), "Voice mode didn't open")
        app.terminate()

        // "Ask field-notes in Redde".
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.askProfile", "field-notes"]
        app.launch()
        XCTAssertTrue(end.waitForExistence(timeout: 30), "Voice mode didn't open for the profile")
        shot("voice on a profile")
        app.terminate()

        // The app is on that profile now: the picker shows it chosen.
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.screen", "profiles"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 20), "The profile picker didn't open")
        let named = app.buttons["field-notes"]
        XCTAssertTrue(named.waitForExistence(timeout: 5), "The profile asked for by name isn't listed")
        XCTAssertTrue(named.isSelected, "The app didn't move to the profile that was asked for")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Default'")).firstMatch.isSelected)
        shot("profile picker")
        app.terminate()

        // Back to the main profile, and the name forgotten, for whatever runs next.
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.askProfile", "default"]
        app.launch()
        XCTAssertTrue(end.waitForExistence(timeout: 30))
        app.terminate()
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.screen", "profiles"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Default'")).firstMatch.isSelected, "The app isn't back on the main profile")
        XCTAssertTrue(named.waitForExistence(timeout: 5))
        named.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(named.waitForNonExistence(timeout: 5), "The name wasn't forgotten")
    }
}
