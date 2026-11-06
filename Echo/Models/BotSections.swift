import Foundation

/// Sections of the chat list's Bots, as Hermes Desktop has them (its hermes-bots plugin's "user
/// sections", 0.21.3+; asked on Reddit by someone with dozens of bots, built 2026-11-05): folders
/// the person makes, "Clients", "Home". Membership lives on the bot, not on the section: a bot's
/// profile.yaml carries `ui_meta['hermes-bots'].sectionId` and `.sectionName`, so a bot is in one
/// place at most, and deleting a section loses nobody. The section list itself (its order, the
/// empty ones) is each app's own: Desktop keeps it in its plugin storage, Redde in Settings,
/// synced. A section met on a bot that Redde never made is taken in by the name the bot carries
/// (`adopted`), as Desktop does, so sections made on the desktop show on the phone.
///
/// Where a bot can't carry it (added for the Hermes API alone, or a server where no bot is set up
/// yet, which a write would set up), and for group chats (Desktop keeps theirs on its own side
/// too), the membership is kept on the phone (`BotSectionsHere.kept`).
nonisolated struct BotSection: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String

    /// "sec-<time>-<random>", as Desktop makes them.
    static func newID(now: Date = .now) -> String {
        let time = String(Int(now.timeIntervalSince1970 * 1000), radix: 36)
        let letters = "abcdefghijklmnopqrstuvwxyz0123456789"
        return "sec-\(time)-" + String((0 ..< 5).map { _ in letters.randomElement()! })
    }
}

/// A server's sections, in order, and the memberships kept on the phone, by `BotListItem` id.
nonisolated struct BotSectionsHere: Codable, Equatable, Sendable {
    var sections: [BotSection] = []
    var kept: [String: String] = [:]

    var isEmpty: Bool { sections.isEmpty && kept.isEmpty }
}

/// A run of the Bots section: a section's bots and group chats, or (`section` nil) those in none.
nonisolated struct BotSectionBlock: Equatable, Sendable {
    var section: BotSection?
    var items: [BotListItem]

    var key: String { section?.id ?? "loose" }
    var bots: [HermesBot] { items.compactMap { if case .bot(let bot) = $0 { bot } else { nil } } }
    var rooms: [GroupRoom] { items.compactMap { if case .room(let room) = $0 { room } else { nil } } }
}

nonisolated enum BotSectioning {
    /// The section an item is in: a bot's own (on the server), else the one kept for it here; one
    /// the list doesn't have (deleted elsewhere) is none.
    static func section(of item: BotListItem, in here: BotSectionsHere) -> String? {
        let known = Set(here.sections.map(\.id))
        var id: String?
        if case .bot(let bot) = item, let own = bot.sectionID { id = own }
        id = id ?? here.kept[item.id]
        return id.flatMap { known.contains($0) ? $0 : nil }
    }

    /// The items in runs: each section in order (an empty one too, so a new one shows), then those
    /// in none. Every item once, in the order given.
    static func blocks(_ items: [BotListItem], in here: BotSectionsHere) -> [BotSectionBlock] {
        var bySection: [String: [BotListItem]] = [:]
        var loose: [BotListItem] = []
        for item in items {
            if let id = section(of: item, in: here) { bySection[id, default: []].append(item) } else { loose.append(item) }
        }
        return here.sections.map { BotSectionBlock(section: $0, items: bySection[$0.id] ?? []) } + [BotSectionBlock(section: nil, items: loose)]
    }

    /// The list with the sections the bots carry that it doesn't have (made in Hermes Desktop, or
    /// on another phone without iCloud), by the name they carry; and a known one renamed when every
    /// bot in it carries the same other name (renamed elsewhere). `deleting`: ones being emptied
    /// now, whose bots still carry them for a moment.
    static func adopted(_ here: BotSectionsHere, bots: [HermesBot], deleting: Set<String> = []) -> BotSectionsHere {
        var names: [String: Set<String>] = [:]
        var order: [String] = []
        for bot in bots {
            guard let id = bot.sectionID, let name = bot.sectionName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { continue }
            if names[id] == nil { order.append(id) }
            names[id, default: []].insert(name)
        }
        var next = here
        next.sections = here.sections.map { section in
            guard let carried = names[section.id], carried.count == 1, let name = carried.first else { return section }
            return BotSection(id: section.id, name: name)
        }
        let known = Set(here.sections.map(\.id))
        for id in order where !known.contains(id) && !deleting.contains(id) {
            if let name = names[id]?.sorted().first { next.sections.append(BotSection(id: id, name: name)) }
        }
        return next
    }

    /// The membership goes on the bot itself, on the server: a Dashboard bot, where bots are set up
    /// already (writing Desktop's settings to a server with none would set the first one up and
    /// let them message each other, a choice of its own: `letBotsMessageEachOther`).
    static func onServer(_ bot: HermesBot, roster: BotRoster?) -> Bool {
        !bot.viaAPI && (bot.isSetUp || roster?.messagingIsOn == true)
    }
}

/// Making, naming and filing into sections: the bots' own memberships written to the server one at
/// a time (each is its own profile's write), the rest kept here. Whoever calls reads the roster
/// again after.
enum BotSectionActions {
    /// Sections being emptied: their bots still carry them until each write lands, and the roster
    /// read meanwhile would bring them back (`BotSectioning.adopted`).
    private(set) static var deleting: Set<String> = []

    /// A new section, with `items` filed in it. Nil for a blank name.
    @discardableResult
    static func make(_ name: String, filing items: [BotListItem] = [], roster: BotRoster?,
                     settings: Settings = .shared, client: HermesServeClient = .shared) async throws -> BotSection? {
        guard let name = name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        let section = BotSection(id: BotSection.newID(), name: String(name.prefix(60)))
        settings.botSectionsHere.sections.append(section)
        try await file(items, in: section, roster: roster, settings: settings, client: client)
        return section
    }

    /// `items` into `section` (nil: out of any).
    static func file(_ items: [BotListItem], in section: BotSection?, roster: BotRoster?,
                     settings: Settings = .shared, client: HermesServeClient = .shared) async throws {
        for item in items {
            if case .bot(let bot) = item, BotSectioning.onServer(bot, roster: roster) {
                settings.botSectionsHere.kept[item.id] = nil
                guard bot.sectionID != section?.id || bot.sectionName != section?.name else { continue }
                try await client.setBotSection(bot, section)
            } else {
                settings.botSectionsHere.kept[item.id] = section?.id
            }
        }
    }

    /// The section's new name, given again to the bots in it, which is how it reaches Desktop.
    static func rename(_ section: BotSection, to name: String, items: [BotListItem], roster: BotRoster?,
                       settings: Settings = .shared, client: HermesServeClient = .shared) async throws {
        guard let name = name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return }
        let renamed = BotSection(id: section.id, name: String(name.prefix(60)))
        settings.botSectionsHere.sections = settings.botSectionsHere.sections.map { $0.id == section.id ? renamed : $0 }
        let members = items.filter { BotSectioning.section(of: $0, in: settings.botSectionsHere) == section.id }
        try await file(members, in: renamed, roster: roster, settings: settings, client: client)
    }

    /// The section only: its bots and group chats go back to none.
    static func delete(_ section: BotSection, items: [BotListItem], roster: BotRoster?,
                       settings: Settings = .shared, client: HermesServeClient = .shared) async throws {
        let members = items.filter { BotSectioning.section(of: $0, in: settings.botSectionsHere) == section.id }
        deleting.insert(section.id)
        defer { deleting.remove(section.id) }
        settings.botSectionsHere.sections.removeAll { $0.id == section.id }
        settings.botSectionsHere.kept = settings.botSectionsHere.kept.filter { $0.value != section.id }
        // Bots whose sectionId names it (now unknown, so `section(of:)` no longer sees them).
        let carrying = items.filter { if case .bot(let bot) = $0 { bot.sectionID == section.id } else { false } }
        try await file(Array(Set(members.map(\.id)).union(carrying.map(\.id))).compactMap { id in items.first { $0.id == id } },
                       in: nil, roster: roster, settings: settings, client: client)
    }

    /// One place up (-1) or down (1).
    static func move(_ section: BotSection, by step: Int, settings: Settings = .shared) {
        var list = settings.botSectionsHere.sections
        guard let from = list.firstIndex(of: section), list.indices.contains(from + step) else { return }
        list.swapAt(from, from + step)
        settings.botSectionsHere.sections = list
    }

    /// The roster just read: sections its bots carry that this list doesn't have, taken in.
    static func adopt(_ roster: BotRoster?, settings: Settings = .shared) {
        guard let roster else { return }
        let here = settings.botSectionsHere
        let next = BotSectioning.adopted(here, bots: roster.bots, deleting: deleting)
        if next != here { settings.botSectionsHere = next }
    }
}
