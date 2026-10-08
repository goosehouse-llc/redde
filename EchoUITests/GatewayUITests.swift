import XCTest

/// Settings → Gateway, on sample data (`-echo.demoGateway`), so it needs no server: the status,
/// an MCP server switched and tested, a restart confirmed and followed to its end, an update
/// found, and the logs with a filter.
@MainActor
final class GatewayUITests: XCTestCase {
    private func openGateway() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.demoGateway", "-echo.screen", "settings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20), "Settings didn't open")
        let row = app.buttons["Gateway"]
        for _ in 0 ..< 12 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.exists && row.isHittable, "No Gateway row in Settings")
        row.tap()
        XCTAssertTrue(app.navigationBars["Gateway"].waitForExistence(timeout: 10), "The Gateway screen didn't open")
        return app
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Something on the screen says `text`, as its label or as its value: a row made of a title
    /// and a value is one element, with the value beside the title.
    private func shows(_ text: String, in app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
            .firstMatch.waitForExistence(timeout: timeout)
    }

    private func reach(_ element: XCUIElement, in app: XCUIApplication, _ what: String) {
        for _ in 0 ..< 10 where !(element.exists && element.isHittable) { app.swipeUp() }
        XCTAssertTrue(element.exists && element.isHittable, "\(what) isn't on the screen")
    }

    func testTheServerItsMCPServersAndARestart() {
        continueAfterFailure = false
        let app = openGateway()
        XCTAssertTrue(shows("0.21.5 · 2026.9.24", in: app, timeout: 10), "The version isn't shown")
        XCTAssertTrue(shows("homelab", in: app), "The host isn't named")
        XCTAssertTrue(shows("Running", in: app), "The gateway's state isn't shown")
        shot("gateway status")

        // An MCP server that is off: on, and tested.
        let github = app.switches["github"]
        reach(github, in: app, "The github server's switch")
        XCTAssertEqual(github.value as? String, "0", "github should start off")
        let knob = github.switches.firstMatch
        (knob.exists ? knob : github).tap()
        XCTAssertTrue(github.wait(for: \.value, toEqual: "1", timeout: 5) || github.value as? String == "1", "The switch didn't turn on")
        let test = app.buttons["Test basic-memory"]
        reach(test, in: app, "The Test button")
        test.tap()
        XCTAssertTrue(shows("Connected · 4 tools", in: app), "The test's result isn't shown")
        shot("gateway MCP servers")

        // A restart asks first, then is followed to its end.
        let restart = app.buttons["Restart Gateway…"]
        reach(restart, in: app, "Restart Gateway")
        restart.tap()
        let confirm = app.buttons["Restart"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "No confirmation before a restart")
        XCTAssertTrue(shows("1 turn is running now", in: app), "The confirmation doesn't say what is running")
        shot("gateway restart confirmation")
        confirm.tap()
        XCTAssertTrue(shows("The gateway was restarted.", in: app, timeout: 15), "The restart's end isn't reported")

        // An update is found and offered, and asks first too.
        let check = app.buttons["Check for Updates"]
        reach(check, in: app, "Check for Updates")
        check.tap()
        XCTAssertTrue(shows("12 changes behind", in: app), "The update check's answer isn't shown")
        let update = app.buttons["Update Hermes…"]
        reach(update, in: app, "Update Hermes")
        update.tap()
        XCTAssertTrue(app.buttons["Update Hermes"].waitForExistence(timeout: 5), "No confirmation before an update")
        XCTAssertTrue(shows("changes made by hand", in: app), "The confirmation doesn't warn about local changes")
        shot("gateway update confirmation")
        app.buttons["Update Hermes"].tap()
        XCTAssertTrue(shows("Hermes is now 0.21.6.", in: app, timeout: 15), "The update's end isn't reported")
        shot("gateway after the update")
    }

    func testTheLogsAndTheirFilter() {
        continueAfterFailure = false
        let app = openGateway()
        let logs = app.buttons["Logs"]
        reach(logs, in: app, "The Logs row")
        logs.tap()
        XCTAssertTrue(app.navigationBars["Logs"].waitForExistence(timeout: 10), "The log screen didn't open")
        let info = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Gateway running with 2 platform'")).firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 5), "No log lines")
        shot("gateway logs")

        app.buttons["Filter"].tap()
        let errorsOnly = app.buttons["Errors only"]
        XCTAssertTrue(errorsOnly.waitForExistence(timeout: 5), "No level filter")
        errorsOnly.tap()
        let error = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Gateway closed the connection'")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5), "The error line is gone")
        XCTAssertFalse(info.exists, "An info line is still shown with only errors asked for")
    }
}

private extension XCUIElement {
    /// Waits for a property to take a value; true if it did.
    func wait(for keyPath: KeyPath<XCUIElement, Any?>, toEqual wanted: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if self[keyPath: keyPath] as? String == wanted { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }
}
