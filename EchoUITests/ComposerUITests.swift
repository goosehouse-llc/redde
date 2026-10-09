import XCTest

/// The message field's conveniences, with no server: a draft per conversation, Return that sends
/// when asked to, the page of its own for a long message, the microphone, and a pasted picture.
@MainActor
final class ComposerUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    /// On the OpenAI-compatible connection, pointed at nothing: messages can be sent (and fail),
    /// and the conversation list is the phone's own.
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + XCUIApplication.chatsSection
            + ["-transport", "chatCompletions", "-fastLaneURL", "http://127.0.0.1:9", "-fastLaneModel", "test"] + extra
        if extra.contains("-echo.fresh") { app.launchArguments.append("-echo.clearDrafts") }   // nothing left by an earlier test
        app.launch()
        return app
    }

    private func field(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "No message field")
        return field
    }

    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Taps the field until it has the keyboard's focus: right after a launch the first tap can
    /// land while the app is still settling. (Not "until the keyboard is on screen": with a
    /// hardware keyboard attached to the simulator there may be none to see.)
    private func focus(_ field: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 4 {
            field.tap()
            for _ in 0 ..< 6 {
                if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true || app.keyboards.firstMatch.exists { return }
                usleep(500_000)
            }
        }
        XCTFail("The message field didn't take the keyboard's focus")
    }

    private func type(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        focus(field, in: app)
        field.typeText(text)
    }

    private func clear(_ field: XCUIElement) {
        let text = field.value as? String ?? ""
        guard !text.isEmpty, text != field.placeholderValue else { return }
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count + 2))
    }

    /// Removes a conversation a test made, so the next run starts as this one did.
    private func delete(conversation title: String, in app: XCUIApplication) {
        app.buttons["Conversations"].firstMatch.tap()
        let row = app.staticTexts[title].firstMatch
        guard row.waitForExistence(timeout: 10) else { return }
        row.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        if delete.waitForExistence(timeout: 3) { delete.tap() }
    }

    /// Taps a conversation's row in the list. The title is also the header of the conversation
    /// that is open, and a plain tap fails when it finds both, which happened once in a full
    /// run as the list came in: wait for the row to be the only one.
    private func tapRow(_ title: String, in app: XCUIApplication) {
        let matches = app.staticTexts.matching(identifier: title)
        let deadline = Date().addingTimeInterval(5)
        while matches.count != 1, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        matches.firstMatch.tap()
    }

    func testEachConversationKeepsItsOwnDraft() {
        continueAfterFailure = false
        var app = launch(["-echo.fresh", "-echo.demoLibrary"])
        var composer = field(app)
        clear(composer)
        type("for a new conversation", into: composer, in: app)

        // Another conversation: its own draft, empty so far.
        app.buttons["Conversations"].firstMatch.tap()
        let hike = app.staticTexts["Plan the weekend hike"]
        XCTAssertTrue(hike.waitForExistence(timeout: 10), "The demo conversations aren't in the list")
        tapRow("Plan the weekend hike", in: app)
        composer = field(app)
        XCTAssertTrue(app.navigationBars.staticTexts["Plan the weekend hike"].waitForExistence(timeout: 10))
        clear(composer)
        XCTAssertNotEqual(composer.value as? String, "for a new conversation", "The new conversation's draft followed into another one")
        type("about the hike", into: composer, in: app)
        keep("a draft in an existing conversation")

        // Back to a new conversation: what was typed there is there.
        app.buttons["New conversation"].firstMatch.tap()
        XCTAssertEqual(field(app).value as? String, "for a new conversation")

        // And the hike's is still with the hike, after the app has been closed too. The list
        // says which conversation has something unsent.
        app.buttons["Conversations"].firstMatch.tap()
        XCTAssertTrue(hike.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Has a draft"].waitForExistence(timeout: 5), "The list doesn't mark the conversation with a draft")
        XCTAssertEqual(app.staticTexts.matching(identifier: "Has a draft").count, 1, "Only the one conversation has a draft")
        keep("a draft marked in the list")
        tapRow("Plan the weekend hike", in: app)
        XCTAssertEqual(field(app).value as? String, "about the hike")
        XCUIDevice.shared.press(.home)   // drafts are written as the app leaves the screen
        sleep(1)
        app.terminate()
        app = launch()
        _ = field(app)
        app.buttons["Conversations"].firstMatch.tap()
        XCTAssertTrue(hike.waitForExistence(timeout: 10))
        tapRow("Plan the weekend hike", in: app)
        XCTAssertTrue(app.navigationBars.staticTexts["Plan the weekend hike"].waitForExistence(timeout: 10))
        XCTAssertEqual(field(app).value as? String, "about the hike", "The draft didn't survive the app being closed")
        clear(field(app))
    }

    func testReturnSendsOnlyWhenSetTo() {
        continueAfterFailure = false
        var app = launch(["-echo.fresh", "-returnSends", "NO"])
        var composer = field(app)
        clear(composer)
        type("first line\nsecond line", into: composer, in: app)
        XCTAssertEqual(composer.value as? String, "first line\nsecond line", "Return didn't start a new line")
        clear(composer)
        app.terminate()

        app = launch(["-echo.fresh", "-returnSends", "YES"])
        composer = field(app)
        clear(composer)
        type("sent by Return\n", into: composer, in: app)
        // The message is in the conversation (the header takes its first words) and the field is empty again.
        XCTAssertTrue(app.navigationBars.staticTexts["sent by Return"].waitForExistence(timeout: 10), "Return didn't send")
        let left = composer.value as? String ?? ""
        XCTAssertTrue(left.isEmpty || left == composer.placeholderValue, "The field kept \(left)")
        keep("sent by Return")
        delete(conversation: "sent by Return", in: app)
    }

    func testALongMessageOpensOnAPageOfItsOwn() {
        continueAfterFailure = false
        let app = launch(["-echo.fresh"])
        let composer = field(app)
        clear(composer)
        XCTAssertFalse(app.buttons["Open the editor"].exists, "The editor button shows for an empty field")
        type(String(repeating: "A long message needs room. ", count: 8), into: composer, in: app)
        let open = app.buttons["Open the editor"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "No editor button for a long message")
        open.tap()
        XCTAssertTrue(app.navigationBars["Message"].waitForExistence(timeout: 10), "The editor didn't open")
        let editor = app.textViews["Message"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String ?? "").hasPrefix("A long message needs room."), "The editor doesn't hold the draft")
        editor.typeText("\nAnd a second paragraph.")
        keep("the editor")
        app.navigationBars["Message"].buttons["Done"].tap()
        XCTAssertTrue((field(app).value as? String ?? "").hasSuffix("And a second paragraph."), "What was written in the editor didn't come back to the field")
        clear(field(app))
    }

    func testTheMicrophoneInTheField() {
        continueAfterFailure = false
        let app = launch(["-echo.fresh"])
        _ = field(app)
        let dictate = app.buttons["Dictate"]
        XCTAssertTrue(dictate.waitForExistence(timeout: 10), "No Dictate button in the field")
        dictate.tap()
        for label in ["Allow", "OK"] where springboard.alerts.buttons[label].waitForExistence(timeout: 4) { springboard.alerts.buttons[label].tap() }
        // In the simulator the speech model may never arrive: either it listens, or it says why
        // not. Both leave the button a tap away from where it started.
        let stop = app.buttons["Stop dictating"]
        if stop.waitForExistence(timeout: 6) {
            keep("dictating")
            stop.tap()
        }
        XCTAssertTrue(dictate.waitForExistence(timeout: 15), "The microphone button didn't come back")
    }

    func testAPictureOnTheClipboardPastesAsAnAttachment() {
        continueAfterFailure = false
        // A picture, and nothing else, on the clipboard.
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 160))
        UIPasteboard.general.image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
        }
        let app = launch(["-echo.fresh"])
        let composer = field(app)
        clear(composer)
        focus(composer, in: app)
        sleep(1)
        composer.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "The field offers no Paste for a picture")
        paste.tap()
        for label in ["Allow Paste", "Allow"] where springboard.alerts.buttons[label].waitForExistence(timeout: 3) { springboard.alerts.buttons[label].tap() }
        let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove ")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "The pasted picture isn't attached")
        let left = composer.value as? String ?? ""
        XCTAssertTrue(left.isEmpty || left == composer.placeholderValue, "Pasting a picture put text in the field: \(left)")
        keep("a pasted picture")
        remove.tap()
    }
}
