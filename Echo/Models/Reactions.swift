import Foundation

/// Reactions to a reply (asked 2026-11-05, from the Muse / Grok Bot list): hold a reply, tap an
/// emoji, and it shows under the reply. The agent hears of it with the person's next message, in
/// a note Redde hides (`ReactionNote`): a reaction alone starts no turn, and costs nothing until
/// then. Kept with the message here (`Message.reaction`) and carried over when the conversation
/// is read again from the host, which has no reactions of its own (`Conversation.keepingAsides`).
nonisolated enum Reactions {
    /// What can be picked, and what each says to the agent.
    static let all: [(emoji: String, means: String)] = [
        ("👍", "liked it"),
        ("❤️", "loved it"),
        ("😂", "found it funny"),
        ("😮", "was surprised by it"),
        ("🙏", "is thankful for it"),
        ("👎", "didn't like it"),
    ]

    static func means(_ emoji: String) -> String {
        all.first { $0.emoji == emoji }?.means ?? "reacted to it"
    }

    /// The start of a reply, as the note quotes it and as a reply is matched when the
    /// conversation is read again: its first words, on one line.
    static func opening(of text: String, limit: Int = 80) -> String {
        let line = PlainText.display(text).split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return line.count <= limit ? line : String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// The note that tells the agent of reactions made since the person last wrote, after their
/// message; hidden when the message is read back (`ReplyLanguage.stripNote`).
nonisolated enum ReactionNote {
    static let opening = "\n\n[Redde: since your last turn the user reacted"

    /// The note for these reactions, as (emoji, the reply's text), oldest first; nil for none.
    static func note(_ reactions: [(emoji: String, reply: String)]) -> String? {
        guard !reactions.isEmpty else { return nil }
        let each = reactions.map { "\($0.emoji) (\(Reactions.means($0.emoji))) to your reply that began \"\(Reactions.opening(of: $0.reply))\"" }
        return opening + ": " + each.joined(separator: "; ") + ". Take it into account; there is no need to answer it.]"
    }

    /// `text` without the note, wherever it sits among the message's others.
    static func strip(_ text: String) -> String {
        guard let start = text.range(of: opening) else { return text }
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: "no need to answer it.]") else { return text }
        return String(text[..<start.lowerBound] + text[end.upperBound...])
    }
}
