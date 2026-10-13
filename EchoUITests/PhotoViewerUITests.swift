import XCTest

/// Pictures in the conversation: several are set out together, a tap opens the one tapped full
/// screen, a swipe goes to the next, and a pinch or a double tap zooms. Needs no server.
@MainActor
final class PhotoViewerUITests: XCTestCase {
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoPhotos"] + XCUIApplication.straightToChat
        app.launch()
        XCTAssertTrue(app.staticTexts["Here are the 5 most recent photos from your library."].waitForExistence(timeout: 20), "The photo demo didn't open")
        return app
    }

    /// The viewer's "Photo 2 of 5", by what it says (it is found by name as "photo-count").
    private func says(_ words: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", words)).firstMatch
    }

    /// The picture on screen in the viewer. Its neighbors are kept ready beside it.
    private func picture(in app: XCUIApplication) -> XCUIElement {
        let all = app.descendants(matching: .any).matching(identifier: "photo")
        for index in 0 ..< all.count where all.element(boundBy: index).isHittable { return all.element(boundBy: index) }
        return all.firstMatch
    }

    func testSeveralPicturesOpenOnTheOneTappedAndSwipeToTheNext() {
        let app = launch()
        shot("pictures in the conversation")
        // The reply's five pictures are the last collage; the two that were sent come first.
        let second = app.descendants(matching: .any).matching(identifier: "photo-tile-2")
        XCTAssertEqual(second.count, 2, "Two messages have a second picture")
        let tile = second.element(boundBy: 1)
        XCTAssertEqual(tile.label, "Photo 2 of 5")
        tile.tap()

        let count = app.staticTexts["photo-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5), "The viewer didn't open")
        XCTAssertEqual(count.label, "Photo 2 of 5")
        // And it is the second picture that is on the screen, not only the count that says so.
        XCTAssertEqual(picture(in: app).label, "photo-2.jpg", "The viewer opened on another picture than the one tapped")
        shot("viewer, second of five")

        picture(in: app).swipeLeft()
        XCTAssertTrue(says("Photo 3 of 5", in: app).waitForExistence(timeout: 3),
                      "A swipe didn't go to the next picture: the viewer says “\(count.exists ? count.label : "nothing, it is gone")”")
        XCTAssertEqual(picture(in: app).label, "photo-3.jpg")
        picture(in: app).swipeRight()
        XCTAssertTrue(says("Photo 2 of 5", in: app).waitForExistence(timeout: 3),
                      "A swipe back didn't go to the picture before: the viewer says “\(count.exists ? count.label : "nothing, it is gone")”")
        picture(in: app).swipeRight()
        XCTAssertTrue(says("Photo 1 of 5", in: app).waitForExistence(timeout: 3),
                      "Swiping back didn't reach the first: the viewer says “\(count.exists ? count.label : "nothing, it is gone")”")
        XCTAssertEqual(picture(in: app).label, "photo-1.jpg")

        app.buttons["Close"].tap()
        XCTAssertTrue(count.waitForNonExistence(timeout: 5), "The viewer didn't close")

        // The fourth tile stands for the fifth picture too: it opens on the fourth, and the
        // fifth is a swipe on.
        let last = app.descendants(matching: .any).matching(identifier: "photo-tile-4").firstMatch
        XCTAssertEqual(last.label, "Photo 4 of 5, and 1 more")
        last.tap()
        XCTAssertTrue(says("Photo 4 of 5", in: app).waitForExistence(timeout: 5))
        picture(in: app).swipeLeft()
        XCTAssertTrue(says("Photo 5 of 5", in: app).waitForExistence(timeout: 3), "The picture without a tile isn't in the viewer")
        app.buttons["Close"].tap()
    }

    func testAPinchZoomsAndADoubleTapGoesBack() {
        let app = launch()
        app.descendants(matching: .any).matching(identifier: "photo-tile-1").element(boundBy: 1).tap()
        XCTAssertTrue(says("Photo 1 of 5", in: app).waitForExistence(timeout: 5), "The viewer didn't open")
        let shown = picture(in: app)
        XCTAssertEqual(shown.value as? String ?? "", "", "The picture opens whole")

        shown.pinch(withScale: 2.5, velocity: 2)
        let zoomed = NSPredicate(format: "value BEGINSWITH 'Zoomed in'")
        expectation(for: zoomed, evaluatedWith: picture(in: app))
        waitForExpectations(timeout: 5)
        XCTAssertTrue(says("Photo 1 of 5", in: app).exists, "The pinch closed the viewer or turned the page")
        shot("zoomed in")

        // Zoomed in, a drag moves about the picture and not on to the next one.
        picture(in: app).swipeLeft(velocity: .slow)
        XCTAssertTrue(says("Photo 1 of 5", in: app).exists, "A drag on a zoomed picture turned the page")

        picture(in: app).doubleTap()
        let whole = NSPredicate(format: "value == ''")
        expectation(for: whole, evaluatedWith: picture(in: app))
        waitForExpectations(timeout: 5)

        picture(in: app).doubleTap()
        expectation(for: zoomed, evaluatedWith: picture(in: app))
        waitForExpectations(timeout: 5)
        app.buttons["Close"].tap()
        XCTAssertTrue(says("Photo 1 of 5", in: app).waitForNonExistence(timeout: 5))
    }

    /// One picture on its own opens the same way, with nothing to count.
    func testASinglePictureZoomsToo() {
        let app = launch()
        let single = app.images["again-2.jpg"]
        XCTAssertTrue(single.waitForExistence(timeout: 5), "The reply's one picture isn't there")
        single.tap()
        let shown = picture(in: app)
        XCTAssertTrue(shown.waitForExistence(timeout: 5), "The viewer didn't open")
        XCTAssertFalse(app.staticTexts["photo-count"].exists)
        shown.pinch(withScale: 3, velocity: 2)
        expectation(for: NSPredicate(format: "value BEGINSWITH 'Zoomed in'"), evaluatedWith: picture(in: app))
        waitForExpectations(timeout: 5)
        app.buttons["Close"].tap()
    }
}
