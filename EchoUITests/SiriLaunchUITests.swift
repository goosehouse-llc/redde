import XCTest

/// Simulator-only: feeds Siri a recognized phrase and checks that the App Shortcut resolves to
/// Redde and lands in voice mode.
///
/// Opt-in via `ECHO_SIRI_UITEST=1` in the scheme environment. On Xcode 26.3 / iOS 26.2 simulators
/// Siri answers every phrase with "I didn't get that", so these can only pass on a simulator
/// whose Siri actually works. Real verification happens on the phone.
@MainActor
final class SiriLaunchUITests: XCTestCase {
    private static let bundleID = "com.goosehouse.echo"

    // The override is nonisolated by signature; XCTest runs it on the main thread for UI tests.
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ECHO_SIRI_UITEST"] == "1",
                          "Simulator Siri can't recognize phrases; set ECHO_SIRI_UITEST=1 to run anyway.")
        continueAfterFailure = false
        MainActor.assumeIsolated {
            let app = XCUIApplication(bundleIdentifier: Self.bundleID)
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            // updateAppShortcutParameters() registers the phrases shortly after launch; spin the
            // run loop rather than blocking the thread.
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            XCUIDevice.shared.press(.home)
        }
    }

    func testHeyPhraseOpensListening() { assertSiri(phrase: "Hey Redde") }
    func testAskPhraseOpensListening() { assertSiri(phrase: "Ask Redde") }
    func testHermesAlternateNameOpensListening() { assertSiri(phrase: "Ask Hermes") }

    private func assertSiri(phrase: String) {
        let siri = XCUIDevice.shared.siriService
        siri.activate(voiceRecognitionText: phrase)
        let app = XCUIApplication(bundleIdentifier: Self.bundleID)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "Siri did not open Redde for “\(phrase)”")
        XCTAssertTrue(app.staticTexts["Listening"].waitForExistence(timeout: 10)
                      || app.staticTexts["Something went wrong"].waitForExistence(timeout: 2),
                      "Redde opened but not into voice mode for “\(phrase)”")
    }
}
