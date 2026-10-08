import Foundation
import Testing
@testable import Echo

/// The Gateway screen: reading what the Dashboard's administration routes answer (the shapes are
/// what Hermes 0.21.0 and 0.21.5 sent the lab), and following a restart or an update to its end.
struct GatewayAdminTests {
    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    @Test func theStatusSaysWhatRunsAndWhatItIsConnectedTo() throws {
        // Hermes 0.21.5, with one platform in trouble.
        let status = GatewayStatus(try json(#"""
        {"version": "0.21.5", "release_date": "2026.9.24", "can_update_hermes": true, "gateway_running": true, "gateway_state": "running",
         "gateway_platforms": {
           "telegram": {"state": "retrying", "error_code": "network", "error_message": "Connection reset", "needs_attention": true},
           "api_server": {"state": "connected", "error_code": null, "error_message": null, "listener_base": "http://127.0.0.1:8642"}},
         "gateway_exit_reason": null, "active_agents": 2, "active_sessions": 3,
         "components": {"gateway": {"status": "ok", "state": "running"}, "dashboard": {"status": "ok"}, "storage": {"status": "ok"},
                        "platforms": {"status": "degraded", "configured": 2, "connected": 1}},
         "overall": "degraded", "profiles": ["default"]}
        """#))
        #expect(status.version == "0.21.5")
        #expect(status.gatewayRunning)
        #expect(status.gatewayLabel == "Running")
        #expect(status.activeTurns == 2)
        #expect(status.platforms.map(\.title) == ["Hermes API", "Telegram"])
        #expect(status.platforms.map(\.isConnected) == [true, false])
        #expect(status.platforms.last?.error == "Connection reset")
        #expect(status.troubles == [.init(id: "platforms", status: "degraded")])
        #expect(status.canUpdate)
    }

    @Test func aStoppedGatewaySaysSoInHermessWords() throws {
        // Hermes 0.21.0 sends fewer fields; none of the missing ones is needed.
        let status = GatewayStatus(try json(#"""
        {"version": "0.21.0", "release_date": "2026.8.31", "gateway_running": false, "gateway_state": "startup_failed",
         "gateway_platforms": {}, "gateway_exit_reason": "port 8642 is in use", "active_agents": 0, "can_update_hermes": false,
         "components": {"gateway": {"status": "down", "state": "startup_failed"}}}
        """#))
        #expect(!status.gatewayRunning)
        #expect(status.gatewayLabel == "Startup Failed")
        #expect(status.exitReason == "port 8642 is in use")
        #expect(status.platforms.isEmpty)
        #expect(status.troubles.map(\.id) == ["gateway"])
        #expect(!status.canUpdate)
        // Nothing at all still reads, as stopped.
        #expect(GatewayStatus(.null).gatewayLabel == "Stopped")
    }

    @Test func theHostIsNamedWithHowLongItHasBeenUp() throws {
        let host = HostStats(try json(#"""
        {"os": "Darwin", "os_release": "27.0.0", "arch": "arm64", "hostname": "homelab", "hermes_version": "0.21.5", "cpu_count": 10,
         "memory": {"total": 68719476736, "percent": 73.2}, "disk": {"total": 994662584320, "percent": 89.7},
         "cpu_percent": 46.1, "uptime_seconds": 660322, "psutil": true}
        """#))
        #expect(host.hostname == "homelab")
        #expect(host.system == "macOS · arm64")
        #expect(host.uptimeLabel == "7 days, 15 hours")
        #expect(host.memoryPercent == 73.2)
        #expect(GatewayView.percent(89.7) == "90%")
        // Without psutil Hermes says less.
        let bare = HostStats(try json(#"{"os": "Linux", "arch": "x86_64", "hostname": "box", "psutil": false}"#))
        #expect(bare.system == "Linux · x86_64")
        #expect(bare.uptimeLabel == nil)
        #expect(bare.memoryPercent == nil)
    }

    @Test func anMCPServerIsItsNameWhereItIsAndWhetherItIsOn() throws {
        let listed = (try json(#"""
        {"servers": [
          {"name": "home", "transport": "http", "url": "http://ha.local:8123/mcp", "command": null, "args": [], "env": {}, "auth": "header", "enabled": true, "tools": null},
          {"name": "notes", "transport": "stdio", "url": null, "command": "uvx", "args": ["basic-memory", "mcp"], "env": {"KEY": "***"}, "auth": null, "enabled": false, "tools": ["search"]},
          {"name": "from-plugin", "transport": "stdio", "command": "x", "args": [], "enabled": true, "source": "plugin", "plugin": "acme"},
          {"transport": "stdio"}]}
        """#))["servers"]?.array ?? []
        let servers = listed.compactMap(MCPServer.init)
        #expect(servers.map(\.name) == ["home", "notes", "from-plugin"], "an entry without a name is no server")
        #expect(servers[0].target == "http://ha.local:8123/mcp")
        #expect(servers[1].target == "uvx basic-memory mcp")
        #expect(servers.map(\.enabled) == [true, false, true])
        #expect(servers[2].plugin == "acme")
        #expect(servers[0].plugin == nil)
    }

    @Test func aTestSaysHowManyToolsOrWhyNot() throws {
        let good = MCPProbe(try json(#"{"ok": true, "tools": [{"name": "search", "description": "…"}, {"name": "read", "description": "…", "schema_chars": 412}]}"#))
        #expect(good.ok && good.tools == ["search", "read"])
        #expect(good.summary == "Connected · 2 tools")
        #expect(MCPProbe(try json(#"{"ok": true, "tools": [{"name": "one"}]}"#)).summary == "Connected · 1 tool")
        let bad = MCPProbe(try json(#"{"ok": false, "error": "Connection refused", "tools": []}"#))
        #expect(!bad.ok && bad.summary == "Connection refused")
    }

    @Test func anActionIsRunningOrOverWithWhatItPrinted() throws {
        let running = GatewayAction(try json(#"{"name": "gateway-restart", "running": true, "exit_code": null, "pid": 4012, "lines": ["Stopping…\n", "\u001b[32m✓ stopped\u001b[0m\n", "\n"]}"#))
        #expect(running.running && running.exitCode == nil)
        #expect(running.lines == ["Stopping…", "✓ stopped"], "without line breaks, colour codes or empty lines")
        let done = GatewayAction(try json(#"{"name": "gateway-restart", "running": false, "exit_code": 0, "pid": 4012, "lines": []}"#))
        #expect(!done.running && done.exitCode == 0)
        // Before anything was ever started, and after Hermes forgot: not running, no exit code.
        #expect(GatewayAction(try json(#"{"name": "hermes-update", "running": false, "exit_code": null, "pid": null, "lines": []}"#)).exitCode == nil)
    }

    @Test func anUpdateCheckSaysHowFarBehind() throws {
        let behind = HermesUpdate(try json(#"""
        {"install_method": "git", "current_version": "0.21.5", "behind": 12, "update_available": true, "can_apply": true,
         "update_command": "hermes update", "message": null, "commits": [{"sha": "517b5e1", "summary": "fix", "author": "a", "at": 1791481771}]}
        """#))
        #expect(behind.available && behind.canApply)
        #expect(behind.summary == "12 changes behind")
        // 0.21.0 when it can't reach the source: no count, and its own words.
        let unknown = HermesUpdate(try json(#"{"install_method": "git", "current_version": "0.21.0", "behind": null, "update_available": false, "can_apply": true, "update_command": "hermes update", "message": "Couldn't reach the update source — try again later."}"#))
        #expect(!unknown.available)
        #expect(unknown.summary == "Couldn't reach the update source — try again later.")
        let current = HermesUpdate(try json(#"{"current_version": "0.21.5", "behind": 0, "update_available": false, "can_apply": true, "update_command": "hermes update", "message": null}"#))
        #expect(current.summary == "Up to date")
        let docker = HermesUpdate(try json(#"{"install_method": "docker", "current_version": "0.21.5", "behind": 3, "update_available": true, "can_apply": false, "update_command": "docker pull nousresearch/hermes", "message": "Updated by pulling the image."}"#))
        #expect(docker.available && !docker.canApply && docker.command == "docker pull nousresearch/hermes")
    }

    @Test func logLinesAreTidiedAndKnowTheirLevel() {
        #expect(GatewayLog.tidy("2026-10-08 14:23:47,552 INFO gateway.run: up\n") == "2026-10-08 14:23:47,552 INFO gateway.run: up")
        #expect(GatewayLog.tidy("\u{1B}[31mfailed\u{1B}[0m\n") == "failed")
        #expect(GatewayLog.level(of: "2026-10-08 14:23:47,552 INFO gateway.run: an ERROR word later in the line that is long enough") == .all)
        #expect(GatewayLog.level(of: "2026-10-08 14:23:47,552 WARNING tools.mcp_tool: slow") == .warning)
        #expect(GatewayLog.level(of: "2026-10-08 14:23:47,552 ERROR plugins.platforms.discord: closed") == .error)
        #expect(GatewayLog.level(of: "Traceback (most recent call last):") == .error)
    }

    @Test func theWarningsSayWhatWillStop() {
        #expect(GatewayView.restartWarning(turns: 0).hasPrefix("Replies in progress"))
        #expect(GatewayView.restartWarning(turns: 1).hasPrefix("1 turn is running now."))
        #expect(GatewayView.restartWarning(turns: 3).hasPrefix("3 turns are running now."))
        var update = HermesUpdate()
        update.behind = 12
        var host = HostStats()
        host.hostname = "homelab"
        let warning = GatewayView.updateWarning(update, host: host)
        #expect(warning.hasPrefix("This runs hermes update on homelab, 12 changes, and restarts Hermes."))
        #expect(warning.contains("changes made by hand"))
        #expect(GatewayView.updateWarning(nil, host: nil).hasPrefix("This runs hermes update and restarts Hermes."))
    }

    // MARK: The model

    /// A server that does what a test tells it.
    final class Scripted: GatewayAdministering {
        var version = "0.21.5"
        var running = true
        var startedAt: String? = "boot-1"
        /// What the gateway is after the restart has been asked for and `downFor` looks at it.
        var startedAtAfterRestart: String?
        var downFor = 0
        var servers = [MCPServer(name: "home", enabled: true), MCPServer(name: "notes", enabled: false)]
        var refuseSwitch: String?
        /// What each ask about an action answers, in order; nil is a server that doesn't answer.
        var actionAnswers: [GatewayAction?] = []
        var versionAfterAction: String?
        var refuseUpdate: String?
        var calls: [String] = []

        func gatewayStatus() async throws -> GatewayStatus {
            calls.append("status")
            var status = GatewayStatus()
            status.version = version
            status.startedAt = startedAt
            if calls.contains("restart"), downFor > 0 {
                downFor -= 1
                status.gatewayRunning = false
                status.gatewayState = "stopped"
                return status
            }
            if calls.contains("restart"), let startedAtAfterRestart { status.startedAt = startedAtAfterRestart }
            status.gatewayRunning = running
            status.gatewayState = running ? "running" : "stopped"
            return status
        }
        func hostStats() async throws -> HostStats { HostStats() }
        func mcpServers() async throws -> [MCPServer] { servers }
        func setMCPServer(_ name: String, enabled: Bool) async throws {
            calls.append("set \(name) \(enabled)")
            if let refuseSwitch { throw GatewayRefusal(message: refuseSwitch) }
            if let i = servers.firstIndex(where: { $0.name == name }) { servers[i].enabled = enabled }
        }
        func testMCPServer(_ name: String) async throws -> MCPProbe {
            if name == "notes" { throw TransportError.http(status: 500, body: "boom") }
            return MCPProbe(ok: true, tools: ["a", "b"])
        }
        func gatewayLogs(_ file: GatewayLog, lines: Int, level: GatewayLog.Level, search: String) async throws -> [String] { [] }
        func restartGateway() async throws -> String { calls.append("restart"); return GatewayAction.restart }
        func gatewayAction(_ name: String) async throws -> GatewayAction {
            calls.append("action \(name)")
            guard !actionAnswers.isEmpty else { return GatewayAction(running: false, exitCode: 0) }
            let next = actionAnswers.removeFirst()
            if actionAnswers.isEmpty, let versionAfterAction { version = versionAfterAction }
            guard let next else { throw TransportError.http(status: 502, body: "restarting") }
            return next
        }
        func hermesUpdate() async throws -> HermesUpdate {
            var update = HermesUpdate()
            update.currentVersion = version
            return update
        }
        func updateHermes() async throws -> String {
            calls.append("update")
            if let refuseUpdate { throw GatewayRefusal(message: refuseUpdate) }
            return GatewayAction.update
        }
    }

    private func model(_ source: Scripted) -> GatewayModel {
        let model = GatewayModel(source: source)
        model.pollEvery = .milliseconds(5)
        return model
    }

    @Test func aSwitchIsFlippedAndThenHermessOwnListIsRead() async {
        let source = Scripted()
        let model = model(source)
        await model.load()
        #expect(model.servers.map(\.enabled) == [true, false])
        await model.setServer(model.servers[1], enabled: true)
        #expect(source.calls.contains("set notes true"))
        #expect(model.servers.map(\.enabled) == [true, true])
        #expect(model.problem == nil)

        // A switch Hermes turns down says why and goes back to what Hermes has.
        source.refuseSwitch = "Server 'home' is provided by plugin 'acme' and cannot be modified"
        await model.setServer(model.servers[0], enabled: false)
        #expect(model.problem == "Server 'home' is provided by plugin 'acme' and cannot be modified")
        #expect(model.servers[0].enabled, "the switch shows what the server has")
        #expect(model.busy.isEmpty)
    }

    @Test func aTestIsKeptByItsServerAndAFailureIsAResultToo() async {
        let model = model(Scripted())
        await model.load()
        await model.test(model.servers[0])
        await model.test(model.servers[1])
        #expect(model.probes["home"]?.summary == "Connected · 2 tools")
        #expect(model.probes["notes"]?.ok == false)
        #expect(model.probes["notes"]?.summary.isEmpty == false)
    }

    @Test func aRestartIsFollowedUntilItHasEnded() async {
        let source = Scripted()
        source.actionAnswers = [GatewayAction(running: true, lines: ["Stopping gateway…"]), GatewayAction(running: true, lines: ["Stopping gateway…", "Starting gateway…"]),
                                GatewayAction(running: false, exitCode: 0, lines: ["Stopping gateway…", "Starting gateway…", "✓ done"])]
        let model = model(source)
        await model.load()
        await model.restart()
        #expect(source.calls.filter { $0 == "action gateway-restart" }.count == 3)
        #expect(model.work == nil)
        #expect(model.progress.last == "✓ done")
        #expect(model.outcome == .init(ok: true, text: "The gateway was restarted."))
        #expect(source.calls.last == "status", "and the status is read again")
    }

    @Test func aRestartWhoseCommandBecomesTheGatewayIsOverWhenANewGatewayRuns() async {
        // No service manager: Hermes's restart command stops the old gateway and runs the new one
        // itself, so it is "running" for as long as the gateway is.
        let source = Scripted()
        source.actionAnswers = Array(repeating: GatewayAction(running: true, lines: ["✓ Stopped gateway for this profile", "Starting gateway..."]), count: 50)
        source.downFor = 2
        source.startedAtAfterRestart = "boot-2"
        let model = model(source)
        await model.load()
        await model.restart()
        #expect(model.outcome == .init(ok: true, text: "The gateway was restarted."))
        #expect(source.calls.filter { $0 == "action gateway-restart" }.count <= 4, "it stops asking once the new gateway is up")
        #expect(model.status?.startedAt == "boot-2")

        // The same gateway still running is no restart: that one is waited for.
        let stuck = Scripted()
        stuck.actionAnswers = Array(repeating: GatewayAction(running: true), count: 400)
        let waiting = self.model(stuck)
        waiting.restartPatience = .milliseconds(60)
        await waiting.restart()
        #expect(waiting.outcome?.ok == false)
    }

    @Test func aRestartThatFailsSaysWhatHermesPrinted() async {
        let source = Scripted()
        source.actionAnswers = [GatewayAction(running: false, exitCode: 1, lines: ["Error: no service installed"])]
        let model = model(source)
        await model.restart()
        #expect(model.outcome == .init(ok: false, text: "The restart failed: Error: no service installed"))

        // It ran, and the gateway is not back.
        source.actionAnswers = [GatewayAction(running: false, exitCode: 0)]
        source.running = false
        await model.restart()
        #expect(model.outcome?.ok == false)
        #expect(model.outcome?.text == "The gateway stopped and hasn't come back (it says: Stopped). Start it on the server: hermes gateway start")
    }

    @Test func anUpdateIsFollowedThroughTheSilenceOfARestart() async {
        let source = Scripted()
        // Hermes restarts under the update: it answers nothing for a while, then no longer knows how it ended.
        source.actionAnswers = [GatewayAction(running: true, lines: ["→ Fetching updates…"]), nil, nil, GatewayAction(running: false, exitCode: nil)]
        source.versionAfterAction = "0.21.6"
        let model = model(source)
        await model.load()
        await model.applyUpdate()
        #expect(source.calls.filter { $0 == "action hermes-update" }.count == 4)
        #expect(model.outcome == .init(ok: true, text: "Hermes is now 0.21.6."))
        #expect(model.update?.currentVersion == "0.21.6", "the update check is read again")
        #expect(model.work == nil)
    }

    @Test func anUpdateThatChangedNothingOrWasRefusedSaysSo() async {
        let source = Scripted()
        source.actionAnswers = [GatewayAction(running: false, exitCode: nil)]
        let model = model(source)
        await model.load()
        await model.applyUpdate()
        #expect(model.outcome?.ok == false)
        #expect(model.outcome?.text.contains("still 0.21.5") == true)

        source.actionAnswers = [GatewayAction(running: false, exitCode: 2, lines: ["error: local changes would be overwritten"])]
        await model.applyUpdate()
        #expect(model.outcome == .init(ok: false, text: "The update failed: error: local changes would be overwritten"))

        source.refuseUpdate = "Hermes updates are managed outside this dashboard. (docker pull)"
        await model.applyUpdate()
        #expect(model.outcome == .init(ok: false, text: "Hermes wasn't updated: Hermes updates are managed outside this dashboard. (docker pull)"))
        #expect(!source.calls.suffix(3).contains("action hermes-update"), "nothing is followed when nothing started")
    }

    @Test func somethingThatNeverEndsIsGivenUpOn() async {
        let source = Scripted()
        source.actionAnswers = Array(repeating: GatewayAction(running: true), count: 400)
        let model = model(source)
        model.restartPatience = .milliseconds(60)
        await model.restart()
        #expect(model.outcome?.ok == false)
        #expect(model.outcome?.text.contains("took too long") == true)
        #expect(model.work == nil)
    }

    @Test func aServerThatCannotBeReadSaysWhy() async {
        final class Down: GatewayAdministering {
            func gatewayStatus() async throws -> GatewayStatus { throw TransportError.http(status: 401, body: "session_expired") }
            func hostStats() async throws -> HostStats { HostStats() }
            func mcpServers() async throws -> [MCPServer] { [] }
            func setMCPServer(_ name: String, enabled: Bool) async throws {}
            func testMCPServer(_ name: String) async throws -> MCPProbe { MCPProbe(ok: false) }
            func gatewayLogs(_ file: GatewayLog, lines: Int, level: GatewayLog.Level, search: String) async throws -> [String] { [] }
            func restartGateway() async throws -> String { "" }
            func gatewayAction(_ name: String) async throws -> GatewayAction { GatewayAction(running: false) }
            func hermesUpdate() async throws -> HermesUpdate { HermesUpdate() }
            func updateHermes() async throws -> String { "" }
        }
        let model = GatewayModel(source: Down())
        await model.load()
        #expect(model.status == nil)
        #expect(model.problem?.isEmpty == false)
        #expect(!model.loading)
    }
}

/// What the client asks the Dashboard for. In the client's own suite: the stub is shared, and
/// that suite runs one test at a time.
extension HermesServeClientTests {
    private func gatewayClient(profile: String = "") -> HermesServeClient {
        let settings = Settings(defaults: UserDefaults(suiteName: "gateway-test-\(UUID().uuidString)")!)
        settings.serveURL = "http://serve.test:9119"
        settings.serveUsername = "redde"
        settings.hermesProfile = profile
        return HermesServeClient(settings: settings, password: { "hunter2" }, tokens: TokenBox().store, protocolClasses: [ServeStub.self])
    }

    /// Answers every administration route, and writes down what was asked.
    private func installAdmin(_ asked: Asked, updateRefused: Bool = false) {
        ServeStub.reset()
        ServeStub.handler = { request, body in
            let path = request.url?.path(percentEncoded: true) ?? ""
            let query = request.url?.query(percentEncoded: false) ?? ""
            if path.hasPrefix("/api/"), path != "/api/sessions" {
                asked.add("\(request.httpMethod ?? "") \(path)\(query.isEmpty ? "" : "?" + query)\(body.map { " " + String(decoding: $0, as: UTF8.self) } ?? "")")
            }
            switch (request.httpMethod, path) {
            case ("GET", "/api/sessions"): return (200, Data("[]".utf8))
            case ("GET", "/api/status"): return (200, Data(#"{"version":"0.21.5","gateway_running":true,"gateway_state":"running"}"#.utf8))
            case ("GET", "/api/system/stats"): return (200, Data(#"{"hostname":"homelab","os":"Linux","arch":"x86_64"}"#.utf8))
            case ("GET", "/api/mcp/servers"): return (200, Data(#"{"servers":[{"name":"my notes","transport":"stdio","command":"uvx","args":["bm"],"enabled":true}]}"#.utf8))
            case ("PUT", "/api/mcp/servers/my%20notes/enabled"): return (200, Data(#"{"ok":true,"name":"my notes","enabled":false}"#.utf8))
            case ("PUT", "/api/mcp/servers/from-plugin/enabled"):
                return (409, Data(#"{"detail":"Server 'from-plugin' is provided by plugin 'acme' and cannot be modified"}"#.utf8))
            case ("POST", "/api/mcp/servers/my%20notes/test"): return (200, Data(#"{"ok":true,"tools":[{"name":"search","description":""}]}"#.utf8))
            case ("GET", "/api/logs"): return (200, Data(#"{"file":"gateway","lines":["one\n","two\n"]}"#.utf8))
            case ("POST", "/api/gateway/restart"): return (200, Data(#"{"ok":true,"pid":41,"name":"gateway-restart"}"#.utf8))
            case ("GET", "/api/actions/gateway-restart/status"): return (200, Data(#"{"name":"gateway-restart","running":false,"exit_code":0,"pid":41,"lines":["done\n"]}"#.utf8))
            case ("GET", "/api/hermes/update/check"): return (200, Data(#"{"current_version":"0.21.5","behind":2,"update_available":true,"can_apply":true,"update_command":"hermes update"}"#.utf8))
            case ("POST", "/api/hermes/update"):
                return updateRefused
                    ? (200, Data(#"{"ok":false,"pid":null,"name":"hermes-update","error":"docker_update_unsupported","message":"Hermes runs in a container here.","update_command":"docker pull hermes"}"#.utf8))
                    : (200, Data(#"{"ok":true,"pid":42,"name":"hermes-update","action_id":"abc"}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
    }

    nonisolated final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    @Test func theGatewayScreenAsksTheDashboardsOwnRoutes() async throws {
        let asked = Asked()
        installAdmin(asked)
        defer { ServeStub.reset() }
        let client = gatewayClient()

        #expect(try await client.gatewayStatus().version == "0.21.5")
        #expect(try await client.hostStats().hostname == "homelab")
        let servers = try await client.mcpServers()
        #expect(servers.map(\.name) == ["my notes"])
        try await client.setMCPServer("my notes", enabled: false)
        #expect(try await client.testMCPServer("my notes").tools == ["search"])
        #expect(try await client.gatewayLogs(.gateway, lines: 9_000, level: .warning, search: " reset ") == ["one", "two"])
        #expect(try await client.restartGateway() == "gateway-restart")
        #expect(try await client.gatewayAction("gateway-restart") == GatewayAction(running: false, exitCode: 0, lines: ["done"]))
        #expect(try await client.hermesUpdate().behind == 2)
        #expect(try await client.updateHermes() == "hermes-update")

        #expect(asked.all == [
            "GET /api/status",
            "GET /api/system/stats",
            "GET /api/mcp/servers",
            #"PUT /api/mcp/servers/my%20notes/enabled {"enabled":false}"#,
            "POST /api/mcp/servers/my%20notes/test",
            "GET /api/logs?file=gateway&lines=500&level=WARNING&search=reset",
            "POST /api/gateway/restart",
            "GET /api/actions/gateway-restart/status?lines=40",
            "GET /api/hermes/update/check",
            "POST /api/hermes/update",
        ])
    }

    @Test func theSelectedProfileRidesOnTheRoutesThatTakeOne() async throws {
        let asked = Asked()
        installAdmin(asked)
        defer { ServeStub.reset() }
        let client = gatewayClient(profile: "work")
        _ = try await client.gatewayStatus()
        _ = try await client.mcpServers()
        try await client.setMCPServer("my notes", enabled: false)
        _ = try await client.gatewayLogs(.agent, lines: 50, level: .all, search: "")
        _ = try await client.restartGateway()
        _ = try await client.hostStats()
        _ = try await client.hermesUpdate()
        _ = try await client.gatewayAction("gateway-restart")
        #expect(asked.all == [
            "GET /api/status?profile=work",
            "GET /api/mcp/servers?profile=work",
            #"PUT /api/mcp/servers/my%20notes/enabled?profile=work {"enabled":false}"#,
            "GET /api/logs?file=agent&lines=50&profile=work",
            "POST /api/gateway/restart?profile=work",
            // The machine, Hermes's own version and a running action belong to no profile.
            "GET /api/system/stats",
            "GET /api/hermes/update/check",
            "GET /api/actions/gateway-restart/status?lines=40",
        ])
    }

    @Test func whatHermesTurnsDownIsSaidInItsWords() async throws {
        let asked = Asked()
        installAdmin(asked, updateRefused: true)
        defer { ServeStub.reset() }
        let client = gatewayClient()
        await #expect(throws: GatewayRefusal(message: "Hermes runs in a container here. (docker pull hermes)")) {
            _ = try await client.updateHermes()
        }
        var said = ""
        do { try await client.setMCPServer("from-plugin", enabled: false) } catch { said = error.localizedDescription }
        #expect(said.contains("provided by plugin 'acme'"))
    }

    @Test func aNameIsOnePartOfAPath() {
        #expect(HermesServeClient.pathPart("my notes") == "my%20notes")
        #expect(HermesServeClient.pathPart("a/b?c#d") == "a%2Fb%3Fc%23d")
        #expect(HermesServeClient.pathPart("home-assistant") == "home-assistant")
    }
}
