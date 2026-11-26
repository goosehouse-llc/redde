import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

extension TodayList {
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
                            company: i["with"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(60)) },
                            help: i["help"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) })
            }
            let emoji = l["emoji"]?.string.flatMap { $0.count == 1 && $0.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x238C } ? $0 : nil }
            return TodayList(id: id, title: l["title"]?.string ?? "", items: items, kind: l["kind"]?.string.flatMap(Kind.init(rawValue:)),
                             emoji: emoji, hue: l["color"]?.string.flatMap(Hue.init(rawValue:)))
        }
        return (lists, json["said"]?["error"]?.string)
    }

    /// The plugin keeps help lines (1.46): its lists answer says so.
    static func helps(_ output: String) -> Bool {
        PluginReply.json(output, "lists")?["can"]?.array?.contains { $0.string == "help" } ?? false
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
    /// The plugin keeps a to-do's help line (1.46): what the Agent Can Help layout asks the agent for.
    private(set) var helps = false
    /// The list open in its sheet.
    var shownID: String?
    /// The last change that didn't reach the Hermes, said in the list's sheet.
    var problem: String?

    @ObservationIgnored var plugin: PushService.PluginCommand = PushService.command(over: .shared)
    @ObservationIgnored var reachable: () async -> Bool = { await HermesServeClient.shared.canUse() }
    @ObservationIgnored var defaults: UserDefaults? = TodayLists.appGroup
    /// The app group's defaults, once: the widgets hear of changes kept there, not a test's.
    private static let appGroup = NeedsYou.shared
    @ObservationIgnored private var server: () -> String = { Settings.shared.activeServerID.uuidString }
    /// Apple Reminders, for `addDueReminders` (made-up ones in tests).
    @ObservationIgnored var dueReminders: (Date) async -> [DeviceCalendar.DueReminder] = { await DeviceCalendar.remindersDue(by: $0) }
    @ObservationIgnored var finishedReminders: (Set<String>) async -> Set<String> = { await DeviceCalendar.finished($0) }
    /// Settings › Chat List and Settings › Calendars: reminders onto a list on their day, and which.
    @ObservationIgnored var settingsStore: UserDefaults = .standard
    /// One change at a time, in the order they were made.
    @ObservationIgnored private var sending: Task<Void, Never>?
    /// A watch list's nights onto the calendar (`FilmNights`; made-up ones in tests), one pass at a time.
    @ObservationIgnored var placeNights: @Sendable ([TodayList], Set<String>) async -> Void = { await FilmNights.place($0, known: $1) }
    @ObservationIgnored var canPlaceNights: () -> Bool = { FilmNights.canPlace }
    @ObservationIgnored private var placing: Task<Void, Never>?
    @ObservationIgnored private var placeAgain = false

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
            // `-echo.demoFilms N`: N more made-up films on the watch list, to measure a long one scrolling.
            if let more = DevHooks.value("-echo.demoFilms").flatMap(Int.init), let at = lists.firstIndex(where: { $0.id == "films" }) {
                lists[at].items += Self.demoFilms(more)
            }
            available = true
            helps = true
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
        if defaults === Self.appGroup { WidgetWriter.listsChanged(lists) }
    }

    /// Waits for the changes under way to reach the Hermes: a widget's tick, with Redde started for it.
    func settle() async {
        while let task = sending { await task.value; if sending == task { break } }
    }

    private func take(_ fresh: [TodayList]) {
        if fresh != lists { lists = fresh }
        if let id = shownID, !fresh.contains(where: { $0.id == id }) { shownID = nil }
        keep()
        placeFilmNights()
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
        helps = TodayList.helps(output)
        // (A change sent meanwhile is newer than this answer: its own answer will say the lists.)
        guard sending == nil else { return }
        take(parsed.lists)
        await addDueReminders()
        await tellNights()
    }

    // MARK: A watch list's nights on the calendar

    static let nightsKey = "lists.nights"
    private static let knownListsKey = "lists.nightsKnown"
    /// Per server: when this device last asked to keep the calendar, and whether it does (1.51).
    private static let claimKey = "lists.nightsClaim"
    private static let deviceKey = "lists.nightsDevice"

    /// Settings › Chat List and Settings › Calendars: films and series with a night go on the
    /// calendar. On by default on an iPhone only (asked 2026-11-26: the iPhone by default): an iPad or a
    /// Mac with the phone's calendar already leaves it to the phone, unless switched on there.
    var addsNights: Bool {
        get { settingsStore.object(forKey: Self.nightsKey) as? Bool ?? onPhone }
        set { settingsStore.set(newValue, forKey: Self.nightsKey) }
    }

    /// This is an iPhone (made-up in tests).
    @ObservationIgnored var onPhone: Bool = {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }()

    /// The lists this server has had: a night of one gone is taken off the calendar, one of
    /// another server's lists is left alone.
    private func knownLists() -> Set<String> {
        var known = settingsStore.dictionary(forKey: Self.knownListsKey) as? [String: [String]] ?? [:]
        let ids = Set(known[server()] ?? []).union(lists.map(\.id))
        if ids.count != known[server()]?.count {
            known[server()] = Array(ids).sorted().suffix(200).map { $0 }
            settingsStore.set(known, forKey: Self.knownListsKey)
        }
        return ids
    }

    /// This device, to the plugin: made once, kept here only (not synced, as each device is its own).
    private var nightsDevice: String {
        if let id = settingsStore.string(forKey: Self.deviceKey), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        settingsStore.set(id, forKey: Self.deviceKey)
        return id
    }

    private var claims: [String: [String: Double]] {
        get { settingsStore.dictionary(forKey: Self.claimKey) as? [String: [String: Double]] ?? [:] }
        set { settingsStore.set(newValue, forKey: Self.claimKey) }
    }

    /// The plugin said this device is the one that keeps the calendar for this server.
    var ownsNights: Bool { claims[server()]?["mine"] == 1 }

    /// Puts the watch lists' nights on the calendar as they are now, after whatever pass is under way;
    /// only on the device that keeps the calendar.
    func placeFilmNights() {
        guard addsNights, canPlaceNights(), ownsNights else { return }
        if placing != nil { placeAgain = true; return }
        placing = Task { [weak self] in
            repeat {
                guard let self else { return }
                self.placeAgain = false
                await self.placeNights(self.lists, self.knownLists())
            } while self?.placeAgain == true
            self?.placing = nil
        }
    }

    /// Waits for the calendar pass under way (tests).
    func settleNights() async { await placing?.value }

    /// Asks the plugin (1.51) to be the device that keeps the calendar, which also tells it the agent
    /// should leave the calendar to Redde: every 12 hours while on, as the plugin keeps it for the
    /// one that asks again within three days, then gives it to whichever asks next. Switched off on
    /// the device that keeps it, it lets it go. A plugin before 1.51 doesn't say whose it is: then no
    /// device keeps it, so none doubles another's, and each look asks again.
    func tellNights(now: Date = .now) async {
        let on = addsNights && canPlaceNights()
        let claim = claims[server()]
        if on, let at = claim?["at"], now.timeIntervalSince1970 - at < 12 * 3600 { return }
        if !on {
            guard let claim else { return }
            if claim["mine"] == 1 {
                guard await reachable(), (try? await plugin("lists nights off " + nightsDevice)) != nil else { return }
            }
            claims[server()] = nil
            return
        }
        guard await reachable(), let output = try? await plugin("lists nights on " + nightsDevice) else { return }
        // A plugin before 1.51 says nothing of whose it is: asked again at the next look, so the
        // plugin's update counts at once (2026-11-26: both devices waited 12 hours after it).
        guard let mine = PluginReply.json(output, "lists")?["mine"]?.bool else { claims[server()] = nil; return }
        let was = ownsNights
        claims[server()] = ["at": now.timeIntervalSince1970, "mine": mine ? 1 : 0]
        if mine, !was { placeFilmNights() }
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

    nonisolated private static var editNeedsUpdate: String {
        String(localized: "Your Hermes needs Redde's plugin 1.45 or later to edit an item. Update it in Settings › Redde Plugin.",
               comment: "A to-do list's sheet: editing an item's words on a server with an older plugin")
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

    /// New words for one item (asked 2026-11-24: "Allow to edit the todo items with a long press").
    /// A film's poster is looked for again under its new title. One brought from Reminders is
    /// still known by its new words, so a tick there still ticks it here.
    func edit(_ item: TodayList.Item, to text: String, in list: TodayList) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != item.text else { return }
        var listed = self.listed
        for (id, words) in listed where DeviceCalendar.folded(words) == DeviceCalendar.folded(item.text) { listed[id] = text }
        if listed != self.listed { self.listed = listed }
        apply(list.id, ["action": .string("edit"), "items": .array([.string(item.id)]), "title": .string(text)]) { kept in
            guard let i = kept.items.firstIndex(where: { $0.id == item.id }) else { return }
            kept.items[i].text = text
            if kept.kind == .watch { kept.items[i].poster = nil; kept.items[i].year = nil }
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
        let before = sending, action = change["action"]?.string
        let task = Task { [weak self] in
            await before?.value
            guard let self else { return }
            await self.send(encoded, action: action)
        }
        sending = task
        Task { [weak self] in
            await task.value
            if self?.sending == task { self?.sending = nil }
        }
    }

    private func send(_ encoded: String, action: String?) async {
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
                // (A plugin before 1.45 doesn't know `edit`, before 1.42 `unplan`, before 1.38 `plan`.)
                problem = !error.hasPrefix("Unknown action") ? error : action == "edit" ? Self.editNeedsUpdate : Self.datesNeedUpdate
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
    /// Made-up films with made-up posters, every fifth with a night set (`-echo.demoFilms`).
    static func demoFilms(_ count: Int) -> [TodayList.Item] {
        let words = ["Paper Moons", "Northbound", "The Lantern Keeper", "The Quiet Floor", "Snow on Maple Street", "Hollow Pines",
                     "Salt and Cedar", "Midnight Orchard", "Glass Harbor", "The Long Thaw", "Copper Sky", "Winter Station"]
        return (0 ..< count).map { n in
            let title = words[n % words.count] + (n < words.count ? "" : " \(n / words.count + 1)")
            return .init(id: "fx\(n)", text: title, done: n % 7 == 6,
                         poster: "https://demo.example/posters/\(title.lowercased().filter { $0.isLetter || $0 == " " }.replacingOccurrences(of: " ", with: "-")).jpg",
                         year: 1950 + (n * 7) % 74,
                         when: n % 5 == 2 ? Calendar.current.date(byAdding: .day, value: 2 + n % 20, to: Calendar.current.startOfDay(for: .now))?.addingTimeInterval(20 * 3600) : nil)
        }
    }

    static var demoDatedList: TodayList {
        let calendar = Calendar.current
        func day(_ offset: Int, _ hour: Int) -> Date? {
            calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: .now))
                .flatMap { calendar.date(bySettingHour: hour, minute: 0, second: 0, of: $0) }
        }
        return TodayList(id: "house", title: "House To-Dos", items: [
            .init(id: "h1", text: "Pay the water bill", done: false, when: day(-1, 10)),
            .init(id: "h2", text: "Call the dentist", done: false, when: day(0, 14), help: "Find their number and hours"),
            .init(id: "h3", text: "Renew the car registration", done: false, when: day(4, 9), help: "Look up what you need to renew"),
            .init(id: "h4", text: "Return the library books", done: false, when: day(5, 11), company: "Robin"),
            .init(id: "h5", text: "Book the holiday flights", done: false, when: day(14, 18)),
            .init(id: "h6", text: "Fix the bike's back brake", done: false),
            .init(id: "h7", text: "Order a new air filter", done: false, help: "Compare the right size and prices"),
            .init(id: "h8", text: "Clean the gutters", done: true),
            .init(id: "h9", text: "Send Ana the signed copy", done: true)], kind: .todo, emoji: "🏠", hue: .green)
    }
    #endif
}
