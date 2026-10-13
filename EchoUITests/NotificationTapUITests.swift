import XCTest

/// A notification tapped while Redde isn't in front. iOS hands the tap to the app and waits to
/// be told it was handled; 1.7 told it from a background thread, and iOS closed the app for that
/// before it ever came to the front. The notification here is a local one the app posts for the
/// test (`-echo.demoNotify`): a tap on it travels the same way as a tap on one a Hermes sent.
@MainActor
final class NotificationTapUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    /// Redde, started with a notification on its way that arrives well after this returns.
    private func launchWithANotificationComing() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoShort", "-echo.demoNotify", "20"] + XCUIApplication.straightToChat
        app.launch()
        // Right after a new build is installed, the simulator sometimes starts Redde in the
        // background by itself just as the test asks for it, and the test is handed that process,
        // which has none of its flags. The demo conversation says which one this is.
        let demo = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "What's on my calendar tomorrow")).firstMatch
        if !demo.waitForExistence(timeout: 10) {
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(app.navigationBars.buttons["New conversation"].firstMatch.waitForExistence(timeout: 15), "The app didn't come up")
        // The first time, iOS asks whether Redde may send notifications.
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 6) { allow.tap() }
        sleep(1)   // the notification is asked for once the answer is in
        return app
    }

    private func tapTheNotification() {
        // The banner is one element, of a kind that has changed between iOS releases.
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "A notification to tap")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 40), "No notification to tap")
        banner.tap()
    }

    private func expectInFrontToStay(_ app: XCUIApplication) {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "The tap didn't bring Redde to the front")
        // What closed 1.7 came a moment after the tap, so it has to still be there.
        sleep(6)
        XCTAssertEqual(app.state, .runningForeground, "Redde was closed after the tap")
    }

    func testANotificationTappedWhileTheAppIsClosedOpensIt() {
        let app = launchWithANotificationComing()
        app.terminate()
        tapTheNotification()
        expectInFrontToStay(app)
    }

    func testANotificationTappedWhileTheAppIsInTheBackgroundOpensIt() {
        let app = launchWithANotificationComing()
        XCUIDevice.shared.press(.home)
        tapTheNotification()
        expectInFrontToStay(app)
    }
}
