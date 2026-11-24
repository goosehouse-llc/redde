import XCTest

/// The Home Screen widgets placed for real (asked 2026-11-24, "build them all"): Redde opened with
/// `-echo.demoWidgets`, each widget added through the Home Screen's editor and photographed into
/// SHOT_DIR, and a tick on the Lists widget tried. Run it on a simulator kept for it (the widgets
/// stay on its Home Screen), one on which Redde has been opened a minute before: the widget
/// gallery is slow to find a new app's widgets.
@MainActor
final class HomeWidgetsUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var shots: URL?

    private func hold(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func shot(_ name: String) {
        guard let shots else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appendingPathComponent("\(name).png"))
    }


    /// Adds `widget` in its `size`th size (0 is the smallest) to the Home Screen's first page.
    private func place(_ widget: String, size: Int) {
        XCUIDevice.shared.press(.home)
        hold(1.5)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).press(forDuration: 1.6)
        XCTAssertTrue(springboard.buttons["Edit"].waitForExistence(timeout: 8), "no Edit")
        springboard.buttons["Edit"].tap()
        XCTAssertTrue(springboard.buttons["Add Widget"].waitForExistence(timeout: 8), "no Add Widget")
        springboard.buttons["Add Widget"].tap()
        let search = springboard.searchFields["Search Widgets"]
        XCTAssertTrue(search.waitForExistence(timeout: 8), "no search field")
        search.tap()
        search.typeText("Redde")
        let cell = springboard.cells.containing(NSPredicate(format: "label CONTAINS 'Redde'")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "no Redde in the gallery")
        cell.tap()
        hold(2)
        let name = springboard.staticTexts[widget]
        for _ in 0 ..< 30 where !(name.exists && name.isHittable) { springboard.swipeLeft(); hold(0.8) }
        XCTAssertTrue(name.exists && name.isHittable, "\(widget) isn't in the gallery")
        for _ in 0 ..< size { springboard.swipeLeft(); hold(0.8) }
        shot("gallery-\(widget)-\(size)")
        let add = springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Add Widget'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "no Add Widget button")
        add.tap()
        hold(1.5)
        if springboard.buttons["Done"].waitForExistence(timeout: 5) { springboard.buttons["Done"].tap() }
        hold(4)   // (the widget's first timeline)
    }

    func testPlaceTheWidgets() throws {
        continueAfterFailure = false
        shots = ProcessInfo.processInfo.environment["SHOT_DIR"].map { URL(fileURLWithPath: $0) }
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demoWidgets", ProcessInfo.processInfo.environment["WIDGETS_DAY"] == nil ? "leaving" : "day",
                               "-echo.demoLists", "house"]
        app.launch()
        hold(6)

        // Each new one goes to the top of the first page, so each picture leads with it.
        // WIDGETS_SKIP=n leaves out the first n (already placed by an earlier run).
        let skip = Int(ProcessInfo.processInfo.environment["WIDGETS_SKIP"] ?? "") ?? 0
        for (widget, size) in [("Goals", 1), ("Your Agents", 1), ("Your Day", 2), ("Needs you", 1), ("Lists", 1), ("Up Next", 0), ("Up Next", 2)].dropFirst(skip) {
            place(widget, size: size)
            shot("home-\(widget)-\(size)")
        }

        // A tick on the Lists widget, now on the second page with Up Next's two on the first.
        XCUIDevice.shared.press(.home)
        hold(1.5)
        XCUIDevice.shared.press(.home)   // (a second press goes to the first page)
        hold(1.5)
        springboard.swipeLeft()
        hold(2)
        shot("home-page-2-before-tick")
        let item = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Call the vet'")).firstMatch
        if item.waitForExistence(timeout: 5) {
            item.tap()
            hold(5)
            shot("home-page-2-after-tick")
        } else {
            shot("home-page-2-no-item")
        }

        // The pages after it: Needs You's answers, Goals, Your Agents.
        for page in 3 ... 4 {
            springboard.swipeLeft()
            hold(2)
            shot("home-page-\(page)")
        }
    }
}
