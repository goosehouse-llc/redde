// The kinds of connection a turn can go by (Settings → Connection).
import Foundation

/// Which backend a turn is sent to.
nonisolated enum Transport: String, CaseIterable, Identifiable, Codable {
    // Declaration order is the order Settings and setup list them: Dashboard, API, OpenAI-compatible.
    /// `hermes serve` desktop gateway over WebSocket: live reasoning, approvals, slash commands.
    case hermesServe
    /// Hermes gateway sessions API — the shared ledger (Telegram, CLI, Discord, Echo), with live
    /// reasoning and tool events. Bearer key required.
    case hermesSessions
    /// OpenAI-compatible `/v1/chat/completions` — used for the llama-swap "fast lane" straight to the model.
    case chatCompletions
    /// An agent that speaks ACP (the Agent Client Protocol): Claude Code, Codex, Gemini CLI, Goose,
    /// Hermes's own `hermes acp`…, through the Redde bridge on its host (`AcpClient`, docs/acp.md).
    case acp

    var id: String { rawValue }
    var label: String {
        switch self {
        case .hermesSessions: String(localized: "Hermes API (shared sessions)")
        case .hermesServe: String(localized: "Hermes Dashboard or Webapp (WebSocket)", comment: "A connection: the Hermes Dashboard, or the Webapp Hermes 0.23's gateway serves itself")
        case .chatCompletions: String(localized: "OpenAI-compatible (direct to a model)")
        case .acp: String(localized: "Other agent (ACP)", comment: "A connection: Claude Code, Codex and other agents through the Agent Client Protocol")
        }
    }
    /// Its name inside its group (`Kind`), where the group's header says the rest.
    var shortLabel: String {
        switch self {
        case .hermesServe: String(localized: "Dashboard or Webapp (WebSocket)", comment: "A Hermes connection, listed under the header Hermes: the Dashboard, or the Webapp Hermes 0.23's gateway serves itself")
        case .hermesSessions: String(localized: "API (shared sessions)", comment: "A Hermes connection, listed under the header Hermes")
        case .acp: String(localized: "Claude Code, Codex and others (ACP)", comment: "A connection listed under the header Other Agents: agents through the Agent Client Protocol and the Redde bridge")
        case .chatCompletions: String(localized: "OpenAI-compatible server", comment: "A connection listed under the header Direct to a Model: llama-swap, LM Studio and the like")
        }
    }

    /// Its name on its own, short enough for a row's value (Settings' Connection row).
    var name: String {
        switch self {
        case .hermesServe: String(localized: "Hermes Dashboard", comment: "Session Details: the connection")
        case .hermesSessions: String(localized: "Hermes API", comment: "Session Details: the connection")
        case .acp: String(localized: "Other agent (ACP)", comment: "A connection: Claude Code, Codex and other agents through the Agent Client Protocol")
        case .chatCompletions: String(localized: "OpenAI-compatible")
        }
    }

    /// The kinds of agent a connection reaches, for grouping connections and servers.
    enum Kind: Int, CaseIterable, Identifiable, Comparable {
        case hermes, agent, model
        var id: Int { rawValue }
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
        var title: String {
            switch self {
            case .hermes: String(localized: "Hermes", comment: "Group header for the Hermes connections and servers")
            case .agent: String(localized: "Other Agents", comment: "Group header for agents over ACP (Claude Code, Codex…) and their servers")
            case .model: String(localized: "Direct to a Model", comment: "Group header for the OpenAI-compatible connection, which talks to a model with no agent")
            }
        }
        var symbol: String {
            switch self {
            case .hermes: "server.rack"
            case .agent: "terminal"
            case .model: "cpu"
            }
        }
        var transports: [Transport] { Transport.allCases.filter { $0.kind == self } }
    }

    var kind: Kind {
        switch self {
        case .hermesServe, .hermesSessions: .hermes
        case .acp: .agent
        case .chatCompletions: .model
        }
    }

    /// Uses the API server (8642) with the bearer key.
    var usesGateway: Bool { self == .hermesSessions }

    /// Old installs may have stored a transport that no longer exists; map it to the default.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Transport(rawValue: raw) ?? .hermesSessions
    }
    /// Shows a server-side session list: the server keeps the conversation, and a turn left for
    /// another chat goes on there.
    var hasLedger: Bool { self == .hermesSessions || self == .hermesServe || self == .acp }
    /// A Hermes connection: bots, steering, routines, the plugin and the rest Hermes alone has.
    var isHermes: Bool { self == .hermesSessions || self == .hermesServe }
}
