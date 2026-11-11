import XCTest

/// Pinned models (asked 2026-11-07): a long press in the model picker pins one, pinned ones come
/// first, so switching is a tap on the header and one on the pin.
@MainActor
final class PinnedModelsUITests: XCTestCase {
    private func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAPinnedModelIsFirstInThePicker() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.demoModels", "-echo.screen", "model"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Model"].waitForExistence(timeout: 20), "The model picker didn't open")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'qwen36-35b-q4'")).firstMatch
        if app.staticTexts["Pinned"].waitForExistence(timeout: 3) {
            // Left pinned by a run that stopped halfway.
            row.press(forDuration: 1.0)
            app.buttons["Unpin"].tap()
        }
        XCTAssertFalse(app.staticTexts["Pinned"].waitForExistence(timeout: 2), "A Pinned section with nothing pinned")
        for _ in 0 ..< 6 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.exists && row.isHittable, "No demo model")
        row.press(forDuration: 1.0)
        let pin = app.buttons["Pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "A long press didn't offer Pin")
        pin.tap()
        // The Pinned section is at the top, scrolled out of the half-height sheet to reach the
        // model (a swipe down on the sheet closes it), so the row's pin mark says it here; the
        // section itself is checked when the picker opens again below.
        let marked = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Pinned' OR (label CONTAINS 'qwen36-35b-q4' AND label CONTAINS 'Pinned')")).firstMatch
        XCTAssertTrue(marked.waitForExistence(timeout: 5), "The model isn't marked pinned after pinning")
        shot("pinned in the picker", app)

        // (from the full height, one swipe only takes the sheet to half)
        for _ in 0 ..< 3 where app.navigationBars["Model"].exists { app.navigationBars["Model"].swipeDown(velocity: .fast); sleep(1) }
        let header = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Model:'")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 8), "No chat header")
        app.buttons["More"].firstMatch.tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Switch Model'")).firstMatch.waitForExistence(timeout: 2),
                       "Switch Model is still in the … menu (taken out 11-07)")

        // A tap on the header, then on the pinned model at the top: switched. (The first tap may
        // only close the … menu.)
        header.tap()
        if !app.navigationBars["Model"].waitForExistence(timeout: 3) { header.tap() }
        XCTAssertTrue(app.navigationBars["Model"].waitForExistence(timeout: 8), "The header didn't open the picker")
        let pinned = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'qwen36-35b-q4'")).firstMatch
        XCTAssertTrue(pinned.waitForExistence(timeout: 5), "The pinned model isn't at the top")
        XCTAssertTrue(app.staticTexts["Pinned"].exists, "No Pinned section after pinning")
        pinned.tap()
        for _ in 0 ..< 3 where app.navigationBars["Model"].exists { app.navigationBars["Model"].swipeDown(velocity: .fast); sleep(1) }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Model: qwen36-35b-q4'")).firstMatch.waitForExistence(timeout: 8),
                      "The header didn't switch to the pinned model")
        shot("switched", app)

        // Unpinned from the picker again, for the next run.
        header.tap()
        XCTAssertTrue(app.navigationBars["Model"].waitForExistence(timeout: 8))
        let again = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'qwen36-35b-q4'")).firstMatch
        for _ in 0 ..< 6 where !(again.exists && again.isHittable) { app.swipeUp() }
        again.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Unpin"].waitForExistence(timeout: 5), "No Unpin for a pinned model")
        app.buttons["Unpin"].tap()
        XCTAssertFalse(app.staticTexts["Pinned"].waitForExistence(timeout: 2), "Unpinning left the section")
    }

    /// "qwen 3.8 flash" finds Venice's qwen-3-8-flash; its price shows under it, and a long press
    /// holds up its details.
    func testASearchFindsDashedNamesAndShowsPrices() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.demoModels", "-echo.screen", "model", "-echo.modelSearch", "qwen 3.8 flash"]
        app.launch()
        let venice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'qwen-3-8-flash'")).firstMatch
        XCTAssertTrue(venice.waitForExistence(timeout: 20), "The search didn't find Venice's qwen-3-8-flash")
        XCTAssertTrue(venice.label.contains("$0.14 in"), "No price under the model: \(venice.label)")
        shot("search with prices", app)
        venice.press(forDuration: 1.0)
        let cached = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Cached input'")).firstMatch
        XCTAssertTrue(cached.waitForExistence(timeout: 5), "The long press didn't show the model's details")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == '$0.014'")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == '1M tokens'")).firstMatch.exists)
        shot("model details", app)
    }
}
