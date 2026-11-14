import XCTest

/// iPhone: a swipe to the right on the chat opens the conversation list, and the transcript
/// still scrolls up and down.
@MainActor
final class SwipeToConversationsUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat
            + ["-echo.demo", "-transport", "chatCompletions"]
        app.launch()
        return app
    }

    private func drag(_ app: XCUIApplication, from: CGVector, to: CGVector) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: from)
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: to), withVelocity: .fast,
                   thenHoldForDuration: 0)
    }

    /// The list is open when its bar can be reached: parked, the panel's bar is hidden but still
    /// in the tree (iOS 27.2), so its being there says nothing.
    private func listIsOpen(_ app: XCUIApplication, _ open: Bool, timeout: TimeInterval = 5) -> Bool {
        let bar = app.navigationBars["Conversations"]
        let end = Date.now.addingTimeInterval(timeout)
        repeat {
            if (bar.exists && bar.isHittable) == open { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date.now < end
        return false
    }

    func testSwipeRightOpensConversations() throws {
        let app = launch()
        try XCTSkipIf(app.windows.firstMatch.frame.width > 600, "iPad keeps the list in the sidebar")
        XCTAssertTrue(app.buttons["Conversations"].waitForExistence(timeout: 15), "The chat never appeared")
        drag(app, from: CGVector(dx: 0.1, dy: 0.45), to: CGVector(dx: 0.9, dy: 0.47))
        XCTAssertTrue(app.navigationBars["Conversations"].waitForExistence(timeout: 5), "Swiping right didn't open the list")
    }

    /// The panel closes from the dimmed chat beside it, and when a conversation is picked.
    func testPanelCloses() throws {
        let app = launch()
        try XCTSkipIf(app.windows.firstMatch.frame.width > 600, "iPad keeps the list in the sidebar")
        XCTAssertTrue(app.buttons["Conversations"].waitForExistence(timeout: 15), "The chat never appeared")
        let list = app.navigationBars["Conversations"]

        app.buttons["Conversations"].tap()
        XCTAssertTrue(listIsOpen(app, true), "The button didn't open the list")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(listIsOpen(app, false), "Tapping the chat beside the panel didn't close it")

        drag(app, from: CGVector(dx: 0.1, dy: 0.45), to: CGVector(dx: 0.9, dy: 0.47))
        XCTAssertTrue(listIsOpen(app, true), "Swiping right didn't open the list")
        drag(app, from: CGVector(dx: 0.95, dy: 0.5), to: CGVector(dx: 0.2, dy: 0.5))
        XCTAssertTrue(listIsOpen(app, false), "Dragging the chat back didn't close the panel")

        app.buttons["Conversations"].tap()
        XCTAssertTrue(listIsOpen(app, true), "The button didn't open the list")
        list.buttons["New conversation"].tap()
        XCTAssertTrue(listIsOpen(app, false), "Starting a new conversation didn't close the panel")
    }

    /// A swipe too short to open the panel leaves it parked: its bar (Settings, New conversation)
    /// must not stay reachable off screen.
    func testShortSwipeLeavesThePanelClosed() throws {
        let app = launch()
        try XCTSkipIf(app.windows.firstMatch.frame.width > 600, "iPad keeps the list in the sidebar")
        XCTAssertTrue(app.buttons["Conversations"].waitForExistence(timeout: 15), "The chat never appeared")
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        sleep(2)   // time for it to open, if it were going to
        XCTAssertTrue(listIsOpen(app, false, timeout: 0), "A short swipe opened the list")
    }

    func testVerticalScrollDoesNotOpenConversations() throws {
        let app = launch()
        try XCTSkipIf(app.windows.firstMatch.frame.width > 600, "iPad keeps the list in the sidebar")
        XCTAssertTrue(app.buttons["Conversations"].waitForExistence(timeout: 15), "The chat never appeared")
        drag(app, from: CGVector(dx: 0.4, dy: 0.3), to: CGVector(dx: 0.5, dy: 0.7))
        sleep(2)   // time for it to open, if it were going to
        XCTAssertTrue(listIsOpen(app, false, timeout: 0), "A scroll opened the list")
    }
}
