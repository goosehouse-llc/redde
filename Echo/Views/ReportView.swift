import SwiftUI

/// An agent's report laid out (`ReportLayout`): the outcome on a tinted card, labelled lines as
/// callouts, bold-led points each on a card of its own. Text that doesn't read as a report shows as
/// `MarkdownView` does.
struct ReportView: View {
    let text: String
    var selectable = true
    private let parts: [ReportLayout.Part]?
    @Environment(\.theme) private var theme

    init(text: String, selectable: Bool = true) {
        self.text = text
        self.selectable = selectable
        parts = ReportLayout.parts(text)
    }

    var body: some View {
        if let parts {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    view(part)
                }
            }
            .modifier(Selectable(on: selectable))
        } else {
            MarkdownView(text: text, selectable: selectable)
        }
    }

    @ViewBuilder private func view(_ part: ReportLayout.Part) -> some View {
        switch part {
        case let .headline(label, text):
            VStack(alignment: .leading, spacing: 4) {
                if let label { tag(label, color: theme.accent) }
                inline(text).font(theme.headingFont(1))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.accent.opacity(0.13), in: .rect(cornerRadius: 14))
        case let .callout(label, text):
            let mark = Self.mark(for: label)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    if let mark { Image(systemName: mark.symbol).font(.caption.weight(.semibold)).foregroundStyle(mark.color) }
                    tag(label, color: .secondary)
                }
                inline(Self.capitalized(text)).font(theme.messageFont)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 14))
        case let .point(number, lead, body):
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let number {
                        Text(verbatim: number).font(.subheadline.weight(.bold)).monospacedDigit()
                    } else {
                        Circle().frame(width: 7, height: 7)
                    }
                }
                .foregroundStyle(theme.accent)
                .frame(width: 28, height: 28)
                .background(theme.accent.opacity(0.13), in: .circle)
                VStack(alignment: .leading, spacing: 6) {
                    inline(lead).font(theme.headingFont(2))
                    ForEach(Array(body.enumerated()), id: \.offset) { _, block in
                        MarkdownBlockView(block: block).equatable()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 14))
        case let .block(block):
            MarkdownBlockView(block: block).equatable()
        }
    }

    /// A symbol for the labels wrap-ups and reports use most; none for any other.
    static func mark(for label: String) -> (symbol: String, color: Color)? {
        let label = label.lowercased()
        func has(_ words: String...) -> Bool { words.contains { label.contains($0) } }
        if has("waiting", "needs you", "for you", "action", "to do", "todo") { return ("hand.raised.fill", .orange) }
        if has("done", "finished", "completed", "shipped", "merged") { return ("checkmark.circle.fill", .green) }
        if has("tomorrow", "next", "coming up", "later", "upcoming") { return ("sunrise.fill", .indigo) }
        if has("short answer", "bottom line", "tl;dr", "tldr", "summary", "verdict") { return ("text.quote", .secondary) }
        if has("warning", "risk", "heads-up", "heads up", "blocked", "problem", "issue") { return ("exclamationmark.triangle.fill", .yellow) }
        if has("health", "steps", "sleep") { return ("heart.fill", .pink) }
        return nil
    }

    /// "the vet booked" as "The vet booked", after a label.
    static func capitalized(_ text: String) -> String {
        // Not a name that starts small ("iPhone", "eBay").
        guard let first = text.first, first.isLowercase, !(text.dropFirst().first?.isUppercase ?? false) else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private func tag(_ label: String, color: Color) -> some View {
        Text(verbatim: label).font(.caption.weight(.semibold)).textCase(.uppercase).foregroundStyle(color)
    }

    private func inline(_ text: String) -> Text {
        MarkdownView.styledInline(text, codeFont: theme.codeFont, accent: theme.linkColor)
    }

    /// `.textSelection(.enabled)` when `on`, never switched (as `MarkdownView`'s).
    private struct Selectable: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            if on { content.textSelection(.enabled) } else { content }
        }
    }
}
