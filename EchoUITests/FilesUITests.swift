import XCTest

/// Settings → Files, on sample folders (`-echo.demoFiles`), so it needs no server: folders
/// opened, hidden names kept back, a text file read and changed, a folder made and deleted, and
/// a search of the names.
@MainActor
final class FilesUITests: XCTestCase {
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A folder's or a file's row: its name, then its size and date.
    private func row(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")).firstMatch
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    func testFoldersATextFileAndANewFolder() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.demoFiles", "-echo.screen", "settings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 30), "Settings didn't open")
        let files = app.buttons["Files"]
        for _ in 0 ..< 14 where !(files.exists && files.isHittable) { app.swipeUp() }
        XCTAssertTrue(files.exists && files.isHittable, "No Files row in Settings")
        files.tap()
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 10), "The file browser didn't open")

        // The server's starting folder: folders first, dotfiles kept back.
        XCTAssertTrue(row("Documents", in: app).waitForExistence(timeout: 10), "The folder didn't list")
        XCTAssertTrue(row("projects", in: app).exists && row("notes.md", in: app).exists && row("photo.jpg", in: app).exists)
        XCTAssertFalse(row(".hermes", in: app).exists, "A hidden folder is shown")
        XCTAssertTrue(app.staticTexts["/home/redde"].exists, "The path isn't shown")
        shot("files home")

        // Hermes's own folder is one tap away all the same.
        app.buttons["Hermes"].tap()
        XCTAssertTrue(row("SOUL.md", in: app).waitForExistence(timeout: 10), "Hermes's folder didn't open")
        XCTAssertTrue(row("memories", in: app).exists)
        back(app)

        // A text file is read, changed and saved.
        row("notes.md", in: app).tap()
        XCTAssertTrue(app.navigationBars["notes.md"].waitForExistence(timeout: 10))
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue((editor.value as? String)?.contains("Renew the domain") == true, "The file's text isn't shown")
        let save = app.buttons["Save"]
        XCTAssertFalse(save.isEnabled, "Nothing changed, nothing to save")
        editor.tap()
        editor.typeText("- Added from the phone\n")
        XCTAssertTrue(save.isEnabled)
        shot("files text")
        save.tap()
        XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: false, timeout: 5), "Saving didn't finish")
        back(app)
        row("notes.md", in: app).tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue((editor.value as? String)?.contains("Added from the phone") == true, "The change wasn't kept")
        back(app)

        // Into a folder; a new folder there, then deleted.
        row("Documents", in: app).tap()
        XCTAssertTrue(app.navigationBars["Documents"].waitForExistence(timeout: 10))
        XCTAssertTrue(row("Reports", in: app).waitForExistence(timeout: 10) && row("budget.csv", in: app).exists && row("scan.pdf", in: app).exists)
        app.buttons["Folder Actions"].tap()
        app.buttons["New Folder…"].tap()
        let name = app.alerts["New Folder"].textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), "No name was asked for")
        name.typeText("Inbox")
        app.alerts["New Folder"].buttons["Create"].tap()
        let inbox = row("Inbox", in: app)
        XCTAssertTrue(inbox.waitForExistence(timeout: 10), "The new folder isn't listed")
        shot("files folder")
        inbox.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let confirm = app.buttons["Delete Folder and Its Contents"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Deleting a folder didn't ask first")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'everything in it'")).firstMatch.exists)
        confirm.tap()
        XCTAssertTrue(inbox.waitForNonExistence(timeout: 10), "The folder wasn't deleted")
        XCTAssertTrue(row("Reports", in: app).exists, "Something else went with it")

        // A search of the names.
        let search = app.searchFields.firstMatch
        if !search.exists { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5), "No search field")
        search.tap()
        search.typeText("bud")
        XCTAssertTrue(row("budget.csv", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(row("scan.pdf", in: app).exists, "The search didn't narrow the list")
    }
}
