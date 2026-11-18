// The last failed requests, for a bug report (Diagnostics.swift). Also in the watch app, which
// has the Hermes API client.
import Foundation

/// The last requests that failed, kept so a report can say what went wrong where: which
/// connection, which route or call, the status and the error's first words. Never a message's
/// text, a key, a password or an address: a route is its path without the query, and nothing
/// leaves the device unless the person copies the report.
nonisolated final class FailureLog: @unchecked Sendable {   // Sendable by hand: every field under `lock`.
    static let shared = FailureLog()

    struct Entry: Codable, Equatable, Sendable {
        var at: Date
        /// The connection: "dashboard", "dashboard rest", "api", "agent".
        var via: String
        /// The call or route: `session.create`, `api/sessions/{id}/messages`.
        var what: String
        var status: Int?
        var error: String
        /// How many times in a row it failed so (`at` is the latest); one line, not a page of them.
        var times: Int? = nil

        func isSame(as other: Entry) -> Bool {
            via == other.via && what == other.what && status == other.status && error == other.error
        }
    }

    static let kept = 25
    private static let key = "diagnostics.failures"
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var entries: [Entry]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    var recent: [Entry] { lock.withLock { entries } }

    func clear() {
        lock.withLock { entries = [] }
        defaults.removeObject(forKey: Self.key)
    }

    /// One failure, unless it's nothing to report (a call cancelled because the person moved on).
    func record(via: String, what: String, error: any Error, at: Date = .now) {
        guard !Self.isCancellation(error) else { return }
        let status: Int? = if case .http(let code, _)? = error as? TransportError { code } else { nil }
        let entry = Entry(at: at, via: via, what: Self.route(what), status: status, error: Self.words(error))
        let kept: [Entry] = lock.withLock {
            if let last = entries.last, last.isSame(as: entry) {
                entries[entries.count - 1].times = (last.times ?? 1) + 1
                entries[entries.count - 1].at = entry.at
                return entries
            }
            entries.append(entry)
            if entries.count > Self.kept { entries.removeFirst(entries.count - Self.kept) }
            return entries
        }
        if let data = try? JSONEncoder().encode(kept) { defaults.set(data, forKey: Self.key) }
    }

    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return false
    }

    /// A route as the report shows it: no query (it can carry a search or a file name), no
    /// scheme or host, and long ids cut down so the path stays readable.
    static func route(_ text: String) -> String {
        var path = text
        if let url = URL(string: text), url.scheme != nil { path = url.path() }
        path = String(path.split(separator: "?", maxSplits: 1).first ?? "")
        path = path.split(separator: "/", omittingEmptySubsequences: false).map { part in
            part.count > 24 ? part.prefix(8) + "…" : part
        }.joined(separator: "/")
        return String(path.prefix(80))
    }

    /// The error's first words, on one line.
    static func words(_ error: any Error) -> String {
        let text: String = if case .http(let code, let body)? = error as? TransportError {
            "HTTP \(code) \(body)"
        } else if let error = error as? LocalizedError {
            error.errorDescription ?? String(describing: error)
        } else {
            (error as NSError).localizedDescription
        }
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }
}
