import XCTest

/// An empty conversation greets and offers the last conversation back.
@MainActor
final class StartScreenUITests: XCTestCase {
    func testTheContinueCardReopensTheLastConversation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoShort"] + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        app.launch()
        let reply = app.text(containing: "I've added a reminder")
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "The demo reply didn't appear")

        // A new conversation: the greeting, and the one just left as a card.
        app.navigationBars.buttons["New conversation"].firstMatch.tap()
        XCTAssertTrue(app.text(containing: "look into?").waitForExistence(timeout: 5),
                      "No greeting on an empty conversation")
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Continue: What's on my calendar tomorrow")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "No card for the conversation just left")

        card.tap()
        XCTAssertTrue(reply.waitForExistence(timeout: 5), "The card didn't reopen the conversation")
    }
}
