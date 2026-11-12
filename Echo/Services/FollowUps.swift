import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Three things the person might send next, once a reply has finished: answers to what the agent
/// asked, or follow-up questions. Written on the device by Apple's own model where it can
/// (Apple Intelligence on; 2026-11-11, "suggested replies" from the Conduit gap list), so
/// nothing leaves the phone and it works on both connections; else by the model on the
/// OpenAI-compatible connection (the fast lane), when that's set up. Never the agent: an extra
/// prompt in the agent's session would land in the chat.
nonisolated enum FollowUps {
    static let count = 3

    /// Where suggestions come from on this device.
    enum Source: Equatable { case onDevice, fastLane, none }

    static func source(fastLaneSet: Bool) -> Source {
        if onDeviceAvailable { return .onDevice }
        return fastLaneSet ? .fastLane : .none
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

    #if canImport(FoundationModels)
    @Generable
    struct Answers {
        @Guide(description: "Three different short answers the person could give to the assistant's question, in the person's voice: for example one yes, one no, one asking for a change", .count(3))
        var replies: [String]
    }

    @Generable
    struct Questions {
        @Guide(description: "Three short questions the person could type to the assistant next, each ending with a question mark and about something the reply didn't already say, such as: How long does it keep?", .count(3))
        var replies: [String]
    }
    #endif

    /// What the reply asks the person at its end, if it does: its last sentence, when that ends
    /// with a question mark.
    static func endingQuestion(_ reply: String) -> String? {
        let text = PlainText.display(reply).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasSuffix("?") || text.hasSuffix("？") else { return nil }
        let body = text.dropLast()
        let start = body.lastIndex(where: { ".!?。！？\n".contains($0) }).map { body.index(after: $0) } ?? body.startIndex
        let sentence = text[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.count >= 3 ? sentence : nil
    }

    /// The suggestions of Apple's on-device model, or none: it isn't available, its guardrails
    /// turned the chat down, or nothing usable came back. A reply that ends by asking gets
    /// answers to that; any other, questions to ask next. One instruction for both was answered
    /// with questions alone, some of them in the assistant's voice (tried 2026-11-11).
    @concurrent static func suggestOnDevice(question: String, reply: String) async -> [String] {
        #if canImport(FoundationModels)
        guard onDeviceAvailable else { return [] }
        let session = LanguageModelSession(instructions: """
            You write what a person could send next in a chat with their AI assistant. Every \
            suggestion is the person speaking to the assistant, under eight words, in the language \
            the person wrote in. Nothing the assistant would say, no thanks or greetings alone.
            """)
        let chat = """
            The person wrote:
            \(question.prefix(600))

            The assistant replied:
            \(reply.prefix(2000))
            """
        let options = GenerationOptions(temperature: 0.5, maximumResponseTokens: 90)
        do {
            if let asked = endingQuestion(reply) {
                let answer = try await session.respond(to: chat + "\n\nThe assistant asked the person: \"\(asked.prefix(200))\" Suggest three answers to it.",
                                                       generating: Answers.self, options: options)
                return tidy(answer.content.replies, reply: reply)
            }
            let answer = try await session.respond(to: chat + "\n\nSuggest three questions the person could ask next.",
                                                   generating: Questions.self, options: options)
            return tidy(answer.content.replies, reply: reply)
        } catch {
            return []
        }
        #else
        return []
        #endif
    }

    /// The on-device model's suggestions as chips: one line each, short, not the reply's own last
    /// words, no two alike, three at most.
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

    /// The suggestions, or none: the fast lane isn't set up, the model didn't answer in time,
    /// or what it wrote wasn't questions.
    static func suggest(question: String, reply: String, baseURL: URL, apiKey: String?, model: String) async -> [String] {
        struct Msg: Encodable { var role: String; var content: String }
        struct Body: Encodable {
            var model: String
            var messages: [Msg]
            var stream = false
            var max_tokens = 120
            var temperature = 0.7
            var chat_template_kwargs: [String: JSONValue]?
        }
        struct Response: Decodable {
            struct Choice: Decodable { struct Message: Decodable { var content: String? }; var message: Message? }
            var choices: [Choice]?
        }
        let prompt = """
            The user asked:
            \(question.prefix(1200))

            The assistant replied:
            \(reply.prefix(2400))

            Write \(count) short follow-up questions the user might ask next, in the user's language. \
            Under eight words each, one per line, no numbering, bullets or other text.
            """
        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let body = Body(model: model, messages: [Msg(role: "user", content: prompt)],
                        chat_template_kwargs: ChatCompletionsTransport.thinkingKwargs(effort: "none", baseURL: baseURL))
        guard let data = try? JSONEncoder().encode(body) else { return [] }
        request.httpBody = data
        guard let (response, http) = try? await URLSession.shared.data(for: request),
              let status = (http as? HTTPURLResponse)?.statusCode, (200 ..< 300).contains(status),
              let content = try? JSONDecoder().decode(Response.self, from: response).choices?.first?.message?.content else { return [] }
        return parse(content)
    }

    /// One question per line; numbering, bullets and quotes stripped; nothing that isn't a
    /// question or runs long.
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let first = line.first, first.isNumber || "-•*.)".contains(first) || first == " " { line.removeFirst() }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: " \"“”'"))
            guard line.count >= 4, line.count <= 80, line.hasSuffix("?") || line.hasSuffix("？"),
                  seen.insert(line.lowercased()).inserted else { return nil }
            return line
        }
        .prefix(count)
        .map { $0 }
    }
}
