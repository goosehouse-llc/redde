import XCTest

/// Copying a reply says so, and a tool step opens onto what it returned. Taps are the point, so
/// these run in the app.
@MainActor
final class ReplyActionsUITests: XCTestCase {
    private func launchDemo() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoShort", "-conversations.section", "sessions", "-setupDone", "YES", "-openToVoiceScreen", "NO",
                               "-listenOnOpen", "NO", "-requireBiometrics", "NO"]
        app.launch()
        return app
    }

    private func text(_ app: XCUIApplication, containing fragment: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    func testCopySaysSo() {
        let app = launchDemo()
        XCTAssertTrue(text(app, containing: "I've added a reminder").waitForExistence(timeout: 15), "The demo reply didn't appear")
        // The actions sit under a finished reply without being asked for.
        XCTAssertTrue(app.buttons["Regenerate"].waitForExistence(timeout: 3), "No actions under the reply")

        app.buttons["Copy reply"].tap()
        let toast = app.staticTexts["Copied"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "No toast after copying")
        XCTAssertTrue(app.buttons["Copied"].exists, "The copy button didn't turn into a check")
        let composer = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        XCTAssertLessThan(toast.frame.maxY, composer.frame.minY, "The toast sits under the composer")
    }

    func testAToolStepOpensOntoWhatItReturned() {
        let app = launchDemo()
        let steps = app.buttons["Show tool steps"]
        XCTAssertTrue(steps.waitForExistence(timeout: 15), "No steps card on the demo reply")
        steps.tap()

        let step = app.buttons["Tool calendar, completed"]
        XCTAssertTrue(step.waitForExistence(timeout: 3), "The card didn't open onto its steps")
        XCTAssertFalse(text(app, containing: "Standup").exists, "A step's output is showing before it is opened")
        step.tap()
        XCTAssertTrue(text(app, containing: "Standup").waitForExistence(timeout: 3), "The step didn't open onto its output")
        XCTAssertTrue(app.buttons["Open full output"].exists)

        app.buttons["Open full output"].tap()
        XCTAssertTrue(app.navigationBars["calendar"].waitForExistence(timeout: 3), "The full output didn't open")
    }
}
