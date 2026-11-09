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
}
