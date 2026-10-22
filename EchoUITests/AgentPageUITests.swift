import XCTest

/// A page the agent made (`::preview{file=…}`) is live in its reply, and its buttons talk to the
/// agent without a message of the person's showing for it (a Reddit report, 2026-10-21: the
/// directive showed as text). `-echo.demoPage` supplies the reply.
@MainActor
final class AgentPageUITests: XCTestCase {
    func testAPageIsLiveAndItsButtonsReachTheAgent() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoPage"] + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        app.launch()
        XCTAssertTrue(app.text(containing: "the week's rain").waitForExistence(timeout: 20), "The demo reply didn't appear")
        XCTAssertFalse(app.text(containing: "::preview").exists, "The directive shows as text")
        // Written by the page's own script: scripts run.
        XCTAssertTrue(app.webViews.staticTexts["Millimetres a day, drawn by the page"].waitForExistence(timeout: 10), "The page's script didn't run")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "page"
        attachment.lifetime = .keepAlways
        add(attachment)
        // The demo's conversation was never on a server, so the page's message has nowhere to go
        // and says so: it got as far as the conversation. (`AgentPageTests` follows it from there.)
        app.webViews.buttons["Porto"].tap()
        XCTAssertTrue(app.text(containing: "can't reach the agent from here").waitForExistence(timeout: 10), "The page's button didn't reach the app")
        XCTAssertFalse(app.text(containing: "Show Porto instead").exists, "What the page sent shows as a message")
    }
}
