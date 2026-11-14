import XCTest

/// The ACP connection end to end: the Redde bridge in front of `hermes acp`, answered by the
/// lab's stub model (`scripts/acp-lab.sh up`: ws://127.0.0.1:18765, token labtoken, which a
/// simulator shares with the Mac). Setup through its own screen, then a chat with a reply, a
/// command that asks first, the chat in the list, and the chat reopened from the agent's history.
/// Skips without the lab.
@MainActor
final class AcpUITests: XCTestCase {
    private let bridge = "127.0.0.1:18765"

    private func labIsUp() -> Bool {
        var request = URLRequest(url: URL(string: "http://\(bridge)/agents")!)
        request.setValue("Bearer labtoken", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 3
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var up = false
        URLSession.shared.dataTask(with: request) { data, _, _ in
            up = data.map { String(decoding: $0, as: UTF8.self).contains("\"hermes\"") } ?? false
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return up
    }

    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func reach(_ element: XCUIElement, in app: XCUIApplication, _ what: String) {
        for _ in 0 ..< 8 where !(element.exists && element.isHittable) { app.swipeUp() }
        XCTAssertTrue(element.exists && element.isHittable, "\(what) isn't on screen")
    }

    /// Picking an agent in Setup on a Hermes server that is in use adds a server for it: Setup says
    /// so, and the Hermes server keeps its address and sign-in (2026-11-12). Needs no lab.
    func testAnAgentOnAServerInUseIsANewServer() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.screen", "setup", "-transport", "hermesServe", "-serveURL", "http://hermes.test:9119",
                               "-serveUsername", "sam"]
        app.launchEnvironment["ECHO_TEST_SERVE_PASSWORD"] = "pw"
        app.launch()
        XCTAssertTrue(app.navigationBars["Set up Redde"].waitForExistence(timeout: 20), "Setup didn't open")
        let agent = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Claude Code, Codex'")).firstMatch
        reach(agent, in: app, "The agent connection")
        agent.tap()
        let said = app.text(containing: "This is a new server.")
        XCTAssertTrue(said.waitForExistence(timeout: 5), "Setup didn't say a server was added")
        keep("A new server for the agent")
        XCTAssertTrue(app.textFields["ws://your-computer:8765"].exists, "No bridge address field")
    }

    /// The demo agent, as App Review meets it: picked in Setup with no address or token, then its
    /// tour with an approval, a plan to approve and a question. Needs no lab.
    func testTheDemoAgent() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.screen", "setup", "-transport", "acp", "-acpURL", "", "-acpAgent", "", "-acpFolder", "", "-echo.clearDrafts"]
        app.launchEnvironment["ECHO_TEST_ACP_TOKEN"] = ""   // empty deletes
        app.launch()
        XCTAssertTrue(app.navigationBars["Set up Redde"].waitForExistence(timeout: 20), "Setup didn't open")
        let demo = app.buttons["acp-try-demo"]
        reach(demo, in: app, "Try the Demo Agent")
        demo.tap()
        let test = app.buttons["Test connection"]
        reach(test, in: app, "Test connection")
        test.tap()
        XCTAssertTrue(app.text(containing: "Connected to Demo Agent").waitForExistence(timeout: 20), "The demo agent didn't connect")
        keep("Demo agent in Setup")
        app.navigationBars["Set up Redde"].buttons["Done"].tap()
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 20), "Setup didn't finish into a chat")
        let new = app.buttons["New conversation"].firstMatch
        if new.waitForExistence(timeout: 5) { new.tap() }

        send("Fix the notes", in: app)
        let allow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow'")).firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 30), "No approval card for the command")
        keep("Demo approval")
        allow.tap()
        XCTAssertTrue(app.text(containing: "all three checks pass").waitForExistence(timeout: 30), "The tour didn't finish")
        keep("Demo tour")

        send("Show me a plan", in: app)
        XCTAssertTrue(app.text(containing: "Tidy the notes").waitForExistence(timeout: 30), "The plan wasn't shown")
        keep("Demo plan")
        let go = app.buttons.matching(NSPredicate(format: "label CONTAINS 'go ahead'")).firstMatch
        XCTAssertTrue(go.waitForExistence(timeout: 5), "No way to approve the plan")
        go.tap()
        XCTAssertTrue(app.text(containing: "Plan done").waitForExistence(timeout: 30), "The plan wasn't carried out")

        send("Ask me a question", in: app)
        let hello = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Just a hello'")).firstMatch
        XCTAssertTrue(hello.waitForExistence(timeout: 30), "The question card didn't come")
        keep("Demo question")
        hello.tap()
        XCTAssertTrue(app.text(containing: "Hello from Redde's demo agent").waitForExistence(timeout: 30), "The answer didn't reach the agent")
        keep("Demo answered")
    }

    func testSettingUpABridge() throws {
        continueAfterFailure = false
        try XCTSkipUnless(labIsUp(), "No ACP lab on \(bridge) (scripts/acp-lab.sh up)")
        let app = XCUIApplication()
        app.launchArguments = ["-echo.screen", "setup", "-transport", "acp", "-acpURL", "", "-acpAgent", "", "-acpFolder", ""]
        app.launchEnvironment["ECHO_TEST_ACP_TOKEN"] = ""   // empty deletes
        app.launch()
        XCTAssertTrue(app.navigationBars["Set up Redde"].waitForExistence(timeout: 20), "Setup didn't open")

        let address = app.textFields["ws://your-computer:8765"]
        reach(address, in: app, "The bridge's address field")
        address.tap()
        address.typeText(bridge)
        let token = app.secureTextFields["Token"]
        token.tap()
        token.typeText("labtoken")
        // The bridge has one agent, so it is named rather than picked.
        XCTAssertTrue(app.text(containing: "Hermes").waitForExistence(timeout: 10), "The bridge's agent isn't shown")
        keep("ACP setup filled in")

        let test = app.buttons["Test connection"]
        reach(test, in: app, "Test connection")
        test.tap()
        XCTAssertTrue(app.text(containing: "Connected to Hermes through the Redde bridge").waitForExistence(timeout: 60),
                      "The connection test didn't reach the agent")
        keep("ACP connection tested")
        app.navigationBars["Set up Redde"].buttons["Done"].tap()
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 20), "Setup didn't finish into a chat")
    }

    func testAChatWithTheAgent() throws {
        continueAfterFailure = false
        try XCTSkipUnless(labIsUp(), "No ACP lab on \(bridge) (scripts/acp-lab.sh up)")
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat
            + ["-echo.clearDrafts", "-transport", "acp", "-acpURL", bridge, "-acpAgent", "hermes", "-acpFolder", ""]
        app.launchEnvironment["ECHO_TEST_ACP_TOKEN"] = "labtoken"
        app.launch()

        let composer = app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "No message field")
        // A new chat, whatever the simulator had open.
        let new = app.buttons["New conversation"].firstMatch
        if new.waitForExistence(timeout: 5) { new.tap() }
        send("hello there", in: app)
        XCTAssertTrue(app.text(containing: "[A:alpha]").waitForExistence(timeout: 90), "The agent's reply didn't arrive")
        keep("ACP reply")

        // A command Hermes asks about first: the card, answered from the phone.
        send("please do the danger thing", in: app)
        let allow = app.buttons["Allow Once"]
        XCTAssertTrue(allow.waitForExistence(timeout: 90), "No approval card for the command")
        keep("ACP approval")
        allow.tap()
        XCTAssertTrue(app.text(containing: "[gone]").waitForExistence(timeout: 90), "The command didn't run after allowing it")
        keep("ACP after approval")

        // The chat is the agent's own session: it's in the list, and opens again from its history.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        back.tap()
        let row = app.text(containing: "[A:alpha]")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The chat isn't in the list")
        keep("ACP chat list")
        app.terminate()
        app.launchArguments = XCUIApplication.straightToChat
            + ["-transport", "acp", "-acpURL", bridge, "-acpAgent", "hermes"]
        app.launch()
        let listed = app.text(containing: "[A:alpha]")
        XCTAssertTrue(listed.waitForExistence(timeout: 30), "The chat isn't listed after a relaunch")
        listed.tap()
        XCTAssertTrue(app.text(containing: "please do the danger thing").waitForExistence(timeout: 30), "The reopened chat lost its history")
        XCTAssertTrue(app.text(containing: "[gone]").exists, "The reopened chat lost the agent's reply")
        keep("ACP chat reopened")
    }

    /// A real Claude Code behind a Redde bridge on this Mac, editing a file in a scratch folder: the
    /// step shows its change, and View changes opens the whole diff. Skipped unless it's given the
    /// bridge (`TEST_RUNNER_REDDE_BRIDGE_TOKEN`, `TEST_RUNNER_REDDE_BRIDGE_FOLDER`, and
    /// `TEST_RUNNER_REDDE_SHOTS` for a folder to put screenshots in). Uses Claude Code for real.
    func testClaudeCodesChangeCanBeRead() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let token = env["REDDE_BRIDGE_TOKEN"], !token.isEmpty, let folder = env["REDDE_BRIDGE_FOLDER"] else {
            throw XCTSkip("No Claude Code bridge given (TEST_RUNNER_REDDE_BRIDGE_TOKEN, TEST_RUNNER_REDDE_BRIDGE_FOLDER)")
        }
        func shot(_ name: String) {
            keep(name)
            if let dir = env["REDDE_SHOTS"] {
                try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            }
        }
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat
            + ["-echo.clearDrafts", "-transport", "acp", "-acpURL", "127.0.0.1:8767", "-acpAgent", "claude", "-acpFolder", folder]
        app.launchEnvironment["ECHO_TEST_ACP_TOKEN"] = token
        app.launch()
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 20), "No message field")
        let new = app.buttons["New conversation"].firstMatch
        if new.waitForExistence(timeout: 5) { new.tap() }
        send("Create notes.txt with three lines: one, two, three. Then edit it so the middle line says TWO. Use the Write and Edit tools, no shell. Reply in one short sentence.", in: app)
        // In Manual mode Claude Code asks first; allow each.
        let reply = app.text(containing: "TWO")
        for _ in 0 ..< 60 where !reply.exists {
            let allow = app.buttons["Allow Once"]
            if allow.exists, allow.isHittable { allow.tap() }
            sleep(2)
        }
        XCTAssertTrue(reply.exists, "Claude Code's reply didn't arrive")
        sleep(3)
        shot("acp-edit-reply")
        let fold = app.buttons["Show tool steps"].firstMatch
        if fold.exists { fold.tap() }
        let step = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tool Edit'")).firstMatch
        XCTAssertTrue(step.waitForExistence(timeout: 10), "No Edit step")
        step.tap()
        let view = app.buttons["View changes"]
        XCTAssertTrue(view.waitForExistence(timeout: 10), "The Edit step doesn't offer its change")
        shot("acp-edit-step")
        view.tap()
        XCTAssertTrue(app.staticTexts["+TWO"].waitForExistence(timeout: 10), "The change doesn't show its added line")
        shot("acp-edit-patch")
    }

    /// The same Claude Code in Plan mode: its plan is shown on the card with its own options, words
    /// typed instead send it back to planning with them, and the next plan is approved in auto mode.
    /// The folder needs a notes.txt reading one, two, three.
    func testClaudeCodesPlanIsShownAndAnswered() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let token = env["REDDE_BRIDGE_TOKEN"], !token.isEmpty, let folder = env["REDDE_BRIDGE_FOLDER"] else {
            throw XCTSkip("No Claude Code bridge given (TEST_RUNNER_REDDE_BRIDGE_TOKEN, TEST_RUNNER_REDDE_BRIDGE_FOLDER)")
        }
        func shot(_ name: String) {
            keep(name)
            if let dir = env["REDDE_SHOTS"] {
                try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            }
        }
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat
            + ["-echo.clearDrafts", "-transport", "acp", "-acpURL", "127.0.0.1:8767", "-acpAgent", "claude", "-acpFolder", folder,
               "-acpPicks.ws://127.0.0.1:8767/acp/claude", "{ mode = plan; }"]
        app.launchEnvironment["ECHO_TEST_ACP_TOKEN"] = token
        app.launch()
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 20), "No message field")
        let new = app.buttons["New conversation"].firstMatch
        if new.waitForExistence(timeout: 5) { new.tap() }
        send("Plan how you'd add a fourth line 'four' to notes.txt. Keep the plan to three short bullet points.", in: app)

        let auto = app.buttons["Yes, and use auto mode"]
        XCTAssertTrue(auto.waitForExistence(timeout: 180), "No plan to approve")
        XCTAssertTrue(app.buttons["No, keep planning"].exists, "The plan's options aren't the agent's own")
        XCTAssertTrue(app.text(containing: "four").exists, "The plan isn't on the card")
        shot("acp-plan-card")

        let other = app.textViews["Something else…"].exists ? app.textViews["Something else…"] : app.textFields["Something else…"]
        other.tap()
        other.typeText("Write it as FOUR, in capitals.")
        let arrow = app.buttons.matching(identifier: "Send").allElementsBoundByIndex.first { $0.isHittable && $0.frame.maxY < app.textFields["composer"].frame.minY }
        XCTAssertNotNil(arrow, "No send arrow by the typed words")
        arrow?.tap()
        XCTAssertTrue(app.text(containing: "No, keep planning").waitForExistence(timeout: 20), "Typed words didn't stand for No")
        XCTAssertTrue(app.text(containing: "Write it as FOUR, in capitals.").waitForExistence(timeout: 30), "The words didn't go to the agent")
        XCTAssertTrue(auto.waitForExistence(timeout: 180), "No second plan after the words")
        shot("acp-plan-again")
        auto.tap()
        let done = app.text(containing: "FOUR")
        for _ in 0 ..< 60 where !(done.exists && !auto.exists) { sleep(2) }
        sleep(5)
        shot("acp-plan-done")
    }

    /// The same Claude Code, steered: words typed while it works join the reply (Steer this
    /// reply) instead of waiting for it, and it acts on them before it ends.
    func testClaudeCodeCanBeSteered() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let token = env["REDDE_BRIDGE_TOKEN"], !token.isEmpty, let folder = env["REDDE_BRIDGE_FOLDER"] else {
            throw XCTSkip("No Claude Code bridge given (TEST_RUNNER_REDDE_BRIDGE_TOKEN, TEST_RUNNER_REDDE_BRIDGE_FOLDER)")
        }
        func shot(_ name: String) {
            keep(name)
            if let dir = env["REDDE_SHOTS"] {
                try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            }
        }
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat
            + ["-echo.clearDrafts", "-transport", "acp", "-acpURL", "127.0.0.1:8767", "-acpAgent", "claude", "-acpFolder", folder,
               "-acpPicks.ws://127.0.0.1:8767/acp/claude", "{ mode = bypassPermissions; }"]
        app.launchEnvironment["ECHO_TEST_ACP_TOKEN"] = token
        app.launch()
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 20), "No message field")
        let new = app.buttons["New conversation"].firstMatch
        if new.waitForExistence(timeout: 5) { new.tap() }
        send("Write the numbers from 1 to 400 as words, one per line, with nothing else. No tools.", in: app)

        let steer = app.buttons["Steer this reply"]
        let composer = app.textFields["composer"]
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 60), "The reply didn't start")
        XCTAssertTrue(app.text(containing: "three").waitForExistence(timeout: 60), "The reply didn't start writing")
        composer.tap()
        composer.typeText("Also end your reply with the word BANANA.")
        _ = steer.waitForExistence(timeout: 10)
        shot("acp-steer-typed")
        XCTAssertTrue(steer.exists, "No way to steer the reply")
        steer.tap()
        XCTAssertTrue(app.text(containing: "steer queued").waitForExistence(timeout: 20), "Claude Code didn't take the words into the reply")
        let banana = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'BANANA' AND NOT (label CONTAINS 'Also end')")).firstMatch
        XCTAssertTrue(banana.waitForExistence(timeout: 180), "The reply didn't act on the steer")
        shot("acp-steer-done")
    }

    /// Claude Code's chats from the list: one renamed "Steering test" (by testClaudeCodeCanBeSteered
    /// and a rename) is forked, and the copy opens with its history under the new name.
    func testClaudeCodesChatCanBeForked() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let token = env["REDDE_BRIDGE_TOKEN"], !token.isEmpty, let folder = env["REDDE_BRIDGE_FOLDER"] else {
            throw XCTSkip("No Claude Code bridge given (TEST_RUNNER_REDDE_BRIDGE_TOKEN, TEST_RUNNER_REDDE_BRIDGE_FOLDER)")
        }
        func shot(_ name: String) {
            keep(name)
            if let dir = env["REDDE_SHOTS"] {
                try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            }
        }
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat
            + ["-transport", "acp", "-acpURL", "127.0.0.1:8767", "-acpAgent", "claude", "-acpFolder", folder]
        app.launchEnvironment["ECHO_TEST_ACP_TOKEN"] = token
        app.launch()
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 20), "No message field")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.staticTexts.matching(NSPredicate(format: "label == 'Steering test'")).firstMatch
        _ = row.waitForExistence(timeout: 30)
        shot("acp-fork-list")
        let onScreen = app.staticTexts.matching(NSPredicate(format: "label == 'Steering test'")).allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(onScreen, "The chat isn't in the list")
        onScreen?.press(forDuration: 1.2)
        let fork = app.buttons["Fork"]
        XCTAssertTrue(fork.waitForExistence(timeout: 5), "No Fork in the chat's menu")
        shot("acp-fork-menu")
        fork.tap()
        XCTAssertTrue(app.text(containing: "Write the numbers from 1 to 400").waitForExistence(timeout: 60), "The copy didn't open with its history")
        XCTAssertTrue(app.text(containing: "(fork)").waitForExistence(timeout: 10), "The copy isn't named as one")
        sleep(2)
        shot("acp-fork-open")
    }

    /// Claude Code's chats grouped by folder: the scratch folder is a project, and a chat started
    /// in it works there (it reads the folder's notes.txt), though the server's folder is another.
    func testAChatStartsInAFolderClaudeCodeWorkedIn() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let token = env["REDDE_BRIDGE_TOKEN"], !token.isEmpty, let folder = env["REDDE_BRIDGE_FOLDER"] else {
            throw XCTSkip("No Claude Code bridge given (TEST_RUNNER_REDDE_BRIDGE_TOKEN, TEST_RUNNER_REDDE_BRIDGE_FOLDER)")
        }
        func shot(_ name: String) {
            keep(name)
            if let dir = env["REDDE_SHOTS"] {
                try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            }
        }
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat
            + ["-transport", "acp", "-acpURL", "127.0.0.1:8767", "-acpAgent", "claude", "-acpFolder", ""]
        app.launchEnvironment["ECHO_TEST_ACP_TOKEN"] = token
        app.launch()
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 20), "No message field")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let name = URL(fileURLWithPath: folder).lastPathComponent
        let project = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        _ = project.waitForExistence(timeout: 30)
        shot("acp-folders-list")
        XCTAssertTrue(project.exists, "The folder isn't a project in the list")
        project.tap()
        let new = app.navigationBars.buttons["New Conversation"]
        XCTAssertTrue(new.waitForExistence(timeout: 10), "No New Conversation in the folder")
        shot("acp-folder-chats")
        new.tap()
        send("Reply with only the last line of notes.txt in the current folder, nothing else.", in: app)
        let four = app.staticTexts.matching(NSPredicate(format: "label == 'FOUR'")).firstMatch
        XCTAssertTrue(four.waitForExistence(timeout: 120), "The chat didn't work in the folder")
        shot("acp-folder-reply")
    }

    /// The same Claude Code: after a reply, the model sheet shows how much of the Claude plan's
    /// limits are used, as Claude Code reported them on that reply.
    func testClaudeCodesPlanUsageIsShown() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let token = env["REDDE_BRIDGE_TOKEN"], !token.isEmpty, let folder = env["REDDE_BRIDGE_FOLDER"] else {
            throw XCTSkip("No Claude Code bridge given (TEST_RUNNER_REDDE_BRIDGE_TOKEN, TEST_RUNNER_REDDE_BRIDGE_FOLDER)")
        }
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat
            + ["-echo.clearDrafts", "-transport", "acp", "-acpURL", "127.0.0.1:8767", "-acpAgent", "claude", "-acpFolder", folder]
        app.launchEnvironment["ECHO_TEST_ACP_TOKEN"] = token
        app.launch()
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 20), "No message field")
        let new = app.buttons["New conversation"].firstMatch
        if new.waitForExistence(timeout: 5) { new.tap() }
        send("Reply with just the word PELICAN, nothing else, and use no tools.", in: app)
        XCTAssertTrue(app.text(containing: "PELICAN").waitForExistence(timeout: 30), "The message isn't shown")
        let reply = app.staticTexts.matching(NSPredicate(format: "label == %@", "PELICAN"))
        for _ in 0 ..< 60 where reply.count < 1 { sleep(2) }
        sleep(3)
        let header = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Model:")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), "No header to open the model sheet")
        header.tap()
        let usage = app.staticTexts["Plan Usage"].firstMatch.exists ? app.staticTexts["Plan Usage"].firstMatch : app.staticTexts["PLAN USAGE"].firstMatch
        for _ in 0 ..< 6 where !usage.exists { app.swipeUp() }
        XCTAssertTrue(usage.exists, "No plan usage in the model sheet")
        XCTAssertTrue(app.text(containing: "5-hour limit").exists, "No 5-hour limit")
        XCTAssertTrue(app.text(containing: "used").exists, "No share used")
        keep("acp-plan-usage")
        if let dir = env["REDDE_SHOTS"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("acp-plan-usage.png"))
        }
    }

    private func send(_ text: String, in app: XCUIApplication) {
        let composer = app.textFields["composer"]
        for _ in 0 ..< 4 {
            composer.tap()
            if (composer.value(forKey: "hasKeyboardFocus") as? Bool) == true || app.keyboards.firstMatch.exists { break }
            usleep(500_000)
        }
        composer.typeText(text)
        app.buttons.matching(identifier: "Send").allElementsBoundByIndex.last { $0.isHittable }?.tap()
    }
    /// Every agent on the bridge in one list (asked 2026-11-14): Claude Code's and Codex's chats
    /// together, each marked with its agent; New Chat asks which, and the chat is that agent's.
    func testEveryAgentInOneList() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let token = env["REDDE_BRIDGE_TOKEN"], !token.isEmpty, let folder = env["REDDE_BRIDGE_FOLDER"] else {
            throw XCTSkip("No Claude Code bridge given (TEST_RUNNER_REDDE_BRIDGE_TOKEN, TEST_RUNNER_REDDE_BRIDGE_FOLDER)")
        }
        func shot(_ name: String) {
            keep(name)
            if let dir = env["REDDE_SHOTS"] {
                try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            }
        }
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat
            + ["-echo.clearDrafts", "-transport", "acp", "-acpURL", "127.0.0.1:8767", "-acpAgent", "claude", "-acpFolder", folder,
               "-acpAllAgents", "YES"]
        app.launchEnvironment["ECHO_TEST_ACP_TOKEN"] = token
        app.launch()
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 20), "No message field")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // Both agents' chats, each with its agent's name on the row.
        func marked(_ agent: String) -> XCUIElement {
            let all = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ AND NOT (label CONTAINS 'model')", agent))
            return all.allElementsBoundByIndex.first { $0.isHittable } ?? all.firstMatch
        }
        XCTAssertTrue(app.text(containing: "conversations").waitForExistence(timeout: 60), "The list didn't load")
        // Below the projects, the chats themselves.
        for _ in 0 ..< 10 where !(marked("Codex").exists && marked("Claude Code").exists) {
            app.swipeUp()
        }
        shot("acp-all-list")
        // The title is the agent menu: All Agents, then each agent.
        let menu = app.buttons["agent-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "No agent menu in the title")
        menu.tap()
        XCTAssertTrue(app.buttons["Antigravity"].waitForExistence(timeout: 5), "The agent menu doesn't list the agents")
        shot("acp-all-menu")
        app.buttons["All Agents"].firstMatch.tap()
        XCTAssertTrue(marked("Codex").exists, "No chat of Codex's in the list")
        XCTAssertTrue(marked("Claude Code").exists, "No chat of Claude Code's in the list")
        // A chat of Codex's opens on Codex, though the app was on Claude Code.
        marked("Codex").tap()
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 30), "No message field")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "placeholderValue CONTAINS 'Codex' OR label CONTAINS 'Ask Codex'")).firstMatch
            .waitForExistence(timeout: 30), "Codex's chat isn't on Codex")
        sleep(2)
        shot("acp-all-open-codex")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let new = app.buttons["new-chat-agents"]
        XCTAssertTrue(new.waitForExistence(timeout: 10), "New Chat doesn't ask which agent")
        new.tap()
        let claude = app.buttons["new-chat-agent-claude"]
        XCTAssertTrue(claude.waitForExistence(timeout: 5), "Claude Code isn't offered")
        XCTAssertTrue(app.buttons["new-chat-agent-codex"].exists, "Codex isn't offered")
        shot("acp-all-new")
        claude.tap()
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 10), "No message field")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "placeholderValue CONTAINS 'Claude Code' OR label CONTAINS 'Ask Claude Code'")).firstMatch
            .waitForExistence(timeout: 30), "The new chat isn't Claude Code's")
        sleep(2)
        shot("acp-all-claude")
    }
}
