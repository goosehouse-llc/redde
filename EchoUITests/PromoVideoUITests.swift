import XCTest

/// Drives the App Store preview's shots while the simulator records (see design/video). Skipped
/// unless the runner sets PROMO_VIDEO=1 (`TEST_RUNNER_PROMO_VIDEO=1 xcodebuild test …`). Each shot
/// prints when it starts and ends, so the recording can be cut to exactly that span.
@MainActor
final class PromoVideoUITests: XCTestCase {
    private func launch(_ extra: [String]) throws -> XCUIApplication {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PROMO_VIDEO"] == "1", "Promo video shots run on request")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.chatsSection + XCUIApplication.straightToChat
            + ["-echo.demoHosts", "-transport", "chatCompletions"] + extra
        app.launch()
        return app
    }

    private func mark(_ what: String) { print("PROMO \(what) \(Date().timeIntervalSince1970)") }
    private func hold(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func drag(_ app: XCUIApplication, from: CGVector, to: CGVector, velocity: XCUIGestureVelocity = .slow) {
        let w = app.windows.firstMatch
        w.coordinate(withNormalizedOffset: from)
            .press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: to), withVelocity: velocity, thenHoldForDuration: 0.1)
    }

    /// Answers with substance: read up through the checklist, table, diagram and math.
    func testRichAnswers() throws {
        let app = try launch(["-echo.demo", "-echo.demoLibrary", "-theme", "claudeCode", "-appearance", "dark"])
        XCTAssertTrue(app.staticTexts["Where are we on the kitchen project?"].waitForExistence(timeout: 20))
        // On iPad the transcript is the right-hand column, beside the sidebar.
        let x: CGFloat = app.windows.firstMatch.frame.width > 600 ? 0.66 : 0.5
        // Diagrams and math draw when they first scroll into view: pass over them all once, then
        // start the take from the top of the transcript.
        for _ in 0..<4 { drag(app, from: CGVector(dx: x, dy: 0.8), to: CGVector(dx: x, dy: 0.2), velocity: .fast); hold(0.8) }
        hold(1.5)
        for _ in 0..<5 { drag(app, from: CGVector(dx: x, dy: 0.25), to: CGVector(dx: x, dy: 0.85), velocity: .fast) }
        hold(1.5)
        mark("start")
        hold(0.8)
        for _ in 0..<3 {
            drag(app, from: CGVector(dx: x, dy: 0.78), to: CGVector(dx: x, dy: 0.38), velocity: 250)
            hold(0.5)
        }
        hold(0.8)
        mark("end")
    }

    /// Every chat, cron job and board: swipe the conversations in, then open the Kanban board.
    func testConversationsAndKanban() throws {
        let app = try launch(["-echo.demo", "-echo.demoLibrary", "-echo.demoKanban", "-theme", "claudeCode", "-appearance", "dark"])
        XCTAssertTrue(app.buttons["Conversations"].waitForExistence(timeout: 20))
        hold(2.5)
        mark("start")
        hold(0.7)
        drag(app, from: CGVector(dx: 0.08, dy: 0.5), to: CGVector(dx: 0.85, dy: 0.52), velocity: 700)
        hold(1.6)
        // By position: the Kanban segment in the panel's first row. (Accessibility lookups found
        // the hidden ⌘3 shortcut button of the same name, or nothing.)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.69, dy: 0.262)).tap()
        hold(2.4)
        mark("end")
    }

    /// Phone tools: the agent reads the calendar, the phone asks before the reminder is added,
    /// and a photo is found by what it shows (`-echo.demoPhone`). One take, with marks at the
    /// question's arrival and at its answer.
    func testPhoneTools() throws {
        let app = try launch(["-echo.demoPhone", "-theme", "claudeCode", "-appearance", "dark"])
        XCTAssertTrue(app.navigationBars.buttons["New conversation"].firstMatch.waitForExistence(timeout: 20))
        mark("start")
        let allow = app.alerts.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 20), "Phone tools didn't ask about the reminder")
        mark("asked")
        hold(2.0)
        allow.tap()
        mark("allowed")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "bowled")).firstMatch.waitForExistence(timeout: 30))
        hold(3.0)
        mark("end")
    }

    /// Phone tools reaching a person: a call the agent starts and a message it writes
    /// (`-echo.demoPhone reach`). In a simulator there is no phone for iOS to ask about and no
    /// Messages to open, so the take shows the conversation and not those two screens of iOS's.
    func testPhoneToolsReach() throws {
        let app = try launch(["-echo.demoPhone", "reach", "-theme", "claudeCode", "-appearance", "dark"])
        XCTAssertTrue(app.navigationBars.buttons["New conversation"].firstMatch.waitForExistence(timeout: 20))
        mark("start")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Tap Call")).firstMatch.waitForExistence(timeout: 30))
        mark("called")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "You sent it")).firstMatch.waitForExistence(timeout: 30))
        mark("sent")
        hold(2.5)
        mark("end")
    }

    // MARK: The second Phone tools video: a day with the agent (`-echo.demoFun`)

    private func fun(_ scene: String, _ extra: [String] = []) throws -> XCUIApplication {
        try launch(["-echo.demoFun", scene, "-theme", "claudeCode", "-appearance", "dark"] + extra)
    }

    private func says(_ app: XCUIApplication, _ words: String) -> Bool {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", words)).firstMatch.waitForExistence(timeout: 30)
    }

    private func started(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars.buttons["New conversation"].firstMatch.waitForExistence(timeout: 20))
        mark("start")
    }

    /// Readies a simulator for the takes, unrecorded: iOS asked for Alarms and answered, and the
    /// agent's widget on the Home Screen. Wants an iOS 26.3 simulator (27.0's refuses alarms)
    /// on which Redde has been opened a minute or more before (the widget gallery is slow to
    /// find a new app's widgets).
    func testFunReady() throws {
        let app = try launch(["-echo.demoAlarm", "5", "-echo.demoBoard", "clear"])
        XCTAssertTrue(app.navigationBars.buttons["New conversation"].firstMatch.waitForExistence(timeout: 20))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }
        hold(8)
        let stop = springboard.buttons["Stop"]
        if stop.waitForExistence(timeout: 6) { stop.tap() }
        XCUIDevice.shared.press(.home)
        hold(2)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70)).press(forDuration: 1.6)
        XCTAssertTrue(springboard.buttons["Edit"].waitForExistence(timeout: 8), "no Edit")
        springboard.buttons["Edit"].tap()
        XCTAssertTrue(springboard.buttons["Add Widget"].waitForExistence(timeout: 8), "no Add Widget")
        springboard.buttons["Add Widget"].tap()
        let search = springboard.searchFields["Search Widgets"]
        XCTAssertTrue(search.waitForExistence(timeout: 8), "no search field")
        search.tap()
        search.typeText("Redde")
        let cell = springboard.cells.containing(NSPredicate(format: "label CONTAINS 'Redde'")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 8), "no Redde in the gallery")
        cell.tap()
        hold(2)
        let wanted = springboard.staticTexts["From Your Agent"]
        for _ in 0 ..< 12 where !(wanted.exists && wanted.isHittable) { springboard.swipeLeft(); hold(1) }
        XCTAssertTrue(wanted.exists, "the agent's widget isn't in the gallery")
        springboard.swipeLeft()   // its second size, the wide one
        hold(1)
        let add = springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Add Widget'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "no Add Widget button")
        add.tap()
        hold(1)
        if springboard.buttons["Done"].waitForExistence(timeout: 5) { springboard.buttons["Done"].tap() }
        hold(2)
        tidyHomeScreen(springboard)
    }

    /// The test runner's own icon into the Utilities folder, out of the Home Screen takes, and the
    /// Lock Screen cleared.
    private func tidyHomeScreen(_ springboard: XCUIApplication) {
        let runner = springboard.icons.matching(NSPredicate(format: "label BEGINSWITH 'EchoUITests'")).firstMatch
        let folder = springboard.icons["Utilities"]
        if runner.exists, runner.isHittable, folder.exists {
            runner.press(forDuration: 1.2, thenDragTo: folder, withVelocity: .slow, thenHoldForDuration: 1.5)
            hold(2)
        }
        XCUIDevice.shared.press(.home)
        hold(1)
        if springboard.buttons["Done"].exists { springboard.buttons["Done"].tap() }
        XCUIDevice.shared.press(.home)
        hold(1)
        // A new simulator's own notification ("Ready for Apple Intelligence") off the Lock Screen.
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        hold(1)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        hold(2)
        let note = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Apple Intelligence'")).firstMatch
        if note.waitForExistence(timeout: 4) {
            note.swipeLeft()
            hold(1)
            let clear = springboard.buttons.matching(NSPredicate(format: "label == 'Clear' OR label == 'Clear All'")).firstMatch
            if clear.waitForExistence(timeout: 3) { clear.tap() }
        }
        hold(1)
        XCUIDevice.shared.press(.home)
        hold(1)
    }

    func testFunTidy() throws {
        _ = try launch([])
        XCUIDevice.shared.press(.home)
        hold(2)
        tidyHomeScreen(XCUIApplication(bundleIdentifier: "com.apple.springboard"))
    }

    /// The Phone tools store screenshot's two insets, as pictures in SHOT_DIR: the agent's widget
    /// on the Home Screen (as it was left: the `widget` take writes the shopping list on it) and a
    /// nine-minute timer counting down on the Lock Screen. On the simulator `testFunReady`
    /// readied, with no status bar override (one hides the countdown).
    func testToolsShotInsets() throws {
        let app = try launch(["-echo.demoAlarm", "540"])
        let dir = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["SHOT_DIR"], "SHOT_DIR is where they go"))
        XCTAssertTrue(app.navigationBars.buttons["New conversation"].firstMatch.waitForExistence(timeout: 20))
        hold(2)
        XCUIDevice.shared.press(.home)
        hold(3)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appending(path: "home-widget.png"))
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        hold(1)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        hold(4)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appending(path: "lock-timer.png"))
        XCUIDevice.shared.press(.home)
        let clear = XCUIApplication()
        clear.launchArguments = XCUIApplication.straightToChat + ["-echo.demoAlarm", "clear"]
        clear.launch()
        hold(2)
    }

    /// Morning: the day from the calendar, then a reminder, which Phone tools asks about.
    func testFunMorning() throws {
        let app = try fun("morning")
        started(app)
        let allow = app.alerts.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 30), "Phone tools didn't ask about the reminder")
        mark("asked")
        hold(1.6)
        allow.tap()
        mark("allowed")
        XCTAssertTrue(says(app, "nudge you"))
        hold(2.5)
        mark("end")
    }

    /// A real timer, then the Lock Screen with it counting down. Cancelled again after.
    func testFunTimer() throws {
        let app = try fun("timer")
        started(app)
        XCTAssertTrue(says(app, "rings even"))
        hold(1.8)
        mark("locking")
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        hold(1.0)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        mark("locked")
        hold(4.5)
        mark("end")
        XCUIDevice.shared.press(.home)
        let clear = XCUIApplication()
        clear.launchArguments = XCUIApplication.straightToChat + ["-echo.demoAlarm", "clear"]
        clear.launch()
        hold(2)
    }

    /// The list saved to Files and put on the widget, then the Home Screen with the widget.
    func testFunWidget() throws {
        let app = try fun("widget")
        started(app)
        XCTAssertTrue(says(app, "forget the parmesan"))
        hold(1.6)
        mark("home")
        XCUIDevice.shared.press(.home)
        hold(4.0)
        mark("end")
    }

    func testFunPhoto() throws {
        let app = try fun("photo")
        started(app)
        XCTAssertTrue(says(app, "Personal best"))
        hold(2.8)
        mark("end")
    }

    /// Voice mode with the camera on, then the question it went with and the answer.
    func testFunLook() throws {
        let app = try fun("look", ["-echo.voiceView", "-echo.voiceLook", "-echo.voiceDemo", "Is my plant okay? It looks kind of sad."])
        let camera = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Camera")).firstMatch
        XCTAssertTrue(camera.waitForExistence(timeout: 30), "No camera button on the voice screen")
        hold(1.0)
        mark("start")
        hold(0.6)
        camera.tap()
        mark("camera")
        hold(2.8)
        // The voice screen's: the conversation beneath has a Stop of its own.
        let stop = app.buttons.matching(identifier: "Stop").allElementsBoundByIndex.last { $0.isHittable }
        XCTAssertNotNil(stop, "No Stop on the voice screen")
        stop?.tap()
        mark("closed")
        XCTAssertTrue(says(app, "perk up"))
        hold(2.5)
        mark("end")
    }

    func testFunReach() throws {
        let app = try fun("reach")
        started(app)
        XCTAssertTrue(says(app, "Tap Call"))
        mark("called")
        XCTAssertTrue(says(app, "Dana knows"))
        mark("sent")
        hold(2.5)
        mark("end")
    }

    /// Phone tools in Settings: each area with its own switch, and one of them being chosen.
    func testPhoneToolsSettings() throws {
        let app = try launch(["-echo.demoPhone", "settings", "-echo.screen", "settings", "-echo.demoPlugin", "there",
                              "-theme", "claudeCode", "-appearance", "dark"])
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20))
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Phone tools'")).firstMatch
        for _ in 0 ..< 14 where !(row.exists && row.isHittable) { app.swipeUp() }
        hold(0.6)
        row.tap()
        XCTAssertTrue(app.navigationBars["Phone Tools"].waitForExistence(timeout: 10))
        hold(1.2)
        mark("start")
        hold(2.2)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Contacts'")).firstMatch.tap()
        hold(1.6)
        app.buttons["Allow reading"].tap()
        hold(1.8)
        mark("end")
    }

    /// Set up by code: Settings shows this connection as a QR code for another device to scan.
    func testSetUpByCode() throws {
        let app = try launch(["-echo.demo", "-echo.screen", "settings", "-theme", "claudeCode", "-appearance", "dark"])
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20))
        let button = app.buttons["Set up another device…"].firstMatch
        for _ in 0 ..< 6 where !button.isHittable { app.swipeUp(velocity: .slow) }
        hold(1.5)
        mark("start")
        hold(0.8)
        button.tap()
        XCTAssertTrue(app.images["setup-code"].waitForExistence(timeout: 5))
        hold(3)
        mark("end")
    }

    /// Make it yours: Settings with the app icons open, scrolled gently.
    func testMakeItYours() throws {
        let app = try launch(["-echo.demo", "-echo.screen", "settings", "-echo.expandAppIcons", "-theme", "standard", "-appearance", "light"])
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20))
        hold(2)
        mark("start")
        hold(1.2)
        // On iPad Settings is a sheet in the middle of the screen: a drag from lower down starts outside it.
        let wide = app.windows.firstMatch.frame.width > 600
        drag(app, from: CGVector(dx: 0.5, dy: wide ? 0.62 : 0.75), to: CGVector(dx: 0.5, dy: wide ? 0.42 : 0.5), velocity: 180)
        hold(2)
        mark("end")
    }
}
