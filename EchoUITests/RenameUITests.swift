import XCTest

/// Rename from the header's menu: the alert takes a name and the header shows it.
@MainActor
final class RenameUITests: XCTestCase {
    func testRenamingFromTheHeaderMenuChangesTheHeader() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoShort", "-conversations.section", "sessions", "-setupDone", "YES", "-openToVoiceScreen", "NO",
                               "-listenOnOpen", "NO", "-requireBiometrics", "NO"]
        app.launch()
        func header(_ title: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        }
        XCTAssertTrue(header("What's on my calendar tomorrow").waitForExistence(timeout: 15), "The demo didn't open under its first question")

        app.navigationBars.buttons["More"].firstMatch.tap()   // the reply's action row has a "More" too
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 3), "No Rename in the header menu")
        app.buttons["Rename"].tap()

        let alert = app.alerts["Rename conversation"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3), "Rename didn't ask for a name")
        let field = alert.textFields.firstMatch
        let current = (field.value as? String) ?? ""
        XCTAssertTrue(current.hasPrefix("What's on my calendar tomorrow"), "The field doesn't start from the current title")
        // The field has the keyboard and its cursor at the end: delete the old title, type the
        // new name, Return. (No taps inside the alert: once the keyboard has pushed it up, the
        // accessibility frames of its field and buttons stay where they were, and a tap aimed
        // by them lands below the real thing.)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + "Vet and calendar\n")
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3), "Return didn't save and close the alert")

        XCTAssertTrue(header("Vet and calendar").waitForExistence(timeout: 5), "The header didn't take the new name")
    }
}
