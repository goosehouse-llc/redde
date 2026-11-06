import XCTest

/// All Mailboxes (2026-11-06): with two accounts the Inbox can show both together, and what is
/// picked stays picked the next time Redde opens. Runs on the demo inbox with a second account.
@MainActor
final class MailboxesUITests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoInbox", "two", "-echo.screen", "inbox"] + extra + XCUIApplication.straightToChat
        app.launch()
        return app
    }

    func testAllMailboxesShowsBothAndStays() {
        // Start from Home alone (the argument outranks what an earlier run kept).
        var app = launch(["-mail.inboxAccount", "main"])
        XCTAssertTrue(app.text(containing: "Priya Nair").waitForExistence(timeout: 15), "No demo mail")
        XCTAssertFalse(app.text(containing: "IT Desk").exists, "Work's mail shown under Home")

        app.navigationBars["Home"].buttons["More"].tap()
        app.buttons["All Mailboxes"].tap()
        XCTAssertTrue(app.text(containing: "IT Desk").waitForExistence(timeout: 5), "Work's mail missing from All Mailboxes")
        XCTAssertTrue(app.text(containing: "Priya Nair").exists, "Home's mail missing from All Mailboxes")
        XCTAssertTrue(app.navigationBars["All Mailboxes"].exists, "Title doesn't say All Mailboxes")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "all-mailboxes"
        shot.lifetime = .keepAlways
        add(shot)

        app.terminate()
        app = launch()
        XCTAssertTrue(app.text(containing: "IT Desk").waitForExistence(timeout: 15), "All Mailboxes didn't stay picked")
        XCTAssertTrue(app.navigationBars["All Mailboxes"].exists)
    }
}
