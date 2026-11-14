import XCTest

/// All Servers on the demo list (`-echo.demoAllServers`, no server): another server's chats among
/// this one's, each tagged with its server, and a line naming the one that didn't answer.
@MainActor
final class AllServersUITests: XCTestCase {
    func testAnotherServersChatsAreListedWithItsName() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoProjects", "-echo.demoAllServers", "-echo.clearDrafts", "-displayName", "Redde"]
            + XCUIApplication.straightToChat
        app.launch()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 20))
        if app.windows.firstMatch.frame.width < 600 { app.buttons["Conversations"].firstMatch.tap() }

        let list = app.collectionViews.firstMatch
        let row = list.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Garage door sensor")).firstMatch
        // Below the drawer's hello, counters and places: scrolled to.
        for _ in 0 ..< 4 where !(row.waitForExistence(timeout: 3) && row.isHittable) { list.swipeUp() }
        XCTAssertTrue(row.exists, "the other server's chat isn't listed")
        XCTAssertTrue((row.label as NSString).contains("Workshop"), "its row doesn't name its server: \(row.label)")
        XCTAssertTrue(app.text(containing: "Cabin didn't answer").exists, "the server that didn't answer isn't named")
        XCTAssertTrue(list.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Transcript scrolling")).firstMatch.exists,
                      "this server's own chats aren't there with it")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "all-servers"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
