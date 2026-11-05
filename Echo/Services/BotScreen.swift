import CryptoKit
import Foundation
import Network
import Observation

/// Hermes's Bot Screen (code in 0.21.5, announced in 0.22.0; `tools/bot_desktop/`): a profile's
/// own Linux desktop (TigerVNC Xvnc + Xfce) that its `computer_use` tool and, when the browser
/// runs headed, its browser draw on. Redde watches it and takes it over the way Hermes Desktop
/// does, on the Dashboard only (the Hermes API has none of it):
///
/// - `display.status` / `.start` / `.thumbnail` / `.observe` / `.lease.acquire` / `.lease.release`
///   over `/api/ws`, each naming the profile (`tui_gateway/methods_display.py`);
/// - `display.observe` mints a single-use 30 s ticket and a viewer id for this connection; the
///   picture streams as raw RFB 3.8 (no password) over `wss://…/api/display/ws?display_ticket=…`
///   (`hermes_cli/web_routers/display.py`), drawn here by noVNC in a web view;
/// - the lease says who drives: the agent, or the one person who took over. While a person holds
///   it, the agent's screen tools refuse (`human_has_control`) and the thumbnail is withheld;
///   input from anyone else is dropped by the bridge. A clean close (1000/1001) hands back; a
///   dropped link keeps the person's hold, so they can come back to a half-typed login.
nonisolated enum BotScreen {
    /// Who drives the screen (`DisplayLease`).
    struct Lease: Equatable, Sendable {
        var holder: String = "agent"
        /// The first 12 hex of sha256(viewer id) of the person holding it; the id itself never travels.
        var viewerHash: String?
        var reason: String = ""
        var epoch: Int = 0

        var humanHolds: Bool { holder == "human" }

        init(holder: String = "agent", viewerHash: String? = nil, reason: String = "", epoch: Int = 0) {
            self.holder = holder; self.viewerHash = viewerHash; self.reason = reason; self.epoch = epoch
        }

        init(_ j: JSONValue?) {
            holder = j?["holder"]?.string ?? "agent"
            viewerHash = j?["viewer_hash"]?.string?.nilIfEmpty
            reason = j?["reason"]?.string ?? ""
            epoch = j?["epoch"]?.int ?? 0
        }
    }

    /// A profile's screen as `display.status` reports it (`DisplayStatus`).
    struct Status: Equatable, Sendable {
        var profile: String = ""
        var profileKey: String = ""
        /// A Linux gateway host; Bot Desktop exists nowhere else.
        var supported = false
        var installed = false
        var missing: [String] = []
        var running = false
        var geometry: String = ""
        var installCommand: String?
        /// Why starting it would be refused now (not enough memory), as Hermes words it.
        var blocker: String?
        var lease = Lease()

        init() {}

        init(_ j: JSONValue) {
            profile = j["profile"]?.string ?? ""
            profileKey = j["profile_key"]?.string ?? ""
            supported = j["supported"]?.bool ?? false
            installed = j["installed"]?.bool ?? false
            missing = j["missing"]?.array?.compactMap(\.string) ?? []
            running = j["running"]?.bool ?? false
            geometry = j["geometry"]?.string ?? ""
            installCommand = j["install_command"]?.string?.nilIfEmpty
            blocker = j["blocker"]?.string?.nilIfEmpty
            lease = Lease(j["lease"])
        }
    }

    /// Whether this chat's agent has a screen to watch, and if not, why, in one line.
    enum Availability: Equatable, Sendable {
        case checking
        case ready(Status)
        /// There, but not running: Watch starts it.
        case stopped(Status)
        case notLinux
        case notInstalled(missing: [String], command: String?)
        case blocked(String)
        /// The Hermes predates `display.*` (before 0.21.5).
        case olderHermes
        /// The Hermes API connection: Bot Screen is the Dashboard's alone.
        case notDashboard
        case unreachable(String)

        var status: Status? {
            switch self {
            case let .ready(s), let .stopped(s): s
            default: nil
            }
        }

        /// The one line saying why there's no screen, with what would give one.
        var explanation: String? {
            switch self {
            case .checking, .ready, .stopped: nil
            case .notLinux:
                String(localized: "Bot Screen runs only when Hermes is on a Linux computer. This Hermes isn't.", comment: "Agent's Screen: why there is no screen")
            case let .notInstalled(missing, command):
                command.map { String(localized: "This Hermes needs the desktop installed first (\($0)), or Hermes Desktop's Screen pane can install it.", comment: "Agent's Screen: what to install") }
                    ?? String(localized: "This Hermes is missing \(missing.joined(separator: ", ")) for its screen.", comment: "Agent's Screen: what is missing")
            case let .blocked(reason):
                String(localized: "Hermes won't start the screen now: \(reason)", comment: "Agent's Screen: the host refused to start it")
            case .olderHermes:
                String(localized: "Watching the agent's screen needs Hermes 0.22 or later on the server.", comment: "Agent's Screen: the server's Hermes is too old")
            case .notDashboard:
                String(localized: "The agent's screen comes over the Hermes Dashboard. Connect with the Dashboard in Settings to watch it.", comment: "Agent's Screen: on the Hermes API connection")
            case let .unreachable(message):
                String(localized: "Couldn't reach the screen: \(message)", comment: "Agent's Screen: an error")
            }
        }
    }

    static func availability(_ status: Status) -> Availability {
        if !status.supported { return .notLinux }
        if !status.installed { return .notInstalled(missing: status.missing, command: status.installCommand) }
        if status.running { return .ready(status) }
        if let blocker = status.blocker { return .blocked(blocker) }
        return .stopped(status)
    }

    /// The error a Hermes without `display.*` answers with (JSON-RPC method not found).
    static func isMissingMethod(_ error: Error) -> Bool {
        guard let rpc = error as? HermesServeClient.RPCError else { return false }
        let message = rpc.message.lowercased()
        return rpc.code == -32601 || message.contains("method not found") || message.contains("unknown method")
    }

    /// Who drives, as this viewer sees it.
    enum Control: Equatable, Sendable {
        case agent
        case you
        /// Someone else took over (another device, Hermes Desktop): watch only.
        case someoneElse
    }

    static func control(_ lease: Lease, viewerHash: String?) -> Control {
        guard lease.humanHolds else { return .agent }
        guard let viewerHash, lease.viewerHash == viewerHash else { return .someoneElse }
        return .you
    }

    /// `viewer_hash` as the lease carries it: the first 12 hex digits of sha256(viewer id).
    static func viewerHash(_ viewerID: String) -> String {
        SHA256.hash(data: Data(viewerID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// The stream's address: the Dashboard's, on `path`, with the ticket in the query (the only
    /// place the bridge reads it).
    static func socketURL(baseURL: URL, path: String, ticket: String) -> URL? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var comps = URLComponents(url: baseURL.appending(path: trimmed), resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        comps.queryItems = [URLQueryItem(name: "display_ticket", value: ticket)]
        return comps.url
    }

    /// How the stream ended, from its close code.
    enum Ended: Equatable, Sendable {
        /// 4000: someone else took over; watch again on a fresh ticket.
        case controlTaken
        /// 4001: the screen stopped.
        case screenGone
        /// 4401: the ticket was spent or stale; observe again.
        case badTicket
        /// 4403: the server's Host/Origin check refused the socket.
        case refused
        /// 1000/1001: closed on purpose.
        case closed
        /// Anything else: the link dropped.
        case dropped

        init(code: Int) {
            switch code {
            case 4000: self = .controlTaken
            case 4001: self = .screenGone
            case 4401: self = .badTicket
            case 4403: self = .refused
            case 1000, 1001: self = .closed
            default: self = .dropped
            }
        }
    }

    /// noVNC's picture quality (0–9) and compression (0–9) for the link: a phone on cellular or
    /// Low Data Mode gets the small picture.
    static func quality(expensive: Bool) -> (quality: Int, compression: Int) {
        expensive ? (3, 7) : (6, 2)
    }
}

/// The calls Bot Screen makes of the Dashboard client, so the session can be tried without one.
@MainActor
protocol BotScreenHost: AnyObject {
    @discardableResult
    func call(_ method: String, params: JSONValue, timeout: TimeInterval) async throws -> JSONValue
    func addListener(_ listener: @escaping (HermesServeClient.Event) -> Void) -> UUID
    func removeListener(_ id: UUID)
    func ensureConnected() async throws
}

extension HermesServeClient: BotScreenHost {}

/// One open Agent's Screen: the profile's status, its thumbnail, the viewer this connection was
/// given, and who drives. Lives as long as the screen is on view; nothing runs after it closes.
@MainActor @Observable
final class BotScreenSession {
    private(set) var availability: BotScreen.Availability = .checking
    private(set) var thumbnail: Data?
    /// The thumbnail is withheld while a person drives (it may show them typing).
    private(set) var thumbnailWithheld = false
    private(set) var lease = BotScreen.Lease()
    private(set) var viewerID: String?
    private(set) var viewerHash: String?
    private(set) var busy = false
    /// A line about the last thing that went wrong, or a takeover by someone else.
    var notice: String?
    /// Handed back just now: the chat offers "Continue".
    private(set) var handedBack = false

    var control: BotScreen.Control { BotScreen.control(lease, viewerHash: viewerHash) }

    let profile: String?
    private let host: (any BotScreenHost)?
    private let isDashboard: Bool
    private var listener: UUID?

    init(profile: String?, host: (any BotScreenHost)?, isDashboard: Bool) {
        self.profile = profile
        self.host = host
        self.isDashboard = isDashboard
    }

    /// A screen to show in screenshots and previews (`-echo.demoBotScreen`).
    static func demo(thumbnail: Data?, control: BotScreen.Control = .agent) -> BotScreenSession {
        let session = BotScreenSession(profile: nil, host: nil, isDashboard: true)
        var status = BotScreen.Status()
        status.supported = true; status.installed = true; status.running = true; status.geometry = "1280x800"
        session.availability = .ready(status)
        session.thumbnail = thumbnail
        if control == .you {
            session.viewerID = "demo"; session.viewerHash = BotScreen.viewerHash("demo")
            session.lease = BotScreen.Lease(holder: "human", viewerHash: session.viewerHash, epoch: 1)
        } else if control == .someoneElse {
            session.lease = BotScreen.Lease(holder: "human", viewerHash: "000000000000", epoch: 1)
        }
        return session
    }

    var isDemo: Bool { host == nil && isDashboard }

    private func params(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        var fields = extra
        if let profile, !profile.isEmpty { fields["profile"] = .string(profile) }
        return .object(fields)
    }

    /// Asks what there is, and listens for the lease and the screen changing while on view.
    func open() async {
        guard !isDemo else { return }
        guard isDashboard, let host else { availability = .notDashboard; return }
        if listener == nil {
            listener = host.addListener { [weak self] event in self?.heard(event) }
        }
        await refreshStatus()
    }

    func close() {
        if let listener { host?.removeListener(listener) }
        listener = nil
    }

    func refreshStatus() async {
        guard let host else { return }
        do {
            try await host.ensureConnected()
            let status = BotScreen.Status(try await host.call("display.status", params: params(), timeout: 20))
            apply(status)
        } catch {
            availability = BotScreen.isMissingMethod(error) ? .olderHermes : .unreachable(error.localizedDescription)
        }
    }

    private func apply(_ status: BotScreen.Status) {
        availability = BotScreen.availability(status)
        lease = status.lease
    }

    /// Starts a screen that's there but stopped (`display.start` blocks until it is up).
    func start() async {
        guard let host, case .stopped = availability else { return }
        busy = true
        defer { busy = false }
        do {
            apply(BotScreen.Status(try await host.call("display.start", params: params(), timeout: 60)))
        } catch {
            notice = error.localizedDescription
        }
    }

    /// One still of the screen (≤ 960×600 JPEG): the picture shown until Watch Live.
    func refreshThumbnail() async {
        guard let host, case .ready = availability else { return }
        do {
            let result = try await host.call("display.thumbnail", params: params(), timeout: 15)
            if result["suppressed"]?.string != nil {
                thumbnailWithheld = true
                return
            }
            thumbnailWithheld = false
            if let url = result["data_url"]?.string, let data = Self.decode(dataURL: url) { thumbnail = data }
        } catch {
            if BotScreen.isMissingMethod(error) { return }
            notice = error.localizedDescription
        }
    }

    /// A ticket for the stream, keeping this connection's viewer id across reconnects.
    func observe() async throws -> (ticket: String, path: String) {
        guard let host else { throw TransportError.unreachable(String(localized: "not connected to Hermes Dashboard")) }
        var extra: [String: JSONValue] = [:]
        if let viewerID { extra["viewer_id"] = .string(viewerID) }
        let result = try await host.call("display.observe", params: params(extra), timeout: 20)
        guard let ticket = result["ticket"]?.string, let id = result["viewer_id"]?.string else {
            throw TransportError.malformed("display.observe gave no ticket")
        }
        viewerID = id
        viewerHash = BotScreen.viewerHash(id)
        apply(BotScreen.Status(result))
        return (ticket, result["path"]?.string ?? "/api/display/ws")
    }

    /// Take Over: the lease is this viewer's until handed back; the agent's screen tools wait.
    func takeOver() async {
        guard let host, let viewerID else { return }
        busy = true
        defer { busy = false }
        handedBack = false
        do {
            let result = try await host.call("display.lease.acquire",
                                             params: params(["viewer_id": .string(viewerID),
                                                             "reason": .string(String(localized: "Taken over from Redde", comment: "The reason Hermes shows for a takeover"))]),
                                             timeout: 20)
            lease = BotScreen.Lease(result["lease"])
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Hand Back: the agent drives again.
    func handBack() async {
        guard let host, let viewerID else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await host.call("display.lease.release", params: params(["viewer_id": .string(viewerID)]), timeout: 20)
            lease = BotScreen.Lease(result["lease"])
            handedBack = true
        } catch {
            notice = error.localizedDescription
        }
    }

    func dismissContinue() { handedBack = false }

    /// The stream ended with a code: what to tell the person.
    func ended(_ how: BotScreen.Ended) {
        switch how {
        case .controlTaken:
            notice = String(localized: "Someone else took over the screen. You're watching again.", comment: "Agent's Screen")
        case .screenGone:
            notice = String(localized: "The screen stopped.", comment: "Agent's Screen")
            Task { await refreshStatus() }
        case .refused:
            notice = String(localized: "The server refused the screen's connection. A proxy in front of the Dashboard has to pass its Host header through.", comment: "Agent's Screen: close code 4403")
        case .badTicket, .closed, .dropped:
            break
        }
    }

    /// `display.lease` and `display.status` for this profile's screen.
    func heard(_ event: HermesServeClient.Event) {
        guard event.type == "display.lease" || event.type == "display.status" else { return }
        let key = event.payload["profile_key"]?.string
        if let mine = availability.status?.profileKey, !mine.isEmpty, let key, key != mine { return }
        if event.type == "display.lease" {
            let was = control
            lease = BotScreen.Lease(event.payload["lease"])
            if was == .you, control == .someoneElse {
                notice = String(localized: "Someone else took over the screen. You're watching again.", comment: "Agent's Screen")
            }
        } else {
            apply(BotScreen.Status(event.payload))
        }
    }

    nonisolated static func decode(dataURL: String) -> Data? {
        guard let comma = dataURL.firstIndex(of: ","), dataURL[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
    }
}

/// The picture stream: binary RFB frames between the Dashboard's bridge and the noVNC page.
/// Frames from the server are gathered and handed on together (`flush`) so a busy screen costs
/// one hop into the web view per batch, not one per frame.
@MainActor
final class BotScreenStream {
    private var task: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var pending = Data()
    private var flushScheduled = false
    /// Bytes from the server, in order, a batch at a time.
    var onBytes: ((Data) -> Void)?
    /// The stream ended, with how.
    var onEnd: ((BotScreen.Ended) -> Void)?

    var isOpen: Bool { task != nil }

    func open(_ task: URLSessionWebSocketTask) {
        close(handBack: false)
        self.task = task
        receiver = Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    let data: Data
                    switch message {
                    case let .data(bytes): data = bytes
                    case let .string(text): data = Data(text.utf8)
                    @unknown default: continue
                    }
                    await self?.received(data)
                } catch {
                    let code = task.closeCode.rawValue
                    await self?.finished(task, code: code == 0 ? 1006 : code)
                    return
                }
            }
        }
    }

    private func received(_ data: Data) {
        pending.append(data)
        guard !flushScheduled else { return }
        flushScheduled = true
        // One hop per ~frame: what came in meanwhile goes with it.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(12))
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = Data()
        onBytes?(batch)
    }

    private func finished(_ ended: URLSessionWebSocketTask, code: Int) {
        guard ended === task else { return }
        flush()
        task = nil
        receiver = nil
        onEnd?(BotScreen.Ended(code: code))
    }

    /// Input and replies from the viewer (noVNC), passed on as they are.
    func send(_ data: Data) {
        task?.send(.data(data)) { _ in }
    }

    /// Closing on purpose hands control back (1000); dropping the link (leaving the app while in
    /// control) keeps it, so the person can come back to what they were typing.
    func close(handBack: Bool) {
        receiver?.cancel()
        receiver = nil
        if let task {
            if handBack { task.cancel(with: .normalClosure, reason: nil) } else { task.cancel() }
        }
        task = nil
        pending = Data()
    }
}

/// Whether the phone's link is costly (cellular, Low Data Mode): the stream asks for a smaller
/// picture there. Its handler is made here, in nonisolated code (the MainActor-default build would
/// otherwise trap it on the monitor's queue).
nonisolated final class LinkCost: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.goosehouse.echo.linkcost", qos: .utility)

    init(_ changed: @escaping @MainActor @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor in changed(expensive) }
        }
        monitor.start(queue: queue)
    }

    func stop() { monitor.cancel() }
}
