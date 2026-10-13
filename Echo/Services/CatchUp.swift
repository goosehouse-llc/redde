import Foundation

/// The car's "Catch me up": which chats have something new since you last saw them, and what
/// Redde says about each, a line or two of its latest reply. Nothing is asked of a model; it is
/// read off the chat list and the chats themselves, so it costs a second and says only what a
/// reply said.
///
/// "Since you last saw them" is kept as marks (`Marks`, in `Settings.catchUp`): when a catch-up
/// was last heard to its end, and for each chat when it was last on the phone's screen or its
/// reply was last heard by voice. A chat has news when it has moved since the later of the two.
nonisolated enum CatchUp {
    struct Marks: Codable, Equatable, Sendable {
        /// When a catch-up was last heard to its end: everything before that has been told.
        var told: Date?
        /// When each chat was last on the phone's screen, or its reply last heard, by `CarPlayChat.key`.
        var seen: [String: Date] = [:]

        /// The moment after which movement in a chat is news. Before any catch-up, a day back.
        func mark(for key: String, now: Date = .now) -> Date {
            max(told ?? now.addingTimeInterval(-CatchUp.firstLook), seen[key] ?? .distantPast)
        }

        mutating func saw(_ key: String, at date: Date = .now) {
            seen[key] = date
            // A mark older than the last catch-up says nothing that one doesn't.
            if let told { seen = seen.filter { $0.value > told } }
            if seen.count > 200 { seen = Dictionary(uniqueKeysWithValues: seen.sorted { $0.value > $1.value }.prefix(200).map { ($0.key, $0.value) }) }
        }
    }

    /// How far back the first catch-up looks, in seconds.
    static let firstLook: TimeInterval = 24 * 3600
    /// How many chats are read out; the rest are counted.
    static let most = 5

    /// The chats that have moved since they were last seen, newest first.
    static func moved(_ chats: [CarPlayChat], marks: Marks, now: Date = .now) -> [CarPlayChat] {
        chats.filter { chat in chat.lastActive.map { $0 > marks.mark(for: chat.key, now: now) } ?? false }
            .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }

    /// One chat's news.
    struct Item: Equatable, Sendable {
        enum Said: Equatable, Sendable {
            /// The start of the latest reply.
            case reply(String)
            /// The last word is yours: the agent hasn't answered yet.
            case working
            /// It moved, and there are no words to read: only tools ran, or it couldn't be read.
            case nothing
        }

        var title: String
        var when: Date
        var said: Said
    }

    /// What there is to say about a chat the list says has moved, from its messages. Nil when
    /// none of them is newer than the mark: the list counted something that isn't a message.
    static func item(for chat: CarPlayChat, messages: [Message], working: Bool = false, marks: Marks, now: Date = .now) -> Item? {
        let mark = marks.mark(for: chat.key, now: now)
        guard let last = messages.last, last.createdAt > mark else { return nil }
        let when = chat.lastActive ?? last.createdAt
        if working || last.role == .user { return Item(title: chat.title, when: when, said: .working) }
        // The latest reply with words in it: one that only ran tools has nothing to read.
        let reply = messages.reversed().lazy.filter { $0.role == .assistant && $0.createdAt > mark }.map { gist($0.text) }.first { !$0.isEmpty }
        return Item(title: chat.title, when: when, said: reply.map(Item.Said.reply) ?? .nothing)
    }

    /// The start of a reply, fit to be said: its first sentences, up to `limit` characters,
    /// without what can't be read aloud.
    static func gist(_ reply: String, limit: Int = 220) -> String {
        let plain = PlainText.spoken(reply).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard plain.count > limit else { return plain }
        var taken = ""
        plain.enumerateSubstrings(in: plain.startIndex..., options: .bySentences) { sentence, _, _, stop in
            guard let sentence, taken.count + sentence.count <= limit else { stop = true; return }
            taken += sentence
        }
        taken = taken.trimmingCharacters(in: .whitespaces)
        if !taken.isEmpty { return taken }
        // One long sentence: as much of it as fits, cut between words.
        let cut = plain.prefix(limit)
        return String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]) + ", and more."
    }

    /// What is said. `more`: chats with news beyond the ones in `items`. `waiting`: the open
    /// chat, if it stands still on a request that has to be answered on the phone.
    static func script(_ items: [Item], more: Int = 0, told: Date?, waiting: String? = nil, now: Date = .now) -> String {
        var lines: [String] = []
        if let waiting { lines.append("\(spoken(waiting)) is waiting for your answer on your iPhone.") }
        guard !items.isEmpty else {
            let since = told.map { "since \(time($0, now: now))" } ?? "in the last day"
            lines.append((waiting == nil ? "You're all caught up. Nothing" : "Otherwise nothing") + " new \(since).")
            return lines.joined(separator: "\n\n")
        }
        let total = items.count + more
        lines.append((total == 1 ? "One chat has" : "\(total) chats have") + " something new."
            + (more > 0 ? " Here are the latest \(items.count)." : ""))
        for item in items {
            let what = switch item.said {
            case let .reply(text): " " + text
            case .working: " No reply yet."
            case .nothing: ""
            }
            lines.append("\(spoken(item.title)), \(ago(item.when, now: now)).\(what)")
        }
        return lines.joined(separator: "\n\n")
    }

    /// A chat's name as it is said: a chat nobody named is "an untitled chat", not a title.
    private static func spoken(_ title: String) -> String {
        title == CarPlayChats.untitled ? "An untitled chat" : title.trimmingCharacters(in: CharacterSet(charactersIn: " .:;,"))
    }

    /// "20 minutes ago", "yesterday". In English, like the sentences around it.
    private static func ago(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "2:10 PM", "yesterday at 2:10 PM", "Monday".
    private static func time(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        // (The system puts a narrow no-break space before "PM"; a plain one reads the same.)
        let clock = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "en_US")))
            .replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(clock)"
        }
        return date.formatted(Date.FormatStyle(locale: Locale(identifier: "en_US")).weekday(.wide).month(.wide).day())
    }
}

extension Conversation {
    /// What this conversation is known by in the chat list (`CarPlayChat.key`): its session on a
    /// Hermes server, or its own id on this phone. Nil before a Hermes session exists.
    var catchUpKey: String? {
        settings.transport.hasLedger ? serverSessionID : id.uuidString
    }
}

extension CatchUp {
    /// The open conversation has been seen as it stands: it is on the phone's screen, or its
    /// reply has just been heard. No news to a catch-up until it moves again.
    @MainActor static func saw(_ conversation: Conversation, now: Date = .now) {
        guard let key = conversation.catchUpKey else { return }
        conversation.settings.catchUp.saw(key, at: now)
    }
}
