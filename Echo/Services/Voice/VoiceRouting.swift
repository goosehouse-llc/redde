import Foundation

nonisolated struct SpokenPrefix: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var word: String
    var aliases: [String] = []
    var prefix: String
    /// Switch the conversation to this model before sending (sticky: it stays there). Optional,
    /// so rules saved before this field existed decode as text-only rules.
    var model: String? = nil
    var provider: String? = nil

    /// A rule does something: rewrites the text, switches the model, or both.
    var isActive: Bool { !prefix.isEmpty || !(model ?? "").isEmpty }
}

/// Voice-only routing. Apply to finalized voice and Siri transcripts, never to typed text.
nonisolated enum VoiceRouting {
    /// What a matched rule asks for: the text to send (the word gone, the prefix in front) and,
    /// when the rule names one, the model to switch the conversation to first.
    struct Route: Equatable, Sendable {
        var text: String
        var model: String?
        var provider: String?
    }

    /// The text to send, or nil when no rule matches. Kept for callers that only rewrite.
    static func routed(_ transcript: String, rules: [SpokenPrefix]) -> String? {
        route(transcript, rules: rules)?.text
    }

    static func route(_ transcript: String, rules: [SpokenPrefix]) -> Route? {
        for rule in rules {
            let names = ([rule.word] + rule.aliases)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { NSRegularExpression.escapedPattern(for: $0) }
            guard !names.isEmpty, rule.isActive else { continue }
            let pattern = #"^\s*(?:(?:hey|ok|okay)[\s,]+)?(?:"# + names.joined(separator: "|")
                + #")\b[\s,.:;!?-]*(.*)$"#
            guard let regex = try? Regex(pattern).ignoresCase().dotMatchesNewlines(),
                  let match = transcript.wholeMatch(of: regex),
                  match.output.count > 1,
                  let rest = match.output[1].substring?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rest.isEmpty
            else { continue }
            let model = (rule.model ?? "").isEmpty ? nil : rule.model
            return Route(text: rule.prefix + rest, model: model, provider: model == nil ? nil : rule.provider?.nilIfEmpty)
        }
        return nil
    }

    static func contextualStrings(for rules: [SpokenPrefix]) -> [String] {
        rules.map(\.word).filter { !$0.isEmpty }
    }
}
