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
        /// Asked by the chat's agent itself (`relayOpening`), not by the person: never in the JSON.
        var relayed: Bool? = nil
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

    /// The answers to the agents the chat's agent itself asked (2.7): the turn Redde gives it back
    /// with them, which has no words of the person's.
    static let relayOpening = "\n\n[Redde: the agents you asked by @name answered, and the user was shown their answers. Go on with what the user asked. Their answers: "

    static func relayNote(for asides: [Aside]) -> String? {
        note(for: asides).map { relayOpening + $0.dropFirst(opening.count) }
    }

    /// A message loaded back: its own words, and the asides its note told of.
    static func split(_ text: String) -> (text: String, asides: [Aside]) {
        guard text.hasSuffix("]") else { return (text, []) }
        for (marker, relayed) in [(opening, false), (relayOpening, true)] {
            guard let range = text.range(of: marker, options: .backwards) else { continue }
            let json = text[range.upperBound ..< text.index(before: text.endIndex)]
            guard var asides = try? JSONDecoder().decode([Aside].self, from: Data(json.utf8)) else { continue }
            if relayed { for i in asides.indices { asides[i].relayed = true } }
            return (String(text[..<range.lowerBound]), asides)
        }
        return (text, [])
    }

    static func strip(_ text: String) -> String { split(text).text }

    /// The two messages an aside was, as they showed: the question, then the bot's answer.
    /// One the chat's agent asked: the answer alone, its question being the reply before it.
    static func messages(_ aside: Aside, before at: Date) -> [Message] {
        if aside.relayed == true {
            var answer = Message(role: .user, text: aside.answer, createdAt: at.addingTimeInterval(-1))
            answer.delivered = Delivered(kind: .answer, profile: aside.agent, name: aside.name, noted: true, asked: aside.asked)
            return [answer]
        }
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
            let asked = delivered.asked ?? messages[..<i].last { $0.delivered?.kind == .asked }?.text ?? ""
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
    /// `asked`: from a reply's menu (2026-11-04), what the user asked for that reply; the routine
    /// is what was done for it, not the whole conversation.
    static func note(name: String, skill: String, when: String?, asked: String? = nil) -> String {
        let what = asked.map { "what you did to answer their request \"\($0)\"" } ?? "what you did in this conversation"
        return opening + "\"\(name)\". Save \(what) as a skill named \"\(skill)\" with your skill tool "
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

/// A tap on a card the agent asked with (`ReplyCard.review`, `.choice`, `.checklist`, `.form`):
/// the note on the person's message that says exactly what they picked or left in the fields,
/// with the card's key, so the card shows it answered when the conversation is read back. Words
/// to the model: English. Other clients see it; Redde hides it.
nonisolated enum CardNote {
    static let opening = "\n\n[Redde card "

    static func note(key: String, said: String) -> String { opening + key + ": " + said + "]" }

    /// A message loaded back: its own words, and the answered card's key and what was said.
    static func split(_ text: String) -> (text: String, key: String?, said: String?) {
        guard text.hasSuffix("]"), let range = text.range(of: opening, options: .backwards) else { return (text, nil, nil) }
        let body = text[range.upperBound ..< text.index(before: text.endIndex)]
        guard let colon = body.range(of: ": ") else { return (text, nil, nil) }
        return (String(text[..<range.lowerBound]), String(body[..<colon.lowerBound]), String(body[colon.upperBound...]))
    }

    static func strip(_ text: String) -> String { split(text).text }

    /// The card a message answered, wherever the note sits among the message's others.
    static func find(in text: String) -> (key: String, said: String)? {
        guard let range = text.range(of: opening) else { return nil }
        let rest = text[range.upperBound...]
        let end = rest.range(of: "]\n\n[")?.lowerBound ?? rest.lastIndex(of: "]") ?? rest.endIndex
        let body = rest[..<end]
        guard let colon = body.range(of: ": ") else { return nil }
        return (String(body[..<colon.lowerBound]), String(body[colon.upperBound...]))
    }
}

/// What goes to a tagged bot with the person's words (`BotAsides`), and off again when its own chat
/// is read back (it used to show there as it was sent). Words to the model: English.
nonisolated enum TaggedNote {
    static let opening = "\n\n[Redde: the user tagged you in their chat with "

    /// Asked by another agent (2.7): a line of its reply in its chat with the person began with this
    /// one's @name, and Redde passed it on.
    static let agentOpening = "\n\n[Redde: another agent asked you this, from its chat with the user: "

    static func note(from chat: String) -> String {
        opening + "\(chat), not here; your answer is shown to them there. Answer them directly.]"
    }

    static func note(asker: String) -> String {
        agentOpening + "\(asker). Your answer goes back to it and is shown to the user too. Answer it directly.]"
    }

    static func strip(_ text: String) -> String {
        for marker in [opening, agentOpening] {
            guard text.hasSuffix("]"), let range = text.range(of: marker, options: .backwards),
                  !text[range.upperBound...].contains("\n") else { continue }
            return String(text[..<range.lowerBound])
        }
        return text
    }
}

/// Who the chat's agent can ask (2.7, "allow all to talk to each other by @mention"): told once
/// per chat, again when that changes, with the person's message. A line of its reply beginning
/// with one's @name is passed on (`BotAsides.relayed`). Words to the model: English. Redde hides it.
/// What the chat's agent is told when the person said no to its asking another agent (or wrote
/// again before saying either): with their next message, so it doesn't wait on an answer.
nonisolated enum DeclinedNote {
    static let opening = "\n\n[Redde: the user chose not to ask "

    static func note(_ tags: [String]) -> String? {
        let named = tags.map { "@" + $0.filter { $0 != "[" && $0 != "]" } }
        guard !named.isEmpty else { return nil }
        return opening + named.joined(separator: ", ") + " for you, so nobody was asked. Go on without their answer.]"
    }

    /// Wherever it is among the other notes.
    static func strip(_ text: String) -> String {
        guard let start = text.range(of: opening), let end = text[start.upperBound...].firstIndex(of: "]") else { return text }
        return String(text[..<start.lowerBound] + text[text.index(after: end)...])
    }
}

nonisolated enum RosterNote {
    static let opening = "\n\n[Redde: other agents you can ask: "
    /// At most this many named: the prompt stays short.
    static let most = 12

    /// `entries`: each "@tag (Name)".
    static func note(_ entries: [String]) -> String? {
        let kept = entries.prefix(most).map { $0.filter { $0 != "[" && $0 != "]" } }
        guard !kept.isEmpty else { return nil }
        return opening + kept.joined(separator: ", ")
            + ". When one would help, start a line of your reply with its @name and what you want from it; Redde asks it, shows the user its answer and gives you the answer to go on with. Don't begin a line with an @name otherwise.]"
    }

    /// Wherever it is among the other notes.
    static func strip(_ text: String) -> String {
        guard let start = text.range(of: opening), let end = text[start.upperBound...].firstIndex(of: "]") else { return text }
        return String(text[..<start.lowerBound] + text[text.index(after: end)...])
    }
}

/// An agent's asks of other agents, put to the person before anyone is asked (Settings → Replies
/// & Writing → Ask Me First, on at first; 11-17, his ask). It is an approval like a command's,
/// so the card, voice mode's "approve or deny", a nod and "Needs you" all work as they do, but
/// it is Redde's own: answered here, never sent to a host.
nonisolated enum AgentAsks {
    /// Its request's id begins with this.
    static let prefix = "redde-ask-"

    static func isAsk(_ request: ApprovalRequest) -> Bool { request.id.hasPrefix(prefix) }

    /// `asker` wants to ask each of `asks` (whom, by name, and the line that asks them).
    static func request(asker: String, asks: [(name: String, text: String)]) -> ApprovalRequest {
        let names = asks.map(\.name)
        let whom = names.count == 1 ? names[0] : ListFormatter.localizedString(byJoining: names)
        return ApprovalRequest(id: prefix + UUID().uuidString,
                               command: asks.map(\.text).joined(separator: "\n"),
                               description: String(localized: "\(asker) wants to ask \(whom)",
                                                   comment: "Ask Me First: the chat's agent wants to ask other agents, named; on the card and said aloud"),
                               choices: ["once", "deny"])
    }
}
