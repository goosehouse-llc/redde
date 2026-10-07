import XCTest

/// Signing in to a Dashboard through a browser, with the real thing at every step: the app's
/// button, the system's sign-in sheet on the Dashboard's own login page, and the way back to the
/// app over the phone's loopback. Then Settings says who is signed in, and Sign out forgets it.
///
/// Needs the lab's Dashboard, which has a login (`scripts/hermes-lab/lab.sh up <tag> approval`:
/// lab / labpass-labpass on 127.0.0.1:19119, which a simulator shares with the Mac). Skips
/// without it.
@MainActor
final class SignInUITests: XCTestCase {
    private let dashboard = "http://127.0.0.1:19119"
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    /// For this launch only, the app's Dashboard is the lab's, with no username and no password.
    /// `signedOut` also forgets a sign-in an earlier run left behind.
    private func launch(screen: String, signedOut: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat
            + ["-echo.screen", screen, "-transport", "hermesServe", "-serveURL", dashboard, "-serveUsername", ""]
        app.launchEnvironment["ECHO_TEST_SERVE_PASSWORD"] = ""   // empty deletes
        if signedOut { app.launchEnvironment["ECHO_TEST_SERVE_SIGNIN"] = "" }
        app.launch()
        return app
    }

    private func labIsUp() -> Bool {
        var request = URLRequest(url: URL(string: dashboard + "/api/status")!)
        request.timeoutInterval = 3
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var gated = false
        URLSession.shared.dataTask(with: request) { data, _, _ in
            gated = data.map { String(decoding: $0, as: UTF8.self).contains("native_pkce") } ?? false
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return gated
    }

    private func keep(_ screenshot: XCUIScreenshot, as name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSigningInThroughTheSheetThenOut() throws {
        continueAfterFailure = false
        try XCTSkipUnless(labIsUp(), "No lab Dashboard with a login on 127.0.0.1:19119 (scripts/hermes-lab/lab.sh up <tag> approval)")

        // Setup, on the Dashboard connection: the address is in, and there is nothing to type a login into.
        var app = launch(screen: "setup", signedOut: true)
        XCTAssertTrue(app.navigationBars["Set up Redde"].waitForExistence(timeout: 20), "Setup didn't open")
        // The Dashboard's fields are below the welcome.
        let signIn = app.buttons["Sign in with a browser"]
        for _ in 0 ..< 6 where !(signIn.exists && signIn.isHittable) { app.swipeUp() }
        XCTAssertTrue(signIn.exists && signIn.isHittable, "Setup doesn't offer the browser sign-in")
        signIn.tap()

        // iOS asks before an app opens a sign-in sheet.
        let consent = springboard.alerts.buttons["Continue"]
        if consent.waitForExistence(timeout: 10) { consent.tap() }

        // The Dashboard's own login page, in the sheet. The app sees none of this.
        let sheet = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let page = app.webViews.firstMatch.waitForExistence(timeout: 20) ? app.webViews.firstMatch : sheet.webViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 20), "The sign-in sheet didn't open the Dashboard's page")
        let username = page.textFields.firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 20), "The Dashboard's login page has no username field")
        keep(XCUIScreen.main.screenshot(), as: "sign-in sheet")
        username.tap()
        username.typeText("lab")
        let password = page.secureTextFields.firstMatch
        password.tap()
        password.typeText("labpass-labpass")
        // (The page draws its button in capitals.)
        page.buttons.matching(NSPredicate(format: "label ==[c] %@", "Sign in")).firstMatch.tap()

        // Back in the app, by way of its loopback listener: signed in, and the connection test passes.
        XCTAssertTrue(app.text(containing: "Signed in through a browser").waitForExistence(timeout: 30),
                      "The sheet didn't bring the sign-in back to the app")
        XCTAssertTrue(app.text(containing: "Login accepted").waitForExistence(timeout: 20), "The Dashboard didn't take the token")
        keep(XCUIScreen.main.screenshot(), as: "signed in, in setup")
        app.terminate()

        // Settings says who, and Sign out forgets it.
        app = launch(screen: "settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20), "Settings didn't open")
        let details = app.buttons["Connection details"]
        for _ in 0 ..< 8 where !(details.exists && details.isHittable) { app.swipeUp() }
        details.tap()
        XCTAssertTrue(app.staticTexts["Signed in"].waitForExistence(timeout: 15), "Settings doesn't show the sign-in")
        // The name is asked of the Dashboard and arrives a moment later. However the row is read
        // out (two texts, or one with a value), "lab" is in it.
        let named = NSPredicate(format: "label ENDSWITH %@ OR value ENDSWITH %@", "lab", "lab")
        let who = app.descendants(matching: .any).matching(named).firstMatch
        if !who.waitForExistence(timeout: 15) {
            let seen = app.staticTexts.allElementsBoundByIndex.map { "\($0.label)|\(String(describing: $0.value))" }
            XCTFail("Settings doesn't say who is signed in. On screen: \(seen)")
        }
        keep(XCUIScreen.main.screenshot(), as: "signed in, in Settings")
        app.buttons["Sign out"].tap()
        XCTAssertTrue(app.buttons["Sign in with a browser"].waitForExistence(timeout: 10), "Signing out didn't bring the button back")
        XCTAssertFalse(app.staticTexts["Signed in"].exists)
    }
}
