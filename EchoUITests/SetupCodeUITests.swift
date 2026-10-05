import XCTest

/// Setup by link: a `redde://connect` link is shown for confirmation, saved only on request, and
/// can be taken back out; a server's connection can be shown as a code for another device.
@MainActor
final class SetupCodeUITests: XCTestCase {
    /// Nothing listens on port 9, so the connection test fails at once.
    private let link = "redde://connect?name=UITest%20Office&dashboard=http://127.0.0.1:9&user=redde&password=not-a-real-password"
    private let base = ["-echo.demo", "-echo.demoShort", "-setupDone", "YES", "-openToVoiceScreen", "NO", "-listenOnOpen", "NO", "-requireBiometrics", "NO"]

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = base + extra
        app.launch()
        return app
    }

    private func text(_ app: XCUIApplication, containing part: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", part)).firstMatch
    }

    /// The Servers screen, for checking what was saved.
    private func serversShowTheTestServer() -> Bool {
        let app = launch(["-echo.screen", "servers"])
        XCTAssertTrue(app.navigationBars["Servers"].waitForExistence(timeout: 15), "The Servers screen didn't open")
        return text(app, containing: "UITest Office").exists
    }

    func testALinkIsShownAndSavesNothingUntilAsked() {
        continueAfterFailure = false
        // Opened the way the Camera or a tapped link opens it, with the app already running.
        let app = launch([])
        XCTAssertTrue(app.navigationBars.buttons["New conversation"].firstMatch.waitForExistence(timeout: 15), "The app didn't come up")
        XCUIDevice.shared.system.open(URL(string: link)!)
        XCTAssertTrue(app.navigationBars["Setup code"].waitForExistence(timeout: 15), "No confirmation for the setup link")
        XCTAssertTrue(text(app, containing: "http://127.0.0.1:9").exists, "The address to check isn't shown")
        XCTAssertTrue(text(app, containing: "password included").exists)
        XCTAssertTrue(text(app, containing: "Only use a code from someone you trust").exists)

        app.navigationBars["Setup code"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Setup code"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(serversShowTheTestServer(), "A cancelled setup link left a server behind")
    }

    func testAddingAServerThatDoesntAnswerCanBeUndone() throws {
        continueAfterFailure = false
        let app = launch(["-echo.setupCode", link])
        XCTAssertTrue(app.navigationBars["Setup code"].waitForExistence(timeout: 15), "No confirmation for the setup link")
        // A simulator whose server is still blank would have the code fill it in, which this
        // test can't put back.
        let add = app.buttons["Add server"]
        try XCTSkipUnless(add.exists, "This simulator has no server set up, so the code wouldn't add one")
        add.tap()

        XCTAssertTrue(text(app, containing: "No Hermes Dashboard answered at 127.0.0.1").waitForExistence(timeout: 20),
                      "The connection test didn't report the dead address")
        let remove = app.buttons["Remove this server"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "No way to take the server back out")
        remove.tap()
        XCTAssertTrue(app.navigationBars["Setup code"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(serversShowTheTestServer(), "Remove left the server behind")
    }

    func testPastingASetupLinkInSetup() {
        continueAfterFailure = false
        UIPasteboard.general.string = "Here is the link: \(link)"
        let app = launch(["-echo.screen", "setup"])
        XCTAssertTrue(app.navigationBars["Set up Redde"].waitForExistence(timeout: 15), "Setup didn't open")
        XCTAssertTrue(text(app, containing: "Paste a setup link").waitForExistence(timeout: 5))
        app.buttons["Paste"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Setup code"].waitForExistence(timeout: 10), "Pasting a setup link didn't bring up its confirmation")
        XCTAssertTrue(text(app, containing: "http://127.0.0.1:9").exists)
        app.navigationBars["Setup code"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Set up Redde"].waitForExistence(timeout: 5), "Cancel didn't return to Setup")
    }

    func testTheConnectionIsShownAsACodeForAnotherDevice() throws {
        continueAfterFailure = false
        let app = launch(["-echo.screen", "settings"])
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15), "Settings didn't open")
        let button = app.buttons["Set up another device…"].firstMatch
        for _ in 0 ..< 6 where !button.isHittable { app.swipeUp(velocity: .slow) }
        button.tap()
        XCTAssertTrue(app.navigationBars["Set up another device"].waitForExistence(timeout: 5))
        try XCTSkipIf(text(app, containing: "no connection to hand over yet").exists, "This simulator has no connection set up")
        XCTAssertTrue(app.images["setup-code"].waitForExistence(timeout: 5), "No QR code")
        // Without the passwords until they are asked for (which takes the passcode).
        XCTAssertTrue(text(app, containing: "Passwords and keys are left out").exists, "The code should start without secrets")
        XCTAssertEqual(app.switches.firstMatch.value as? String, "0")
        // (Copy link is left alone: the Simulator app mirrors its clipboard to the Mac's.)
        app.navigationBars["Set up another device"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }
}
