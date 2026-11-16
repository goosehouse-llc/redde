import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Three things the person might send next, once a reply has finished. A reply that lists
/// options and asks which gets those options, word for word and with no model. Any other is
/// read for what it calls for (a yes or no, an answer such as a time, or what to do or ask next)
/// and a model writes three for that: Apple's on-device model where it can (Apple Intelligence
/// on; nothing leaves the phone), or the model on the OpenAI-compatible connection (the fast
/// lane) when that's set up and the person chose it, or when it's the only one. Both work on
/// every connection. Never the agent: an extra prompt in the agent's session would land in the
/// chat. (2026-11-11, "suggested replies" from the Conduit gap list; reworked 2026-11-14 after
/// "they are currently not very good": options came back as "Yes, Frontier", a done task got
/// "Are the lights dim?", a question for a time got "Later?".)
nonisolated enum FollowUps {
    static let count = 3

    /// Where suggestions come from on this device.
    enum Source: Equatable { case onDevice, fastLane, none }

    /// The on-device model unless the person chose the fast lane's, or it's the only one there.
    static func source(fastLaneSet: Bool, preferFastLane: Bool = false) -> Source {
        if fastLaneSet, preferFastLane || !onDeviceAvailable { return .fastLane }
        return onDeviceAvailable ? .onDevice : .none
    }

    /// Apple's on-device model is there, switched on, downloaded, and speaks the person's language.
    static var onDeviceAvailable: Bool {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return false }
        return model.supportsLocale(Locale.current)
        #else
        return false
        #endif
    }

    // MARK: What the reply calls for

    /// What a finished reply calls for from the person.
    enum Kind: Equatable {
        /// It offers to do something and asks whether to ("Want me to book it?").
        case yesNo(String)
        /// It asks for something only the person knows ("When should I remind you?").
        case ask(String)
        /// It asks nothing: what to have it do or ask next.
        case next
    }

    /// The words a yes-or-no question starts with (English; any other language's question is
    /// answered as an `ask`, which suits a yes or no as well).
    private static let yesNoStarts: Set<String> = ["want", "would", "should", "shall", "do", "does", "did", "can", "could",
                                                   "is", "are", "will", "may", "ok", "okay", "need", "anything"]

    static func kind(of reply: String) -> Kind { kind(asked: endingQuestion(reply)) }

    /// What a reply calls for, from the question it ends with (`endingQuestion`), if any.
    private static func kind(asked: String?) -> Kind {
        guard let asked else { return .next }
        let first = asked.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        return yesNoStarts.contains(first) ? .yesNo(asked) : .ask(asked)
    }

    /// Whether a model should write suggestions for this reply: not after a short one that asks
    /// nothing ("Done, the lights are off."), where every suggestion tried was noise ("Are the
    /// lights dimmed?", 2026-11-14).
    static func worthSuggesting(_ reply: String) -> Bool {
        let shown = PlainText.display(reply)
        return worthSuggesting(kind: kind(asked: endingQuestion(shown: shown)), shown: shown)
    }

    private static func worthSuggesting(kind: Kind, shown: String) -> Bool { kind != .next || shown.count > 60 }

    /// What to do once a reply has finished (`Conversation.suggestFollowUps`): show the options
    /// it lists, have a model write suggestions for what it calls for, or nothing. The same as
    /// asking `listedOptions`, then `worthSuggesting` and `kind`, with the reply made plain text
    /// once: asked in turn they made it four times, some eighty regular-expression passes over a
    /// long reply on the main actor as it ended (2026-11-15).
    enum Decision: Equatable, Sendable {
        case options([String])
        case suggest(Kind)
        case nothing
    }

    static func decide(_ reply: String) -> Decision {
        let shown = PlainText.display(reply)
        let asked = endingQuestion(shown: shown)
        let kind = kind(asked: asked)
        let options = listedOptions(reply, asked: asked, kind: kind)
        if !options.isEmpty { return .options(options) }
        return worthSuggesting(kind: kind, shown: shown) ? .suggest(kind) : .nothing
    }

    /// `decide`, off the main actor.
    @concurrent static func deciding(_ reply: String) async -> Decision { decide(reply) }

    /// What the reply asks the person at its end, if it does: its last sentence, when that ends
    /// with a question mark.
    static func endingQuestion(_ reply: String) -> String? { endingQuestion(shown: PlainText.display(reply)) }

    /// `endingQuestion`, of a reply already made plain text (`PlainText.display`).
    private static func endingQuestion(shown: String) -> String? {
        let text = shown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasSuffix("?") || text.hasSuffix("？") else { return nil }
        let body = text.dropLast()
        let start = body.lastIndex(where: { ".!?。！？\n¿".contains($0) }).map { body.index(after: $0) } ?? body.startIndex
        let sentence = text[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.count >= 3 ? sentence : nil
    }

    /// The options a reply lists just before asking which: a numbered or bulleted list right
    /// above its closing question. Each option up to its first dash or colon ("Frontier 4:15 PM,
    /// $142"); none when any is too long to be a chip, or the question is a yes or no that isn't
    /// about picking one ("Here's what changed: … Should I commit?").
    static func listedOptions(_ reply: String) -> [String] {
        let asked = endingQuestion(reply)
        return listedOptions(reply, asked: asked, kind: kind(asked: asked))
    }

    /// `listedOptions`, given the reply's ending question and what it calls for.
    private static func listedOptions(_ reply: String, asked: String?, kind: Kind) -> [String] {
        guard let asked else { return [] }
        if case .yesNo = kind {
            let words = asked.lowercased()
            guard words.contains("which") || words.contains(" one") || words.contains(" or ") else { return [] }
        }
        // The lines above the question, back to the first that isn't an item.
        var lines = reply.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        lines.removeLast()   // the question
        var options: [String] = []
        for line in lines.reversed() {
            guard let marker = line.range(of: #"^(\d{1,2}[.)]|[-•*])\s+"#, options: .regularExpression) else { break }
            options.insert(String(line[marker.upperBound...]), at: 0)
        }
        guard (2 ... 6).contains(options.count) else { return [] }
        let labels = options.map(optionLabel)
        guard labels.allSatisfy({ (2 ... 40).contains($0.count) }) else { return [] }
        var seen = Set<String>()
        return labels.filter { seen.insert($0.lowercased()).inserted }.prefix(4).map { $0 }
    }

    /// An option as a chip: no Markdown, up to its first dash or colon, no full stop.
    private static func optionLabel(_ item: String) -> String {
        var label = item.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
        if let cut = label.range(of: #"\s+[—–-]\s+|:\s"#, options: .regularExpression) { label = String(label[..<cut.lowerBound]) }
        return label.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:"))
    }

    /// What the model is asked for, by what the reply calls for.
    static func request(for kind: Kind) -> String {
        switch kind {
        case .yesNo(let asked):
            return """
                The assistant asked: "\(asked.prefix(200))"
                Write three replies: the first says yes in a way that names what to do, the second \
                says no, the third asks for one change. For example, for "Want me to book the 7pm \
                table?": Yes, book it / No, not tonight / Make it 8pm instead
                """
        case .ask(let asked):
            return """
                The assistant asked: "\(asked.prefix(200))"
                Write three different answers the person might give, each the answer itself, not a \
                question. For example, for "What time should I set it for?": Tomorrow at 9am / \
                Tonight at 7 / In an hour
                """
        case .next:
            return """
                Write what the person might send next: two short questions about this topic that \
                the reply did not answer, and one short request for the assistant to do one more \
                thing related to it, starting with a verb.
                """
        }
    }

    // MARK: On this device

    #if canImport(FoundationModels)
    @Generable
    struct Replies {
        @Guide(description: "Three different short replies the person could send", .count(3))
        var replies: [String]
    }

    /// What to send next after a reply that asks nothing. Three fields rather than a list: asked
    /// for a list, the model wrote "Add it to my notes / Mark as done" after anything (2026-11-14).
    @Generable
    struct Next {
        @Guide(description: "A short question the person could ask the assistant about this topic that the reply did not answer")
        var question: String
        @Guide(description: "A different short question about this topic that the reply did not answer")
        var another: String
        @Guide(description: "A short request asking the assistant to do one more thing related to this reply, starting with a verb")
        var request: String
    }
    #endif

    /// The instructions both models get.
    private static let instructions = """
        You write the replies a person could tap to send next in a chat with their AI assistant. \
        Each one is the person talking to the assistant: short (two to six words), specific to this \
        chat, in the language the person wrote in. Never something the assistant would say, never a \
        question the reply already answered, never just thanks.
        """

    private static func chat(question: String, reply: String, limit: (Int, Int)) -> String {
        """
        The person wrote:
        \(question.prefix(limit.0))

        The assistant replied:
        \(reply.prefix(limit.1))
        """
    }

    /// The suggestions of Apple's on-device model, or none: it isn't available, its guardrails
    /// turned the chat down, or nothing usable came back.
    /// `kind`: what the reply calls for, when already known (`decide`).
    @concurrent static func suggestOnDevice(question: String, reply: String, kind: Kind? = nil) async -> [String] {
        #if canImport(FoundationModels)
        guard onDeviceAvailable else { return [] }
        let session = LanguageModelSession(instructions: instructions)
        let chat = chat(question: question, reply: reply, limit: (600, 2000)) + "\n\n"
        let options = GenerationOptions(temperature: 0.4, maximumResponseTokens: 90)
        let kind = kind ?? self.kind(of: reply)
        do {
            if kind == .next {
                let next = try await session.respond(to: chat + request(for: kind), generating: Next.self, options: options).content
                return tidy([next.question, next.another, next.request], reply: reply)
            }
            let answer = try await session.respond(to: chat + request(for: kind), generating: Replies.self, options: options)
            return tidy(answer.content.replies, reply: reply)
        } catch {
            return []
        }
        #else
        return []
        #endif
    }

    /// Suggestions as chips: one line each, short, not the reply's own last words, no two alike,
    /// three at most.
    static func tidy(_ replies: [String], reply: String) -> [String] {
        var seen = Set<String>()
        let replyEnd = reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return replies.compactMap { raw -> String? in
            var line = (raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"“”'-•*"))
            // A chip reads as a button: no full stop at its end ("Yes, book it."), "?" and "!" stay.
            if line.hasSuffix("."), !line.hasSuffix("..") { line.removeLast() }
            guard line.count >= 2, line.count <= 60, !replyEnd.hasSuffix(line.lowercased()),
                  seen.insert(line.lowercased()).inserted else { return nil }
            return line
        }
        .prefix(count)
        .map { $0 }
    }

    // MARK: On the fast lane

    /// The fast lane model's suggestions, or none: it isn't set up, didn't answer in time, or
    /// wrote nothing usable. `kind`: what the reply calls for, when already known (`decide`).
    /// Off the main actor: the prompt, the request and the answer are all the reply's size.
    @concurrent static func suggest(question: String, reply: String, baseURL: URL, apiKey: String?, model: String, kind: Kind? = nil) async -> [String] {
        struct Msg: Encodable { var role: String; var content: String }
        struct Body: Encodable {
            var model: String
            var messages: [Msg]
            var stream = false
            var max_tokens = 120
            var temperature = 0.5
            var chat_template_kwargs: [String: JSONValue]?
        }
        struct Response: Decodable {
            struct Choice: Decodable { struct Message: Decodable { var content: String? }; var message: Message? }
            var choices: [Choice]?
        }
        let prompt = chat(question: question, reply: reply, limit: (1200, 2400)) + "\n\n" + request(for: kind ?? self.kind(of: reply)) + """


            Write exactly \(count), one per line, with no numbering, bullets, quotes or other text.
            """
        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let body = Body(model: model, messages: [Msg(role: "system", content: instructions), Msg(role: "user", content: prompt)],
                        chat_template_kwargs: ChatCompletionsTransport.thinkingKwargs(effort: "none", baseURL: baseURL))
        guard let data = try? JSONEncoder().encode(body) else { return [] }
        request.httpBody = data
        guard let (response, http) = try? await URLSession.shared.data(for: request),
              let status = (http as? HTTPURLResponse)?.statusCode, (200 ..< 300).contains(status),
              let content = try? JSONDecoder().decode(Response.self, from: response).choices?.first?.message?.content else { return [] }
        return tidy(parse(content, questionsOnly: false), reply: reply)
    }

    /// One suggestion per line; numbering, bullets and quotes stripped; nothing that runs long,
    /// introduces a list ("Here are some ideas:"), or, with `questionsOnly`, isn't a question.
    static func parse(_ text: String, questionsOnly: Bool = true) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let first = line.first, first.isNumber || "-•*.)".contains(first) || first == " " { line.removeFirst() }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: " \"“”'"))
            let isQuestion = line.hasSuffix("?") || line.hasSuffix("？")
            guard line.count >= (questionsOnly ? 4 : 2), line.count <= 80, !line.hasSuffix(":"),
                  isQuestion || !questionsOnly, seen.insert(line.lowercased()).inserted else { return nil }
            return line
        }
        .prefix(count)
        .map { $0 }
    }
}
