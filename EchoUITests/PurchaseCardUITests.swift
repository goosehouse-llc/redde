import XCTest

/// The purchase card (asked 2026-10-30): the pick with View at its store, the others as rows that
/// open in place to their pros, cons and specs, and the chips that ask the agent for more.
/// `-echo.demoCards purchase` supplies the reply. With `TEST_RUNNER_SHOT_DIR` set, the screens are
/// written there too (`SHOT_NAME` before each name), for looking at; `TEST_RUNNER_LINK_PREVIEWS=YES`
/// shows the products' pictures (drawn on the phone in the demo).
@MainActor
final class PurchaseCardUITests: XCTestCase {
    func testThePickTheRowsAndTheChips() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoCards", "purchase", "-openToVoiceScreen", "NO", "-listenOnOpen", "NO", "-requireBiometrics", "NO",
                               "-linkPreviews", environment["LINK_PREVIEWS"] ?? "NO"]
        app.launch()
        XCTAssertTrue(app.text(containing: "Aurora Q5 is the one").waitForExistence(timeout: 20), "The demo reply didn't appear")
        XCTAssertTrue(app.buttons["Cheaper options"].exists, "The chips aren't there")
        shot(app, "bottom")

        let window = app.windows.firstMatch
        for _ in 0 ..< 4 where !app.text(containing: "Noise-cancelling headphones under").isHittable { window.swipeDown() }
        XCTAssertTrue(app.buttons["View at Best Buy"].exists, "The pick can't be opened at its store")
        sleep(1)
        shot(app, "top")

        // A row opens in place to its pros, cons and specs.
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Tidal Air 3")).firstMatch
        XCTAssertTrue(row.exists, "The other products aren't rows")
        row.tap()
        XCTAssertTrue(app.buttons["View at Amazon"].waitForExistence(timeout: 5), "The row didn't open")
        XCTAssertTrue(app.text(containing: "Folds flat").exists, "Its pros aren't shown")
        for _ in 0 ..< 2 where !app.buttons["View at Amazon"].isHittable { window.swipeUp() }
        sleep(1)
        shot(app, "open")

        // A chip asks the agent, and the card says what was asked.
        for _ in 0 ..< 3 where !app.buttons["Why this one?"].isHittable { window.swipeUp() }
        app.buttons["Why this one?"].tap()
        XCTAssertTrue(app.text(containing: "Why the Aurora Q5?").waitForExistence(timeout: 5), "The chip didn't send its message")
        XCTAssertTrue(app.text(containing: "Asked: Why this one?").waitForExistence(timeout: 5), "The card doesn't say what was asked")
        XCTAssertFalse(app.buttons["Cheaper options"].exists, "The chips stay after one was tapped")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let screen = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screen)
        attachment.name = "purchase-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
        let environment = ProcessInfo.processInfo.environment
        if let folder = environment["SHOT_DIR"] {
            let file = URL(fileURLWithPath: folder).appending(path: (environment["SHOT_NAME"] ?? "") + name + ".png")
            try? screen.pngRepresentation.write(to: file)
        }
    }
}
