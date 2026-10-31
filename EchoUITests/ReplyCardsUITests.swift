import XCTest

/// A reply's cards (`redde_show`): a walk on a map with its directions, a list of places, the
/// weather now, by the hour and by the day, and the time in Tokyo. `-echo.demoCards` supplies the replies.
@MainActor
final class ReplyCardsUITests: XCTestCase {
    func testAReplyShowsAMapPlacesAndTheWeather() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Without -setupDone YES, which keeps demo flags from working (UAT 2.3.1): as the newer card
        // tests launch, the setup a simulator never had skipped over the demo.
        app.launchArguments = ["-echo.demoCards", "-openToVoiceScreen", "NO", "-listenOnOpen", "NO", "-requireBiometrics", "NO"]
        app.launch()
        if app.buttons["Skip"].waitForExistence(timeout: 4) { app.buttons["Skip"].tap() }
        XCTAssertTrue(app.text(containing: "Rossio Roasters is the pick").waitForExistence(timeout: 20), "The demo reply didn't appear")
        // (Its words and the cards as drawn since the places and weather cards' new look, 2026-10-30.)
        let any = { (fragment: String) in app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch }
        XCTAssertFalse(app.text(containing: "\"cards\"").exists, "The card call shows as text")

        // The map: the walk, with a way to get directions.
        let window = app.windows.firstMatch
        for _ in 0 ..< 4 where !app.buttons["Directions"].isHittable { window.swipeDown() }
        XCTAssertTrue(app.text(containing: "To Rossio Roasters").exists, "The map's title isn't there")
        XCTAssertTrue(app.buttons["Directions"].exists, "The map has no Directions")
        XCTAssertTrue(app.text(containing: "Walk").exists, "The map doesn't say how")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "cards-map"
        shot.lifetime = .keepAlways
        add(shot)

        // The places, each with its rating, each opening in Maps, and Directions to the pick.
        for _ in 0 ..< 4 where !any("Alfama Bean").isHittable { window.swipeUp() }
        XCTAssertTrue(app.text(containing: "Coffee near the office").exists, "The places card's title isn't there")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "rated 4.7")).firstMatch.exists
                      || any("rated 4.7").exists, "A place's rating isn't shown")
        XCTAssertTrue(any("rated 4.8").exists, "A rating given as text isn't read")
        XCTAssertTrue(app.buttons["Directions to Rossio Roasters"].exists, "No Directions to the pick")
        XCTAssertTrue(app.buttons["Maps"].exists, "The places can't be opened in Maps")

        // The weather: now, the hours, the days.
        for _ in 0 ..< 4 where !any("Lisbon · Now").isHittable { window.swipeUp() }
        XCTAssertTrue(any("Lisbon · Now").exists, "The weather's place isn't there")
        XCTAssertTrue(any("Partly cloudy · H 21°").exists, "Today's reading isn't shown")
        XCTAssertTrue(any("Rain 80%").exists, "The chance of rain isn't shown")
        let weather = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        weather.name = "cards-weather"
        weather.lifetime = .keepAlways
        add(weather)

        // The time in Tokyo, running, and how far it is from here.
        for _ in 0 ..< 4 where !app.text(containing: "Tokyo's time").isHittable { window.swipeUp() }
        XCTAssertTrue(app.text(containing: "Tokyo").exists, "The time card's place isn't there")
        XCTAssertTrue(app.text(containing: "hr ahead").exists || app.text(containing: "hr behind").exists
                      || app.text(containing: "Same time").exists, "The time card doesn't say how far it is from here")
        let time = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        time.name = "cards-time"
        time.lifetime = .keepAlways
        add(time)
    }
}
