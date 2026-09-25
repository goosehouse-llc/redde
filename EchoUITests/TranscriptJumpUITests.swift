import XCTest

/// The jump-to-bottom arrow has to bring back the newest message after fast flings. XCUITest waits
/// for the list to settle before each tap, so a tap during momentum can't be simulated here;
/// these cover what broke it: the arrow vanishing mid-fling and long jumps landing short.
@MainActor
final class TranscriptJumpUITests: XCTestCase {
    private func launchLongDemo() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Launch arguments land in UserDefaults' argument domain: skip setup, stay on the transcript.
        app.launchArguments = ["-echo.demoLong", "-setupDone", "YES", "-openToVoiceScreen", "NO",
                               "-listenOnOpen", "NO", "-requireBiometrics", "NO"]
        app.launch()
        XCTAssertTrue(app.staticTexts["End of the long demo."].waitForExistence(timeout: 15), "The long demo didn't open at its end")
        return app
    }

    func testJumpArrowReachesTheEndAtRest() {
        let app = launchLongDemo()
        let end = app.staticTexts["End of the long demo."]
        let transcript = app.scrollViews.firstMatch
        transcript.swipeDown(velocity: .fast)
        transcript.swipeDown(velocity: .fast)
        let jump = app.buttons["Jump to the newest message"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "No jump arrow after scrolling up")
        jump.tap()
        XCTAssertTrue(end.waitForExistence(timeout: 5), "The arrow didn't bring back the newest message")
        XCTAssertTrue(end.isHittable, "The newest message exists but isn't on screen")
    }

    func testJumpArrowReachesTheEndAfterLongFlings() {
        let app = launchLongDemo()
        let end = app.staticTexts["End of the long demo."]
        let transcript = app.scrollViews.firstMatch

        // Read back up the transcript so the arrow appears.
        transcript.swipeDown(velocity: .fast)
        transcript.swipeDown(velocity: .fast)
        let jump = app.buttons["Jump to the newest message"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "No jump arrow after scrolling up")
        // A screen point captured earlier, so the tap goes where the arrow was even if it vanished.
        let frame = jump.frame
        let target = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY))

        // Fling far up the transcript, then hit the arrow.
        transcript.swipeDown(velocity: 3000)
        target.tap()

        XCTAssertTrue(end.waitForExistence(timeout: 5), "The arrow didn't bring back the newest message")
        XCTAssertTrue(end.isHittable, "The newest message exists but isn't on screen")
    }
}
