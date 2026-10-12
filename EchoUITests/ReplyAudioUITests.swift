import XCTest

/// A reply that came with a sound file shows a player where the file's path used to be, and the
/// player plays. `-echo.demoAudio` supplies the reply; no server is needed.
@MainActor
final class ReplyAudioUITests: XCTestCase {
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testASoundInAReplyPlaysWhereItStands() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoAudio"] + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        app.launch()
        XCTAssertTrue(app.text(containing: "read aloud").waitForExistence(timeout: 20), "The demo reply didn't appear")
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), "No player under the reply")
        XCTAssertTrue(app.staticTexts["0:04"].waitForExistence(timeout: 5), "The player doesn't say how long the sound is")
        XCTAssertFalse(app.text(containing: "summary.wav").exists, "The file's name is shown where a player should be")
        shot("audio at rest")

        play.tap()
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 3), "Play didn't start it")
        shot("audio playing")
        pause.tap()
        XCTAssertTrue(play.waitForExistence(timeout: 3), "Pause didn't hold it")
    }
}
