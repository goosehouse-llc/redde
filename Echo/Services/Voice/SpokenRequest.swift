import Foundation

/// A request the agent waits on, put to the person aloud in voice mode (Settings → Voice →
/// Answer requests by voice): a command to approve or deny, or one question. What has to be
/// typed (a password, a secret) and what has several parts stays for the screen.
///
/// Approving a command by voice means anyone in earshot can do it, and so can a word misheard.
/// So an answer is the whole utterance and one of a short list: "approve" or "yes" approves,
/// "sure, why not" does not, and anything that isn't an answer is asked about once more and then
/// left for the screen. Nothing is ever approved by default.
///
/// The answers are heard in English and in the listening language (`words`), and what is said is
/// said in the listening language.
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
    /// The listening language's words, and where what is said is looked up.
    let words: VoiceWords

    /// Nil for a request that can't be answered aloud: a password, a secret, several questions at
    /// once, a question that takes several answers, or an approval without a plain yes and no.
    init?(_ interrupt: Interrupt, words: VoiceWords = .current) {
        self.words = words
        let said = words.bundle
        switch interrupt {
        case let .approval(request):
            guard let yesNo = request.yesNo else { return nil }
            id = request.id
            kind = .approval(approve: yesNo.approve, deny: yesNo.deny)
            let what = [request.description, request.command]
                .compactMap { $0.map { Self.speakable($0, words: words) } }
                .filter { !$0.isEmpty }
            prompt = Self.sentences([String(localized: "Approval needed", bundle: said, comment: "Said aloud too, in voice mode, before the command is read out")]
                + what.prefix(2) + [Self.sayApproveOrDeny(words)])
        case let .clarify(request):
            guard request.questions.count == 1, let question = request.questions.first, !question.multiSelect,
                  question.choices.count <= Self.numbers.count else { return nil }
            id = request.id
            kind = .question(id: request.isBatch ? question.id : "", choices: question.choices)
            let choices = question.choices.enumerated().map {
                "\(words.spokenNumbers[$0.offset].capitalized(with: words.locale)): \(Self.speakable($0.element, words: words))"
            }
            prompt = Self.sentences([Self.speakable(question.question, limit: 400, words: words)] + choices
                + (choices.isEmpty ? [] : [String(localized: "Say the number, or the answer.", bundle: said, comment: "On the voice screen, and said aloud after the choices are read out")]))
        case .sudo, .secret:
            return nil
        }
    }

    /// What is said when an answer wasn't one, before listening once more.
    var reminder: String {
        switch kind {
        case .approval: return Self.sayApproveOrDeny(words)
        case let .question(_, choices):
            let list = words.spokenList(Array(words.spokenNumbers.prefix(choices.count)))
            return choices.isEmpty ? String(localized: "What's your answer?", bundle: words.bundle, comment: "Said aloud in voice mode, when what was heard didn't answer a question")
                : String(localized: "Say \(list).", bundle: words.bundle, comment: "Said aloud in voice mode: the numbers of a question's choices, \"Say one, two or three.\"")
        }
    }

    /// "Say approve, or deny.", in the listening language with its words.
    private static func sayApproveOrDeny(_ words: VoiceWords) -> String {
        String(localized: "Say \(words.approveWord), or \(words.denyWord).", bundle: words.bundle,
               comment: "Said aloud in voice mode after an approval is read out. The two values are the words Redde listens for to approve and to deny, in this language")
    }

    /// Under the voice screen's state while the answer is listened for.
    var hint: String {
        switch kind {
        case .approval: String(localized: "Say “\(words.approveWord)” or “\(words.denyWord)”.", comment: "On the voice screen. The two values are the words Redde listens for to approve and to deny, in the language it listens in")
        case let .question(_, choices): choices.isEmpty ? String(localized: "Say your answer.", comment: "On the voice screen")
            : String(localized: "Say the number, or the answer.", comment: "On the voice screen, and said aloud after the choices are read out")
        }
    }

    /// The same, while a nod and a shake of the head answer too.
    var nodHint: String {
        switch kind {
        case .approval: String(localized: "Nod or say “\(words.approveWord)”. Shake your head or say “\(words.denyWord)”.", comment: "On the voice screen. The two values are the words Redde listens for to approve and to deny, in the language it listens in")
        case .question: String(localized: "Nod for yes, shake your head for no, or say it.", comment: "On the voice screen")
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
            let yes = choices.filter { isYes(plain($0)) }
            let no = choices.filter { isNo(plain($0)) }
            guard choices.count == 2, yes.count == 1, no.count == 1 else { return nil }
            return .clarify(questionID: id, answer: nod ? yes[0] : no[0])
        }
    }

    /// What an utterance answers; nil when it is no answer to this request.
    func answer(_ utterance: String) -> Answer? {
        let said = plain(utterance)
        guard !said.isEmpty else { return nil }
        switch kind {
        case let .approval(approve, deny):
            // As said, then without the polite words around it: an answer that starts with one
            // ("はいありがとう") is taken whole.
            let whole = StopPhrase.normalize(utterance)
            if isNo(whole) { return .approval(deny) }
            if isYes(whole) { return .approval(approve) }
            if isYes(said) { return .approval(approve) }
            if isNo(said) { return .approval(deny) }
            return nil
        case let .question(id, choices):
            guard !choices.isEmpty else {
                return .clarify(questionID: id, answer: utterance.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let n = Self.number(said) ?? words.number(said), n <= choices.count { return .clarify(questionID: id, answer: choices[n - 1]) }
            if let choice = choices.first(where: { plain($0) == said }) { return .clarify(questionID: id, answer: choice) }
            return nil
        }
    }

    /// Said back before the reply carries on, so a mishearing is heard.
    func confirmation(of answer: Answer) -> String {
        let said = words.bundle
        let okay = String(localized: "Okay.", bundle: said, comment: "Said aloud in voice mode: an answer taken, or a stop phrase heard")
        switch (kind, answer) {
        case let (.approval(approve, _), .approval(choice)):
            return choice == approve ? String(localized: "Approved.", bundle: said, comment: "Said aloud in voice mode: a command approved by voice")
                : String(localized: "Denied.", bundle: said, comment: "Said aloud in voice mode: a command denied by voice")
        case let (.question(_, choices), .clarify(_, answer)):
            let answer = Self.speakable(answer, words: words)
            return choices.isEmpty ? okay : String(localized: "Okay, \(answer).", bundle: said, comment: "Said aloud in voice mode: the choice taken, read back")
        default:
            return okay
        }
    }

    private func isYes(_ said: String) -> Bool { Self.yes.contains(said) || words.yes.contains(said) }
    private func isNo(_ said: String) -> Bool { Self.no.contains(said) || words.no.contains(said) }

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
    func plain(_ utterance: String) -> String { Self.plain(utterance, words: words) }

    static func plain(_ utterance: String, words: VoiceWords = .current) -> String {
        var text = StopPhrase.normalize(utterance)
        let leading = words.before + ["okay", "ok", "um", "uh", "hermes", "redde"]
        let trailing = words.after + ["thank you", "please", "thanks", "hermes", "redde"]
        while let peeled = VoiceWords.peel(text, leading: leading) ?? VoiceWords.peel(text, trailing: trailing) { text = peeled }
        return text
    }

    /// Text made fit to be read out: one line, and not all of a long command.
    static func speakable(_ text: String, limit: Int = 140, words: VoiceWords = .current) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .:;"))
        guard line.count > limit else { return line }
        let cut = line.prefix(limit)
        return String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)])
            + String(localized: ", and more", bundle: words.bundle, comment: "Said aloud in voice mode after a long command cut short (it follows the command's first words directly)")
    }

    /// Parts read one after the other, each ended as a sentence unless it ends itself.
    private static func sentences(_ parts: [String]) -> String {
        parts.map { part in [".", "?", "!", "。", "？", "！"].contains { part.hasSuffix($0) } ? part : part + "." }
            .joined(separator: " ")
    }
}
