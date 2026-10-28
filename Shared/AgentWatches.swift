import Foundation

/// What each watch last said had changed (Redde's plugin 1.9, `watches.py`; asked 2026-10-28):
/// kept in the app group as notes arrive, the notification extension's too, so Redde's Watches
/// list can show it beside the watch, with Redde closed between.
nonisolated struct WatchReport: Codable, Equatable, Sendable {
    /// The watch's id (its job's `[redde-watch:<id>]` tag).
    var id: String
    var title: String
    var agent: String
    var text: String
    var at: Date
    /// It couldn't look, and `text` says why.
    var failed: Bool

    private static let key = "watchReports"
    static let most = 100

    static func all(in defaults: UserDefaults? = NeedsYou.shared) -> [String: WatchReport] {
        guard let data = defaults?.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: WatchReport].self, from: data)) ?? [:]
    }

    /// A watch's note: kept as its latest. False for any other note.
    @discardableResult
    static func take(_ note: PushNote, now: Date = .now, in defaults: UserDefaults? = NeedsYou.shared) -> Bool {
        guard note.kind == .watch, let id = note.i, !id.isEmpty else { return false }
        var kept = all(in: defaults)
        kept[id] = WatchReport(id: id, title: note.t ?? "", agent: note.d ?? "", text: note.b ?? "",
                               at: note.at.map { Date(timeIntervalSince1970: $0) } ?? now, failed: note.w == "failed")
        if kept.count > most {
            for old in kept.values.sorted(by: { $0.at < $1.at }).prefix(kept.count - most) { kept[old.id] = nil }
        }
        defaults?.set(try? JSONEncoder().encode(kept), forKey: key)
        return true
    }

    static func forget(_ id: String, in defaults: UserDefaults? = NeedsYou.shared) {
        var kept = all(in: defaults)
        guard kept.removeValue(forKey: id) != nil else { return }
        defaults?.set(try? JSONEncoder().encode(kept), forKey: key)
    }
}
