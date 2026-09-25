import Foundation

/// Recognizes an utterance that means "stop listening" so it never reaches the model.
/// Whole-utterance match only: "stop" ends the loop, "stop by the store" is a question.
nonisolated enum StopPhrase {
    static let phrases: Set<String> = [
        "stop", "stop listening", "stop hands free", "stop hands-free", "hands free off", "hands-free off",
        "that's all", "that is all", "that's it", "that's enough", "that will be all",
        "goodbye", "bye", "bye bye", "good night", "goodnight",
        "end conversation", "end the conversation", "end chat", "we're done", "i'm done", "done",
        "cancel", "never mind", "nevermind",
        "thank you", "thanks", "thank you hermes", "thanks hermes", "thank you redde", "thanks redde", "okay thanks", "ok thanks",
        "thanks that's all", "thank you that's all", "ok that's all", "okay that's all",
    ]

    // Longest first so "for now" is peeled before "now" leaves a dangling "for".
    private static let leadingFiller = ["all right", "alright", "hermes", "redde", "reddy", "okay", "echo", "hey", "and", "ok", "so"]
    private static let trailingFiller = ["thank you", "for now", "hermes", "please", "thanks", "redde", "reddy", "echo", "now"]

    static func matches(_ utterance: String) -> Bool {
        var text = normalize(utterance)
        guard !text.isEmpty, text.split(separator: " ").count <= 7 else { return false }
        if phrases.contains(text) { return true }
        // Peel polite wrappers: "okay redde, that's all, thanks" → "that's all".
        var changed = true
        while changed {
            changed = false
            for filler in leadingFiller where text.hasPrefix(filler + " ") {
                text = String(text.dropFirst(filler.count + 1)); changed = true
            }
            for filler in trailingFiller where text.hasSuffix(" " + filler) {
                text = String(text.dropLast(filler.count + 1)); changed = true
            }
            if phrases.contains(text) { return true }
        }
        return false
    }

    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
            .replacingOccurrences(of: "’", with: "'")
        let kept = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "'" || $0 == "-" }
        return String(String.UnicodeScalarView(kept))
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
