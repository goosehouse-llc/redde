import XCTest

/// A thread of long replies shows its newest part, and "Show earlier messages" brings in what
/// comes before without moving the reader.
@MainActor
final class TranscriptPageUITests: XCTestCase {
    func testEarlierMessagesLoadOnATapAndThePlaceHolds() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Six turns of ~10,000-character replies: the page holds the last two.
        app.launchArguments = ["-echo.demoHeavy", "6"] + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        app.launch()
        // In the transcript itself: the header shows the first question too, as the title.
        let transcript = app.scrollViews.firstMatch
        func question(_ turn: Int) -> XCUIElement { transcript.staticTexts["Turn \(turn): walk me through the sequence again, in full."] }
        XCTAssertTrue(question(6).waitForExistence(timeout: 20), "The thread didn't open")
        XCTAssertTrue(question(5).exists, "The last turns should be laid out")
        // The oldest turn on the page: somewhere after the first, since the thread doesn't fit.
        let firstShown = try XCTUnwrap((1 ... 6).first { question($0).exists })
        XCTAssertGreaterThan(firstShown, 1, "The whole thread is laid out: the page isn't bounding it")

        // Up to the top of the page, where the button is.
        let earlier = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Show earlier messages")).firstMatch
        for _ in 0 ..< 14 where !earlier.isHittable { transcript.swipeDown(velocity: .fast) }
        XCTAssertTrue(earlier.isHittable, "No way to earlier messages at the top of the page")
        XCTAssertEqual(earlier.label, "Show earlier messages (\(2 * (firstShown - 1)))")
        XCTAssertTrue(question(firstShown).isHittable, "The page should open on a question, at its top")

        earlier.tap()
        XCTAssertTrue(question(firstShown - 1).waitForExistence(timeout: 5), "The earlier page didn't load")
        XCTAssertTrue(question(firstShown).isHittable, "The reader's place moved when the earlier page came in")
    }
}
