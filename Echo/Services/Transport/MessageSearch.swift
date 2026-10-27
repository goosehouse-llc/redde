import Foundation

/// Searching inside every message on the server: the Dashboard's full-text search
/// (`GET /api/sessions/search`, Hermes 0.21 onwards). The chat list's own filter only sees the
/// titles and previews it has loaded; this finds a word said anywhere in any conversation.
///
/// Hermes matches word beginnings ("nimb" finds "nimbus"), folds a conversation that auto-
/// compression split into new segments into one result, also matches a pasted session id and
/// manually set titles, and returns each conversation once, with the conversation's own row
/// (title, source, dates) and a snippet of the matching message, the matched words between
/// `>>>` and `<<<`. Only the Dashboard has this route; the Hermes API has none.
nonisolated struct MessageSearchHit: Decodable, Identifiable, Sendable, Equatable {
    /// The conversation, as the chat list knows conversations.
    var session: HermesSessionsAPI.SessionSummary
    /// The matching message, cut down by Hermes, matched words marked; or the conversation's
    /// preview when what matched was its title or id.
    var snippet: String
    /// Who said the matching message ("user", "assistant", "tool"); nil for a title or id match.
    var role: String?
    var archived: Bool

    var id: String { session.id }

    private enum CodingKeys: String, CodingKey { case snippet, role, archived }

    init(session: HermesSessionsAPI.SessionSummary, snippet: String, role: String? = nil, archived: Bool = false) {
        self.session = session
        self.snippet = snippet
        self.role = role
        self.archived = archived
    }

    init(from decoder: Decoder) throws {
        session = try HermesSessionsAPI.SessionSummary(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        snippet = (try? c.decodeIfPresent(String.self, forKey: .snippet)) ?? ""
        role = try? c.decodeIfPresent(String.self, forKey: .role)
        archived = (try? c.decodeIfPresent(Bool.self, forKey: .archived)) ?? false
    }

    /// One stretch of the snippet: matched by the search, or the text around it.
    struct Run: Equatable, Sendable {
        var text: String
        var matched: Bool
    }

    /// The snippet as runs, on one line: Hermes's markers taken out, line breaks and runs of
    /// spaces folded, so a match in the middle of a code block reads as one line in the list.
    var runs: [Run] {
        let flat = snippet.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
        var out: [Run] = []
        var rest = Substring(flat)
        while let open = rest.range(of: ">>>") {
            if open.lowerBound > rest.startIndex { out.append(Run(text: String(rest[..<open.lowerBound]), matched: false)) }
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "<<<") else {
                out.append(Run(text: String(after), matched: true))
                return out
            }
            out.append(Run(text: String(after[..<close.lowerBound]), matched: true))
            rest = after[close.upperBound...]
        }
        if !rest.isEmpty { out.append(Run(text: String(rest), matched: false)) }
        return out
    }

    /// What Find in the conversation should look for on the way in: the first word Hermes
    /// matched (a search for two words matches them anywhere in a message, not side by side),
    /// else what was typed.
    func findText(typed: String) -> String {
        runs.first(where: \.matched)?.text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "You" or "Hermes" before a matched message, so a hit says who said it.
    var speaker: String? {
        switch role {
        case "user": String(localized: "You", comment: "Who said a message found by search: the person")
        case "assistant": "Hermes"
        case "tool": String(localized: "Tool", comment: "Who said a message found by search: a tool the agent ran")
        default: nil
        }
    }
}

extension HermesServeClient {
    /// Conversations with a message (or a title, or an id) matching `query`, best first.
    /// Empty for an empty query; throws as any Dashboard call does (a Hermes without the route
    /// answers 404).
    func searchMessages(_ query: String, limit: Int = 30) async throws -> [MessageSearchHit] {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return [] }
        var comps = URLComponents()
        comps.path = "api/sessions/search"
        comps.queryItems = [.init(name: "q", value: wanted), .init(name: "limit", value: String(limit))]
        let answer = try await restJSON("GET", comps.string ?? "api/sessions/search")
        let data = try JSONEncoder().encode(answer["results"] ?? .array([]))
        // One odd row must not lose the rest.
        return ((try? JSONDecoder().decode([Lenient].self, from: data)) ?? []).compactMap(\.hit)
    }

    private struct Lenient: Decodable {
        var hit: MessageSearchHit?
        init(from decoder: Decoder) throws { hit = try? MessageSearchHit(from: decoder) }
    }
}
