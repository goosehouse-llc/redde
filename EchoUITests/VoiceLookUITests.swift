import XCTest

/// The camera button on the voice screen. The simulator has no camera, so `-echo.voiceLook`
/// gives voice mode a made-up one: enough to see the button, the viewfinder taking the orb's
/// place and the line that says what happens. A real camera's picture takes a phone.
@MainActor
final class VoiceLookUITests: XCTestCase {
    private func launch(_ extra: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoShort", "-echo.voiceView"] + extra + XCUIApplication.straightToChat
        app.launch()
        XCTAssertTrue(app.buttons["Switch to typing"].waitForExistence(timeout: 30), "The voice screen didn't open")
        return app
    }

    private func camera(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Camera")).firstMatch
    }

    func testTheCameraButtonOpensAViewfinderWhereTheOrbWas() {
        let app = launch(["-echo.voiceLook"])
        let camera = camera(app)
        XCTAssertTrue(camera.waitForExistence(timeout: 5), "No camera button on the voice screen")
        let says = app.text(containing: "goes with a picture of what the camera sees")
        XCTAssertFalse(says.exists)
        camera.tap()
        XCTAssertTrue(says.waitForExistence(timeout: 5), "Nothing says the camera is on")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "voice-look"
        shot.lifetime = .keepAlways
        add(shot)
        camera.tap()
        XCTAssertTrue(says.waitForNonExistence(timeout: 5), "The camera didn't switch off")
    }

    func testWithNoCameraThereIsNoButton() {
        let app = launch([])
        XCTAssertFalse(camera(app).exists, "The simulator has no camera, and none should be offered")
    }
}
