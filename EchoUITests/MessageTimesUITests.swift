import XCTest

/// Swipe left in a chat to see each message's time (asked 2026-11-06).
@MainActor
final class MessageTimesUITests: XCTestCase {
    func testTimesShowPastTheRows() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // The times held out, as mid-swipe (a drag's middle can't be pictured from a test).
        app.launchArguments = ["-echo.demo", "-echo.showTimes"] + XCUIApplication.straightToChat
        app.launch()
        let time = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", #"^\d{1,2}:\d{2}\s?[AP]M$"#)).firstMatch
        _ = time.waitForExistence(timeout: 15)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "times"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testASwipeLeftDoesntStopTheScroll() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoLong"] + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        app.launch()
        let end = app.staticTexts["End of the long demo."]
        XCTAssertTrue(end.waitForExistence(timeout: 15))
        let transcript = app.scrollViews.firstMatch
        transcript.swipeLeft()
        XCTAssertTrue(end.isHittable, "A swipe left moved the chat away")
        transcript.swipeDown(velocity: .fast)
        XCTAssertTrue(app.buttons["Jump to the newest message"].waitForExistence(timeout: 5), "The chat didn't scroll after a swipe left")
    }
}
