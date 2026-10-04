import Foundation

/// Three things the user might ask next, written by the OpenAI-compatible model once a reply
/// has finished. A plain completion, not the agent: an extra prompt in the agent's session would
/// land in the conversation. So this needs the fast lane set up, whichever connection the
/// conversation itself is on.
nonisolated enum FollowUps {
    static let count = 3

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
