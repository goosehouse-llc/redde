import Foundation
import Observation

/// The person's lists (asked 2026-11-09: "the ability to ask for a to do list, add things to it,
/// check them off … added to a today card that stays just to the right of email"): kept on the
/// Hermes by Redde's plugin 1.20 (`lists.py`, the agent's `redde_list`), shared by every bot, and
/// each one a tile on the Today row after the Inbox until it is deleted. Not the agent's own todo
/// list (`TodoList`), which is its plan for one turn.
nonisolated struct TodayList: Codable, Equatable, Identifiable, Sendable {
    struct Item: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var text: String
        var done: Bool
    }

    var id: String
    var title: String
    var items: [Item]

    var open: [Item] { items.filter { !$0.done } }
    var finished: [Item] { items.filter(\.done) }

    /// The plugin's `lists list` and `lists do` answers: "redde-push lists {…}". Nil for anything
    /// else (a plugin older than 1.20 answers with its usage).
    static func parse(_ output: String) -> (lists: [TodayList], error: String?)? {
        guard output.hasPrefix("redde-push lists "), let start = output.firstIndex(of: "{"),
              let json = try? JSONDecoder().decode(JSONValue.self, from: Data(output[start...].utf8)),
              let found = json["lists"]?.array else { return nil }
        let lists = found.compactMap { l -> TodayList? in
            guard let id = l["id"]?.string, !id.isEmpty else { return nil }
            let items = (l["items"]?.array ?? []).compactMap { i -> Item? in
                guard let id = i["id"]?.string, !id.isEmpty else { return nil }
                return Item(id: id, text: i["text"]?.string ?? "", done: i["done"]?.bool ?? false)
            }
            return TodayList(id: id, title: l["title"]?.string ?? "", items: items)
        }
        return (lists, json["said"]?["error"]?.string)
    }

    /// What the plugin said it did, from a `lists do` answer: `made` or `already_there` hold the id
    /// of the list a `make` went to.
    static func said(_ output: String) -> JSONValue? {
        guard output.hasPrefix("redde-push lists "), let start = output.firstIndex(of: "{"),
              let json = try? JSONDecoder().decode(JSONValue.self, from: Data(output[start...].utf8)) else { return nil }
        return json["said"]
    }
}

/// The lists on this device, for the Today row: kept in the app group so the tiles show at once,
/// asked of the plugin when the chat list shows, when Redde comes to the front and after an agent
/// changed one (`Conversation`, on `redde_list`). A tap changes the list here at once and on the
/// Hermes right after; what the plugin answers is the list from then on.
@MainActor
@Observable
final class TodayLists {
    static let shared = TodayLists()
    static let tool = "redde_list"

    private(set) var lists: [TodayList] = []
    /// The plugin answered for lists on this server (1.20 or later, over the Dashboard): what
    /// Make It a List and Add to a List wait for, so neither is offered where it can't work.
    private(set) var available = false
    /// The list open in its sheet.
    var shownID: String?
    /// The last change that didn't reach the Hermes, said in the list's sheet.
    var problem: String?

    @ObservationIgnored var plugin: PushService.PluginCommand = PushService.command(over: .shared)
    @ObservationIgnored var reachable: () async -> Bool = { await HermesServeClient.shared.canUse() }
    @ObservationIgnored var defaults: UserDefaults? = NeedsYou.shared
    @ObservationIgnored private var server: () -> String = { Settings.shared.activeServerID.uuidString }
    /// One change at a time, in the order they were made.
    @ObservationIgnored private var sending: Task<Void, Never>?

    private static let key = "todayLists"

    private struct Snapshot: Codable {
        var server: String
        var lists: [TodayList]
    }

    init() {
        #if DEBUG
        // (`-echo.showList` opens the first in its sheet.)
        if Self.demo { lists = Self.demoLists; available = true; if DevHooks.has("-echo.showList") { shownID = lists.first?.id }; return }
        #endif
        restore()
    }

    var shown: TodayList? { shownID.flatMap { id in lists.first { $0.id == id } } }

    /// The cached lists, if they are this server's.
    func restore() {
        guard let data = defaults?.data(forKey: Self.key), let kept = try? JSONDecoder().decode(Snapshot.self, from: data),
              kept.server == server() else { lists = []; available = false; return }
        lists = kept.lists
        available = true
    }

    private func keep() {
        guard let data = try? JSONEncoder().encode(Snapshot(server: server(), lists: lists)) else { return }
        defaults?.set(data, forKey: Self.key)
    }

    private func take(_ fresh: [TodayList]) {
        if fresh != lists { lists = fresh }
        if let id = shownID, !fresh.contains(where: { $0.id == id }) { shownID = nil }
        keep()
    }

    /// Asks the plugin for every list. Says nothing when there's no Dashboard or the plugin is older.
    func refresh() async {
        #if DEBUG
        if Self.demo { return }
        #endif
        restore()
        guard await reachable(), let output = try? await plugin("lists list") else { return }
        guard let parsed = TodayList.parse(output) else { available = false; return }   // a plugin older than 1.20
        available = true
        // (A change sent meanwhile is newer than this answer: its own answer will say the lists.)
        guard sending == nil else { return }
        take(parsed.lists)
    }

    // MARK: From a reply

    /// What became of Make It a List or Add to a List.
    enum Made: Equatable {
        /// A new list, with this title.
        case made(String)
        /// Onto the list of that title that was there already.
        case added(String)
        case failed(String)
    }

    /// A new list with these items, ticked as they were (a checklist card's Make It a List), or,
    /// when a list of that title is there already, the items onto it, as the agent's `make` does.
    func make(_ title: String, items: [(text: String, done: Bool)]) async -> Made {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = items.map { (text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), done: $0.done) }.filter { !$0.text.isEmpty }
        guard !title.isEmpty else { return .failed(String(localized: "A list needs a name.", comment: "Make It a List / Add to a List: no title")) }
        #if DEBUG
        if Self.demo {
            lists.append(TodayList(id: UUID().uuidString, title: title,
                                   items: items.map { .init(id: UUID().uuidString, text: $0.text, done: $0.done) }))
            return .made(title)
        }
        #endif
        await sending?.value
        do {
            let answer = try await run(["action": .string("make"), "title": .string(title), "items": .array(items.map { .string($0.text) })])
            let said = TodayList.said(answer.output)
            if let error = said?["error"]?.string { return .failed(error) }
            guard let id = said?["made"]?.string ?? said?["already_there"]?.string,
                  let list = answer.lists.first(where: { $0.id == id }) else { take(answer.lists); return .failed(Self.tooOld) }
            // The items just added are the list's last ones, in order: tick the ones that were done.
            let added = list.items.suffix(items.count)
            let ticks = zip(added, items).filter { $0.1.done }.map { JSONValue.string($0.0.id) }
            if !ticks.isEmpty, let ticked = try? await run(["action": .string("check"), "list": .string(id), "items": .array(ticks)]) {
                take(ticked.lists)
            } else {
                take(answer.lists)
            }
            return said?["made"] != nil ? .made(list.title) : .added(list.title)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// One line onto a list that is there (Add to a List): at once here, then on the Hermes.
    func add(_ text: String, toList id: String) {
        guard let list = lists.first(where: { $0.id == id }) else { return }
        add(text, to: list)
    }

    nonisolated private static var tooOld: String {
        String(localized: "Your Hermes needs Redde's plugin 1.20 or later for lists. Update it in Settings › Redde Plugin.",
               comment: "A to-do list's sheet: the server's plugin is too old")
    }

    /// One `lists do`, and the lists as the plugin says they are after it.
    private func run(_ args: [String: JSONValue]) async throws -> (output: String, lists: [TodayList]) {
        guard await reachable() else {
            throw Unreachable()
        }
        let encoded = Self.encode(args)
        let output = try await plugin("lists do " + encoded)
        guard let parsed = TodayList.parse(output) else { throw TooOld() }
        return (output, parsed.lists)
    }

    nonisolated private struct Unreachable: LocalizedError {
        var errorDescription: String? {
            String(localized: "Couldn't reach your Hermes. Try again when Redde is connected.",
                   comment: "Make It a List / Add to a List: the server couldn't be reached")
        }
    }

    nonisolated private struct TooOld: LocalizedError {
        var errorDescription: String? { TodayLists.tooOld }
    }

    private static func encode(_ args: [String: JSONValue]) -> String {
        guard let data = try? JSONEncoder().encode(JSONValue.object(args)) else { return "" }
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: Changes

    func toggle(_ item: TodayList.Item, in list: TodayList) {
        // The same reminder in Reminders, ticked too, where there is one.
        let text = item.text, ticking = !item.done
        Task { await DeviceCalendar.tick(text, done: ticking) }
        apply(list.id, ["action": .string(item.done ? "uncheck" : "check"), "items": .array([.string(item.id)])]) { kept in
            if let i = kept.items.firstIndex(where: { $0.id == item.id }) { kept.items[i].done.toggle() }
        }
    }

    func add(_ text: String, to list: TodayList) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        apply(list.id, ["action": .string("add"), "items": .array([.string(text)])]) { kept in
            kept.items.append(.init(id: "new-" + UUID().uuidString, text: text, done: false))
        }
    }

    func remove(_ items: [TodayList.Item], from list: TodayList) {
        guard !items.isEmpty else { return }
        let ids = Set(items.map(\.id))
        apply(list.id, ["action": .string("remove"), "items": .array(items.map { .string($0.id) })]) { kept in
            kept.items.removeAll { ids.contains($0.id) }
        }
    }

    func clearDone(in list: TodayList) {
        apply(list.id, ["action": .string("clear_done")]) { kept in kept.items.removeAll(where: \.done) }
    }

    func rename(_ list: TodayList, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != list.title else { return }
        apply(list.id, ["action": .string("rename"), "title": .string(title)]) { kept in kept.title = title }
    }

    func delete(_ list: TodayList) {
        if shownID == list.id { shownID = nil }
        apply(list.id, ["action": .string("delete")], delete: true) { _ in }
    }

    /// Changes the list here at once, then on the Hermes; the plugin's answer is the lists from
    /// then on, and a change it couldn't make puts back what it says.
    private func apply(_ id: String, _ change: [String: JSONValue], delete: Bool = false, here: (inout TodayList) -> Void) {
        guard let i = lists.firstIndex(where: { $0.id == id }) else { return }
        if delete { lists.remove(at: i) } else { here(&lists[i]) }
        keep()
        problem = nil
        #if DEBUG
        if Self.demo { return }
        #endif
        var args = change
        args["list"] = .string(id)
        let encoded = Self.encode(args)
        guard !encoded.isEmpty else { return }
        let before = sending
        let task = Task { [weak self] in
            await before?.value
            guard let self else { return }
            await self.send(encoded)
        }
        sending = task
        Task { [weak self] in
            await task.value
            if self?.sending == task { self?.sending = nil }
        }
    }

    private func send(_ encoded: String) async {
        guard await reachable() else {
            problem = String(localized: "Couldn't reach your Hermes, so this change is only on this device for now.",
                             comment: "A to-do list's sheet: a change that didn't reach the server")
            return
        }
        do {
            let output = try await plugin("lists do " + encoded)
            guard let parsed = TodayList.parse(output) else {
                problem = Self.tooOld
                return
            }
            if let error = parsed.error { problem = error }
            take(parsed.lists)
        } catch {
            problem = error.localizedDescription
        }
    }

    #if DEBUG
    /// `-echo.demoLists`: two made-up lists, for screenshots.
    static var demo: Bool { DevHooks.has("-echo.demoLists") }

    static let demoLists: [TodayList] = [
        TodayList(id: "groceries", title: "Groceries", items: [
            .init(id: "g1", text: "Oat milk", done: false), .init(id: "g2", text: "Eggs", done: true),
            .init(id: "g3", text: "Sourdough", done: false), .init(id: "g4", text: "Lemons", done: false),
            .init(id: "g5", text: "Coffee beans", done: true)]),
        TodayList(id: "todo", title: "To Do", items: [
            .init(id: "t1", text: "Call the vet about Friday", done: false), .init(id: "t2", text: "Renew the car registration", done: false),
            .init(id: "t3", text: "Send Ana the photos", done: true)]),
    ]
    #endif
}
