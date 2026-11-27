import Foundation
import Observation

/// Side chats (asked 2026-11-27, "now build the muse gaps", after Meta's Muse's side chats): a new
/// chat started from one message of another, about it, so the first keeps its thread. It goes by
/// the same connection and agent; its first message quotes the message it's about. Kept apart from
/// the chat list, it's reached from the chat it came from, and has a way back to it.
///
/// Not a fork of the server's session: the Hermes API's fork ends the chat it copies
/// (`POST /api/sessions/{id}/fork`, end_reason "branched", Hermes 0.23), and a whole transcript copied
/// is more than a question about one message needs. Which chat is whose side chat is kept on this
/// device, by connection and session.
@MainActor @Observable
final class SideChats {
    static let shared = SideChats()

    struct Link: Codable, Equatable, Sendable {
        /// The chat it came from: its session, and its title then.
        var parent: String
        var title: String
        /// What it's about: the start of the message it quotes.
        var about: String
        var at: Date
    }

    static let key = "sideChats"
    static let most = 200
    static let longestQuote = 1_200

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var links: [String: Link]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        links = (defaults.data(forKey: Self.key)).flatMap { try? JSONDecoder().decode([String: Link].self, from: $0) } ?? [:]
    }

    private static func key(_ session: String, _ connection: String) -> String { "\(connection)|\(session)" }

    func link(of session: String?, connection: String) -> Link? {
        session.flatMap { links[Self.key($0, connection)] }
    }

    func isSide(_ session: String, connection: String) -> Bool { links[Self.key(session, connection)] != nil }

    /// This chat's side chats, newest first: (session, link).
    func sides(of parent: String?, connection: String) -> [(session: String, link: Link)] {
        guard let parent else { return [] }
        let prefix = connection + "|"
        return links.compactMap { key, link in
            key.hasPrefix(prefix) && link.parent == parent ? (String(key.dropFirst(prefix.count)), link) : nil
        }
        .sorted { $0.link.at > $1.link.at }
    }

    func add(_ session: String, connection: String, link: Link) {
        links[Self.key(session, connection)] = link
        if links.count > Self.most {
            for (key, _) in links.sorted(by: { $0.value.at < $1.value.at }).prefix(links.count - Self.most) { links[key] = nil }
        }
        save()
    }

    func remove(_ session: String, connection: String) {
        guard links.removeValue(forKey: Self.key(session, connection)) != nil else { return }
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(links), forKey: Self.key)
    }

    /// A message's words as the side chat quotes them: plain, clipped.
    static func quote(_ text: String) -> String {
        let plain = PlainText.display(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.count > longestQuote ? String(plain.prefix(longestQuote)) + "…" : plain
    }

    static func about(_ text: String) -> String {
        let line = quote(text).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }
}
