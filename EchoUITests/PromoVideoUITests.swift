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
        let app = try bots(["-echo.screen", "sessions", "-conversations.section", "sessions", "-mutes", "<>",
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
        let dir = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["SHOT_DIR"], "SHOT_DIR is where they go"))
        let kind = UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "ph"
        var voice: [String] = []
        if let url = ProcessInfo.processInfo.environment["KOKORO_URL"], !url.isEmpty {
            voice = ["-replyVoice", "kokoro", "-kokoroURL", url, "-voiceSpeed", "1"]
        }
        // The iPad's sidebar shows the library under the bots: the sample one, as its other shots.
        let screen = kind == "ph" ? ["-echo.screen", "sessions"] : ["-echo.demoLibrary"]
        let list = try bots(screen + ["-conversations.section", "sessions", "-echo.demoMarks", "-mutes", "<>"])
        XCTAssertTrue(list.staticTexts["Weekend hike"].firstMatch.waitForExistence(timeout: 20))
        hold(3)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appending(path: "\(kind)-bots.png"))
        let room = try bots(screen + ["-conversations.section", "sessions", "-mutes", "<>",
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
        app.openSettingsPage("Agent")
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

    /// 7:00: the chat list; the dentist's heads-up comes, as a banner and at the top; opened.
    func testDayMorning() throws {
        let app = try day("morning", ["-echo.screen", "sessions", "-echo.demoDayAt", "3"])
        allowNotifications()
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Dentist'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the heads-up didn't come")
        mark("arrived")
        hold(3.2)
        row.tap()
        XCTAssertTrue(says(app, "insurance card"))
        mark("opened")
        hold(3.0)
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
        XCTAssertTrue(says(app, "Thursday at 3:30"))
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

    /// 6:30 PM: "Where should we go for dinner?", Sol's choice card, one picked, and Sol on it.
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
        hold(3.0)
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
            let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", item)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "no \(item)")
            row.tap()
            mark("ticked")
            hold(0.9)
        }
        XCTAssertTrue(says(app, "Everything's done"))
        mark("done")
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

    /// 21:00: the Evening wrap-up in Briefings, opened.
    func testDayEvening() throws {
        let app = try day("evening", ["-echo.screen", "sessions"])
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Evening wrap-up'")).firstMatch
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
}
