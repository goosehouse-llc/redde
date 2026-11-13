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
    /// The provider of its own model (Run On): with `model`, what it runs on.
    var provider: String?
    /// Run On's choice still waiting in its name for the Redde plugin (on the Hermes API, which
    /// can't set a job's model: `RunOn`), taken off `name`.
    var askedModel: RunOn.Pick?
    /// The profile whose store it is in, as the Dashboard lists every profile's (`?profile=all`);
    /// nil for the one the server runs as, or a backend that doesn't say.
    var profile: String?
    /// Coming Up's Skip (2026-11-02): the next run, by its time, that the Redde plugin is to pass
    /// over (`ComingUp.skipTag` at the end of the job's name, which is taken off `name`).
    var skipping: Date?
    /// How many runs it has left, when it was made to run a number of times (Hermes's `repeat`);
    /// nil for one that runs on until stopped.
    var runsLeft: Int?

    /// It runs once (a follow-up, a heads-up, a reminder): skipping it is cancelling it.
    var isOneOff: Bool {
        runsLeft == 1 || schedule.lowercased().hasPrefix("once") || name.hasPrefix(ComingUp.followUpTag)
            || name.hasPrefix(ComingUp.headsUpTag)
    }

    /// A bot's schedule (`BotRoutines`): its answer goes into a bot's Bot Chat.
    var isBotRoutine: Bool { deliver?.hasPrefix("bot-chat") == true }
    /// Its name less Hermes Desktop's tag for a bot's ("[bot:scout] What to wear").
    var title: String { BotRoutines.untagged(name) }

    init?(_ j: JSONValue) {
        guard let id = j["id"]?.string ?? j["job_id"]?.string else { return nil }
        self.id = id
        // The marks the app adds for the plugin (a model, a skipped run), each taken off the name.
        let (unmodeled, asked) = RunOn.unmarked(j["name"]?.string ?? "")
        askedModel = asked
        (name, skipping) = ComingUp.unmarked(unmodeled)
        if let times = j["repeat"]?["times"]?.int, times > 0 {
            runsLeft = max(0, times - (j["repeat"]?["completed"]?.int ?? 0))
        } else if let times = j["repeat"]?.int, times > 0 {
            runsLeft = times
        }
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
        model = j["model"]?.string?.nilIfEmpty
        provider = j["provider"]?.string?.nilIfEmpty
        profile = j["profile"]?.string?.nilIfEmpty
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
    static let builtIn = [CronDeliveryTarget(id: "local", name: String(localized: "Local (save only)", comment: "Where a scheduled job's output goes")), CronDeliveryTarget(id: "origin", name: String(localized: "Where the job was created", comment: "Where a scheduled job's output goes"))]
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

    /// The Dashboard whenever its login is kept, on either connection: it has every profile's
    /// jobs, their runs and the blueprints, which the Hermes API's jobs routes don't. Otherwise the
    /// Hermes API by its key.
    static func current() -> CronBackend? {
        let settings = Settings.shared
        if HermesServeClient.shared.hasCredentials, settings.serveBaseURL != nil { return .serve }
        if let url = settings.gatewayBaseURL, let key = settings.gatewayAPIKey, !key.isEmpty {
            return .apiServer(HermesSessionsAPI(baseURL: url, apiKey: key, headers: settings.apiHeaders))
        }
        return nil
    }

    /// A Dashboard path in the store of `profile` (a job listed from another profile's is only
    /// found there).
    static func scoped(_ path: String, _ profile: String?) -> String {
        guard let profile, !profile.isEmpty else { return path }
        let encoded = profile.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profile
        return path + (path.contains("?") ? "&" : "?") + "profile=" + encoded
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
        guard case .serve = self else { throw TransportError.malformed(String(localized: "Blueprints need hermes serve")) }
        let body: JSONValue = .object(["blueprint": .string(key), "values": .object(values.mapValues { .string($0) })])
        _ = try await HermesServeClient.shared.restJSON("POST", "api/cron/blueprints/instantiate", body: body)
    }

    /// Makes a job; on the Dashboard, in `profile`'s store when one is named (a bot's). `runs`: how
    /// many times it runs before Hermes lets it go (a watch template's days); nil, until stopped.
    func create(name: String, schedule: String, prompt: String, deliver: String? = nil, profile: String? = nil, runs: Int? = nil) async throws {
        var fields: [String: JSONValue] = ["name": .string(name), "schedule": .string(schedule), "prompt": .string(prompt)]
        if let deliver, !deliver.isEmpty { fields["deliver"] = .string(deliver) }
        if let runs, runs > 0 { fields["repeat"] = .number(Double(runs)) }
        let body: JSONValue = .object(fields)
        switch self {
        case .serve: _ = try await HermesServeClient.shared.restJSON("POST", Self.scoped("api/cron/jobs", profile), body: body)
        case let .apiServer(api): _ = try await api.requestJSON("POST", "api/jobs", body: body)
        }
    }

    func update(_ id: String, name: String, schedule: String, prompt: String, deliver: String? = nil, profile: String? = nil) async throws {
        var dict: [String: JSONValue] = ["name": .string(name), "schedule": .string(schedule), "prompt": .string(prompt)]
        if let deliver, !deliver.isEmpty { dict["deliver"] = .string(deliver) }
        let fields: JSONValue = .object(dict)
        switch self {
        case .serve: _ = try await HermesServeClient.shared.restJSON("PUT", Self.scoped("api/cron/jobs/\(id)", profile), body: .object(["updates": fields]))
        case let .apiServer(api): _ = try await api.requestJSON("PATCH", "api/jobs/\(id)", body: fields)
        }
    }

    /// Changes when a job runs and nothing else (Change Time, 2026-11-11): Hermes reads the new
    /// schedule and works out the next run from it, on both backends.
    func reschedule(_ id: String, schedule: String, profile: String? = nil) async throws {
        let fields: JSONValue = .object(["schedule": .string(schedule)])
        switch self {
        case .serve: _ = try await HermesServeClient.shared.restJSON("PUT", Self.scoped("api/cron/jobs/\(id)", profile), body: .object(["updates": fields]))
        case let .apiServer(api): _ = try await api.requestJSON("PATCH", "api/jobs/\(id)", body: fields)
        }
    }

    /// Renames a job and changes nothing else (both backends take a name alone).
    func rename(_ id: String, to name: String, profile: String? = nil) async throws {
        let fields: JSONValue = .object(["name": .string(name)])
        switch self {
        case .serve: _ = try await HermesServeClient.shared.restJSON("PUT", Self.scoped("api/cron/jobs/\(id)", profile), body: .object(["updates": fields]))
        case let .apiServer(api): _ = try await api.requestJSON("PATCH", "api/jobs/\(id)", body: fields)
        }
    }

    /// Coming Up's Skip for a job that repeats: its next run, marked in its name for the Redde plugin
    /// (1.15) to pass over. Neither backend lets a client set a job's next run; the plugin moves it
    /// with Hermes's own schedule arithmetic and takes the mark off (`ComingUp.skipTag`).
    func markSkip(_ job: CronJob, run: Date) async throws {
        try await rename(job.id, to: ComingUp.marked(job.name, skipping: run), profile: job.profile)
    }

    /// Takes a skip mark off again (one the plugin never took up).
    func unmarkSkip(_ job: CronJob) async throws {
        try await rename(job.id, to: job.name, profile: job.profile)
    }

    /// Run On: the job's own model, or the main model again. On the Dashboard at once (true); on the
    /// Hermes API as a mark in its name the Redde plugin takes up within half a minute (false). A
    /// skip still waiting keeps its mark.
    @discardableResult
    func setModel(_ job: CronJob, _ pick: RunOn.Pick) async throws -> Bool {
        switch self {
        case .serve:
            let fields: JSONValue = .object(["model": .string(pick.model), "provider": .string(pick.isMain ? "" : pick.provider)])
            _ = try await HermesServeClient.shared.restJSON("PUT", Self.scoped("api/cron/jobs/\(job.id)", job.profile), body: .object(["updates": fields]))
            return true
        case .apiServer:
            let base = job.skipping.map { ComingUp.marked(job.name, skipping: $0) } ?? job.name
            guard let name = RunOn.marked(base, pick) else {
                throw TransportError.malformed(String(localized: "That model's name can't be set on a job over the Hermes API."))
            }
            try await rename(job.id, to: name, profile: job.profile)
            return false
        }
    }

    /// The server's models, as the model picker lists them (the Dashboard's, else the Hermes API's).
    func modelOptions() async throws -> [ModelChoice] {
        switch self {
        case .serve: try await HermesServeClient.shared.modelOptions()
        case let .apiServer(api): try await api.modelOptions()
        }
    }

    func setPaused(_ id: String, _ paused: Bool, profile: String? = nil) async throws {
        let verb = paused ? "pause" : "resume"
        switch self {
        case .serve: _ = try await HermesServeClient.shared.restJSON("POST", Self.scoped("api/cron/jobs/\(id)/\(verb)", profile))
        case let .apiServer(api): _ = try await api.requestJSON("POST", "api/jobs/\(id)/\(verb)")
        }
    }

    /// Runs the job now. On serve this blocks until the run finishes.
    func runNow(_ id: String, profile: String? = nil) async throws {
        switch self {
        case .serve: _ = try await HermesServeClient.shared.restJSON("POST", Self.scoped("api/cron/jobs/\(id)/trigger", profile), timeout: 600)   // blocks until the run ends
        case let .apiServer(api): _ = try await api.requestJSON("POST", "api/jobs/\(id)/run")
        }
    }

    func delete(_ id: String, profile: String? = nil) async throws {
        switch self {
        case .serve: _ = try await HermesServeClient.shared.restJSON("DELETE", Self.scoped("api/cron/jobs/\(id)", profile))
        case let .apiServer(api): _ = try await api.requestJSON("DELETE", "api/jobs/\(id)")
        }
    }

    func runs(_ id: String, limit: Int = 20, profile: String? = nil) async throws -> [CronRun] {
        guard case .serve = self else { return [] }
        let json = try await HermesServeClient.shared.restJSON("GET", Self.scoped("api/cron/jobs/\(id)/runs?limit=\(limit)", profile))
        return (json["runs"]?.array ?? []).compactMap(CronRun.init)
    }

    /// One profile's jobs (the Dashboard's), a bot's included.
    func list(profile: String) async throws -> [CronJob] {
        guard case .serve = self else { return [] }
        let json = try await HermesServeClient.shared.restJSON("GET", Self.scoped("api/cron/jobs", profile))
        return (json.array ?? json["jobs"]?.array ?? []).compactMap(CronJob.init)
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
    /// The profile that made it (an agent's card), or "dashboard" for one made by hand.
    var createdBy: String?
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
        createdBy = j["created_by"]?.string
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

/// Something that happened to a card (Hermes's kanban events): its report's timeline.
nonisolated struct KanbanEvent: Identifiable, Equatable, Sendable {
    var id: Int
    var kind: String
    var at: Date?
    /// What the event says about itself: a reason, a summary, who it went to.
    var detail: String?

    init?(_ j: JSONValue) {
        guard let id = j["id"]?.int, let kind = j["kind"]?.string else { return nil }
        self.id = id
        self.kind = kind
        at = j["created_at"]?.number.map { Date(timeIntervalSince1970: $0) }
        let p = j["payload"]
        detail = [p?["reason"], p?["summary"], p?["assignee"], p?["profile"], p?["status"]].lazy.compactMap { $0?.string }.first { !$0.isEmpty }
    }

    var label: String {
        switch kind {
        case "created": String(localized: "Created", comment: "A kanban card's timeline: the card was made")
        case "claimed": String(localized: "Picked up", comment: "A kanban card's timeline: a worker started on it")
        case "completed": String(localized: "Finished", comment: "A kanban card's timeline: a worker finished it")
        case "blocked": String(localized: "Blocked", comment: "A Kanban column")
        case "review_requested": String(localized: "Sent for review", comment: "A kanban card's timeline")
        case "changes_requested": String(localized: "Changes asked for", comment: "A kanban card's timeline")
        case "commented": String(localized: "Comment", comment: "A kanban card's timeline: someone commented")
        case "edited": String(localized: "Edited", comment: "A kanban card's timeline")
        case "assigned": String(localized: "Assigned", comment: "A kanban card's timeline")
        case "scheduled": String(localized: "Scheduled", comment: "A Kanban column")
        case "reclaimed": String(localized: "Taken back", comment: "A kanban card's timeline: a stalled worker's claim was ended")
        case "archived": String(localized: "Archived", comment: "A Kanban column")
        case "attached": String(localized: "File attached", comment: "A kanban card's timeline")
        default: kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// One attempt at a card (Hermes's kanban runs): who worked on it, when, how it ended, and the
/// summary it handed over.
nonisolated struct KanbanRun: Identifiable, Equatable, Sendable {
    var id: Int
    var profile: String?
    var outcome: String?
    var summary: String?
    var error: String?
    var startedAt: Date?
    var endedAt: Date?

    init?(_ j: JSONValue) {
        guard let id = j["id"]?.int else { return nil }
        self.id = id
        profile = j["profile"]?.string
        outcome = j["outcome"]?.string ?? j["status"]?.string
        summary = j["summary"]?.string
        error = j["error"]?.string
        startedAt = j["started_at"]?.number.map { Date(timeIntervalSince1970: $0) }
        endedAt = j["ended_at"]?.number.map { Date(timeIntervalSince1970: $0) }
    }
}

/// A card with all Hermes keeps of it: for its report.
nonisolated struct KanbanDetail: Sendable {
    var task: KanbanTask
    var comments: [KanbanComment]
    var attachments: [KanbanAttachment]
    var events: [KanbanEvent]
    var runs: [KanbanRun]

    /// The web pages it relied on: the links in its result, its summaries and its comments,
    /// each once, in the order they first appear.
    var sources: [URL] {
        let texts = [task.result, task.latestSummary] + runs.map(\.summary) + comments.map(\.body)
        var seen = Set<String>(), found: [URL] = []
        for text in texts.compactMap(\.self) {
            for match in text.matches(of: /https?:\/\/[^\s<>"'\)\]]+/) {
                let link = String(match.output).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
                if seen.insert(link).inserted, let url = URL(string: link) { found.append(url) }
            }
        }
        return found
    }

    /// Why it is waiting on the person, if it is: blocked (and the reason given), or waiting for
    /// a review.
    var waitingReason: String? {
        switch task.status {
        case "blocked": events.last { $0.kind == "blocked" }?.detail ?? task.lastFailure
        case "review": runs.last?.summary ?? task.latestSummary
        default: nil
        }
    }
}

/// A file on a card (Hermes's kanban attachments): one a person added, or a worker's work, as the
/// claude bot leaves its patch.
nonisolated struct KanbanAttachment: Identifiable, Equatable, Sendable {
    var id: Int
    var filename: String
    var contentType: String?
    var size: Int

    init?(_ j: JSONValue) {
        guard let id = j["id"]?.int, let name = j["filename"]?.string else { return nil }
        self.id = id
        filename = name
        contentType = j["content_type"]?.string
        size = j["size"]?.int ?? 0
    }

    /// A change in patch form, shown as a diff.
    var isPatch: Bool {
        let name = filename.lowercased(), type = (contentType ?? "").lowercased()
        return name.hasSuffix(".patch") || name.hasSuffix(".diff") || type.contains("diff") || type.contains("patch")
    }

    /// Notes left with a change (the claude bot's HANDOFF.md: steps that need a key).
    var isNotes: Bool { filename.lowercased() == "handoff.md" }
}

nonisolated struct KanbanColumn: Identifiable, Sendable {
    var name: String
    var tasks: [KanbanTask]
    var id: String { name }

    /// Every column newest first, whatever order the server sends (his ask 2026-11-09): by when
    /// the card was made, a card with no date last, ties in the server's order.
    init(name: String, tasks: [KanbanTask]) {
        self.name = name
        self.tasks = tasks.enumerated().sorted { a, b in
            switch (a.element.createdAt, b.element.createdAt) {
            case let (x?, y?) where x != y: x > y
            case (_?, nil): true
            case (nil, _?): false
            default: a.offset < b.offset
            }
        }.map(\.element)
    }
}

/// The board's fixed status columns, in dispatcher order. `running` can't be set by hand.
enum KanbanStatus {
    static let columns = ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"]
    static let movable = ["triage", "todo", "scheduled", "ready", "blocked", "review", "done", "archived"]

    static func label(_ s: String) -> String {
        switch s {
        case "triage": String(localized: "Triage", comment: "A Kanban column")
        case "todo": String(localized: "To do", comment: "A Kanban column")
        case "scheduled": String(localized: "Scheduled", comment: "A Kanban column")
        case "ready": String(localized: "Ready", comment: "A Kanban column")
        case "running": String(localized: "Running", comment: "A Kanban column: tasks being worked on")
        case "blocked": String(localized: "Blocked", comment: "A Kanban column")
        case "review": String(localized: "Review", comment: "A Kanban column")
        case "done": String(localized: "task.done", defaultValue: "Done", comment: "A task, finished (not the Done button): a ticked checklist item, the agent's finished task, the Kanban column, the title after a plugin change")
        case "archived": String(localized: "Archived", comment: "A Kanban column")
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
    nonisolated static let base = "api/plugins/kanban"

    /// A route on one of Hermes's boards. Hermes keeps several (a `default` and any made beside
    /// it) and every route takes which in `?board=`; with none it answers for the board current
    /// on the server, which is what the rest of Redde works on (goals, hand-offs, approvals).
    /// The Kanban screen names the board it shows (GitHub issue 65: only the current one could
    /// be seen from the phone).
    nonisolated static func path(_ tail: String, board: String?) -> String {
        guard let board, !board.isEmpty,
              let slug = board.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) else { return "\(base)/\(tail)" }
        return "\(base)/\(tail)?board=\(slug)"
    }

    /// One of Hermes's boards, as the switcher lists it.
    nonisolated struct BoardInfo: Identifiable, Equatable, Sendable {
        var slug: String
        var name: String
        /// Its cards, those archived left out.
        var total: Int
        /// The board Hermes has current: where cards made elsewhere go.
        var isCurrent: Bool

        var id: String { slug }

        init?(_ json: JSONValue) {
            guard let slug = json["slug"]?.string, json["archived"]?.bool != true else { return nil }
            self.slug = slug
            let name = json["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.name = name.isEmpty ? slug : name
            total = json["total"]?.int ?? 0
            isCurrent = json["is_current"]?.bool ?? false
        }
    }

    /// Hermes's boards, the default first (`GET /boards`, there since 2026.8.31).
    static func boards() async throws -> [BoardInfo] {
        #if DEBUG
        if isDemo { return demoBoards() }
        #endif
        let json = try await HermesServeClient.shared.restJSON("GET", "\(base)/boards")
        return (json["boards"]?.array ?? []).compactMap(BoardInfo.init)
    }

    struct Board: Sendable {
        var columns: [KanbanColumn]
        var latestEventID: Int
        var assignees: [String]
    }

    static func board(_ board: String? = nil) async throws -> Board {
        #if DEBUG
        if isDemo { return demoBoard(board) }
        #endif
        let json = try await HermesServeClient.shared.restJSON("GET", path("board", board: board))
        let columns = (json["columns"]?.array ?? []).compactMap { col -> KanbanColumn? in
            guard let name = col["name"]?.string else { return nil }
            return KanbanColumn(name: name, tasks: (col["tasks"]?.array ?? []).compactMap(KanbanTask.init))
        }
        return Board(columns: columns, latestEventID: json["latest_event_id"]?.int ?? 0,
                     assignees: (json["assignees"]?.array ?? []).compactMap(\.string))
    }

    /// Edit the card's own fields. Pass nil to leave a field alone.
    static func edit(_ id: String, title: String?, body: String?, priority: Int?, assignee: String?, board: String? = nil) async throws {
        var fields: [String: JSONValue] = [:]
        if let title { fields["title"] = .string(title) }
        if let body { fields["body"] = .string(body) }
        if let priority { fields["priority"] = .number(Double(priority)) }
        if let assignee { fields["assignee"] = .string(assignee) }
        guard !fields.isEmpty else { return }
        try await patch(id, fields, board: board)
    }

    /// Move with the context the server wants: a reason for Blocked/Scheduled, a summary for Review/Done.
    static func move(_ id: String, to status: String, reason: String? = nil, summary: String? = nil, board: String? = nil) async throws {
        var fields: [String: JSONValue] = ["status": .string(status)]
        if let reason, !reason.isEmpty { fields["block_reason"] = .string(reason) }
        if let summary, !summary.isEmpty { fields["summary"] = .string(summary) }
        try await patch(id, fields, board: board)
    }

    static func task(_ id: String, board: String? = nil) async throws -> (KanbanTask, [KanbanComment], [KanbanAttachment]) {
        let detail = try await detail(id, board: board)
        return (detail.task, detail.comments, detail.attachments)
    }

    /// A card with its timeline and its runs (`/tasks/<id>` lists them beside its comments and
    /// attachments).
    static func detail(_ id: String, board: String? = nil) async throws -> KanbanDetail {
        #if DEBUG
        if isDemo, let card = demoBoard(board).columns.flatMap(\.tasks).first(where: { $0.id == id }) {
            return KanbanDetail(task: card, comments: [], attachments: [], events: [], runs: [])
        }
        #endif
        let json = try await HermesServeClient.shared.restJSON("GET", path("tasks/\(id)", board: board))
        guard let t = json["task"].flatMap(KanbanTask.init) else { throw TransportError.malformed("no task") }
        return KanbanDetail(task: t, comments: (json["comments"]?.array ?? []).compactMap(KanbanComment.init),
                            attachments: (json["attachments"]?.array ?? []).compactMap(KanbanAttachment.init),
                            events: (json["events"]?.array ?? []).compactMap(KanbanEvent.init),
                            runs: (json["runs"]?.array ?? []).compactMap(KanbanRun.init))
    }

    /// An attachment's contents, as text.
    static func attachmentText(_ id: Int, board: String? = nil) async throws -> String {
        String(decoding: try await HermesServeClient.shared.restData(path("attachments/\(id)", board: board)), as: UTF8.self)
    }

    /// The change a card carries: its newest patch, and the notes left with it.
    nonisolated struct CardChange: Equatable, Sendable {
        var task: KanbanTask
        var patch: String
        var notes: String?
    }

    /// A card's change, or nil when it has no patch on it.
    static func change(of id: String, board: String? = nil) async throws -> CardChange? {
        let (task, _, attachments) = try await self.task(id, board: board)
        guard let patch = attachments.last(where: \.isPatch) else { return nil }
        var notes: String?
        if let note = attachments.last(where: \.isNotes) { notes = try? await attachmentText(note.id, board: board) }
        return CardChange(task: task, patch: try await attachmentText(patch.id, board: board), notes: notes)
    }

    static func create(title: String, body: String?, priority: Int, assignee: String?, ready: Bool, board: String? = nil) async throws -> String? {
        var fields: [String: JSONValue] = ["title": .string(title), "priority": .number(Double(priority)), "triage": .bool(!ready)]
        if let body, !body.isEmpty { fields["body"] = .string(body) }
        if let assignee, !assignee.isEmpty { fields["assignee"] = .string(assignee) }
        let json = try await HermesServeClient.shared.restJSON("POST", path("tasks", board: board), body: .object(fields))
        Task { try? await nudge(board: board) }
        return json["warning"]?.string
    }

    static func patch(_ id: String, _ fields: [String: JSONValue], board: String? = nil) async throws {
        _ = try await HermesServeClient.shared.restJSON("PATCH", path("tasks/\(id)", board: board), body: .object(fields))
        Task { try? await nudge(board: board) }
    }

    static func delete(_ id: String, board: String? = nil) async throws {
        _ = try await HermesServeClient.shared.restJSON("DELETE", path("tasks/\(id)", board: board))
    }

    static func comment(_ id: String, _ text: String, board: String? = nil) async throws {
        _ = try await HermesServeClient.shared.restJSON("POST", path("tasks/\(id)/comments", board: board),
                                                        body: .object(["author": .string("redde"), "body": .string(text)]))
    }

    static func assignees(board: String? = nil) async throws -> [String] {
        let json = try await HermesServeClient.shared.restJSON("GET", path("assignees", board: board))
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

        /// `slug`: which of Hermes's boards to follow (nil, its current one). The socket is the
        /// board's from its opening: another board is another socket.
        func start(since cursor: Int, on slug: String? = nil) {
            stop()
            task = Task { [weak self] in await Self.run(since: cursor, board: self, slug: slug) }
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
        private static func run(since: Int, board: LiveBoard?, slug: String?) async {
            weak let board = board
            var cursor = since
            var backoff: Double = 2
            while !Task.isCancelled, board != nil {
                do {
                    let ws = try await HermesServeClient.shared.openPluginSocket(
                        path: "\(KanbanClient.base)/events",
                        query: [.init(name: "since", value: String(cursor))] + (slug.map { [.init(name: "board", value: $0)] } ?? []))
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
    static func nudge(board: String? = nil) async throws {
        _ = try await HermesServeClient.shared.restJSON("POST", path("dispatch", board: board))
    }
}

#if DEBUG
extension KanbanClient {
    /// Screenshot helper (`-echo.demoKanban`): a sample board instead of the plugin's.
    static var isDemo: Bool { DevHooks.demoKanban }

    /// Two boards (`-echo.demoKanban`), so the switcher shows: the household's, and a second one.
    static func demoBoards() -> [BoardInfo] {
        [BoardInfo(.object(["slug": .string("default"), "name": .string("Household"), "total": .number(14), "is_current": .bool(true)])),
         BoardInfo(.object(["slug": .string("garden"), "name": .string("Garden"), "total": .number(2)]))].compactMap(\.self)
    }

    static func demoBoard(_ slug: String? = nil) -> Board {
        let now = Date.now.timeIntervalSince1970
        // Assigned to the sample bots (`-echo.demoBots`, Claude with `-echo.demoClaudeBot`), so
        // the cards show their faces.
        func card(_ id: String, _ title: String, _ summary: String, _ status: String, priority: Int = 0,
                  assignee: String? = "default", ago: TimeInterval, started: TimeInterval? = nil, finished: TimeInterval? = nil,
                  comments: Int = 0) -> JSONValue {
            var j: [String: JSONValue] = [
                "id": .string(id), "title": .string(title), "body": .string(summary), "status": .string(status),
                "priority": .number(Double(priority)), "created_at": .number(now - ago), "comment_count": .number(Double(comments)),
            ]
            if let assignee { j["assignee"] = .string(assignee) }
            if let started { j["started_at"] = .number(now - started) }
            if let finished { j["completed_at"] = .number(now - finished) }
            return .object(j)
        }
        if slug == "garden" {
            let cards = [card("g1", "Order the tomato seeds", "San Marzano and one cherry kind, before March.", "todo", ago: 4_000),
                         card("g2", "Plan the raised beds", "Two beds, 1.2 by 2.4 m, where the old shed stood.", "ready", ago: 50_000)]
            return Board(columns: KanbanStatus.columns.map { name in
                KanbanColumn(name: name, tasks: cards.compactMap(KanbanTask.init).filter { $0.status == name })
            }, latestEventID: 0, assignees: ["redde", "home"])
        }
        let cards = [
            card("t1", "Compare heat pump quotes", "Three installers so far. Pull the SEER ratings and rebates into one table.", "todo", priority: 2, assignee: "scout", ago: 5_400, comments: 2),
            card("t2", "Renew the car registration", "Due on the 14th. Needs the emissions certificate from last month.", "todo", priority: 1, ago: 20_000),
            card("t3", "Book the Lisbon flights", "Direct on the 12th, back on the 16th, aisle seats. Hold off until the price dips.", "todo", assignee: "scout", ago: 90_000, comments: 1),
            card("t4", "Summarise the school newsletter", "Every Friday: dates, forms to sign, anything the kids need to bring.", "todo", assignee: "writer", ago: 170_000),
            card("t5", "Sort the photo backup", "Duplicates from the old phone, then album by trip.", "todo", assignee: nil, ago: 400_000),
            card("t6", "Tidy the recipe notes", "Merge the two soup lists.", "triage", assignee: nil, ago: 3_000),
            card("t7", "Price the deck boards", "Composite, mid-grey, 40 m².", "ready", assignee: "scout", ago: 8_000),
            card("t8", "Draft the landlord email", "Heating, lease clause 7.", "running", assignee: "writer", ago: 1_200, started: 900),
            card("t12", "Fix the photo jump in the transcript", "Claude Code is on it: the reply jumps when a picture finishes loading.", "running",
                 priority: 1, assignee: "claude", ago: 2_400, started: 420, comments: 1),
            card("t9", "Weekend hike plan", "Route and packing list saved.", "review", assignee: "scout", ago: 30_000),
            card("t13", "Restart the media server", "Needs your OK to restart it while nobody's watching.", "blocked", assignee: "fixit", ago: 12_000),
            card("t10", "Insurance renewal", "Switched, saved 18%.", "done", ago: 300_000, finished: 200_000),
            card("t11", "Return the drill", "Receipt emailed.", "done", assignee: "fixit", ago: 500_000, finished: 400_000),
            card("t14", "Clear out the old backups", "Freed 212 GB on the server.", "done", assignee: "fixit", ago: 1_300_000, finished: 1_200_000),
        ]
        let columns = KanbanStatus.columns.map { name in
            KanbanColumn(name: name, tasks: cards.compactMap(KanbanTask.init).filter { $0.status == name })
        }
        return Board(columns: columns, latestEventID: 0, assignees: ["default", "scout", "writer", "fixit", "claude"])
    }
}
#endif
