import Foundation
import Testing
@testable import Echo

/// Planned (2026-11-03, in Cron's place in the drawer): the week of what the agents will do, with
/// the alarms, timers, reminders and events they set on this device (`PhoneMade`).
struct PlannedTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .gmt; return c }

    private func job(_ id: String, _ name: String, _ schedule: String = "0 9 * * *", in hours: Double) throws -> CronJob {
        try #require(CronJob(.object(["id": .string(id), "name": .string(name), "schedule": .string(schedule), "enabled": .bool(true),
                                      "next_run_at": .number(now.addingTimeInterval(hours * 3600).timeIntervalSince1970)])))
    }

    @Test func theWeekNotJustTheDay() throws {
        let jobs = [try job("a", "[redde-goal:10k] Run a 10K", in: 30), try job("b", "[redde] Morning ideas", in: 10),
                    try job("c", "[redde-notify] Week ahead", in: 24 * 8)]
        #expect(ComingUp.plan(jobs: jobs, leave: [:], now: now).map(\.title) == ["Morning ideas"], "Coming Up keeps its day")
        let week = ComingUp.plan(jobs: jobs, leave: [:], now: now, within: ComingUp.week).map(\.title)
        #expect(week == ["Morning ideas", "Run a 10K"], "Planned's week, not past it")
    }

    @Test func phoneItemsJoinTheJobsInTimeOrder() throws {
        let records = [PhoneMade.Record(kind: .reminder, id: "r1", title: "Call the vet", at: now.addingTimeInterval(2 * 3600), added: now),
                       PhoneMade.Record(kind: .event, id: "e1", title: "Dinner", at: now.addingTimeInterval(30 * 3600), added: now)]
        let live = ["r1": PhoneMade.Now(title: "Call the vet", at: now.addingTimeInterval(2 * 3600)),
                    "e1": PhoneMade.Now(title: "Dinner with Ana", at: now.addingTimeInterval(30 * 3600))]
        let alarms = [PhoneMade.Alarm(id: "a1", title: "Pasta", rings: now.addingTimeInterval(600), timer: true),
                      PhoneMade.Alarm(id: "a2", title: "Long ago", rings: now.addingTimeInterval(-60), timer: false)]
        let phone = PhoneMade.items(alarms: alarms, records: records, live: live, now: now, within: ComingUp.week)
        #expect(phone.gone.isEmpty)
        let items = ComingUp.plan(jobs: [try job("b", "[redde] Morning ideas", in: 5)], leave: [:], now: now, within: ComingUp.week, phone: phone.items)
        #expect(items.map(\.title) == ["Pasta", "Call the vet", "Morning ideas", "Dinner with Ana"], "the event's title as Calendar has it now")
        #expect(items.map(\.kind) == [.timer, .reminder, .daily, .event])
        #expect(items[0].phoneID == "a1" && items[2].phoneID == nil)
        #expect(ComingUp.skipWay(items[0], now: now) == .none, "phone items have their own actions, not Skip")
    }

    @Test func doneOrDeletedRemindersAreDroppedAndForgotten() {
        let records = [PhoneMade.Record(kind: .reminder, id: "done", title: "Done one", at: now, added: now),
                       PhoneMade.Record(kind: .reminder, id: "deleted", title: "Deleted", at: now, added: now),
                       PhoneMade.Record(kind: .reminder, id: "open", title: "No time", at: nil, added: now),
                       PhoneMade.Record(kind: .reminder, id: "late", title: "Overdue", at: now.addingTimeInterval(-86400), added: now)]
        let live = ["done": PhoneMade.Now(title: "Done one", at: now, completed: true),
                    "open": PhoneMade.Now(title: "No time", at: nil),
                    "late": PhoneMade.Now(title: "Overdue", at: now.addingTimeInterval(-86400))]
        let made = PhoneMade.items(alarms: [], records: records, live: live, now: now, within: ComingUp.week)
        #expect(made.gone == ["done", "deleted"])
        #expect(Set(made.items.map(\.title)) == ["No time", "Overdue"], "not done: still shown, without a time or overdue")
        #expect(made.items.first { $0.title == "No time" }?.untimed == true)
        #expect(made.items.first { $0.title == "Overdue" }?.untimed == false)
        // Overdue and timeless ones go under today.
        let days = ComingUp.byDay(made.items, now: now, calendar: calendar)
        #expect(days.count == 1 && days[0].day == calendar.startOfDay(for: now))
    }

    @Test func groupedByDayTodayFirst() throws {
        let jobs = [try job("a", "[redde] Morning ideas", in: 1), try job("b", "[redde-goal:g] Goal", in: 26),
                    try job("c", "[redde-notify] Week ahead", in: 24 * 5)]
        let days = ComingUp.byDay(ComingUp.plan(jobs: jobs, leave: [:], now: now, within: ComingUp.week), now: now, calendar: calendar)
        #expect(days.count == 3)
        #expect(days.map { $0.items.map(\.title) } == [["Morning ideas"], ["Goal"], ["Week ahead"]])
        #expect(zip(days, days.dropFirst()).allSatisfy { $0.day < $1.day })
    }

    @Test func recordsKeepTheNewestAndForget() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "phone-made-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        for i in 0..<(PhoneMade.most + 5) {
            PhoneMade.note(.init(kind: .reminder, id: "r\(i)", title: "R\(i)", at: nil, added: now), file: file, now: now)
        }
        PhoneMade.note(.init(kind: .reminder, id: "r\(PhoneMade.most + 4)", title: "Again", at: nil, added: now), file: file, now: now)
        var kept = PhoneMade.load(from: file)
        #expect(kept.count == PhoneMade.most)
        #expect(kept.last?.title == "Again" && kept.filter { $0.id == "r\(PhoneMade.most + 4)" }.count == 1)
        PhoneMade.forget(["r10"], file: file)
        kept = PhoneMade.load(from: file)
        #expect(!kept.contains { $0.id == "r10" })
        // Old ones go as new ones come.
        PhoneMade.note(.init(kind: .event, id: "new", title: "New", at: nil, added: now), file: file,
                       now: now.addingTimeInterval(PhoneMade.keep + 1))
        #expect(PhoneMade.load(from: file).map(\.id) == ["new"])
    }
}
