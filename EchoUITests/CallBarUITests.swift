import XCTest

/// The call bar (`CallBar`): a live call put away from the voice screen, as a bar over the chat.
/// Posed with no call under it (`-echo.demoCallBar`), so no server and no microphone are needed.
@MainActor
final class CallBarUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    /// The bar, once it is up. A simulator that was never asked for the microphone asks as Redde
    /// opens, over everything: answered first.
    private func bar(_ app: XCUIApplication) -> XCUIElement {
        let bar = app.descendants(matching: .any).matching(identifier: "callBar").firstMatch
        for _ in 0 ..< 3 where !bar.waitForExistence(timeout: 10) {
            for label in ["Allow", "OK"] where springboard.alerts.buttons[label].exists { springboard.alerts.buttons[label].tap() }
        }
        for label in ["Allow", "OK"] where springboard.alerts.buttons[label].exists { springboard.alerts.buttons[label].tap() }
        return bar
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoShort", "-echo.demoCallBar"] + XCUIApplication.straightToChat
        app.launch()
        return app
    }

    func testTheBarSitsAboveTheChatsHeaderAndItsButtonsWork() {
        let app = launch()
        let bar = bar(app), hangUp = app.buttons["Hang Up"]
        XCTAssertTrue(bar.exists, "No call bar over the chat")
        XCTAssertTrue(bar.label.contains("On a call"), "The bar doesn't say there is a call: \(bar.label)")
        // Everything else is under it: it lay on the chat's header when it was a safe-area inset.
        let header = app.navigationBars.firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5), "No header on the chat")
        XCTAssertLessThanOrEqual(bar.frame.maxY, header.frame.minY + 1, "The bar covers the chat's header")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "call bar"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["Mute"].tap()
        XCTAssertTrue(app.buttons["Unmute"].waitForExistence(timeout: 3), "Mute didn't shut the microphone")
        XCTAssertTrue(bar.label.contains("Muted"), "The bar doesn't say it is muted: \(bar.label)")
        app.buttons["Unmute"].tap()
        XCTAssertTrue(app.buttons["Mute"].waitForExistence(timeout: 3), "Unmute didn't open the microphone")

        hangUp.tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5), "Hang Up left the bar up")
        XCTAssertTrue(header.frame.minY < 80, "The chat's header didn't go back up")
    }

    func testATapOnTheBarOpensTheVoiceScreen() {
        let app = launch()
        let bar = bar(app)
        XCTAssertTrue(bar.exists, "No call bar over the chat")
        bar.tap()
        XCTAssertTrue(app.buttons["Switch to typing"].waitForExistence(timeout: 8), "The voice screen didn't open")
        XCTAssertFalse(bar.exists, "The bar is still up behind the voice screen")
    }
}
