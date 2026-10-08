import XCTest

/// Reading a conversation: its own text size, how full the model's context is, and what this
/// iPhone kept of a server's conversations when the server can't be reached. No server needed.
@MainActor
final class ReadingUITests: XCTestCase {
    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Settings → Appearance → Chat text size, picked the way a person does.
    private func pick(_ size: String, in app: XCUIApplication) {
        app.buttons["More"].firstMatch.tap()
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings didn't open")
        let picker = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Chat text size")).firstMatch
        for _ in 0 ..< 6 where !(picker.exists && picker.isHittable) { app.swipeUp() }
        XCTAssertTrue(picker.exists && picker.isHittable, "No Chat text size in Settings")
        picker.tap()
        let choice = app.buttons[size]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "Chat text size doesn't offer \(size)")
        choice.tap()
        app.navigationBars["Settings"].buttons["Done"].tap()
    }

    func testTheConversationHasATextSizeOfItsOwn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // (The size is read as the iPhone's for this launch, whatever an earlier run left.)
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.demo", "-echo.demoShort", "-chatTextSize", "0"]
        app.launch()
        let reply = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "I've added a reminder")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20), "The demo conversation isn't on screen")
        let title = app.navigationBars.firstMatch.frame.height
        let usual = reply.frame.height

        pick("Largest", in: app)
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        let large = reply.frame.height
        keep("chat text size, largest")
        XCTAssertGreaterThan(large, usual, "Largest isn't larger than the iPhone's size")
        XCTAssertEqual(app.navigationBars.firstMatch.frame.height, title, "The bar around the conversation changed size with it")

        pick("Smallest", in: app)
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        keep("chat text size, smallest")
        XCTAssertLessThan(reply.frame.height, usual, "Smallest isn't smaller than the iPhone's size")

        pick("Same as iPhone", in: app)
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        XCTAssertEqual(reply.frame.height, usual, "Same as iPhone didn't put it back")
    }

    func testTheHeaderSaysHowFullTheContextIs() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.demo"]
        app.launch()
        let ring = app.buttons["Context"]
        XCTAssertTrue(ring.waitForExistence(timeout: 20), "No context ring in the header")
        XCTAssertTrue((ring.value as? String ?? "").contains("tokens"), "The ring doesn't say how many tokens: \(String(describing: ring.value))")
        keep("the context ring")
        ring.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "of 131")).firstMatch.waitForExistence(timeout: 5),
                      "Tapping the ring doesn't show the token counts")
        keep("the context ring, tapped")
    }

    func testAServersConversationsCanBeReadWhenItCannotBeReached() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // The Hermes API at an address nothing answers on, and a few conversations this iPhone
        // kept copies of from that server.
        app.launchArguments = XCUIApplication.straightToChat + XCUIApplication.chatsSection
            + ["-transport", "hermesSessions", "-gatewayURL", "http://127.0.0.1:9", "-echo.fresh", "-echo.demoSaved", "-echo.screen", "sessions"]
        app.launch()
        XCTAssertTrue(app.staticTexts["On this iPhone"].waitForExistence(timeout: 30)
                      || app.staticTexts["ON THIS IPHONE"].waitForExistence(timeout: 2), "The saved copies aren't offered when the list can't load")
        let copy = app.staticTexts["Lisbon trip ideas"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Saved copy")).firstMatch.exists)
        keep("saved copies")
        copy.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "a day in Sintra")).firstMatch.waitForExistence(timeout: 15),
                      "The saved copy didn't open")
        keep("a saved copy, open")
    }
}
