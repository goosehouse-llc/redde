import XCTest

/// The review and the checklist drawn to the approved designs (asked 2026-10-30), every part of
/// them working: a review's Cancel, Edit and its button; a checklist's rows, its ring and its
/// groups; each a finger's size, with a VoiceOver hint. `-echo.demoAsks` supplies the cards; the
/// answers and ticks start empty each run (`-cardAnswers`, `-cardTicks`).
@MainActor
final class AnswerCardsUITests: XCTestCase {
    private func launch(_ extra: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoAsks"] + extra + ["-cardAnswers", "<dict/>", "-cardTicks", "<dict/>"]
            + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        app.launch()
        return app
    }

    private func button(_ app: XCUIApplication, _ label: String) -> XCUIElement? {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).hittable(within: 10)
    }

    private func assertFingerSized(_ element: XCUIElement, _ name: String) {
        XCTAssertGreaterThanOrEqual(element.frame.height, 43.5, "\(name) is shorter than a finger")
        XCTAssertGreaterThanOrEqual(element.frame.width, 43.5, "\(name) is narrower than a finger")
    }

    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testAReviewEditsThenSendsWhatItSays() throws {
        let app = launch(["-echo.demoAsksReviewOnly"])
        XCTAssertTrue(app.text(containing: "Email to send").waitForExistence(timeout: 20), "The review didn't appear")
        XCTAssertTrue(app.text(containing: "Running a little late tonight").exists, "The subject isn't shown")

        let edit = try XCTUnwrap(button(app, "Edit"), "No Edit")
        let cancel = try XCTUnwrap(button(app, "Cancel"), "No Cancel")
        let send = try XCTUnwrap(button(app, "Send"), "No Send")
        for (element, name) in [(edit, "Edit"), (cancel, "Cancel"), (send, "Send")] { assertFingerSized(element, name) }

        // Edit opens the sheet for changes; Done shows it as it will go.
        edit.tap()
        let subject = app.textFields["Subject"].exists ? app.textFields["Subject"] : app.textViews["Subject"]
        XCTAssertTrue(subject.waitForExistence(timeout: 5), "Edit didn't open the fields")
        keep("review-editing")
        try XCTUnwrap(button(app, "Done"), "No Done while editing").tap()
        XCTAssertFalse(app.textFields["Subject"].exists || app.textViews["Subject"].exists, "Done didn't close the fields")

        // The button sends it, and the card says so.
        send.tap()
        XCTAssertTrue(app.text(containing: "Done: Send").waitForExistence(timeout: 10), "Send didn't answer the card")
        XCTAssertFalse(app.text(containing: "Needs you").exists && app.buttons["Edit"].exists, "The answered card still asks")
        keep("review-sent")
    }

    func testAReviewCancels() throws {
        let app = launch(["-echo.demoAsksBooking"])
        XCTAssertTrue(app.text(containing: "Table at Lupa Trattoria").waitForExistence(timeout: 20), "The booking didn't appear")
        let cancels = app.buttons.matching(NSPredicate(format: "label == %@", "Cancel"))
        // The booking's, the last card: on screen.
        let cancel = try XCTUnwrap(cancels.hittable(within: 10), "No Cancel on screen")
        cancel.tap()
        XCTAssertTrue(app.text(containing: "Cancelled").waitForExistence(timeout: 10), "Cancel didn't answer the card")
    }

    func testAChecklistTicksLiveAndFolds() throws {
        let app = launch(["-echo.demoAsksMore", "-echo.demoAsksListOnly"])
        XCTAssertTrue(app.text(containing: "Cocoa Beach weekend").waitForExistence(timeout: 20), "The list didn't appear")
        let ring = { (said: String) in app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", said)).firstMatch }
        XCTAssertTrue(ring("3 of 8 packed").exists, "The ring doesn't say how it stands")

        // Each row ticks, and the ring follows.
        let layer = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "A warm layer")).firstMatch
        XCTAssertTrue(layer.waitForExistence(timeout: 5), "No row for an item")
        assertFingerSized(layer, "A row")
        XCTAssertEqual(layer.value as? String, "Not done")
        layer.tap()
        XCTAssertTrue(ring("4 of 8 packed").waitForExistence(timeout: 5), "The ring didn't follow a tick")
        XCTAssertEqual(layer.value as? String, "Done")
        XCTAssertNotNil(button(app, "Send"), "A changed list has no Send")
        keep("checklist-ticked")
        layer.tap()
        XCTAssertTrue(ring("3 of 8 packed").waitForExistence(timeout: 5), "The ring didn't follow an untick")
        for text in ["Swimsuits", "Sandals", "Sunscreen", "Beach towels", "Umbrella", "Phone chargers", "Snacks for the drive"] {
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
            XCTAssertTrue(row.isHittable, "\(text) can't be tapped")
        }

        // A group's name folds it away and back.
        let clothes = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "Clothes")).firstMatch
        XCTAssertTrue(clothes.exists, "A group's name isn't a button")
        assertFingerSized(clothes, "A group's name")
        clothes.tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sandals")).firstMatch.waitForExistence(timeout: 2),
                       "The group didn't fold")
        clothes.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sandals")).firstMatch.waitForExistence(timeout: 5),
                      "The group didn't open again")

        let more = app.buttons["More for Cocoa Beach weekend"]
        XCTAssertTrue(more.exists, "No menu")
        assertFingerSized(more, "The menu")
    }
}
