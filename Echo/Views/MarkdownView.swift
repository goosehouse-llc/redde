import SwiftUI

/// Renders a reply's Markdown with the current theme's type. Re-parses on every change, which is
/// cheap at chat sizes and keeps streaming replies rendering as they arrive.
struct MarkdownView: View {
    let text: String
    /// While streaming, the trailing diagram/math block stays a plain code block until its
    /// fence closes, so a WebView isn't reloaded on every token.
    var isLive = false
    /// Parsed once per text change, not on every body evaluation: a streaming reply re-rendering
    /// at 20 fps must not re-parse the whole document each time.
    @State private var blocks: [MarkdownBlock] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                MarkdownBlockView(block: block, trailing: isLive && i == blocks.count - 1).equatable()
            }
        }
        .textSelection(.enabled)
        .onChange(of: text, initial: true) { blocks = MarkdownParser.parse(text) }
    }

    /// Bold, italic, strikethrough, code spans and links via Foundation's Markdown parser, then
    /// styled: code spans in the theme's mono face on a tint, links in the accent colour.
    nonisolated static func styledInline(_ text: String, codeFont: Font, accent: Color) -> Text {
        guard var attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return Text(text)
        }
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = codeFont
                attributed[run.range].backgroundColor = accent.opacity(0.12)
            }
            if run.link != nil {
                attributed[run.range].foregroundColor = accent
                attributed[run.range].underlineStyle = .single
            }
        }
        return Text(attributed)
    }
}

/// One block of a reply. A named view rather than an opaque one so block quotes can nest it.
/// Equatable so a streaming reply re-styles only the block that changed: every inline run is a
/// full Markdown parse, and a table has one per cell.
struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    /// The last block of a reply that is still streaming.
    var trailing = false
    @Environment(\.theme) private var theme

    nonisolated static func == (a: Self, b: Self) -> Bool { a.block == b.block && a.trailing == b.trailing }

    var body: some View {
        switch block {
        case let .heading(level, text):
            inline(text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 4 : 2)
        case let .paragraph(text):
            inline(text).font(theme.messageFont)
        case let .list(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let checked = item.checked {
                            Image(systemName: checked ? "checkmark.square.fill" : "square")
                                .foregroundStyle(checked ? theme.checkboxColor : .secondary)
                                .font(theme.messageFont)
                                .accessibilityLabel(checked ? "Done" : "Not done")
                        } else {
                            Text(item.marker)
                                .font(theme.messageFont.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: item.ordered ? 22 : 10, alignment: .trailing)
                        }
                        inline(item.text).font(theme.messageFont)
                            .strikethrough(item.checked == true, color: .secondary)
                            .foregroundStyle(item.checked == true ? .secondary : .primary)
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
        case let .code(language, code):
            if language?.lowercased() == "mermaid", !trailing {
                MermaidBlock(source: code)
            } else {
                CodeBlock(language: language, code: code, live: trailing)
            }
        case let .math(source):
            if trailing {
                CodeBlock(language: "math", code: source)
            } else {
                MathBlock(source: source)
            }
        case let .quote(blocks):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(theme.quoteBarColor).frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in MarkdownBlockView(block: b).equatable() }
                }
                .foregroundStyle(.secondary)
            }
        case .rule:
            Divider().padding(.vertical, 2)
        case let .table(header, rows, alignments):
            MarkdownTable(header: header, rows: rows, alignments: alignments)
        case let .image(alt, url):
            MarkdownImage(alt: alt, url: url)
        }
    }

    private func headingFont(_ level: Int) -> Font { theme.headingFont(level) }

    private func inline(_ text: String) -> Text {
        MarkdownView.styledInline(text, codeFont: theme.codeFont, accent: theme.linkColor)
    }
}

/// An image the model referenced: remote URLs and data: URIs both load through URLSession.
/// Tap for a zoomable full-screen view; long-press to copy the link.
struct MarkdownImage: View {
    let alt: String
    let url: String
    @State private var showViewer = false
    @State private var loaded: UIImage?
    /// Remote images fetch only on request: the app promises to talk to your servers alone,
    /// and an auto-loaded <img> is a tracking pixel. Inline data URIs load at once.
    @State private var wantsRemote = false
    private var isRemote: Bool { !url.hasPrefix("data:") }
    private static let maxBytes = 8 * 1024 * 1024
    private struct LoadKey: Equatable { let url: String; let wantsRemote: Bool }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let loaded {
                    Image(uiImage: loaded).resizable().scaledToFit()
                } else if isRemote, !wantsRemote {
                    Button { wantsRemote = true } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "photo").font(.title2)
                            Text("Load image from \(URL(string: url)?.host() ?? "the web")").font(.caption)
                        }
                        .frame(maxWidth: .infinity).frame(height: 120)
                        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06))
                        ProgressView()
                    }
                    .frame(height: 120)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 320, alignment: .leading)
            .clipShape(.rect(cornerRadius: 10))
            .contentShape(.rect)
            .onTapGesture { if loaded != nil { showViewer = true } }
            .contextMenu {
                Button("Copy image link", systemImage: "link") { UIPasteboard.general.string = url }
                if let loaded { Button("Copy image", systemImage: "doc.on.doc") { UIPasteboard.general.image = loaded } }
            }
            .accessibilityLabel(alt.isEmpty ? "Image" : alt)
            .accessibilityAddTraits(.isImage)
            if !alt.isEmpty { Text(alt).font(.caption).foregroundStyle(.secondary) }
        }
        // A struct key, not a string: for agent-sent images `url` is the whole data URI.
        .task(id: LoadKey(url: url, wantsRemote: wantsRemote)) {
            guard !isRemote || wantsRemote, let u = URL(string: url) else { return }
            guard let (data, response) = try? await URLSession.shared.data(from: u) else { return }
            if let length = (response as? HTTPURLResponse)?.expectedContentLength, length > Self.maxBytes { return }
            guard data.count <= Self.maxBytes else { return }
            let bytes = data
            loaded = await Task.detached(priority: .utility) { ImageThumbnail.decode(bytes, maxPixel: 1600) }.value
        }
        .fullScreenCover(isPresented: $showViewer) {
            if let loaded { ZoomableImage(image: loaded, caption: alt) }
        }
    }
}

struct ZoomableImage: View {
    let image: UIImage
    let caption: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                Image(uiImage: image).resizable().scaledToFit()
                    .containerRelativeFrame([.horizontal, .vertical]) { size, _ in size * scale }
            }
            .gesture(MagnifyGesture().onChanged { v in scale = max(1, min(5, lastScale * v.magnification)) }
                                     .onEnded { _ in lastScale = scale })
            .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5; lastScale = scale } }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.9))
            }
            .padding()
            .accessibilityLabel("Close")
        }
        .overlay(alignment: .bottom) {
            if !caption.isEmpty {
                Text(caption).font(.footnote).foregroundStyle(.white).padding(8)
                    .background(.black.opacity(0.5), in: .capsule).padding()
            }
        }
    }
}

/// Monospaced block with the language tag and a copy button.
struct CodeBlock: View {
    let language: String?
    let code: String
    /// Still streaming: shown plain, highlighted once the fence closes.
    var live = false
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false
    /// Carries the code it was built from, so a block whose text just changed shows plain
    /// text rather than the previous code's colors until the new result lands.
    private struct Highlighted { var code: String; var text: AttributedString }
    @State private var highlighted: Highlighted?

    /// Re-highlight only when the code, palette or fence state changes, not on every parent render.
    private struct HighlightKey: Equatable { let code: String; let language: String?; let live: Bool; let palette: SyntaxHighlighter.Palette }
    private var highlightKey: HighlightKey { HighlightKey(code: code, language: language, live: live, palette: theme.syntaxPalette(dark: colorScheme == .dark)) }
    /// Under this size the highlight runs inline, so the first frame is already colored.
    private static let inlineLimit = 4_000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.caption2.weight(.medium)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlighted?.code == code ? highlighted!.text : AttributedString(code))
                    .font(theme.codeFont)
                    .padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 10))
        .onChange(of: highlightKey, initial: true) { _, key in
            if key.live { highlighted = nil; return }
            guard key.code.utf8.count < Self.inlineLimit else { return }
            highlighted = Highlighted(code: key.code, text: SyntaxHighlighter.highlight(key.code, language: key.language, palette: key.palette))
        }
        // A big block (a pasted file) goes off the main actor: the page isn't lazy, so a scheme
        // flip re-highlights every block at once.
        .task(id: highlightKey) {
            let key = highlightKey
            guard !key.live, key.code.utf8.count >= Self.inlineLimit else { return }
            let result = await Task.detached(priority: .userInitiated) { SyntaxHighlighter.highlight(key.code, language: key.language, palette: key.palette) }.value
            if !Task.isCancelled { highlighted = Highlighted(code: key.code, text: result) }
        }
    }
}

struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    var alignments: [MarkdownBlock.ColumnAlignment] = []
    @Environment(\.theme) private var theme

    private func inline(_ text: String) -> Text {
        MarkdownView.styledInline(text, codeFont: theme.codeFont, accent: theme.linkColor)
    }

    /// Up to four columns share the width and wrap; wider tables scroll with fixed columns.
    private var scrolls: Bool { header.count > 4 }
    private let fixedColumn: CGFloat = 150

    private func alignment(_ i: Int) -> Alignment {
        guard i < alignments.count else { return .leading }
        switch alignments[i] { case .leading: return .leading; case .center: return .center; case .trailing: return .trailing }
    }

    private func textAlignment(_ i: Int) -> TextAlignment {
        guard i < alignments.count else { return .leading }
        switch alignments[i] { case .leading: return .leading; case .center: return .center; case .trailing: return .trailing }
    }

    private func cell(_ text: String, index: Int, header isHeader: Bool) -> some View {
        inline(text)
            .font(theme.tableFont.weight(isHeader ? .semibold : .regular))
            .multilineTextAlignment(textAlignment(index))
            .padding(.horizontal, 10).padding(.vertical, isHeader ? 7 : 6)
            .frame(width: scrolls ? fixedColumn : nil, alignment: alignment(index))
            .frame(maxWidth: scrolls ? nil : .infinity, alignment: alignment(index))
    }

    private func row(_ cells: [String], isHeader: Bool, striped: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                cell(c, index: i, header: isHeader)
            }
        }
        .background(isHeader ? theme.tableHeaderTint : striped ? Color.primary.opacity(0.03) : Color.clear)
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(header, isHeader: true, striped: false)
            ForEach(Array(rows.enumerated()), id: \.offset) { r, cells in
                row(cells, isHeader: false, striped: !r.isMultiple(of: 2))
            }
        }
    }

    var body: some View {
        Group {
            if scrolls {
                ScrollView(.horizontal, showsIndicators: false) { grid }
            } else {
                grid
            }
        }
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        .clipShape(.rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table with \(header.count) columns and \(rows.count) rows")
    }
}
