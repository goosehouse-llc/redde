import XCTest

/// Add → Drawing, with no server: the menu offers it, a stroke drawn with a finger enables Done,
/// and Done leaves the drawing in the strip above the field. (Add → Scan Document needs a real
/// camera: the simulator has none, so the menu leaves it out there.) With `TEST_RUNNER_SHOT_DIR`
/// set, the menu and the canvas are also saved there as pictures.
@MainActor
final class ScanAndDrawUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + XCUIApplication.chatsSection
            + ["-transport", "chatCompletions", "-fastLaneURL", "http://127.0.0.1:9", "-fastLaneModel", "test", "-echo.clearDrafts"]
        app.launch()
        return app
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let keep = XCTAttachment(screenshot: shot)
        keep.name = name
        keep.lifetime = .keepAlways
        add(keep)
        guard let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] else { return }
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: name + ".png"))
    }

    func testADrawingIsAttached() {
        let app = launch()
        let tag = ProcessInfo.processInfo.environment["SHOT_TAG"] ?? "light"
        let add = app.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 20), "No Add button")
        add.tap()
        let drawing = app.buttons["Drawing"]
        XCTAssertTrue(drawing.waitForExistence(timeout: 5), "No Drawing in the Add menu")
        save("add-menu-\(tag)")
        drawing.tap()

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "The drawing didn't open")
        XCTAssertFalse(done.isEnabled, "Done before anything was drawn")
        let window = app.windows.firstMatch
        let strokes: [((CGFloat, CGFloat), (CGFloat, CGFloat))] = [((0.25, 0.30), (0.75, 0.32)), ((0.30, 0.45), (0.70, 0.55)),
                                                                   ((0.50, 0.25), (0.48, 0.60))]
        for (from, to) in strokes {
            window.coordinate(withNormalizedOffset: CGVector(dx: from.0, dy: from.1))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: to.0, dy: to.1)))
        }
        XCTAssertTrue(done.isEnabled, "Done stayed off after drawing")
        save("drawing-canvas-\(tag)")
        done.tap()

        let tile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove Drawing")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "No drawing in the strip")
        save("drawing-attached-\(tag)")
    }
}
