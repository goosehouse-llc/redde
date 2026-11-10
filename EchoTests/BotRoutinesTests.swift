import Foundation
import Testing
import UserNotifications
@testable import Echo

/// A bot's schedules (`BotRoutines`, `RoutineWhen`): when they run, how Hermes is told, how a run
/// shows in the bot's chat, and the note that says it ran.
@MainActor
struct BotRoutinesTests {
    @Test func eachKindOfWhenIsWhatHermesTakes() {
        #expect(RoutineWhen(repeats: .daily, hour: 7, minute: 30).schedule == "30 7 * * *")
        #expect(RoutineWhen(repeats: .weekdays, hour: 7).schedule == "0 7 * * 1-5")
        #expect(RoutineWhen(repeats: .weekends, hour: 9).schedule == "0 9 * * 0,6")
        #expect(RoutineWhen(repeats: .weekly, hour: 18, minute: 15, days: [5, 1, 3]).schedule == "15 18 * * 1,3,5")
        #expect(RoutineWhen(repeats: .hours, everyHours: 3).schedule == "every 3h")
        let once = RoutineWhen(repeats: .once, once: Date(timeIntervalSince1970: 1_791_330_000)).schedule
        #expect(ISO8601DateFormatter().date(from: once) == Date(timeIntervalSince1970: 1_791_330_000), "a moment with its offset: \(once)")
    }

    @Test func whatRedeWritesReadsBack() {
        for when in [RoutineWhen(repeats: .daily, hour: 7, minute: 30), RoutineWhen(repeats: .weekdays, hour: 7),
                     RoutineWhen(repeats: .weekends, hour: 9), RoutineWhen(repeats: .weekly, hour: 18, minute: 15, days: [1, 3]),
                     RoutineWhen(repeats: .hours, everyHours: 3)] {
            let read = RoutineWhen(schedule: when.schedule)
            #expect(read?.schedule == when.schedule, "\(when.schedule) read back as \(String(describing: read?.schedule))")
        }
        #expect(RoutineWhen(schedule: "6,0 9 * * *") == nil, "one Redde doesn't write is kept as it is")
        #expect(RoutineWhen(schedule: "0 7 1 * *") == nil)
        #expect(RoutineWhen(schedule: "0 7 * * 0,6")?.repeats == .weekends)
        #expect(RoutineWhen(repeats: .hours, everyHours: 1).summary == "Every hour")
        #expect(RoutineWhen(repeats: .weekdays, hour: 7).summary.hasPrefix("Weekdays at "))
    }

    @Test func aBotsScheduleIsKnownByWhereItAnswers() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"id": "12d49a4bc559", "name": "[bot:scout] What to wear", "prompt": "Check the weather", "schedule_display": "0 7 * * 1-5",
         "deliver": "bot-chat:scout", "profile": "scout", "enabled": true}
        """.utf8))
        let job = try #require(CronJob(json))
        #expect(job.isBotRoutine && job.title == "What to wear" && job.profile == "scout")
        #expect(CronBackend.scoped("api/cron/jobs/12d49a4bc559", "scout") == "api/cron/jobs/12d49a4bc559?profile=scout")
        #expect(CronBackend.scoped("api/cron/jobs/x/runs?limit=20", "scout") == "api/cron/jobs/x/runs?limit=20&profile=scout")
        #expect(CronBackend.scoped("api/cron/jobs", nil) == "api/cron/jobs")
        #expect(BotRoutines.untagged("Backups") == "Backups")
    }

    @Test func aScheduleThatDidntRunIsSeen() throws {
        let now = Date(timeIntervalSince1970: 1_791_330_000)
        func job(next: Date, last: Date?) throws -> CronJob {
            var fields: [String: JSONValue] = ["id": .string("a"), "next_run_at": .number(next.timeIntervalSince1970), "enabled": .bool(true)]
            if let last { fields["last_run_at"] = .number(last.timeIntervalSince1970) }
            return try #require(CronJob(.object(fields)))
        }
        #expect(BotRoutines.missed(try job(next: now.addingTimeInterval(-900), last: nil), now: now), "due a quarter of an hour ago, never run")
        #expect(!BotRoutines.missed(try job(next: now.addingTimeInterval(-60), last: nil), now: now), "a minute late is the ticker's")
        #expect(!BotRoutines.missed(try job(next: now.addingTimeInterval(-900), last: now.addingTimeInterval(-800)), now: now))
        #expect(!BotRoutines.missed(try job(next: now.addingTimeInterval(600), last: nil), now: now))
    }

    @Test func aRunInTheBotsChatShowsAsTheSchedulesNotThePersons() throws {
        let text = "[Cronjob \"[bot:scout] What to wear\" output — scheduled job, not the user. Review it, act on anything that needs action, and summarize for the chat.]\n\nA light jacket: 14 degrees."
        let message = try #require(BotMessages.userMessage(text: text, displayKind: nil, displayText: nil, at: .now))
        #expect(message.delivered == Delivered(kind: .routine, title: "What to wear"))
        #expect(message.text == "A light jacket: 14 degrees.")
        #expect(BotMessages.rowPreview(text, roster: [], mainName: "Redde") == "What to wear ran")
    }

    @Test func theNoteSaysWhichScheduleAndOpensTheBotsChat() {
        let content = UNMutableNotificationContent()
        PushNote(k: "routine", t: "What to wear", b: "A light jacket.", d: "Scout", p: "scout").fill(content)
        #expect(content.title == "What to wear" && content.subtitle == "Scout" && content.body == "A light jacket.")
        #expect(content.userInfo[PushNote.botKey] as? String == "scout")
        let failed = UNMutableNotificationContent()
        PushNote(k: "routine", t: "What to wear", b: "It didn't finish: no model", w: "failed", p: "scout").fill(failed)
        #expect(failed.title == "What to wear didn't finish")

        let h = NotifierTests.Harness()
        _ = LaunchRouter.shared.consumeBot()
        h.notifier.route(action: UNNotificationDefaultActionIdentifier, requestID: nil, questionID: nil, approve: nil, deny: nil,
                         userText: nil, bot: "scout")
        #expect(LaunchRouter.shared.consumeBot() == "scout")
    }

    /// Issue 63: over the Hermes API a background task's coming back starts no turn, and the chat
    /// ended on Hermes's report as if the person had sent it.
    @Test func aTaskComingBackIsANoticeNotTheirMessage() throws {
        let one = """
        [ASYNC DELEGATION BATCH COMPLETE — deleg_deaefad5]
        A background fan-out unit you dispatched earlier — 1 subagent(s) — has finished; its consolidated results are below.

        Dispatched: 2026-11-09 23:44:12 (0s ago)
        Role: leaf   Model: alpha   Total duration: 0.16s

        --- ✓ TASK 1/1: Say hello, lab:wordy-subagent.  (status=completed, api_calls=1, 0.09s) ---
        Subagent's summary: said hello, nothing else to report.
        Full live transcript (complete tool/assistant trace): /tmp/hermes/cache/delegation/live/deleg_deaefad5/task-0.log
        """
        let message = try #require(BotMessages.userMessage(text: one, displayKind: "async_delegation_complete", displayText: nil, at: .now))
        #expect(message.delivered?.kind == .task)
        #expect(message.delivered?.title == "Task finished: Say hello, lab:wordy-subagent.")
        #expect(message.text == "Subagent's summary: said hello, nothing else to report.", "no instructions, no path")
        #expect(BotMessages.rowPreview(one, roster: [], mainName: "Sol") == "A background task finished")

        let two = """
        [ASYNC DELEGATION BATCH COMPLETE — batch]
        Private instructions
        Role: leaf

        --- ✓ TASK 1/2: Find the flights
        to Lisbon  (status=completed) ---
        Two direct ones on Friday.
        Full live transcript (complete tool/assistant trace): /private/path

        --- ✗ TASK 2/2: Book the hotel  (status=failed, 3.1s) ---
        (no summary — status=failed: no card on file)
        """
        let (delivered, said) = try #require(BotMessages.taskNotice(two))
        #expect(delivered.title == "Some tasks didn't finish")
        #expect(said == "**Find the flights**\nTwo direct ones on Friday.\n\n**Book the hotel**\n(no summary — status=failed: no card on file)")

        let failed = "[ASYNC DELEGATION TASK FAILED — deleg_x, task 2/3]\nOne subagent failed.\nTask: Book the hotel\nStatus: failed   Duration: 2s\nError: no card on file"
        #expect(BotMessages.taskNotice(failed)?.0.title == "Task didn't finish: Book the hotel")
        #expect(BotMessages.taskNotice(failed)?.1 == "no card on file")
    }

    @Test func aTaskTheAgentAnsweredFoldsAway() throws {
        let notice = try #require(BotMessages.userMessage(text: "[ASYNC DELEGATION BATCH COMPLETE — d]\n\n--- ✓ TASK 1/1: Hi  (status=completed) ---\nDone.",
                                                          displayKind: nil, displayText: nil, at: .now))
        var answered = [notice, Message(role: .assistant, text: "It said hello.", createdAt: .now)]
        BotMessages.foldAnsweredTasks(&answered)
        #expect(answered[0].delivered?.noted == true)
        var alone = [notice, Message(role: .user, text: "thanks", createdAt: .now)]
        BotMessages.foldAnsweredTasks(&alone)
        #expect(alone[0].delivered?.noted == false, "over the Hermes API nothing answers it: shown open")
    }
}
