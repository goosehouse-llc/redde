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
        // (the chat's own scroll view isn't always one XCTest finds, 2026-11-22: the composer instead)
        XCTAssertTrue(app.composerField.waitForExistence(timeout: 15), "The chat didn't open")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
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

    /// A goal's steps are the person's or the agent's (2026-11-22, "not sure the current makes
    /// sense"): theirs a checklist, ticked on the goal's page and the count follows at once; the
    /// Today tile's check ticks off the next one without opening the goal.
    func testTheirStepsAreTickedOnTheGoalAndFromToday() {
        let app = openDrawer()
        let goal = tile(app, "Run a 10K by March")
        XCTAssertTrue(goal.waitForExistence(timeout: 10), "No goal tile")
        XCTAssertTrue(app.staticTexts["Next: Long run at 8 km"].exists || tile(app, "Long run at 8 km").exists,
                      "The tile doesn't name their next step")
        let done = app.buttons["goal-tile-done"].firstMatch
        XCTAssertTrue(done.exists, "No Done on the goal's tile")
        done.tap()
        XCTAssertTrue(tile(app, "Taper week").waitForExistence(timeout: 5), "Done didn't move the tile on to the next step")
        goal.tap()
        // (2026-11-22, "still not sure what to do with this goal screen": what waits on them first,
        // with why; the plan in its order; finished steps and the agent's own cards folded away.)
        XCTAssertTrue(app.staticTexts["Needs You"].waitForExistence(timeout: 5), "What waits on them isn't first")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Which pace'")).firstMatch.exists, "A blocked step doesn't say why")
        XCTAssertTrue(app.buttons["Answer"].exists && app.buttons["Go Ahead"].exists, "A blocked step's buttons don't say what they do")
        XCTAssertTrue(app.staticTexts["Plan"].exists, "The plan isn't one list")
        XCTAssertTrue(app.buttons["goal-own-tasks"].exists, "The agent's own cards aren't folded away")
        XCTAssertFalse(app.buttons["Approve All"].exists, "The plan is approved in the chat, not again here")
        XCTAssertFalse(app.buttons["goal-step-5"].exists, "A finished step isn't folded away")
        app.buttons["goal-step-6"].tap()   // Taper week, in the plan
        XCTAssertTrue(app.staticTexts["5/7"].waitForExistence(timeout: 5), "The count didn't follow the tick")
        app.buttons["goal-done-steps"].tap()
        app.swipeUp()   // (the finished steps open beneath, below the screen's edge)
        XCTAssertEqual(app.buttons["goal-step-5"].waitForExistence(timeout: 3) ? app.buttons["goal-step-5"].value as? String : nil, "Done",
                       "The tile's tick isn't on the goal's page")
        app.buttons["goal-step-6"].tap()   // now among the finished ones: the tick taken back
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["4/7"].waitForExistence(timeout: 5), "A tick couldn't be taken back")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "goal-steps"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// An idea opens in full on a tap (2026-11-22: "allow to tap on the card to see what it says
    /// before making me dismiss or push it"): every word, and the message Do It would send. Closed,
    /// it is still in the deck; Not Now closes the sheet.
    func testAnIdeaOpensInFullOnATap() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoIdeas", "-echo.drawerPage", "today"] + XCUIApplication.straightToChat
        app.launch()
        // (the chat's own scroll view isn't always one XCTest finds, 2026-11-22: the composer instead)
        XCTAssertTrue(app.composerField.waitForExistence(timeout: 15), "The chat didn't open")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        let card = app.staticTexts["Book the vet for Pickles"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "No idea card")
        card.tap()
        let request = app.staticTexts["idea-request"]
        XCTAssertTrue(request.waitForExistence(timeout: 5), "The idea didn't open")
        XCTAssertEqual(request.label, "Book Pickles in at the vet on Thursday afternoon")
        XCTAssertTrue(app.buttons["idea-do-it"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "idea-open"
        shot.lifetime = .keepAlways
        add(shot)
        app.navigationBars.buttons["Close"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5), "Closing put the idea away")
        card.tap()
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        // Not Now from the sheet closes it (the demo's made-up ideas come back after it, so the
        // deck itself isn't checked here).
        app.buttons["idea-not-now"].tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: request)
        wait(for: [gone], timeout: 5)
    }

    /// A list's own page (2026-11-14, "make the to do list nicer to look at"): its name and ring,
    /// what's left, then what's done; checking one off moves it down to Done.
    func testAListOpensAsItsOwnPage() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoLists", "-echo.drawerPage", "today"] + XCUIApplication.straightToChat
        app.launch()
        // (the chat's own scroll view isn't always one XCTest finds, 2026-11-22: the composer instead)
        XCTAssertTrue(app.composerField.waitForExistence(timeout: 15), "The chat didn't open")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
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

    /// A watch list (2026-11-23, "make these lists a bit more fun"): its tile and page in its own
    /// colour with its emoji, its films as posters; one tapped is stamped Watched; Change Look opens.
    /// A watch list opens as a clean list (2026-11-23): each title beside its poster, ticked as watched.
    func testAWatchListIsACleanList() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoLists", "-echo.drawerPage", "today", "-linkPreviews", "YES"] + XCUIApplication.straightToChat
        app.launch()
        XCTAssertTrue(app.composerField.waitForExistence(timeout: 15), "The chat didn't open")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        let films = tile(app, "Christmas Movies")
        XCTAssertTrue(films.waitForExistence(timeout: 5), "No watch list tile")
        XCTAssertTrue(films.label.contains("🎄") && films.label.contains("6 to watch"), "The tile: \(films.label)")
        let strip = XCTAttachment(screenshot: app.screenshot())
        strip.name = "watch-list-tile"; strip.lifetime = .keepAlways; add(strip)
        reach(app, films)
        films.tap()
        let elf = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Elf, 2003")).firstMatch
        XCTAssertTrue(elf.waitForExistence(timeout: 5), "No row for Elf")
        sleep(1)
        let page = XCTAttachment(screenshot: app.screenshot())
        page.name = "watch-list-page"; page.lifetime = .keepAlways; add(page)
        // A long press goes out to its pages (2026-11-24).
        elf.press(forDuration: 1.0)
        for site in ["IMDb", "Wikipedia", "Where can I watch it?"] {
            XCTAssertTrue(app.buttons[site].waitForExistence(timeout: 3), "No \(site) in the film's menu")
        }
        let menu = XCTAttachment(screenshot: app.screenshot())
        menu.name = "film-look-up"; menu.lifetime = .keepAlways; add(menu)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()   // the dimmed list's header (the status bar doesn't close it)
        XCTAssertTrue(app.buttons["IMDb"].waitForNonExistence(timeout: 3), "The film's menu didn't close")
        elf.tap()
        XCTAssertTrue(app.staticTexts["3 of 8 done"].waitForExistence(timeout: 5), "Watching one didn't count")
        app.buttons["Change Look"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Change Look"].waitForExistence(timeout: 5), "Change Look didn't open")
        sleep(1)
        let look = XCTAttachment(screenshot: app.screenshot())
        look.name = "change-look"; look.lifetime = .keepAlways; add(look)
    }

    func testAGoalTileOpensTheGoal() {
        let app = openDrawer()
        let goal = tile(app, "Run a 10K by March")
        XCTAssertTrue(goal.waitForExistence(timeout: 5), "No goal tile")
        reach(app, goal)
        goal.tap()
        XCTAssertTrue(app.staticTexts["Plan"].waitForExistence(timeout: 5), "The goal didn't open")
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

    /// 2026-11-19, asked: a briefing's tile on Today stops its notifications from its hold menu,
    /// as the deck's Don't Show does, and the tile goes. (The demo's jobs are shown again at the
    /// next launch.)
    func testABriefingTileStopsItsNotifications() {
        let app = openDrawer()
        let brief = app.buttons.matching(NSPredicate(format: "label MATCHES %@", #"^\d{1,2}:\d{2}\s?[AP]M.*"#)).firstMatch
        XCTAssertTrue(brief.waitForExistence(timeout: 5), "No briefing tile")
        let label = brief.label
        brief.press(forDuration: 1.2)
        let stop = app.buttons["Stop These Notifications"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "No Stop These Notifications in the tile's menu")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "stop-notifications"
        shot.lifetime = .keepAlways
        add(shot)
        stop.tap()
        let same = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(same.waitForNonExistence(timeout: 5), "The tile stayed")
    }

    /// 2026-11-20, "turning briefings on/off is not clear in Your Day settings": each daily briefing
    /// is a switch on Your Day with its time under it, and the person's other jobs that send briefings
    /// are listed with how they arrive (Notify Me, Drawer Only, Off).
    func testYourDaySwitchesBriefings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoBriefings", "-echo.screen", "settings", "-echo.settingsAnchor", "day"]
        app.launch()
        let wrapUp = app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Evening Wrap-up")).firstMatch
        XCTAssertTrue(wrapUp.waitForExistence(timeout: 20), "No Evening Wrap-up switch on Your Day")
        XCTAssertEqual(wrapUp.value as? String, "0", "The sample wrap-up should start off")
        wrapUp.switches.firstMatch.exists ? wrapUp.switches.firstMatch.tap() : wrapUp.tap()
        XCTAssertTrue(NSPredicate(format: "value == '1'").evaluate(with: wrapUp) || {
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: wrapUp)], timeout: 3)
            return wrapUp.value as? String == "1"
        }(), "The switch didn't turn the wrap-up on")
        let others = app.staticTexts["From Your Other Jobs"]
        for _ in 0 ..< 8 where !others.exists || !app.windows.firstMatch.frame.contains(others.frame) { app.swipeUp() }
        XCTAssertTrue(others.exists, "No section for the other jobs")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "your-day-briefings"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// 2026-11-21, "on cron jobs, I see skip and pause, but not a clear way to stop and delete":
    /// a job's hold menu on Coming Up has Delete, which asks first.
    func testComingUpDeletesAJob() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.screen", "comingUp", "-echo.demoComingUp"]
        app.launch()
        let job = app.staticTexts["The NAS's free space"]
        XCTAssertTrue(job.waitForExistence(timeout: 20), "No demo job on Coming Up")
        job.press(forDuration: 1.2)
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "No Delete in the job's menu")
        XCTAssertTrue(app.buttons["Pause"].exists, "Pause is still there")
        delete.tap()
        let confirm = app.buttons["Delete Job"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete didn't ask first")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "coming-up-delete"
        shot.lifetime = .keepAlways
        add(shot)
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
        // (the chat's own scroll view isn't always one XCTest finds, 2026-11-22: the composer instead)
        XCTAssertTrue(app.composerField.waitForExistence(timeout: 15), "The chat didn't open")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
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
