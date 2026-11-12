import Foundation
import Observation

/// "Ahead of Your Day" (asked 2026-10-30, after 2.3.1's What's New): the proactive features, each
/// off by default on a page of its own, turned on in one step. A sheet lists the core set ticked
/// (Morning Ideas, Heads-Ups, Leave-By Alerts, the Evening Wrap-up, the Week Ahead; Routine
/// Suggestions to tick), and Turn On does, in order: looks at what the connection can do, installs
/// or updates the Redde plugin over the Dashboard (`PushPluginModel`, the Redde Plugin page's way),
/// makes the daily jobs (`DailyJob.set`, the pages' own), turns on Leave-By Alerts (its asks in
/// turn), and offers pairing for notifications when this device has none, so ideas and briefings
/// come with Redde closed. What fails leaves the rest done and says what to do. Offered once, under
/// the item in What's New; always in Settings → Agent → Your Day.
enum AheadOfYourDay {
    /// What the sheet lists, in its order.
    enum Part: String, CaseIterable, Identifiable, Sendable {
        case morningIdeas, headsUps, leaveBy, wrapUp, weekAhead, routines
        /// Watch templates (2.4), off until ticked; they read email.
        case urgentEmail, schoolMessages
        var id: String { rawValue }

        /// The watch template behind it.
        var template: WatchTemplate.Kind? {
            switch self {
            case .urgentEmail: .urgentEmail
            case .schoolMessages: .schoolMessages
            default: nil
            }
        }

        /// The Hermes job behind it; Leave-By Alerts are worked out on this device.
        var job: DailyJob? {
            switch self {
            case .morningIdeas: MorningIdeas.job
            case .headsUps: HeadsUps.job
            case .wrapUp: EveningWrapUp.job
            case .weekAhead: WeekAhead.job
            case .routines: RoutineSuggestions.job
            case .leaveBy, .urgentEmail, .schoolMessages: nil
            }
        }

        var isJob: Bool { self != .leaveBy }
    }

    /// Ticked when the sheet opens; Routine Suggestions is there to tick.
    static let core: [Part] = [.morningIdeas, .headsUps, .leaveBy, .wrapUp, .weekAhead]

    /// What is known before anything is done: what the connection can do, and what is on already.
    struct Situation: Equatable, Sendable {
        /// Hermes jobs can be made: the Dashboard login or the Hermes API key (`CronBackend.current`).
        var jobs = false
        /// The Dashboard login: the plugin can be looked at and installed (`PushSettingsView.canAskDashboard`).
        var dashboard = false
        /// Chats go over that Dashboard, so pairing takes a tap; otherwise it takes a code.
        var pairsDirectly = false
        /// This device is paired with a Hermes for notifications.
        var paired = false
        /// The plugin as the Dashboard says; nil when it couldn't be asked.
        var plugin: PushPlugin.State?
        /// The plugin was installed and Hermes loads it only once restarted (0.21.0 and 0.21.3).
        var restartPending = false
        /// On already: the jobs found by name, and Leave-By Alerts.
        var on: Set<Part> = []
        /// The Hermes can read email (an email MCP server, seen over the Dashboard); nil, can't be
        /// told (the Hermes API alone: the email watches look at once and say).
        var email: Bool?
    }

    /// Why a step isn't done.
    enum Skip: Equatable, Sendable {
        /// Unticked.
        case notPicked
        case alreadyOn
        /// No Dashboard login and no Hermes API key: nothing to make a job with.
        case needsConnection
        /// No Dashboard login: the plugin can't be looked at from here (the terminal's command can).
        case needsDashboard
        /// The Dashboard couldn't say what plugin is there.
        case unreadable
        case upToDate
        /// Nothing picked needs it.
        case notNeeded
        case alreadyPaired
        /// Pairing needs the plugin running: after Hermes restarts.
        case waitsForRestart
        /// An email watch, on a Hermes with no way to read email.
        case needsEmail
    }

    enum Action: Equatable, Sendable {
        case run
        case skip(Skip)
    }

    enum Pairing: Equatable, Sendable {
        case skip(Skip)
        /// Over the Dashboard, with a tap (`PushPairingSheet`).
        case direct
        /// With the code the plugin's command shows (Settings → Notifications).
        case byCode
    }

    struct Plan: Equatable, Sendable {
        var plugin: Action
        var parts: [Part: Action]
        var pairing: Pairing
    }

    /// What Turn On does for what is picked, given the situation. Every job needs the plugin (its
    /// tools, its notes); Leave-By Alerts need neither the plugin nor a pairing.
    static func plan(picked: Set<Part>, situation: Situation) -> Plan {
        var parts: [Part: Action] = [:]
        for part in Part.allCases {
            parts[part] = if !picked.contains(part) { .skip(.notPicked) }
                else if situation.on.contains(part) { .skip(.alreadyOn) }
                else if part.isJob, !situation.jobs { .skip(.needsConnection) }
                else if part.template?.needsEmail == true, situation.email == false { .skip(.needsEmail) }
                else { .run }
        }
        let jobsWanted = picked.contains { $0.isJob }
        let plugin: Action = if !jobsWanted { .skip(.notNeeded) }
            else if !situation.dashboard { .skip(.needsDashboard) }
            else if let state = situation.plugin {
                state.installed && state.enabled && !state.isOutdated ? .skip(.upToDate) : .run
            } else { .skip(.unreadable) }
        let pairing: Pairing = if !jobsWanted { .skip(.notNeeded) }
            else if situation.paired { .skip(.alreadyPaired) }
            else if situation.restartPending { .skip(.waitsForRestart) }
            else if situation.pairsDirectly, situation.plugin?.installed == true { .direct }
            else { .byCode }
        return Plan(plugin: plugin, parts: parts, pairing: pairing)
    }

    /// The picks count as on: each of them is (Settings → Agent shows "On").
    static func isOn(picked: Set<Part>, on: Set<Part>) -> Bool {
        !picked.isEmpty && picked.isSubset(of: on)
    }

    // MARK: Offered once

    /// Whether What's New offers the setup under its item: an entry with the item, to someone not
    /// offered it before. Shown once, it counts as answered, taken or not ("never nag twice").
    static func offersSetup(in release: WhatsNew.Release, answered: Bool) -> Bool {
        !answered && release.items.contains { $0.action == .aheadOfYourDay }
    }

    private static let answeredKey = "aheadOfYourDay.answered"
    private static let pickedKey = "aheadOfYourDay.picked"

    static func answered(in defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: answeredKey) }
    static func markAnswered(in defaults: UserDefaults = .standard) { defaults.set(true, forKey: answeredKey) }

    /// What the person last turned on here (the core set before they have).
    static func picked(in defaults: UserDefaults = .standard) -> Set<Part> {
        guard let saved = defaults.stringArray(forKey: pickedKey) else { return Set(core) }
        return Set(saved.compactMap(Part.init))
    }

    static func setPicked(_ parts: Set<Part>, in defaults: UserDefaults = .standard) {
        defaults.set(Part.allCases.filter(parts.contains).map(\.rawValue), forKey: pickedKey)
    }

    /// The days a job runs, as a person says them: "Every day at 7:30 AM", "Sundays at 6:00 PM".
    static func when(_ daily: DailyJob, hour: Int, minute: Int) -> String {
        let time = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now)?
            .formatted(date: .omitted, time: .shortened) ?? "\(hour):\(String(format: "%02d", minute))"
        return daily.days == "0" ? String(localized: "Sundays at \(time)", comment: "Ahead of Your Day: when a weekly job runs, e.g. Sundays at 6:00 PM")
            : String(localized: "Every day at \(time)", comment: "Ahead of Your Day: when a daily job runs, e.g. Every day at 7:30 AM")
    }
}

/// What Turn On acts on: the server and this device, or stand-ins (tests).
protocol AheadOfYourDayHost: AnyObject {
    var plugin: any PushPluginManaging { get }
    /// What the connection can do and whether this device is paired; the plugin and the jobs are
    /// asked about after.
    func situation() -> AheadOfYourDay.Situation
    func jobs() async throws -> [CronJob]
    func setJob(_ daily: DailyJob, hour: Int, minute: Int, replacing job: CronJob?) async throws
    /// Turns Leave-By Alerts on with that way of getting about, asking for what it needs; what is
    /// still missing.
    func turnOnLeaveBy(_ way: LeaveTime.Mode) async -> Set<LeaveByAlerts.Missing>
    var leaveByOn: Bool { get }
    /// The pairings changed (the pairing sheet closed): paired now?
    func paired() -> Bool
    /// Turn Off (asked 2026-10-30: "when it's already on, don't have the Turn On option anymore.
    /// Allow for turn off if wanted"): a daily job taken off the server, Leave-By Alerts off.
    func removeJob(_ job: CronJob) async throws
    func turnOffLeaveBy() async
    /// Watch templates (2.4): whether the Hermes can read email (nil, can't be told), and setting one up.
    func emailAccess() async -> Bool?
    func setWatch(_ template: WatchTemplate, emailKnown: Bool?) async throws
}

extension AheadOfYourDayHost {
    func emailAccess() async -> Bool? { nil }
    func setWatch(_ template: WatchTemplate, emailKnown: Bool?) async throws {}
}

/// The real one: the active server's cron, the Redde plugin over the Dashboard, this device's
/// Leave-By Alerts and pairings.
final class LiveAheadHost: AheadOfYourDayHost {
    var plugin: any PushPluginManaging { PushSettingsView.pluginManager }

    func situation() -> AheadOfYourDay.Situation {
        var situation = AheadOfYourDay.Situation()
        situation.jobs = CronBackend.current() != nil
        situation.dashboard = PushSettingsView.canAskDashboard
        situation.pairsDirectly = PushSettingsView.signedInToDashboard
        situation.paired = paired()
        return situation
    }

    func jobs() async throws -> [CronJob] {
        guard let backend = CronBackend.current() else { return [] }
        return try await backend.list()
    }

    func setJob(_ daily: DailyJob, hour: Int, minute: Int, replacing job: CronJob?) async throws {
        try await daily.set(at: hour, minute, option: daily.defaultOption, replacing: job)
    }

    func turnOnLeaveBy(_ way: LeaveTime.Mode) async -> Set<LeaveByAlerts.Missing> {
        LeaveTime.setMode(way)
        Settings.shared.leaveByAlerts = true
        await LeaveByAlerts.shared.turned(on: true)
        return LeaveByAlerts.shared.missing
    }

    var leaveByOn: Bool { Settings.shared.leaveByAlerts }

    func paired() -> Bool {
        PushService.shared.reload()
        return PushService.shared.pairings.contains(where: \.isPaired)
    }

    func removeJob(_ job: CronJob) async throws {
        try await CronBackend.current()?.delete(job.id)
    }

    func turnOffLeaveBy() async {
        Settings.shared.leaveByAlerts = false
        await LeaveByAlerts.shared.turned(on: false)
    }

    func emailAccess() async -> Bool? { await WatchTemplate.emailAccess() }

    func setWatch(_ template: WatchTemplate, emailKnown: Bool?) async throws {
        try await WatchTemplate.create(template, emailKnown: emailKnown)
    }
}

/// The sheet's state while it is open: what is picked, what is on, and each row's progress.
@Observable
final class AheadOfYourDaySetup {
    typealias Part = AheadOfYourDay.Part

    /// A line of the sheet that Turn On reports on.
    enum Row: Hashable {
        case connection, plugin, pairing
        case part(Part)
    }

    /// How a row stands, in words for under it.
    enum Status: Equatable {
        case working(String?)
        case done(String)
        /// Nothing to do, said plainly ("Already on.").
        case skipped(String)
        case failed(String)
        /// Done as far as Redde can; the person has a step left (a pairing, a restart).
        case needsYou(String)
        /// A permission the device's Settings have to give (Leave-By Alerts'): a tap goes there.
        case needsSettings(String)
    }

    enum Phase: Equatable { case loading, ready, running, finished }

    var picked: Set<Part>
    var morningTime: Date
    var way: LeaveTime.Mode
    /// School Messages: whose (a school's or a teacher's name); empty, any school.
    var schoolFrom = ""
    private(set) var phase = Phase.loading
    /// The running phase is Turn Off's, not Turn On's.
    private(set) var turningOff = false
    private(set) var situation = AheadOfYourDay.Situation()
    private(set) var status: [Row: Status] = [:]
    /// The jobs on already, by part, for their times.
    private(set) var found: [Part: CronJob] = [:]
    /// Leave-By Alerts still miss these permissions.
    private(set) var missing: Set<LeaveByAlerts.Missing> = []
    /// The server's jobs couldn't be listed: why.
    private(set) var listProblem: String?
    let plugin: PushPluginModel
    @ObservationIgnored let host: any AheadOfYourDayHost
    @ObservationIgnored private let defaults: UserDefaults

    init(host: any AheadOfYourDayHost = AheadOfYourDaySetup.defaultHost, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.host = host
        plugin = PushPluginModel(manager: host.plugin)
        picked = AheadOfYourDay.picked(in: defaults)
        morningTime = Calendar.current.date(bySettingHour: MorningIdeas.job.hour, minute: MorningIdeas.job.minute, second: 0, of: .now) ?? .now
        let mode = LeaveTime.mode()
        way = mode == .off ? .driving : mode
    }

    /// The live host.
    static var defaultHost: any AheadOfYourDayHost {
        LiveAheadHost()
    }

    var plan: AheadOfYourDay.Plan { AheadOfYourDay.plan(picked: picked, situation: situation) }

    /// Everything picked is on already: the sheet offers Turn Off instead of Turn On.
    var everythingOn: Bool { AheadOfYourDay.isOn(picked: picked, on: situation.on) }

    /// The bottom button's pairing, once the rest is done: a tap over the Dashboard.
    var offersPairing: Bool { phase == .finished && plan.pairing == .direct && !situation.paired }

    // MARK: Looking

    /// What the connection can do, what is on already, and the plugin: as the sheet opens, and
    /// again as Turn On starts.
    func load() async {
        var situation = host.situation()
        situation.restartPending = self.situation.restartPending
        listProblem = nil
        if situation.jobs {
            // What can't be listed can't be told from what isn't there: no job is made twice.
            let jobs: [CronJob]
            do { jobs = try await host.jobs() } catch {
                listProblem = error.localizedDescription
                situation.jobs = false
                jobs = []
            }
            for part in Part.allCases {
                if let daily = part.job, let job = jobs.first(where: { $0.name == daily.name }) {
                    found[part] = job
                    situation.on.insert(part)
                } else if let kind = part.template, let job = WatchTemplate.find(kind, in: jobs) {
                    found[part] = job
                    situation.on.insert(part)
                } else {
                    found[part] = nil
                }
            }
            if picked.contains(where: { $0.template?.needsEmail == true }) || situation.on.contains(where: { $0.template?.needsEmail == true }) {
                situation.email = await host.emailAccess()
            }
        }
        if host.leaveByOn { situation.on.insert(.leaveBy) }
        if situation.dashboard {
            await plugin.refresh()
            situation.plugin = plugin.state
        }
        self.situation = situation
        if phase == .loading { phase = .ready }
    }

    // MARK: Turning on

    /// Each step in turn; one that fails leaves the others to go on.
    func turnOn() async {
        guard phase == .ready else { return }
        phase = .running
        status = [:]
        AheadOfYourDay.markAnswered(in: defaults)
        AheadOfYourDay.setPicked(picked, in: defaults)
        let jobsWanted = picked.contains { $0.isJob }

        // 1. The connection.
        status[.connection] = .working(nil)
        await load()
        status[.connection] = connectionStatus(jobsWanted: jobsWanted)

        // 2. The plugin.
        let plan = plan
        switch plan.plugin {
        case .run:
            status[.plugin] = .working(String(localized: "Hermes is fetching it from GitHub. This can take a minute."))
            await plugin.install()
            if let problem = plugin.problem {
                status[.plugin] = .failed(problem)
            } else if plugin.outcome == .needsRestart {
                situation.restartPending = true
                status[.plugin] = .needsYou(String(localized: "Hermes loads it when it next starts. Restart the gateway and the Dashboard on that machine."))
            } else {
                situation.plugin = plugin.state
                status[.plugin] = .done(plugin.state.map { PushSettingsView.pluginLine($0, restart: false) } ?? String(localized: "Installed.", comment: "Ahead of Your Day: the Redde plugin was installed"))
            }
        case let .skip(why):
            status[.plugin] = pluginSkipped(why)
        }

        // 3. The daily jobs, then 4. Leave-By Alerts, in the sheet's order.
        for part in Part.allCases {
            switch plan.parts[part] ?? .skip(.notPicked) {
            case .run:
                status[.part(part)] = .working(nil)
                if let daily = part.job {
                    status[.part(part)] = await make(daily, part)
                } else if let kind = part.template {
                    status[.part(part)] = await watch(kind, part)
                } else {
                    missing = await host.turnOnLeaveBy(way)
                    situation.on.insert(.leaveBy)
                    status[.part(part)] = missing.isEmpty ? .done(String(localized: "On.", comment: "Ahead of Your Day: a feature now on"))
                        : .needsSettings(String(localized: "Redde needs access to \(Self.names(missing)). Open Settings…",
                                           comment: "Settings → Leave-By Alerts, when a permission is denied: e.g. Calendars and Location"))
                }
            case .skip(.alreadyOn):
                status[.part(part)] = .skipped(found[part].flatMap { job in
                    part.job.flatMap { daily in DailyJob.time(of: job).map { AheadOfYourDay.when(daily, hour: $0.hour, minute: $0.minute) } }
                } ?? String(localized: "Already on.", comment: "Ahead of Your Day: a feature that was on before"))
            case .skip(.needsEmail):
                status[.part(part)] = .needsYou(WatchTemplate.needsEmailHint)
            case .skip(.needsConnection):
                status[.part(part)] = .failed(listProblem != nil ? String(localized: "Not made: your Hermes didn't list its jobs.", comment: "Ahead of Your Day: a daily job not made because the server's jobs couldn't be read")
                    : String(localized: "Needs the Hermes Dashboard login or the Hermes API key.", comment: "Ahead of Your Day: a daily job that can't be made over this connection"))
            case .skip:
                break
            }
        }

        // 5. Notifications with Redde closed, as the plugin now stands: offered at the bottom, or said how.
        status[.pairing] = pairingStatus(self.plan.pairing)
        phase = .finished
    }

    // MARK: Turning off

    /// What this sheet turned on, off again: each daily job it finds taken off the server, and
    /// Leave-By Alerts off on this device. The plugin and the pairing stay (other things use them).
    /// One that fails leaves the others off, and says why; then the sheet offers Turn On again.
    func turnOff() async {
        guard phase == .ready else { return }
        phase = .running
        turningOff = true
        defer { turningOff = false }
        status = [:]
        for part in Part.allCases where situation.on.contains(part) {
            status[.part(part)] = .working(nil)
            if part.job != nil || part.template != nil {
                guard let job = found[part] else { continue }
                do {
                    try await host.removeJob(job)
                    status[.part(part)] = .done(String(localized: "Turned off.", comment: "Ahead of Your Day: a feature Turn Off turned off"))
                } catch {
                    status[.part(part)] = .failed(error.localizedDescription)
                }
            } else {
                await host.turnOffLeaveBy()
                status[.part(part)] = .done(String(localized: "Turned off."))
            }
        }
        await load()
        phase = .ready
    }

    /// The pairing sheet closed: paired now, or still to do.
    func pairingChanged() {
        situation.paired = host.paired()
        if situation.paired { status[.pairing] = .done(String(localized: "Paired")) }
    }

    private func make(_ daily: DailyJob, _ part: Part) async -> Status {
        let (hour, minute) = part == .morningIdeas
            ? { let parts = Calendar.current.dateComponents([.hour, .minute], from: morningTime); return (parts.hour ?? daily.hour, parts.minute ?? daily.minute) }()
            : (daily.hour, daily.minute)
        do {
            try await host.setJob(daily, hour: hour, minute: minute, replacing: found[part])
            situation.on.insert(part)
            return .done(AheadOfYourDay.when(daily, hour: hour, minute: minute))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A watch template set up: on the Dashboard, said plainly; over the Hermes API, an email one
    /// looks at once and says whether it can read email.
    private func watch(_ kind: WatchTemplate.Kind, _ part: Part) async -> Status {
        let template: WatchTemplate = switch kind {
        case .urgentEmail: .urgentEmail
        case .schoolMessages: .schoolMessages(from: schoolFrom.trimmingCharacters(in: .whitespacesAndNewlines))
        case .package, .priceDrop: .urgentEmail   // not in the sheet: they need a number or a link (New Watch)
        }
        do {
            try await host.setWatch(template, emailKnown: situation.email)
            situation.on.insert(part)
            return situation.email == nil
                ? .done(String(localized: "On. It looks now, to see whether your Hermes can read your email.", comment: "Ahead of Your Day: an email watch set up over the Hermes API"))
                : .done(String(localized: "On.", comment: "Ahead of Your Day: a feature now on"))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func connectionStatus(jobsWanted: Bool) -> Status {
        if !jobsWanted { return .skipped(String(localized: "Leave-By Alerts are worked out on this device.", comment: "Ahead of Your Day: only Leave-By Alerts picked, nothing asked of the server")) }
        if let listProblem { return .failed(listProblem) }
        guard situation.jobs else {
            return .failed(String(localized: "Your agent's daily jobs need the Hermes Dashboard login or the Hermes API key. Add one in Settings → Connection details.", comment: "Ahead of Your Day: no connection that can make Hermes jobs"))
        }
        return .done(situation.dashboard ? String(localized: "Through the Hermes Dashboard.", comment: "Ahead of Your Day: how the daily jobs are made")
            : String(localized: "Through the Hermes API.", comment: "Ahead of Your Day: how the daily jobs are made"))
    }

    private func pluginSkipped(_ why: AheadOfYourDay.Skip) -> Status? {
        switch why {
        case .upToDate:
            return .skipped(situation.plugin.map { PushSettingsView.pluginLine($0, restart: false) } ?? String(localized: "Already on.", comment: "Ahead of Your Day: a feature that was on before"))
        case .needsDashboard:
            return .needsYou(String(localized: "Redde checks the plugin through the Hermes Dashboard login. Without it, install or update it on the machine that runs Hermes.", comment: "Ahead of Your Day: the plugin can't be checked over the Hermes API alone"))
        case .unreadable:
            if case let .unknown(why) = plugin.phase { return .needsYou(why) }
            return .needsYou(String(localized: "Redde couldn't ask your Hermes about the plugin.", comment: "Ahead of Your Day: the Dashboard didn't answer about the plugin"))
        default:
            return nil
        }
    }

    private func pairingStatus(_ pairing: AheadOfYourDay.Pairing) -> Status? {
        switch pairing {
        case .direct:
            return .needsYou(String(localized: "Pair this device so ideas and briefings arrive with Redde closed.", comment: "Ahead of Your Day: offering to pair for notifications"))
        case .byCode:
            return .needsYou(String(localized: "So ideas and briefings arrive with Redde closed, pair this device with a code in Settings → Notifications → Notify When Redde Is Closed.", comment: "Ahead of Your Day: pairing over the Hermes API takes the plugin's code"))
        case .skip(.alreadyPaired):
            return .skipped(String(localized: "Paired"))
        case .skip(.waitsForRestart):
            return .needsYou(String(localized: "Once Hermes has restarted, pair this device in Settings → Notifications → Notify When Redde Is Closed.", comment: "Ahead of Your Day: pairing waits for the plugin to load"))
        case .skip:
            return nil
        }
    }

    /// "Calendars and Location", as the device's own settings name them (Leave-By Alerts' words).
    static func names(_ missing: Set<LeaveByAlerts.Missing>) -> String {
        let names = [(LeaveByAlerts.Missing.calendar, String(localized: "Calendars")),
                     (.location, String(localized: "Location", comment: "The location permission, as the device's settings name it")),
                     (.notifications, String(localized: "Notifications"))]
        return ListFormatter.localizedString(byJoining: names.filter { missing.contains($0.0) }.map(\.1))
    }
}
