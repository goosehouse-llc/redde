import Foundation
import Observation

/// The notification plugin on a Hermes, seen and installed through its Dashboard: the routes its
/// own Plugins page uses, the same in Hermes 0.21.0, 0.21.3 and 0.21.5. With them a phone that
/// is signed in to the Dashboard can put the plugin there itself, which until now took a
/// terminal on that machine.
nonisolated enum PushPlugin {
    static let name = "redde-push"
    /// What Hermes is asked to install: this repository's folder on GitHub, as the command does.
    static let identifier = "goosehouse-llc/redde/companion/hermes-plugin/redde-push"
    /// The plugin's version in this build's source (`companion/hermes-plugin/redde-push/plugin.yaml`):
    /// one on a Hermes that is older than this can be brought up to it.
    static let version = "1.1.0"

    /// Whether the plugin is on a Hermes, and in what state.
    struct State: Equatable, Sendable {
        var installed = false
        var version: String?
        /// Hermes loads it (it can be installed and switched off).
        var enabled = false

        /// Older than the one this build of the app goes with.
        var isOutdated: Bool { installed && version.map { PushPlugin.isOlder($0, than: PushPlugin.version) } == true }

        /// From the Dashboard's plugin list (`GET /api/dashboard/plugins/hub`).
        init(hub: JSONValue) {
            guard let entry = hub["plugins"]?.array?.first(where: { $0["name"]?.string == PushPlugin.name }) else { return }
            installed = true
            version = entry["version"]?.string?.nilIfEmpty
            enabled = entry["runtime_status"]?.string == "enabled"
        }

        init(installed: Bool = false, version: String? = nil, enabled: Bool = false) {
            self.installed = installed; self.version = version; self.enabled = enabled
        }
    }

    /// How an install left things.
    enum Outcome: Equatable, Sendable {
        /// The running Hermes has loaded it: pairing can go ahead (Hermes 0.21.5 and later).
        case running
        /// It is on disk and switched on, and Hermes loads it when it next starts: the gateway
        /// and the Dashboard have to be restarted on that machine (0.21.0 and 0.21.3).
        case needsRestart

        /// From what the install answered: live when Hermes says nothing needs a restart and
        /// names the plugin's command among what it switched on.
        init(answer: JSONValue) {
            let commands = answer["activation"]?["activated_now"]?["gateway_commands"]?.array?.compactMap(\.string) ?? []
            self = answer["restart_required"]?.bool == false && commands.contains(PushPlugin.name) ? .running : .needsRestart
        }
    }

    /// "1.0.2" is older than "1.1.0"; a version that can't be read is not called older.
    static func isOlder(_ version: String, than other: String) -> Bool {
        func parts(_ text: String) -> [Int]? {
            let numbers = text.split(separator: ".").map { Int($0) }
            return numbers.isEmpty || numbers.contains(nil) ? nil : numbers.compactMap { $0 }
        }
        guard let a = parts(version), let b = parts(other) else { return false }
        for i in 0 ..< max(a.count, b.count) {
            let (x, y) = (i < a.count ? a[i] : 0, i < b.count ? b[i] : 0)
            if x != y { return x < y }
        }
        return false
    }

    /// A refusal in the screen's words.
    static func explain(_ error: Error) -> String {
        guard case let TransportError.http(status, body) = error else { return error.localizedDescription }
        if body.localizedCaseInsensitiveContains("timed out") {
            return "Hermes couldn't download the plugin in time. It fetches it from GitHub, which can be slow the first time: try again."
        }
        if status == 401 { return "The Hermes Dashboard login was refused." }
        return body.isEmpty ? "The server answered \(status)." : body
    }
}

/// What the notifications screen asks of a server about the plugin. `HermesServeClient` in the
/// app; a stand-in for tests.
protocol PushPluginManaging: AnyObject {
    func pushPlugin() async throws -> PushPlugin.State
    /// Has Hermes download the plugin and switch it on; `replacing` an older one that is there.
    func installPushPlugin(replacing: Bool) async throws -> PushPlugin.Outcome
}

extension HermesServeClient: PushPluginManaging {
    func pushPlugin() async throws -> PushPlugin.State {
        PushPlugin.State(hub: try await restJSON("GET", "api/dashboard/plugins/hub"))
    }

    func installPushPlugin(replacing: Bool) async throws -> PushPlugin.Outcome {
        // Hermes clones the repository (it allows itself a minute) and then loads the plugin.
        let answer = try await restJSON("POST", "api/dashboard/agent-plugins/install", body: .object([
            "identifier": .string(PushPlugin.identifier), "force": .bool(replacing), "enable": .bool(true)]), timeout: 150)
        return PushPlugin.Outcome(answer: answer)
    }
}

/// The plugin's line on the notifications screen: whether it is on the server the app is signed
/// in to, and putting it there.
@Observable
final class PushPluginModel {
    enum Phase: Equatable {
        /// Not asked yet, or asking.
        case checking
        case known(PushPlugin.State)
        /// The Dashboard couldn't be asked: the command for a terminal is the way.
        case unknown(String)
    }

    @ObservationIgnored private let manager: any PushPluginManaging
    private(set) var phase = Phase.checking
    private(set) var installing = false
    /// How the install this screen ran left things; nil before one has.
    private(set) var outcome: PushPlugin.Outcome?
    var problem: String?

    init(manager: any PushPluginManaging) { self.manager = manager }

    var state: PushPlugin.State? { if case let .known(state) = phase { state } else { nil } }

    /// Something to install: it isn't there, it is older than this build's, or it is switched off.
    var offersInstall: Bool { state.map { !$0.installed || $0.isOutdated || !$0.enabled } ?? false }

    /// What the button says for the state the plugin is in.
    var installTitle: String {
        guard let state, state.installed else { return "Install the Plugin" }
        return state.isOutdated ? "Update the Plugin" : "Turn the Plugin On"
    }

    func refresh() async {
        do {
            phase = .known(try await manager.pushPlugin())
        } catch {
            if state == nil { phase = .unknown(PushPlugin.explain(error)) }
        }
    }

    /// Installs, updates or switches on, whichever the state calls for.
    func install() async {
        guard !installing else { return }
        installing = true
        problem = nil
        defer { installing = false }
        do {
            outcome = try await manager.installPushPlugin(replacing: state?.installed == true)
            await refresh()
        } catch {
            problem = PushPlugin.explain(error)
        }
    }
}

#if DEBUG
/// A server whose plugin state is made up, for the notifications screen's own look and its UI
/// test (`-echo.demoPlugin missing|old|off|there`). Installing takes a moment and leaves the
/// plugin running, as on Hermes 0.21.5; with `restart` after the state, as on the older ones.
final class DemoPushPlugin: PushPluginManaging {
    private var state: PushPlugin.State
    private let needsRestart: Bool

    init(_ named: String, needsRestart: Bool = false) {
        state = switch named {
        case "old": PushPlugin.State(installed: true, version: "1.0.0", enabled: true)
        case "off": PushPlugin.State(installed: true, version: PushPlugin.version, enabled: false)
        case "there": PushPlugin.State(installed: true, version: PushPlugin.version, enabled: true)
        default: PushPlugin.State()
        }
        self.needsRestart = needsRestart
    }

    func pushPlugin() async throws -> PushPlugin.State { state }

    func installPushPlugin(replacing: Bool) async throws -> PushPlugin.Outcome {
        try await Task.sleep(for: .milliseconds(600))
        state = PushPlugin.State(installed: true, version: PushPlugin.version, enabled: true)
        return needsRestart ? .needsRestart : .running
    }
}
#endif
