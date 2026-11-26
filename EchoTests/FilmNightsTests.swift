import EventKit
import Foundation
import Testing
@testable import Echo

/// A watch list's films with a night, on the calendar (asked 2026-11-26: "When a movie on list is
/// given a time and date, have it added to the calendar"): what should be there (`wanted`), what
/// to do about what is (`steps`), the lists telling it and the plugin, and the real calendar where
/// this simulator lets Redde at it.
@MainActor
struct FilmNightsTests {
    static let now = Date(timeIntervalSince1970: 1_795_700_000)   // 2026-11-26
    static let night = now.addingTimeInterval(3 * 86_400)

    static func watch(_ items: [TodayList.Item], id: String = "l1") -> TodayList {
        TodayList(id: id, title: "Christmas Movies", items: items, kind: .watch, emoji: "🎄", hue: .red)
    }

    static func placed(_ key: String, at start: Date, title: String = "🎄 Elf", id: String = "e1", external: String = "x1") -> FilmNights.Placed {
        .init(id: id, external: external, key: key, title: title, start: start, end: start.addingTimeInterval(7200))
    }

    @Test func theNightsAheadOfAWatchList() throws {
        let lists = [
            Self.watch([
                .init(id: "a", text: "Elf (2003)", done: false, when: Self.night, company: "Robin"),
                .init(id: "b", text: "Klaus", done: false),
                .init(id: "c", text: "Home Alone", done: true, when: Self.night),
                .init(id: "d", text: "Jingle All the Way", done: false, when: Self.now.addingTimeInterval(-3600)),
            ]),
            TodayList(id: "l2", title: "Chores", items: [.init(id: "t", text: "Gutters", done: false, when: Self.night)], kind: .todo),
        ]
        let wanted = FilmNights.wanted(lists, now: Self.now)
        #expect(wanted.map(\.key) == ["l1/a"], "not one with no night, ticked off, past, or a to-do")
        let elf = try #require(wanted.first)
        #expect(elf.name == "Elf")
        #expect(elf.title == "🎄 Elf · with Robin")
        #expect(elf.start == Self.night)
        #expect(elf.notes.contains("Christmas Movies"))
    }

    @Test func anEventOfReddesIsKnownByItsAddress() throws {
        let url = try #require(FilmNights.url(list: "3f9a", item: "b7c1"))
        #expect(url.absoluteString == "redde://list/3f9a/b7c1")
        #expect(FilmNights.key(of: url) == "3f9a/b7c1")
        #expect(FilmNights.key(of: URL(string: "https://redde.goosehouse.org/list/a/b")) == nil)
        #expect(FilmNights.key(of: URL(string: "redde://list/a")) == nil)
        #expect(FilmNights.key(of: nil) == nil)
    }

    private func wanted(_ items: [TodayList.Item]) -> [FilmNights.Night] {
        FilmNights.wanted([Self.watch(items)], now: Self.now)
    }

    @Test func theAddressIsOnTheNotesLastLineToo() throws {
        let elf = try #require(wanted([.init(id: "a", text: "Elf", done: false, when: Self.night)]).first)
        #expect(FilmNights.notes(nil, for: elf) == "From your Christmas Movies list in Redde.\nredde://list/l1/a")
        #expect(FilmNights.notes("Bring popcorn", for: elf) == "Bring popcorn\nredde://list/l1/a", "their notes kept")
        #expect(FilmNights.notes("Bring popcorn\nredde://list/old/a\n", for: elf) == "Bring popcorn\nredde://list/l1/a")
        #expect(FilmNights.key(inNotes: "Bring popcorn\nredde://list/l1/a") == "l1/a")
        #expect(FilmNights.key(inNotes: "From your list in Redde.") == nil)
    }

    @Test func onesMadeWithOnlyTheNotesLineAreKnownAndMadeOne() throws {
        // 6b1efc5 on an iPhone and an iPad opened together: two of every film, their URLs maybe lost.
        let elf = wanted([.init(id: "a", text: "Elf", done: false, when: Self.night)])
        let notes = elf[0].notes
        #expect(FilmNights.made(title: "🎄 Elf", start: Self.night, notes: notes, for: elf)?.key == "l1/a")
        #expect(FilmNights.made(title: "🎄 Elf", start: Self.night, notes: notes + " Bring popcorn", for: elf) == nil, "notes of their own: not ours")
        #expect(FilmNights.made(title: "Dinner", start: Self.night, notes: notes, for: elf) == nil)
        #expect(FilmNights.made(title: "🎄 Elf", start: Self.night.addingTimeInterval(3600), notes: notes, for: elf) == nil)
        var phone = Self.placed("l1/a", at: Self.night, id: "p", external: "A")
        var pad = Self.placed("l1/a", at: Self.night, id: "q", external: "B")
        phone.marked = false
        pad.marked = false
        #expect(FilmNights.steps(wanted: elf, placed: [pad, phone], others: [], known: ["l1"], now: Self.now)
                == [.remove(id: "q"), .update(id: "p", elf[0], length: 7200, retitle: false)], "one left, its address added")
    }

    @Test func addedOnceThenLeftAsItIs() {
        let elf = wanted([.init(id: "a", text: "Elf", done: false, when: Self.night)])
        #expect(FilmNights.steps(wanted: elf, placed: [], others: [], known: ["l1"], now: Self.now) == [.add(elf[0])])
        #expect(FilmNights.steps(wanted: elf, placed: [Self.placed("l1/a", at: Self.night)], others: [], known: ["l1"], now: Self.now).isEmpty)
    }

    @Test func movedWithItsNightKeepingItsLengthAndNamedAgainWithTheFilm() {
        let later = Self.night.addingTimeInterval(86_400)
        let elf = wanted([.init(id: "a", text: "Elf", done: false, when: later)])
        var mine = Self.placed("l1/a", at: Self.night)
        mine.end = Self.night.addingTimeInterval(5400)   // made shorter in Calendar
        #expect(FilmNights.steps(wanted: elf, placed: [mine], others: [], known: ["l1"], now: Self.now)
                == [.update(id: "e1", elf[0], length: 5400, retitle: false)])
        let renamed = wanted([.init(id: "a", text: "Elf (2003 film)", done: false, when: Self.night)])
        #expect(FilmNights.steps(wanted: renamed, placed: [Self.placed("l1/a", at: Self.night)], others: [], known: ["l1"], now: Self.now)
                == [.update(id: "e1", renamed[0], length: 7200, retitle: true)])
        // Its title changed in Calendar, the film's name still in it: left as they wrote it.
        #expect(FilmNights.steps(wanted: elf.map { var n = $0; n.start = Self.night; return n },
                                 placed: [Self.placed("l1/a", at: Self.night, title: "Movie night: ELF!")], others: [], known: ["l1"], now: Self.now).isEmpty)
    }

    @Test func goneWhenTheNightIsTakenOffOrTheFilmTickedOrTakenOff() {
        let mine = [Self.placed("l1/a", at: Self.night), Self.placed("l1/b", at: Self.night, id: "e2", external: "x2")]
        let left = wanted([.init(id: "a", text: "Elf", done: false), .init(id: "b", text: "Klaus", done: true, when: Self.night)])
        #expect(Set(FilmNights.steps(wanted: left, placed: mine, others: [], known: ["l1"], now: Self.now).map { "\($0)" })
                == Set([FilmNights.Step.remove(id: "e1"), .remove(id: "e2")].map { "\($0)" }))
        // A night already past, and another server's list, are left alone.
        let past = Self.placed("l1/a", at: Self.now.addingTimeInterval(-600))
        let theirs = Self.placed("zz/a", at: Self.night, id: "e3", external: "x3")
        #expect(FilmNights.steps(wanted: [], placed: [past, theirs], others: [], known: ["l1"], now: Self.now).isEmpty)
    }

    @Test func twoMadeAtOnceOnTwoDevicesAreMadeOne() {
        let elf = wanted([.init(id: "a", text: "Elf", done: false, when: Self.night)])
        let ipad = Self.placed("l1/a", at: Self.night, id: "here-2", external: "B")
        let iphone = Self.placed("l1/a", at: Self.night, id: "here-1", external: "A")
        #expect(FilmNights.steps(wanted: elf, placed: [ipad, iphone], others: [], known: ["l1"], now: Self.now) == [.remove(id: "here-2")],
                "every device keeps the one whose server identifier sorts first")
    }

    @Test func oneTheAgentAddedIsTakenOverNotDoubled() {
        let elf = wanted([.init(id: "a", text: "Elf", done: false, when: Self.night)])
        let agents = FilmNights.Other(id: "g1", title: "Movie night: Elf", start: Self.night.addingTimeInterval(20), editable: true)
        #expect(FilmNights.steps(wanted: elf, placed: [], others: [agents], known: ["l1"], now: Self.now) == [.adopt(id: "g1", elf[0])])
        var readOnly = agents
        readOnly.editable = false
        #expect(FilmNights.steps(wanted: elf, placed: [], others: [readOnly], known: ["l1"], now: Self.now).isEmpty)
        let dinner = FilmNights.Other(id: "g2", title: "Dinner with the Hendersons", start: Self.night, editable: true)
        #expect(FilmNights.steps(wanted: elf, placed: [], others: [dinner], known: ["l1"], now: Self.now) == [.add(elf[0])])
    }

    // MARK: The lists

    private static let answer = """
    redde-push lists {"lists": [{"id": "l1", "title": "Christmas Movies", "kind": "watch", "emoji": "🎄", "color": "red",
      "items": [{"id": "a", "text": "Elf", "done": false, "when": "2026-12-05T21:00-05:00"}]}]}
    """

    private nonisolated final class Placings: @unchecked Sendable {
        var lists: [[TodayList]] = []
        var known: [Set<String>] = []
    }

    private func lists(answer: @escaping () -> String, mine: Bool = true, asked: @escaping (String) -> Void = { _ in }) -> (TodayLists, Placings) {
        let store = TodayLists()
        store.defaults = UserDefaults(suiteName: "FilmNightsTests-\(UUID().uuidString)")
        store.settingsStore = UserDefaults(suiteName: "FilmNightsTests-settings-\(UUID().uuidString)")!
        store.plugin = { words in
            asked(words)
            return words.hasPrefix("lists nights") ? #"redde-push lists {"nights": true, "by": "x", "mine": \#(mine)}"# : answer()
        }
        store.reachable = { true }
        store.dueReminders = { _ in [] }
        store.canPlaceNights = { true }
        let placings = Placings()
        store.placeNights = { lists, known in placings.lists.append(lists); placings.known.append(known) }
        return (store, placings)
    }

    @Test func theListsAsTheyAreGoToTheCalendarAndAListGoneIsStillKnown() async {
        var answer = Self.answer
        let (store, placings) = lists(answer: { answer })
        await store.refresh()
        await store.settleNights()
        #expect(placings.lists.last?.first?.items.first?.when != nil)
        #expect(placings.known.last == ["l1"])
        answer = #"redde-push lists {"lists": []}"#
        await store.refresh()
        await store.settleNights()
        #expect(placings.lists.last?.isEmpty == true)
        #expect(placings.known.last == ["l1"], "its nights ahead are taken off")
        store.addsNights = false
        await store.refresh()
        await store.settleNights()
        #expect(placings.lists.count == 2, "switched off: the calendar is left as it is")
    }

    @Test func onlyTheDeviceThePluginGivesItToKeepsTheCalendar() async {
        // 1.51: the iPad, asking after the iPhone, leaves the calendar to it.
        var asked: [String] = []
        let (pad, placings) = lists(answer: { Self.answer }, mine: false, asked: { asked.append($0) })
        await pad.refresh()
        await pad.settleNights()
        #expect(!pad.ownsNights)
        #expect(placings.lists.isEmpty)
        pad.addsNights = false
        await pad.tellNights(now: .now.addingTimeInterval(13 * 3600))
        #expect(!asked.contains { $0.hasPrefix("lists nights off") }, "not its to let go")
        // A plugin before 1.51 says nothing of whose it is: no device keeps it.
        let (old, oldPlacings) = lists(answer: { Self.answer })
        old.plugin = { words in words.hasPrefix("lists nights") ? "redde-push lists: this command is for the Redde app." : Self.answer }
        await old.refresh()
        await old.settleNights()
        #expect(!old.ownsNights && oldPlacings.lists.isEmpty)
    }

    @Test func thePluginIsAskedTwiceADayAndLetGoWhenItsSwitchedOff() async {
        var asked: [String] = []
        let (store, _) = lists(answer: { Self.answer }, asked: { asked.append($0) })
        await store.tellNights(now: Self.now)
        await store.tellNights(now: Self.now.addingTimeInterval(3600))
        #expect(asked.count == 1 && asked[0].hasPrefix("lists nights on ") && asked[0].count > "lists nights on ".count + 30)
        #expect(store.ownsNights)
        await store.tellNights(now: Self.now.addingTimeInterval(13 * 3600))
        #expect(asked.count == 2 && asked[1] == asked[0], "the same device each time")
        store.addsNights = false
        await store.tellNights(now: Self.now.addingTimeInterval(14 * 3600))
        await store.tellNights(now: Self.now.addingTimeInterval(15 * 3600))
        #expect(asked.count == 3 && asked[2] == asked[0].replacingOccurrences(of: "nights on", with: "nights off"))
        #expect(!store.ownsNights)
        // Never on, never told.
        var none: [String] = []
        let (quiet, _) = lists(answer: { Self.answer }, asked: { none.append($0) })
        quiet.canPlaceNights = { false }
        await quiet.tellNights(now: Self.now)
        #expect(none.isEmpty)
    }

    // MARK: The calendar itself

    /// On a simulator that lets Redde at its calendar (`xcrun simctl privacy <udid> grant calendar
    /// com.goosehouse.echo`): made, moved, and taken off again.
    @Test(.enabled(if: EKEventStore.authorizationStatus(for: .event) == .fullAccess))
    func onTheRealCalendar() async throws {
        let list = "test" + UUID().uuidString.prefix(8).lowercased()
        let night = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: .now))!.addingTimeInterval(20 * 3600)
        func lists(_ when: Date?, done: Bool = false) -> [TodayList] {
            [Self.watch([.init(id: "a", text: "Elf", done: done, when: when)], id: list)]
        }
        func mine() async -> [(start: Date, title: String)] {
            await CalendarReader.shared.read { store in
                store.events(matching: store.predicateForEvents(withStart: .now, end: .now.addingTimeInterval(FilmNights.reach), calendars: nil))
                    .filter { FilmNights.key(of: $0.url) == "\(list)/a" }.map { ($0.startDate, $0.title ?? "") }
            }
        }
        defer { Task { await FilmNights.place([], known: [list]) } }
        guard await FilmNights.place(lists(night), known: [list]) == [.add(FilmNights.wanted(lists(night), now: .now)[0])] else {
            Issue.record("no calendar to add to on this simulator")
            return
        }
        #expect(await mine().map(\.start) == [night])
        #expect(await mine().first?.title == "🎄 Elf")
        #expect(await FilmNights.place(lists(night), known: [list])?.isEmpty == true, "in place: nothing to do")
        let later = night.addingTimeInterval(86_400)
        _ = await FilmNights.place(lists(later), known: [list])
        #expect(await mine().map(\.start) == [later])
        _ = await FilmNights.place(lists(later, done: true), known: [list])
        #expect(await mine().isEmpty)

        // Two made by 6b1efc5 on two devices, kept without their URL: made one, its address added.
        let night2 = night.addingTimeInterval(2 * 86_400)
        let wanted2 = FilmNights.wanted(lists(night2), now: .now)
        await CalendarReader.shared.read { store in
            for _ in 0 ..< 2 {
                let event = EKEvent(eventStore: store)
                event.calendar = DeviceCalendar.newEventsCalendar(in: store)
                event.title = wanted2[0].title
                event.startDate = night2
                event.endDate = night2.addingTimeInterval(FilmNights.length)
                event.notes = wanted2[0].notes
                try? store.save(event, span: .thisEvent, commit: true)
            }
        }
        _ = await FilmNights.place(lists(night2), known: [list])
        let left = await CalendarReader.shared.read { store in
            store.events(matching: store.predicateForEvents(withStart: night2.addingTimeInterval(-60), end: night2.addingTimeInterval(60), calendars: nil))
                .filter { $0.title == wanted2[0].title }.map { $0.notes ?? "" }
        }
        #expect(left == [wanted2[0].notes + "\nredde://list/\(list)/a"])
        _ = await FilmNights.place([], known: [list])
        #expect(await mine().isEmpty)
    }
}
