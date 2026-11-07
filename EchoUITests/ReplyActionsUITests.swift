import XCTest

/// Copying a reply says so, and a tool step opens onto what it returned. Taps are the point, so
/// these run in the app.
@MainActor
final class ReplyActionsUITests: XCTestCase {
    private func launchDemo() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoShort"] + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        app.launch()
        return app
    }


    func testCopySaysSo() {
        let app = launchDemo()
        XCTAssertTrue(app.text(containing: "I've added a reminder").waitForExistence(timeout: 15), "The demo reply didn't appear")
        // The actions sit under a finished reply without being asked for.
        XCTAssertTrue(app.buttons["Regenerate"].waitForExistence(timeout: 3), "No actions under the reply")

        app.buttons["Copy reply"].tap()
        let toast = app.staticTexts["Copied"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "No toast after copying")
        XCTAssertTrue(app.buttons["Copied"].exists, "The copy button didn't turn into a check")
        let composer = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        XCTAssertLessThan(toast.frame.maxY, composer.frame.minY, "The toast sits under the composer")
    }

    /// While a reply is being worked on its thinking is open, and a tap folds it all the same:
    /// it used to stay open, with a header that took no taps, until the reply was done.
    func testThinkingFoldsWhileTheReplyIsStillComing() {
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoStream"] + XCUIApplication.straightToChat
        app.launch()
        let hide = app.buttons["Hide thinking"]
        XCTAssertTrue(hide.waitForExistence(timeout: 20), "The thinking isn't open while the reply is live")
        hide.tap()
        XCTAssertTrue(app.buttons["Show thinking"].waitForExistence(timeout: 3), "The tap didn't fold the thinking")
        XCTAssertFalse(hide.exists)
        // And it stays as the person left it once the reply is done.
        XCTAssertTrue(app.buttons["Regenerate"].waitForExistence(timeout: 30), "The demo reply never finished")
        XCTAssertTrue(app.buttons["Show thinking"].exists)
    }

    func testAToolStepOpensOntoWhatItReturned() {
        let app = launchDemo()
        let steps = app.buttons["Show tool steps"]
        XCTAssertTrue(steps.waitForExistence(timeout: 15), "No steps card on the demo reply")
        steps.tap()

        let step = app.buttons["Tool calendar, completed"]
        XCTAssertTrue(step.waitForExistence(timeout: 3), "The card didn't open onto its steps")
        XCTAssertFalse(app.text(containing: "Standup").exists, "A step's output is showing before it is opened")
        step.tap()
        XCTAssertTrue(app.text(containing: "Standup").waitForExistence(timeout: 3), "The step didn't open onto its output")
        XCTAssertTrue(app.buttons["Open full output"].exists)

        app.buttons["Open full output"].tap()
        XCTAssertTrue(app.navigationBars["calendar"].waitForExistence(timeout: 3), "The full output didn't open")
    }

    /// GitHub issue 46: a long-press on a reply's text selects the word under the finger where
    /// it stands, with the selection's menu; "Ask about this" puts it in the composer as a quote.
    func testALongPressSelectsInPlaceAndAsksAboutIt() {
        let app = launchDemo()
        let reply = app.text(containing: "I've added a reminder")
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "The demo reply didn't appear")
        reply.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 0.8)

        let ask = app.menuItems["Ask about this"].exists ? app.menuItems["Ask about this"] : app.buttons["Ask about this"]
        XCTAssertTrue(ask.waitForExistence(timeout: 3), "The long-press didn't select with the selection's menu")
        XCTAssertFalse(app.navigationBars["Select text"].exists, "It opened the sheet, not a selection in place")
        XCTAssertFalse(app.buttons["Make This a Routine…"].exists || app.buttons["Watch This…"].exists, "The reply's own menu came up instead")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "inline-selection"
        shot.lifetime = .keepAlways
        add(shot)
        // Let go with a tap elsewhere, and press again: the same, the reply drawn as before between.
        app.staticTexts["Redde"].firstMatch.tap()
        XCTAssertTrue(ask.waitForNonExistence(timeout: 3), "A tap elsewhere didn't let go of the selection")
        XCTAssertTrue(reply.waitForExistence(timeout: 3), "The reply wasn't drawn as before")
        reply.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).press(forDuration: 0.8)
        XCTAssertTrue(ask.waitForExistence(timeout: 3), "A second long-press didn't select")
        ask.tap()

        let composer = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.matching(NSPredicate(format: "value BEGINSWITH %@", "> ")).firstMatch
        let quoted = NSPredicate(format: "value BEGINSWITH %@", "> ")
        expectation(for: quoted, evaluatedWith: composer)
        waitForExpectations(timeout: 5)
    }

    /// The selection's handles move it, as in Notes: the end handle dragged along takes in more.
    func testDraggingAHandleGrowsTheSelection() {
        let app = launchDemo()
        let reply = app.text(containing: "I've added a reminder")
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "The demo reply didn't appear")
        reply.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).press(forDuration: 0.8)
        let selection = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH %@", "inline-selection|")).firstMatch
        XCTAssertTrue(selection.waitForExistence(timeout: 3), "The long-press didn't select in place")
        func state() -> (length: Int, end: CGPoint) {
            let parts = selection.identifier.split(separator: "|").compactMap { Int($0) }
            return (parts[0], CGPoint(x: parts[1], y: parts[2]))
        }
        let before = state()
        let first = XCTAttachment(screenshot: app.screenshot())
        first.name = "selected \(before.length) end \(Int(before.end.x)),\(Int(before.end.y))"
        first.lifetime = .keepAlways
        add(first)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let handle = origin.withOffset(CGVector(dx: before.end.x, dy: before.end.y + 4))
        handle.press(forDuration: 0.15, thenDragTo: origin.withOffset(CGVector(dx: min(before.end.x + 140, 380), dy: before.end.y + 4)))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "handle-dragged"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(selection.waitForExistence(timeout: 2), "The selection ended when its handle was dragged")
        let after = state()
        XCTAssertGreaterThan(after.length, before.length, "Dragging the end handle didn't take in more text (\(before.length) → \(after.length))")
    }

    /// The reply's menu is on its ··· button now, "Select text" (the whole reply in a sheet) with it.
    func testTheMoreButtonStillHasTheRepliesMenu() {
        let app = launchDemo()
        XCTAssertTrue(app.buttons["Regenerate"].waitForExistence(timeout: 15), "No actions under the reply")
        // The reply's, not the header's.
        app.buttons.matching(NSPredicate(format: "label == %@", "More")).allElementsBoundByIndex.last?.tap()
        XCTAssertTrue(app.buttons["Select text"].waitForExistence(timeout: 3), "No Select text in the ··· menu")
        app.buttons["Select text"].tap()
        XCTAssertTrue(app.navigationBars["Select text"].waitForExistence(timeout: 5), "The selectable copy didn't open")
    }

    /// A double-tap on a reply brings up the reactions; one picked shows under it.
    func testADoubleTapReacts() {
        let app = launchDemo()
        let reply = app.text(containing: "I've added a reminder")
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "The demo reply didn't appear")
        reply.doubleTap()
        let thumbs = app.buttons["React 👍"]
        XCTAssertTrue(thumbs.waitForExistence(timeout: 3), "The double-tap didn't bring up the reactions")
        thumbs.tap()
        XCTAssertTrue(app.buttons["You reacted 👍. Remove"].waitForExistence(timeout: 3), "The reaction doesn't show under the reply")
    }
}

