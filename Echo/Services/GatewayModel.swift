import Foundation
import Observation

/// What the Gateway screen shows and does: the server's status, its MCP servers, and a restart
/// or an update followed to its end.
@Observable
final class GatewayModel {
    /// A restart or an update under way.
    enum Work: Equatable, Sendable { case restarting, updating }

    /// How the last one ended.
    struct Outcome: Equatable, Sendable {
        var ok: Bool
        var text: String
    }

    private(set) var status: GatewayStatus?
    private(set) var host: HostStats?
    private(set) var servers: [MCPServer] = []
    /// What testing a server found, by its name.
    private(set) var probes: [String: MCPProbe] = [:]
    /// Servers being switched or tested right now.
    private(set) var busy: Set<String> = []
    private(set) var update: HermesUpdate?
    private(set) var checkingUpdate = false
    private(set) var work: Work?
    /// The last lines Hermes printed while it worked.
    private(set) var progress: [String] = []
    private(set) var outcome: Outcome?
    private(set) var loading = true
    /// Why the server couldn't be read, or why a switch didn't take.
    var problem: String?

    @ObservationIgnored let source: any GatewayAdministering
    /// How often a restart or an update is asked how it is getting on, and how long each may take.
    @ObservationIgnored var pollEvery: Duration = .seconds(1)
    @ObservationIgnored var restartPatience: Duration = .seconds(120)
    @ObservationIgnored var updatePatience: Duration = .seconds(15 * 60)

    init(source: any GatewayAdministering) {
        self.source = source
    }

    /// Reads the status, the host and the MCP servers. Only the status has to be there: the
    /// rest is shown when it comes.
    func load() async {
        do {
            status = try await source.gatewayStatus()
            problem = nil
        } catch {
            problem = error.localizedDescription
            loading = false
            return
        }
        host = try? await source.hostStats()
        if let listed = try? await source.mcpServers() { servers = listed }
        loading = false
    }

    func setServer(_ server: MCPServer, enabled: Bool) async {
        guard !busy.contains(server.name) else { return }
        busy.insert(server.name)
        defer { busy.remove(server.name) }
        if let i = servers.firstIndex(where: { $0.name == server.name }) { servers[i].enabled = enabled }
        do {
            try await source.setMCPServer(server.name, enabled: enabled)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        // Hermes's own list is the truth, whichever way the switch went.
        if let listed = try? await source.mcpServers() { servers = listed }
    }

    func test(_ server: MCPServer) async {
        guard !busy.contains(server.name) else { return }
        busy.insert(server.name)
        defer { busy.remove(server.name) }
        probes[server.name] = nil
        do {
            probes[server.name] = try await source.testMCPServer(server.name)
        } catch {
            probes[server.name] = MCPProbe(ok: false, error: error.localizedDescription)
        }
    }

    func checkForUpdate() async {
        guard !checkingUpdate else { return }
        checkingUpdate = true
        defer { checkingUpdate = false }
        do {
            update = try await source.hermesUpdate()
        } catch {
            outcome = Outcome(ok: false, text: "Couldn't check for an update: \(error.localizedDescription)")
        }
    }

    /// Restarts the gateway and waits for it to be back.
    ///
    /// Where a service manager runs the gateway, Hermes's restart command ends when it is done.
    /// Where the gateway was started by hand, that command stops the old one and becomes the new
    /// one, so it never ends: there the restart is over when a gateway that started after the
    /// request is running.
    func restart() async {
        guard work == nil else { return }
        work = .restarting
        progress = []
        outcome = nil
        defer { work = nil }
        do {
            let before = (try? await source.gatewayStatus())?.startedAt ?? status?.startedAt
            var wentDown = false
            let ended = try await follow(try await source.restartGateway(), patience: restartPatience) { [source] in
                guard let now = try? await source.gatewayStatus() else { return false }
                if !now.gatewayRunning { wentDown = true; return false }
                return wentDown || (now.startedAt != nil && now.startedAt != before)
            }
            await load()
            if let code = ended.exitCode, code != 0 {
                outcome = Outcome(ok: false, text: "The restart failed: \(ended.lines.last ?? "exit code \(code)")")
            } else if status?.gatewayRunning == false {
                // Hermes 0.21.5 does this to a gateway that was started by hand: it stops it, takes
                // the one it just stopped for a running one, and starts nothing.
                outcome = Outcome(ok: false, text: "The gateway stopped and hasn't come back (it says: \(status?.gatewayLabel ?? "Stopped")). Start it on the server: hermes gateway start")
            } else {
                outcome = Outcome(ok: true, text: "The gateway was restarted.")
            }
        } catch {
            outcome = Outcome(ok: false, text: "The gateway wasn't restarted: \(error.localizedDescription)")
            await load()
        }
    }

    /// Has Hermes update itself and waits for it to be back, which can take minutes: it
    /// restarts on the way, and for a while answers nothing.
    func applyUpdate() async {
        guard work == nil else { return }
        work = .updating
        progress = []
        outcome = nil
        defer { work = nil }
        let before = status?.version ?? ""
        do {
            let ended = try await follow(try await source.updateHermes(), patience: updatePatience)
            await load()
            let now = status?.version ?? ""
            if let code = ended.exitCode, code != 0 {
                outcome = Outcome(ok: false, text: "The update failed: \(ended.lines.last ?? "exit code \(code)")")
            } else if !now.isEmpty, now != before {
                outcome = Outcome(ok: true, text: "Hermes is now \(now).")
            } else if ended.exitCode == 0 {
                outcome = Outcome(ok: true, text: "Hermes was updated.")
            } else {
                // Hermes restarted and no longer knows how the update ended; its version is what it was.
                outcome = Outcome(ok: false, text: "The update ended and Hermes is still \(before.isEmpty ? "the same version" : before). Its log says why.")
            }
            update = try? await source.hermesUpdate()
        } catch {
            outcome = Outcome(ok: false, text: "Hermes wasn't updated: \(error.localizedDescription)")
            await load()
        }
    }

    /// Asks how an action is getting on until it has ended, or until `isOver` says its work is
    /// done although its command runs on. A server that doesn't answer is asked again: one that
    /// is restarting is silent for a while, which is no failure.
    private func follow(_ name: String, patience: Duration, isOver: (() async -> Bool)? = nil) async throws -> GatewayAction {
        let clock = ContinuousClock()
        let deadline = clock.now + patience
        while true {
            try await Task.sleep(for: pollEvery)
            if let action = try? await source.gatewayAction(name) {
                if !action.lines.isEmpty { progress = Array(action.lines.suffix(4)) }
                if !action.running { return action }
                if let isOver, await isOver() { return GatewayAction(running: false, exitCode: 0, lines: action.lines) }
            }
            guard clock.now < deadline else { throw GatewayRefusal(message: "it took too long. Look at the server.") }
        }
    }
}

#if DEBUG
/// A server made of sample data, for the Gateway screen's own look (`-echo.demoGateway`) and its tests.
final class DemoGateway: GatewayAdministering {
    var servers = [MCPServer(name: "home-assistant", transport: "http", target: "http://homelab.local:8123/mcp", enabled: true),
                   MCPServer(name: "basic-memory", transport: "stdio", target: "uvx basic-memory mcp", enabled: true),
                   MCPServer(name: "github", transport: "http", target: "https://api.githubcopilot.com/mcp/", enabled: false)]
    var version = "0.21.5"
    private var polls = 0

    func gatewayStatus() async throws -> GatewayStatus {
        var status = GatewayStatus()
        status.version = version
        status.releaseDate = "2026.9.24"
        status.gatewayRunning = true
        status.gatewayState = "running"
        status.activeTurns = 1
        status.startedAt = "2026-10-08T14:23:47+00:00"
        status.platforms = [.init(id: "api_server", state: "connected"), .init(id: "discord", state: "retrying", error: "Gateway closed the connection (4004)"),
                            .init(id: "telegram", state: "connected")]
        return status
    }

    func hostStats() async throws -> HostStats {
        var host = HostStats()
        host.hostname = "homelab"
        host.system = "Linux · x86_64"
        host.uptime = 6 * 86_400 + 15 * 3_600
        host.memoryPercent = 41.5
        host.diskPercent = 63
        return host
    }

    func mcpServers() async throws -> [MCPServer] { servers }

    func setMCPServer(_ name: String, enabled: Bool) async throws {
        if let i = servers.firstIndex(where: { $0.name == name }) { servers[i].enabled = enabled }
    }

    func testMCPServer(_ name: String) async throws -> MCPProbe {
        name == "github" ? MCPProbe(ok: false, error: "OAuth authentication required — no token found.")
            : MCPProbe(ok: true, tools: ["search", "read", "write", "list"])
    }

    func gatewayLogs(_ file: GatewayLog, lines: Int, level: GatewayLog.Level, search: String) async throws -> [String] {
        let all = ["2026-10-08 14:23:47,552 INFO gateway.run: Gateway running with 2 platform(s)",
                   "2026-10-08 14:23:47,561 INFO gateway.run: Channel directory built: 3 target(s)",
                   "2026-10-08 14:24:02,118 INFO run_agent: turn started session=20261008_142401_3f2a model=qwen3-32b",
                   "2026-10-08 14:24:05,904 WARNING tools.mcp_tool: home-assistant: tools/list took 3.2s",
                   "2026-10-08 14:24:09,377 INFO run_agent: turn finished in 7.3s (2 tool calls)",
                   "2026-10-08 14:31:40,020 ERROR plugins.platforms.discord: Gateway closed the connection (4004)",
                   "2026-10-08 14:31:45,031 INFO plugins.platforms.discord: reconnecting in 30s"]
        return all.filter { line in
            (level == .all || GatewayLog.level(of: line) == .error || (level == .warning && GatewayLog.level(of: line) == .warning))
                && (search.isEmpty || line.localizedCaseInsensitiveContains(search))
        }
    }

    func restartGateway() async throws -> String {
        polls = 0
        return GatewayAction.restart
    }

    func gatewayAction(_ name: String) async throws -> GatewayAction {
        polls += 1
        let said = name == GatewayAction.update ? ["→ Fetching updates…", "→ Installing dependencies…", "✓ Hermes updated"] : ["Stopping gateway…", "Starting gateway…", "✓ Gateway restarted"]
        if polls >= 3, name == GatewayAction.update { version = "0.21.6" }
        return GatewayAction(running: polls < 3, exitCode: polls < 3 ? nil : 0, lines: Array(said.prefix(polls)))
    }

    func hermesUpdate() async throws -> HermesUpdate {
        var update = HermesUpdate()
        update.currentVersion = version
        update.available = version == "0.21.5"
        update.behind = version == "0.21.5" ? 12 : 0
        update.command = "hermes update"
        return update
    }

    func updateHermes() async throws -> String {
        polls = 0
        return GatewayAction.update
    }
}
#endif
