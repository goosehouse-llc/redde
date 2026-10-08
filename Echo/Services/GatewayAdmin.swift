import Foundation

// The Hermes server itself, as its own Dashboard administers it: what is running and what it is
// connected to, its MCP servers and its logs, and restarting or updating it. All of it is the
// Dashboard's REST API (`hermes serve`), the routes its own web pages use, and the same in Hermes
// 0.21.0, 0.21.3 and 0.21.5 (`scripts/hermes-lab/lab.sh admin`). The Hermes API server has none
// of them, so this needs the Dashboard login.

/// `GET /api/status`: the gateway's account of itself.
nonisolated struct GatewayStatus: Equatable, Sendable {
    var version = ""
    var releaseDate = ""
    var gatewayRunning = false
    /// Hermes's own word: "running", "stopped", "draining", "startup_failed"…
    var gatewayState = ""
    var exitReason: String?
    /// Turns the gateway is in the middle of: what a restart cuts off.
    var activeTurns = 0
    /// What the gateway is connected to: its API server and the messaging platforms.
    var platforms: [Platform] = []
    /// The parts Hermes says are not in order (a component whose status isn't "ok").
    var troubles: [Trouble] = []
    /// False where Hermes is updated some other way (a container, a package manager).
    var canUpdate = true
    /// When this gateway process started, as Hermes writes it. A different one after a restart
    /// is how the restart is known to be over.
    var startedAt: String?

    struct Platform: Identifiable, Equatable, Sendable {
        var id: String
        var state: String
        var error: String?
        var isConnected: Bool { state == "connected" }
        var title: String { Self.titles[id] ?? id.replacingOccurrences(of: "_", with: " ").capitalized }
        private static let titles = ["api_server": "Hermes API", "whatsapp": "WhatsApp", "imessage": "iMessage", "sms": "SMS",
                                     "homeassistant": "Home Assistant", "bluebubbles": "BlueBubbles"]
    }

    struct Trouble: Identifiable, Equatable, Sendable {
        var id: String
        var status: String
    }

    init() {}

    init(_ json: JSONValue) {
        version = json["version"]?.string ?? ""
        releaseDate = json["release_date"]?.string ?? ""
        gatewayRunning = json["gateway_running"]?.bool ?? false
        gatewayState = json["gateway_state"]?.string ?? ""
        exitReason = json["gateway_exit_reason"]?.string?.nilIfEmpty
        activeTurns = json["active_agents"]?.int ?? 0
        platforms = (json["gateway_platforms"]?.object ?? [:]).map { name, entry in
            Platform(id: name, state: entry["state"]?.string ?? "unknown", error: entry["error_message"]?.string?.nilIfEmpty)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        troubles = (json["components"]?.object ?? [:]).compactMap { name, entry in
            let status = entry["status"]?.string ?? ""
            return status.isEmpty || status == "ok" ? nil : Trouble(id: name, status: status)
        }.sorted { $0.id < $1.id }
        canUpdate = json["can_update_hermes"]?.bool ?? true
        startedAt = json["memory"]?["boot_id"]?.string?.nilIfEmpty
    }

    /// "Running", or Hermes's own word for anything else.
    var gatewayLabel: String {
        if gatewayRunning, gatewayState.isEmpty || gatewayState == "running" { return "Running" }
        let state = gatewayState.isEmpty ? (gatewayRunning ? "running" : "stopped") : gatewayState
        return state.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// `GET /api/system/stats`: the machine Hermes runs on.
nonisolated struct HostStats: Equatable, Sendable {
    var hostname = ""
    /// "macOS", "Linux", "Windows", with the processor: "Linux · x86_64".
    var system = ""
    var uptime: TimeInterval?
    var memoryPercent: Double?
    var diskPercent: Double?

    init() {}

    init(_ json: JSONValue) {
        hostname = json["hostname"]?.string ?? ""
        let os = json["os"]?.string ?? ""
        system = [os == "Darwin" ? "macOS" : os, json["arch"]?.string ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        uptime = json["uptime_seconds"]?.number
        memoryPercent = json["memory"]?["percent"]?.number
        diskPercent = json["disk"]?["percent"]?.number
    }

    /// "7 days, 15 hours".
    var uptimeLabel: String? {
        guard let uptime, uptime >= 60 else { return nil }
        return Duration.seconds(Int(uptime)).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2))
    }
}

/// One entry of `GET /api/mcp/servers`.
nonisolated struct MCPServer: Identifiable, Equatable, Sendable {
    var name: String
    /// "http" or "stdio".
    var transport: String
    /// Where it is: the address, or the command that starts it.
    var target: String
    var enabled: Bool
    /// The plugin that provides it (Hermes 0.21.5). Such a server is switched with its plugin,
    /// not here.
    var plugin: String?
    var id: String { name }

    init(name: String, transport: String = "stdio", target: String = "", enabled: Bool = true, plugin: String? = nil) {
        self.name = name; self.transport = transport; self.target = target; self.enabled = enabled; self.plugin = plugin
    }

    init?(_ json: JSONValue) {
        guard let name = json["name"]?.string, !name.isEmpty else { return nil }
        self.name = name
        transport = json["transport"]?.string ?? ""
        let command = [json["command"]?.string ?? ""] + (json["args"]?.array ?? []).compactMap(\.string)
        target = json["url"]?.string?.nilIfEmpty ?? command.filter { !$0.isEmpty }.joined(separator: " ")
        enabled = json["enabled"]?.bool ?? true
        plugin = json["plugin"]?.string?.nilIfEmpty
    }
}

/// `POST /api/mcp/servers/{name}/test`: Hermes connects, lists the tools and disconnects.
nonisolated struct MCPProbe: Equatable, Sendable {
    var ok: Bool
    var tools: [String]
    var error: String?

    init(ok: Bool, tools: [String] = [], error: String? = nil) {
        self.ok = ok; self.tools = tools; self.error = error
    }

    init(_ json: JSONValue) {
        ok = json["ok"]?.bool ?? false
        tools = (json["tools"]?.array ?? []).compactMap { $0["name"]?.string }
        error = json["error"]?.string?.nilIfEmpty
    }

    var summary: String {
        if ok { return tools.isEmpty ? "Connected, no tools" : "Connected · \(tools.count) tool\(tools.count == 1 ? "" : "s")" }
        return error ?? "Couldn't connect"
    }
}

/// `GET /api/actions/{name}/status`: a restart or an update Hermes is carrying out, and what it
/// has printed so far.
nonisolated struct GatewayAction: Equatable, Sendable {
    static let restart = "gateway-restart"
    static let update = "hermes-update"

    var running: Bool
    /// Nil while it runs, and when Hermes no longer knows how it ended (it restarted meanwhile).
    var exitCode: Int?
    var lines: [String]

    init(running: Bool, exitCode: Int? = nil, lines: [String] = []) {
        self.running = running; self.exitCode = exitCode; self.lines = lines
    }

    init(_ json: JSONValue) {
        running = json["running"]?.bool ?? false
        exitCode = json["exit_code"]?.int
        lines = (json["lines"]?.array ?? []).compactMap(\.string).map(GatewayLog.tidy).filter { !$0.isEmpty }
    }
}

/// `GET /api/hermes/update/check`.
nonisolated struct HermesUpdate: Equatable, Sendable {
    var currentVersion = ""
    /// How many commits behind; nil when Hermes couldn't find out.
    var behind: Int?
    var available = false
    /// False where the Dashboard can't apply an update itself; `command` then says what does.
    var canApply = true
    var command = ""
    /// Hermes's own remark: why it couldn't check, or how this install is updated.
    var message: String?

    init() {}

    init(_ json: JSONValue) {
        currentVersion = json["current_version"]?.string ?? ""
        behind = json["behind"]?.int
        available = json["update_available"]?.bool ?? false
        canApply = json["can_apply"]?.bool ?? true
        command = json["update_command"]?.string ?? ""
        message = json["message"]?.string?.nilIfEmpty
    }

    var summary: String {
        if available { return behind.map { "\($0) change\($0 == 1 ? "" : "s") behind" } ?? "An update is available" }
        return message ?? "Up to date"
    }
}

/// The log files `GET /api/logs` reads, and its filters.
nonisolated enum GatewayLog: String, CaseIterable, Identifiable, Sendable {
    case agent, errors, gateway
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    enum Level: String, CaseIterable, Identifiable, Sendable {
        case all = "", warning = "WARNING", error = "ERROR"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "Everything"
            case .warning: "Warnings and errors"
            case .error: "Errors only"
            }
        }
    }

    /// The most lines Hermes hands over in one answer.
    static let mostLines = 500

    /// A line as it is shown: without its line break, and without the colour codes a terminal
    /// would have used.
    static func tidy(_ line: String) -> String {
        line.replacing(/\u{1B}\[[0-9;]*[A-Za-z]/, with: "").trimmingCharacters(in: .newlines)
    }

    /// The level a line was logged at, for its colour: "2026-10-08 14:23:47,552 WARNING gateway.run: …".
    static func level(of line: String) -> Level {
        let head = line.prefix(48)
        if head.contains(" ERROR ") || head.contains(" CRITICAL ") || line.hasPrefix("Traceback") { return .error }
        return head.contains(" WARNING ") ? .warning : .all
    }
}

/// Hermes answered, and the answer was no: an update it won't apply to this install.
nonisolated struct GatewayRefusal: LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

/// What the Gateway screen asks of a server. `HermesServeClient` in the app; a fixture for the
/// screen's demo and its tests.
protocol GatewayAdministering: AnyObject {
    func gatewayStatus() async throws -> GatewayStatus
    func hostStats() async throws -> HostStats
    func mcpServers() async throws -> [MCPServer]
    func setMCPServer(_ name: String, enabled: Bool) async throws
    func testMCPServer(_ name: String) async throws -> MCPProbe
    func gatewayLogs(_ file: GatewayLog, lines: Int, level: GatewayLog.Level, search: String) async throws -> [String]
    /// Starts a restart and names the action to follow.
    func restartGateway() async throws -> String
    func gatewayAction(_ name: String) async throws -> GatewayAction
    func hermesUpdate() async throws -> HermesUpdate
    /// Starts an update and names the action to follow; throws `GatewayRefusal` when Hermes won't.
    func updateHermes() async throws -> String
}

extension HermesServeClient: GatewayAdministering {
    func gatewayStatus() async throws -> GatewayStatus {
        GatewayStatus(try await restJSON("GET", "api/status"))
    }

    func hostStats() async throws -> HostStats {
        HostStats(try await restJSON("GET", "api/system/stats"))
    }

    func mcpServers() async throws -> [MCPServer] {
        (try await restJSON("GET", "api/mcp/servers")["servers"]?.array ?? []).compactMap(MCPServer.init)
    }

    /// Switches a server on or off in Hermes's config. It takes effect where Hermes next reads
    /// it: a new conversation, or a restart.
    func setMCPServer(_ name: String, enabled: Bool) async throws {
        _ = try await restJSON("PUT", "api/mcp/servers/\(Self.pathPart(name))/enabled", body: .object(["enabled": .bool(enabled)]))
    }

    func testMCPServer(_ name: String) async throws -> MCPProbe {
        // Hermes starts the server and waits for its tools: a slow one takes a while.
        MCPProbe(try await restJSON("POST", "api/mcp/servers/\(Self.pathPart(name))/test", timeout: 90))
    }

    func gatewayLogs(_ file: GatewayLog, lines: Int, level: GatewayLog.Level, search: String) async throws -> [String] {
        var comps = URLComponents()
        comps.path = "api/logs"
        comps.queryItems = [.init(name: "file", value: file.rawValue), .init(name: "lines", value: String(min(max(lines, 1), GatewayLog.mostLines)))]
        if level != .all { comps.queryItems?.append(.init(name: "level", value: level.rawValue)) }
        let wanted = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !wanted.isEmpty { comps.queryItems?.append(.init(name: "search", value: wanted)) }
        let answer = try await restJSON("GET", comps.string ?? "api/logs")
        return (answer["lines"]?.array ?? []).compactMap(\.string).map(GatewayLog.tidy).filter { !$0.isEmpty }
    }

    func restartGateway() async throws -> String {
        try await restJSON("POST", "api/gateway/restart")["name"]?.string ?? GatewayAction.restart
    }

    func gatewayAction(_ name: String) async throws -> GatewayAction {
        GatewayAction(try await restJSON("GET", "api/actions/\(Self.pathPart(name))/status?lines=40"))
    }

    func hermesUpdate() async throws -> HermesUpdate {
        HermesUpdate(try await restJSON("GET", "api/hermes/update/check", timeout: 60))
    }

    func updateHermes() async throws -> String {
        let answer = try await restJSON("POST", "api/hermes/update")
        guard answer["ok"]?.bool == true else {
            let how = answer["update_command"]?.string?.nilIfEmpty.map { " (\($0))" } ?? ""
            throw GatewayRefusal(message: (answer["message"]?.string?.nilIfEmpty ?? "Hermes didn't start the update.") + how)
        }
        return answer["name"]?.string ?? GatewayAction.update
    }

    /// A name as one part of a path: a server called "a/b" must not become two.
    nonisolated static func pathPart(_ name: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }
}
