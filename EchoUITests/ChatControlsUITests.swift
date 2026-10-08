import XCTest

/// A conversation's own switches in the model menu, on sample data (`-echo.demoChatControls`), and
/// "Move to Project" in the chat list's row menu (`-echo.demoProjects`). Neither needs a server.
@MainActor
final class ChatControlsUITests: XCTestCase {
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The switch itself, inside its row: a tap on the row's middle lands on the label.
    private func flip(_ row: XCUIElement) {
        let knob = row.switches.firstMatch
        (knob.exists ? knob : row).tap()
    }

    private func value(of element: XCUIElement, becomes wanted: String, within timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.value as? String == wanted { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    func testFastModeAndRunningWithoutAskingInTheModelMenu() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.demoChatControls", "-echo.screen", "model"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Model"].waitForExistence(timeout: 20), "The model menu didn't open")
        let mark = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Commands run without asking'")).firstMatch
        XCTAssertFalse(mark.exists, "The header marks a conversation that still asks")

        let fast = app.switches["Fast mode"]
        for _ in 0 ..< 6 where !(fast.exists && fast.isHittable) { app.swipeUp() }
        XCTAssertTrue(fast.exists && fast.isHittable, "No Fast mode switch in the model menu")
        XCTAssertEqual(fast.value as? String, "0")
        flip(fast)
        XCTAssertTrue(value(of: fast, becomes: "1"), "Fast mode didn't turn on")

        // Running without asking asks first.
        let unasked = app.switches["Run commands without asking"]
        XCTAssertTrue(unasked.exists && unasked.isHittable, "No switch for running commands without asking")
        XCTAssertEqual(unasked.value as? String, "0")
        flip(unasked)
        let confirm = app.buttons["Run Without Asking"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Turning it on didn't ask first")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'every command it wants to'")).firstMatch.exists,
                      "The question doesn't say what it means")
        shot("run without asking confirmation")
        confirm.tap()
        XCTAssertTrue(value(of: unasked, becomes: "1"), "The switch didn't turn on")
        shot("model menu switches")

        // Back on the chat, the header says so for as long as it is on.
        app.navigationBars["Model"].swipeDown(velocity: .fast)
        XCTAssertTrue(mark.waitForExistence(timeout: 8), "Nothing in the header says commands run without asking")
        shot("header mark")
    }

    func testMoveToProjectIsInTheRowsMenu() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoProjects", "-echo.screen", "sessions"] + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Transcript scrolling'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "The demo's conversations never appeared")
        row.press(forDuration: 1.2)
        let move = app.buttons["Move to Project"]
        XCTAssertTrue(move.waitForExistence(timeout: 5), "No Move to Project in the row's menu")
        move.tap()
        XCTAssertTrue(app.buttons["Echo"].waitForExistence(timeout: 5), "The project isn't offered as a place to move to")
        shot("move to project")
    }
}
