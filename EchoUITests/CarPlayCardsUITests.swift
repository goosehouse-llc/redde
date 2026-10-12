import XCTest

/// Settings → Appearance → CarPlay cards: the six looks of the car's Ask tab, each shown as the
/// three pictures the car is given. Needs no server and no car.
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
}
