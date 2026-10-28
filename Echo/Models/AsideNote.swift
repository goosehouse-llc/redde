import Foundation

/// The asides not yet told to the main agent, as a note after the person's next message to it,
/// and read back out of that message when the chat is loaded from the host. Words to the model:
/// English, as Redde's other notes are.
nonisolated enum AsideNote {
    static let opening = "\n\n[Redde: apart from you, the user asked other agents here, and their answers were shown to them: "

    struct Aside: Codable, Equatable, Sendable {
        /// The bot's profile, and what it is called.
        var agent: String
        var name: String
        var asked: String
        var answer: String
    }

    /// At most this many, the newest, and this long each: enough to go on, short for the prompt.
    static let most = 4
    static let askedLength = 500
    static let answerLength = 1500

    static func note(for asides: [Aside]) -> String? {
        let kept = asides.suffix(most).map {
            Aside(agent: $0.agent, name: $0.name, asked: String($0.asked.prefix(askedLength)), answer: String($0.answer.prefix(answerLength)))
        }
        guard !kept.isEmpty, let data = try? JSONEncoder().encode(Array(kept)), let json = String(data: data, encoding: .utf8) else { return nil }
        return opening + json + "]"
    }

    /// A message loaded back: its own words, and the asides its note told of.
    static func split(_ text: String) -> (text: String, asides: [Aside]) {
        guard text.hasSuffix("]"), let range = text.range(of: opening, options: .backwards) else { return (text, []) }
        let json = text[range.upperBound ..< text.index(before: text.endIndex)]
        guard let asides = try? JSONDecoder().decode([Aside].self, from: Data(json.utf8)) else { return (text, []) }
        return (String(text[..<range.lowerBound]), asides)
    }

    static func strip(_ text: String) -> String { split(text).text }

    /// The two messages an aside was, as they showed: the question, then the bot's answer.
    static func messages(_ aside: Aside, before at: Date) -> [Message] {
        var asked = Message(role: .user, text: aside.asked, createdAt: at.addingTimeInterval(-2))
        asked.delivered = Delivered(kind: .asked, profile: aside.agent, name: aside.name, noted: true)
        var answer = Message(role: .user, text: aside.answer, createdAt: at.addingTimeInterval(-1))
        answer.delivered = Delivered(kind: .answer, profile: aside.agent, name: aside.name, noted: true)
        return [asked, answer]
    }

    /// The asides in `messages` the main agent hasn't been told of: each question with its answer.
    static func pending(in messages: [Message]) -> [Aside] {
        var out: [Aside] = []
        for (i, message) in messages.enumerated() where message.delivered?.kind == .answer && message.delivered?.noted != true {
            guard message.error == nil, !message.text.isEmpty, let delivered = message.delivered else { continue }
            let asked = messages[..<i].last { $0.delivered?.kind == .asked }?.text ?? ""
            out.append(Aside(agent: delivered.profile ?? "", name: delivered.name ?? "", asked: asked, answer: message.text))
        }
        return out
    }
}

/// "Make This a Routine" (asked 2026-10-28, after Grok Bot's teach-it-once routines): the note on
/// the message that asks the agent to keep what it did in the chat as a Hermes skill, to do again
/// on its own. Words to the model: English. Other clients see it; Redde hides it.
nonisolated enum RoutineNote {
    static let opening = "\n\n[Redde: the user wants this to become a routine named "

    /// A skill's name for a routine's ("Morning Report" → "morning-report").
    static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en")).lowercased()
        let slug = folded.replacing(/[^a-z0-9]+/, with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((slug.isEmpty ? "routine" : slug).prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// `when`: how often it will run, in words ("every day at 07:30"), or nil for only when asked.
    static func note(name: String, skill: String, when: String?) -> String {
        opening + "\"\(name)\". Save what you did in this conversation as a skill named \"\(skill)\" with your skill tool "
            + "(skill_manage; find it with tool_search if it isn't among your tools): the steps to do it again on your own, "
            + "which tools and sources you used, and what to give back at the end; leave out the details that change each time. "
            + "Don't do the task again now. Then say in one line that it is saved"
            + (when.map { " and that it will run \($0), its answer coming to them as a notification" } ?? "") + ".]"
    }

    static func strip(_ text: String) -> String {
        guard text.hasSuffix(".]"), let range = text.range(of: opening, options: .backwards) else { return text }
        return String(text[..<range.lowerBound])
    }

    /// What its scheduled job asks each time.
    static func jobPrompt(name: String, skill: String) -> String {
        "Routine \"\(name)\": use your skill \"\(skill)\" (open it with skill_view first) and do what it says, for now. "
            + "Your answer is what the user reads, as a notification: keep it short. If the skill isn't there, say so in one line."
    }
}
