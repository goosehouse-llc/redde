import XCTest

/// The recipe, delivery, flight, show, conversion and stock cards (asked 2026-10-31), from
/// `-echo.demoCards recipe|delivery|flight|show|conversion|stock`. `TEST_RUNNER_APPEARANCE=dark`
/// draws them dark; `TEST_RUNNER_LINK_PREVIEWS=YES` shows the recipe's picture and the posters
/// (drawn on the phone in the demo). With `TEST_RUNNER_SHOT_DIR` set, the screens are written there
/// too (`SHOT_NAME` before each name), for looking at.
@MainActor
final class NewestCardsUITests: XCTestCase {
    private var look: String { ProcessInfo.processInfo.environment["APPEARANCE"] ?? "light" }

    private func launch(_ kind: String, waitingFor text: String) -> XCUIApplication {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoCards", kind, "-openToVoiceScreen", "NO", "-listenOnOpen", "NO", "-requireBiometrics", "NO",
                               "-appearance", look, "-linkPreviews", environment["LINK_PREVIEWS"] ?? "NO"]
        app.launch()
        // A simulator never set up offers setup first: skipped, the demo is under it.
        if app.buttons["Skip"].waitForExistence(timeout: 4) { app.buttons["Skip"].tap() }
        XCTAssertTrue(app.text(containing: text).waitForExistence(timeout: 20), "The demo reply didn't appear")
        return app
    }

    private func scrollUp(_ app: XCUIApplication, until element: XCUIElement) {
        for _ in 0 ..< 6 where !element.isHittable { app.windows.firstMatch.swipeDown() }
        sleep(1)
    }

    private func scrollDown(_ app: XCUIApplication, until element: XCUIElement) {
        for _ in 0 ..< 6 where !element.isHittable { app.windows.firstMatch.swipeUp() }
        sleep(1)
    }

    func testARecipeScalesTicksAndAsks() {
        let app = launch("recipe", waitingFor: "about 30 minutes")
        scrollUp(app, until: app.text(containing: "Tomato and Basil Spaghetti"))
        shot(app, "recipe-top")
        let servings = app.otherElements["Servings"].firstMatch.exists ? app.otherElements["Servings"].firstMatch
            : app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Servings")).firstMatch
        XCTAssertTrue(servings.exists, "No servings control")
        scrollDown(app, until: servings)
        app.windows.firstMatch.swipeUp()
        sleep(1)
        servings.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        servings.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["18 oz spaghetti"].waitForExistence(timeout: 5), "Six servings didn't work the amounts out again")
        XCTAssertTrue(app.buttons["¾ tsp red pepper flakes"].exists, "A fraction didn't scale")
        app.buttons["18 oz spaghetti"].tap()
        sleep(1)
        shot(app, "recipe-scaled")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Steps")).firstMatch.tap()
        XCTAssertTrue(app.text(containing: "Crush the tomatoes").waitForExistence(timeout: 5), "The steps don't show")
        scrollDown(app, until: app.buttons["Shopping list"])
        shot(app, "recipe-steps")
        app.buttons["Shopping list"].tap()
        XCTAssertTrue(app.text(containing: "Make a shopping list for the Tomato").waitForExistence(timeout: 5), "The chip didn't send its message")
        XCTAssertTrue(app.text(containing: "Asked: Shopping list").waitForExistence(timeout: 5))
    }

    func testDeliveriesTrackAndCopy() {
        let app = launch("delivery", waitingFor: "It came yesterday")
        shot(app, "delivery-bottom")
        scrollUp(app, until: app.text(containing: "Aurora Q5 headphones"))
        XCTAssertTrue(app.buttons["Track at UPS"].exists || app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Track at UPS")).firstMatch.exists,
                      "No link to the carrier")
        XCTAssertTrue(app.buttons["Copy tracking number"].firstMatch.exists, "No Copy")
        shot(app, "delivery-top")
        app.buttons["All updates (4)"].tap()
        XCTAssertTrue(app.text(containing: "Label created").waitForExistence(timeout: 5), "The older scans don't open")
        shot(app, "delivery-history")
    }

    func testFlightsInTheirOwnTimeAndRefresh() {
        let app = launch("flight", waitingFor: "Both flights are on schedule")
        XCTAssertTrue(app.text(containing: "Layover in Newark").exists, "The layover isn't said")
        shot(app, "flight-trip")
        scrollUp(app, until: app.text(containing: "Northwind Air NW 238"))
        XCTAssertTrue(app.text(containing: "Delayed").exists, "The delay isn't shown")
        shot(app, "flight-delayed")
        let refresh = app.buttons["Refresh"].firstMatch
        scrollDown(app, until: refresh)
        refresh.tap()
        XCTAssertTrue(app.text(containing: "Asked: Refresh").waitForExistence(timeout: 5), "Refresh didn't ask the agent")
    }

    func testShowsOpenInPlaceAndAsk() {
        let app = launch("show", waitingFor: "closest match")
        scrollUp(app, until: app.text(containing: "Something like what you liked"))
        shot(app, "show-top")
        let row = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Paper Moons")).firstMatch
        scrollDown(app, until: row)
        app.windows.firstMatch.swipeUp()
        sleep(1)
        row.tap()
        XCTAssertTrue(app.text(containing: "Directed by Lea Brandt").waitForExistence(timeout: 5), "The row didn't open")
        scrollDown(app, until: app.buttons["Similar picks"])
        shot(app, "show-open")
        app.buttons["Similar picks"].tap()
        XCTAssertTrue(app.text(containing: "More like The Quiet Floor").waitForExistence(timeout: 5), "The chip didn't send its message")
    }

    func testConversionsWorkOutAgain() {
        let app = launch("conversion", waitingFor: "About 177")
        shot(app, "conversion-bottom")
        scrollUp(app, until: app.text(containing: "Miles to kilometers"))
        XCTAssertTrue(app.text(containing: "8.05").exists, "5 mi isn't 8.05 km")
        let field = app.textFields["conversion.amount"].firstMatch
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "100")
        XCTAssertTrue(app.text(containing: "160.9").waitForExistence(timeout: 5), "100 mi wasn't worked out again")
        shot(app, "conversion-top")
    }

    func testStocksWithTheirLines() {
        let app = launch("stock", waitingFor: "Kestrel slipped")
        shot(app, "stock-bottom")
        scrollUp(app, until: app.text(containing: "Northwind Systems"))
        XCTAssertTrue(app.text(containing: "As of").exists, "When the price was read isn't said")
        shot(app, "stock-top")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let screen = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screen)
        attachment.name = name + "-" + look
        attachment.lifetime = .keepAlways
        add(attachment)
        let environment = ProcessInfo.processInfo.environment
        if let folder = environment["SHOT_DIR"] {
            try? screen.pngRepresentation.write(to: URL(fileURLWithPath: folder).appending(path: (environment["SHOT_NAME"] ?? "") + name + "-" + look + ".png"))
        }
    }
}
