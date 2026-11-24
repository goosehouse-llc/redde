import Foundation
import Testing
@testable import Echo

/// The person's lists on the Today row (2026-11-09, plugin 1.20's `lists list` / `lists do`): what
/// the plugin says is read, a tap changes the list here at once and asks the plugin, and the
/// plugin's answer is the list from then on.
@MainActor
struct TodayListsTests {
    static let answer = """
    redde-push lists {"lists": [{"id": "l1", "title": "Groceries", "changed": 1000,
      "items": [{"id": "a", "text": "Milk", "done": false}, {"id": "b", "text": "Eggs", "done": true}]}]}
    """

    private func store(_ plugin: @escaping PushService.PluginCommand) -> TodayLists {
        let lists = TodayLists()
        lists.defaults = UserDefaults(suiteName: "TodayListsTests-\(UUID().uuidString)")
        lists.plugin = plugin
        lists.reachable = { true }
        return lists
    }

    /// The By When layout: Wednesday, November 25, 2026, 3 PM, a week that starts on Monday.
    @Test func sortsWhatsLeftByWhen() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        calendar.firstWeekday = 2
        func at(_ day: Int, _ hour: Int, month: Int = 11) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour)))
        }
        let now = try at(25, 15)
        let list = TodayList(id: "l", title: "To Do", items: [
            .init(id: "none-1", text: "No day", done: false),
            .init(id: "later", text: "Monday next week", done: false, when: try at(30, 0)),
            .init(id: "sun", text: "Sunday night", done: false, when: try at(29, 23)),
            .init(id: "fri", text: "Friday", done: false, when: try at(27, 9)),
            .init(id: "evening", text: "This evening", done: false, when: try at(25, 19)),
            .init(id: "morning", text: "Earlier today", done: false, when: try at(25, 8)),
            .init(id: "late", text: "Last night", done: false, when: try at(24, 23)),
            .init(id: "none-2", text: "No day either", done: false),
            .init(id: "gone", text: "Finished", done: true, when: try at(25, 9)),
        ], kind: .todo)
        let groups = list.openByWhen(now: now, calendar: calendar)
        #expect(groups.map(\.when) == [.overdue, .today, .thisWeek, .later, .anytime])
        #expect(groups.map { $0.items.map(\.id) } == [["late"], ["morning", "evening"], ["fri", "sun"], ["later"], ["none-1", "none-2"]])
    }

    @Test func leavesOutEmptyGroupsAndNonToDoLists() {
        let plain = TodayList(id: "l", title: "To Do", items: [.init(id: "a", text: "A", done: false)], kind: .todo)
        #expect(plain.openByWhen().map(\.when) == [.anytime])
        #expect(TodayList(id: "e", title: "Empty", items: []).openByWhen().isEmpty)
        #expect(TodayList(id: "n", title: "Old", items: []).groupsByWhen)
        for kind in [TodayList.Kind.watch, .shopping, .reading, .packing, .gifts] {
            #expect(!TodayList(id: "k", title: "K", items: [], kind: kind).groupsByWhen)
        }
    }

    @Test func aPlansTimeKeepsWhoItsWith() throws {
        let when = try #require(TodayList.planDate("2026-11-26T19:30-05:00"))
        let alone = TodayList.Item(id: "a", text: "A", done: false, when: when)
        let together = TodayList.Item(id: "b", text: "B", done: false, when: when, company: "Robin")
        #expect(TodayList.Item(id: "c", text: "C", done: false).timeAndCompany == nil)
        #expect(alone.timeAndCompany == when.formatted(.dateTime.hour().minute()))
        #expect(try #require(together.timeAndCompany).hasSuffix("Robin"))
        #expect(try #require(together.plan).hasSuffix("Robin"))
    }

    private func sentChange(_ words: String?) throws -> JSONValue {
        let sent = try #require(words)
        var encoded = String(sent.dropFirst("lists do ".count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return try JSONDecoder().decode(JSONValue.self, from: try #require(Data(base64Encoded: encoded)))
    }

    private static let dated = """
    redde-push lists {"lists": [{"id": "l1", "title": "To Do", "kind": "todo", "items": [
      {"id": "a", "text": "Call", "done": false, "when": "2026-11-26T19:30-05:00", "with": "Robin"}]}]}
    """

    @Test func movingADateKeepsWhoItsWithAndRemovingItClearsBoth() async throws {
        var asked: [String] = []
        let lists = store { words in asked.append(words); return Self.dated }
        await lists.refresh()
        let list = try #require(lists.lists.first)
        let moved = Date(timeIntervalSince1970: 1_800_000_000)
        lists.setDate(moved, for: list.items[0], in: list)
        #expect(lists.lists[0].items[0].when == moved, "moved here before the plugin answers")
        try await Task.sleep(for: .milliseconds(200))
        let plan = try sentChange(asked.last)
        #expect(plan["action"]?.string == "plan")
        #expect(plan["items"]?.array?.first?.string == "a")
        #expect(plan["with"]?.string == "Robin")
        #expect(TodayList.planDate(try #require(plan["when"]?.string)) == moved)

        lists.setDate(nil, for: list.items[0], in: list)
        #expect(lists.lists[0].items[0].when == nil && lists.lists[0].items[0].company == nil)
        try await Task.sleep(for: .milliseconds(200))
        let unplan = try sentChange(asked.last)
        #expect(unplan["action"]?.string == "unplan")
        #expect(unplan["when"] == nil)
    }

    @Test func anOlderPluginAsksForTheUpdateAndPutsTheDateBack() async throws {
        let refused = Self.dated.replacingOccurrences(of: "]}]}", with: #"]}], "said": {"error": "Unknown action 'unplan': one of show."}}"#)
        let lists = store { $0 == "lists list" ? Self.dated : refused }
        await lists.refresh()
        let list = try #require(lists.lists.first)
        lists.setDate(nil, for: list.items[0], in: list)
        try await Task.sleep(for: .milliseconds(200))
        #expect(lists.problem?.contains("1.42") == true)
        #expect(lists.lists[0].items[0].when != nil, "the plugin's answer stands")
    }

    @Test func theDatePickerOpensOnTheItemsDateOrTomorrowMorning() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 15)))
        let tomorrow = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 9)))
        let ahead = now.addingTimeInterval(86_400 * 3), past = now.addingTimeInterval(-3_600)
        #expect(TodayList.Item(id: "a", text: "A", done: false).suggestedDate(now: now, calendar: calendar) == tomorrow)
        #expect(TodayList.Item(id: "b", text: "B", done: false, when: past).suggestedDate(now: now, calendar: calendar) == tomorrow)
        #expect(TodayList.Item(id: "c", text: "C", done: false, when: ahead).suggestedDate(now: now, calendar: calendar) == ahead)
        #expect(TodayList.planRange(now: now).upperBound == now.addingTimeInterval(60 * 86_400))
    }

    @Test func aDateGoesToThePluginInThePersonsOwnTime() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let date = try #require(TodayList.planDate("2026-11-26T19:30-05:00"))
        #expect(TodayList.planText(date, timeZone: zone) == "2026-11-26T19:30:00-05:00")
    }

    @Test func readsThePluginsAnswer() throws {
        let parsed = try #require(TodayList.parse(Self.answer))
        #expect(parsed.lists.map(\.title) == ["Groceries"])
        #expect(parsed.lists[0].open.map(\.text) == ["Milk"])
        #expect(parsed.lists[0].finished.map(\.text) == ["Eggs"])
        #expect(parsed.error == nil)
        #expect(TodayList.parse("redde-push: this command is for the Redde app.") == nil, "a plugin older than 1.20")
        let refused = try #require(TodayList.parse(#"redde-push lists {"said": {"error": "No list called 'x'."}, "lists": []}"#))
        #expect(refused.error == "No list called 'x'.")
    }

    /// Plugin 1.37 (2026-11-23): a list's look, and a watch list's posters; an older plugin's
    /// lists have none, and a poster that isn't https or on their own network is dropped.
    @Test func readsAListsLookAndPosters() throws {
        let answer = #"redde-push lists {"lists": [{"id": "w", "title": "Christmas Movies", "kind": "watch", "emoji": "🎄", "color": "red", "items": ["#
            + #"{"id": "a", "text": "Home Alone (1990)", "done": false, "poster": "https://upload.wikimedia.org/h.jpg", "year": 1990},"#
            + #"{"id": "b", "text": "Elf", "done": true, "poster": "http://img.example.com/elf.jpg"},"#
            + #"{"id": "c", "text": "Die Hard", "done": false, "poster": "http://100.101.12.34:8096/Items/d/Images/Primary", "when": "2026-11-26T19:30-05:00", "with": "Robin"}]},"#
            + #"{"id": "o", "title": "Odd", "kind": "boat", "emoji": "hello", "color": "plaid", "items": []}]}"#
        let lists = try #require(TodayList.parse(answer)).lists
        let films = lists[0]
        #expect(films.kind == .watch && films.emoji == "🎄" && films.hue == .red)
        #expect(films.items.map(\.poster) == ["https://upload.wikimedia.org/h.jpg", nil, "http://100.101.12.34:8096/Items/d/Images/Primary"])
        #expect(films.items[0].year == 1990 && films.items[0].name == "Home Alone")
        #expect(films.items[2].when == Date(timeIntervalSince1970: 1_795_739_400) && films.items[2].company == "Robin", "a plan (plugin 1.38)")
        #expect(films.items[0].when == nil && films.items[0].plan == nil)
        #expect(lists[1].kind == nil && lists[1].emoji == nil && lists[1].hue == nil, "what it can't use is left out")
        let old = try #require(TodayList.parse(Self.answer)).lists[0]
        #expect(old.kind == nil && old.emoji == nil)
    }

    @Test func refreshTakesTheLists() async {
        let lists = store { _ in Self.answer }
        await lists.refresh()
        #expect(lists.lists.map(\.id) == ["l1"])
    }

    @Test func aTapChangesItAtOnceAndAsksThePlugin() async throws {
        var asked: [String] = []
        let lists = store { words in
            asked.append(words)
            guard words != "lists list" else { return Self.answer }
            return Self.answer.replacingOccurrences(of: #""text": "Milk", "done": false"#, with: #""text": "Milk", "done": true"#)
        }
        await lists.refresh()
        let list = try #require(lists.lists.first)
        lists.toggle(list.items[0], in: list)
        #expect(lists.lists[0].items[0].done, "checked here before the plugin answers")
        try await Task.sleep(for: .milliseconds(200))
        let sent = try #require(asked.last)
        #expect(sent.hasPrefix("lists do "))
        var encoded = String(sent.dropFirst("lists do ".count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        let change = try JSONDecoder().decode(JSONValue.self, from: try #require(Data(base64Encoded: encoded)))
        #expect(change["action"]?.string == "check")
        #expect(change["list"]?.string == "l1")
        #expect(change["items"]?.array?.first?.string == "a", "the item by its id")
        #expect(lists.lists[0].items[0].done)
    }

    @Test func theAnswerWinsOverWhatWasGuessed() async throws {
        let lists = store { words in words == "lists list" ? Self.answer : #"redde-push lists {"said": {"added": 1}, "lists": []}"# }
        await lists.refresh()
        let list = try #require(lists.lists.first)
        lists.add("Bread", to: list)
        #expect(lists.lists[0].items.map(\.text) == ["Milk", "Eggs", "Bread"])
        try await Task.sleep(for: .milliseconds(200))
        #expect(lists.lists.isEmpty, "deleted on the Hermes meanwhile: the plugin's answer is the lists now")
    }

    @Test func anOldPluginIsSaid() async throws {
        let lists = store { words in words == "lists list" ? Self.answer : "redde-push: this command is for the Redde app." }
        await lists.refresh()
        let list = try #require(lists.lists.first)
        lists.clearDone(in: list)
        #expect(lists.lists[0].items.map(\.text) == ["Milk"])
        try await Task.sleep(for: .milliseconds(200))
        #expect(lists.problem?.contains("1.20") == true)
    }

    private static func decoded(_ sent: String) throws -> JSONValue {
        var encoded = String(sent.dropFirst("lists do ".count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return try JSONDecoder().decode(JSONValue.self, from: try #require(Data(base64Encoded: encoded)))
    }

    /// Make It a List (2026-11-09): a checklist card's items on a new list, then the ones done
    /// there ticked, by the ids the plugin gave the new items.
    @Test func makeItAListKeepsWhatWasDone() async throws {
        var asked: [JSONValue] = []
        let made = """
        redde-push lists {"said": {"made": "n1", "title": "Packing"}, "lists": [{"id": "n1", "title": "Packing",
          "items": [{"id": "x1", "text": "Tent", "done": false}, {"id": "x2", "text": "Stove", "done": false},
                    {"id": "x3", "text": "Sunscreen SPF 50", "done": false}]}]}
        """
        let lists = store { words in
            if words == "lists list" { return #"redde-push lists {"lists": []}"# }
            asked.append(try Self.decoded(words))
            return asked.count == 1 ? made : made.replacingOccurrences(of: #""text": "Stove", "done": false"#, with: #""text": "Stove", "done": true"#)
        }
        await lists.refresh()
        #expect(lists.available)
        let result = await lists.make("Packing", items: [(text: "Tent", done: false), (text: "Stove", done: true), (text: "Sunscreen SPF 50", done: false)])
        #expect(result == .made("Packing"))
        #expect(asked.count == 2)
        #expect(asked[0]["action"]?.string == "make")
        #expect(asked[0]["items"]?.array?.compactMap(\.string) == ["Tent", "Stove", "Sunscreen SPF 50"])
        #expect(asked[1]["action"]?.string == "check")
        #expect(asked[1]["list"]?.string == "n1")
        #expect(asked[1]["items"]?.array?.compactMap(\.string) == ["x2"])
        #expect(lists.lists.first?.finished.map(\.text) == ["Stove"])
    }

    @Test func aListOfThatNameTakesTheItems() async throws {
        let lists = store { words in
            words == "lists list" ? Self.answer
                : #"redde-push lists {"said": {"already_there": "l1"}, "lists": [{"id": "l1", "title": "Groceries", "items": [{"id": "a", "text": "Milk", "done": false}, {"id": "c", "text": "Bread", "done": false}]}]}"#
        }
        await lists.refresh()
        #expect(await lists.make("groceries", items: [(text: "Bread", done: false)]) == .added("Groceries"))
        #expect(lists.lists[0].items.map(\.text) == ["Milk", "Bread"])
    }

    @Test func listsAreOfferedOnlyWhereThePluginAnswers() async {
        let old = store { _ in "redde-push: this command is for the Redde app." }
        await old.refresh()
        #expect(!old.available)
        #expect(await old.make("Packing", items: [(text: "Tent", done: false)]) != .made("Packing"))
    }

    // MARK: Reminders on their day

    private func reminderStore(lists json: String, _ asked: @escaping (JSONValue) -> String) -> TodayLists {
        let lists = store { words in
            if words == "lists list" { return "redde-push lists " + json }
            return asked(try Self.decoded(words))
        }
        lists.settingsStore = UserDefaults(suiteName: "TodayListsTests-settings-\(UUID().uuidString)")!
        return lists
    }

    @Test func remindersDueGoOnANewToDoListOnce() async throws {
        var asked: [JSONValue] = []
        let lists = reminderStore(lists: #"{"lists": []}"#) { change in
            asked.append(change)
            return #"redde-push lists {"said": {"made": "t1"}, "lists": [{"id": "t1", "title": "To Do", "items": [{"id": "a", "text": "BP", "done": false}, {"id": "b", "text": "Car payment", "done": false}]}]}"#
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        lists.finishedReminders = { _ in [] }
        lists.dueReminders = { _ in [] }
        await lists.refresh()   // (with the real clock: nothing due yet)
        lists.dueReminders = { end in
            #expect(end > now && end < now.addingTimeInterval(86400), "by the end of today")
            return [.init(id: "r1", title: "BP", due: now.addingTimeInterval(-9 * 86400)), .init(id: "r2", title: "Car payment", due: now)]
        }
        await lists.addDueReminders(now: now)
        #expect(asked.count == 1)
        #expect(asked.first?["action"]?.string == "make")
        #expect(asked.first?["title"]?.string == "To Do")
        #expect(asked.first?["items"]?.array?.compactMap(\.string) == ["BP", "Car payment"], "overdue first")
        await lists.addDueReminders(now: now)
        #expect(asked.count == 1, "each reminder once")
    }

    @Test func onlyWhatIsntThereAlready() async throws {
        var asked: [JSONValue] = []
        let lists = reminderStore(lists: #"{"lists": [{"id": "t1", "title": "To-do", "items": [{"id": "a", "text": "bp", "done": false}]}]}"#) { change in
            asked.append(change)
            return #"redde-push lists {"said": {"added": 1}, "lists": [{"id": "t1", "title": "To-do", "items": [{"id": "a", "text": "bp", "done": false}, {"id": "b", "text": "Dentist", "done": false}]}]}"#
        }
        lists.dueReminders = { _ in [.init(id: "r1", title: "BP", due: .now), .init(id: "r2", title: "Dentist", due: .now)] }
        lists.finishedReminders = { _ in [] }
        await lists.refresh()
        #expect(asked.count == 1)
        #expect(asked.first?["action"]?.string == "add")
        #expect(asked.first?["list"]?.string == "t1", "\"To-do\" is the To Do list")
        #expect(asked.first?["items"]?.array?.compactMap(\.string) == ["Dentist"])
    }

    @Test func doneInRemindersIsTickedHere() async throws {
        var asked: [JSONValue] = []
        let lists = reminderStore(lists: #"{"lists": [{"id": "t1", "title": "To Do", "items": [{"id": "a", "text": "Dentist", "done": false}]}]}"#) { change in
            asked.append(change)
            return #"redde-push lists {"said": {}, "lists": [{"id": "t1", "title": "To Do", "items": [{"id": "a", "text": "Dentist", "done": true}]}]}"#
        }
        var done: Set<String> = []
        lists.dueReminders = { _ in done.isEmpty ? [.init(id: "r2", title: "Dentist", due: .now)] : [] }
        lists.finishedReminders = { ids in ids.intersection(done) }
        await lists.refresh()
        #expect(asked.isEmpty, "already on the list by its words")
        done = ["r2"]
        await lists.addDueReminders()
        #expect(asked.first?["action"]?.string == "check")
        #expect(asked.first?["items"]?.array?.compactMap(\.string) == ["a"])
        #expect(lists.lists.first?.items.first?.done == true)
    }

    @Test func remindersCanBeTurnedOff() async {
        var asked = 0
        let lists = reminderStore(lists: #"{"lists": []}"#) { _ in asked += 1; return "" }
        lists.addsReminders = false
        lists.dueReminders = { _ in [.init(id: "r1", title: "BP", due: .now)] }
        await lists.refresh()
        #expect(asked == 0)
    }
}
