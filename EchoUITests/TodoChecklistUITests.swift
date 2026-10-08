import XCTest

/// The agent's task list under a reply, on sample data (`-echo.demoTodos`): two replies, each
/// with the list as it left it. Needs no server.
@MainActor
final class TodoChecklistUITests: XCTestCase {
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, labelled label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    func testEachReplyShowsTheTaskListAsItLeftIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.demoTodos"]
        app.launch()

        // The newest reply: three of the six steps still wanted are done, one was dropped.
        XCTAssertTrue(element(app, labelled: "Tasks, 3 of 6 done").waitForExistence(timeout: 20), "The last reply has no task list")
        for row in ["Done: Import them into the new one", "In progress: Fix the image links", "Done: Cover images", "To do: Inline images",
                    "Dropped: Redirect the old addresses", "To do: Check the feed in a reader"] {
            XCTAssertTrue(element(app, labelled: row).exists, "No row \"\(row)\" in the last reply's list")
        }
        shot("task list")

        // The reply before it keeps the list as it stood then.
        let earlier = element(app, labelled: "Tasks, 1 of 7 done")
        for _ in 0 ..< 6 where !earlier.exists { app.swipeDown() }
        XCTAssertTrue(earlier.exists, "The earlier reply lost its own list")
        XCTAssertTrue(element(app, labelled: "In progress: Import them into the new one").exists, "The earlier list shows the later state")
        shot("task list earlier")
    }
}
