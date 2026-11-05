import Foundation

/// What the agent remembers ("memory you can see", 2.4): Hermes's built-in memory, two files in
/// the profile's home, `memories/USER.md` (who the person is) and `memories/MEMORY.md` (the agent's
/// own notes). Entries are separated by a line holding only "§" (Hermes's `ENTRY_DELIMITER`,
/// "\n§\n"), and each file is capped by characters, counted as the entries joined by that
/// delimiter (`memory.user_char_limit` 1,375 and `memory.memory_char_limit` 2,200 by default,
/// Hermes 0.21–0.22). The agent reads them at the start of a conversation.
///
/// Read and written through the Dashboard's file routes, as Settings' file editors are; those
/// leave stale-write detection to the client (`fs_write_text`), so a save reads the file again
/// and applies only what was changed here (`apply`), refusing when the agent changed the same
/// entry meanwhile. The Hermes API has no route to these files.
nonisolated enum AgentMemory {
    enum Target: String, CaseIterable, Identifiable, Sendable {
        case user, memory
        var id: String { rawValue }
        /// Where it is in the profile's home.
        var file: String { self == .user ? "memories/USER.md" : "memories/MEMORY.md" }
        var defaultLimit: Int { self == .user ? 1375 : 2200 }
        /// Its limit's name in the `memory` section of config.yaml.
        var limitKey: String { self == .user ? "user_char_limit" : "memory_char_limit" }
    }

    static let delimiter = "\n§\n"

    /// A file's entries as Hermes reads them: split on the whole delimiter (a "§" inside an entry
    /// stays), trimmed, empty ones dropped, repeats dropped (the first kept).
    static func entries(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.components(separatedBy: delimiter)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func joined(_ entries: [String]) -> String { entries.joined(separator: delimiter) }

    /// Characters as Hermes counts them (Python's `len`: Unicode code points).
    static func size(_ entries: [String]) -> Int { joined(entries).unicodeScalars.count }

    // MARK: Changes

    /// One change made on the Memory page, applied to the file as it is when saving.
    enum Change: Equatable, Sendable {
        case add(String)
        case remove(String)
        case replace(String, with: String)
    }

    /// `changes` applied to `current`, the file read again just now. An entry removed here and
    /// already gone there is fine; one edited here that the agent changed or removed there is a
    /// conflict (returned, and left as the agent has it). New entries go at the end, once.
    static func apply(_ changes: [Change], to current: [String]) -> (entries: [String], conflicts: [String]) {
        var entries = current
        var conflicts: [String] = []
        for change in changes {
            switch change {
            case let .add(text):
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, !entries.contains(text) { entries.append(text) }
            case let .remove(text):
                entries.removeAll { $0 == text }
            case let .replace(old, new):
                let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
                if let index = entries.firstIndex(of: old) {
                    if new.isEmpty || entries.contains(new) { entries.remove(at: index) } else { entries[index] = new }
                } else if !entries.contains(new) {
                    conflicts.append(old)
                }
            }
        }
        return (entries, conflicts)
    }

    /// Whether a save may write `entries`: under the limit, or at least no further over it than
    /// the file already is (Hermes keeps an oversized file but refuses the agent's additions).
    static func fits(_ entries: [String], limit: Int, before: [String]) -> Bool {
        let after = Self.size(entries)
        return after <= limit || after <= Self.size(before)
    }

    // MARK: What a reply did to it

    /// What a reply's call of the memory tool did, for the chip under it: kept something, forgot
    /// something, or changed it some other way. Nil when it didn't call the tool, or the call failed.
    struct ReplyChange: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case remembered, forgot, changed }
        var kind: Kind
        var target: Target?
        /// The entry's words, to find it on the Memory page.
        var text: String?
    }

    static let toolName = "memory"

    /// The last successful memory call among a reply's steps. Its arguments are kept as a line
    /// per field (`ToolActivity.detail`): "action: add", "content: …", "old_text: …", "target: user".
    static func change(in tools: [ToolActivity]) -> ReplyChange? {
        guard let tool = tools.last(where: { $0.name == toolName && $0.status == .completed }) else { return nil }
        let fields = fields(tool.args ?? tool.preview ?? "")
        let target = fields["target"].flatMap(Target.init(rawValue:))
        switch fields["action"] {
        case "add": return ReplyChange(kind: .remembered, target: target, text: fields["content"])
        case "replace", "patch": return ReplyChange(kind: .remembered, target: target, text: fields["content"] ?? fields["new_text"])
        case "remove": return ReplyChange(kind: .forgot, target: target, text: fields["old_text"])
        default: return ReplyChange(kind: .changed, target: target, text: nil)
        }
    }

    /// "key: value" lines, and "key:" followed by lines of its own for a value with line breaks.
    static func fields(_ text: String) -> [String: String] {
        let keys = ["action", "target", "content", "old_text", "new_text"]
        var out: [String: String] = [:]
        var current: String?
        var collected: [String] = []
        func close() {
            if let current { out[current] = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            current = nil
            collected = []
        }
        for line in text.components(separatedBy: "\n") {
            if let colon = line.firstIndex(of: ":"), keys.contains(String(line[..<colon])) {
                close()
                current = String(line[..<colon])
                let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { collected.append(rest) }
            } else if let colon = line.firstIndex(of: ":"), !line[..<colon].contains(" "), line[..<colon].count < 20 {
                close()   // a field this doesn't read
            } else if current != nil {
                collected.append(line)
            }
        }
        close()
        return out
    }

    /// The message a long press sends ("Remember This"): the plugin's note turns it into one entry.
    static func rememberMessage(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = text.count > 600 ? String(text.prefix(600)) + "…" : text
        return "Remember that: " + cut
    }
}

/// The Memory page's working copy of one profile's memory, read and saved through the Dashboard.
@MainActor @Observable
final class AgentMemoryModel {
    /// One entry on the page: as it was read (nil for one added here) and as it is now.
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var original: String?
        var text: String
        var deleted = false
        var isNew: Bool { original == nil }
        var changed: Bool { deleted ? original != nil : text.trimmingCharacters(in: .whitespacesAndNewlines) != (original ?? "") }
    }

    struct File: Equatable {
        var path: String
        var base: [String] = []
        var rows: [Row] = []
        var limit: Int
        var exists = true
    }

    /// A bot's profile; nil for the one Redde is using.
    let profile: String?
    var files: [AgentMemory.Target: File] = [:]
    var loading = false
    var saving = false
    var problem: String?
    /// Hermes's external memory provider, when one is on (`memory.provider`): what it keeps isn't
    /// in these files.
    var provider: String?
    /// The Dashboard login isn't there: nothing to read.
    var needsLogin = false
    let demo: Bool

    init(profile: String? = nil, demo: Bool = false) {
        self.profile = profile
        #if DEBUG
        self.demo = demo || DevHooks.has("-echo.demoMemory")
        #else
        self.demo = demo
        #endif
    }

    var dirty: Bool { files.values.contains { $0.rows.contains(where: \.changed) } }

    /// Its size now, as the page has it, for the footer.
    func size(_ target: AgentMemory.Target) -> Int {
        AgentMemory.size(rows(target).filter { !$0.deleted }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    func rows(_ target: AgentMemory.Target) -> [Row] { files[target]?.rows ?? [] }

    func binding(_ target: AgentMemory.Target, _ id: Row.ID) -> Row? { files[target]?.rows.first { $0.id == id } }

    func update(_ target: AgentMemory.Target, _ id: Row.ID, text: String) {
        guard let i = files[target]?.rows.firstIndex(where: { $0.id == id }) else { return }
        files[target]?.rows[i].text = text
    }

    func delete(_ target: AgentMemory.Target, _ id: Row.ID, _ deleted: Bool = true) {
        guard let i = files[target]?.rows.firstIndex(where: { $0.id == id }) else { return }
        if files[target]?.rows[i].isNew == true, deleted { files[target]?.rows.remove(at: i); return }
        files[target]?.rows[i].deleted = deleted
    }

    @discardableResult
    func add(_ target: AgentMemory.Target, _ text: String = "") -> Row.ID? {
        guard files[target] != nil else { return nil }
        let row = Row(original: nil, text: text)
        files[target]?.rows.append(row)
        return row.id
    }

    func discard() {
        for target in AgentMemory.Target.allCases { if let base = files[target]?.base { files[target]?.rows = base.map { Row(original: $0, text: $0) } } }
    }

    // MARK: Reading and saving

    func load() async {
        loading = true
        problem = nil
        defer { loading = false }
        if demo {
            for target in AgentMemory.Target.allCases where files[target] == nil {
                let base = target == .user ? MemoryDemo.user : MemoryDemo.notes
                files[target] = File(path: "~/.hermes/" + target.file, base: base, rows: base.map { Row(original: $0, text: $0) }, limit: target.defaultLimit)
            }
            provider = nil
            return
        }
        guard await Self.canUseDashboard() else { needsLogin = true; return }
        needsLogin = false
        let client = HermesServeClient.shared
        let home = await Self.home(of: profile)
        let named = profile == nil || profile == ProfileCatalog.defaultID ? nil : profile
        var limits: [AgentMemory.Target: Int] = [:]
        if let config = try? await client.restJSON("GET", HermesServeClient.naming("api/config?include_defaults=false", profile: named)) {
            for target in AgentMemory.Target.allCases { limits[target] = config["memory"]?[target.limitKey]?.int }
        }
        if let status = try? await client.restJSON("GET", HermesServeClient.naming("api/memory", profile: named)) {
            provider = status["active"]?.string?.nilIfEmpty
        }
        do {
            for target in AgentMemory.Target.allCases {
                let path = home + "/" + target.file
                let raw = try await client.readText(path: path)
                let base = AgentMemory.entries(raw ?? "")
                files[target] = File(path: path, base: base, rows: base.map { Row(original: $0, text: $0) },
                                     limit: limits[target] ?? target.defaultLimit, exists: raw != nil)
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Writes what changed, file by file: each read again first, the changes applied to it, so an
    /// entry the agent added meanwhile stays. True when everything was written.
    @discardableResult
    func save() async -> Bool {
        saving = true
        problem = nil
        defer { saving = false }
        var refused: [String] = []
        for target in AgentMemory.Target.allCases {
            guard let file = files[target] else { continue }
            let changes = Self.changes(file.rows)
            guard !changes.isEmpty else { continue }
            do {
                let current = demo ? file.base : AgentMemory.entries(try await HermesServeClient.shared.readText(path: file.path) ?? "")
                let (entries, conflicts) = AgentMemory.apply(changes, to: current)
                if !conflicts.isEmpty {
                    refused.append(String(localized: "Your agent changed this while you were editing, so your edit wasn't saved: “\(conflicts[0])”"))
                }
                guard AgentMemory.fits(entries, limit: file.limit, before: current) else {
                    let over = AgentMemory.size(entries) - file.limit
                    refused.append(target == .user
                        ? String(localized: "About You would be \(over) characters over Hermes's limit. Shorten or remove something first.")
                        : String(localized: "Notes would be \(over) characters over Hermes's limit. Shorten or remove something first."))
                    continue
                }
                if !demo { try await HermesServeClient.shared.writeText(path: file.path, content: AgentMemory.joined(entries)) }
                files[target]?.base = entries
                files[target]?.rows = entries.map { Row(original: $0, text: $0) }
                files[target]?.exists = true
            } catch {
                refused.append(error.localizedDescription)
            }
        }
        problem = refused.isEmpty ? nil : refused.joined(separator: "\n")
        return refused.isEmpty
    }

    /// Facts from an import (`MemoryImport`), added to About You and saved.
    func addAndSave(_ facts: [String]) async -> Bool {
        if files[.user] == nil { await load() }
        guard files[.user] != nil else { return false }
        for fact in facts { add(.user, fact) }
        return await save()
    }

    nonisolated static func changes(_ rows: [Row]) -> [AgentMemory.Change] {
        rows.compactMap { row in
            let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch (row.original, row.deleted) {
            case (nil, false): return text.isEmpty ? nil : .add(text)
            case (nil, true): return nil
            case let (original?, true): return .remove(original)
            case let (original?, false): return text == original ? nil : (text.isEmpty ? .remove(original) : .replace(original, with: text))
            }
        }
    }

    /// The profile's home, as the Dashboard's profile list says; Hermes's usual layout otherwise.
    static func home(of profile: String?) async -> String {
        let client = HermesServeClient.shared
        if let profile, let listed = try? await client.profiles(),
           let found = listed.first(where: { $0.name.caseInsensitiveCompare(profile) == .orderedSame || ($0.isDefault && profile == ProfileCatalog.defaultID) }),
           !found.path.isEmpty {
            return found.path.hasSuffix("/") ? String(found.path.dropLast()) : found.path
        }
        if profile == nil, let home = await client.profileHome() { return home.hasSuffix("/") ? String(home.dropLast()) : home }
        if let profile, profile != ProfileCatalog.defaultID { return "~/.hermes/profiles/\(profile)" }
        return String(Settings.shared.profileFilePath("x").dropLast(2))
    }

    static func canUseDashboard() async -> Bool {
        if Keychain.read(.serveDashboardPassword) != nil || HermesServeClient.shared.isSignedIn { return true }
        return await HermesServeClient.shared.canUse()
    }
}

/// Made-up memory for screenshots and the simulator (`-echo.demoMemory`).
nonisolated enum MemoryDemo {
    static let user = [
        "Goes by Alex. Lives in Lisbon, works from home on Fridays.",
        "Vegetarian; allergic to cats.",
        "Prefers short answers, metric units and 24-hour times.",
        "Partner: Jo. Daughter: Mia, 7, starts school at 8:30.",
        "Runs Hermes on a small Linux box; models on a Mac.",
    ]
    static let notes = [
        "The porch light is light.porch in Home Assistant; the garage door is cover.garage.",
        "Weekly review happens Sundays at 6 pm; send the agenda by 5.",
        "Alex's dentist is Dr. Ramos, Rua Augusta 12; usually books 9 am slots.",
    ]
}
