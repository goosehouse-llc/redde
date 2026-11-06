import XCTest

/// The Inbox redrawn (2026-11-06): the piles as tabs, Select for several emails at once, and an
/// email as its sender laid it out. Runs on the demo inbox, which answers for the plugin.
@MainActor
final class InboxLookUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoInbox", "-echo.screen", "inbox"] + XCUIApplication.straightToChat
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSelectArchivesSeveral() {
        let app = launch()
        let first = app.text(containing: "Priya Nair")
        XCTAssertTrue(first.waitForExistence(timeout: 15), "No demo mail")
        shot(app, "inbox")

        app.buttons["Select"].tap()
        XCTAssertTrue(app.buttons["Archive"].waitForExistence(timeout: 3), "No Select bar")
        app.cells.containing(.staticText, identifier: nil).element(boundBy: 1).tap()
        app.cells.element(boundBy: 2).tap()
        XCTAssertTrue(app.staticTexts["2 Selected"].waitForExistence(timeout: 3), "Two picks don't say so")
        shot(app, "selecting")
        app.buttons["Archive"].tap()
        XCTAssertTrue(app.text(containing: "Archived: 2 emails").waitForExistence(timeout: 5), "No toast for the two")
        XCTAssertFalse(app.staticTexts["2 Selected"].exists, "Select didn't end")
    }

    func testANewsletterShowsAsLaidOut() {
        let app = launch()
        XCTAssertTrue(app.text(containing: "Priya Nair").waitForExistence(timeout: 15), "No demo mail")
        let news = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Newsletters")).firstMatch
        XCTAssertTrue(news.waitForExistence(timeout: 3), "No Newsletters tab")
        // The tabs scroll sideways (asked 2026-11-06): Newsletters is past the screen's edge.
        let row = news.frame.midY / app.frame.height
        for _ in 0 ..< 3 where news.frame.maxX > app.frame.maxX {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: row))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: row)))
        }
        news.tap()
        let lumen = app.text(containing: "Lumen Coffee")
        XCTAssertTrue(lumen.waitForExistence(timeout: 5), "No newsletter")
        lumen.tap()
        // The email's own words, drawn by the web view.
        XCTAssertTrue(app.webViews.staticTexts["Our autumn roast is back"].waitForExistence(timeout: 10), "The email isn't drawn")
        let page = app.webViews.firstMatch
        XCTAssertLessThanOrEqual(page.frame.width, app.frame.width, "The 600-point email isn't fitted")
        shot(app, "reader")
        // All of it: the page is as tall as the email, its last line reachable.
        app.swipeUp()
        app.swipeUp()
        shot(app, "reader-end")
        let last = app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "You signed up")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 3), "The email's last line isn't there")
        // (Its frames are the page's before it's fitted, so the picture is the check of the fit.)
    }

    /// Hold an email: Send to Paperless labels it for Paperless-ngx (asked 2026-11-06).
    func testHoldSendsAnEmailToPaperless() {
        let app = launch()
        let first = app.text(containing: "Priya Nair")
        XCTAssertTrue(first.waitForExistence(timeout: 15), "No demo mail")
        first.press(forDuration: 1.0)
        let send = app.buttons["Send to Paperless"]
        XCTAssertTrue(send.waitForExistence(timeout: 3), "No Send to Paperless in the hold menu")
        shot(app, "hold-menu")
        send.tap()
        XCTAssertTrue(app.text(containing: "Labelled Paperless").waitForExistence(timeout: 5), "No toast for the label")
    }
}
