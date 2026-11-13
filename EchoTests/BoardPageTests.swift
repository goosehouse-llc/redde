import SwiftUI
import Testing
import UIKit
@testable import Echo

/// The drawer's Board page (2026-11-13): the hero's counts, where its counters go, and the
/// status pills' colours.
@MainActor
struct BoardPageTests {
    private func task(_ id: String, _ status: String, created: Date? = nil, completed: Date? = nil) -> KanbanTask? {
        var j: [String: JSONValue] = ["id": .string(id), "title": .string(id), "status": .string(status)]
        if let created { j["created_at"] = .number(created.timeIntervalSince1970) }
        if let completed { j["completed_at"] = .number(completed.timeIntervalSince1970) }
        return KanbanTask(.object(j))
    }

    private func board(_ cards: [KanbanTask?]) -> [KanbanColumn] {
        let all = cards.compactMap(\.self)
        return KanbanStatus.columns.map { name in KanbanColumn(name: name, tasks: all.filter { $0.status == name }) }
    }

    @Test func theHeroCountsWhatsMoving() {
        let now = Date.now
        let day: TimeInterval = 24 * 3600
        let columns = board([
            task("a", "running"), task("b", "running"),
            task("c", "review"), task("d", "blocked"),
            task("e", "todo"), task("f", "todo"), task("g", "todo"), task("h", "triage"), task("i", "ready"),
            task("j", "done", completed: now.addingTimeInterval(-2 * day)),
            // Finished long ago, but made recently: by when it was finished.
            task("k", "done", created: now.addingTimeInterval(-day), completed: now.addingTimeInterval(-10 * day)),
            // No finish time: by when it was made.
            task("l", "done", created: now.addingTimeInterval(-3 * day)),
            task("m", "done"),
        ])
        let summary = BoardSummary(columns: columns, now: now)
        #expect(summary.working == 2)
        #expect(summary.waiting == 2)
        #expect(summary.doneThisWeek == 2)
        #expect(summary.total == 13)
    }

    /// The line names the three busiest open columns, in the board's order; Done is never one.
    @Test func theLineNamesTheBusiestOpenColumns() {
        let columns = board([
            task("a", "todo"), task("b", "todo"), task("c", "todo"),
            task("d", "triage"),
            task("e", "ready"),
            task("f", "review"), task("g", "review"),
            task("h", "done"), task("i", "done"), task("j", "done"), task("k", "done"),
        ])
        let busiest = BoardSummary(columns: columns).busiest
        #expect(busiest.map(\.name) == ["triage", "todo", "review"])
        #expect(busiest.map(\.count) == [1, 3, 2])
        #expect(BoardSummary(columns: board([task("x", "done")])).busiest.isEmpty)
        #expect(BoardSummary(columns: board([])).total == 0)
    }

    @Test func eachCounterOpensItsColumn() {
        let both = board([task("a", "review"), task("b", "blocked")])
        #expect(BoardSummary.column(for: .working, in: both) == "running")
        #expect(BoardSummary.column(for: .waiting, in: both) == "review")
        #expect(BoardSummary.column(for: .done, in: both) == "done")
        // Only blocked cards wait: Waiting opens Blocked.
        #expect(BoardSummary.column(for: .waiting, in: board([task("b", "blocked")])) == "blocked")
        #expect(BoardSummary.column(for: .waiting, in: board([])) == "review")
        // A board without that column: nowhere.
        #expect(BoardSummary.column(for: .working, in: [KanbanColumn(name: "todo", tasks: [])]) == nil)
    }

    @Test func movingAndWaitingCardsStandOut() {
        #expect(BoardSummary.isMoving("running"))
        #expect(!BoardSummary.isMoving("ready"))
        #expect(BoardSummary.needsYou("review") && BoardSummary.needsYou("blocked"))
        #expect(!BoardSummary.needsYou("todo"))
    }

    // MARK: Colours

    private func rgb(_ color: Color, _ scheme: ColorScheme) -> (Double, Double, Double) {
        var env = EnvironmentValues()
        env.colorScheme = scheme
        let ui = UIColor(cgColor: color.resolve(in: env).cgColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private func contrast(_ x: Color, _ y: Color, _ scheme: ColorScheme) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func lum(_ c: (Double, Double, Double)) -> Double { 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2) }
        let (a, b) = (lum(rgb(x, scheme)), lum(rgb(y, scheme)))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The column shown is a pill filled in its hue with the words in the page colour: they read
    /// in every theme, by day and after dark.
    @Test(arguments: Theme.allCases)
    func wordsOnTheColumnPillsRead(_ theme: Theme) {
        let tone = BoardTone(theme.resolved(with: nil))
        for scheme in [ColorScheme.light, .dark] {
            for status in KanbanStatus.columns {
                let name = "\(theme.rawValue) \(scheme == .dark ? "dark" : "light") \(status)"
                #expect(contrast(tone.tone.page, tone.solid(status), scheme) >= 3, "\(name)")
            }
        }
    }
}
