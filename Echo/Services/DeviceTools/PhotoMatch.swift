import Foundation
import NaturalLanguage

/// What the phone has made out in one picture by looking at it (`PhotoLook`): the things in it,
/// each with how sure, and the text it could read.
nonisolated struct PhotoSeen: Codable, Equatable, Sendable {
    /// "waterfall": 0.85. The names are the recognizer's own, in English: "blue_sky".
    var labels: [String: Double] = [:]
    var text = ""

    /// The things it is fairly sure of, most sure first, as words: for telling the agent.
    var shows: [String] {
        let sorted = labels.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        let sure = sorted.filter { $0.value >= 0.3 }
        return (sure.isEmpty ? Array(sorted.prefix(2)) : Array(sure.prefix(6))).map { $0.key.replacingOccurrences(of: "_", with: " ") }
    }
}

/// A question about pictures in plain words ("bowling scoreboard", "my dog at the beach"), and
/// how well a picture answers it.
///
/// The words are matched against what the person wrote on the picture in Photos (its caption
/// and keywords), what the phone made out in it, and the text read in it. A word also counts
/// when a near relation of it is there: "puppy" finds a picture of a dog, less surely than
/// "dog" does. That nearness comes from the word embedding iOS carries, so it is English; text
/// in a picture is matched as written, in any language.
nonisolated struct PhotoQuery {
    /// What is being looked for, one word each.
    let terms: [String]
    private let near: NLEmbedding?
    /// How much a word found on a picture counts for a term, once worked out: the same few
    /// words come up on picture after picture.
    private let memo = Memo()
    private nonisolated final class Memo { var worth: [String: [String: Double]] = [:] }

    /// Words that ask for nothing: the small ones, and the ones every picture answers.
    static let empty: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "to", "by", "for", "from", "with", "and", "or", "that", "this", "these", "those",
        "is", "are", "was", "were", "be", "it", "its", "my", "me", "our", "we", "us", "i", "you", "your", "there", "where", "when",
        "which", "who", "what", "one", "ones", "some", "any", "all", "show", "shows", "showing", "find", "get", "taken", "took",
        "about", "like", "has", "have", "had", "he", "she", "him", "her", "his", "they", "them", "their", "not", "no", "see",
        "look", "looking", "recent", "latest", "newest", "last", "most", "very", "just", "also", "please",
        "photo", "photos", "picture", "pictures", "pic", "pics", "image", "images", "shot", "shots", "snap",
    ]

    init(_ text: String, near: NLEmbedding? = NLEmbedding.wordEmbedding(for: .english)) throws {
        var seen: Set<String> = []
        terms = Self.words(text).filter { !Self.empty.contains($0) && seen.insert(Self.root($0)).inserted }
        guard !terms.isEmpty else {
            throw DeviceToolError("\"query\" has nothing to look for: give a few plain words for what the picture shows or says, like \"bowling scoreboard\".")
        }
        self.near = near
    }

    /// The words in a piece of text, in small letters: "Dad's 70th, blue_sky" gives dad, 70th,
    /// blue, sky.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { $0.count > 1 }
    }

    /// A word without its plural: enough to make "scoreboards" and "scoreboard" one word, and
    /// applied to both sides, so a root that isn't a word ("tenni") does no harm.
    static func root(_ word: String) -> String {
        if word.count > 4, word.hasSuffix("ies") { return word.dropLast(3) + "y" }
        if word.count > 4, ["ches", "shes", "sses", "xes", "zes"].contains(where: word.hasSuffix) { return String(word.dropLast(2)) }
        if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    /// How much finding `word` on a picture counts for `term`: all of it for the word itself,
    /// part for a near relation (only where `related` is asked for), nothing otherwise.
    private func worth(of word: String, for term: String, related: Bool) -> Double {
        if Self.root(word) == Self.root(term) { return 1 }
        guard related, let near else { return 0 }
        if let known = memo.worth[term]?[word] { return known }
        // The embedding's cosine distance: "puppy" to "dog" is 0.79, "pond" to "lake" 0.87,
        // "sunset" to "beach" 0.93, "dog" to "car" 1.21.
        let distance = near.distance(between: term, and: word, distanceType: .cosine)
        let value = distance < 0.82 ? 0.6 : distance < 0.92 ? 0.35 : 0
        memo.worth[term, default: [:]][word] = value
        return value
    }

    /// How well a picture answers: between nothing and 1, and which of the words it answers.
    /// Nil when it answers none of them.
    func match(caption: String? = nil, keywords: [String] = [], seen: PhotoSeen? = nil) -> (score: Double, matched: [String])? {
        // The person's own words count in full; what the phone made out counts by how sure it
        // was; text read in the picture counts as written, with no relations.
        var written = Self.words(caption ?? "")
        for keyword in keywords { written += Self.words(keyword) }
        let labels = (seen?.labels ?? [:]).flatMap { name, sure in
            Self.words(name).filter { $0 != "other" && $0 != "regular" }.map { (word: $0, weight: 0.5 + 0.5 * min(max(sure, 0), 1)) }
        }
        let read = Set(Self.words(seen?.text ?? "").map(Self.root))
        var total = 0.0
        var matched: [String] = []
        for term in terms {
            var best = read.contains(Self.root(term)) ? 0.9 : 0
            for word in written where best < 1 { best = max(best, worth(of: word, for: term, related: true)) }
            for label in labels where best < 1 { best = max(best, label.weight * worth(of: label.word, for: term, related: true)) }
            if best >= 0.3 {
                total += best
                matched.append(term)
            }
        }
        return matched.isEmpty ? nil : (total / Double(terms.count), matched)
    }
}
