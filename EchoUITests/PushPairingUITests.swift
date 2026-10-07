import XCTest

/// Notifications from a paired Hermes. The first two tests need nothing but the app: a pairing
/// link is confirmed before anything is sent, and Settings says how to pair. The third runs only
/// from the lab (`scripts/hermes-lab/lab.sh push --app`), which hands it a pairing link from an
/// unmodified Hermes: the app pairs through the lab's relay, and the notification for that
/// Hermes's next reply arrives sealed and is shown with the reply's text.
///
/// The simulator gets these as simulated pushes, which skip the notification extension; the app,
/// in front, opens them itself (`Notifier.presentUnopened`). The extension opening one while the
/// app is closed takes a real push from Apple and a phone.
@MainActor
final class PushPairingUITests: XCTestCase {
    /// A well-formed code nobody is waiting on.
    private let link = "redde://connect?push=j0DFrbaPJWJK5bIU6nZ6bslNgp09e14a0bpvPiE4KF8"
    private let base = ["-echo.demo", "-echo.demoShort"] + XCUIApplication.straightToChat
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        // Port 9: nothing listens, so a test that should send nothing can't reach a relay anyway.
        app.launchArguments = base + (extra.contains("-push.relay") ? [] : ["-push.relay", "http://127.0.0.1:9"]) + extra
        app.launch()
        return app
    }

    /// A screenshot kept with the result when the test passes too: it is the lab's evidence.
    private func keep(_ screenshot: XCUIScreenshot, as name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAPairingLinkAsksBeforeAnythingIsSent() {
        continueAfterFailure = false
        let app = launch([])
        XCTAssertTrue(app.navigationBars.buttons["New conversation"].firstMatch.waitForExistence(timeout: 15), "The app didn't come up")
        XCUIDevice.shared.system.open(URL(string: link)!)
        let bar = app.navigationBars["Pair with your Hermes"]
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "No confirmation for the pairing link")
        XCTAssertTrue(app.text(containing: "Get notifications from this Hermes?").exists)
        XCTAssertTrue(app.text(containing: "the relay that carries them can't read them").exists)
        XCTAssertTrue(app.buttons["Pair"].exists)
        XCTAssertFalse(app.navigationBars["Setup code"].exists, "A pairing link was taken for a setup code")
        bar.buttons["Cancel"].tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
    }

    func testSettingsSayHowToPairAndListNoPairingAtFirst() throws {
        continueAfterFailure = false
        let app = launch(["-echo.screen", "push"])
        XCTAssertTrue(app.navigationBars["When Redde is closed"].waitForExistence(timeout: 15), "The pairing screen didn't open")
        try XCTSkipIf(app.text(containing: "Paired ").exists, "This simulator is paired with a Hermes already")
        XCTAssertTrue(app.text(containing: "Not paired with a Hermes yet.").exists)
        XCTAssertTrue(app.text(containing: "hermes plugins install goosehouse-llc/redde/companion/hermes-plugin/redde-push").exists)
        // Signed in to a Dashboard, the app offers to pair in one tap and folds the code away.
        let byCode = app.buttons["Pair with a code instead"]
        if byCode.exists { byCode.tap() }
        XCTAssertTrue(app.text(containing: "hermes redde-push pair").exists)
        XCTAssertTrue(app.buttons["Paste the pairing link"].exists)
        XCTAssertTrue(app.text(containing: "neither can read it").exists, "The footer says who can read a notification")
    }

    func testPairingWithTheLabsHermesThenANotification() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let link = environment["PUSH_LINK"], !link.isEmpty else {
            throw XCTSkip("Runs from scripts/hermes-lab/lab.sh push --app, which supplies a pairing link")
        }
        let relay = environment["PUSH_RELAY"] ?? "http://127.0.0.1:18980"

        let app = launch(["-push.relay", relay, "-echo.pushLink", link])
        let bar = app.navigationBars["Pair with your Hermes"]
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "No confirmation for the lab's pairing link")
        app.buttons["Pair"].tap()
        // The first time, iOS asks whether Redde may send notifications.
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 6) { allow.tap() }
        // Both ends hold the same key once the plugin's first note has opened here.
        XCTAssertTrue(app.text(containing: "Paired with").waitForExistence(timeout: 60),
                      "The lab's Hermes never confirmed: " + (app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")))
        keep(XCUIScreen.main.screenshot(), as: "paired")
        app.buttons["Done"].tap()

        // The lab now has its Hermes reply (the stub model answers "[A:alpha]"): the plugin's note
        // has to arrive and show what the reply says, not the relay's words.
        let banner = springboard.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "[A:alpha]")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 90), "No notification with the reply's text")
        XCTAssertFalse(springboard.text(containing: "Open Redde to see what's new").exists, "The relay's words show: the note wasn't opened")
        keep(XCUIScreen.main.screenshot(), as: "notified")

        // Leave the simulator as it was: remove the pairing (which also removes it at the relay).
        let again = launch(["-push.relay", relay, "-echo.screen", "push"])
        XCTAssertTrue(again.navigationBars["When Redde is closed"].waitForExistence(timeout: 20))
        let row = again.text(containing: "Paired ")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The pairing isn't listed")
        row.swipeLeft()
        again.buttons["Remove"].tap()
        XCTAssertTrue(again.text(containing: "Not paired with a Hermes yet.").waitForExistence(timeout: 10))
    }
}
