import Foundation
import Observation

/// The person's lists (asked 2026-11-09: "the ability to ask for a to do list, add things to it,
/// check them off … added to a today card that stays just to the right of email"): kept on the
/// Hermes by Redde's plugin 1.20 (`lists.py`, the agent's `redde_list`), shared by every bot, and
/// each one a tile on the Today row after the Inbox until it is deleted. Not the agent's own todo
/// list (`TodoList`), which is its plan for one turn.
///
/// From plugin 1.37.0 (asked 2026-11-23 of a list of Christmas films: "make these lists a bit more
/// fun"), each list has a look: its kind, an emoji and a colour, the agent's or guessed from the
/// title; a watch list's films and series come with their posters.
nonisolated struct TodayList: Codable, Equatable, Identifiable, Sendable {
    struct Item: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var text: String
        var done: Bool
        /// A film's or a series' poster on a watch list (https, or on the person's own network).
        var poster: String? = nil
        var year: Int? = nil
        /// A plan (plugin 1.38): when, and with whom. Redde reminds them on the day and checks after.
        var when: Date? = nil
        var company: String? = nil

        /// "Thu, Nov 26, 7:30 PM · with Robin".
        var plan: String? {
            when.map { withCompany($0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())) }
        }

        /// "7:30 PM · with Robin", for a row that shows its day on its own.
        var timeAndCompany: String? {
            when.map { withCompany($0.formatted(.dateTime.hour().minute())) }
        }

        private func withCompany(_ at: String) -> String {
            guard let company, !company.isEmpty else { return at }
            return at + " · " + String(localized: "with \(company)", comment: "A list item's plan: who it's with, after its date (\"Thu, Nov 26, 7:30 PM · with Robin\")")
        }

        /// Where the date picker opens: its own date while that's ahead, else tomorrow at 9.
        func suggestedDate(now: Date = .now, calendar: Calendar = .current) -> Date {
            if let when, when > now { return when }
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }

        /// Its name without the year it was written with ("Home Alone (1990)").
        var name: String { text.replacing(/\s*\((?:18|19|20)\d\d\)\s*$/, with: "") }
    }

    /// What a list is for: a watch list's titles show as posters.
    enum Kind: String, Codable, Sendable, CaseIterable {
        case watch, todo, shopping, reading, packing, gifts, other
    }

    /// The colours a list can be: the plugin's names.
    enum Hue: String, Codable, Sendable, CaseIterable {
        case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, brown, gray
    }

    var id: String
    var title: String
    var items: [Item]
    var kind: Kind? = nil
    var emoji: String? = nil
    var hue: Hue? = nil

    var open: [Item] { items.filter { !$0.done } }
    var finished: [Item] { items.filter(\.done) }

    /// Where a to-do sits on its list's page (the By When layout, picked 2026-11-23).
    enum When: Hashable, Sendable {
        case overdue, today, thisWeek, later, anytime
    }

    struct WhenGroup: Identifiable, Equatable, Sendable {
        let when: When
        let items: [Item]
        var id: When { when }
    }

    /// Lists of things to do, where a date is the point: not a shopping, packing or watch list.
    var groupsByWhen: Bool { kind == nil || kind == .todo || kind == .other }

    /// What's left, soonest first: overdue (before today; earlier today is still today), today, the
    /// rest of this calendar week, later, and anytime (no date, in the list's own order). Groups
    /// with nothing in them are left out.
    func openByWhen(now: Date = .now, calendar: Calendar = .current) -> [WhenGroup] {
        let today = calendar.startOfDay(for: now)
        let weekEnd = calendar.dateInterval(of: .weekOfYear, for: now)?.end ?? today.addingTimeInterval(7 * 86_400)
        let placed = Dictionary(grouping: open) { item -> When in
            guard let date = item.when else { return .anytime }
            if date < today { return .overdue }
            if calendar.isDate(date, inSameDayAs: now) { return .today }
            return date < weekEnd ? .thisWeek : .later
        }
        return [When.overdue, .today, .thisWeek, .later, .anytime].compactMap { when in
            guard var items = placed[when] else { return nil }
            if when != .anytime { items.sort { ($0.when ?? .distantFuture) < ($1.when ?? .distantFuture) } }
            return WhenGroup(when: when, items: items)
        }
    }

    /// The plugin's `lists list` and `lists do` answers: "redde-push lists {…}". Nil for anything
    /// else (a plugin older than 1.20 answers with its usage).
    static func parse(_ output: String) -> (lists: [TodayList], error: String?)? {
        guard let json = PluginReply.json(output, "lists"), let found = json["lists"]?.array else { return nil }
        let lists = found.compactMap { l -> TodayList? in
            guard let id = l["id"]?.string, !id.isEmpty else { return nil }
            let items = (l["items"]?.array ?? []).compactMap { i -> Item? in
                guard let id = i["id"]?.string, !id.isEmpty else { return nil }
                let poster = i["poster"]?.string.flatMap { ReplyCards.https(.string($0)) ?? URL(string: $0).flatMap(ReplyCards.ownNetwork)?.absoluteString }
                return Item(id: id, text: i["text"]?.string ?? "", done: i["done"]?.bool ?? false, poster: poster,
                            year: i["year"]?.number.flatMap(\.nearestInt), when: i["when"]?.string.flatMap(planDate),
                            company: i["with"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(60)) })
            }
            let emoji = l["emoji"]?.string.flatMap { $0.count == 1 && $0.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x238C } ? $0 : nil }
            return TodayList(id: id, title: l["title"]?.string ?? "", items: items, kind: l["kind"]?.string.flatMap(Kind.init(rawValue:)),
                             emoji: emoji, hue: l["color"]?.string.flatMap(Hue.init(rawValue:)))
        }
        return (lists, json["said"]?["error"]?.string)
    }

    /// A plan's time as the plugin keeps it: "2026-11-26T19:30-05:00", seconds or not.
    static func planDate(_ text: String) -> Date? {
        for format in ["yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
            let reader = DateFormatter()
            reader.locale = Locale(identifier: "en_US_POSIX")
            reader.dateFormat = format
            if let date = reader.date(from: text) { return date }
        }
        return nil
    }

    /// A date as the plugin takes it, in the person's own time: "2026-11-26T19:30:00-05:00".
    static func planText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let writer = DateFormatter()
        writer.locale = Locale(identifier: "en_US_POSIX")
        writer.timeZone = timeZone
        writer.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return writer.string(from: date)
    }

    /// The dates a plan can take: from now to the plugin's limit, 60 days ahead.
    static func planRange(now: Date = .now) -> ClosedRange<Date> {
        now ... now.addingTimeInterval(60 * 86_400)
    }

    /// What the plugin said it did, from a `lists do` answer: `made` or `already_there` hold the id
    /// of the list a `make` went to.
    static func said(_ output: String) -> JSONValue? {
        PluginReply.json(output, "lists")?["said"]
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
    /// Apple Reminders, for `addDueReminders` (made-up ones in tests).
    @ObservationIgnored var dueReminders: (Date) async -> [DeviceCalendar.DueReminder] = { await DeviceCalendar.remindersDue(by: $0) }
    @ObservationIgnored var finishedReminders: (Set<String>) async -> Set<String> = { await DeviceCalendar.finished($0) }
    /// Settings › Chat List and Settings › Calendars: reminders onto a list on their day, and which.
    @ObservationIgnored var settingsStore: UserDefaults = .standard
    /// One change at a time, in the order they were made.
    @ObservationIgnored private var sending: Task<Void, Never>?

    private static let key = "todayLists"

    private struct Snapshot: Codable {
        var server: String
        var lists: [TodayList]
    }

    init() {
        #if DEBUG
        if Self.demo {
            lists = Self.demoLists
            if DevHooks.value("-echo.demoLists") == "house" { lists.append(Self.demoDatedList) }
            available = true
            // `-echo.demoLists films`: the watch list open at launch.
            if let open = DevHooks.value("-echo.demoLists"), lists.contains(where: { $0.id == open }) { shownID = open }
            return
        }
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
        await addDueReminders()
    }

    // MARK: Reminders on their day

    static let remindersKey = "lists.reminders"
    static let remindersListKey = "lists.remindersList"
    static let remindersListDefault = "To Do"
    private static let listedKey = "listedReminders"

    var addsReminders: Bool {
        get { settingsStore.object(forKey: Self.remindersKey) as? Bool ?? true }
        set { settingsStore.set(newValue, forKey: Self.remindersKey) }
    }

    var remindersList: String {
        get { settingsStore.string(forKey: Self.remindersListKey)?.nilIfEmpty ?? Self.remindersListDefault }
        set { settingsStore.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.remindersListKey) }
    }

    /// The list reminders go on: the one of that name (any case, spaces and dashes aside: "To-do"
    /// is "To Do"), else nil and it gets made.
    func remindersTarget() -> TodayList? {
        let key = Self.letters(remindersList)
        return lists.first { Self.letters($0.title) == key }
    }

    private static func letters(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Reminders this device put on a list, by server: their ids and the item's words.
    private var listed: [String: String] {
        get { (defaults?.dictionary(forKey: Self.listedKey)?[server()] as? [String: String]) ?? [:] }
        set {
            var all = defaults?.dictionary(forKey: Self.listedKey) ?? [:]
            all[server()] = newValue
            defaults?.set(all, forKey: Self.listedKey)
        }
    }

    /// Each reminder whose day has come (overdue ones too) onto the To Do list, once (asked
    /// 2026-11-09: "when I add a reminder … auto list in my todo list for whatever day the
    /// reminder is scheduled for"): Apple Reminders lives on the person's devices, so the phone
    /// (or the Mac) brings them, whenever the lists are read. One already on the list, open, by
    /// the same words isn't added twice (another device brought it). One done in Reminders since
    /// gets its tick here too.
    func addDueReminders(now: Date = .now) async {
        guard addsReminders, available else { return }
        #if DEBUG
        if Self.demo { return }
        #endif
        var listed = self.listed
        // Done in Reminders: ticked here (ticking here ticks Reminders already: `toggle`).
        let finished = await finishedReminders(Set(listed.keys))
        if !finished.isEmpty, let list = remindersTarget() {
            let ids = finished.compactMap { id in
                listed[id].flatMap { words in list.items.first { !$0.done && DeviceCalendar.folded($0.text) == DeviceCalendar.folded(words) }?.id }
            }
            if !ids.isEmpty, let answer = try? await run(["action": .string("check"), "list": .string(list.id), "items": .array(ids.map(JSONValue.string))]) {
                take(answer.lists)
            }
        }
        for id in finished { listed[id] = nil }

        let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(86400 - 1)
        let open = Set((remindersTarget()?.open ?? []).map { DeviceCalendar.folded($0.text) })
        let fresh = await dueReminders(endOfDay).filter { listed[$0.id] == nil }
        let adding = fresh.filter { !open.contains(DeviceCalendar.folded($0.title)) }
        defer { self.listed = listed }
        // Already there by its words: counted as listed, so a deleted one doesn't come back.
        for reminder in fresh where !adding.contains(reminder) { listed[reminder.id] = reminder.title }
        guard !adding.isEmpty else { return }
        let titles = adding.map(\.title)
        if let list = remindersTarget() {
            guard let answer = try? await run(["action": .string("add"), "list": .string(list.id), "items": .array(titles.map(JSONValue.string))]) else { return }
            take(answer.lists)
        } else {
            if case .failed = await make(remindersList, items: titles.map { (text: $0, done: false) }) { return }
        }
        for reminder in adding { listed[reminder.id] = reminder.title }
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

    nonisolated private static var datesNeedUpdate: String {
        String(localized: "Your Hermes needs Redde's plugin 1.42 or later for this. Update it in Settings › Redde Plugin.",
               comment: "A to-do list's sheet: setting or removing a date on a server with an older plugin")
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

    /// Sets, moves or (with nil) takes off a to-do's date. The plugin keeps the reminder and the
    /// check that go with it. Who it's with stays when the date moves.
    func setDate(_ date: Date?, for item: TodayList.Item, in list: TodayList) {
        var change: [String: JSONValue] = ["action": .string(date == nil ? "unplan" : "plan"), "items": .array([.string(item.id)])]
        if let date {
            change["when"] = .string(TodayList.planText(date))
            if let company = item.company { change["with"] = .string(company) }
        }
        apply(list.id, change) { kept in
            guard let i = kept.items.firstIndex(where: { $0.id == item.id }) else { return }
            kept.items[i].when = date
            if date == nil { kept.items[i].company = nil }
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

    /// A list's look: its emoji, colour or kind, the same 'style' the agent gives.
    func style(_ list: TodayList, emoji: String? = nil, hue: TodayList.Hue? = nil, kind: TodayList.Kind? = nil) {
        var change: [String: JSONValue] = ["action": .string("style")]
        if let emoji { change["emoji"] = .string(emoji) }
        if let hue { change["color"] = .string(hue.rawValue) }
        if let kind { change["kind"] = .string(kind.rawValue) }
        guard change.count > 1 else { return }
        apply(list.id, change) { kept in
            if let emoji { kept.emoji = emoji }
            if let hue { kept.hue = hue }
            if let kind { kept.kind = kind }
        }
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
            if let error = parsed.error {
                // (A plugin before 1.42 doesn't know `unplan`, before 1.38 `plan`.)
                problem = error.hasPrefix("Unknown action") ? Self.datesNeedUpdate : error
            }
            take(parsed.lists)
        } catch {
            problem = error.localizedDescription
        }
    }

    #if DEBUG
    /// `-echo.demoLists`: two made-up lists, for screenshots.
    static var demo: Bool { DevHooks.has("-echo.demoLists") }

    static let demoLists: [TodayList] = [
        TodayList(id: "films", title: "Christmas Movies", items: [
            ("Donnie Brasco", 1997, false), ("Home Alone", 1990, false), ("Elf", 2003, false), ("It's a Wonderful Life", 1946, true), ("Die Hard", 1988, false),
            ("Love Actually", 2003, false), ("Scrooged", 1988, true), ("The Polar Express", 2004, false)].enumerated().map { n, film in
                .init(id: "f\(n)", text: film.0, done: film.2, poster: "https://demo.example/posters/\(film.0.lowercased().filter { $0.isLetter || $0 == " " }.replacingOccurrences(of: " ", with: "-")).jpg",
                      year: film.1, when: n == 0 ? Calendar.current.date(byAdding: .day, value: 3, to: Calendar.current.startOfDay(for: .now))?.addingTimeInterval(19.5 * 3600) : nil,
                      company: n == 0 ? "Robin" : nil) }, kind: .watch, emoji: "🎄", hue: .red),
        TodayList(id: "groceries", title: "Groceries", items: [
            .init(id: "g1", text: "Oat milk", done: false), .init(id: "g2", text: "Eggs", done: true),
            .init(id: "g3", text: "Sourdough", done: false), .init(id: "g4", text: "Lemons", done: false),
            .init(id: "g5", text: "Coffee beans", done: true)], kind: .shopping, emoji: "🛒", hue: .green),
        TodayList(id: "todo", title: "To Do", items: [
            .init(id: "t1", text: "Call the vet about Friday", done: false), .init(id: "t2", text: "Renew the car registration", done: false),
            .init(id: "t3", text: "Send Ana the photos", done: true)], kind: .todo, emoji: "✅", hue: .blue),
    ]

    /// `-echo.demoLists house`: a made-up to-do list with something in every By When group.
    static var demoDatedList: TodayList {
        let calendar = Calendar.current
        func day(_ offset: Int, _ hour: Int) -> Date? {
            calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: .now))
                .flatMap { calendar.date(bySettingHour: hour, minute: 0, second: 0, of: $0) }
        }
        return TodayList(id: "house", title: "House To-Dos", items: [
            .init(id: "h1", text: "Pay the water bill", done: false, when: day(-1, 10)),
            .init(id: "h2", text: "Call the dentist", done: false, when: day(0, 14)),
            .init(id: "h3", text: "Renew the car registration", done: false, when: day(4, 9)),
            .init(id: "h4", text: "Return the library books", done: false, when: day(5, 11), company: "Robin"),
            .init(id: "h5", text: "Book the holiday flights", done: false, when: day(14, 18)),
            .init(id: "h6", text: "Fix the bike's back brake", done: false),
            .init(id: "h7", text: "Order a new air filter", done: false),
            .init(id: "h8", text: "Clean the gutters", done: true),
            .init(id: "h9", text: "Send Ana the signed copy", done: true)], kind: .todo, emoji: "🏠", hue: .green)
    }
    #endif
}
