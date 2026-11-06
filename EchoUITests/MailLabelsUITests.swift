import XCTest

/// Gmail Labels (Settings › Agent › Email › an account): a tagging rule can add more than one
/// label (asked 2026-11-06). Runs on the demo inbox, which answers for the plugin.
@MainActor
final class MailLabelsUITests: XCTestCase {
    func testARuleCanAddTwoLabels() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoInbox", "-echo.screen", "mailLabels"] + XCUIApplication.straightToChat
        app.launch()

        XCTAssertTrue(app.text(containing: "Label School, Kids").waitForExistence(timeout: 15), "The demo's two-label rule doesn't name both")

        let newRule = app.buttons["Add Tagging Rule"]
        if !newRule.isHittable { app.swipeUp() }
        newRule.tap()
        let subject = app.textFields["Subject has"]
        XCTAssertTrue(subject.waitForExistence(timeout: 5), "No rule editor")
        subject.tap()
        subject.typeText("invoice")

        let name = app.textFields["Label name"]
        for _ in 0 ..< 4 where !name.isHittable { app.swipeUp() }
        name.tap()
        name.typeText("Bills")
        app.buttons["Add Another Label"].tap()

        // The second label picked from the account's own.
        let another = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Another Label")).firstMatch
        XCTAssertTrue(another.waitForExistence(timeout: 3), "No second label")
        another.tap()
        app.buttons["Paperless"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Remove Label"].exists, "The second label can't be taken off")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "two-labels"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["Save"].tap()
        XCTAssertTrue(app.text(containing: "Label Bills, Paperless").waitForExistence(timeout: 5), "The saved rule doesn't name both labels")
    }
}
