import Foundation
import Observation

// MARK: - Cron

/// One scheduled job, normalized from either backend. `hermes serve` returns the raw store
/// record (`id`, structured `schedule` + `schedule_display`); the API server does the same;
/// the gateway's `cron.manage` RPC flattens it (`job_id`, `schedule` as text). Decode all three.
nonisolated struct CronJob: Identifiable, Equatable, Sendable {
    enum State: String, Sendable { case scheduled, paused, completed, error }
    var id: String
    var name: String
    var prompt: String
    var schedule: String
    var enabled: Bool
    var state: State
    var nextRunAt: Date?
    var lastRunAt: Date?
    var lastStatus: String?
    var lastError: String?
    var deliver: String?
    var model: String?

    init?(_ j: JSONValue) {
        guard let id = j["id"]?.string ?? j["job_id"]?.string else { return nil }
        self.id = id
        name = j["name"]?.string ?? ""
        prompt = j["prompt"]?.string ?? j["prompt_preview"]?.string ?? ""
        schedule = j["schedule_display"]?.string ?? j["schedule"]?.string ?? j["schedule"]?["display"]?.string ?? ""
        enabled = j["enabled"]?.bool ?? true
        let raw = j["state"]?.string ?? ""
        // The scheduler treats `enabled` as authoritative; terminal states survive either way.
        state = raw == "completed" ? .completed : raw == "error" ? .error : enabled ? .scheduled : .paused
        nextRunAt = Self.date(j["next_run_at"])
        lastRunAt = Self.date(j["last_run_at"])
        lastStatus = j["last_status"]?.string
        lastError = j["last_error"]?.string
        deliver = j["deliver"]?.string
        model = j["model"]?.string
    }

    /// ISO8601DateFormatter is expensive to create; three fixed instances cover the shapes seen.
    /// The formatter is documented thread-safe, hence the unchecked declaration.
    nonisolated(unsafe) private static let isoFormatters: [ISO8601DateFormatter] = {
        let optionSets: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
            [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime],
        ]
        return optionSets.map { opts in let f = ISO8601DateFormatter(); f.formatOptions = opts; return f }
    }()

    nonisolated static func date(_ v: JSONValue?) -> Date? {
        if let n = v?.number { return Date(timeIntervalSince1970: n) }
        guard let s = v?.string else { return nil }
        for f in isoFormatters { if let d = f.date(from: s) { return d } }
        return nil
    }
}

/// A past run of a job (serve only): cron runs are ordinary sessions with source "cron".
nonisolated struct CronRun: Identifiable, Sendable {
    var id: String
    var title: String?
    var preview: String?
    var startedAt: Date?
    var active: Bool

    init?(_ j: JSONValue) {
        guard let id = j["id"]?.string ?? j["session_id"]?.string else { return nil }
        self.id = id
        title = j["title"]?.string
        preview = j["preview"]?.string
        startedAt = (j["started_at"] ?? j["created_at"]).flatMap(CronJob.date)
        active = j["is_active"]?.bool ?? false
    }
}

/// Where a job's output goes: "local" (save only), "origin", or a gateway platform id.
nonisolated struct CronDeliveryTarget: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var homeTargetSet: Bool
    init(id: String, name: String, homeTargetSet: Bool = true) { self.id = id; self.name = name; self.homeTargetSet = homeTargetSet }
    init?(_ j: JSONValue) {
        guard let id = j["id"]?.string else { return nil }
        self.id = id
        name = j["name"]?.string ?? id
        homeTargetSet = j["home_target_set"]?.bool ?? true
    }
    static let builtIn = [CronDeliveryTarget(id: "local", name: "Local (save only)"), CronDeliveryTarget(id: "origin", name: "Where the job was created")]
}

/// A prebuilt job template from the gateway's catalog: a form of slots that fills a schedule
/// and prompt. Serve only.
nonisolated struct CronBlueprint: Identifiable, Equatable, Sendable {
    nonisolated struct Field: Identifiable, Equatable, Sendable {
        var name: String
        var type: String          // enum | time | text | …
        var label: String
        var defaultValue: String
        var options: [String]
        var optional: Bool
        var help: String?
        var id: String { name }
    }
    var key: String
    var title: String
    var description: String
    var category: String
    var scheduleHuman: String
    var fields: [Field]
    var id: String { key }

    init?(_ j: JSONValue) {
        guard let key = j["key"]?.string else { return nil }
        self.key = key
        title = j["title"]?.string ?? key
        description = j["description"]?.string ?? ""
        category = j["category"]?.string ?? ""
        scheduleHuman = j["scheduleHuman"]?.string ?? j["schedule"]?.string ?? ""
        fields = (j["fields"]?.array ?? []).compactMap { f in
            guard let name = f["name"]?.string else { return nil }
            let def: String = f["default"]?.string ?? f["default"]?.number.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? ""
            return Field(name: name, type: f["type"]?.string ?? "text", label: f["label"]?.string ?? name, defaultValue: def,
                         options: (f["options"]?.array ?? []).compactMap { $0.string ?? $0.number.map { String(Int($0)) } },
                         optional: f["optional"]?.bool ?? false, help: f["help"]?.string)
        }
    }
}

/// Which server answers cron calls. Both are used through the same interface.
enum CronBackend {
    case serve            // hermes serve dashboard REST, /api/cron/jobs
    case apiServer(HermesSessionsAPI)   // API server, /api/jobs

    /// Prefer the dashboard when its credentials exist; otherwise the ledger API key.
    static func current() -> CronBackend? {
        let settings = Settings.shared
        if settings.transport == .hermesServe, HermesServeClient.shared.hasCredentials { return .serve }
        if let url = settings.gatewayBaseURL, let key = settings.gatewayAPIKey, !key.isEmpty {
            return .apiServer(HermesSessionsAPI(baseURL: url, apiKey: key))
        }
        if HermesServeClient.shared.hasCredentials, settings.serveBaseURL != nil { return .serve }
        return nil
    }

    var supportsRunHistory: Bool { if case .serve = self { return true } else { return false } }

    func list() async throws -> [CronJob] {
        switch self {
        case .serve:
            let json = try await HermesServeClient.shared.restJSON("GET", "api/cron/jobs?profile=all")
            return (json.array ?? json["jobs"]?.array ?? []).compactMap(CronJob.init)
        case let .apiServer(api):
            let json = try await api.requestJSON("GET", "api/jobs", query: [.init(name: "include_disabled", value: "true")])
            return (json["jobs"]?.array ?? json.array ?? []).compactMap(CronJob.init)
        }
    }

    var supportsBlueprints: Bool { supportsRunHistory }

    /// Delivery targets: the dashboard lists configured platforms; the API server has no such
    /// endpoint, so it gets the two built-ins plus whatever is typed.
    func deliveryTargets() async -> [CronDeliveryTarget] {
        guard case .serve = self,
              let json = try? await HermesServeClient.shared.restJSON("GET", "api/cron/delivery-targets") else { return CronDeliveryTarget.builtIn }
        let targets = (json["targets"]?.array ?? []).compactMap(CronDeliveryTarget.init)
        return targets.isEmpty ? CronDeliveryTarget.builtIn : targets
    }

    func blueprints() async throws -> [CronBlueprint] {
        guard case .serve = self else { return [] }
        let json = try await HermesServeClient.shared.restJSON("GET", "api/cron/blueprints")
        return (json["blueprints"]?.array ?? []).compactMap(CronBlueprint.init)
    }

    func instantiate(blueprint key: String, values: [String: String]) async throws {
        guard case .serve = self else { throw TransportError.malformed("Blueprints need hermes serve") }
        let body: JSONValue = .object(["blueprint": .string(key), "values": .object(values.mapValues { .string($0) })])
        _ = try await HermesServeClient.shared.restJSON("POST", "api/cron/blueprints/instantiate", body: body)
    }

    func create(name: String, schedule: String, prompt: String, deliver: String? = nil) async throws {
        var fields: [String: JSONValue] = ["name": .string(name), "schedule": .string(schedule), "prompt": .string(prompt)]
        if let deliver, !deliver.isEmpty { fields["deliver"] = .string(deliver) }
        let body: JSONValue = .object(fields)
        switch self {
        case .serve: _ = try await HermesServeClient.shared.restJSON("POST", "api/cron/jobs", body: body)
        case let .apiServer(api): _ = try await api.requestJSON("POST", "api/jobs", body: body)
        }
    }

    func update(_ id: String, name: String, schedule: String, prompt: String, deliver: String? = nil) async throws {
        var dict: [String: JSONValue] = ["name": .string(name), "schedule": .string(schedule), "prompt": .string(prompt)]
        if let deliver, !deliver.isEmpty { dict["deliver"] = .string(deliver) }
        let fields: JSONValue = .object(dict)
        switch self {
        case .serve: _ = try await HermesServeClient.shared.restJSON("PUT", "api/cron/jobs/\(id)", body: .object(["updates": fields]))
        case let .apiServer(api): _ = try await api.requestJSON("PATCH", "api/jobs/\(id)", body: fields)
        }
    }

    func setPaused(_ id: String, _ paused: Bool) async throws {
        let verb = paused ? "pause" : "resume"
        switch self {
        case .serve: _ = try await HermesServeClient.shared.restJSON("POST", "api/cron/jobs/\(id)/\(verb)")
        case let .apiServer(api): _ = try await api.requestJSON("POST", "api/jobs/\(id)/\(verb)")
        }
    }

    /// Runs the job now. On serve this blocks until the run finishes.
    func runNow(_ id: String) async throws {
        switch self {
        case .serve: _ = try await HermesServeClient.shared.restJSON("POST", "api/cron/jobs/\(id)/trigger", timeout: 600)   // blocks until the run ends
        case let .apiServer(api): _ = try await api.requestJSON("POST", "api/jobs/\(id)/run")
        }
    }

    func delete(_ id: String) async throws {
        switch self {
        case .serve: _ = try await HermesServeClient.shared.restJSON("DELETE", "api/cron/jobs/\(id)")
        case let .apiServer(api): _ = try await api.requestJSON("DELETE", "api/jobs/\(id)")
        }
    }

    func runs(_ id: String, limit: Int = 20) async throws -> [CronRun] {
        guard case .serve = self else { return [] }
        let json = try await HermesServeClient.shared.restJSON("GET", "api/cron/jobs/\(id)/runs?limit=\(limit)")
        return (json["runs"]?.array ?? []).compactMap(CronRun.init)
    }
}

// MARK: - Kanban (hermes serve dashboard plugin only)

nonisolated struct KanbanTask: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var body: String?
    var status: String
    var priority: Int
    var assignee: String?
    var tenant: String?
    var createdAt: Date?
    var startedAt: Date?
    var completedAt: Date?
    var latestSummary: String?
    var result: String?
    var sessionID: String?
    var commentCount: Int
    var lastFailure: String?

    init?(_ j: JSONValue) {
        guard let id = j["id"]?.string else { return nil }
        self.id = id
        title = j["title"]?.string ?? ""
        body = j["body"]?.string
        status = j["status"]?.string ?? "todo"
        priority = j["priority"]?.int ?? 0
        assignee = j["assignee"]?.string
        tenant = j["tenant"]?.string
        createdAt = j["created_at"]?.number.map { Date(timeIntervalSince1970: $0) }
        startedAt = j["started_at"]?.number.map { Date(timeIntervalSince1970: $0) }
        completedAt = j["completed_at"]?.number.map { Date(timeIntervalSince1970: $0) }
        latestSummary = j["latest_summary"]?.string
        result = j["result"]?.string
        sessionID = j["session_id"]?.string
        commentCount = j["comment_count"]?.int ?? 0
        lastFailure = j["last_failure_error"]?.string
    }
}

nonisolated struct KanbanComment: Identifiable, Sendable {
    var id: String
    var author: String
    var body: String
    var createdAt: Date?
    init?(_ j: JSONValue) {
        guard let id = (j["id"]?.string ?? j["id"]?.int.map(String.init)) else { return nil }
        self.id = id
        author = j["author"]?.string ?? ""
        body = j["body"]?.string ?? ""
        createdAt = j["created_at"]?.number.map { Date(timeIntervalSince1970: $0) }
    }
}

nonisolated struct KanbanColumn: Identifiable, Sendable {
    var name: String
    var tasks: [KanbanTask]
    var id: String { name }
}

/// The board's fixed status columns, in dispatcher order. `running` can't be set by hand.
enum KanbanStatus {
    static let columns = ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"]
    static let movable = ["triage", "todo", "scheduled", "ready", "blocked", "review", "done", "archived"]

    static func label(_ s: String) -> String {
        switch s {
        case "triage": "Triage"
        case "todo": "To do"
        case "scheduled": "Scheduled"
        case "ready": "Ready"
        case "running": "Running"
        case "blocked": "Blocked"
        case "review": "Review"
        case "done": "Done"
        case "archived": "Archived"
        default: s.capitalized
        }
    }

    static func icon(_ s: String) -> String {
        switch s {
        case "triage": "tray"
        case "todo": "circle"
        case "scheduled": "calendar"
        case "ready": "play.circle"
        case "running": "gearshape.2"
        case "blocked": "hand.raised"
        case "review": "eye"
        case "done": "checkmark.circle"
        case "archived": "archivebox"
        default: "circle"
        }
    }
}

struct KanbanClient {
    static var isAvailable: Bool {
        #if DEBUG
        if isDemo { return true }
        #endif
        return Settings.shared.serveBaseURL != nil && HermesServeClient.shared.hasCredentials
    }
    static let base = "api/plugins/kanban"

    struct Board: Sendable {
        var columns: [KanbanColumn]
        var latestEventID: Int
        var assignees: [String]
    }

    static func board() async throws -> Board {
        #if DEBUG
        if isDemo { return demoBoard() }
        #endif
        let json = try await HermesServeClient.shared.restJSON("GET", "\(base)/board")
        let columns = (json["columns"]?.array ?? []).compactMap { col -> KanbanColumn? in
            guard let name = col["name"]?.string else { return nil }
            return KanbanColumn(name: name, tasks: (col["tasks"]?.array ?? []).compactMap(KanbanTask.init))
        }
        return Board(columns: columns, latestEventID: json["latest_event_id"]?.int ?? 0,
                     assignees: (json["assignees"]?.array ?? []).compactMap(\.string))
    }

    /// Edit the card's own fields. Pass nil to leave a field alone.
    static func edit(_ id: String, title: String?, body: String?, priority: Int?, assignee: String?) async throws {
        var fields: [String: JSONValue] = [:]
        if let title { fields["title"] = .string(title) }
        if let body { fields["body"] = .string(body) }
        if let priority { fields["priority"] = .number(Double(priority)) }
        if let assignee { fields["assignee"] = .string(assignee) }
        guard !fields.isEmpty else { return }
        try await patch(id, fields)
    }

    /// Move with the context the server wants: a reason for Blocked/Scheduled, a summary for Review/Done.
    static func move(_ id: String, to status: String, reason: String? = nil, summary: String? = nil) async throws {
        var fields: [String: JSONValue] = ["status": .string(status)]
        if let reason, !reason.isEmpty { fields["block_reason"] = .string(reason) }
        if let summary, !summary.isEmpty { fields["summary"] = .string(summary) }
        try await patch(id, fields)
    }

    static func task(_ id: String) async throws -> (KanbanTask, [KanbanComment]) {
        let json = try await HermesServeClient.shared.restJSON("GET", "\(base)/tasks/\(id)")
        guard let t = json["task"].flatMap(KanbanTask.init) else { throw TransportError.malformed("no task") }
        return (t, (json["comments"]?.array ?? []).compactMap(KanbanComment.init))
    }

    static func create(title: String, body: String?, priority: Int, assignee: String?, ready: Bool) async throws -> String? {
        var fields: [String: JSONValue] = ["title": .string(title), "priority": .number(Double(priority)), "triage": .bool(!ready)]
        if let body, !body.isEmpty { fields["body"] = .string(body) }
        if let assignee, !assignee.isEmpty { fields["assignee"] = .string(assignee) }
        let json = try await HermesServeClient.shared.restJSON("POST", "\(base)/tasks", body: .object(fields))
        Task { try? await nudge() }
        return json["warning"]?.string
    }

    static func patch(_ id: String, _ fields: [String: JSONValue]) async throws {
        _ = try await HermesServeClient.shared.restJSON("PATCH", "\(base)/tasks/\(id)", body: .object(fields))
        Task { try? await nudge() }
    }

    static func delete(_ id: String) async throws {
        _ = try await HermesServeClient.shared.restJSON("DELETE", "\(base)/tasks/\(id)")
    }

    static func comment(_ id: String, _ text: String) async throws {
        _ = try await HermesServeClient.shared.restJSON("POST", "\(base)/tasks/\(id)/comments",
                                                        body: .object(["author": .string("redde"), "body": .string(text)]))
    }

    static func assignees() async throws -> [String] {
        let json = try await HermesServeClient.shared.restJSON("GET", "\(base)/assignees")
        return (json.array ?? json["assignees"]?.array ?? []).compactMap { $0.string ?? $0["name"]?.string }
    }

    /// Live board changes. The plugin exposes its own events socket; frames are
    /// `{"events":[{id, task_id, kind, payload, created_at}], "cursor": N}`. Falls back to a
    /// 15 s poll when the socket can't be opened (OAuth-only setups, old gateways).
    @MainActor @Observable
    final class LiveBoard {
        private var socket: URLSessionWebSocketTask?
        private var task: Task<Void, Never>?
        private(set) var isLive = false
        var onChange: (@MainActor ([String]) -> Void)?   // touched task ids (empty = refresh all)

        func start(since cursor: Int) {
            stop()
            task = Task { [weak self] in await Self.run(since: cursor, board: self) }
        }

        #if DEBUG
        /// Screenshot helper: the green live indicator without a socket.
        func showLiveForDemo() { isLive = true }
        #endif

        func stop() {
            task?.cancel(); task = nil
            socket?.cancel(with: .goingAway, reason: nil); socket = nil
            isLive = false
        }

        /// A view that is torn down without `stop()` (state discarded while a refresh was in
        /// flight) must not leave the loop polling the board for the life of the process.
        isolated deinit { stop() }

        /// Holds the board weakly: the loop only ever touches it between awaits, so releasing
        /// the board ends the loop instead of the loop keeping the board alive.
        private static func run(since: Int, board: LiveBoard?) async {
            weak let board = board
            var cursor = since
            var backoff: Double = 2
            while !Task.isCancelled, board != nil {
                do {
                    let ws = try await HermesServeClient.shared.openPluginSocket(
                        path: "\(KanbanClient.base)/events", query: [.init(name: "since", value: String(cursor))])
                    guard board != nil else { ws.cancel(with: .goingAway, reason: nil); return }
                    board?.socket = ws
                    board?.isLive = true
                    backoff = 2
                    while !Task.isCancelled {
                        let frame = try await ws.receive()
                        guard board != nil else { ws.cancel(with: .goingAway, reason: nil); return }
                        let data: Data
                        switch frame {
                        case let .data(d): data = d
                        case let .string(s): data = Data(s.utf8)
                        @unknown default: continue
                        }
                        guard let json = try? JSONValue.parse(data) else { continue }
                        if let c = json["cursor"]?.int { cursor = c }
                        let ids = (json["events"]?.array ?? []).compactMap { $0["task_id"]?.string }
                        if !ids.isEmpty || json["events"]?.array?.isEmpty == false { board?.onChange?(Array(Set(ids))) }
                    }
                } catch {
                    guard board != nil, !Task.isCancelled else { return }
                    board?.isLive = false
                    board?.socket = nil
                    // Poll while the socket is down, then try to reopen with growing backoff.
                    board?.onChange?([])
                    try? await Task.sleep(for: .seconds(min(backoff, 15)))
                    backoff = min(backoff * 2, 15)
                }
            }
        }
    }

    /// Wake the dispatcher so a new `ready` card starts without waiting for the 60 s tick.
    static func nudge() async throws {
        _ = try await HermesServeClient.shared.restJSON("POST", "\(base)/dispatch")
    }
}

#if DEBUG
extension KanbanClient {
    /// Screenshot helper (`-echo.demoKanban`): a sample board instead of the plugin's.
    static var isDemo: Bool { CommandLine.arguments.contains("-echo.demoKanban") }

    static func demoBoard() -> Board {
        let now = Date.now.timeIntervalSince1970
        func card(_ id: String, _ title: String, _ summary: String, _ status: String, priority: Int = 0,
                  assignee: String? = "redde", ago: TimeInterval, comments: Int = 0) -> JSONValue {
            var j: [String: JSONValue] = [
                "id": .string(id), "title": .string(title), "body": .string(summary), "status": .string(status),
                "priority": .number(Double(priority)), "created_at": .number(now - ago), "comment_count": .number(Double(comments)),
            ]
            if let assignee { j["assignee"] = .string(assignee) }
            return .object(j)
        }
        let cards = [
            card("t1", "Compare heat pump quotes", "Three installers so far. Pull the SEER ratings and rebates into one table.", "todo", priority: 2, ago: 5_400, comments: 2),
            card("t2", "Renew the car registration", "Due on the 14th. Needs the emissions certificate from last month.", "todo", priority: 1, assignee: "home", ago: 20_000),
            card("t3", "Book the Lisbon flights", "Direct on the 12th, back on the 16th, aisle seats. Hold off until the price dips.", "todo", ago: 90_000, comments: 1),
            card("t4", "Summarise the school newsletter", "Every Friday: dates, forms to sign, anything the kids need to bring.", "todo", ago: 170_000),
            card("t5", "Sort the photo backup", "Duplicates from the old phone, then album by trip.", "todo", assignee: nil, ago: 400_000),
            card("t6", "Tidy the recipe notes", "Merge the two soup lists.", "triage", assignee: nil, ago: 3_000),
            card("t7", "Price the deck boards", "Composite, mid-grey, 40 m².", "ready", ago: 8_000),
            card("t8", "Draft the landlord email", "Heating, lease clause 7.", "running", ago: 1_200),
            card("t9", "Weekend hike plan", "Route and packing list saved.", "review", ago: 30_000),
            card("t10", "Insurance renewal", "Switched, saved 18%.", "done", ago: 300_000),
            card("t11", "Return the drill", "Receipt emailed.", "done", ago: 500_000),
        ]
        let columns = KanbanStatus.columns.map { name in
            KanbanColumn(name: name, tasks: cards.compactMap(KanbanTask.init).filter { $0.status == name })
        }
        return Board(columns: columns, latestEventID: 0, assignees: ["redde", "home"])
    }
}
#endif
