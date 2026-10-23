import XCTest

/// A reply's cards (`redde_show`): a walk on a map with its directions, a list of places, the
/// weather now, by the hour and by the day. `-echo.demoCards` supplies the reply.
@MainActor
final class ReplyCardsUITests: XCTestCase {
    func testAReplyShowsAMapPlacesAndTheWeather() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoCards"] + XCUIApplication.chatsSection + XCUIApplication.straightToChat
        app.launch()
        XCTAssertTrue(app.text(containing: "twelve-minute walk").waitForExistence(timeout: 20), "The demo reply didn't appear")
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

        // The places, each with its rating and a way to open it in Maps.
        for _ in 0 ..< 4 where !app.text(containing: "Alfama Bean").isHittable { window.swipeUp() }
        XCTAssertTrue(app.text(containing: "Coffee near the office").exists, "The places card's title isn't there")
        XCTAssertTrue(app.text(containing: "★ 4.7").exists, "A place's rating isn't shown")
        XCTAssertTrue(app.text(containing: "★ 4.6").exists, "A rating given as text isn't read")
        XCTAssertTrue(app.buttons["Open Alfama Bean in Maps"].exists, "A place can't be opened in Maps")
        XCTAssertTrue(app.links["Call Rossio Roasters"].exists || app.buttons["Call Rossio Roasters"].exists, "A place with a phone can't be called")

        // The weather: now, the hours, the days.
        for _ in 0 ..< 4 where !app.text(containing: "Feels like").isHittable { window.swipeUp() }
        XCTAssertTrue(app.text(containing: "Lisbon").exists, "The weather's place isn't there")
        XCTAssertTrue(app.text(containing: "Humidity 62%").exists, "Today's details aren't shown")
        XCTAssertTrue(app.text(containing: "70%").exists, "The chance of rain isn't shown")
        let weather = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        weather.name = "cards-weather"
        weather.lifetime = .keepAlways
        add(weather)
    }
}
