import Foundation

/// Recognizes an utterance that means "stop listening" so it never reaches the model.
/// Whole-utterance match only: "stop" ends the loop, "stop by the store" is a question.
/// The list here is English; a person's own phrases (Settings → Voice → Stop phrases) are heard
/// as well, which is how another language gets one, or a household its own word.
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

    /// The most phrases a person can add, and how long one can be: a list to say aloud, not a
    /// document.
    static let mostOwn = 20
    static let longestOwn = 60

    /// A person's phrases as they are compared: lowercased, without punctuation, no empties, no
    /// repeats, in the order given.
    static func own(_ phrases: [String]) -> [String] {
        var seen: Set<String> = []
        return phrases.map(normalize).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func matches(_ utterance: String, own: [String] = []) -> Bool {
        var text = normalize(utterance)
        let own = Self.own(own)
        let phrases = own.isEmpty ? Self.phrases : Self.phrases.union(own)
        // Longer than any phrase with its polite wrapping: a sentence, not a goodbye.
        let longest = max(7, (own.map { $0.split(separator: " ").count }.max() ?? 0) + 3)
        guard !text.isEmpty, text.split(separator: " ").count <= longest else { return false }
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

    /// Lowercased, accents and width set aside (a phrase typed "arrete" is the one heard as
    /// "Arrête"), punctuation dropped, single spaces.
    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
        let kept = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "'" || $0 == "-" }
        return String(String.UnicodeScalarView(kept))
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
