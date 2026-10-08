import XCTest

/// Settings → Voice → Notification sound: on until it is turned off, and it stays as set across a
/// launch. Needs no server. Leaves the setting as it found it.
@MainActor
final class NotificationSoundUITests: XCTestCase {
    private func settings() -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.screen", "settings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20), "Settings didn't open")
        let sound = app.switches["Notification sound"]
        for _ in 0 ..< 12 where !(sound.exists && sound.isHittable) { app.swipeUp() }
        XCTAssertTrue(sound.exists && sound.isHittable, "No Notification sound switch in Settings")
        return (app, sound)
    }

    /// The switch itself, inside the row: a tap on the row's middle lands on its label.
    private func flip(_ row: XCUIElement) {
        let knob = row.switches.firstMatch
        (knob.exists ? knob : row).tap()
    }

    func testTheSwitchStaysAsSet() {
        continueAfterFailure = false
        var (app, sound) = settings()
        let before = sound.value as? String
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "notification sound in Settings"
        shot.lifetime = .keepAlways
        add(shot)
        flip(sound)
        let after = sound.value as? String
        XCTAssertNotEqual(before, after, "The switch didn't move")
        app.terminate()

        (app, sound) = settings()
        XCTAssertEqual(sound.value as? String, after, "The setting didn't survive a launch")
        flip(sound)
        XCTAssertEqual(sound.value as? String, before, "The setting wasn't put back")
    }
}
