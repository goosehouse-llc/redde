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
        // The bots as faces, side by side, New Bot after them.
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.buttons["Scout"].waitForExistence(timeout: 10), "Scout isn't in the bots' row")
        XCTAssertTrue(list.buttons["Fix-it"].exists, "a bot without a chat yet isn't listed")
        XCTAssertTrue(list.buttons["New Bot"].exists, "no New Bot at the end of the row")
        XCTAssertLessThan(list.buttons["Scout"].frame.minX, list.buttons["New Bot"].frame.minX, "New Bot isn't after the bots")
        XCTAssertEqual(list.buttons["Scout"].frame.midY, list.buttons["Fix-it"].frame.midY, accuracy: 2, "the bots aren't in one row")
        XCTAssertFalse(app.text(containing: "Three trails under two hours").exists, "a bot's last line still shows")
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

    /// Mute from a bot's face in the bots' row: for an hour, it then reads as muted, and Unmute,
    /// from the same menu, lifts it. The same for a group chat's row.
    func testABotAndAGroupChatCanBeMutedFromTheirRows() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoProjects", "-echo.demoBots", "-echo.clearDrafts", "-displayName", "Redde",
                               "-echo.screen", "sessions", "-mutes", "<>"] + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        app.launch()
        let list = app.collectionViews.firstMatch
        // A bot's face in the row is named for the bot; a group chat's row starts with its name.
        func row(_ name: String) -> XCUIElement {
            list.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")).firstMatch
        }
        for name in ["Scout", "Weekend hike"] {
            let target = row(name)
            XCTAssertTrue(target.waitForExistence(timeout: 20), "no \(name) row")
            XCTAssertFalse((target.value as? String ?? "").contains("Muted"), "\(name) is muted already")
            target.press(forDuration: 1.0)
            let mute = app.buttons["Mute"].firstMatch
            XCTAssertTrue(mute.waitForExistence(timeout: 5), "no Mute in \(name)'s menu")
            mute.tap()
            let hour = app.buttons["For 1 Hour"].firstMatch
            XCTAssertTrue(hour.waitForExistence(timeout: 5), "Mute offers no spans")
            hour.tap()
            XCTAssertTrue(NSPredicate(format: "value CONTAINS %@", "Muted").evaluate(with: row(name)) || {
                sleep(1); return (row(name).value as? String ?? "").contains("Muted")
            }(), "\(name)'s row doesn't read as muted")
            row(name).press(forDuration: 1.0)
            let unmute = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Unmute")).firstMatch
            XCTAssertTrue(unmute.waitForExistence(timeout: 5), "no Unmute once muted")
            unmute.tap()
            sleep(1)
            XCTAssertFalse((row(name).value as? String ?? "").contains("Muted"), "\(name) is still muted")
        }
    }

    /// New Bot from a template: its name and what it does are filled in; another template replaces
    /// a name a template gave, and Blank keeps a name the person typed.
    func testNewBotFromATemplateFillsItIn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoProjects", "-echo.demoBots", "-echo.clearDrafts", "-displayName", "Redde",
                               "-echo.screen", "sessions", "-echo.botEditor", "new"] + XCUIApplication.chatsSection
        app.launch()
        let writer = app.buttons["Writer"].firstMatch
        XCTAssertTrue(writer.waitForExistence(timeout: 20), "no templates in New Bot")
        writer.tap()
        // (The Name field, by its placeholder: the chat's own field is behind the sheet.)
        let name = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Scout")).firstMatch
        XCTAssertEqual(name.value as? String, "Writer", "the template didn't name it")
        XCTAssertTrue(app.textViews.containing(NSPredicate(format: "value CONTAINS %@", "in your voice")).firstMatch.exists
                      || app.textFields.matching(NSPredicate(format: "value CONTAINS %@", "in your voice")).firstMatch.exists,
                      "what it does isn't filled in")
        app.buttons["Researcher"].firstMatch.tap()
        XCTAssertEqual(name.value as? String, "Researcher", "a name the template gave stays")
        name.tap()
        name.typeText(" Bee")
        app.buttons["Blank"].firstMatch.tap()
        XCTAssertEqual(name.value as? String, "Researcher Bee", "a name the person typed went")
    }

    /// A bot's schedules: listed in words, one opened shows what it does and when, and a new one
    /// offers each kind of when.
    func testABotsSchedulesOpenAndANewOneOffersWhen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoProjects", "-echo.demoBots", "-echo.clearDrafts", "-displayName", "Redde",
                               "-echo.screen", "sessions", "-echo.botSchedules", "scout"] + XCUIApplication.chatsSection
        app.launch()
        let wear = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "What to wear")).firstMatch
        XCTAssertTrue(wear.waitForExistence(timeout: 20), "Scout's schedules aren't listed")
        XCTAssertTrue(app.text(containing: "Weekdays at").exists, "when isn't in words")
        wear.tap()
        let name = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "What to wear")).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "What to wear", "the schedule didn't open with its name")
        app.buttons["Cancel"].firstMatch.tap()
        app.buttons["New Schedule"].firstMatch.tap()
        XCTAssertTrue(app.text(containing: "Repeat").waitForExistence(timeout: 5), "no Repeat for a new schedule")
        // (In the sheet's own bar: the chat behind it has an Add button of its own.)
        let add = app.navigationBars["New Schedule"].buttons["Add"]
        XCTAssertTrue(add.exists, "no Add in New Schedule")
        XCTAssertFalse(add.isEnabled, "it can be added with nothing to do")
    }

    /// More than six bots: one row, the first four and "more", which shows them all, and Fewer
    /// folds them again; folded or not is kept for the next launch.
    func testMoreThanSixBotsFoldAndStayAsLeft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoProjects", "-echo.demoBots", "-echo.demoBotCount", "9", "-echo.clearDrafts", "-displayName", "Redde",
                               "-echo.screen", "sessions", "-botOrder", "<>"]
            + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        app.launch()
        let list = app.collectionViews.firstMatch
        // (Folded or not as an earlier run left it: an argument would hold it for the launch.)
        XCTAssertTrue(list.buttons["Redde"].waitForExistence(timeout: 20), "no bots")
        if list.buttons["Fewer"].exists { list.buttons["Fewer"].tap() }
        let more = list.buttons["5 more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "nine bots didn't fold to four and \"5 more\"")
        XCTAssertFalse(list.buttons["New Bot"].exists, "New Bot shows while the bots are folded")
        XCTAssertEqual(list.buttons["Redde"].frame.midY, more.frame.midY, accuracy: 2, "the folded bots aren't one row")
        more.tap()
        let fewer = list.buttons["Fewer"]
        XCTAssertTrue(fewer.waitForExistence(timeout: 5), "\"more\" didn't show them all")
        for name in ["Home", "Chef", "Coach", "Atlas", "Penny", "New Bot"] {
            XCTAssertTrue(list.buttons[name].exists, "\(name) isn't shown with them all")
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "nine bots"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Kept: the next launch shows them all still.
        app.terminate()
        app.launch()
        XCTAssertTrue(list.buttons["Fewer"].waitForExistence(timeout: 20), "showing them all wasn't kept")
        list.buttons["Fewer"].tap()
        XCTAssertTrue(list.buttons["5 more"].waitForExistence(timeout: 5), "Fewer didn't fold them")
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
    /// launch too (first in the bots' row), a group chat goes among the bots, and Sort Bots by
    /// Recent puts the row back.
    func testBotsAndGroupChatsCanBeDraggedIntoAnOrder() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoProjects", "-echo.demoBots", "-echo.clearDrafts", "-displayName", "Redde",
                               "-echo.screen", "sessions"] + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        // No order left from an earlier run: an empty one, for this launch only.
        app.launchArguments += ["-botOrder", "<>"]
        app.launch()
        let list = app.collectionViews.firstMatch
        // Matched on the row's own label: a group chat's names its bots ("Fix-it and Scout"). A bot
        // is its face in the bots' row, named for it, and a row of its own while being put in order.
        func row(_ name: String) -> XCUIElement {
            list.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")).firstMatch
        }
        /// Drags a row by its handle onto another's place. (A handle is named for its row:
        /// "Reorder Fix-it", or for the whole row, "Reorder Fix-it, Looks after the home server".)
        func handle(_ name: String) -> XCUIElement {
            list.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Reorder " + name, "Reorder " + name + ",")).firstMatch
        }
        func drag(_ name: String, onto other: String) {
            let from = handle(name).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let to = handle(other).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            from.press(forDuration: 0.4, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.5)
            sleep(1)
        }
        let fixit = row("Fix-it"), quill = row("Quill"), garage = row("Garage project")
        XCTAssertTrue(fixit.waitForExistence(timeout: 20), "no Fix-it in the bots' row")
        XCTAssertTrue(garage.exists, "no group chat row")
        XCTAssertLessThan(quill.frame.minX, fixit.frame.minX, "the most recent bot isn't before one never talked to")

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
        XCTAssertLessThan(fixit.frame.minX, quill.frame.minX, "the order wasn't kept in the bots' row")
        fixit.press(forDuration: 1.0)
        app.buttons["Reorder Bots"].firstMatch.tap()
        XCTAssertTrue(app.text(containing: "into the order you want").waitForExistence(timeout: 5))
        XCTAssertLessThan(garage.frame.minY, fixit.frame.minY, "the order wasn't kept")
        XCTAssertLessThan(fixit.frame.minY, quill.frame.minY, "the order wasn't kept")
        app.buttons["Done"].firstMatch.tap()

        quill.press(forDuration: 1.0)
        let sort = app.buttons["Sort Bots by Recent"].firstMatch
        XCTAssertTrue(sort.waitForExistence(timeout: 5), "no Sort Bots by Recent")
        sort.tap()
        sleep(1)
        XCTAssertLessThan(quill.frame.minX, fixit.frame.minX, "the row didn't go back to the most recent first")
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

        let quill = app.collectionViews.firstMatch.buttons["Quill"].firstMatch
        XCTAssertTrue(quill.waitForExistence(timeout: 5))
        quill.tap()
        XCTAssertTrue(app.text(containing: "tighten the opening").waitForExistence(timeout: 10), "Quill's chat didn't take the group chat's place")
        XCTAssertFalse(app.textFields["Message the group"].exists)
    }

    /// New Bot and Topology fold into one More tile (his ask 2026-10-22), and stay folded, until More.
    func testNewBotAndTopologyFoldIntoOneTileAndStaySo() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoProjects", "-echo.demoBots", "-echo.clearDrafts", "-displayName", "Redde"]
            + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        func openList() {
            XCTAssertTrue(app.text(containing: "tighten the opening").waitForExistence(timeout: 20), "the demo bot's chat isn't open")
            if app.windows.firstMatch.frame.width < 600 { app.buttons["Conversations"].firstMatch.tap() }
        }
        app.launch()
        openList()
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.buttons["Topology"].waitForExistence(timeout: 5), "New Bot and Topology aren't shown at first")
        list.buttons["Less"].tap()
        XCTAssertTrue(list.buttons["More"].waitForExistence(timeout: 3), "no More once folded")
        XCTAssertFalse(list.buttons["New Bot"].exists || list.buttons["Topology"].exists, "they still show folded")

        app.launch()
        openList()
        XCTAssertTrue(list.buttons["More"].waitForExistence(timeout: 5), "folding them wasn't kept")
        list.buttons["More"].tap()
        XCTAssertTrue(list.buttons["New Bot"].waitForExistence(timeout: 3) && list.buttons["Topology"].exists, "More doesn't bring them back")
    }

    /// The Topology map from the Bots section: you, the group chats, the bots with what each is
    /// doing, the models they run on; a bot there opens its chat.
    func testTopologyShowsTheBotsTheirGroupChatsAndModels() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoProjects", "-echo.demoBots", "-echo.demoMarks", "-echo.demoClaudeBot", "-echo.clearDrafts", "-displayName", "Redde"]
            + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        app.launch()
        XCTAssertTrue(app.text(containing: "tighten the opening").waitForExistence(timeout: 20), "the demo bot's chat isn't open")
        if app.windows.firstMatch.frame.width < 600 { app.buttons["Conversations"].firstMatch.tap() }

        let list = app.collectionViews.firstMatch
        let topology = list.buttons["Topology"]
        XCTAssertTrue(topology.waitForExistence(timeout: 5), "no Topology in the Bots section")
        // Beside New Bot, a tile the size of a bot's (five bots: New Bot and it on the second row).
        let newBot = list.buttons["New Bot"], scoutTile = list.buttons["Scout"]
        XCTAssertEqual(topology.frame.midY, newBot.frame.midY, accuracy: 2, "Topology isn't beside New Bot")
        XCTAssertGreaterThan(topology.frame.minX, newBot.frame.minX, "Topology isn't after New Bot")
        XCTAssertEqual(topology.frame.width, scoutTile.frame.width, accuracy: 2, "Topology isn't a bot's size")
        XCTAssertEqual(topology.frame.height, scoutTile.frame.height, accuracy: 4, "Topology isn't a bot's size")
        topology.tap()

        XCTAssertTrue(app.navigationBars["Topology"].waitForExistence(timeout: 5), "the map didn't open")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Weekend hike")).firstMatch.exists,
                      "the group chat isn't on the map")
        // (Scout on the map, not Scout's face in the list behind it.)
        let scout = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Scout, runs on")).firstMatch
        XCTAssertTrue(scout.exists, "Scout isn't on the map")
        XCTAssertEqual(scout.value as? String, "Working, hands work to Quill", "Scout's work, and who it asks, aren't shown")
        XCTAssertTrue(app.text(containing: "claude-sonnet-4.5").exists, "Quill's model isn't on the map")
        XCTAssertTrue(app.text(containing: "qwen3.6-35b-a3b").exists, "the shared model isn't on the map")
        XCTAssertTrue(app.text(containing: "Claude Code").exists, "the bot that works through Claude Code doesn't show it")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND value CONTAINS %@", "Redde, runs on", "hands work to"))
                        .firstMatch.exists, "Redde's handoffs aren't told")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "topology"
        shot.lifetime = .keepAlways
        add(shot)

        scout.tap()
        XCTAssertFalse(app.navigationBars["Topology"].waitForExistence(timeout: 2), "the map stayed open")
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
