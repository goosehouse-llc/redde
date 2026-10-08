import Foundation
import Observation

/// How a conversation on the Dashboard runs: whether its commands are run without asking, and
/// whether its provider is asked for the fast tier. Both are the session's own on the server
/// (`config.set key=yolo` and `key=fast`, the same in Hermes 0.21.0, 0.21.3 and 0.21.5), and the
/// server says where they stand in a session's `info`: when it is resumed, and in every
/// `session.info` event after a change.
nonisolated struct ChatControls: Equatable, Sendable {
    /// Commands run without asking: this conversation's switch, or the server's own setting.
    var autoApprove = false
    /// Hermes's `approvals.mode`: "manual", "smart", or "off", which asks about nothing anywhere.
    var approvalMode = ""
    /// The provider's fast (priority) tier is asked for.
    var fast = false

    init(autoApprove: Bool = false, approvalMode: String = "", fast: Bool = false) {
        self.autoApprove = autoApprove; self.approvalMode = approvalMode; self.fast = fast
    }

    /// Takes what a session's info says. Only what it says: Hermes also sends short infos (a
    /// working directory that changed), and those leave the rest as it was.
    mutating func merge(_ info: JSONValue) {
        if let yolo = info["yolo"]?.bool { autoApprove = yolo }
        if let mode = info["approval_mode"]?.string { approvalMode = mode }
        if let fast = info["fast"]?.bool { self.fast = fast } else if let tier = info["service_tier"]?.string { fast = tier == "priority" }
    }

    /// The server approves everything by its own config: there is nothing to switch for one
    /// conversation, and the switch says so.
    var serverNeverAsks: Bool { approvalMode == "off" }

    /// Why Hermes turned fast mode down, in the screen's words; its own otherwise.
    static func fastRefusal(_ message: String) -> String {
        message.localizedCaseInsensitiveContains("not available for this model") ? "This model has no fast mode."
            : message.localizedCaseInsensitiveContains("without a selected model") ? "Pick a model first: fast mode belongs to a model."
            : message
    }
}

/// Where each open conversation's controls stand, by the session's id on the server. Written by
/// the Dashboard client as the server reports them; read by the chat's header, which marks a
/// conversation that runs commands without asking.
@Observable
final class ChatControlStore {
    static let shared = ChatControlStore()

    private(set) var bySession: [String: ChatControls] = [:]

    func controls(for session: String?) -> ChatControls? { session.flatMap { bySession[$0] } }

    /// What the server just said about a session; an equal answer changes nothing.
    @discardableResult
    func note(_ info: JSONValue, for session: String) -> ChatControls {
        var controls = bySession[session] ?? ChatControls()
        controls.merge(info)
        set(controls, for: session)
        return controls
    }

    func set(_ controls: ChatControls, for session: String) {
        if bySession[session] != controls { bySession[session] = controls }
    }

    /// Another server: its sessions are other sessions.
    func removeAll() {
        if !bySession.isEmpty { bySession = [:] }
    }
}

/// What the model menu's switches ask of a server. `HermesServeClient` in the app; sample data
/// for the menu's own look and its UI test.
protocol ChatControlling: AnyObject {
    func chatControls(stored: String) async throws -> ChatControls
    func setAutoApprove(_ on: Bool, stored: String) async throws -> ChatControls
    func setFast(_ on: Bool, stored: String) async throws -> ChatControls
}

extension HermesServeClient: ChatControlling {
    /// Asks the server where a stored session's controls stand, by resuming it.
    func chatControls(stored: String) async throws -> ChatControls {
        let resumed = try await resume(stored: stored, withMessages: false)
        return ChatControlStore.shared.note(resumed["info"] ?? .null, for: stored)
    }

    /// Has this conversation's commands run without asking, or ask again. Session-scoped: no
    /// `scope`, so Hermes's config and every other conversation stay as they are. The flag lives
    /// in the Hermes process, so a restart of Hermes turns it off.
    func setAutoApprove(_ on: Bool, stored: String) async throws -> ChatControls {
        let answer = try await setControl("yolo", to: on ? "on" : "off", stored: stored)
        var controls = ChatControlStore.shared.controls(for: stored) ?? ChatControls()
        controls.autoApprove = answer == "1" || controls.serverNeverAsks
        ChatControlStore.shared.set(controls, for: stored)
        return controls
    }

    /// Asks the provider for its fast tier in this conversation, or the normal one. Hermes turns
    /// it down (4002) for a model that has none.
    func setFast(_ on: Bool, stored: String) async throws -> ChatControls {
        let answer = try await setControl("fast", to: on ? "fast" : "normal", stored: stored)
        var controls = ChatControlStore.shared.controls(for: stored) ?? ChatControls()
        controls.fast = answer == "fast"
        ChatControlStore.shared.set(controls, for: stored)
        return controls
    }

    /// One `config.set` on a stored session's live runtime; the value Hermes says it now has.
    private func setControl(_ key: String, to value: String, stored: String) async throws -> String {
        try await ensureConnected()
        return try await withLiveSession(stored: stored) { runtime in
            try await self.call("config.set", params: .object([
                "session_id": .string(runtime), "key": .string(key), "value": .string(value)]))["value"]?.string ?? ""
        }
    }

    /// Moves a stored session into a project: its working directory becomes that folder, which
    /// is what puts a conversation in a project (`session.workspace.move`, as Hermes Desktop's
    /// "Move to project" does). The folder has to exist on the server.
    func moveSession(stored: String, toFolder path: String) async throws {
        try await ensureConnected()
        _ = try await call("session.workspace.move", params: .object(["session_key": .string(stored), "cwd": .string(path)]))
    }
}

extension HermesServeClient.Project {
    /// The projects a conversation can be moved into: the ones that are a folder, and not the
    /// one it is in already (`cwd` is the conversation's own folder, when the list said).
    static func moveTargets(in projects: [HermesServeClient.Project], from cwd: String?) -> [HermesServeClient.Project] {
        projects.filter { project in
            guard !project.isHome, let path = project.path, !path.isEmpty else { return false }
            guard let cwd, !cwd.isEmpty else { return true }
            return cwd != path && !cwd.hasPrefix(path.hasSuffix("/") ? path : path + "/")
        }
    }
}

#if DEBUG
/// Switches made of sample data, for the model menu's own look (`-echo.demoChatControls`) and its
/// UI test: a conversation whose model has a fast mode.
final class DemoChatControls: ChatControlling {
    static let session = "demo-session"
    private var controls = ChatControls(approvalMode: "manual")

    func chatControls(stored: String) async throws -> ChatControls { controls }

    func setAutoApprove(_ on: Bool, stored: String) async throws -> ChatControls {
        controls.autoApprove = on
        ChatControlStore.shared.set(controls, for: stored)
        return controls
    }

    func setFast(_ on: Bool, stored: String) async throws -> ChatControls {
        controls.fast = on
        ChatControlStore.shared.set(controls, for: stored)
        return controls
    }
}
#endif
