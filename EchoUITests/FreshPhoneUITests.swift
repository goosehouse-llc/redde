import XCTest

/// "Someone else's phone": Redde as a person who isn't its maker meets it, with the built-in demo
/// agent (no server, no lab), in another language, at the largest text size, in light mode with
/// 24-hour time and metric units. Each test walks the same path: the demo agent's tour with its
/// approval, the chat list, Today pulled to refresh, and Settings → About → Report a Problem.
/// Elements are found by identifiers, which are the same in every language; the demo agent's own
/// words stay English. Screenshots are kept for a look afterwards (UAT).
@MainActor
final class FreshPhoneUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testInSwedish() throws { try walk("Swedish", ["-AppleLanguages", "(sv)", "-AppleLocale", "sv_SE"]) }
    func testInJapanese() throws { try walk("Japanese", ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]) }
    func testAtTheLargestTextSize() throws {
        try walk("Largest text", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    }
    func testInLightModeWith24HourTimeAndMetric() throws {
        try walk("Light, en_GB", ["-appearance", "light", "-AppleLanguages", "(en-GB)", "-AppleLocale", "en_GB"])
    }

    private func walk(_ look: String, _ extra: [String]) throws {
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat
            + ["-transport", "acp", "-acpURL", "demo", "-acpAgent", "", "-acpFolder", "", "-echo.fresh", "-echo.clearDrafts"] + extra
        app.launchEnvironment["ECHO_TEST_ACP_TOKEN"] = ""   // empty deletes
        app.launch()
        let pad = app.windows.firstMatch.frame.width > 600

        // A chat with the demo agent: its tour asks before a command, then finishes.
        let composer = app.composerField
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "\(look): no chat to type in")
        keep("\(look) 1 chat")
        composer.tap()
        // (A first tap on a freshly launched iPad can land before the field takes focus.)
        if !((composer.value(forKey: "hasKeyboardFocus") as? Bool) ?? false) {
            sleep(1)
            composer.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        }
        XCTAssertTrue((composer.value(forKey: "hasKeyboardFocus") as? Bool) ?? false, "\(look): tapping the message box doesn't let you type")
        composer.typeText("Fix the notes")
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "\(look): no Send button")
        send.tap()
        let allow = app.buttons["approval.once"]
        XCTAssertTrue(allow.waitForExistence(timeout: 40), "\(look): the demo's command never asked first")
        keep("\(look) 2 approval")
        allow.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'all three checks pass'")).firstMatch
            .waitForExistence(timeout: 40), "\(look): the demo's tour didn't finish")
        keep("\(look) 3 reply")

        // The chat list, then Today, pulled down to refresh.
        if !pad {
            let list = app.buttons["chat.conversations"]
            XCTAssertTrue(list.waitForExistence(timeout: 10), "\(look): no way to the chat list")
            list.tap()
        }
        let settingsButton = app.buttons["list.settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10), "\(look): the chat list didn't open")
        let row = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Fix the notes'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "\(look): the new chat isn't in the chat list")
        keep("\(look) 4 chat list")
        let today = app.buttons["drawer.place.today"]
        if today.waitForExistence(timeout: 5) {
            today.tap()
            let page = app.collectionViews.firstMatch
            XCTAssertTrue(page.waitForExistence(timeout: 10), "\(look): Today didn't open")
            page.swipeDown(velocity: .slow)
            keep("\(look) 5 today")
            XCTAssertEqual(app.state, .runningForeground, "\(look): Redde quit on Today's refresh")
            let back = app.buttons["BackButton"]   // the system's back button, in any language
            if back.waitForExistence(timeout: 3) { back.tap() }
        }

        // Settings → About → Report a Problem.
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10), "\(look): lost the chat list")
        settingsButton.tap()
        let report = app.buttons["about.report"]
        for _ in 0 ..< 14 where !(report.exists && report.isHittable) { app.swipeUp() }
        XCTAssertTrue(report.exists && report.isHittable, "\(look): no Report a Problem in Settings")
        keep("\(look) 6 settings about")
        report.tap()
        let text = app.staticTexts["diagnostics.report"]
        XCTAssertTrue(text.waitForExistence(timeout: 20), "\(look): the report didn't appear")
        XCTAssertTrue(text.label.contains("Connection acp"), "\(look): the report doesn't name the connection: \(text.label)")
        keep("\(look) 7 report")
        XCTAssertEqual(app.state, .runningForeground, "\(look): Redde quit")
    }

    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
