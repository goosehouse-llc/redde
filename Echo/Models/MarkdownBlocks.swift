import Foundation

/// The subset of Markdown that chat replies actually use, parsed into blocks. Inline styling
/// (bold, italic, code spans, links) is left to AttributedString at render time.
nonisolated indirect enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(items: [ListItem])
    case code(language: String?, text: String)
    /// Quotes hold any blocks: paragraphs, lists, code, nested quotes.
    case quote([MarkdownBlock])
    case rule
    case table(header: [String], rows: [[String]], alignments: [ColumnAlignment])
    /// A paragraph that is only an image: `![alt](url)`.
    case image(alt: String, url: String)
    /// Display math: `$$ … $$` or `\[ … \]`, LaTeX source without the delimiters.
    case math(String)

    nonisolated enum ColumnAlignment: Equatable, Sendable { case leading, center, trailing }

    nonisolated struct ListItem: Equatable, Sendable {
        var ordered: Bool
        var marker: String      // "•" or "1."
        var text: String
        var indent: Int
        /// Task list state: nil for a plain item, true/false for `[x]` / `[ ]`.
        var checked: Bool? = nil
    }
}

nonisolated enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            // Lines join with a space, except after a hard break (two trailing spaces, a
            // backslash, or <br>), which keeps the newline.
            var text = ""
            for (n, raw) in paragraph.enumerated() {
                var line = raw.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n").replacingOccurrences(of: "<br />", with: "\n")
                var hard = false
                if line.hasSuffix("  ") { hard = true; line = line.trimmingCharacters(in: .whitespaces) }
                else if line.hasSuffix("\\") { hard = true; line.removeLast() }
                text += n == 0 ? line : (text.hasSuffix("\n") ? line : " " + line)
                if hard { text += "\n" }
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if let code = loneInlineCode(text) { blocks.append(code) }
                else if let image = parseImage(text) { blocks.append(image) }
                else { blocks.append(contentsOf: splitEmbeddedImages(text)) }
            }
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code (an unterminated fence, mid-stream, runs to the end).
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i]); i += 1
                }
                i += 1
                blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            // Display math. Single line `$$ x $$`, or an opening `$$` / `\[` closed on a later line.
            if let math = parseMathStart(trimmed) {
                flushParagraph()
                if let inlineBody = math.closedBody {
                    blocks.append(.math(inlineBody)); i += 1; continue
                }
                var body: [String] = math.firstLine.isEmpty ? [] : [math.firstLine]
                i += 1
                // An unterminated block mid-stream renders what has arrived.
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if let end = l.range(of: math.closer) {
                        let before = String(l[..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
                        if !before.isEmpty { body.append(before) }
                        i += 1; break
                    }
                    body.append(l); i += 1
                }
                blocks.append(.math(body.joined(separator: "\n")))
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph(); blocks.append(heading); i += 1; continue
            }

            // Setext heading: a single paragraph line underlined with === or ---.
            if paragraph.count == 1, isSetextUnderline(trimmed) {
                let text = paragraph[0].trimmingCharacters(in: .whitespaces)
                paragraph = []
                blocks.append(.heading(level: trimmed.hasPrefix("=") ? 1 : 2, text: text))
                i += 1; continue
            }

            if isRule(trimmed) { flushParagraph(); blocks.append(.rule); i += 1; continue }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var body = String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst())
                    if body.hasPrefix(" ") { body.removeFirst() }
                    quote.append(body)
                    i += 1
                }
                blocks.append(.quote(parse(quote.joined(separator: "\n"))))
                continue
            }

            if let item = parseListItem(line) {
                flushParagraph()
                var items: [MarkdownBlock.ListItem] = [item]
                i += 1
                while i < lines.count {
                    if let next = parseListItem(lines[i]) { items.append(next); i += 1 }
                    else if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, lines[i].hasPrefix("  "), var last = items.popLast() {
                        // Continuation line of the previous item.
                        last.text += " " + lines[i].trimmingCharacters(in: .whitespaces)
                        items.append(last); i += 1
                    } else { break }
                }
                blocks.append(.list(items: items))
                continue
            }

            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableDivider(lines[i + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                let alignments = cells(lines[i + 1].trimmingCharacters(in: .whitespaces)).map { spec -> MarkdownBlock.ColumnAlignment in
                    let l = spec.hasPrefix(":"), r = spec.hasSuffix(":")
                    return l && r ? .center : r ? .trailing : .leading
                }
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var row = cells(lines[i].trimmingCharacters(in: .whitespaces))
                    while row.count < header.count { row.append("") }
                    rows.append(Array(row.prefix(header.count))); i += 1
                }
                blocks.append(.table(header: header, rows: rows, alignments: alignments))
                continue
            }

            paragraph.append(line.trimmingCharacters(in: .whitespaces).isEmpty ? "" : String(line.drop { $0 == " " }))
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 { level += 1; idx = line.index(after: idx) }
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
        return .heading(level: level, text: String(line[idx...]).trimmingCharacters(in: .whitespaces))
    }

    private struct MathStart { var closer: String; var firstLine: String; var closedBody: String? }

    private static func parseMathStart(_ line: String) -> MathStart? {
        for (opener, closer) in [("$$", "$$"), ("\\[", "\\]")] where line.hasPrefix(opener) {
            let rest = String(line.dropFirst(opener.count))
            if let end = rest.range(of: closer, options: .backwards), end.upperBound == rest.endIndex, !rest.isEmpty {
                let body = String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
                if body.isEmpty { return nil }   // bare "$$$$"
                return MathStart(closer: closer, firstLine: "", closedBody: body)
            }
            return MathStart(closer: closer, firstLine: rest.trimmingCharacters(in: .whitespaces), closedBody: nil)
        }
        return nil
    }

    private static func isSetextUnderline(_ line: String) -> Bool {
        line.count >= 3 && (Set(line) == ["="] || Set(line) == ["-"])
    }

    /// A paragraph that is exactly one inline code span — how models often present a runnable
    /// command (`ssh host "…"`) — promotes to a code block, so it gets the copyable code window
    /// instead of styled prose. Inline code *within* a sentence stays inline.
    private static func loneInlineCode(_ text: String) -> MarkdownBlock? {
        guard text.count > 2, text.hasPrefix("`"), text.hasSuffix("`"), !text.hasPrefix("```") else { return nil }
        let inner = String(text.dropFirst().dropLast())
        guard !inner.isEmpty, !inner.contains("`"), !inner.contains("\n") else { return nil }
        return .code(language: nil, text: inner)
    }

    /// `![alt](url)` on its own, optionally wrapped in a link.
    private static func parseImage(_ text: String) -> MarkdownBlock? {
        var t = text
        if t.hasPrefix("[") && t.hasSuffix(")"), let close = t.range(of: "](", options: .backwards) {
            t = String(t[t.index(after: t.startIndex)..<close.lowerBound])   // unwrap [![alt](img)](link)
        }
        guard t.hasPrefix("!["), t.hasSuffix(")"), let mid = t.range(of: "](") else { return nil }
        let alt = String(t[t.index(t.startIndex, offsetBy: 2)..<mid.lowerBound])
        var url = String(t[mid.upperBound..<t.index(before: t.endIndex)])
        guard !url.contains("![") else { return nil }   // a second image: not one standalone image
        if let space = url.firstIndex(of: " ") { url = String(url[..<space]) }   // drop a title
        guard !url.isEmpty, !url.contains(" ") else { return nil }
        return .image(alt: alt, url: url)
    }

    /// A paragraph with `![alt](url)` mid-text — how the API server inlines a picture the agent
    /// sends ("Here it is ![image](data:…)"). Splits into paragraph and image blocks so the
    /// picture renders instead of showing as raw markup.
    private static func splitEmbeddedImages(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var rest = Substring(text)
        func flushText(_ t: Substring) {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { blocks.append(.paragraph(trimmed)) }
        }
        while let start = rest.range(of: "![") {
            guard let mid = rest.range(of: "](", range: start.upperBound..<rest.endIndex),
                  let close = MarkdownURL.closingParen(of: rest, from: mid.upperBound) else { break }
            let afterClose = rest.index(after: close)
            var url = String(rest[mid.upperBound..<close])
            if let space = url.firstIndex(of: " ") { url = String(url[..<space]) }   // drop a title
            guard !url.isEmpty, !url.contains(" ") else {
                flushText(rest[..<afterClose])
                rest = rest[afterClose...]
                continue
            }
            flushText(rest[..<start.lowerBound])
            blocks.append(.image(alt: String(rest[start.upperBound..<mid.lowerBound]), url: url))
            rest = rest[afterClose...]
        }
        flushText(rest)
        return blocks.isEmpty ? [.paragraph(text)] : blocks
    }

    private static func isRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        return stripped.count >= 3 && (Set(stripped) == ["-"] || Set(stripped) == ["*"] || Set(stripped) == ["_"])
    }

    private static func parseListItem(_ line: String) -> MarkdownBlock.ListItem? {
        let leading = line.prefix { $0 == " " }.count
        let body = line.dropFirst(leading)
        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
            var text = String(body.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            var checked: Bool?
            if text.hasPrefix("[ ] ") || text == "[ ]" { checked = false; text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            else if text.lowercased().hasPrefix("[x] ") || text.lowercased() == "[x]" { checked = true; text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            return .init(ordered: false, marker: "•", text: text, indent: leading / 2, checked: checked)
        }
        // "1. " / "12) "
        var digits = ""
        var idx = body.startIndex
        while idx < body.endIndex, body[idx].isNumber { digits.append(body[idx]); idx = body.index(after: idx) }
        guard !digits.isEmpty, idx < body.endIndex, body[idx] == "." || body[idx] == ")" else { return nil }
        let afterMarker = body.index(after: idx)
        guard afterMarker < body.endIndex, body[afterMarker] == " " else { return nil }
        return .init(ordered: true, marker: "\(digits).", text: String(body[afterMarker...]).trimmingCharacters(in: .whitespaces), indent: leading / 2)
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|") else { return false }
        let inner = t.replacingOccurrences(of: "|", with: "").replacingOccurrences(of: " ", with: "")
        return !inner.isEmpty && inner.allSatisfy { $0 == "-" || $0 == ":" }
    }

    private static func cells(_ line: String) -> [String] {
        var t = line
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
