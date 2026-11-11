import Foundation
import Testing
@testable import Echo

/// A finished task's report as its notification told it, kept by the plugin (1.27) for the chat
/// until Hermes puts its own row there (GitHub issue 63).
struct TaskReportsTests {
    private func notice(at: Date) -> Message {
        var message = Message(role: .user, text: "Counted 12 files.", createdAt: at)
        message.delivered = Delivered(kind: .task, title: "Task finished: count the files")
        return message
    }

    @Test func thePluginsAnswerIsRead() throws {
        let said = #"redde-push tasks {"tasks": [{"id": "19a7", "at": 1762900000.5, "summary": "12 files.", "about": "", "tasks": 1, "failed": 0}, {"id": "19a8", "at": 1762900100, "summary": "", "about": "2 tasks, 1 not completed", "tasks": 2, "failed": 1}]}"#
        let reports = try #require(TaskReport.parse(said))
        #expect(reports.map(\.id) == ["19a7", "19a8"])
        #expect(reports[0].at == Date(timeIntervalSince1970: 1762900000.5))
        #expect(reports[0].body == "12 files.")
        #expect(reports[1].body == "2 tasks, 1 not completed")
        #expect(reports[1].heading == String(localized: "Some tasks didn't finish"))
        // An older plugin answers with its usage: nothing known, rather than "no reports".
        #expect(TaskReport.parse("redde-push: unknown command tasks") == nil)
        #expect(TaskReport.parse(#"redde-push tasks {"tasks": []}"#) == [])
    }

    @Test func aReportWaitsAtTheEndUntilHermesWritesItsRowThenThatRowIsItsAndStaysOpen() {
        let then = Date(timeIntervalSince1970: 1_762_900_000)
        let report = TaskReport(id: "a", at: then, summary: "12 files.", about: "", tasks: 1, failed: 0)
        let earlier = notice(at: then.addingTimeInterval(-3600))   // another task's, an hour before
        let reply = Message(role: .assistant, text: "On it.", createdAt: then.addingTimeInterval(-60))

        let before = TaskReports.layout([report], in: [earlier, reply])
        #expect(before.waiting == [report])
        #expect(before.openNotices.isEmpty)

        let row = notice(at: then.addingTimeInterval(900))   // the person came back a quarter of an hour later
        let after = TaskReports.layout([report], in: [earlier, reply, row, Message(role: .assistant, text: "The count is in.", createdAt: then.addingTimeInterval(905))])
        #expect(after.waiting.isEmpty)
        #expect(after.openNotices == [row.id])
    }

    @Test func eachReportHasItsOwnRow() {
        let then = Date(timeIntervalSince1970: 1_762_900_000)
        let first = TaskReport(id: "a", at: then, summary: "one", about: "", tasks: 1, failed: 0)
        let second = TaskReport(id: "b", at: then.addingTimeInterval(600), summary: "two", about: "", tasks: 1, failed: 0)
        let row = notice(at: then.addingTimeInterval(60))
        let layout = TaskReports.layout([second, first], in: [row])
        #expect(layout.openNotices == [row.id])
        #expect(layout.waiting == [second], "the second came back after the only row Hermes wrote")
    }
}
