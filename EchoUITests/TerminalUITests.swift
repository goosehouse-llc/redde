import XCTest

/// The terminal with the real app and a real OpenSSH server (`scripts/terminal-lab/lab.sh up`,
/// run with TEST_RUNNER_REDDE_TERMINAL_LAB and TEST_RUNNER_REDDE_TERMINAL_USER): Settings ›
/// Terminal takes the account, shows this iPhone's key (which the test puts in the lab's
/// authorized_keys, as a person would on their server), opens the terminal, asks to trust the
/// server, and a command typed runs. Skips without the lab.
@MainActor
final class TerminalUITests: XCTestCase {
    private func keep(_ screenshot: XCUIScreenshot, as name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Empties a field the way a person does: long-press, Select All, delete. (A run of delete
    /// keys left a character behind in the numbers-only port field.)
    private func clear(_ field: XCUIElement, in app: XCUIApplication) {
        field.tap()
        guard let old = field.value as? String, !old.isEmpty, old != field.placeholderValue else { return }
        field.press(forDuration: 1.0)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 3) {
            selectAll.tap()
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        } else {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 30))
        }
    }

    private func replace(_ field: XCUIElement, with text: String, in app: XCUIApplication) {
        clear(field, in: app)
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text, "the field didn't take what was typed")
    }

    func testSettingsKeyTrustAndACommand() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let lab = env["REDDE_TERMINAL_LAB"], env["REDDE_TERMINAL_USER"] != nil else {
            throw XCTSkip("No terminal lab (scripts/terminal-lab/lab.sh up, and TEST_RUNNER_REDDE_TERMINAL_LAB / _USER)")
        }

        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.screen", "settings"]
        app.launch()
        let row = app.buttons["Terminal"]
        for _ in 0 ..< 10 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no Terminal row in Settings")
        row.tap()

        replace(app.textFields["hermes.example.ts.net"], with: "127.0.0.1", in: app)
        replace(app.textFields["22"], with: "2222", in: app)
        // With the user empty (an earlier run may have saved one), the form says so, and Open
        // Terminal goes to the field instead of opening.
        let user = app.textFields["required, such as hermes"]
        clear(user, in: app)
        sleep(1)
        keep(app.screenshot(), as: "terminal-user-missing")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'fill in the user'")).firstMatch
                        .waitForExistence(timeout: 5), "nothing says the user is missing")
        app.buttons["Open Terminal"].tap()
        XCTAssertFalse(app.alerts["Trust this server?"].waitForExistence(timeout: 3), "it tried to connect without a user")
        XCTAssertFalse(app.buttons["Close"].exists, "the terminal opened without a user")
        replace(user, with: env["REDDE_TERMINAL_USER"]!, in: app)
        let key = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'ssh-ed25519 '")).firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 10), "this iPhone's key isn't shown")
        try (key.label + "\n").write(toFile: lab + "/authorized_keys", atomically: true, encoding: .utf8)
        defer { try? "".write(toFile: lab + "/authorized_keys", atomically: true, encoding: .utf8) }
        keep(app.screenshot(), as: "terminal-settings")

        // A fresh trust each run: forget any key an earlier run trusted.
        let forget = app.buttons["Forget This Server's Key"]
        if forget.exists { forget.tap() }
        app.buttons["Open Terminal"].tap()

        let trust = app.alerts["Trust this server?"]
        XCTAssertTrue(trust.waitForExistence(timeout: 20), "a new server wasn't asked about")
        keep(app.screenshot(), as: "terminal-trust")
        trust.buttons["Trust"].tap()

        // The shell is up when the keyboard is (the terminal takes it); then a command.
        sleep(4)
        keep(app.screenshot(), as: "terminal-after-trust")
        if !app.keyboards.firstMatch.waitForExistence(timeout: 6) {
            app.scrollViews["Terminal"].firstMatch.tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the terminal didn't take the keyboard")
        sleep(1)
        app.typeText("echo redde-$((6*7)); stty size\n")
        sleep(2)
        keep(app.screenshot(), as: "terminal-command")
        app.buttons["Close"].tap()
    }
}
