import XCTest

/// "New conversation in voice mode" (GitHub issue 14): coming into voice mode from outside the
/// chat starts a new conversation; the Talk button in a chat carries that chat on. On the demo
/// conversation, so no server is needed.
@MainActor
final class VoiceFreshStartUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func launch(_ extra: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoShort", "-newConversationForVoice", "YES", "-handsFreeByDefault", "NO"]
            + extra + XCUIApplication.straightToChat
        app.launch()
        return app
    }

    /// The demo conversation's first message, in the transcript.
    private func question(_ app: XCUIApplication) -> XCUIElement {
        app.text(containing: "What's on my calendar tomorrow")
    }

    /// The start screen, shown only on an empty conversation. (Its Continue card names the last
    /// one, so the question alone doesn't tell the two apart.)
    private func startScreen(_ app: XCUIApplication) -> XCUIElement {
        app.text(containing: "What should Redde look into")
    }

    /// The voice screen is up; back to the chat. Listening may ask for the microphone first.
    private func backToTyping(_ app: XCUIApplication) {
        let typing = app.buttons["Switch to typing"]
        for _ in 0 ..< 3 where !typing.waitForExistence(timeout: 8) {
            for label in ["Allow", "OK"] where springboard.alerts.buttons[label].exists { springboard.alerts.buttons[label].tap() }
        }
        XCTAssertTrue(typing.exists, "The voice screen didn't open")
        typing.tap()
        XCTAssertTrue(typing.waitForNonExistence(timeout: 8), "The voice screen didn't close")
    }

    func testTheTalkButtonInAChatCarriesThatChatOn() {
        let app = launch([])
        XCTAssertTrue(question(app).waitForExistence(timeout: 30), "The demo conversation isn't on screen")
        let talk = app.buttons["Talk"]
        XCTAssertTrue(talk.waitForExistence(timeout: 5), "No Talk button beside the message field")
        talk.tap()
        backToTyping(app)
        XCTAssertTrue(question(app).waitForExistence(timeout: 5), "Not back on the chat")
        XCTAssertFalse(startScreen(app).exists, "The Talk button started a new conversation")
    }

    func testVoiceModeFromOutsideStartsANewConversation() {
        // `-echo.voiceView` opens voice mode as a launch into it does.
        let app = launch(["-echo.voiceView"])
        backToTyping(app)
        XCTAssertTrue(startScreen(app).waitForExistence(timeout: 5), "Coming into voice mode from outside kept the old conversation")
    }
}
