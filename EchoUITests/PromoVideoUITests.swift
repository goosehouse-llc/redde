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
        app.launchArguments = XCUIApplication.straightToChat
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

    // MARK: BOTS! (design/video, `make_preview.py bots`)

    /// The demo bots in the Code theme, dark, as every BOTS! take is.
    private func bots(_ extra: [String]) throws -> XCUIApplication {
        try launch(["-echo.demoProjects", "-echo.demoBots", "-echo.clearDrafts", "-displayName", "Redde",
                    "-theme", "claudeCode", "-appearance", "dark"] + extra)
    }

    /// New Bot from a template: Researcher, then Writer, then Coder fill it in; then its face,
    /// changed with Surprise Me.
    func testBotsTemplate() throws {
        let app = try bots(["-echo.screen", "sessions", "-echo.botEditor", "new"])
        let researcher = app.buttons["Researcher"].firstMatch
        XCTAssertTrue(researcher.waitForExistence(timeout: 20))
        mark("start")
        hold(1.2)
        for name in ["Researcher", "Writer", "Coder"] {
            app.buttons[name].firstMatch.tap()
            mark(name.lowercased())
            hold(1.7)
        }
        app.buttons["Change Face"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Shape"].firstMatch.waitForExistence(timeout: 5))
        mark("faces")
        hold(1.0)
        // The parts at the top of the picker, each drawn as the bot with it.
        for part in ["Star", "Blob", "Ghost", "Sparkle", "Happy"] {
            let button = app.buttons[part].firstMatch
            if button.exists { button.tap(); hold(0.75) }
        }
        mark("end")
        hold(1.0)
    }

    /// In a bot's chat, Scout and Quill having messaged each other; then an @ offers the other
    /// bots, and one picked, the question goes on.
    func testBotsMention() throws {
        let app = try bots(["-echo.demoMarks"])
        XCTAssertTrue(app.text(containing: "Lost Lake").waitForExistence(timeout: 20))
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        mark("start")
        hold(1.0)
        field.tap()
        hold(0.5)
        field.typeText("Ask @")
        let scout = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "@scout")).firstMatch
        XCTAssertTrue(scout.waitForExistence(timeout: 5))
        mark("offered")
        hold(1.6)
        scout.tap()
        field.typeText("which trails are open this weekend")
        mark("end")
        hold(1.5)
    }

    /// The group's voice screen: one question, and Redde, Scout and Quill answering it in turn,
    /// each in its own voice (Kokoro's, at `TEST_RUNNER_KOKORO_URL`, when given). Marks as each begins.
    func testBotsVoiceRound() throws {
        var voice: [String] = []
        if let url = ProcessInfo.processInfo.environment["KOKORO_URL"], !url.isEmpty {
            voice = ["-replyVoice", "kokoro", "-kokoroURL", url, "-voiceSpeed", "1"]
        }
        let app = try bots(["-echo.screen", "sessions", "-mutes", "<>",
                            "-echo.openGroup", "-echo.demoRound", "-echo.groupVoice"] + voice)
        var label: XCUIElement?
        for name in ["Redde", "Scout", "Quill"] {
            label = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "\(name) is speaking")).firstMatch
            XCTAssertTrue(label!.waitForExistence(timeout: 40), "\(name) never spoke")
            mark(name.lowercased())
        }
        if let label { wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: label)], timeout: 30) }
        mark("end")
        hold(1.5)
    }

    /// The 2.0 store screenshots' raw shots, as pictures in SHOT_DIR (`ph-` or `pad-` by the
    /// device; design/screenshots): the chat list's Bots, and a group chat's voice screen once the
    /// round has come to Quill, the third bot, with the others' answers above it.
    func testBotsShots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PROMO_VIDEO"] == "1", "Promo video shots run on request")
        let dir = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["SHOT_DIR"], "SHOT_DIR is where they go"))
        let kind = UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "ph"
        var voice: [String] = []
        if let url = ProcessInfo.processInfo.environment["KOKORO_URL"], !url.isEmpty {
            voice = ["-replyVoice", "kokoro", "-kokoroURL", url, "-voiceSpeed", "1"]
        }
        // The iPad's sidebar shows the library under the bots: the sample one, as its other shots.
        let screen = kind == "ph" ? ["-echo.screen", "sessions"] : ["-echo.demoLibrary"]
        let list = try bots(screen + ["-echo.demoMarks", "-mutes", "<>"])
        XCTAssertTrue(list.staticTexts["Weekend hike"].firstMatch.waitForExistence(timeout: 20))
        hold(3)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appending(path: "\(kind)-bots.png"))
        let room = try bots(screen + ["-mutes", "<>",
                                      "-echo.openGroup", "-echo.demoRound", "-echo.groupVoice"] + voice)
        let quill = room.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Quill is speaking")).firstMatch
        XCTAssertTrue(quill.waitForExistence(timeout: 60), "the round never came to Quill")
        hold(1.5)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appending(path: "\(kind)-crew.png"))
    }

    /// Scout muted from its row, then its schedules, one opened.
    func testBotsMuteAndSchedules() throws {
        let app = try bots(["-echo.screen", "sessions", "-mutes", "<>"])
        let list = app.collectionViews.firstMatch
        let scout = list.buttons["Scout"].firstMatch
        XCTAssertTrue(scout.waitForExistence(timeout: 20))
        mark("start")
        hold(1.0)
        scout.press(forDuration: 1.0)
        app.buttons["Mute"].firstMatch.tap()
        hold(0.6)
        app.buttons["For 8 Hours"].firstMatch.tap()
        mark("muted")
        hold(1.8)
        scout.press(forDuration: 1.0)
        app.buttons["Schedules…"].firstMatch.tap()
        let wear = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "What to wear")).firstMatch
        XCTAssertTrue(wear.waitForExistence(timeout: 10))
        mark("schedules")
        hold(1.8)
        wear.tap()
        mark("opened")
        hold(2.2)
        mark("end")
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
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Phone tools'")).firstMatch
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
        app.openSettingsPage("Connection")
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
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 20), "Settings → Appearance didn't open on the icons")
        hold(2)
        mark("start")
        hold(1.2)
        // On iPad Settings is a sheet in the middle of the screen: a drag from lower down starts outside it.
        let wide = app.windows.firstMatch.frame.width > 600
        drag(app, from: CGVector(dx: 0.5, dy: wide ? 0.62 : 0.75), to: CGVector(dx: 0.5, dy: wide ? 0.42 : 0.5), velocity: 180)
        hold(2)
        mark("end")
    }

    // MARK: A day with Redde (design/video, `make_day.py`)

    /// The day's agents (Sol, Home, Coder) and chats, canned answers (`DemoDay`), in the Code
    /// theme, dark, as the other takes are.
    private func day(_ scene: String, _ extra: [String] = []) throws -> XCUIApplication {
        try launch(["-echo.demoProjects", "-echo.demoBots", "-echo.demoDay", scene, "-displayName", "Sol", "-echo.clearDrafts",
                    "-sessions.botActionsShown", "NO", "-projectsInChatList", "NO",
                    "-theme", "claudeCode", "-appearance", "dark"] + extra)
    }

    /// iOS asking to send notifications, answered (a fresh install's first launch of a scene that posts one).
    private func allowNotifications() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 12) { allow.tap() }
        mark("allowed")
    }

    /// A slow drag from an element's middle, held at the end so what it shows there is seen.
    private func slide(_ element: XCUIElement, by dx: CGFloat, hold seconds: TimeInterval = 0.7) {
        let from = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.08, thenDragTo: from.withOffset(CGVector(dx: dx, dy: 0)), withVelocity: 320, thenHoldForDuration: seconds)
    }

    /// A Form picker's menu, and one of its choices.
    private func pick(_ app: XCUIApplication, _ picker: String, _ choice: String) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", picker)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no \(picker)")
        row.tap()
        hold(0.9)
        let item = app.buttons.matching(NSPredicate(format: "label == %@", choice)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no \(choice) in \(picker)")
        item.tap()
        mark(choice.lowercased().replacingOccurrences(of: " ", with: "-"))
    }

    /// The test runner's icon off the Home Screen (into the App Library), for the arrive-home take.
    func testDayTidy() throws {
        _ = try day("tidy")
        XCUIDevice.shared.press(.home)
        hold(1.5)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let runner = springboard.icons.matching(NSPredicate(format: "label BEGINSWITH 'EchoUITests'")).firstMatch
        XCTAssertTrue(runner.waitForExistence(timeout: 5), "no runner icon")
        runner.press(forDuration: 1.4)
        let remove = springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Remove'")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "no Remove App")
        remove.tap()
        let fromHome = springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Home Screen'")).firstMatch
        XCTAssertTrue(fromHome.waitForExistence(timeout: 5), "no Remove from Home Screen")
        fromHome.tap()
        hold(1.5)
        XCUIDevice.shared.press(.home)
        hold(1)
    }

    /// A briefing's card on the deck at the top of the chat list (its words read as one element).
    private func deckCard(_ app: XCUIApplication, _ words: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    /// 7:00: the chat list, the Week Ahead waiting in Briefings; the dentist's heads-up comes, as a
    /// banner and on top of the deck (its time, Leave by, the address); opened: the event card and
    /// the map.
    func testDayMorning() throws {
        let app = try day("morning", ["-echo.screen", "sessions", "-echo.demoDayAt", "3"])
        allowNotifications()
        let card = deckCard(app, "Leave by")
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the heads-up didn't come")
        mark("arrived")
        hold(3.2)
        card.tap()
        XCTAssertTrue(says(app, "Open in Calendar"), "no event card")
        mark("opened")
        XCTAssertTrue(app.buttons["Directions"].firstMatch.waitForExistence(timeout: 15), "no map")
        mark("map")
        hold(5.5)
        mark("end")
    }

    /// 7:02: the Week Ahead on top of the deck, its strip of days; opened: the week as a calendar,
    /// scrolled to its end.
    func testDayWeek() throws {
        let app = try day("week", ["-echo.screen", "sessions"])
        let card = deckCard(app, "Week ahead")
        XCTAssertTrue(card.waitForExistence(timeout: 20), "no Week Ahead")
        hold(1.0)
        mark("start")
        hold(1.8)
        card.tap()
        XCTAssertTrue(says(app, "Team planning"), "no calendar")
        mark("opened")
        hold(2.2)
        drag(app, from: CGVector(dx: 0.5, dy: 0.8), to: CGVector(dx: 0.5, dy: 0.45), velocity: 260)
        mark("scrolled")
        hold(2.5)
        mark("end")
    }

    /// Idea cards: one put away with a swipe left, one taken with a swipe right, and Sol doing it.
    func testDayIdeas() throws {
        let app = try day("ideas", ["-echo.screen", "sessions"])
        let first = app.staticTexts["Learn the bagpipes"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20), "no idea cards")
        hold(1.0)
        mark("start")
        hold(1.2)
        slide(first, by: -230)
        mark("notnow")
        hold(1.4)
        let second = app.staticTexts["Book the vet for Pickles"].firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        slide(second, by: 230)
        mark("doit")
        XCTAssertTrue(says(app, "tomorrow at 3:30"))
        mark("booked")
        hold(3.0)
        mark("end")
    }

    /// @Home in a chat with Sol: the bots offered, Home picked, the question sent, Home's answer
    /// here under its face.
    func testDayAside() throws {
        let app = try day("aside", ["-echo.fresh"])
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        hold(1.5)
        mark("start")
        hold(0.8)
        field.tap()
        hold(0.5)
        field.typeText("@Ho")
        let home = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "@home")).firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 5), "Home wasn't offered")
        mark("offered")
        hold(1.2)
        home.tap()
        field.typeText("is the garage shut?")
        hold(0.6)
        app.buttons.matching(identifier: "Send").allElementsBoundByIndex.last { $0.isHittable }?.tap()
        mark("sent")
        XCTAssertTrue(says(app, "8:12"))
        mark("answered")
        hold(3.0)
        mark("end")
    }

    /// A question typed to Sol and sent; the reply's own words, once they show.
    private func ask(_ app: XCUIApplication, _ question: String) {
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        hold(1.5)
        mark("start")
        hold(0.6)
        field.tap()
        hold(0.4)
        field.typeText(question)
        hold(0.5)
        app.buttons.matching(identifier: "Send").allElementsBoundByIndex.last { $0.isHittable }?.tap()
        mark("sent")
    }

    /// 6:30 PM: "Where should we go for dinner?", Sol's choice card, one picked, and Sol on it, with
    /// a map of the place's address.
    func testDayDinner() throws {
        let app = try day("dinner", ["-echo.fresh"])
        ask(app, "Where should we go for dinner?")
        let lupa = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Lupa Trattoria'")).firstMatch
        XCTAssertTrue(lupa.waitForExistence(timeout: 15), "no choice card")
        mark("card")
        XCTAssertTrue(says(app, "all open now"))
        hold(2.0)
        lupa.tap()
        mark("picked")
        XCTAssertTrue(says(app, "Table for four"))
        mark("confirmed")
        // Its address gets a map (`AddressMaps`), under the reply: brought up over the composer.
        XCTAssertTrue(app.buttons["Directions"].firstMatch.waitForExistence(timeout: 15), "no map")
        mark("map")
        hold(1.2)
        drag(app, from: CGVector(dx: 0.5, dy: 0.72), to: CGVector(dx: 0.5, dy: 0.52), velocity: 220)
        mark("scrolled")
        hold(3.5)
        mark("end")
    }

    /// 8:00 PM: the cabin's packing list as a checklist card, the last three things ticked off.
    func testDayPacking() throws {
        let app = try day("packing", ["-echo.fresh"])
        ask(app, "Make me a packing list for the cabin")
        XCTAssertTrue(says(app, "Cabin weekend"), "no checklist card")
        mark("card")
        XCTAssertTrue(says(app, "packed already"))
        hold(1.6)
        for item in ["Rain jackets", "S'mores supplies", "Fishing rods"] {
            // (a toggle since the 10-30 redesign, not a button)
            let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", item)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "no \(item)")
            row.tap()
            mark("ticked")
            hold(0.9)
        }
        mark("done")
        hold(3.0)
        mark("end")
    }

    // MARK: The 2.3 day (design/video, `make_day23.py`): the new cards and proactive moments

    /// 7:30: "What's my day look like?", today as a timeline (the walk over, a free stretch, the
    /// now line); the dentist tapped open in place.
    func testDayToday() throws {
        let app = try day("today", ["-echo.fresh"])
        ask(app, "What's my day look like?")
        XCTAssertTrue(says(app, "Free for"), "no timeline")
        mark("card")
        XCTAssertTrue(says(app, "when to leave"))
        mark("answered")
        hold(2.6)
        let dentist = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Dentist'")).firstMatch
        if dentist.waitForExistence(timeout: 5) { dentist.tap() }
        mark("opened")
        hold(3.0)
        mark("end")
    }

    /// 10:15: "Good coffee near me?", answered from where the phone is: the places on a map,
    /// walks measured from here.
    func testDayCoffee() throws {
        let app = try day("coffee", ["-echo.fresh"])
        ask(app, "Good coffee near me?")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Directions to'")).firstMatch.waitForExistence(timeout: 30), "no places card")
        mark("card")
        hold(5.0)
        mark("end")
    }

    /// 12:10: "Will it rain this afternoon?", the weather card with the storms called out.
    func testDayRain() throws {
        let app = try day("rain", ["-echo.fresh"])
        ask(app, "Will it rain this afternoon?")
        XCTAssertTrue(says(app, "Storms likely"), "no weather card")
        mark("card")
        hold(5.0)
        mark("end")
    }

    /// 1:30 PM: the dentist's heads-up arriving (banner, deck), opened: the event card and the map.
    func testDayAfternoon() throws {
        let app = try day("afternoon", ["-echo.screen", "sessions", "-echo.demoDayAt", "3"])
        allowNotifications()
        let card = deckCard(app, "Leave by")
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the heads-up didn't come")
        mark("arrived")
        hold(3.2)
        card.tap()
        XCTAssertTrue(says(app, "Open in Calendar"), "no event card")
        mark("opened")
        XCTAssertTrue(app.buttons["Directions"].firstMatch.waitForExistence(timeout: 15), "no map")
        mark("map")
        hold(5.5)
        mark("end")
    }

    /// 2:00 PM: the Leave-By Alert, worked out on the phone, as a banner over the chat list; then
    /// held open, with Open in Maps.
    func testDayLeave() throws {
        _ = try day("leave", ["-echo.screen", "sessions", "-echo.demoDayAt", "3"])
        allowNotifications()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Time to leave'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "no Leave-By Alert")
        mark("banner")
        hold(3.0)
        if ProcessInfo.processInfo.environment["PROMO_EXPAND"] == "1" {
            banner.press(forDuration: 1.0)
            mark("expanded")
            hold(3.5)
        }
        mark("end")
    }

    /// 7:50, again: the timeline's free stretch tapped, Apple's new-event editor at its start, a
    /// title typed, Add.
    func testDayAddEvent() throws {
        let app = try day("today", ["-echo.fresh"])
        ask(app, "What's my day look like?")
        let free = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Free for'")).firstMatch
        XCTAssertTrue(free.waitForExistence(timeout: 30), "no free stretch")
        XCTAssertTrue(says(app, "when to leave"))
        mark("card")
        hold(2.0)
        free.tap()
        mark("tapped")
        let title = app.textFields["Title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "no event editor")
        mark("editor")
        hold(1.2)
        title.tap()
        title.typeText("Walk by the lake")
        mark("typed")
        hold(1.0)
        // Add: the editor's tick, top right (Apple's editor; its button isn't found by name here).
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.89, dy: 0.105)).tap()
        mark("added")
        hold(2.5)
        mark("end")
    }

    /// 10:40: a watch and a follow-up asked for in words.
    func testDayWatchAsk() throws {
        let app = try day("watchask", ["-echo.fresh"])
        ask(app, "Let me know when the bike part ships. I'll call the plumber tomorrow.")
        XCTAssertTrue(says(app, "plumber tomorrow at 9"), "no answer")
        mark("answered")
        hold(3.5)
        mark("end")
    }

    /// 1:45 PM: the traffic re-check, heavier: leave by 1:55 now.
    func testDayTraffic() throws {
        _ = try day("traffic", ["-echo.screen", "sessions", "-echo.demoDayAt", "3"])
        allowNotifications()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'traffic is heavier'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "no re-check")
        mark("banner")
        hold(4.5)
        mark("end")
    }

    /// 4:20 PM: the bike part's watch says it shipped, as a banner over Watches & Follow-ups, and
    /// its row says so too, with the plumber's follow-up below.
    func testDayShipped() throws {
        let app = try day("shipped", ["-echo.screen", "watches", "-echo.demoDayAt", "4"])
        allowNotifications()
        XCTAssertTrue(app.navigationBars["Watches & Follow-ups"].waitForExistence(timeout: 20), "no Watches")
        mark("start")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'bike part'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "no watch note")
        mark("banner")
        XCTAssertTrue(says(app, "Arriving Thursday"), "the row didn't change")
        mark("row")
        hold(3.5)
        mark("end")
    }

    /// 11:30: Coder's approval card in plain words (the delete in red); Allow Once.
    func testDayApproval() throws {
        let app = try day("approval")
        let allow = app.buttons["Allow Once"].firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 20), "no approval card")
        hold(1.0)
        mark("start")
        hold(3.0)
        allow.tap()
        mark("allowed")
        hold(3.0)
        mark("end")
    }

    /// 3:35 PM: "Tell Ana I'm running 15 minutes late for pickup", the email drawn as itself; Send.
    func testDayEmail() throws {
        let app = try day("email", ["-echo.fresh"])
        ask(app, "Tell Ana I'm running 15 minutes late for pickup")
        XCTAssertTrue(says(app, "Running late for pickup"), "no email card")
        mark("card")
        XCTAssertTrue(says(app, "tap Send"))
        hold(2.8)
        let send = app.buttons.matching(NSPredicate(format: "label == 'Send'")).allElementsBoundByIndex.last { $0.isHittable }
        XCTAssertNotNil(send, "no Send on the card")
        send?.tap()
        mark("sent")
        XCTAssertTrue(says(app, "writes back"))
        mark("answered")
        hold(3.0)
        mark("end")
    }

    /// Triggers from Your iPhone, down to its ideas (arriving home first among them).
    func testDayTriggers() throws {
        let app = try day("triggers", ["-echo.screen", "triggers"])
        XCTAssertTrue(app.navigationBars["Triggers from Your iPhone"].waitForExistence(timeout: 20))
        hold(1.0)
        mark("start")
        hold(1.0)
        drag(app, from: CGVector(dx: 0.5, dy: 0.78), to: CGVector(dx: 0.5, dy: 0.42), velocity: 260)
        mark("scrolled")
        hold(3.0)
        mark("end")
    }

    /// Arriving home: Redde in the background, as an automation runs it, and Home's answer comes
    /// as Redde's notification over the Home Screen.
    func testDayHome() throws {
        let app = try day("home", ["-echo.demoDayAt", "7"])
        allowNotifications()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 20))
        hold(0.8)
        XCUIDevice.shared.press(.home)
        mark("home")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Welcome home'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "no notification")
        mark("banner")
        hold(4.0)
        mark("end")
    }

    /// 21:00: the Evening wrap-up on top of the Briefings deck, opened.
    func testDayEvening() throws {
        let app = try day("evening", ["-echo.screen", "sessions"])
        let row = deckCard(app, "Evening wrap-up")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no wrap-up")
        hold(1.0)
        mark("start")
        hold(1.8)
        row.tap()
        XCTAssertTrue(says(app, "Waiting on you"))
        mark("opened")
        hold(3.5)
        mark("end")
    }

    /// Make This a Routine over the dinner plan: every week, on Sundays.
    func testDayRoutine() throws {
        let app = try day("routine")
        XCTAssertTrue(app.navigationBars["Make This a Routine"].waitForExistence(timeout: 20))
        hold(0.8)
        mark("start")
        hold(0.8)
        pick(app, "Run It", "Every week")
        hold(0.8)
        pick(app, "Day", "Sunday")
        hold(2.0)
        mark("end")
    }

    /// Agent Activity, the day so far.
    func testDayActivity() throws {
        let app = try day("activity", ["-echo.screen", "activity"])
        XCTAssertTrue(app.navigationBars["Agent Activity"].waitForExistence(timeout: 20))
        XCTAssertTrue(says(app, "nothing new"))
        hold(0.8)
        mark("start")
        hold(3.5)
        mark("end")
    }

    /// Plugin Updates: three, all updated at once.
    func testDayPlugins() throws {
        let app = try day("plugins", ["-echo.screen", "pluginUpdates"])
        let all = app.buttons["Update All"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 20))
        hold(0.8)
        mark("start")
        hold(1.0)
        all.tap()
        mark("updating")
        hold(3.2)
        mark("end")
    }

    /// New Watch on the garage door: how often, Home watching, a change handed to Sol.
    func testDayWatch() throws {
        let app = try day("watch")
        XCTAssertTrue(app.navigationBars["New Watch"].waitForExistence(timeout: 20))
        hold(0.8)
        mark("start")
        hold(0.6)
        pick(app, "How often", "Every 15 minutes")
        hold(0.6)
        pick(app, "Who Watches", "Home")
        hold(0.6)
        pick(app, "When It Changes", "Hand It to Sol")
        hold(2.2)
        mark("end")
    }

    // MARK: Redde 2.4 (design/video, `make_24.py`)

    /// 2.4's sample data in the standard theme, dark, as the 2.4 screenshots: the inbox, two goals,
    /// the briefings, the bots and the made-up Coming Up day, on the chat list.
    private func v24(_ extra: [String] = []) throws -> XCUIApplication {
        try launch(["-echo.demoInbox", "two", "-echo.demoGoals", "-echo.demoBriefings", "-echo.demoComingUp",
                    "-echo.demoProjects", "-echo.demoBots", "-displayName", "Sol", "-echo.clearDrafts",
                    "-theme", "standard", "-appearance", "dark"] + extra)
    }

    /// The goal's tile in the Today row tapped: its page, then down to the plan.
    func testV24Goal() throws {
        let app = try v24(["-echo.screen", "sessions"])
        let tile = app.staticTexts["Run a 10K by March"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "no goal tile")
        hold(1.5)
        mark("start")
        hold(1.0)
        tile.tap()
        XCTAssertTrue(app.staticTexts["Last Check-in"].firstMatch.waitForExistence(timeout: 10))
        mark("open")
        hold(2.5)
        drag(app, from: CGVector(dx: 0.5, dy: 0.8), to: CGVector(dx: 0.5, dy: 0.35))
        mark("plan")
        hold(2.5)
        mark("end")
    }

    /// The Inbox's tile tapped: Important, then Needs Reply, then an email in the reader.
    func testV24Inbox() throws {
        let app = try v24(["-echo.screen", "sessions"])
        let tile = app.staticTexts["Inbox"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "no inbox tile")
        hold(1.5)
        mark("start")
        hold(1.0)
        tile.tap()
        let reply = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Needs Reply")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "no piles")
        mark("open")
        hold(2.0)
        reply.tap()
        mark("reply")
        hold(2.0)
        let row = app.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no email")
        row.tap()
        mark("email")
        hold(3.0)
        mark("end")
    }

    /// The Today row slid along, then Planned: what the agent will do next.
    func testV24Today() throws {
        let app = try v24(["-echo.screen", "sessions"])
        let tile = app.staticTexts["Inbox"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "no Today row")
        hold(1.5)
        mark("start")
        hold(1.2)
        slide(tile, by: -320, hold: 0.4)
        mark("slid")
        hold(1.6)
        app.buttons["drawer.place.planned"].firstMatch.tap()
        mark("planned")
        hold(3.5)
        mark("end")
    }

    /// Memory: a fact added in words and saved.
    func testV24Memory() throws {
        // (only the memory's sample data: with the rest, something presented at launch closes the
        // page again a few seconds in)
        let app = try launch(["-echo.demoMemory", "-echo.screen", "memory", "-echo.clearDrafts", "-theme", "standard", "-appearance", "dark"])
        let add = app.navigationBars["Memory"].waitForExistence(timeout: 20) ? app.collectionViews.buttons["Add"].firstMatch : app.buttons["no memory page"]
        XCTAssertTrue(add.waitForExistence(timeout: 20), "no memory page")
        hold(1.2)
        mark("start")
        hold(1.0)
        add.tap()
        hold(0.6)
        app.typeText("Training for a 10K in March.")   // (the new row has the focus)
        mark("typed")
        hold(1.0)
        let save = app.navigationBars.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "no Save")
        save.tap()
        mark("saved")
        hold(2.5)
        mark("end")
    }

    // MARK: Agents, for Reddit (design/video, `make_agents.py`)

    /// The sample bots on the new drawer, in the standard theme, dark (`DemoAgents`: each bot's chat
    /// opens from the Team row, and the answers are canned). Main agent: Sol.
    /// On the Dashboard connection (as `-echo.demoProjects` has it; `launch`'s `-transport` would take
    /// the app back off it), so @ offers the bots.
    private func agents(_ extra: [String] = []) throws -> XCUIApplication {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PROMO_VIDEO"] == "1", "Promo video shots run on request")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat
            + ["-echo.demoHosts", "-transport", "hermesServe", "-echo.demoProjects", "-echo.demoBots", "-echo.demoAgents", "-displayName", "Sol",
               "-echo.clearDrafts", "-suggestFollowUps", "<false/>", "-mutes", "<>", "-theme", "standard", "-appearance", "dark"] + extra
        app.launch()
        return app
    }

    /// The list, from an open chat (the iPhone's chat covers it).
    private func toList(_ app: XCUIApplication) {
        let list = app.buttons["Conversations"].firstMatch
        if list.waitForExistence(timeout: 3), list.isHittable { list.tap() }
    }

    /// A face in the drawer's Team row.
    private func member(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let all = app.buttons.matching(NSPredicate(format: "label == %@", name))
        return all.hittable(within: 10) ?? all.firstMatch
    }

    /// The drawer, then Quill, Scout and Fix-it opened from the Team row in turn, back to the
    /// drawer between them.
    func testAgentsTeam() throws {
        let app = try agents(["-echo.screen", "sessions", "-echo.demoMarks"])
        XCTAssertTrue(app.staticTexts["Good morning"].firstMatch.waitForExistence(timeout: 20), "no drawer")
        hold(1.5)
        mark("start")
        hold(2.0)
        for (name, words) in [("Quill", "fog"), ("Scout", "Falls Loop"), ("Fix-it", "backup")] {
            member(app, name).tap()
            XCTAssertTrue(app.text(containing: words).waitForExistence(timeout: 10), "\(name)'s chat didn't open")
            mark(name.lowercased().replacingOccurrences(of: "-", with: ""))
            hold(2.0)
            toList(app)
            mark("list")
            hold(1.2)
        }
        mark("end")
        hold(1.0)
    }

    /// Sol's chat: a hike asked for and answered as it streams, Scout asked with an @ (its answer
    /// here, under its face), the invite handed to Quill (its progress under Sol's reply), and
    /// Quill's chat opened from there.
    func testAgentsChat() throws {
        let app = try agents()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        XCTAssertTrue(app.text(containing: "call the vet").waitForExistence(timeout: 10), "not Sol's chat")
        hold(1.5)
        mark("start")
        hold(0.8)
        field.tap()
        hold(0.4)
        func send() { app.buttons.matching(identifier: "Send").allElementsBoundByIndex.last { $0.isHittable }?.tap() }
        field.typeText("Find us a hike for Saturday morning")
        hold(0.4)
        send()
        mark("asked")
        XCTAssertTrue(app.text(containing: "waterfall halfway").waitForExistence(timeout: 20), "no hike")
        mark("hike")
        hold(2.5)
        field.tap()
        field.typeText("@sc")
        let scout = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "@scout")).firstMatch
        XCTAssertTrue(scout.waitForExistence(timeout: 5), "Scout wasn't offered")
        mark("offered")
        hold(1.0)
        scout.tap()
        hold(0.6)
        // (the caret stays where "@sc" ended: put it at the end of "@scout ")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        hold(0.3)
        field.typeText("is the trail open?")
        hold(0.4)
        send()
        mark("mentioned")
        XCTAssertTrue(app.text(containing: "footbridge").waitForExistence(timeout: 20), "Scout didn't answer")
        mark("scout")
        hold(2.5)
        field.tap()
        field.typeText("Ask Quill to write the invite")
        hold(0.4)
        send()
        mark("handed")
        let answered = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Quill answered")).firstMatch
        XCTAssertTrue(answered.waitForExistence(timeout: 30), "Quill never answered")
        mark("answered")
        hold(1.8)
        answered.tap()
        XCTAssertTrue(app.text(containing: "Coffee").waitForExistence(timeout: 10), "Quill's chat didn't open on the invite")
        mark("quill")
        hold(3.0)
        mark("end")
    }

    /// The group chat's voice screen: one question, and Sol, Scout and Quill answering in turn,
    /// each in its own voice (Kokoro's, at `TEST_RUNNER_KOKORO_URL`, when given).
    func testAgentsVoiceRound() throws {
        var voice: [String] = []
        if let url = ProcessInfo.processInfo.environment["KOKORO_URL"], !url.isEmpty {
            voice = ["-replyVoice", "kokoro", "-kokoroURL", url, "-voiceSpeed", "1"]
        }
        let app = try agents(["-echo.screen", "sessions", "-echo.openGroup", "-echo.demoRound", "-echo.groupVoice"] + voice)
        var label: XCUIElement?
        for name in ["Sol", "Scout", "Quill"] {
            label = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "\(name) is speaking")).firstMatch
            XCTAssertTrue(label!.waitForExistence(timeout: 40), "\(name) never spoke")
            mark(name.lowercased())
        }
        if let label { wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: label)], timeout: 30) }
        mark("end")
        hold(1.5)
    }

    /// The group chat, a bot's reply coming in as it is written.
    func testAgentsGroup() throws {
        let app = try agents(["-echo.screen", "sessions", "-echo.openGroup", "-echo.demoDraft"])
        XCTAssertTrue(app.text(containing: "Weekend hike").waitForExistence(timeout: 20), "no group chat")
        mark("start")
        hold(9.0)
        mark("end")
    }

    /// What waits on you, from several bots, on the drawer: the stack opened.
    func testAgentsWaiting() throws {
        let app = try agents(["-echo.screen", "sessions", "-echo.demoMarks", "-echo.demoBotWait"])
        XCTAssertTrue(app.staticTexts["Good morning"].firstMatch.waitForExistence(timeout: 20), "no drawer")
        hold(1.5)
        mark("start")
        hold(1.5)
        let more = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "more")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "no stack")
        more.tap()
        mark("opened")
        hold(2.5)
        mark("end")
    }

    /// From the drawer, the server menu to Redde's demo agent (a coding agent, as Claude Code or
    /// Codex through the bridge): a new chat, "Fix the notes", its approval allowed, and back to
    /// Home and the team.
    func testAgentsCodingAgent() throws {
        let app = try agents(["-echo.screen", "sessions", "-echo.demoMarks", "-echo.spareAgent", "Demo Agent"])
        XCTAssertTrue(app.staticTexts["Good morning"].firstMatch.waitForExistence(timeout: 20), "no drawer")
        hold(1.5)
        mark("start")
        hold(1.2)
        let server = app.buttons["Server"].firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 5), "no server menu")
        server.tap()
        let agent = app.buttons["Demo Agent"].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: 5), "the demo agent isn't in the menu")
        mark("menu")
        hold(1.2)
        agent.tap()
        mark("switched")
        hold(2.0)
        let new = app.buttons.matching(NSPredicate(format: "label == 'New conversation'")).allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(new, "no New Chat")
        new?.tap()
        let composer = app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "no message field")
        hold(1.0)
        composer.tap()
        hold(0.4)
        composer.typeText("Fix the notes")
        hold(0.4)
        app.buttons.matching(identifier: "Send").allElementsBoundByIndex.last { $0.isHittable }?.tap()
        mark("sent")
        let allow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow'")).firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 60), "the demo agent didn't ask")
        mark("asked")
        if app.keyboards.firstMatch.exists {
            let hide = app.keyboards.buttons["Hide keyboard"]
            if hide.exists { hide.tap() } else { app.swipeDown() }
        }
        hold(2.0)
        allow.tap()
        mark("allowed")
        XCTAssertTrue(app.text(containing: "all three checks pass").waitForExistence(timeout: 30), "the agent didn't finish")
        mark("done")
        hold(2.5)
        toList(app)
        hold(1.0)
        let back = app.buttons["Server"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no server menu on the bridge")
        back.tap()
        let home = app.buttons["Home"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 5), "Home isn't in the menu")
        hold(1.0)
        home.tap()
        mark("home")
        XCTAssertTrue(app.staticTexts["Team"].firstMatch.waitForExistence(timeout: 10) || app.staticTexts["TEAM"].firstMatch.exists, "the team isn't back")
        hold(3.0)
        mark("end")
    }

    // MARK: Agents, the coding agents' cut (2026-11-15)

    /// The whole job in one take, with a ring where the screen is touched: the server menu with the
    /// Hermes server and the stand-ins for Claude Code and Codex (`-echo.demoCoders`); Sol asked what's
    /// left; New Chat held for a chat with Claude Code, which fixes the bug (its approval allowed) and
    /// shows its change; New Chat held again for Codex, which reviews it and asks to run tests (left
    /// waiting); back to Home and Quill for the release notes; and the drawer's stack, Codex's ask on
    /// top of the bots'.
    func testAgentsCoders() throws {
        let app = try agents(["-echo.screen", "sessions", "-echo.demoMarks", "-echo.demoCoders", "-echo.showTouches"])
        XCTAssertTrue(app.staticTexts["Good morning"].firstMatch.waitForExistence(timeout: 20), "no drawer")
        func send() { app.buttons.matching(identifier: "Send").allElementsBoundByIndex.last { $0.isHittable }?.tap() }
        func hideKeyboard() {
            guard app.keyboards.firstMatch.exists else { return }
            let hide = app.keyboards.buttons["Hide keyboard"]
            if hide.exists { hide.tap() } else { app.swipeDown() }
        }
        func ask(_ words: String) {
            let composer = app.textFields["composer"].exists ? app.textFields["composer"] : app.textFields.firstMatch
            XCTAssertTrue(composer.waitForExistence(timeout: 20), "no message field")
            composer.tap()
            hold(0.5)
            composer.typeText(words)
            hold(0.8)
            send()
        }
        /// New Chat held, and a chat with `name` picked from its menu.
        func chat(with name: String) {
            hideKeyboard()
            let new = app.buttons["new-chat-elsewhere"].firstMatch
            XCTAssertTrue(new.waitForExistence(timeout: 10), "no New Chat to hold")
            new.press(forDuration: 1.0)
            let pick = app.buttons["new-chat-elsewhere-\(name)"].firstMatch
            XCTAssertTrue(pick.waitForExistence(timeout: 5), "\(name) isn't in New Chat's menu")
            mark("held" + name.lowercased().filter(\.isLetter))
            hold(2.0)
            pick.tap()
            mark("with" + name.lowercased().filter(\.isLetter))
        }
        hold(2.0)
        mark("start")
        hold(1.5)
        // Every agent: the Hermes server and the coding agents, in the server menu.
        let server = app.buttons["Server"].firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 5), "no server menu")
        server.tap()
        XCTAssertTrue(app.buttons["Codex"].firstMatch.waitForExistence(timeout: 5), "the coding agents aren't in the menu")
        mark("menu")
        hold(3.5)
        app.staticTexts["Good morning"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        mark("closed")
        hold(2.0)
        // Sol: what's left.
        member(app, "Sol").tap()
        XCTAssertTrue(app.text(containing: "call the vet").waitForExistence(timeout: 10), "not Sol's chat")
        mark("sol")
        hold(1.5)
        ask("What's left before the release?")
        mark("asked")
        XCTAssertTrue(app.text(containing: "release notes").waitForExistence(timeout: 20), "Sol didn't answer")
        mark("answered")
        hideKeyboard()
        hold(3.5)
        // Claude Code: the fix.
        chat(with: "Claude Code")
        hold(2.5)
        ask("Fix the login bug")
        mark("sent")
        let allow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow'")).firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 60), "Claude Code didn't ask")
        hideKeyboard()
        mark("approval")
        hold(3.0)
        allow.tap()
        mark("allowed")
        XCTAssertTrue(app.text(containing: "42 tests pass").waitForExistence(timeout: 30), "Claude Code didn't finish")
        mark("fixed")
        hold(3.5)
        // Its change.
        var changes = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'View changes'")).firstMatch
        if !changes.waitForExistence(timeout: 2) {
            let steps = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'tools' OR label CONTAINS[c] 'tool steps'")).allElementsBoundByIndex.last { $0.isHittable }
            steps?.tap()
            mark("steps")
            hold(1.5)
            let edit = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Edit Login.swift'")).allElementsBoundByIndex.last { $0.isHittable }
                ?? app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Edit Login.swift'")).allElementsBoundByIndex.last { $0.isHittable }
            edit?.tap()
            mark("edit")
            hold(1.5)
            changes = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'View changes'")).firstMatch
        }
        XCTAssertTrue(changes.waitForExistence(timeout: 5), "no View changes")
        changes.tap()
        mark("diff")
        hold(4.5)
        let done = app.buttons["Done"].firstMatch
        if done.exists, done.isHittable { done.tap() } else { app.swipeDown() }
        mark("diffclosed")
        hold(1.5)
        // Codex: the review.
        chat(with: "Codex")
        hold(2.5)
        ask("Review Claude Code's change")
        mark("reviewsent")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow'")).firstMatch.waitForExistence(timeout: 60), "Codex didn't ask")
        hideKeyboard()
        mark("reviewed")
        hold(4.5)
        // Back to the team: Home, then Quill.
        toList(app)
        mark("drawer")
        hold(1.5)
        let back = app.buttons["Server"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no server menu on Codex")
        back.tap()
        let home = app.buttons["Home"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 5), "Home isn't in the menu")
        hold(1.5)
        home.tap()
        mark("home")
        hold(2.5)
        member(app, "Quill").tap()
        XCTAssertTrue(app.text(containing: "fog").waitForExistence(timeout: 10), "Quill's chat didn't open")
        mark("quill")
        hold(1.5)
        ask("Write the release notes from today's changes")
        mark("notessent")
        XCTAssertTrue(app.text(containing: "shorter version").waitForExistence(timeout: 20), "Quill didn't write the notes")
        mark("notes")
        hideKeyboard()
        hold(4.0)
        // What needs you: Codex's ask on top of the bots'.
        toList(app)
        mark("needs")
        hold(3.0)
        let more = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "more")).firstMatch
        if more.waitForExistence(timeout: 3) { more.tap() }
        mark("opened")
        hold(4.5)
        mark("end")
    }
}
