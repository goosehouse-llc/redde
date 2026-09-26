import XCTest

/// iPhone: a swipe to the right on the chat opens the conversation list, and the transcript
/// still scrolls up and down.
@MainActor
final class SwipeToConversationsUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-setupDone", "YES", "-openToVoiceScreen", "NO", "-listenOnOpen", "NO",
                               "-requireBiometrics", "NO", "-transport", "chatCompletions"]
        app.launch()
        return app
    }

    private func drag(_ app: XCUIApplication, from: CGVector, to: CGVector) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: from)
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: to), withVelocity: .fast,
                   thenHoldForDuration: 0)
    }

    func testSwipeRightOpensConversations() throws {
        let app = launch()
        try XCTSkipIf(app.windows.firstMatch.frame.width > 600, "iPad keeps the list in the sidebar")
        XCTAssertTrue(app.buttons["Conversations"].waitForExistence(timeout: 15), "The chat never appeared")
        drag(app, from: CGVector(dx: 0.1, dy: 0.45), to: CGVector(dx: 0.9, dy: 0.47))
        XCTAssertTrue(app.navigationBars["Conversations"].waitForExistence(timeout: 5), "Swiping right didn't open the list")
    }

    func testVerticalScrollDoesNotOpenConversations() throws {
        let app = launch()
        try XCTSkipIf(app.windows.firstMatch.frame.width > 600, "iPad keeps the list in the sidebar")
        XCTAssertTrue(app.buttons["Conversations"].waitForExistence(timeout: 15), "The chat never appeared")
        drag(app, from: CGVector(dx: 0.4, dy: 0.3), to: CGVector(dx: 0.5, dy: 0.7))
        XCTAssertFalse(app.navigationBars["Conversations"].waitForExistence(timeout: 2), "A scroll opened the list")
    }
}
