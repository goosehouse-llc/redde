import Foundation
import Observation
import SwiftUI

/// A finished task's report as a notification told it (GitHub issue 63): kept by Redde's plugin
/// 1.27 (`tasks.py`) when no turn of the agent's reported the task, and the phone was told the
/// task's own summary instead.
nonisolated struct TaskReport: Equatable, Identifiable, Sendable {
    var id: String
    var at: Date
    var summary: String
    /// "3 tasks, 1 not completed", "Ended: timeout": what the summary doesn't say.
    var about: String
    var tasks: Int
    var failed: Int

    /// The plugin's `tasks <session>` answer: "redde-push tasks {"tasks": […]}". Nil for anything
    /// else (an older plugin answers with its usage).
    static func parse(_ output: String) -> [TaskReport]? {
        guard output.hasPrefix("redde-push tasks "), let start = output.firstIndex(of: "{"),
              let json = try? JSONDecoder().decode(JSONValue.self, from: Data(output[start...].utf8)),
              let found = json["tasks"]?.array else { return nil }
        return found.compactMap { r in
            guard let id = r["id"]?.string, !id.isEmpty, let at = r["at"]?.number else { return nil }
            return TaskReport(id: id, at: Date(timeIntervalSince1970: at), summary: r["summary"]?.string ?? "",
                              about: r["about"]?.string ?? "", tasks: r["tasks"]?.int ?? 1, failed: r["failed"]?.int ?? 0)
        }
    }

    /// The report's heading, as Hermes's own row for it says it (`BotMessages.taskNotice`).
    var heading: String {
        if tasks > 1 {
            return failed > 0 ? String(localized: "Some tasks didn't finish", comment: "In a chat: the work the agent handed off came back, not all of it done")
                : String(localized: "Tasks finished", comment: "In a chat: the work the agent handed off is done")
        }
        return failed > 0 ? String(localized: "A background task didn't finish", comment: "In a chat: a task the agent handed off came back unfinished")
            : String(localized: "A background task finished")
    }

    /// What the card shows: the summary, else what little is known.
    var body: String {
        let words = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return [words.isEmpty ? nil : words, about.isEmpty ? nil : about].compactMap { $0 }.joined(separator: "\n\n")
    }
}

/// Where a chat's task reports go (`TaskReports.layout`): the ones Hermes hasn't put in the chat
/// yet, shown as cards at its end, and Hermes's own rows for the others, which stay open (the
/// notification's words are in them) rather than folding away behind the agent's answer.
nonisolated struct TaskReportLayout: Equatable, Sendable {
    var waiting: [TaskReport] = []
    var openNotices: Set<UUID> = []
}

/// The task reports of the chat on screen, asked of the plugin when the chat opens, when Redde
/// comes to the front, and when a task's notification comes in or is tapped. Both connections:
/// the plugin's command goes over the Dashboard or the Hermes API, whichever the app is on.
@MainActor
@Observable
final class TaskReports {
    static let shared = TaskReports()

    private(set) var bySession: [String: [TaskReport]] = [:]
    /// Bumped when a task's notification says there may be news for a chat.
    private(set) var nudges = 0
    @ObservationIgnored var plugin: PushService.PluginCommand = PushService.command(over: Settings.shared)
    @ObservationIgnored private var asking: Set<String> = []

    func reports(for session: String?) -> [TaskReport] {
        #if DEBUG
        if let demo = Self.demo { return demo }   // whatever chat is open, a demo's with no session too
        #endif
        return session.flatMap { bySession[$0] } ?? []
    }

    /// A task's notification came in or was tapped: the chat asks again.
    func nudge() { nudges &+= 1 }

    /// Asks the plugin for one chat's reports. Says nothing when the plugin is older or the server
    /// can't be reached: what was known stays.
    func refresh(session: String?) async {
        #if DEBUG
        if Self.demo != nil { return }
        #endif
        guard let session, !session.isEmpty, !asking.contains(session) else { return }
        asking.insert(session)
        defer { asking.remove(session) }
        guard let output = try? await plugin("tasks \(session)"), let found = TaskReport.parse(output) else { return }
        if bySession[session] != found { bySession[session] = found }
    }

    /// Which reports wait for Hermes's row and which rows are a report's. Each report is the first
    /// task row Hermes wrote after it (a moment's slack for clocks): until there is one, it waits.
    nonisolated static func layout(_ reports: [TaskReport], in messages: [Message]) -> TaskReportLayout {
        guard !reports.isEmpty else { return TaskReportLayout() }
        let notices = messages.filter { $0.delivered?.kind == .task }
        var layout = TaskReportLayout()
        for report in reports.sorted(by: { $0.at < $1.at }) {
            if let notice = notices.first(where: { $0.createdAt >= report.at.addingTimeInterval(-5) }) {
                layout.openNotices.insert(notice.id)
            } else {
                layout.waiting.append(report)
            }
        }
        return layout
    }

    #if DEBUG
    /// `-echo.demoTaskReport`: one report kept for whatever chat is open, two minutes old (with
    /// `-echo.demoTaskReportOld`, older than every row, so the chat's task rows are its).
    static let demo: [TaskReport]? = DevHooks.has("-echo.demoTaskReport")
        ? [TaskReport(id: "demo", at: DevHooks.has("-echo.demoTaskReportOld") ? .distantPast : .now.addingTimeInterval(-120),
                      summary: "Counted 12 PDF files in ~/Documents/Taxes. The newest is 2026 W-2.pdf, from Nov 3; two are duplicates of 2025 forms.",
                      about: "", tasks: 1, failed: 0)]
        : nil
    #endif
}

extension EnvironmentValues {
    /// Task rows of Hermes's whose words a notification showed: they stay open (`TaskReports`).
    @Entry var openTaskNotices: Set<UUID> = []
}
