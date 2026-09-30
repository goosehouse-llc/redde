import Foundation

nonisolated struct SpokenPrefix: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var word: String
    var aliases: [String] = []
    var prefix: String
}

/// Voice-only routing. Apply to finalized voice and Siri transcripts, never to typed text.
nonisolated enum VoiceRouting {
    static func routed(_ transcript: String, rules: [SpokenPrefix]) -> String? {
        for rule in rules {
            let names = ([rule.word] + rule.aliases)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { NSRegularExpression.escapedPattern(for: $0) }
            guard !names.isEmpty, !rule.prefix.isEmpty else { continue }
            let pattern = #"^\s*(?:(?:hey|ok|okay)[\s,]+)?(?:"# + names.joined(separator: "|")
                + #")\b[\s,.:;!?-]*(.*)$"#
            guard let regex = try? Regex(pattern).ignoresCase().dotMatchesNewlines(),
                  let match = transcript.wholeMatch(of: regex),
                  match.output.count > 1,
                  let rest = match.output[1].substring?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rest.isEmpty
            else { continue }
            return rule.prefix + rest
        }
        return nil
    }

    static func contextualStrings(for rules: [SpokenPrefix]) -> [String] {
        rules.map(\.word).filter { !$0.isEmpty }
    }
}
