import XCTest

/// Link previews: off, a message with a link has no card; on, its page is a card under it that
/// opens it. `-echo.demoLinkPreview` makes the page up, so no network is needed.
@MainActor
final class LinkPreviewUITests: XCTestCase {
    private func launch(previews: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoLinkPreview", "-linkPreviews", previews ? "YES" : "NO"]
            + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        app.launch()
        return app
    }

    private func card(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Falls Loop trail'")).firstMatch
    }

    func testOnTheLinkHasACard() {
        let app = launch(previews: true)
        let card = card(app)
        // The demo's link is in its second reply, the kitchen plan.
        for _ in 0 ..< 8 where !card.exists { app.scrollViews.firstMatch.swipeDown() }
        XCTAssertTrue(card.waitForExistence(timeout: 10), "No card for the reply's link")
        XCTAssertTrue(card.label.contains("example.com"), "The card doesn't name the site: \(card.label)")
    }

    func testOffThereIsNoCard() {
        let app = launch(previews: false)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'shared plan'")).firstMatch.waitForExistence(timeout: 20)
                      || app.scrollViews.firstMatch.waitForExistence(timeout: 5), "The demo didn't open")
        for _ in 0 ..< 8 { app.scrollViews.firstMatch.swipeDown() }
        XCTAssertFalse(card(app).exists, "A card with Link previews off")
    }
}
