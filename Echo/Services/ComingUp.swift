import Foundation

/// Coming Up (2.4, asked 2026-10-30 after Meta's Muse, which keeps a record of what it will do as
/// well as what it did): the next day of what the agents and this device will do on their own,
/// soonest first: heads-ups, Leave-By Alerts, routines, watches' next looks, follow-ups, the daily
/// jobs and goals' check-ins. Agent Activity's first tab; what was done is its second.
///
/// All of it is read when the page opens (one list of the server's jobs, and this device's
/// Leave-By Alerts as last worked out): nothing polls. What is decided is here, testable.
///
/// Skip passes over one run. A job that runs once is cancelled (after the page asks). One that
/// repeats has its next run marked in its name, ` [redde-skip:<epoch>]`, which the Redde plugin
/// (1.15) takes up within half a minute: it moves the job's next run on by its own schedule and
/// takes the mark off. Neither the Dashboard nor the Hermes API lets a client set a job's next run.
/// On the Dashboard the plugin's command does it at once (`/redde-push skip`). A Leave-By Alert is
/// skipped on this device (`LeaveTime.skippedKey`).
nonisolated enum ComingUp {
    /// How far ahead it looks.
    static let window: TimeInterval = 24 * 3600
    /// A run this close is too near to skip by the mark (the plugin may not see it in time): Pause.
    static let tooSoonToSkip: TimeInterval = 2 * 60
    /// A mark the plugin hasn't taken up this long after it was set: no plugin 1.15 to take it.
    static let markUnheardAfter: TimeInterval = 2 * 60

    static let skipTag = "[redde-skip:"
    /// The plugin's heads-up jobs (`headsup.py`), each run once before its event.
    static let headsUpTag = "[redde-notify] Heads-up: "
    /// A goal's check-ins (2.4 Goals, the plugin's `goals.py`): `GoalReport`'s tag.
    static let goalTag = GoalReport.tag
    /// `Watches`' tags, here too: that enum is the main actor's.
    static let watchTag = "[redde-watch:", followUpTag = "[redde-followup:"

    // MARK: The skip mark

    /// A job's name less a skip mark at its end, and the run the mark names.
    static func unmarked(_ name: String) -> (name: String, skipping: Date?) {
        guard name.hasSuffix("]"), let open = name.range(of: " " + skipTag, options: .backwards),
              let epoch = Double(name[open.upperBound ..< name.index(before: name.endIndex)]) else { return (name, nil) }
        return (String(name[..<open.lowerBound]), Date(timeIntervalSince1970: epoch))
    }

    /// A job's name with its run at `run` marked to be passed over.
    static func marked(_ name: String, skipping run: Date) -> String {
        unmarked(name).name + " " + skipTag + String(Int(run.timeIntervalSince1970)) + "]"
    }

    /// A mark nothing took up: its run came and went, or it was set a while ago (`asked`) and is
    /// still there. Taken off again, with "needs the plugin's update" said.
    static func markUnheard(_ job: CronJob, asked: Date?, now: Date) -> Bool {
        guard let skipping = job.skipping else { return false }
        if now >= skipping { return true }
        return asked.map { now.timeIntervalSince($0) >= markUnheardAfter } ?? false
    }

    /// The plugin's command answer means it skipped the run (1.15: "Skipped …").
    static func pluginSkipped(_ answer: String) -> Bool {
        let said = answer.lowercased()
        return said.contains("skipped") || said.contains("skipping")
    }

    // MARK: What is coming

    enum Kind: String, Equatable, Sendable {
        case headsUp, leaveBy, routine, watch, followUp, daily, goal
        /// On this device, set by the agent through the phone tools (Planned, 2026-11-03).
        case alarm, timer, reminder, event

        var symbol: String {
            switch self {
            case .headsUp: "bell.badge"
            case .leaveBy: "car"
            case .routine: "repeat"
            case .watch: "eye"
            case .followUp: "arrowshape.turn.up.backward"
            case .daily: "sun.max"
            case .goal: "flag"
            case .alarm: "alarm"
            case .timer: "timer"
            case .reminder: "checklist"
            case .event: "calendar"
            }
        }
    }

    struct Item: Identifiable, Equatable, Sendable {
        var id: String
        var kind: Kind
        var title: String
        /// The agent's profile ("default", the main one); nil for this device's (Leave-By Alerts).
        var profile: String?
        /// When it runs, or (a Leave-By Alert) when it says to leave.
        var at: Date
        /// How often, for one that repeats: "Every 15 minutes".
        var cadence: String?
        /// More to say under it: a Leave-By Alert's way there.
        var detail: String?
        /// The server's job, for one that is a job.
        var job: CronJob?
        /// A Leave-By Alert's identifier.
        var alertID: String?
        /// What the agent set on this device (`PhoneMade`): the alarm's, reminder's or event's id.
        var phoneID: String?
        /// A reminder with no due time: shown today, without a time.
        var untimed = false
        var paused = false
        /// Its next run is marked to be passed over; the plugin hasn't moved it yet.
        var skipping = false
        /// A Leave-By Alert skipped on this device.
        var skipped = false

    }

    /// The daily jobs Redde makes, by name (`DailyJob`'s: `MorningIdeas.name` and the rest, which
    /// are the main actor's; a test keeps the two the same).
    static let dailyNames: Set<String> = ["[redde] Morning ideas", "[redde] Heads-ups", "[redde] Routine suggestions",
                                          "[redde-notify] Evening wrap-up", "[redde-notify] Week ahead"]

    /// A tagged job's name less its tag ("[redde-watch:ab12] The kettle's price" → "The kettle's price").
    static func afterTag(_ name: String) -> String {
        guard let close = name.firstIndex(of: "]") else { return name }
        return name[name.index(after: close)...].trimmingCharacters(in: .whitespaces)
    }

    /// What a job is, and its name as the person knows it.
    static func describe(_ job: CronJob) -> (kind: Kind, title: String) {
        let name = job.name
        if dailyNames.contains(name) { return (.daily, AgentActivity.describe(name).title) }
        if name.hasPrefix(headsUpTag) { return (.headsUp, String(name.dropFirst(headsUpTag.count))) }
        if name.hasPrefix(watchTag) { return (.watch, afterTag(name)) }
        if name.hasPrefix(followUpTag) { return (.followUp, afterTag(name)) }
        if name.hasPrefix(goalTag) { return (.goal, afterTag(name)) }
        return (.routine, AgentActivity.describe(name).title)
    }

    /// Everything that will happen in the next `window`, soonest first, then what is paused (Redde's
    /// own jobs and the person's routines; a paused job's next run isn't known). `leave` is what
    /// Leave-By Alerts last worked out (`LeaveBy.worked()`); `skippedLeave` the alerts skipped here.
    /// `within` is Coming Up's day, or Planned's week; `phone` is what the agent set on this device
    /// (`PhoneMade.items`), already cut to the same span.
    static func plan(jobs: [CronJob], leave: [String: LeaveBy.Worked], skippedLeave: Set<String> = [], now: Date,
                     within: TimeInterval = window, phone: [Item] = []) -> [Item] {
        let end = now.addingTimeInterval(within)
        var items: [Item] = []
        var paused: [Item] = []
        for job in jobs where job.state != .completed {
            let (kind, title) = describe(job)
            if job.state == .paused || !job.enabled {
                paused.append(Item(id: "job/" + job.id + "/" + (job.profile ?? ""), kind: kind, title: title, profile: job.profile ?? "default",
                                   at: job.nextRunAt ?? .distantFuture, cadence: cadence(job.schedule), job: job, paused: true))
                continue
            }
            guard let next = job.nextRunAt, next <= end, next > now.addingTimeInterval(-60) else { continue }
            items.append(Item(id: "job/" + job.id + "/" + (job.profile ?? ""), kind: kind, title: title, profile: job.profile ?? "default",
                              at: next, cadence: job.isOneOff ? nil : cadence(job.schedule), job: job,
                              skipping: job.skipping.map { abs($0.timeIntervalSince(next)) < 60 } ?? false))
        }
        for (id, worked) in leave where worked.start > now {
            let isSkipped = skippedLeave.contains(id)
            let at = isSkipped ? worked.leave : (worked.alertAt ?? worked.leave)
            guard at > now, at <= end, isSkipped || worked.alertAt != nil else { continue }
            items.append(Item(id: "leave/" + id, kind: .leaveBy, title: worked.title, profile: nil, at: at,
                              detail: LeaveTime.line(leave: at, travel: worked.travel, mode: worked.mode, now: .distantPast),
                              alertID: id, skipped: isSkipped))
        }
        items += phone
        items.sort { ($0.at, $0.title, $0.id) < ($1.at, $1.title, $1.id) }
        paused.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return items + paused
    }

    /// How often a schedule runs, in words; nil for one this can't read (Hermes's own words are
    /// shown then, by the job's page).
    static func cadence(_ schedule: String) -> String? {
        let text = schedule.trimmingCharacters(in: .whitespaces)
        let lower = text.lowercased()
        if lower.hasPrefix("every ") {
            // Hermes's interval schedules: "every 15m", "every 2h", "every 1d".
            let amount = lower.dropFirst("every ".count)
            if let n = Int(amount.dropLast()), n > 0 {
                switch amount.last {
                case "m": return n == 1 ? String(localized: "Every minute") : String(localized: "Every \(n) minutes")
                case "h": return n == 1 ? String(localized: "Every hour") : String(localized: "Every \(n) hours")
                case "d": return n == 1 ? String(localized: "Every day") : String(localized: "Every \(n) days")
                default: break
                }
            }
            return nil
        }
        let parts = text.split(separator: " ")
        guard parts.count == 5 else { return nil }
        let (minute, hour, dom, month, dow) = (parts[0], parts[1], parts[2], parts[3], parts[4])
        guard dom == "*", month == "*" else { return nil }
        if minute.hasPrefix("*/"), hour == "*", dow == "*", let n = Int(minute.dropFirst(2)) {
            return String(localized: "Every \(n) minutes")
        }
        if Int(minute) != nil, hour.hasPrefix("*/"), dow == "*", let n = Int(hour.dropFirst(2)) {
            return n == 1 ? String(localized: "Every hour") : String(localized: "Every \(n) hours")
        }
        if Int(minute) != nil, hour == "*", dow == "*" { return String(localized: "Every hour") }
        if Int(minute) != nil, Int(hour) != nil {
            switch dow {
            case "*": return String(localized: "Every day")
            case "1-5": return String(localized: "Weekdays")
            case "0", "7": return String(localized: "Sundays")
            case "1": return String(localized: "Mondays")
            default: return String(localized: "Some days")
            }
        }
        return nil
    }

    /// What Skip does for an item, now.
    enum SkipWay: Equatable, Sendable {
        /// A Leave-By Alert, on this device.
        case leave
        /// A job that runs once: cancelled, once the person says so.
        case cancel
        /// A repeating job's next run, marked for the plugin (or, on the Dashboard, its command).
        case mark
        /// Its run is too near to skip by the mark: Pause instead.
        case pauseInstead
        /// Nothing to skip (paused, or already marked).
        case none
    }

    static func skipWay(_ item: Item, now: Date) -> SkipWay {
        if item.phoneID != nil { return .none }
        if item.kind == .leaveBy { return item.skipped ? .none : .leave }
        guard let job = item.job, !item.paused, !item.skipping else { return .none }
        if job.isOneOff { return .cancel }
        return item.at.timeIntervalSince(now) < tooSoonToSkip ? .pauseInstead : .mark
    }

    /// Planned's week, by day: today first (what is overdue on this device counts as today), then
    /// each day after. Paused ones aren't in it.
    static func byDay(_ items: [Item], now: Date, calendar: Calendar = .current) -> [(day: Date, items: [Item])] {
        let today = calendar.startOfDay(for: now)
        return Dictionary(grouping: items.filter { !$0.paused }) { max(today, calendar.startOfDay(for: $0.at)) }
            .map { ($0.key, $0.value) }
            .sorted { $0.day < $1.day }
    }

    /// Planned's span.
    static let week: TimeInterval = 7 * 24 * 3600
}
