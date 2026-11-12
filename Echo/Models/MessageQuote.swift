import Foundation

/// A message, or part of one, quoted in the next message (asked 2026-11-11, from the Conduit gap
/// list). The composer shows it above the field until the message goes; then it's the message's
/// first lines, as a Markdown quote (`Quote.markdown`). Markdown because it then means the same
/// to everything that reads the chat: the agent, Hermes's own apps, and Redde on another device,
/// which draws it back as a quote (`Quote.split`). Nothing on the server has to know of it, on
/// either connection.
nonisolated struct QuotedText: Equatable, Sendable {
    var text: String
    /// Who said it: the agent's or a bot's name, "You", or nil for a selection from a sheet.
    var speaker: String?
    /// The message it came from, while that's known.
    var messageID: UUID?
    /// A message of the person's own.
    var mine = false
}

extension Quote {
    /// How much of a whole message is quoted: the start, enough to say which message it is. The
    /// agent has the rest in its chat.
    static let wholeLimit = 280
    /// How much of a selection is quoted: what was picked, unless it's most of a long reply.
    static let selectionLimit = 2000

    /// A whole message's quote: its words as shown, and only the start of a long one, ended
    /// with "…". A message that quotes another gives its own words alone.
    static func excerpt(_ text: String, limit: Int = wholeLimit) -> String {
        let own = split(text)?.rest ?? text
        let plain = PlainText.display(own).trimmingCharacters(in: .whitespacesAndNewlines)
        return shortened(plain, to: limit)
    }

    /// A selection's quote.
    static func selection(_ text: String) -> String {
        shortened(text.trimmingCharacters(in: .whitespacesAndNewlines), to: selectionLimit)
    }

    private static func shortened(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        var cut = Substring(text.prefix(limit))
        // At a word's end where there's one in the second half.
        if let space = cut.lastIndex(where: \.isWhitespace), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            cut = cut[..<space]
        }
        return cut.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:-–—"))) + "…"
    }

    /// The message as `send` puts it: the quote's lines, a blank line, then what was written.
    static func message(_ text: String, quoting quote: QuotedText?) -> String {
        guard let quote, !quote.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        return markdown(quote.text) + text
    }

    /// A message that opens with a quote: the quote, and what was written under it. Nil when it
    /// doesn't open with one, or has nothing under it (a pasted quote is left as it was).
    static func split(_ message: String) -> (quote: String, rest: String)? {
        guard message.hasPrefix(">") else { return nil }
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        var quoted: [Substring] = []
        var index = 0
        while index < lines.count, lines[index].hasPrefix(">") {
            var line = lines[index].dropFirst()
            if line.hasPrefix(" ") { line = line.dropFirst() }
            quoted.append(line)
            index += 1
        }
        guard index < lines.count, lines[index].allSatisfy(\.isWhitespace) else { return nil }
        let rest = lines[index...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let quote = quoted.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty, !quote.isEmpty else { return nil }
        return (quote, rest)
    }

    /// The message a quote came from: the newest one before `before` whose words hold the quote's
    /// first line (up to 48 characters of it). Nil when none does, as when it has scrolled out of
    /// what this device has of the chat.
    static func source(of quote: String, in messages: [Message], before id: UUID) -> UUID? {
        let first = quote.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let start = String(first.replacingOccurrences(of: "…", with: "").prefix(48)).trimmingCharacters(in: .whitespaces)
        guard start.count >= 3 else { return nil }
        let end = messages.firstIndex { $0.id == id } ?? messages.endIndex
        return messages[..<end].last { message in
            let own = message.role == .user ? (split(message.text)?.rest ?? message.text) : message.text
            return PlainText.display(own).localizedCaseInsensitiveContains(start)
        }?.id
    }
}
