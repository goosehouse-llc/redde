import XCTest

/// Bots on the demo roster (`-echo.demoBots`, no server): the chat list's Bots section, a bot's
/// chat named after its bot, and the bots offered while a tag is typed there.
@MainActor
final class BotsUITests: XCTestCase {
    func testTheListShowsTheBotsAndABotsChatOffersTheOthersToTag() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoProjects", "-echo.demoBots", "-echo.clearDrafts", "-displayName", "Redde"]
            + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        app.launch()
        // The open conversation is Quill's chat, and goes by its name.
        XCTAssertTrue(app.text(containing: "tighten the opening").waitForExistence(timeout: 20), "the demo bot's chat isn't open")
        XCTAssertTrue(app.text(containing: "Quill").exists, "the header doesn't name the bot")
        XCTAssertTrue(app.text(containing: "@writer").exists, "the header doesn't give the bot's handle")

        app.buttons["Conversations"].firstMatch.tap()
        XCTAssertTrue(app.text(containing: "Three trails under two hours").waitForExistence(timeout: 10), "Scout's row isn't listed")
        XCTAssertTrue(app.text(containing: "Fix-it").exists, "a bot without a chat yet isn't listed")
        // Below the bots and the group chats: scrolled to, as a list only builds the rows on screen.
        let letThem = app.text(containing: "Let bots message each other")
        if !letThem.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(letThem.waitForExistence(timeout: 3), "nothing offers to let them message each other")
        // The chat beside the panel closes it.
        let close = app.otherElements["Close conversations"].firstMatch
        if close.exists { close.tap() } else { app.buttons["Close conversations"].firstMatch.tap() }

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Ask @")
        let scout = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "@scout")).firstMatch
        XCTAssertTrue(scout.waitForExistence(timeout: 5), "the other bots aren't offered")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "@hermes")).firstMatch.exists, "the main profile isn't offered")
        XCTAssertFalse(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "@quill")).firstMatch.exists, "the bot being talked to is offered")
        field.typeText("fi")
        let fixit = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "@fix-it")).firstMatch
        XCTAssertTrue(fixit.waitForExistence(timeout: 5), "typing doesn't narrow the bots down")
        XCTAssertFalse(scout.exists)
        fixit.tap()
        XCTAssertEqual(field.value as? String, "Ask @fix-it ", "picking a bot doesn't finish the tag")
        XCTAssertFalse(fixit.exists, "the bots are still offered once the tag is finished")
    }

    /// Change Face in New Bot, in a bot's settings and in the main agent's opens the face picker.
    func testChangeFaceInTheBotEditorOpensThePicker() {
        continueAfterFailure = false
        for which in ["new", "scout", "default"] {
            let app = XCUIApplication()
            app.launchArguments = ["-echo.demoProjects", "-echo.demoBots", "-echo.clearDrafts", "-displayName", "Redde",
                                   "-echo.screen", "sessions", "-echo.botEditor", which] + XCUIApplication.chatsSection
            app.launch()
            let change = app.buttons["Change Face"].firstMatch
            XCTAssertTrue(change.waitForExistence(timeout: 20), "\(which): no Change Face")
            change.tap()
            XCTAssertTrue(app.staticTexts["Shape"].firstMatch.waitForExistence(timeout: 5), "\(which): Change Face opened nothing")
            // Redde's own bubble is offered to the main agent alone; the ghost to everyone.
            XCTAssertEqual(app.buttons["Bubble"].firstMatch.exists, which == "default", "\(which): the bubble offered wrongly")
            XCTAssertTrue(app.buttons["Ghost"].firstMatch.exists, "\(which): no ghost")
            app.terminate()
        }
    }

    override func tearDownWithError() throws {
        // What was typed is a draft, and drafts outlast the app.
        MainActor.assumeIsolated {
            let app = XCUIApplication()
            app.launchArguments = ["-echo.clearDrafts", "-echo.forget", "Can you tighten"] + XCUIApplication.straightToChat
            app.launch()
            _ = app.textFields.firstMatch.waitForExistence(timeout: 10)
            sleep(1)
            app.terminate()
        }
    }
}
