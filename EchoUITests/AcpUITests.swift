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
        app.launchArguments = XCUIApplication.straightToChat + XCUIApplication.chatsSection
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
        app.launchArguments = XCUIApplication.straightToChat + XCUIApplication.chatsSection
            + ["-transport", "acp", "-acpURL", bridge, "-acpAgent", "hermes"]
        app.launch()
        let listed = app.text(containing: "[A:alpha]")
        XCTAssertTrue(listed.waitForExistence(timeout: 30), "The chat isn't listed after a relaunch")
        listed.tap()
        XCTAssertTrue(app.text(containing: "please do the danger thing").waitForExistence(timeout: 30), "The reopened chat lost its history")
        XCTAssertTrue(app.text(containing: "[gone]").exists, "The reopened chat lost the agent's reply")
        keep("ACP chat reopened")
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
}
