import XCTest

/// Dragging the chat down puts the keyboard away, as in Messages (asked 2026-10-26: "allow the
/// 'swipe to remove' the keyboard from the typing chat screen"): in a long conversation, and in a
/// new one with nothing in it yet. Needs the simulator's software keyboard (a hardware keyboard
/// shows none to put away).
@MainActor
final class KeyboardDismissUITests: XCTestCase {
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + XCUIApplication.chatsSection
            + ["-transport", "chatCompletions", "-fastLaneURL", "http://127.0.0.1:9", "-fastLaneModel", "test"] + extra
        app.launch()
        return app
    }

    private func keyboardUp(_ app: XCUIApplication) {
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "No message field")
        for _ in 0 ..< 4 where !app.keyboards.firstMatch.waitForExistence(timeout: 2) { field.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "No keyboard came up (is a hardware keyboard attached?)")
    }

    /// A drag from the middle of the chat down to the bottom of the screen, as a thumb does.
    private func dragDown(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.1)
    }

    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testDraggingALongChatDownPutsTheKeyboardAway() {
        let app = launch(["-echo.demo"])
        keyboardUp(app)
        keep("long chat, keyboard up")
        dragDown(app)
        keep("long chat, after the drag")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3), "The keyboard stayed after a drag down the chat")
    }

    func testSwipingTheMessageBoxDownPutsTheKeyboardAway() {
        let app = launch(["-echo.demo"])
        keyboardUp(app)
        let field = app.textFields.firstMatch
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.05, thenDragTo: field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 3)), withVelocity: .fast, thenHoldForDuration: 0)
        keep("message box swiped down")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3), "The keyboard stayed after a swipe down the message box")
    }

    func testDraggingAnEmptyChatDownPutsTheKeyboardAway() {
        let app = launch(["-echo.fresh", "-echo.clearDrafts"])
        keyboardUp(app)
        keep("empty chat, keyboard up")
        dragDown(app)
        keep("empty chat, after the drag")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3), "The keyboard stayed after a drag down an empty chat")
    }
}
