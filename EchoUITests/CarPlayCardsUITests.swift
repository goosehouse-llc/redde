import XCTest

/// Settings → Appearance → CarPlay cards and CarPlay voice screen: the looks of the car's Ask tab
/// and of its voice card, each shown as the pictures the car is given. Needs no server and no car.
@MainActor
final class CarPlayCardsUITests: XCTestCase {
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

    func testALookForTheCarsCardsIsPickedInSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.screen", "settings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20), "Settings didn't open")
        let row = app.staticTexts["CarPlay cards"]
        reach(row, in: app, "The CarPlay cards row")
        row.tap()

        func look(_ name: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch }
        let glow = look("Glow"), color = look("Color")
        reach(glow, in: app, "Glow")
        XCTAssertTrue(color.exists, "The looks aren't listed")
        for name in ["Orb", "Gold", "Graphite", "Marks"] { XCTAssertTrue(look(name).exists, "\(name) isn't listed") }
        glow.tap()
        XCTAssertTrue(glow.isSelected, "Glow wasn't picked")
        XCTAssertFalse(color.isSelected)
        shot("carplay cards")

        // Back to the look a new install has, for whatever runs next.
        color.tap()
        XCTAssertTrue(color.isSelected)
    }

    /// Settings → Appearance → CarPlay voice screen: the four looks of the car's voice card,
    /// each shown as its Listening, Thinking and Speaking pictures.
    func testALookForTheCarsVoiceScreenIsPickedInSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.screen", "settings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20), "Settings didn't open")
        let row = app.staticTexts["CarPlay voice screen"]
        reach(row, in: app, "The CarPlay voice screen row")
        row.tap()

        // By name in the code: "Orb" is also how the Orb light row and a look of the cards begin.
        func look(_ name: String) -> XCUIElement { app.buttons["carplay-voice-\(name)"] }
        let bars = look("bars"), orb = look("orb")
        reach(bars, in: app, "Bars")
        XCTAssertTrue(bars.isSelected, "A new install has the bars")
        XCTAssertTrue(bars.label.hasPrefix("Bars"), "Bars reads “\(bars.label)”")
        shot("carplay voice screen, bars")
        for name in ["lamps", "kitt", "orb"] {
            reach(look(name), in: app, name)
            XCTAssertFalse(look(name).isSelected)
        }
        XCTAssertTrue(look("kitt").label.hasPrefix("KITT"), "KITT reads “\(look("kitt").label)”")
        orb.tap()
        XCTAssertTrue(orb.isSelected, "Orb wasn't picked")
        // Long enough for the picked look's loops to be drawn and start playing.
        _ = app.staticTexts["nothing by this name"].waitForExistence(timeout: 2)
        shot("carplay voice screen, orb")

        // Back to the look a new install has, for whatever runs next.
        for _ in 0 ..< 6 where !(bars.exists && bars.isHittable) { app.swipeDown() }
        bars.tap()
        XCTAssertTrue(bars.isSelected)
        XCTAssertFalse(orb.exists && orb.isSelected)
    }
}
