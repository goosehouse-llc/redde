import Foundation

/// A bot's schedules (Schedules… on a bot, the chat list's row menu or its chat's ••• menu), as
/// Hermes Desktop makes its Routines: cron jobs in the bot's own store (`?profile=<bot>` on the
/// Dashboard's cron routes), so a run is the bot's, with its personality, model and tools, and
/// delivered into its Bot Chat (`deliver: bot-chat:<bot>`), where Hermes puts the output under
/// its banner ("[Cronjob …") and the bot answers it, with the phone off. Named with Desktop's tag
/// ("[bot:scout] What to wear") so Desktop lists them as the bot's too. Hermes 0.21.5 and later
/// fire a bot's on their own; 0.21.0 and 0.21.3 only with `gateway.multiplex_profiles` on (lab,
/// `lab.sh routines`). The Dashboard's login is needed: the Hermes API's jobs routes reach one
/// profile's store, and a bot added by its own key has no Bot Chat.
enum BotRoutines {
    static func tag(_ profile: String) -> String { "[bot:\(profile)] " }

    /// A job's name without Desktop's tag.
    nonisolated static func untagged(_ name: String) -> String {
        guard name.hasPrefix("[bot:"), let end = name.firstIndex(of: "]") else { return name }
        return name[name.index(after: end)...].trimmingCharacters(in: .whitespaces)
    }

    /// The bot a profile is, by its name in the list; nil for the main one.
    static func botName(_ profile: String) -> String? {
        guard profile != "default" else { return nil }
        return BotDirectory.shared.roster?.bots.first { $0.name == profile }?.label() ?? profile
    }

    /// The Dashboard, which has every profile's store.
    static var backend: CronBackend? {
        guard case .serve = CronBackend.current() else { return nil }
        return .serve
    }

    /// The bot's schedules: the jobs in its store that answer in its chat.
    static func list(_ bot: String) async throws -> [CronJob] {
        guard let backend else { return [] }
        return try await backend.list(profile: bot).filter(\.isBotRoutine)
            .sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
    }

    static func create(_ bot: String, title: String, prompt: String, when: String) async throws {
        try await backend?.create(name: tag(bot) + title, schedule: when, prompt: prompt, deliver: "bot-chat:" + bot, profile: bot)
    }

    static func update(_ job: CronJob, bot: String, title: String, prompt: String, when: String) async throws {
        try await backend?.update(job.id, name: tag(bot) + title, schedule: when, prompt: prompt, deliver: "bot-chat:" + bot, profile: bot)
    }

    /// A job due some minutes ago that hasn't run since: the server didn't fire it (on Hermes
    /// before 0.21.5, a bot's needs `gateway.multiplex_profiles`).
    nonisolated static func missed(_ job: CronJob, now: Date = .now) -> Bool {
        guard job.state == .scheduled, let next = job.nextRunAt, now.timeIntervalSince(next) > 300 else { return false }
        return (job.lastRunAt ?? .distantPast) < next
    }
}

/// When a bot's schedule runs, as the person picks it (every day, weekdays, weekends, some days
/// of the week, every few hours, or once), and as Hermes takes it: a cron expression in the
/// server's own time zone, "every 2h", or a moment with its offset. Pure, for the tests.
nonisolated struct RoutineWhen: Equatable, Sendable {
    enum Repeat: String, CaseIterable, Identifiable, Sendable {
        case daily, weekdays, weekends, weekly, hours, once
        var id: String { rawValue }
        var title: String {
            switch self {
            case .daily: "Every day"
            case .weekdays: "Weekdays"
            case .weekends: "Weekends"
            case .weekly: "On some days"
            case .hours: "Every few hours"
            case .once: "Once"
            }
        }
    }

    var repeats: Repeat = .weekdays
    var hour = 7
    var minute = 0
    /// For `.weekly`: cron's days, Sunday 0 to Saturday 6.
    var days: Set<Int> = [1]
    var everyHours = 2
    var once = Date.now.addingTimeInterval(3600)

    init(repeats: Repeat = .weekdays, hour: Int = 7, minute: Int = 0, days: Set<Int> = [1], everyHours: Int = 2,
         once: Date = .now.addingTimeInterval(3600)) {
        self.repeats = repeats; self.hour = hour; self.minute = minute; self.days = days; self.everyHours = everyHours; self.once = once
    }

    /// What Hermes is sent.
    var schedule: String {
        switch repeats {
        case .daily: return "\(minute) \(hour) * * *"
        case .weekdays: return "\(minute) \(hour) * * 1-5"
        case .weekends: return "\(minute) \(hour) * * 0,6"
        case .weekly: return "\(minute) \(hour) * * \((days.isEmpty ? [1] : days).sorted().map(String.init).joined(separator: ","))"
        case .hours: return "every \(max(1, everyHours))h"
        case .once:
            let format = ISO8601DateFormatter()
            format.timeZone = .current
            format.formatOptions = [.withInternetDateTime]
            return format.string(from: once)
        }
    }

    /// Read back from what Hermes keeps, for the forms Redde writes; nil for any other.
    init?(schedule: String) {
        let text = schedule.trimmingCharacters(in: .whitespaces)
        if let match = text.wholeMatch(of: /every (\d+)h/) {
            self.init(repeats: .hours, everyHours: Int(match.output.1) ?? 2)
            return
        }
        let parts = text.split(separator: " ").map(String.init)
        if parts.count == 5, parts[2] == "*", parts[3] == "*", let minute = Int(parts[0]), let hour = Int(parts[1]),
           (0 ..< 60).contains(minute), (0 ..< 24).contains(hour) {
            switch parts[4] {
            case "*": self.init(repeats: .daily, hour: hour, minute: minute)
            case "1-5": self.init(repeats: .weekdays, hour: hour, minute: minute)
            case "0,6", "6,0": self.init(repeats: .weekends, hour: hour, minute: minute)
            default:
                let days = parts[4].split(separator: ",").compactMap { Int($0) }
                guard !days.isEmpty, days.count == parts[4].split(separator: ",").count, days.allSatisfy((0 ... 6).contains) else { return nil }
                self.init(repeats: .weekly, hour: hour, minute: minute, days: Set(days))
            }
            return
        }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        if let date = format.date(from: text) {
            self.init(repeats: .once, once: date)
            return
        }
        return nil
    }

    /// "Weekdays at 7:00 AM", "Every 2 hours", "Once, Oct 21 at 7:00 AM".
    var summary: String {
        var parts = DateComponents()
        parts.hour = hour
        parts.minute = minute
        let time = (Calendar.current.date(from: parts) ?? .now).formatted(date: .omitted, time: .shortened)
        switch repeats {
        case .daily: return "Every day at \(time)"
        case .weekdays: return "Weekdays at \(time)"
        case .weekends: return "Weekends at \(time)"
        case .weekly:
            let names = Calendar.current.shortWeekdaySymbols
            return (days.isEmpty ? [1] : days).sorted().map { names[$0] }.formatted(.list(type: .and)) + " at \(time)"
        case .hours: return everyHours == 1 ? "Every hour" : "Every \(everyHours) hours"
        case .once: return "Once, \(once.formatted(date: .abbreviated, time: .shortened))"
        }
    }
}
