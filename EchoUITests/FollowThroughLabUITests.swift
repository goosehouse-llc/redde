import XCTest

/// Follow-Through on a real Hermes (plugin 1.40.0): the screen reads what the lab's check left
/// being followed (a Paperless water bill, a trip to Lisbon) and shows the five switches and
/// where Paperless was found. Needs the lab up and filled:
/// `scripts/hermes-lab/lab.sh up v0.23.2 push`, then `followthrough_check.py` against it (in the
/// day). Skips when no lab answers on 127.0.0.1:19119, so the normal suite is unaffected.
final class FollowThroughLabUITests: XCTestCase {
    private let dashboard = "http://127.0.0.1:19119"

    private func up() -> Bool {
        var request = URLRequest(url: URL(string: dashboard + "/api/status")!, timeoutInterval: 3)
        request.httpMethod = "GET"
        let done = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = response != nil
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return ok
    }

    private func keep(_ shot: XCUIScreenshot, as name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTheScreenShowsWhatTheLabsHermesFollows() throws {
        continueAfterFailure = true
        try XCTSkipUnless(up(), "No lab on 127.0.0.1:19119 (scripts/hermes-lab/lab.sh up v0.23.2 push, then followthrough_check.py)")
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat
            + ["-echo.screen", "followThrough", "-transport", "hermesServe", "-serveURL", dashboard, "-serveUsername", "lab"]
        app.launchEnvironment["ECHO_TEST_SERVE_PASSWORD"] = "labpass-labpass"
        app.launch()

        let bill = app.staticTexts["City Water bill"]
        XCTAssertTrue(bill.waitForExistence(timeout: 30), "the Paperless bill isn't listed")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "$41.10 · due ")).firstMatch.exists,
                      "the bill's amount and day")
        XCTAssertTrue(app.staticTexts["Trip to Lisbon"].exists, "the trip isn't listed")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "TP202 · ")).firstMatch.exists,
                      "the trip's flight")
        keep(app.screenshot(), as: "follow-through-items")

        for name in ["mail", "orders", "trips", "habits", "outings", "appointments", "arrivals"] {
            let toggle = app.switches["follow-switch-\(name)"]
            for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
            XCTAssertTrue(toggle.exists, "no \(name) switch")
        }
        XCTAssertTrue(app.staticTexts["Usual Buys"].exists && app.staticTexts["Orders, Bills & Renewals"].exists, "the new switches' names")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Paperless is read")).firstMatch.exists,
                      "the Paperless footer")
        keep(app.screenshot(), as: "follow-through-switches")

        // Trips off on the screen is kept by the Hermes: still off when the screen opens again.
        var trips = app.switches["follow-switch-trips"]
        XCTAssertEqual(trips.value as? String, "1")
        trips.switches.firstMatch.tap()
        XCTAssertTrue(trips.waitForValue("0"), "Trips didn't switch off")
        sleep(2)
        app.terminate()
        app.launch()
        trips = app.switches["follow-switch-trips"]
        XCTAssertTrue(app.staticTexts["City Water bill"].waitForExistence(timeout: 30))
        for _ in 0..<4 where !trips.isHittable { app.swipeUp() }
        XCTAssertTrue(trips.waitForValue("0"), "the Hermes didn't keep Trips off")
        trips.switches.firstMatch.tap()
        XCTAssertTrue(trips.waitForValue("1"), "Trips didn't switch back on")
        sleep(2)
    }
}

private extension XCUIElement {
    func waitForValue(_ value: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if self.value as? String == value { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return false
    }
}
