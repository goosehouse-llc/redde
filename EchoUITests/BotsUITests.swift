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

    /// Reorder Bots, from a bot's menu: a bot dragged above the others stays there, the next
    /// launch too, a group chat goes among the bots, and Sort Bots by Recent puts the list back.
    func testBotsAndGroupChatsCanBeDraggedIntoAnOrder() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoProjects", "-echo.demoBots", "-echo.clearDrafts", "-displayName", "Redde",
                               "-echo.screen", "sessions"] + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        // No order left from an earlier run: an empty one, for this launch only.
        app.launchArguments += ["-botOrder", "<>"]
        app.launch()
        let list = app.collectionViews.firstMatch
        // Matched on the row's own label: a group chat's names its bots ("Fix-it and Scout").
        func row(_ name: String) -> XCUIElement { list.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch }
        /// Drags a row by its handle onto another's place.
        func drag(_ name: String, onto other: String) {
            let from = list.buttons["Reorder " + name].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let to = list.buttons["Reorder " + other].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            from.press(forDuration: 0.4, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.5)
            sleep(1)
        }
        let fixit = row("Fix-it"), quill = row("Quill"), garage = row("Garage project")
        XCTAssertTrue(fixit.waitForExistence(timeout: 20), "no Fix-it row")
        XCTAssertTrue(garage.exists, "no group chat row")
        XCTAssertLessThan(quill.frame.minY, fixit.frame.minY, "the most recent bot isn't above one never talked to")

        fixit.press(forDuration: 1.0)
        let reorder = app.buttons["Reorder Bots"].firstMatch
        XCTAssertTrue(reorder.waitForExistence(timeout: 5), "no Reorder Bots in a bot's menu")
        reorder.tap()
        XCTAssertTrue(app.text(containing: "into the order you want").waitForExistence(timeout: 5), "Reorder Bots didn't start")
        XCTAssertFalse(app.text(containing: "New Bot").exists, "the section's actions show while reordering")
        drag("Fix-it", onto: "Quill")
        XCTAssertLessThan(fixit.frame.minY, quill.frame.minY, "Fix-it didn't move above Quill")
        drag("Garage project", onto: "Fix-it")
        XCTAssertLessThan(garage.frame.minY, fixit.frame.minY, "the group chat didn't move among the bots")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.text(containing: "New Bot").waitForExistence(timeout: 5), "Done didn't end reordering")

        app.terminate()
        app.launchArguments.removeLast(2)
        app.launch()
        XCTAssertTrue(fixit.waitForExistence(timeout: 20))
        XCTAssertLessThan(garage.frame.minY, fixit.frame.minY, "the order wasn't kept")
        XCTAssertLessThan(fixit.frame.minY, quill.frame.minY, "the order wasn't kept")

        quill.press(forDuration: 1.0)
        let sort = app.buttons["Sort Bots by Recent"].firstMatch
        XCTAssertTrue(sort.waitForExistence(timeout: 5), "no Sort Bots by Recent")
        sort.tap()
        sleep(1)
        XCTAssertLessThan(quill.frame.minY, fixit.frame.minY, "the list didn't go back to the most recent first")
        XCTAssertLessThan(fixit.frame.minY, garage.frame.minY, "the group chats didn't go back after the bots")
    }

    /// iPhone: a group chat takes the chat's place, so a swipe to the right opens the list from
    /// it as from a conversation, and a conversation picked there takes its place again.
    func testAGroupChatIsASwipeFromTheList() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoProjects", "-echo.demoBots", "-echo.openGroup", "-echo.clearDrafts", "-displayName", "Redde",
                               "-echo.screen", "sessions"] + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        app.launch()
        try XCTSkipIf(app.windows.firstMatch.frame.width > 600, "iPad keeps the list in the sidebar")
        XCTAssertTrue(app.textFields["Message the group"].waitForExistence(timeout: 20), "the group chat didn't open")
        XCTAssertFalse(app.buttons["Done"].exists, "the group chat is still a cover with Done")

        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.47)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(app.navigationBars["Conversations"].waitForExistence(timeout: 5), "swiping right didn't open the list")

        let quill = app.collectionViews.firstMatch.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Quill,")).firstMatch
        XCTAssertTrue(quill.waitForExistence(timeout: 5))
        quill.tap()
        XCTAssertTrue(app.text(containing: "tighten the opening").waitForExistence(timeout: 10), "Quill's chat didn't take the group chat's place")
        XCTAssertFalse(app.textFields["Message the group"].exists)
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
