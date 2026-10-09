import Foundation
import Testing
@testable import Echo

/// The notification plugin seen and installed through a Hermes's Dashboard: what its plugin list
/// and its install answer mean (the shapes are what Hermes 0.21.0, 0.21.3 and 0.21.5 sent the
/// lab), and the notifications screen's line about it. `scripts/hermes-lab/lab.sh plugin` runs
/// the install for real.
@Suite(.serialized)
struct PushPluginTests {
    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    @Test func thePluginListSaysWhetherItIsThere() throws {
        let hub = try json(#"""
        {"plugins": [
          {"name": "kanban", "version": "0.3.0", "source": "bundled", "runtime_status": "enabled"},
          {"name": "redde-push", "version": "1.0.0", "description": "Notifications", "source": "user", "runtime_status": "enabled",
           "has_dashboard_manifest": false, "can_remove": true, "can_update_git": false, "user_hidden": false}
        ], "orphan_dashboard_plugins": [], "providers": {}}
        """#)
        let state = PushPlugin.State(hub: hub)
        #expect(state == PushPlugin.State(installed: true, version: "1.0.0", enabled: true))
        #expect(state.isOutdated == PushPlugin.isOlder("1.0.0", than: PushPlugin.version))

        #expect(PushPlugin.State(hub: try json(#"{"plugins": [{"name": "kanban", "runtime_status": "enabled"}]}"#)) == PushPlugin.State())
        #expect(PushPlugin.State(hub: try json(#"{"plugins": [{"name": "redde-push", "version": "", "runtime_status": "disabled"}]}"#))
            == PushPlugin.State(installed: true, version: nil, enabled: false))
        #expect(PushPlugin.State(hub: .null) == PushPlugin.State(), "an answer that isn't a list says nothing is there")
        #expect(!PushPlugin.State().isOutdated && !PushPlugin.State(installed: true, version: nil, enabled: true).isOutdated)
    }

    @Test func anInstallIsRunningOnlyWhereHermesLoadedItThere() throws {
        // Hermes 0.21.5 loads the plugin into the running gateway and says what went live.
        let live = try json(#"""
        {"ok": true, "plugin_name": "redde-push", "warnings": ["Custom (unreviewed) source — not from the Hermes catalog."], "python_dependencies": [],
         "missing_env": [], "enabled": true, "gateway_reloaded": true, "restart_required": false,
         "activation": {"name": "redde-push", "key": "redde-push",
                        "activated_now": {"gateway_commands": ["redde-push"], "hooks": ["on_session_start", "post_llm_call"]}, "deferred": {}}}
        """#)
        #expect(PushPlugin.Outcome(answer: live) == .running)
        // 0.21.0 and 0.21.3 put it on disk and switch it on; nothing runs until Hermes restarts.
        #expect(PushPlugin.Outcome(answer: try json(#"{"ok": true, "plugin_name": "redde-push", "warnings": [], "missing_env": [], "enabled": true}"#)) == .needsRestart)
        // Loaded, but Hermes wants a restart all the same; or loaded without its command.
        #expect(PushPlugin.Outcome(answer: try json(#"{"ok": true, "restart_required": true, "activation": {"activated_now": {"gateway_commands": ["redde-push"]}}}"#)) == .needsRestart)
        #expect(PushPlugin.Outcome(answer: try json(#"{"ok": true, "restart_required": false, "activation": {"activated_now": {"hooks": ["post_llm_call"]}}}"#)) == .needsRestart)
        #expect(PushPlugin.Outcome(answer: .null) == .needsRestart)
    }

    @Test func versionsAreComparedByTheirNumbers() {
        #expect(PushPlugin.isOlder("1.0.2", than: "1.1.0"))
        #expect(PushPlugin.isOlder("1.9.0", than: "1.10.0"), "by number, not by letter")
        #expect(PushPlugin.isOlder("1", than: "1.0.1"))
        #expect(!PushPlugin.isOlder("1.1.0", than: "1.1.0") && !PushPlugin.isOlder("1.1", than: "1.1.0") && !PushPlugin.isOlder("2.0.0", than: "1.9.9"))
        #expect(!PushPlugin.isOlder("dev", than: "1.1.0") && !PushPlugin.isOlder("", than: "1.1.0"), "what can't be read isn't called old")
    }

    @Test func theAppKnowsThePluginVersionItShipsWith() throws {
        // The constant is what tells an older plugin from the current one: it has to be the
        // version in the plugin's own manifest. (The simulator reads the source tree.)
        #expect(PushSettingsView.installCommand.contains(PushPlugin.identifier), "the terminal's command installs the same thing")
        #if targetEnvironment(simulator)   // a device has no source tree to read
        let manifest = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "companion/hermes-plugin/redde-push/plugin.yaml")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("version:") })
        #expect(line.dropFirst("version:".count).trimmingCharacters(in: .whitespaces) == PushPlugin.version)
        #expect(text.contains("name: \(PushPlugin.name)"))
        #endif
    }

    @Test func refusalsAreSaidInTheScreensWords() {
        #expect(PushPlugin.explain(TransportError.http(status: 400, body: "Git clone timed out after 60 seconds.")).contains("try again"))
        #expect(PushPlugin.explain(TransportError.http(status: 400, body: "Plugin scan blocked: dangerous pattern")) == "Plugin scan blocked: dangerous pattern")
        #expect(PushPlugin.explain(TransportError.http(status: 401, body: "Unauthorized")) == "The Hermes Dashboard login was refused.")
        #expect(PushPlugin.explain(TransportError.http(status: 500, body: "")) == "The server answered 500.")
    }

    // MARK: The requests

    @Test func theDashboardIsAskedAsItsOwnPluginsPageAsks() async throws {
        ServeStub.reset()
        defer { ServeStub.reset() }
        nonisolated(unsafe) var bodies: [String] = []
        ServeStub.handler = { request, body in
            switch (request.httpMethod, request.url?.path()) {
            case ("POST", "/auth/password-login"): return (200, Data("{}".utf8))
            case ("GET", "/api/dashboard/plugins/hub"):
                return (200, Data(#"{"plugins":[{"name":"redde-push","version":"1.1.0","runtime_status":"enabled"}]}"#.utf8))
            case ("POST", "/api/dashboard/agent-plugins/install"):
                bodies.append(String(decoding: body ?? Data(), as: UTF8.self))
                return bodies.count == 1 ? (400, Data(#"{"detail":"Git clone timed out after 60 seconds."}"#.utf8))
                    : (200, Data(#"{"ok":true,"plugin_name":"redde-push","enabled":true}"#.utf8))
            default: return (404, Data())
            }
        }
        let settings = Settings(defaults: UserDefaults(suiteName: "plugin-\(UUID().uuidString)")!)
        settings.serveURL = "http://serve.test:9119"
        settings.serveUsername = "redde"
        let client = HermesServeClient(settings: settings, password: { "hunter2" }, tokens: HermesServeClientTests.TokenBox().store, protocolClasses: [ServeStub.self])

        #expect(try await client.pushPlugin() == PushPlugin.State(installed: true, version: "1.1.0", enabled: true))
        let slow = await #expect(throws: TransportError.self) { _ = try await client.installPushPlugin(replacing: false) }
        #expect(slow.map(PushPlugin.explain)?.contains("try again") == true)
        #expect(try await client.installPushPlugin(replacing: true) == .needsRestart)
        #expect(try json(bodies[0]) == .object(["identifier": .string("goosehouse-llc/redde/companion/hermes-plugin/redde-push"), "force": .bool(false), "enable": .bool(true)]))
        #expect(try json(bodies[1])["force"]?.bool == true)
    }

    // MARK: The screen's line

    private final class Server: PushPluginManaging {
        var state = PushPlugin.State()
        var outcome = PushPlugin.Outcome.running
        var failure: Error?
        var listFails = false
        var installs: [Bool] = []
        func pushPlugin() async throws -> PushPlugin.State {
            if listFails { throw TransportError.http(status: 401, body: "Unauthorized") }
            return state
        }
        func installPushPlugin(replacing: Bool) async throws -> PushPlugin.Outcome {
            installs.append(replacing)
            if let failure { throw failure }
            state = PushPlugin.State(installed: true, version: PushPlugin.version, enabled: true)
            return outcome
        }
    }

    @Test func aMissingPluginIsInstalledAndAnOldOneReplaced() async {
        let server = Server()
        let model = PushPluginModel(manager: server)
        #expect(model.phase == .checking && !model.offersInstall)
        await model.refresh()
        #expect(model.state == PushPlugin.State() && model.offersInstall && model.installTitle == "Install the Plugin")
        #expect(PushSettingsView.pluginLine(PushPlugin.State(), restart: false) == "The plugin isn't on this Hermes yet.")

        await model.install()
        #expect(server.installs == [false], "nothing there to replace")
        #expect(model.outcome == .running && !model.offersInstall && !model.installing && model.problem == nil)
        #expect(PushSettingsView.pluginLine(model.state ?? .init(), restart: false) == "The plugin \(PushPlugin.version) is on this Hermes.")

        // An older one: the same button, as an update.
        server.state = PushPlugin.State(installed: true, version: "0.9.0", enabled: true)
        server.outcome = .needsRestart
        await model.refresh()
        #expect(model.offersInstall && model.installTitle == "Update the Plugin")
        #expect(PushSettingsView.pluginLine(server.state, restart: false).contains("goes with \(PushPlugin.version)"))
        await model.install()
        #expect(server.installs == [false, true])
        #expect(model.outcome == .needsRestart)
        #expect(PushSettingsView.pluginLine(model.state ?? .init(), restart: true) == "The plugin \(PushPlugin.version) is installed.")

        // Switched off: on again.
        server.state = PushPlugin.State(installed: true, version: PushPlugin.version, enabled: false)
        await model.refresh()
        #expect(model.offersInstall && model.installTitle == "Turn the Plugin On")
        #expect(PushSettingsView.pluginLine(server.state, restart: false).contains("switched off"))
    }

    @Test func anInstallThatFailsSaysWhyAndCanBeTriedAgain() async {
        let server = Server()
        server.failure = TransportError.http(status: 400, body: "Git clone timed out after 60 seconds.")
        let model = PushPluginModel(manager: server)
        await model.refresh()
        await model.install()
        #expect(model.problem?.contains("try again") == true && model.outcome == nil && model.offersInstall && !model.installing)
        server.failure = nil
        await model.install()
        #expect(model.problem == nil && model.outcome == .running)
    }

    @Test func aDashboardThatCannotBeAskedLeavesTheTerminalsWay() async {
        let server = Server()
        server.listFails = true
        let model = PushPluginModel(manager: server)
        await model.refresh()
        #expect(model.phase == .unknown("The Hermes Dashboard login was refused.") && !model.offersInstall)
        // Known once, a failed look later doesn't forget it.
        server.listFails = false
        await model.refresh()
        server.listFails = true
        await model.refresh()
        #expect(model.state == PushPlugin.State())
    }
}
