import XCTest

/// A file that came with a reply opens in QuickLook from its tile, and Done closes it again: it
/// had no Done and could only be swiped away (a Reddit report, 2026-10-21). `-echo.demoDocument`
/// supplies the reply; no server is needed.
@MainActor
final class ReplyDocumentUITests: XCTestCase {
    func testAFileInAReplyOpensAndDoneClosesIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoDocument"] + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        app.launch()
        XCTAssertTrue(app.text(containing: "briefing as a file").waitForExistence(timeout: 20), "The demo reply didn't appear")
        let tile = app.text(containing: "briefing.md")
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "No tile for the file")
        tile.tap()
        let done = app.navigationBars.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "The file opened without a Done button")
        // Long enough for QuickLook to draw the file before the picture is taken.
        _ = app.staticTexts["nothing by this name"].waitForExistence(timeout: 2)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "file open"
        attachment.lifetime = .keepAlways
        add(attachment)
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "Done didn't close the file")
        XCTAssertTrue(tile.isHittable, "The chat isn't back after closing the file")
    }

    /// A file the reply named but nobody could fetch is a file to open, not a path; with no
    /// Dashboard login it says where to add one.
    func testAFileNamedButNotFetchedSaysWhy() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoDocument"] + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        app.launch()
        XCTAssertTrue(app.text(containing: "briefing as a file").waitForExistence(timeout: 20), "The demo reply didn't appear")
        XCTAssertFalse(app.text(containing: "MEDIA:").exists, "The path shows as text")
        let chip = app.buttons["week-ahead.md"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "No chip for the named file")
        chip.tap()
        XCTAssertTrue(app.text(containing: "Settings → Connection details").waitForExistence(timeout: 5), "It doesn't say why it can't open")
    }
}
