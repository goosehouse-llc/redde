import XCTest

/// GitHub issue 21: a card's question, a share and a Siri draft can start a new conversation
/// instead of going into the open one. On the demo conversation, with no server: the OpenAI-
/// compatible connection pointed at nothing, so a question is sent (and fails) without one.
@MainActor
final class NewConversationEntryUITests: XCTestCase {
    private func launch(_ extra: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoShort", "-echo.clearDrafts",
                               "-transport", "chatCompletions", "-fastLaneURL", "http://127.0.0.1:9", "-fastLaneModel", "test"]
            + extra + XCUIApplication.straightToChat
        app.launch()
        return app
    }

    /// Drafts outlast the app, and other tests start from an empty message field: what a share or
    /// a Siri draft left here would be in front of their text. And the card's conversation goes,
    /// so the next run starts as this one did. (Not through the list: its question waits to be
    /// sent, and each try at sending it closes the list.)
    override func tearDownWithError() throws {
        MainActor.assumeIsolated {
            let app = XCUIApplication()
            app.launchArguments = ["-echo.clearDrafts", "-echo.forget", "About kanban card"] + XCUIApplication.straightToChat
            app.launch()
            _ = app.textFields.firstMatch.waitForExistence(timeout: 10)
            sleep(1)
            app.terminate()
        }
    }

    /// The demo conversation's first message, in the transcript.
    private func question(_ app: XCUIApplication) -> XCUIElement {
        app.text(containing: "What's on my calendar tomorrow")
    }

    /// The start screen, shown only on an empty conversation.
    private func startScreen(_ app: XCUIApplication) -> XCUIElement {
        app.text(containing: "What should Redde look into")
    }

    /// What the message field holds, once it holds `fragment`.
    private func composerHolds(_ fragment: String, in app: XCUIApplication) -> Bool {
        let field = app.textFields.firstMatch
        guard field.waitForExistence(timeout: 20) else { return false }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if (field.value as? String)?.contains(fragment) == true { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    func testACardAskedInANewConversationLeavesTheOpenOne() {
        let app = launch(["-echo.demoKanban", "-echo.screen", "sessions", "-echo.section", "kanban"])
        let card = app.text(containing: "Compare heat pump quotes")
        XCTAssertTrue(card.waitForExistence(timeout: 20), "The demo board isn't on screen")
        card.tap()
        let fresh = app.buttons["Ask in a new conversation"]
        XCTAssertTrue(fresh.waitForExistence(timeout: 10), "No way to ask in a new conversation")
        XCTAssertTrue(app.text(containing: "Ask in the open conversation").exists, "No way to ask in the open one")
        fresh.tap()
        XCTAssertTrue(app.text(containing: "About kanban card").waitForExistence(timeout: 10), "The card's question wasn't sent")
        XCTAssertFalse(question(app).exists, "It went into the open conversation")
    }

    func testACardAskedInTheOpenConversationStaysThere() {
        let app = launch(["-echo.demoKanban", "-echo.screen", "sessions", "-echo.section", "kanban"])
        let card = app.text(containing: "Compare heat pump quotes")
        XCTAssertTrue(card.waitForExistence(timeout: 20), "The demo board isn't on screen")
        card.tap()
        let open = app.text(containing: "Ask in the open conversation")
        XCTAssertTrue(open.waitForExistence(timeout: 10), "No way to ask in the open conversation")
        open.tap()
        XCTAssertTrue(app.text(containing: "About kanban card").waitForExistence(timeout: 10), "The card's question wasn't sent")
        XCTAssertTrue(question(app).exists, "It didn't go into the open conversation")
    }

    func testAShareWithNewConversationWaitsInANewOne() {
        let app = launch(["-echo.shareNew", "Shared from Safari"])
        XCTAssertTrue(startScreen(app).waitForExistence(timeout: 20), "The share kept the old conversation")
        XCTAssertTrue(composerHolds("Shared from Safari", in: app), "The share isn't in the new conversation's message field")
        // Back in the one it left (the start screen's Continue card): the share didn't stay
        // behind as its draft too.
        let back = app.text(containing: "Continue: What's on my calendar tomorrow")
        XCTAssertTrue(back.waitForExistence(timeout: 10), "No way back to the conversation it left")
        back.tap()
        XCTAssertTrue(question(app).waitForExistence(timeout: 10), "The demo conversation didn't open")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "No message field")
        XCTAssertFalse((field.value as? String)?.contains("Shared from Safari") == true, "The share stayed behind in the old conversation too")
    }

    func testAShareWithoutItWaitsInTheOpenOne() {
        let app = launch(["-echo.share", "Shared from Safari"])
        XCTAssertTrue(composerHolds("Shared from Safari", in: app), "The share isn't in the message field")
        XCTAssertTrue(question(app).exists, "The share left the open conversation")
    }

    func testASiriDraftWaitsInANewConversationWhenSoSet() {
        let app = launch(["-siriAIEnabled", "YES", "-siriDraftsInNewConversation", "YES", "-echo.siriDraft", "Drafted by Siri"])
        XCTAssertTrue(startScreen(app).waitForExistence(timeout: 20), "The draft kept the old conversation")
        XCTAssertTrue(composerHolds("Drafted by Siri", in: app), "The draft isn't in the new conversation's message field")
    }
}
