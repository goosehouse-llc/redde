import XCTest

/// The chat list's Today strip (2026-11-06): the inbox, briefings and goals as tiles; a tap opens one.
@MainActor
final class TodayStripUITests: XCTestCase {
    private func openDrawer() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoGoals", "-echo.demoBriefings", "day", "-echo.drawerPage", "today"]
            + XCUIApplication.straightToChat
        app.launch()
        let chat = app.scrollViews.firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 15))
        chat.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: chat.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        return app
    }

    private func tile(_ app: XCUIApplication, _ words: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    /// Swiped along the strip until the tile is on screen.
    private func reach(_ app: XCUIApplication, _ tile: XCUIElement) {
        let row = tile.frame.midY / app.frame.height
        for _ in 0 ..< 4 where tile.frame.maxX > app.frame.width * 0.85 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: row))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: row)))
        }
    }

    /// A list's own page (2026-11-14, "make the to do list nicer to look at"): its name and ring,
    /// what's left, then what's done; checking one off moves it down to Done.
    func testAListOpensAsItsOwnPage() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoLists", "-echo.drawerPage", "today"] + XCUIApplication.straightToChat
        app.launch()
        let chat = app.scrollViews.firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 15))
        chat.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: chat.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        let groceries = tile(app, "Groceries")
        XCTAssertTrue(groceries.waitForExistence(timeout: 5), "No list tile")
        reach(app, groceries)
        groceries.tap()
        /// The page's own row (the tile behind it says the same words).
        func item(_ text: String) -> XCUIElement {
            let all = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text))
            return all.allElementsBoundByIndex.first { $0.isHittable } ?? all.firstMatch
        }
        XCTAssertTrue(app.staticTexts["2 of 5 done"].waitForExistence(timeout: 5), "The list didn't open")
        let milk = item("Oat milk")
        XCTAssertTrue(milk.waitForExistence(timeout: 5), "The list didn't open")
        XCTAssertTrue(app.staticTexts["2 of 5 done"].exists, "No count under the name")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "list-page"; shot.lifetime = .keepAlways; add(shot)
        milk.tap()
        XCTAssertTrue(app.staticTexts["3 of 5 done"].waitForExistence(timeout: 5), "Checking one off didn't count")
        for name in ["Sourdough", "Lemons"] {
            item(name).tap()
        }
        XCTAssertTrue(app.staticTexts["All done"].waitForExistence(timeout: 5), "Every item done doesn't say so")
        sleep(1)
        let done = XCTAttachment(screenshot: app.screenshot())
        done.name = "list-all-done"; done.lifetime = .keepAlways; add(done)
    }

    func testAGoalTileOpensTheGoal() {
        let app = openDrawer()
        let goal = tile(app, "Run a 10K by March")
        XCTAssertTrue(goal.waitForExistence(timeout: 5), "No goal tile")
        reach(app, goal)
        goal.tap()
        XCTAssertTrue(app.staticTexts["Last Check-in"].waitForExistence(timeout: 5), "The goal didn't open")
    }

    func testABriefingTileOpensTheBriefing() {
        let app = openDrawer()
        // A briefing's tile starts with its time (one opened in an earlier run is read, and gone).
        let brief = app.buttons.matching(NSPredicate(format: "label MATCHES %@", #"^\d{1,2}:\d{2}\s?[AP]M.*"#)).firstMatch
        XCTAssertTrue(brief.waitForExistence(timeout: 5), "No briefing tile")
        brief.tap()
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForExistence(timeout: 5), "The briefing didn't open")
    }

    /// 2026-11-11: a held tile lifted the whole row, every tile with it. Its menu opens, with the
    /// tile's own colour on it; the screenshots kept with the result show what lifted (only the
    /// held tile, since the fix) and the tile in teal.
    func testHoldingATileOpensItsMenu() {
        let app = openDrawer()
        let brief = app.buttons.matching(NSPredicate(format: "label MATCHES %@", #"^\d{1,2}:\d{2}\s?[AP]M.*"#)).firstMatch
        XCTAssertTrue(brief.waitForExistence(timeout: 5), "No briefing tile")
        brief.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Later"].waitForExistence(timeout: 5), "No menu")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "held-tile"
        shot.lifetime = .keepAlways
        add(shot)
        // Its own colour (asked 2026-11-11), from the same menu.
        app.buttons["Tile Color"].tap()
        XCTAssertTrue(app.buttons["Like the Other Tiles"].waitForExistence(timeout: 5), "No colours")
        app.buttons["Teal"].tap()
        let colored = XCTAttachment(screenshot: app.screenshot())
        colored.name = "teal-tile"
        colored.lifetime = .keepAlways
        add(colored)
        // Back to the others' colour, so the next run starts plain.
        brief.press(forDuration: 1.2)
        app.buttons["Tile Color"].tap()
        app.buttons["Like the Other Tiles"].tap()
    }

    /// 2026-11-11: holding the second tile (a to-do list after the inbox) brought up the first's
    /// menu: the strip is one row of the list, and a row keeps one hold menu. Each tile has its own.
    func testHoldingTheSecondTileOpensItsOwnMenu() {
        let app = openDrawer()
        let goal = tile(app, "Run a 10K by March")
        XCTAssertTrue(goal.waitForExistence(timeout: 5), "No goal tile")
        reach(app, goal)
        goal.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Tile Color"].waitForExistence(timeout: 5), "No menu")
        XCTAssertFalse(app.buttons["Later"].exists, "The briefing's menu came up for the goal")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "held-goal"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// 2026-11-12: Move Right on Up Next puts it after the next tile, Move Left brings it back, and
    /// Arrange Tiles… lists them all. Up Next is "Lunch with Ana", put on the simulator's calendar.
    func testATileMovesFromItsMenu() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoGoals", "-echo.demoBriefings", "day", "-echo.demoUpNext", "-todayTileOrder", "()"]
            + XCUIApplication.straightToChat
        app.launch()
        let chat = app.scrollViews.firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 15))
        chat.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: chat.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        let lunch = tile(app, "Lunch with Ana")
        guard lunch.waitForExistence(timeout: 10) else {
            throw XCTSkip("No calendar access in this simulator (simctl privacy <sim> grant calendar com.goosehouse.echo)")
        }
        let second = app.buttons.matching(NSPredicate(format: "label MATCHES %@", #"^\d{1,2}:\d{2}\s?[AP]M.*"#)).firstMatch
        XCTAssertTrue(second.exists, "No briefing tile after Up Next")
        XCTAssertLessThan(lunch.frame.minX, second.frame.minX, "Up Next isn't first")
        lunch.press(forDuration: 1.2)
        XCTAssertFalse(app.buttons["Move Left"].exists, "The first tile can move left")
        app.buttons["Move Right"].tap()
        XCTAssertTrue(waitUntil { lunch.frame.minX > second.frame.minX }, "Up Next didn't move right")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "moved-right"
        shot.lifetime = .keepAlways
        add(shot)
        lunch.press(forDuration: 1.2)
        app.buttons["Move Left"].tap()
        XCTAssertTrue(waitUntil { lunch.frame.minX < second.frame.minX }, "Up Next didn't move back")
        lunch.press(forDuration: 1.2)
        app.buttons["Arrange Tiles…"].tap()
        XCTAssertTrue(app.navigationBars["Arrange Tiles"].waitForExistence(timeout: 5), "Arrange Tiles didn't open")
        XCTAssertTrue(app.staticTexts["Up Next"].exists, "Up Next isn't listed")
        let sheet = XCTAttachment(screenshot: app.screenshot())
        sheet.name = "arrange-tiles"
        sheet.lifetime = .keepAlways
        add(sheet)
        app.navigationBars["Arrange Tiles"].buttons["Done"].tap()
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        for _ in 0 ..< 20 {
            if condition() { return true }
            RunLoop.current.run(until: .now + 0.25)
        }
        return condition()
    }
}
