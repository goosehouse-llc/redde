import Foundation

/// Settings → Voice → Reply language: ask the agent to answer in one language, whatever the user
/// writes or speaks in. Empty is Automatic: nothing is sent, and the model answers in whatever
/// language it's addressed in.
nonisolated enum ReplyLanguage {
    /// The languages offered, as ISO codes. Most models write these well.
    static let codes = [
        "ar", "bg", "ca", "cs", "da", "de", "el", "en", "es", "et", "fa", "fi", "fr", "he", "hi", "hr", "hu",
        "id", "it", "ja", "ko", "lt", "lv", "ms", "nb", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sr", "sv",
        "sw", "ta", "th", "tl", "tr", "uk", "ur", "vi", "zh",
    ]

    /// For the model: the name in English, and in the language itself ("Dutch (Nederlands)").
    static func name(_ code: String) -> String {
        let english = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        guard let native = Locale(identifier: code).localizedString(forLanguageCode: code),
              native.lowercased() != english.lowercased() else { return english }
        return "\(english) (\(native))"
    }

    /// For the person: the name in the iPhone's language.
    static func displayName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized(with: .current) ?? code
    }

    /// Added to the agent's system prompt (the Hermes API's instructions, an OpenAI-compatible
    /// system message).
    static func instruction(_ code: String) -> String {
        "Always reply in \(name(code)), whatever language the user writes or speaks in, unless they ask for another language."
    }

    /// The Hermes Dashboard takes no instructions with a message, so the request rides on the
    /// message itself. Other clients see it; Redde hides it (`stripNote`).
    static func note(_ code: String) -> String { "\n\n(Reply in \(name(code)).)" }

    /// A message loaded back from the server, without the note, nor the one a question asked
    /// from the car carries after it (`CarBrevity`), nor the one that says who an @mention is
    /// (`MentionNote`), which comes before both, nor the asides told with it (`AsideNote`), before
    /// that, unless `keepingAsides` (the transcript reads them back out).
    static func stripNote(_ text: String, keepingAsides: Bool = false) -> String {
        var text = MeasureUnits.strip(CarBrevity.strip(IncognitoNote.strip(LiveVoiceNote.strip(CallNote.strip(text)))))
        if text.hasSuffix(".)"), let range = text.range(of: "\n\n(Reply in ", options: .backwards),
           !text[range.upperBound...].contains("\n") {
            text = String(text[..<range.lowerBound])
        }
        let plain = CardNote.strip(RoutineNote.strip(MentionNote.strip(AttachedFileNote.strip(text))))
        return keepingAsides ? plain : AsideNote.strip(plain)
    }
}

/// A file sent where only text can go: over the Hermes API, which takes text and pictures only,
/// anything but a picture, and in a group chat, which takes text alone, a picture too. It goes to
/// the server through the Dashboard's login (`ServerFiles.place`), and the message says where it
/// is, for the agent to read or look at with its own tools. Redde hides the note, and a group
/// chat shows the files it names.
nonisolated enum AttachedFileNote {
    static let opening = "\n\n[The user attached a file, saved on your machine at "
    static let pictureOpening = "\n\n[The user attached a picture, saved on your machine at "

    static func note(path: String) -> String { opening + path + " — read it with your tools.]" }
    static func note(picture path: String) -> String { pictureOpening + path + " — look at it with your tools.]" }

    /// A message loaded back from the server, without the notes (one per file).
    static func strip(_ text: String) -> String { split(text).text }

    /// The files a message's notes name, by their paths on the server, in the order sent.
    static func paths(in text: String) -> [String] { split(text).paths }

    /// What was typed, and the paths its notes name. A message that was only files begins with a
    /// note, the blank line before it trimmed away by Hermes.
    static func split(_ text: String) -> (text: String, paths: [String]) {
        var text = text, paths: [String] = []
        let openings = [opening, pictureOpening]
        while text.hasSuffix("]") {
            // The last note: after a blank line, or at the very start.
            let after = openings.compactMap { text.range(of: $0, options: .backwards) }
            let first = openings.compactMap { o in text.hasPrefix(o.dropFirst(2)) ? text.range(of: String(o.dropFirst(2))) : nil }
            guard let note = (after + first).max(by: { $0.lowerBound < $1.lowerBound }), !text[note.upperBound...].contains("\n"),
                  let end = text[note.upperBound...].range(of: " — ", options: .backwards) else { break }
            paths.insert(String(text[note.upperBound ..< end.lowerBound]), at: 0)
            text = String(text[..<note.lowerBound])
        }
        return (text, paths)
    }
}

/// What an incognito chat (`Incognito`) tells the agent, and the words that stand in for its own
/// outside the app.
nonisolated enum IncognitoNote {
    /// What the agent is told: over the Hermes API, among the turn's instructions; on the
    /// Dashboard, which takes none, on the message, where Redde hides it (`strip`).
    static let instruction = "This is an incognito chat: it is deleted when the person leaves it. Don't save anything from it to memory, notes, files or skills, and don't bring it up in other conversations."
    static let note = "\n\n[Incognito chat: deleted when the person leaves it. Save nothing from it to memory, notes, files or skills.]"
    /// What the Lock Screen, a notification and the header say in its words' place.
    static let title = String(localized: "Incognito chat")
    static let replied = String(localized: "Your reply is ready.")

    /// A message loaded back from the server, without the note.
    static func strip(_ text: String) -> String {
        guard text.hasSuffix("]"), let range = text.range(of: note, options: .backwards), range.upperBound == text.endIndex else { return text }
        return String(text[..<range.lowerBound])
    }

}

/// A message to a bot that @mentions another bot carries a note after it saying which bot each
/// tag means, worded as Hermes Desktop words it (`BotMentions.note`): what the agent needs to
/// pass the question on with its message_agent tool. Other clients see it; Redde hides it.
nonisolated enum MentionNote {
    static let opening = "\n\n[@mentions resolved from the Bot Mode roster — "

    /// A message loaded back from the server, without the note (Redde's or Hermes Desktop's).
    static func strip(_ text: String) -> String {
        guard text.hasSuffix("]"), let range = text.range(of: opening, options: .backwards),
              !text[range.upperBound...].contains("\n") else { return text }
        return String(text[..<range.lowerBound])
    }
}

/// Settings → Voice → Short answers in the car: a question asked by voice while the phone is
/// with a car asks the agent for an answer short enough to follow at the wheel, two or three
/// sentences, and to offer the rest. "More" is then a question like any other, and the agent
/// carries on. Nothing is cut or summed up on the phone: the reply in the conversation is the
/// reply that was heard.
/// A turn GPT-Live handed to the agent (`LiveVoice`): what it is and how to answer it, as Hermes
/// tells its own model when its Dashboard takes the turn as a live voice one
/// (`VOICE_LIVE_TURN_NOTE`, tools/voice_live.py). Other connections are told here.
nonisolated enum LiveVoiceNote {
    /// The most of the spoken exchange that goes with a turn, as Hermes keeps it.
    static let contextLimit = 6_000

    static let instruction = """
        This message comes from a live spoken conversation: a voice model is talking with the user \
        and handed this request to you. The text is a voice transcript; it may contain mishearings, \
        hesitations and later corrections, so go by the latest intent. Your reply will be spoken \
        aloud in that voice, often word for word as you write it, so write the words to say to the \
        user, addressed to them: answer in plain conversational sentences, keep it short (a few sentences unless the user asked for detail, or for a story or \
        the like, which you write in full, with what you know about them), with no markdown, no lists, \
        no code blocks and no links read out. Do the work with your tools as usual; only the final \
        facts need to be spoken. Don't say an action succeeded before it actually did.
        """ + " " + lookAgain

    /// With every live turn. Asked "is the tree on?" five times, Home's agent answered from its own
    /// result of a minute before, with no tool, the plug switched off by hand in between (Marta,
    /// 2026-10-26); Hermes's own note for a live turn says nothing of it.
    static let lookAgain = "Whether anything is on or off, open or shut, where it is or what it reads right now: look it up "
        + "with your tools before you answer, every time, even if you checked or changed it a moment ago. Never answer "
        + "that from earlier in this conversation: things change outside it."

    /// Before an exchange the voice speaks in: its lines are its own words. It has no tools and sees
    /// nothing; a guess of its, given to the agent unmarked, was taken for a fact (2026-10-25).
    static let caveat = "(The voice assistant's lines are its own words: it has no tools and can see nothing, "
        + "so what it says about the state of anything is not a fact. Check with your tools, and do what the user asks.)"

    /// The exchange as the agent is given it, newest last and `limit` at most: with `caveat`
    /// before it where the voice has lines in it.
    static func spoken(context: String, limit: Int = contextLimit) -> String {
        guard context.contains("Voice assistant:") else { return String(context.suffix(limit)) }
        return caveat + "\n" + String(context.suffix(limit - caveat.count - 1))
    }

    /// Hermes's `voice_context` (0.21.3 and later), model input only: `lookAgain` first, as Hermes
    /// words the rest of the note itself, then the exchange; `contextLimit` at most, as Hermes keeps.
    static func voiceContext(_ context: String) -> String {
        let rule = "(" + lookAgain + ")"
        guard !context.isEmpty else { return rule }
        return rule + "\n" + spoken(context: context, limit: contextLimit - rule.count - 1)
    }

    /// The instruction, and the exchange it refers to, newest last.
    static func instruction(context: String) -> String {
        context.isEmpty ? instruction : instruction + "\n\nThe recent spoken conversation, newest last:\n" + spoken(context: context)
    }

    /// On a Dashboard that doesn't know live voice turns (Hermes 0.21.0), the note rides on the
    /// message. Redde hides it (`strip`).
    static let opening = "\n\n[Spoken live. "
    static func note(context: String) -> String { opening + instruction(context: context) + "]" }

    /// A message loaded back from the server, without the note.
    static func strip(_ text: String) -> String {
        guard let range = text.range(of: opening), text.hasSuffix("]") else { return text }
        return String(text[..<range.lowerBound])
    }
}

/// The person answered a call the agent made (`AgentCalls`): what they say first goes with a note
/// saying so, and what the agent opened with, so the agent takes it as the answer to its call. Over
/// the Hermes API among the turn's instructions; on the Dashboard on the message, last, where Redde
/// hides it (`strip`).
nonisolated enum CallNote {
    /// The agent's line, as much of it as goes with the note.
    static let lineLimit = 500

    static func instruction(_ line: String) -> String {
        "The user just answered your phone call (call_user) and is talking with you by voice. You opened with: \""
            + String(line.prefix(lineLimit)) + "\" This message is their answer: carry on from there, briefly, as on a call."
    }

    static let opening = "\n\n[Answering your call. "
    static func note(_ line: String) -> String {
        opening + "You opened with: \"" + String(line.prefix(lineLimit)).replacingOccurrences(of: "\n", with: " ") + "\"]"
    }

    /// A message loaded back from the server, without the note.
    static func strip(_ text: String) -> String {
        guard text.hasSuffix("\"]"), let range = text.range(of: opening, options: .backwards),
              !text[range.upperBound...].contains("\n") else { return text }
        return String(text[..<range.lowerBound])
    }
}

nonisolated enum CarBrevity {
    /// Added to the agent's system prompt for the turn (the Hermes API's instructions, an
    /// OpenAI-compatible system message).
    static let instruction = """
        The user is driving and hears this reply read aloud through the car; they can't look at a \
        screen. Answer in two or three short spoken sentences, without lists, tables, code or links. \
        If there is more worth hearing, end by asking whether they want it, and when they say "more" \
        or "go on", carry on from where you stopped. If they ask for something to be read out in \
        full, read it.
        """

    /// The Hermes Dashboard takes no instructions with a message, so the request rides on the
    /// message itself, after a reply-language note if there is one. Other clients see it; Redde
    /// hides it (`strip`).
    static let note = "\n\n(I'm driving and will hear this read aloud: answer in two or three short spoken sentences, and ask whether I want more.)"

    /// A message loaded back from the server, without the note.
    static func strip(_ text: String) -> String {
        text.hasSuffix(note) ? String(text.dropLast(note.count)) : text
    }
}
