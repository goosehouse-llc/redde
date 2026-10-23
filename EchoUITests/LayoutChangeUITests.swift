import XCTest
import notify

/// Opening or closing an iPhone Duo swaps the iPhone's layout for the wide one, or back, while
/// Redde runs, and the chat screen is built again in the other (`LayoutCarry`). `-echo.flipLayout`
/// swaps it when the Darwin notification is posted: here, at the moment each test wants.
@MainActor
final class LayoutChangeUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func launch(_ extra: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.flipLayout", "-echo.clearDrafts"] + extra + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        app.launch()
        return app
    }

    /// The button of that name that is on screen: the iPhone's conversation list stays built
    /// while its panel is closed, with a More menu of its own.
    private func tapOnScreen(_ name: String, in place: XCUIElementTypeQueryProvider) {
        let named = place.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", name, name))
        XCTAssertTrue(named.firstMatch.waitForExistence(timeout: 5), "No \(name) button")
        var button: XCUIElement?
        for _ in 0 ..< 10 where button == nil {
            button = named.allElementsBoundByIndex.first { $0.isHittable }
            if button == nil { Thread.sleep(forTimeInterval: 0.3) }
        }
        XCTAssertNotNil(button, "No \(name) button on screen")
        button?.tap()
    }

    /// The chat's More menu: not a reply's (its action row has a More too), and wherever the bar
    /// is (down the side of an iPhone Duo's outer display, in the iOS 27.1 SDK).
    private func openChatMenu(_ app: XCUIApplication) {
        let inReplies = Set(app.scrollViews.buttons.matching(identifier: "More").allElementsBoundByIndex.map { "\($0.frame)" })
        let menu = app.buttons.matching(identifier: "More").allElementsBoundByIndex.first { $0.isHittable && !inReplies.contains("\($0.frame)") }
        XCTAssertNotNil(menu, "No More menu on the chat")
        menu?.tap()
    }

    /// The layout swapped, and a moment for the other to be built and settle.
    private func flip() {
        notify_post("com.goosehouse.echo.debug.flipLayout")
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// The longer texts in the middle of the screen (between the header and the composer), read in
    /// one snapshot.
    private func textsOnScreen(_ app: XCUIApplication) throws -> Set<String> {
        let window = app.windows.firstMatch.frame
        var found: Set<String> = []
        func walk(_ element: XCUIElementSnapshot) {
            if element.elementType == .staticText, element.label.count > 12,
               element.frame.minY > window.minY + 100, element.frame.maxY < window.maxY - 120 {
                found.insert(element.label)
            }
            element.children.forEach(walk)
        }
        walk(try app.scrollViews.firstMatch.snapshot())
        return found
    }

    /// Read back up a long conversation: through the change and back, the same words are on screen,
    /// not the end.
    func testTheReaderKeepsTheirPlace() throws {
        let app = launch(["-echo.demoLong"])
        let end = app.staticTexts["End of the long demo."]
        XCTAssertTrue(end.waitForExistence(timeout: 15), "The long demo didn't open at its end")
        let transcript = app.scrollViews.firstMatch
        transcript.swipeDown(velocity: .fast)
        transcript.swipeDown(velocity: .fast)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(end.isHittable, "Not scrolled back")
        let before = try textsOnScreen(app)
        XCTAssertFalse(before.isEmpty, "Nothing read on screen")
        for side in ["the other layout", "back"] {
            flip()
            XCTAssertFalse(end.isHittable, "In \(side), the transcript went back to its end")
            let now = try textsOnScreen(app)
            XCTAssertFalse(now.isDisjoint(with: before), "In \(side), none of \(before.prefix(3)) is on screen any more, but \(now.prefix(3))")
        }
    }

    /// Half a message typed: it is still there, with the keyboard up, to go on typing.
    func testTypingCarriesOn() {
        let app = launch(["-echo.demo", "-echo.demoShort"])
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "No message field")
        field.tap()
        field.typeText("half a thought")
        for side in ["the other layout", "back"] {
            flip()
            let now = app.textFields.firstMatch
            XCTAssertEqual(now.value as? String, "half a thought", "In \(side), the draft went")
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "In \(side), the keyboard went")
            now.typeText(" more")
            XCTAssertEqual(now.value as? String, "half a thought more", "In \(side), typing doesn't go on in the field")
            now.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        }
    }

    /// Voice mode stays up through the change: the conversation goes on.
    func testVoiceModeStaysUp() {
        let app = launch(["-echo.demo", "-echo.demoShort", "-handsFreeByDefault", "NO"])
        let talk = app.buttons["Talk"]
        XCTAssertTrue(talk.waitForExistence(timeout: 20), "No Talk button beside the message field")
        talk.tap()
        let typing = app.buttons["Switch to typing"]
        for _ in 0 ..< 3 where !typing.waitForExistence(timeout: 8) {
            for label in ["Allow", "OK"] where springboard.alerts.buttons[label].exists { springboard.alerts.buttons[label].tap() }
        }
        XCTAssertTrue(typing.exists, "The voice screen didn't open")
        for side in ["the other layout", "back"] {
            flip()
            XCTAssertTrue(typing.exists, "In \(side), the voice screen closed")
        }
    }

    /// A message half written to a group chat goes over with it.
    func testAGroupChatsDraftCarriesOn() {
        let app = launch(["-echo.demoProjects", "-echo.demoBots", "-echo.openGroup", "-displayName", "Redde"])
        // `-echo.openGroup` opens the group chat from the conversation list, which the wide layout
        // has on screen: there first.
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 20), "Redde didn't open")
        flip()
        func field() -> XCUIElement { app.textFields["group-composer"] }
        XCTAssertTrue(field().waitForExistence(timeout: 20), "No message field in the group chat")
        field().tap()
        field().typeText("for all of you")
        XCTAssertEqual(field().value as? String, "for all of you", "Typing didn't reach the group chat's field")
        for side in ["the other layout", "back"] {
            flip()
            XCTAssertEqual(field().value as? String, "for all of you", "In \(side), the group chat's draft went")
        }
    }

    /// Settings, opened from the chat's menu, stays open: it is the app's, not the layout's.
    func testSettingsStaysOpen() {
        let app = launch(["-echo.demo", "-echo.demoShort"])
        XCTAssertTrue(app.buttons["More"].firstMatch.waitForExistence(timeout: 20), "No More menu on the chat")
        openChatMenu(app)
        tapOnScreen("Settings", in: app)
        let settings = app.navigationBars["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings didn't open")
        for side in ["the other layout", "back"] {
            flip()
            XCTAssertTrue(settings.exists, "In \(side), Settings closed")
        }
    }

    /// Find in conversation keeps its words and stays open.
    func testFindKeepsItsWords() {
        let app = launch(["-echo.demoLong"])
        XCTAssertTrue(app.staticTexts["End of the long demo."].waitForExistence(timeout: 15), "The long demo didn't open")
        openChatMenu(app)
        tapOnScreen("Find in conversation", in: app)
        let find = app.textFields["Find in conversation"]
        XCTAssertTrue(find.waitForExistence(timeout: 5), "Find didn't open")
        find.typeText("kitchen")
        for side in ["the other layout", "back"] {
            flip()
            XCTAssertEqual(app.textFields["Find in conversation"].value as? String, "kitchen", "In \(side), Find lost its words")
        }
    }
}
