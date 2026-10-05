import XCTest

/// An empty conversation greets and offers the last conversation back.
@MainActor
final class StartScreenUITests: XCTestCase {
    func testTheContinueCardReopensTheLastConversation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoShort", "-conversations.section", "sessions", "-setupDone", "YES", "-openToVoiceScreen", "NO",
                               "-listenOnOpen", "NO", "-requireBiometrics", "NO"]
        app.launch()
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "I've added a reminder")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "The demo reply didn't appear")

        // A new conversation: the greeting, and the one just left as a card.
        app.navigationBars.buttons["New conversation"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "look into?")).firstMatch.waitForExistence(timeout: 5),
                      "No greeting on an empty conversation")
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Continue: What's on my calendar tomorrow")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "No card for the conversation just left")

        card.tap()
        XCTAssertTrue(reply.waitForExistence(timeout: 5), "The card didn't reopen the conversation")
    }
}
