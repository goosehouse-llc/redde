import CryptoKit
import Foundation

/// What the agent hears with a message that isn't the person's words: the reply language, the
/// units, which calendars to look at, roughly where they are on a place question, "short, I'm
/// driving". The Hermes API takes these as the turn's instructions. The Dashboard's
/// `prompt.submit` takes none, so they were written after the message as notes, which Redde
/// hides and every other app shows (GitHub issue 72, 2026-11-09: "location data getting injected
/// into the chat").
///
/// With Redde's plugin on the Hermes (1.21.0 and later) the notes are handed to it just before
/// the message (`/redde-push turn …`) and it gives them to the model as the turn's context:
/// Hermes puts that after the message for the model alone and keeps the message as it was typed.
/// On a Hermes without the plugin, or with an older one, they ride on the message as before.
nonisolated enum TurnNotes {
    /// The turn's notes as the message carries them, in the order `ReplyLanguage.stripNote`
    /// takes them off again; empty when the turn has none. (Who an @mention is, the files sent
    /// with it and the like are part of the message, and stay on it: Redde reads them back.)
    static func riding(_ request: TurnRequest) -> String {
        (request.replyLanguage.map(ReplyLanguage.note) ?? "") + (request.units.map(MeasureUnits.note) ?? "")
            + (request.calendars.map(CalendarChoice.note) ?? "") + (request.location.map(CurrentLocation.note) ?? "")
            + (request.brief ? CarBrevity.note : "")
            + (request.incognito ? IncognitoNote.note : "")
            + (request.live.flatMap { $0.surface ? nil : LiveVoiceNote.note(context: $0.context) } ?? "")
            + (request.answeringCall.map(CallNote.note) ?? "")
    }

    // MARK: Handing them to the plugin

    /// What the plugin answers when it has kept a note.
    static let kept = "redde-push turn kept"
    /// A Hermes that didn't take a note isn't asked again for this long, or until its socket is
    /// opened again (the plugin is installed or updated from the app, and Hermes started again).
    static let askAgainAfter: TimeInterval = 60 * 60
    /// The most the plugin keeps (`turnnote.LONGEST`); longer ones ride on the message.
    static let longest = 16_000

    /// A message by its own words, as the plugin marks it (`turnnote.mark`): the note is kept for
    /// the message with this mark, so one queued behind another turn still gets its own.
    static func mark(_ said: String) -> String {
        let words = said.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return SHA256.hash(data: Data(words.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// `/redde-push`'s arguments that hand `notes` over for the message `said` in the session
    /// Hermes stores as `stored`; nil when there is nothing to hand over, or too much.
    static func command(stored: String, said: String, notes: String) -> String? {
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty, notes.count <= longest, !stored.isEmpty,
              stored.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.:-".unicodeScalars.contains($0)) })
        else { return nil }
        let coded = Data(notes.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "turn \(stored) \(mark(said)) \(coded)"
    }

    // MARK: A chat's first line

    /// How each note opens, without the blank line before it. A chat's preview is the start of
    /// its first message, and a short message's preview ran on into its notes.
    private static let openings: [String] = [
        "(Reply in ", "(Use US units.)", "(Use metric units.)", "(Look only at these calendars: ", "(The user is near ",
        "(I'm driving and will hear this read aloud", "[Incognito chat: ", LiveVoiceNote.opening, CallNote.opening, MentionNote.opening,
        AttachedFileNote.opening, AttachedFileNote.pictureOpening, "[Redde: ", "[Redde card ",
    ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A chat's preview as Hermes gives it (the start of its first message, sixty characters, the
    /// line breaks made spaces, "..." where it was cut), without the notes Redde wrote after the
    /// message: up to the first of them, whole or cut short. Empty for a message that was only notes.
    static func preview(_ text: String) -> String {
        var text = text
        // A note, whole or as far as the preview goes.
        for opening in openings {
            if text.hasPrefix(opening) { return "" }
            for gap in ["\n\n", "  "] {
                if let found = text.range(of: gap + opening) { text = String(text[..<found.lowerBound]) }
            }
        }
        // The preview's end fell in a note's opening ("…near me  (The us..."), or in the blank
        // line before it ("…near me  ...").
        if text.hasSuffix("...") {
            let body = text.dropLast(3)
            let last = ["  (", "  [", "\n\n(", "\n\n["].compactMap { body.range(of: $0, options: .backwards) }.max { $0.lowerBound < $1.lowerBound }
            if let last, case let begun = body[body.index(before: last.upperBound)...], openings.contains(where: { $0.hasPrefix(begun) }) {
                text = String(body[..<last.lowerBound])
            } else if body.hasSuffix("  ") || body.hasSuffix("\n\n") {
                text = String(body)
            } else if openings.contains(where: { $0.hasPrefix(body) }) {
                return ""   // only a note, and a long one
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
