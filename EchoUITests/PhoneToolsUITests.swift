import XCTest

/// Settings → Phone tools: everything is off until it is turned on, each area has its own
/// setting, and the plugin on the server is named. `-echo.demoPlugin there` stands in for a
/// Hermes that has the plugin; no server is needed.
@MainActor
final class PhoneToolsUITests: XCTestCase {
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func reach(_ element: XCUIElement, in app: XCUIApplication, _ what: String) {
        for _ in 0 ..< 14 where !(element.exists && element.isHittable) { app.swipeUp() }
        XCTAssertTrue(element.exists && element.isHittable, "\(what) isn't on the screen")
    }

    private func flip(_ row: XCUIElement) {
        let knob = row.switches.firstMatch
        (knob.exists ? knob : row).tap()
    }

    func testPhoneToolsAreOffUntilTurnedOnAreaByArea() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.screen", "settings", "-echo.demoPlugin", "there"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20), "Settings didn't open")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Phone tools'")).firstMatch
        reach(row, in: app, "The Phone tools row")
        row.tap()
        XCTAssertTrue(app.navigationBars["Phone Tools"].waitForExistence(timeout: 10), "The Phone tools screen didn't open")

        let master = app.switches["Phone tools"]
        XCTAssertTrue(master.waitForExistence(timeout: 5))
        if master.value as? String == "1" { flip(master) }   // (left on by a run that stopped halfway)
        XCTAssertFalse(app.staticTexts["What it may use"].exists || app.staticTexts["WHAT IT MAY USE"].exists, "The areas show while phone tools are off")
        shot("phone tools off")

        flip(master)
        let calendar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Calendar'")).firstMatch
        XCTAssertTrue(calendar.waitForExistence(timeout: 5), "Turned on, the areas aren't offered")
        // More areas than fit on the screen at once: each is scrolled to.
        for area in ["Reminders", "Contacts", "Photos", "Files", "Alarms", "Widget", "Calls and Messages"] {
            reach(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", area)).firstMatch, in: app, "\(area)")
        }
        for _ in 0 ..< 8 where !master.isHittable { app.swipeDown() }
        // Under Photos: where the pictures are looked at, and what of them leaves the phone.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'keeps what it finds here' AND label CONTAINS 'to your Hermes and nowhere else'")).firstMatch.exists,
                      "The note under Photos isn't there")
        // An area starts off, and is turned on by choosing how.
        calendar.tap()
        let asking = app.buttons["Ask each time"]
        XCTAssertTrue(asking.waitForExistence(timeout: 5), "The area's choices didn't open")
        XCTAssertTrue(app.buttons["Off"].exists && app.buttons["Allow reading"].exists)
        asking.tap()
        // Where Redde has never been let at the calendar, this is when iOS asks.
        let full = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Full Access"]
        if full.waitForExistence(timeout: 3) { full.tap() }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Calendar' AND (label CONTAINS 'Ask each time' OR value CONTAINS 'Ask each time')")).firstMatch
            .waitForExistence(timeout: 5), "The choice didn't take")
        shot("phone tools on")

        // Further down, the plugin on the server is named.
        let plugin = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'The plugin' AND label CONTAINS 'is on this Hermes'")).firstMatch
        reach(plugin, in: app, "The plugin on the server")
        shot("phone tools plugin")
        for _ in 0 ..< 6 where !master.isHittable { app.swipeDown() }

        // Off again, for whatever runs next: the area, then the whole thing.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Calendar'")).firstMatch.tap()
        app.buttons["Off"].tap()
        flip(master)
        XCTAssertTrue(calendar.waitForNonExistence(timeout: 5))
    }

    /// Turning Alarms on is when iOS is asked whether Redde may set them. The iOS 27.0 simulator
    /// refuses without asking (the 26.3 one asks), and where it was refused once it stays so.
    func testTurningAlarmsOnAsksIOSForThem() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.screen", "settings", "-echo.demoPlugin", "there"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20), "Settings didn't open")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Phone tools'")).firstMatch
        reach(row, in: app, "The Phone tools row")
        row.tap()
        let master = app.switches["Phone tools"]
        XCTAssertTrue(master.waitForExistence(timeout: 10))
        if master.value as? String != "1" { flip(master) }
        let alarms = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Alarms'")).firstMatch
        reach(alarms, in: app, "The Alarms row")
        alarms.tap()
        app.buttons["Ask each time"].tap()
        // The first time, iOS asks whether Redde may schedule alarms and timers.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 6) { allow.tap() }
        let refused = app.buttons.matching(NSPredicate(format: "label CONTAINS 'allow Redde this'")).firstMatch
        if refused.waitForExistence(timeout: 3) {
            // Refused, the area goes back to Off and says where to allow it: that much is right.
            shot("alarms refused")
            for _ in 0 ..< 6 where !master.isHittable { app.swipeDown() }
            flip(master)
            throw XCTSkip("iOS refused the alarms permission here without being allowed to ask (the iOS 27.0 simulator does)")
        }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Alarms' AND (label CONTAINS 'Ask each time' OR value CONTAINS 'Ask each time')")).firstMatch
            .waitForExistence(timeout: 8), "The choice didn't take")
        shot("alarms on")

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Alarms'")).firstMatch.tap()
        app.buttons["Off"].tap()
        for _ in 0 ..< 6 where !master.isHittable { app.swipeDown() }
        flip(master)
    }
}
