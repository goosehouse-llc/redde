import XCTest

/// iPad regression: opening a project folder from the sidebar and tapping one of its sessions.
/// The folder list lives in the split view's sidebar column, which is a different navigation
/// container from the iPhone sheet, and the row taps stopped working there.
@MainActor
final class ProjectFolderUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoProjects", "-setupDone", "YES", "-openToVoiceScreen", "NO",
                               "-listenOnOpen", "NO", "-requireBiometrics", "NO"]
        app.launch()
        return app
    }

    func testProjectFolderOpensAndSessionRowResponds() {
        let app = launch()
        // Row labels are combined from the whole cell, so match on the leading title.
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Echo,'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 15), "The Projects section never appeared in the sidebar")
        folder.tap()

        // The folder has to push its own screen. Matching on the title alone isn't enough:
        // the same session titles also sit in the Recent section of the list underneath.
        let pushed = app.navigationBars["Echo"]
        XCTAssertTrue(pushed.waitForExistence(timeout: 10),
                      "Tapping the project folder didn't open it; the sidebar stayed on the session list")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Transcript scrolling'")).firstMatch
                        .waitForExistence(timeout: 5), "The project folder opened but showed no sessions")
    }

    func testProjectFolderCanBeLeftAgain() {
        let app = launch()
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Echo,'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 15), "The Projects section never appeared in the sidebar")
        folder.tap()
        XCTAssertTrue(app.navigationBars["Echo"].waitForExistence(timeout: 10), "The project folder didn't open")
        // Without a way back the only escape was force-quitting the app.
        let back = app.navigationBars["Echo"].buttons.firstMatch
        XCTAssertTrue(back.exists && back.isHittable, "No back button out of the project folder")
        back.tap()
        XCTAssertTrue(app.navigationBars["Conversations"].waitForExistence(timeout: 10), "Back didn't return to the session list")
    }
}
