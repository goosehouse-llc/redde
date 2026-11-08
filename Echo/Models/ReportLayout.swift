import Foundation

/// An agent's report read as parts to lay out (asked 2026-11-08 of a Strata watch's answer: "Can we
/// make this more visually appealing? It looks like a wall of text"). Reports come as Markdown
/// paragraphs with bold leads: a line all in bold is the outcome ("**Status: No release yet.**"),
/// "**The short answer:** …" a callout, and a list whose items open in bold ("1. **A full port
/// exists.** Issue #3932 …") points to set apart. Text with fewer than two of those reads as it
/// was written (`parts` is nil), so a short answer stays plain. The outcome comes first.
nonisolated enum ReportLayout {
    enum Part: Equatable, Sendable {
        /// A paragraph all in bold: the outcome, with its label when it opens with one ("Status").
        case headline(label: String?, text: String)
        /// A paragraph that opens with a bold label and a colon.
        case callout(label: String, text: String)
        /// A list item that opens in bold: its number ("1", nil for a bullet), the bold words, and
        /// what follows them (the rest of its line, its own items).
        case point(number: String?, lead: String, body: [MarkdownBlock])
        case block(MarkdownBlock)
    }

    /// The text as parts, or nil when it doesn't read as a report.
    static func parts(_ text: String) -> [Part]? {
        parts(MarkdownParser.parse(text))
    }

    static func parts(_ blocks: [MarkdownBlock]) -> [Part]? {
        var parts: [Part] = []
        for block in blocks {
            switch block {
            case let .paragraph(text):
                parts.append(paragraph(text))
            case let .list(items):
                // Items under the point before, set apart from it by a blank line.
                if let low = items.map(\.indent).min(), low > 0, case let .point(number, lead, body)? = parts.last {
                    parts[parts.count - 1] = .point(number: number, lead: lead, body: body + [.list(items: outdented(items, by: 1))])
                    continue
                }
                parts += list(items)
            default:
                parts.append(.block(block))
            }
        }
        let laidOut = parts.filter { if case .block = $0 { false } else { true } }.count
        guard laidOut >= 2 else { return nil }
        // The outcome first: a headline under a paragraph or two of lead-in goes above them.
        if let h = parts.firstIndex(where: { if case .headline = $0 { true } else { false } }), h > 0, h <= 2,
           parts[..<h].allSatisfy({ if case .block(.paragraph) = $0 { true } else { false } }) {
            parts.insert(parts.remove(at: h), at: 0)
        }
        return parts
    }

    // MARK: Paragraphs

    private static func paragraph(_ text: String) -> Part {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let whole = wholeBold(trimmed) {
            // A short bold line with no sentence in it is a section's name ("**What changed**").
            if whole.count <= 50, !whole.hasSuffix("."), !whole.contains(": ") {
                return .block(.heading(level: 3, text: whole))
            }
            if let (label, rest) = labelled(whole) { return .headline(label: label, text: rest) }
            return .headline(label: nil, text: whole)
        }
        if let (label, rest) = boldLabel(trimmed) { return .callout(label: label, text: rest) }
        return .block(.paragraph(text))
    }

    /// "**…**" with no other bold inside: what is between.
    static func wholeBold(_ text: String) -> String? {
        guard text.count > 4, text.hasPrefix("**"), text.hasSuffix("**") else { return nil }
        let inner = String(text.dropFirst(2).dropLast(2))
        guard !inner.contains("**"), !inner.isEmpty else { return nil }
        return inner.trimmingCharacters(in: .whitespaces)
    }

    /// "Status: No release yet": a label of a few words before a colon, and the rest.
    private static func labelled(_ text: String) -> (String, String)? {
        guard let colon = text.range(of: ": ") else { return nil }
        let label = text[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
        let rest = text[colon.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.count <= 32, label.split(separator: " ").count <= 4, !rest.isEmpty else { return nil }
        return (label, rest)
    }

    /// "**The short answer:** rest" or "**The short answer**: rest".
    private static func boldLabel(_ text: String) -> (String, String)? {
        guard text.hasPrefix("**"), let close = text.range(of: "**", range: text.index(text.startIndex, offsetBy: 2) ..< text.endIndex) else { return nil }
        var label = String(text[text.index(text.startIndex, offsetBy: 2) ..< close.lowerBound]).trimmingCharacters(in: .whitespaces)
        var rest = String(text[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        if label.hasSuffix(":") || label.hasSuffix("—") || label.hasSuffix("–") {
            label.removeLast()
        } else if let mark = [":", "—", "–", "- "].first(where: rest.hasPrefix) {
            // "**Done** — the vet booked" as well as "**Done:** the vet booked".
            rest.removeFirst(mark.count)
        } else {
            return nil
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        label = label.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.count <= 40, label.split(separator: " ").count <= 5, !rest.isEmpty else { return nil }
        return (label, rest)
    }

    // MARK: Lists

    /// A list whose every top-level item opens in bold as points, each with the items under it;
    /// any other list as it is.
    private static func list(_ items: [MarkdownBlock.ListItem]) -> [Part] {
        guard let top = items.map(\.indent).min() else { return [] }
        var groups: [(item: MarkdownBlock.ListItem, under: [MarkdownBlock.ListItem])] = []
        for item in items {
            if item.indent == top || groups.isEmpty { groups.append((item, [])) } else { groups[groups.count - 1].under.append(item) }
        }
        let leads = groups.map { boldLead($0.item.text) }
        guard leads.allSatisfy({ $0 != nil }), groups.allSatisfy({ $0.item.checked == nil }) else { return [.block(.list(items: items))] }
        return zip(groups, leads).map { group, lead in
            let (bold, rest) = lead!
            var body: [MarkdownBlock] = []
            if !rest.isEmpty { body.append(.paragraph(rest)) }
            if !group.under.isEmpty { body.append(.list(items: outdented(group.under, by: top + 1))) }
            let number = group.item.ordered ? String(group.item.marker.dropLast()) : nil
            return .point(number: number, lead: bold, body: body)
        }
    }

    /// "**A full port exists.** Issue #3932 is open": the bold words (without a closing colon),
    /// and the rest.
    private static func boldLead(_ text: String) -> (String, String)? {
        guard text.hasPrefix("**"), let close = text.range(of: "**", range: text.index(text.startIndex, offsetBy: 2) ..< text.endIndex) else { return nil }
        var lead = String(text[text.index(text.startIndex, offsetBy: 2) ..< close.lowerBound]).trimmingCharacters(in: .whitespaces)
        var rest = String(text[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix(":") || rest.hasPrefix("—") || rest.hasPrefix("–") || rest.hasPrefix("- ") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if lead.hasSuffix(":") { lead.removeLast() }
        guard !lead.isEmpty, lead.count <= 200 else { return nil }
        return (lead, rest)
    }

    private static func outdented(_ items: [MarkdownBlock.ListItem], by levels: Int) -> [MarkdownBlock.ListItem] {
        items.map { var item = $0; item.indent = max(0, item.indent - levels); return item }
    }
}
