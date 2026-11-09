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
}
