import Foundation

/// A request the agent waits on, put to the person aloud in voice mode (Settings → Voice →
/// Answer requests by voice): a command to approve or deny, or one question. What has to be
/// typed (a password, a secret) and what has several parts stays for the screen.
///
/// Approving a command by voice means anyone in earshot can do it, and so can a word misheard.
/// So an answer is the whole utterance and one of a short list: "approve" or "yes" approves,
/// "sure, why not" does not, and anything that isn't an answer is asked about once more and then
/// left for the screen. Nothing is ever approved by default.
nonisolated struct SpokenRequest: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The choices to send for yes and for no.
        case approval(approve: String, deny: String)
        /// One question, with the id its answer goes under ("" when the request is the question).
        /// With `choices` the answer is one of them; without, whatever is said.
        case question(id: String, choices: [String])
    }

    enum Answer: Equatable, Sendable {
        /// One of the approval's own choices ("once", "deny").
        case approval(String)
        case clarify(questionID: String, answer: String)
    }

    /// The request's id, as the conversation holds it.
    let id: String
    let kind: Kind
    /// What is read out.
    let prompt: String

    /// Nil for a request that can't be answered aloud: a password, a secret, several questions at
    /// once, a question that takes several answers, or an approval without a plain yes and no.
    init?(_ interrupt: Interrupt) {
        switch interrupt {
        case let .approval(request):
            guard let yesNo = request.yesNo else { return nil }
            id = request.id
            kind = .approval(approve: yesNo.approve, deny: yesNo.deny)
            let what = [request.description, request.command]
                .compactMap { $0.map { Self.speakable($0) } }
                .filter { !$0.isEmpty }
            prompt = Self.sentences(["Approval needed"] + what.prefix(2) + ["Say approve, or deny"])
        case let .clarify(request):
            guard request.questions.count == 1, let question = request.questions.first, !question.multiSelect,
                  question.choices.count <= Self.numbers.count else { return nil }
            id = request.id
            kind = .question(id: request.isBatch ? question.id : "", choices: question.choices)
            let choices = question.choices.enumerated().map { "\(Self.numbers[$0.offset].capitalized): \(Self.speakable($0.element))" }
            prompt = Self.sentences([Self.speakable(question.question, limit: 400)] + choices
                + (choices.isEmpty ? [] : ["Say the number, or the answer"]))
        case .sudo, .secret:
            return nil
        }
    }

    /// What is said when an answer wasn't one, before listening once more.
    var reminder: String {
        switch kind {
        case .approval: "Say approve, or deny."
        case let .question(_, choices):
            choices.isEmpty ? "What's your answer?" : "Say \(Self.spokenList(Self.numbers.prefix(choices.count)))."
        }
    }

    /// Under the voice screen's state while the answer is listened for.
    var hint: String {
        switch kind {
        case .approval: String(localized: "Say “approve” or “deny”.", comment: "On the voice screen. Keep the quoted words in English: they are the words Redde listens for")
        case let .question(_, choices): choices.isEmpty ? String(localized: "Say your answer.", comment: "On the voice screen")
            : String(localized: "Say the number, or the answer.", comment: "On the voice screen. Redde listens for the numbers in English")
        }
    }

    /// The same, while a nod and a shake of the head answer too.
    var nodHint: String {
        switch kind {
        case .approval: String(localized: "Nod or say “approve”. Shake your head or say “deny”.", comment: "On the voice screen. Keep the quoted words in English: they are the words Redde listens for")
        case .question: String(localized: "Nod for yes, shake your head for no, or say it.", comment: "On the voice screen. Redde listens for yes and no in English")
        }
    }

    /// Whether a nod and a shake mean anything here: for an approval, and for a question whose
    /// two choices are a yes and a no.
    var takesNod: Bool { answer(nod: true) != nil }

    /// What a nod of the head answers, or a shake (Settings → Voice → Nod or shake to answer).
    func answer(nod: Bool) -> Answer? {
        switch kind {
        case let .approval(approve, deny):
            return .approval(nod ? approve : deny)
        case let .question(id, choices):
            let yes = choices.filter { Self.yes.contains(Self.plain($0)) }
            let no = choices.filter { Self.no.contains(Self.plain($0)) }
            guard choices.count == 2, yes.count == 1, no.count == 1 else { return nil }
            return .clarify(questionID: id, answer: nod ? yes[0] : no[0])
        }
    }

    /// What an utterance answers; nil when it is no answer to this request.
    func answer(_ utterance: String) -> Answer? {
        let said = Self.plain(utterance)
        guard !said.isEmpty else { return nil }
        switch kind {
        case let .approval(approve, deny):
            if Self.yes.contains(said) { return .approval(approve) }
            if Self.no.contains(said) { return .approval(deny) }
            return nil
        case let .question(id, choices):
            guard !choices.isEmpty else {
                return .clarify(questionID: id, answer: utterance.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let n = Self.number(said), n <= choices.count { return .clarify(questionID: id, answer: choices[n - 1]) }
            if let choice = choices.first(where: { Self.plain($0) == said }) { return .clarify(questionID: id, answer: choice) }
            return nil
        }
    }

    /// Said back before the reply carries on, so a mishearing is heard.
    func confirmation(of answer: Answer) -> String {
        switch (kind, answer) {
        case let (.approval(approve, _), .approval(choice)): choice == approve ? "Approved." : "Denied."
        case let (.question(_, choices), .clarify(_, answer)): choices.isEmpty ? "Okay." : "Okay, \(Self.speakable(answer))."
        default: "Okay."
        }
    }

    // MARK: - Words

    static let yes: Set<String> = [
        "approve", "approved", "approve it", "approve that", "i approve",
        "yes", "yes approve", "yes approve it", "yeah", "yep",
        "go ahead", "yes go ahead", "do it", "yes do it", "run it", "allow", "allow it", "confirm", "confirmed",
    ]

    static let no: Set<String> = [
        "deny", "denied", "deny it", "deny that", "no", "no deny", "no deny it", "nope",
        "don't", "do not", "don't do it", "do not do it", "don't run it", "do not run it",
        "reject", "reject it", "cancel", "stop", "no thanks", "no thank you", "never mind", "nevermind",
    ]

    static let numbers = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    private static let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]

    /// "two", "2", "number two", "option 2", "the second", "the second one": 2.
    static func number(_ said: String) -> Int? {
        var words = said.split(separator: " ").map(String.init)
        if let first = words.first, ["number", "option", "choice", "the"].contains(first) { words.removeFirst() }
        if words.count == 2, words[1] == "one", ordinals.contains(words[0]) { words.removeLast() }
        guard words.count == 1 else { return nil }
        if let i = numbers.firstIndex(of: words[0]) ?? ordinals.firstIndex(of: words[0]) { return i + 1 }
        return Int(words[0]).flatMap { (1 ... numbers.count).contains($0) ? $0 : nil }
    }

    /// An utterance as it is compared: lowercased, without punctuation, and without the polite
    /// words around an answer ("okay, approve it please").
    static func plain(_ utterance: String) -> String {
        var text = StopPhrase.normalize(utterance)
        var changed = true
        while changed {
            changed = false
            for filler in ["okay", "ok", "um", "uh", "hermes", "redde"] where text.hasPrefix(filler + " ") {
                text = String(text.dropFirst(filler.count + 1)); changed = true
            }
            for filler in ["please", "thanks", "thank you", "hermes", "redde"] where text.hasSuffix(" " + filler) {
                text = String(text.dropLast(filler.count + 1)); changed = true
            }
        }
        return text
    }

    /// Text made fit to be read out: one line, and not all of a long command.
    static func speakable(_ text: String, limit: Int = 140) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .:;"))
        guard line.count > limit else { return line }
        let cut = line.prefix(limit)
        return String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]) + ", and more"
    }

    /// Parts read one after the other, each ended as a sentence unless it ends itself.
    private static func sentences(_ parts: [String]) -> String {
        parts.map { $0.hasSuffix("?") || $0.hasSuffix("!") ? $0 : $0 + "." }.joined(separator: " ")
    }

    private static func spokenList(_ words: some Collection<String>) -> String {
        let words = Array(words)
        guard words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " or " + words[words.count - 1]
    }
}
