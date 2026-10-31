import XCTest

/// The home, reminder, comparison and score cards (asked 2026-10-30), from `-echo.demoCards
/// home|reminder|compare|score`. With `TEST_RUNNER_SHOT_DIR` set, the screens are written there too
/// (`SHOT_NAME` before each name), for looking at.
@MainActor
final class MoreCardsUITests: XCTestCase {
    private func launch(_ kind: String, waitingFor text: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoCards", kind, "-openToVoiceScreen", "NO", "-listenOnOpen", "NO", "-requireBiometrics", "NO"]
        app.launch()
        XCTAssertTrue(app.text(containing: text).waitForExistence(timeout: 20), "The demo reply didn't appear")
        return app
    }

    private func scrollUp(_ app: XCUIApplication, until element: XCUIElement) {
        for _ in 0 ..< 5 where !element.isHittable { app.windows.firstMatch.swipeDown() }
        sleep(1)
    }

    func testHomeAsksTheAgentAndConfirmsAnUnlock() {
        let app = launch("home", waitingFor: "The garage is closed")
        scrollUp(app, until: app.text(containing: "Downstairs"))
        XCTAssertTrue(app.text(containing: "Kitchen · On · 80%").exists, "A light's state and brightness from 0–255 aren't shown")
        shot(app, "home-top")
        app.buttons["Unlock"].tap()
        XCTAssertTrue(app.buttons["Unlock"].waitForExistence(timeout: 5) && app.staticTexts["Unlock Front door?"].waitForExistence(timeout: 5),
                      "Unlocking didn't ask first")
        shot(app, "home-confirm")
        app.text(containing: "Kitchen · On").coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()   // outside the question: not unlocked
        sleep(1)
        XCTAssertFalse(app.text(containing: "Unlock Front door").exists, "Unlock was sent")
        let toggle = app.switches["Kitchen lights"]
        XCTAssertTrue(toggle.isHittable, "The kitchen's switch isn't on the screen")
        (toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle).tap()
        XCTAssertTrue(app.text(containing: "Turn off Kitchen lights").waitForExistence(timeout: 5), "The switch didn't ask the agent")
        shot(app, "home-asked")
    }

    func testRemindersCountDownAndAskToChange() {
        let app = launch("reminder", waitingFor: "the pasta timer is running")
        scrollUp(app, until: app.text(containing: "Pasta"))
        XCTAssertTrue(app.text(containing: "Ends at").exists, "The timer doesn't say when it ends")
        shot(app, "reminder-top")
        app.windows.firstMatch.swipeUp()
        sleep(1)
        XCTAssertTrue(app.text(containing: "Every Monday at 9 AM").exists, "How it repeats isn't shown")
        app.buttons["Change…"].firstMatch.tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5), "Change… has no field")
        shot(app, "reminder-change")
    }

    func testAComparisonOfTwoAndOfThree() {
        let app = launch("compare", waitingFor: "Madeira, if you want")
        scrollUp(app, until: app.text(containing: "A first language"))
        XCTAssertTrue(app.text(containing: "For you: Python").exists, "The verdict isn't shown")
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Python")).firstMatch.tap()
        XCTAssertTrue(app.text(containing: "Reads almost like English").waitForExistence(timeout: 5), "An option's pros don't open")
        shot(app, "compare-two")
        for _ in 0 ..< 5 where !app.text(containing: "Getting there").isHittable { app.windows.firstMatch.swipeUp() }
        sleep(1)
        shot(app, "compare-three")
    }

    func testGamesOverToComeAndBeingPlayed() {
        let app = launch("score", waitingFor: "Tampa leads")
        XCTAssertTrue(app.buttons["Refresh"].exists, "A live game has no Refresh")
        shot(app, "score-live")
        scrollUp(app, until: app.text(containing: "Final"))
        shot(app, "score-top")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let screen = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screen)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let environment = ProcessInfo.processInfo.environment
        if let folder = environment["SHOT_DIR"] {
            try? screen.pngRepresentation.write(to: URL(fileURLWithPath: folder).appending(path: (environment["SHOT_NAME"] ?? "") + name + ".png"))
        }
    }
}
