import Foundation
import SwiftUI
import Testing
import UserNotifications
import WidgetKit
@testable import Echo

/// The agent's widget: what it keeps and which of it shows when, the timeline the widget is
/// given, the phone tool that writes it, and the note that writes it while Redde is closed.
@MainActor
struct AgentBoardTests {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "board-\(UUID().uuidString)")! }

    /// Seven in the morning.
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private func hours(_ n: Double) -> Date { start.addingTimeInterval(n * 3600) }

    private func board(_ title: String, from: Double = 0, until: Double? = nil) -> AgentBoard {
        AgentBoard(title: title, text: "\(title) text", from: hours(from), until: until.map(hours))
    }

    // MARK: What is kept, and what shows

    @Test func theOneThatStartedLastShows() {
        let defaults = suite()
        #expect(AgentBoard.showing(at: start, among: AgentBoard.all(in: defaults)) == nil)
        #expect(AgentBoard.put(board("Morning"), at: start, in: defaults))
        #expect(AgentBoard.put(board("Afternoon", from: 5), at: start, in: defaults))
        let kept = AgentBoard.all(in: defaults)
        #expect(AgentBoard.showing(at: hours(1), among: kept)?.title == "Morning")
        #expect(AgentBoard.showing(at: hours(5), among: kept)?.title == "Afternoon", "what was set for later takes over by itself")
        #expect(AgentBoard.turns(after: start, among: kept) == [hours(5)])
        #expect(!AgentBoard.put(board("Morning"), at: start, in: defaults) || AgentBoard.all(in: defaults) == kept, "the same again changes nothing")
    }

    @Test func oneWithAnEndComesOffAndWhatWasThereShowsAgain() {
        let defaults = suite()
        AgentBoard.put(board("Today"), at: start, in: defaults)
        AgentBoard.put(board("Leave now", from: 2, until: 3), at: start, in: defaults)
        let kept = AgentBoard.all(in: defaults)
        #expect(AgentBoard.showing(at: hours(2.5), among: kept)?.title == "Leave now")
        #expect(AgentBoard.showing(at: hours(3), among: kept)?.title == "Today")
        #expect(AgentBoard.turns(after: start, among: kept) == [hours(2), hours(3)])
        // With nothing under it, the widget is empty once it has run out.
        let alone = suite()
        AgentBoard.put(board("Leave now", from: 0, until: 1), at: start, in: alone)
        #expect(AgentBoard.showing(at: hours(1), among: AgentBoard.all(in: alone)) == nil)
    }

    @Test func whatCanNeverShowAgainIsNotKept() {
        let defaults = suite()
        AgentBoard.put(board("Old"), at: start, in: defaults)
        AgentBoard.put(board("Brief", from: 0.5, until: 1), at: start, in: defaults)
        // A new one with no end covers everything that started before it, for good.
        AgentBoard.put(board("New", from: 2), at: hours(2), in: defaults)
        #expect(AgentBoard.all(in: defaults).map(\.title) == ["New"])
        // One for the same moment takes the other's place.
        AgentBoard.put(board("Newer", from: 2), at: hours(2), in: defaults)
        #expect(AgentBoard.all(in: defaults).map(\.title) == ["Newer"])
        // And there is a limit to how many wait: the furthest off go.
        for hour in 3 ..< 3 + AgentBoard.most + 4 { AgentBoard.put(board("At \(hour)", from: Double(hour), until: Double(hour) + 0.5), at: hours(2), in: defaults) }
        let kept = AgentBoard.all(in: defaults)
        #expect(kept.count == AgentBoard.most && kept.first?.title == "Newer" && kept.last?.title == "At \(3 + AgentBoard.most - 2)")
        #expect(AgentBoard.clear(in: defaults))
        #expect(AgentBoard.all(in: defaults).isEmpty && !AgentBoard.clear(in: defaults))
    }

    @Test func aTitleAndTextAreCutToWhatAWidgetHolds() {
        let long = AgentBoard(title: String(repeating: "t", count: 200), text: "  " + String(repeating: "x", count: 900) + "\n", from: start)
        #expect(long.title.count == AgentBoard.titleLimit && long.text.count == AgentBoard.textLimit)
        #expect(AgentBoard(title: " ", text: "\n", from: start).isEmpty)
    }

    // MARK: The timeline

    @Test func theWidgetIsToldEveryChangeAhead() {
        let boards = [board("Today"), board("Leave now", from: 2, until: 3), board("Evening", from: 11)]
        let entries = BoardEntry.timeline(boards, from: start, hidesWords: false)
        #expect(entries.map(\.date) == [start, hours(2), hours(3), hours(11)])
        #expect(entries.map { $0.board?.title } == ["Today", "Leave now", "Today", "Evening"])
        #expect(BoardEntry.timeline([], from: start, hidesWords: true).map { $0.board } == [nil])
    }

    private func drawn(_ card: some View, _ family: WidgetFamily, dark: Bool = false) -> UIImage? {
        let size: CGSize = switch family {
        case .systemMedium: CGSize(width: 364, height: 170)
        case .accessoryRectangular: CGSize(width: 172, height: 76)
        case .accessoryInline: CGSize(width: 240, height: 26)
        default: CGSize(width: 170, height: 170)
        }
        let home = family == .systemSmall || family == .systemMedium
        let renderer = ImageRenderer(content: card
            .padding(home ? 16 : 0)
            .frame(width: size.width, height: size.height)
            .background(home ? Color(.secondarySystemBackground) : Color(.systemGray4), in: .rect(cornerRadius: home ? 24 : 12))
            .padding(8)
            .background(Color(.systemBackground))
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 3
        return renderer.uiImage
    }

    @Test func theCardDrawsInEverySizeFullEmptyAndHidden() throws {
        let board = BoardEntry.sample.board
        for family in [WidgetFamily.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline] {
            for (name, card) in [("full", BoardCard(board: board, family: family)), ("empty", BoardCard(board: nil, family: family)),
                                 ("hidden", BoardCard(board: board, hidesWords: true, family: family))] {
                let image = try #require(drawn(card, family, dark: name == "hidden"), "\(family) \(name)")
                // Kept where a person can look at them when asked to (`BOARD_SHOTS=<folder>`).
                if let folder = ProcessInfo.processInfo.environment["BOARD_SHOTS"] {
                    try image.pngData()?.write(to: URL(fileURLWithPath: folder).appending(path: "board-\(family)-\(name).png"))
                }
            }
        }
    }

    // MARK: The phone tool

    nonisolated final class Reloads: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var times: Int { lock.withLock { count } }
        func one() { lock.withLock { count += 1 } }
    }

    private func tool(onScreen: Bool = true) -> (DeviceBoard, UserDefaults, Reloads) {
        let name = "board-\(UUID().uuidString)"
        let reloads = Reloads()
        return (DeviceBoard(suite: name, reload: { reloads.one(); return onScreen }), UserDefaults(suiteName: name)!, reloads)
    }

    @Test func theToolWritesForNowAndForLater() async throws {
        let (tool, defaults, reloads) = tool()
        let now = DeviceDates.parse("2026-10-14T07:00")!
        let first = try await tool.set(.object(["title": .string("Today"), "text": .string("9:30 standup\n12:15 lunch")]), now: now)
        #expect(first["showing"]?["title"]?.string == "Today")
        #expect(first["showing"]?["text"]?.string == "9:30 standup\n12:15 lunch")
        #expect(first["later"]?.array?.isEmpty == true && first["widget_on_a_screen"]?.bool == true && first["widget"] == nil)
        let second = try await tool.set(.object(["text": .string("Leave by 4:40"), "at": .string("2026-10-14T16:00"), "until": .string("2026-10-14T17:00")]), now: now)
        #expect(second["showing"]?["title"]?.string == "Today", "what is there stays until then")
        #expect(second["later"]?.array?.first?["text"]?.string == "Leave by 4:40")
        #expect(second["later"]?.array?.first?["until"]?.string == DeviceDates.string(DeviceDates.parse("2026-10-14T17:00")!))
        #expect(AgentBoard.all(in: defaults).count == 2 && reloads.times == 2)
        let cleared = try await tool.clear(.object([:]), now: now)
        #expect(cleared["showing"] == .null && cleared["later"]?.array?.isEmpty == true)
        #expect(AgentBoard.all(in: defaults).isEmpty && reloads.times == 3)
    }

    @Test func whatCannotBeShownIsRefusedAndWhatWasCutIsSaid() async throws {
        let (tool, defaults, _) = tool(onScreen: false)
        let now = DeviceDates.parse("2026-10-14T07:00")!
        func refusal(_ args: [String: JSONValue]) async -> String? {
            do { _ = try await tool.set(.object(args), now: now); return nil } catch let error as DeviceToolError { return error.message } catch { return "\(error)" }
        }
        #expect(await refusal([:]) == DeviceToolError.missing("text").message)
        #expect(await refusal(["text": .string(" \n")]) == DeviceToolError.missing("text").message)
        #expect(await refusal(["text": .string("x"), "until": .string("2026-10-14T06:00")])?.contains("\"until\" has to be after") == true)
        #expect(await refusal(["text": .string("x"), "at": .string("2026-10-14T09:00"), "until": .string("2026-10-14T08:00")])?.contains("\"until\"") == true)
        #expect(await refusal(["text": .string("x"), "at": .string("soon")])?.contains("isn't a date") == true)
        #expect(AgentBoard.all(in: defaults).isEmpty)
        let long = try await tool.set(.object(["text": .string(String(repeating: "x", count: 400))]), now: now)
        #expect(long["note"]?.string?.contains("cut to fit") == true)
        #expect(long["widget_on_a_screen"]?.bool == false && long["widget"]?.string?.contains("hasn't added") == true, "it is kept, and the agent can say why nothing shows")
    }

    @Test func writingOnTheWidgetIsWhatAllowingItAllows() async throws {
        #expect([DeviceTool.widgetSet, .widgetClear].allSatisfy { $0.area == .widget && !$0.changes })
        #expect(DeviceArea.widget.allowLabel == "Allow" && DeviceArea.calendar.allowLabel == "Allow reading")
        #expect(DeviceArea.widget.alwaysLabel == "Always Allow the Widget" && DeviceArea.contacts.alwaysLabel == "Always Allow Reading Contacts")
        let allowed = PhoneToolsTests.Harness([.widget: .allow])
        _ = try await allowed.service.perform(.init(id: "1", tool: "phone_widget_set"))
        #expect(allowed.world.asked.isEmpty && allowed.world.ran == [.widgetSet])
        let asking = PhoneToolsTests.Harness([.widget: .ask])
        _ = try await asking.service.perform(.init(id: "1", tool: "phone_widget_set", arguments: .object(["title": .string("Today"), "at": .string("2026-10-14T16:00")])))
        #expect(asking.world.asked.count == 1 && asking.world.asked.first?.offersAlways == true)
        #expect(asking.world.asked.first?.ask.title == "Write on its widget")
        #expect(asking.world.asked.first?.ask.detail.hasPrefix("“Today”, from ") == true)
        #expect(DeviceAsk(.widgetClear, .object([:])).title == "Clear its widget")
    }

    // MARK: With Redde closed: the note

    private func note(_ title: String?, _ text: String?, from: String? = nil, until: String? = nil, written: Date? = nil) -> PushNote {
        PushNote(k: "widget", t: title, b: text, at: (written ?? start).timeIntervalSince1970, f: from, u: until)
    }

    @Test func aNoteForTheWidgetIsPutOnIt() {
        let defaults = suite()
        #expect(AgentBoard.take(note("Today", "9:30 standup"), at: hours(0.1), in: defaults))
        #expect(AgentBoard.all(in: defaults) == [AgentBoard(title: "Today", text: "9:30 standup", from: start)], "from when it was written, not when it arrived")
        // Times as the agent wrote them, read in the phone's own time zone.
        #expect(AgentBoard.take(note(nil, "Leave by 4:40", from: "2026-10-14T16:00", until: "2026-10-14T17:00"), at: hours(0.1), in: defaults))
        let later = AgentBoard.all(in: defaults).last
        #expect(later?.from == DeviceDates.parse("2026-10-14T16:00") && later?.until == DeviceDates.parse("2026-10-14T17:00"))
        // Nothing in it clears the widget; one that ran out on the way changes nothing.
        #expect(!AgentBoard.take(note("Gone", "x", until: "2001-01-01T00:00"), at: hours(0.1), in: defaults))
        #expect(AgentBoard.take(note(nil, nil), at: hours(0.2), in: defaults) && AgentBoard.all(in: defaults).isEmpty)
        // And no other note is taken for one.
        #expect(!AgentBoard.take(PushNote(k: "reply", s: "s-1", b: "Done."), in: defaults))
        #expect(!NeedsYou.take(note("Today", "x"), in: defaults))
    }

    @Test func itsNotificationSaysWhatWasWrittenAndMakesNoSound() {
        let content = UNMutableNotificationContent()
        content.sound = .default
        #expect(note("Today", "9:30 standup").fill(content))
        #expect(content.title == "Your agent updated its widget" && content.body == "Today\n9:30 standup")
        #expect(content.sound == nil && content.interruptionLevel == .passive)
        let cleared = UNMutableNotificationContent()
        note(nil, nil).fill(cleared)
        #expect(cleared.body == "It cleared what was there.")
        // In front, nothing is shown for it: the widget is the telling.
        #expect(NotifierTests.Harness(appActive: true).notifier.presentation(pushKind: "widget", sessionID: nil) == [])
    }

    @Test func aNoteTheAppOpensItselfReachesTheWidgetToo() {
        let defaults = suite()
        StatusWidgets.heard(note("Today", "9:30 standup"), in: defaults)
        #expect(AgentBoard.all(in: defaults).map(\.title) == ["Today"])
        #expect(NeedsYou.waiting(in: defaults).isEmpty)
    }
}
