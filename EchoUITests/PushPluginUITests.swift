import XCTest

/// The plugin's line on the notifications screen, on a made-up server (`-echo.demoPlugin`): a
/// Hermes without the plugin gets it installed from the phone, and one that only loads a plugin
/// when it starts is said to need a restart.
@MainActor
final class PushPluginUITests: XCTestCase {
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func open(_ flags: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat + ["-echo.demoPlugin"] + flags + ["-echo.screen", "push"]
        app.launch()
        XCTAssertTrue(app.navigationBars["When Redde is closed"].waitForExistence(timeout: 30), "The notifications screen didn't open")
        return app
    }

    private func text(_ fragment: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    func testAMissingPluginIsInstalledFromThePhone() {
        continueAfterFailure = false
        let app = open(["missing"])
        XCTAssertTrue(text("The plugin isn't on this Hermes yet.", in: app).waitForExistence(timeout: 10))
        let install = app.buttons["Install the Plugin"]
        XCTAssertTrue(install.waitForExistence(timeout: 5), "No way to install it from here")
        shot("plugin missing")
        install.tap()
        // It says what will happen, and does nothing until agreed to.
        XCTAssertTrue(text("github.com/goosehouse-llc/redde", in: app).waitForExistence(timeout: 5), "Installing didn't say where the plugin comes from")
        app.buttons.matching(NSPredicate(format: "label == 'Install the Plugin'")).element(boundBy: app.buttons.matching(NSPredicate(format: "label == 'Install the Plugin'")).count - 1).tap()
        XCTAssertTrue(text("is on this Hermes.", in: app).waitForExistence(timeout: 10), "The plugin isn't shown as installed")
        XCTAssertFalse(install.exists, "The install button is still offered")
        XCTAssertFalse(text("hermes gateway restart", in: app).exists, "A restart was asked for where none is needed")
        shot("plugin installed")
    }

    func testAnOlderHermesIsToldToRestart() {
        continueAfterFailure = false
        let app = open(["old", "restart"])
        XCTAssertTrue(text("this Redde goes with", in: app).waitForExistence(timeout: 10), "An older plugin isn't said to be older")
        let update = app.buttons["Update the Plugin"]
        XCTAssertTrue(update.waitForExistence(timeout: 5))
        update.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Update the Plugin'"))
        XCTAssertTrue(confirm.firstMatch.waitForExistence(timeout: 5))
        confirm.element(boundBy: confirm.count - 1).tap()
        XCTAssertTrue(text("Restart the gateway and the Dashboard", in: app).waitForExistence(timeout: 10), "The restart isn't asked for")
        XCTAssertTrue(text("hermes gateway restart", in: app).exists, "The command isn't shown")
        shot("plugin needs restart")
    }
}
