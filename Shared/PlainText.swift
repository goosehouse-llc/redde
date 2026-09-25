import Foundation

/// Markdown reduced to plain text, for places that can't render it: the synthesizer, Siri's
/// readout, notifications and widgets. One implementation for all of them.
nonisolated enum PlainText {
    /// Read aloud: decorations vanish, omitted blocks are named so the listener knows.
    static func spoken(_ text: String) -> String { apply(spokenRules, to: text) }

    /// Shown in a small text slot: bullets kept as dots, tables and images dropped.
    static func display(_ text: String) -> String { apply(displayRules, to: text) }

    private static func apply(_ rules: [(NSRegularExpression, String)], to text: String) -> String {
        var s = text
        for (regex, template) in rules {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func rule(_ pattern: String, _ template: String) -> (NSRegularExpression, String) {
        (try! NSRegularExpression(pattern: pattern), template)
    }

    // Compiled once; NSRegularExpression is immutable and Sendable.
    private static let spokenRules: [(NSRegularExpression, String)] = [
        rule(#"```[\s\S]*?```"#, "code block omitted"),
        rule(#"\$\$[\s\S]*?\$\$"#, "formula omitted"),
        // MEDIA:<path> file delivery and the "[IMAGE: /path]" phrasing: never read a server
        // path aloud — the picture arrives in the transcript (see resolveServeMedia).
        rule(ServeMedia.spokenImageTagPattern, "picture attached"),
        rule(ServeMedia.mediaTagPattern, "file attached"),
        rule(ServeMedia.imageTagPattern, "picture attached"),
        rule(#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),
        rule(#"`([^`]*)`"#, "$1"),
        rule(#"\*\*([^*]+)\*\*"#, "$1"),
        rule(#"\*([^*]+)\*"#, "$1"),
        rule(#"_([^_]+)_"#, "$1"),
        rule(#"~~([^~]+)~~"#, "$1"),
        rule(#"(?m)^#{1,6}\s*"#, ""),
        rule(#"(?m)^\s*[-*+]\s+"#, ""),
        rule(#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
        rule(#"\n{3,}"#, "\n\n"),
    ]

    private static let displayRules: [(NSRegularExpression, String)] = [
        rule(#"```[\s\S]*?```"#, "[code]"),
        rule(#"\$\$[\s\S]*?\$\$"#, "[formula]"),
        rule(ServeMedia.mediaTagPattern, ""),
        rule(ServeMedia.imageTagPattern, ""),
        rule(#"!\[[^\]]*\]\([^)]*\)"#, ""),
        rule(#"`([^`]*)`"#, "$1"),
        rule(#"\*\*([^*]+)\*\*"#, "$1"),
        rule(#"\*([^*]+)\*"#, "$1"),
        rule(#"~~([^~]+)~~"#, "$1"),
        rule(#"(?m)^#{1,6}\s*"#, ""),
        rule(#"(?m)^\s*[-*+]\s+"#, "• "),
        rule(#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
        rule(#"(?m)^\|.*\|$"#, ""),
        rule(#"\n{3,}"#, "\n\n"),
    ]
}
