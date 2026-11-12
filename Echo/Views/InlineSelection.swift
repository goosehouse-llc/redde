#if os(iOS)
import SwiftUI
import UIKit

/// Selecting part of a reply where it stands (GitHub issue 46, 2026-11-05): long-press its text
/// and the word under the finger is selected, with handles, Copy, Look Up and "Ask about this",
/// as in Notes. Replies are drawn with SwiftUI's `Text`, which can only select a whole block, and
/// a selectable text view for every reply cost long chats half their opening time (2026-10-21).
/// So only the pressed reply is swapped, at the press, for text views drawn to look the same
/// (`SelectableReply`); it goes back when the selection is let go.
///
/// The reply's menu and its reactions moved to its ··· button, and reactions to a double-tap.
@MainActor
enum InlineSelection {
    /// Where the press was, in window points, for the swapped-in text that is under it to select
    /// the word there. Taken by the first that has it; dropped if none does (the press was on a
    /// code block, a table, a picture).
    static var pending: CGPoint? {
        didSet { if pending != nil { pressedAt = .now } }
    }
    /// When the press was taken, for the time from it to the word being selected (logged in
    /// Debug builds: it has to stay too short to see).
    static var pressedAt: ContinuousClock.Instant?

    static func selected() {
        #if DEBUG
        if let pressedAt { NSLog("[InlineSelection] selected %.1f ms after the press", Double((ContinuousClock.now - pressedAt).components.attoseconds) / 1e15) }
        #endif
        pressedAt = nil
    }
}

/// The long-press that starts it: a UIKit recognizer, for the point in the window.
struct ReplyLongPress: UIGestureRecognizerRepresentable {
    let pressed: (CGPoint) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer()
        // A little under UIKit's half second: the swap takes a few frames, and the word should
        // show selected when it would in Notes.
        press.minimumPressDuration = 0.42
        return press
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        if recognizer.state == .began { pressed(recognizer.location(in: nil)) }
    }
}

/// A finished reply's Markdown as `MarkdownView` draws it, its text selectable: each run of
/// headings, paragraphs and lists one text view; code, tables, diagrams, maths and pictures as
/// they are; a quote's text selectable inside its bar.
struct SelectableReply: View {
    let text: String
    var linkPaths = false
    /// The selection was let go: draw the reply as before.
    let onEnd: () -> Void

    /// Parsed as the view is made, not after its first frame: an empty first frame moved the
    /// transcript under the finger.
    @State private var blocks: [MarkdownBlock]

    init(text: String, linkPaths: Bool = false, onEnd: @escaping () -> Void) {
        self.text = text
        self.linkPaths = linkPaths
        self.onEnd = onEnd
        _blocks = State(initialValue: MarkdownView.blocks(text, linkPaths: linkPaths))
    }

    var body: some View {
        SelectableBlocks(blocks: blocks, secondary: false, onEnd: onEnd)
            .onChange(of: text) { blocks = MarkdownView.blocks(text, linkPaths: linkPaths) }
            .task {
                // A press on no text (a code block, a picture): nothing took it; back at once.
                try? await Task.sleep(for: .milliseconds(400))
                if InlineSelection.pending != nil {
                    InlineSelection.pending = nil
                    onEnd()
                }
            }
    }
}

private struct SelectableBlocks: View {
    let blocks: [MarkdownBlock]
    /// A quote's: in the secondary colour, as `MarkdownBlockView` draws it.
    let secondary: Bool
    let onEnd: () -> Void
    @Environment(\.theme) private var theme

    /// Runs of text blocks together; everything else on its own.
    private enum Segment {
        case text([MarkdownBlock])
        case quote([MarkdownBlock])
        case other(MarkdownBlock)
    }

    private var segments: [Segment] {
        var out: [Segment] = []
        var run: [MarkdownBlock] = []
        func flush() { if !run.isEmpty { out.append(.text(run)); run = [] } }
        for block in blocks {
            switch block {
            case .heading, .paragraph, .list: run.append(block)
            case let .quote(inner): flush(); out.append(.quote(inner))
            default: flush(); out.append(.other(block))
            }
        }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: secondary ? 6 : 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .text(run):
                    InlineTextView(text: ReplyText.attributed(run, theme: theme, secondary: secondary), onEnd: onEnd)
                case let .quote(inner):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(theme.quoteBarColor).frame(width: 3)
                        SelectableBlocks(blocks: inner, secondary: true, onEnd: onEnd)
                    }
                    .foregroundStyle(.secondary)
                case let .other(block):
                    MarkdownBlockView(block: block).equatable()
                }
            }
        }
    }
}

/// One run of a reply's text in a text view that selects as Notes does.
private struct InlineTextView: UIViewRepresentable {
    let text: NSAttributedString
    let onEnd: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @Environment(\.asksAboutSelection) private var asksAbout

    func makeUIView(context: Context) -> ReplyTextView {
        let view = ReplyTextView(frame: .zero)  // TextKit 2; `init(usingTextLayoutManager:)` skips a subclass's own properties
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        let menu = UIEditMenuInteraction(delegate: context.coordinator)
        view.addInteraction(menu)
        view.pressMenu = menu
        return view
    }

    func updateUIView(_ view: ReplyTextView, context: Context) {
        context.coordinator.onEnd = onEnd
        context.coordinator.openURL = openURL
        context.coordinator.asksAbout = asksAbout
        view.onEnd = onEnd
        // Only what changed: setting either again clears the selection, and a redraw while
        // selecting (on the iPad, a tap elsewhere) then ended it mid-update, which SwiftUI
        // ignored, so the reply stayed as text views (2026-11-07). The view's own copy of the
        // text never equals this one (UIKit adds attributes), so the last one set is compared.
        let link = UIColor(theme.linkColor)
        if context.coordinator.linkColor != link {
            context.coordinator.linkColor = link
            view.linkTextAttributes = [.foregroundColor: link, .underlineStyle: NSUnderlineStyle.single.rawValue]
        }
        if context.coordinator.shown != text {
            context.coordinator.shown = text
            view.attributedText = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ReplyTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? .greatestFiniteMagnitude
        guard width > 0, width.isFinite else { return nil }
        // As wide as the text, as `Text` is, so a short reply's bubble stays short.
        let used = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: min(width, ceil(used.width)), height: ceil(height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIEditMenuInteractionDelegate {
        var onEnd: () -> Void = {}
        var shown: NSAttributedString?
        var linkColor: UIColor?
        var openURL: OpenURLAction?
        var asksAbout = false

        /// The selection let go of (a tap on the text): the reply as before.
        func textViewDidChangeSelection(_ view: UITextView) {
            #if DEBUG
            (view as? ReplyTextView)?.showSelectionToTests()
            #endif
                guard let view = view as? ReplyTextView, view.started, view.selectedRange.length == 0 else { return }
            view.finish()
        }

        func textView(_ view: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            UIMenu(children: askAction(view, range) + suggestedActions)
        }

        /// The menu shown as the press selects, which the text view doesn't show by itself.
        func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let view = interaction.view as? UITextView else { return nil }
            return UIMenu(children: askAction(view, view.selectedRange) + suggestedActions)
        }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration, animator: any UIEditMenuInteractionAnimating) {
            (interaction.view as? ReplyTextView)?.menuClosed()
        }

        /// The text view's own menu, after the handles were moved.
        func textView(_ view: UITextView, willDismissEditMenuWith animator: any UIEditMenuInteractionAnimating) {
            (view as? ReplyTextView)?.menuClosed()
        }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
            guard let view = interaction.view as? UITextView, let range = view.selectedTextRange else { return .null }
            return view.selectionRects(for: range).map(\.rect).reduce(CGRect.null) { $0.union($1) }
        }

        /// Links open as the reply's do, through the transcript's `openURL` (paths open the file).
        func textView(_ view: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case let .link(url) = textItem.content, let openURL else { return defaultAction }
            return UIAction { _ in openURL(url) }
        }

        private func askAction(_ view: UITextView, _ range: NSRange) -> [UIMenuElement] {
            guard asksAbout, range.length > 0 else { return [] }
            let selection = (view.attributedText.string as NSString).substring(with: range)
            guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            let ask = UIAction(title: String(localized: "Ask about this"), image: UIImage(systemName: "quote.bubble")) { [weak view] _ in
                (view as? ReplyTextView)?.finish()
                LaunchRouter.shared.requestDraft(text: "", attachments: [], quote: selection)
            }
            return [ask]
        }
    }
}

/// The text view: selects the word under the press as it appears, and lets go on a tap anywhere
/// else on the screen.
final class ReplyTextView: UITextView {
    /// Has a selection the person made; letting go of it ends the swap.
    fileprivate(set) var started = false
    fileprivate var onEnd: () -> Void = {}
    /// The menu shown for the press's selection (`InlineTextView` adds it).
    fileprivate weak var pressMenu: UIEditMenuInteraction?
    private var tapElsewhere: [UITapGestureRecognizer] = []
    /// Fingers on the text.
    private let touches = TouchCount()
    /// Fingers anywhere in the app's windows: the selection's handles aren't the text view's own
    /// subviews, so a finger on one is only seen here (2026-11-07: touching a handle closed the
    /// menu, and with no finger counted on the text the selection ended).
    private var windowTouches: [TouchCount] = []

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        addGestureRecognizer(touches)
    }

    required init?(coder: NSCoder) { fatalError("Not used from a storyboard") }

    override func layoutSubviews() {
        super.layoutSubviews()
        lookForPress()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopWatching() } else { lookForPress() }
    }

    /// The text is laid out before SwiftUI puts the view in its place; the press is looked for
    /// once it is there, a turn of the run loop later.
    private func lookForPress() {
        guard InlineSelection.pending != nil else { return }
        takePress()
        if InlineSelection.pending != nil { DispatchQueue.main.async { [weak self] in self?.takePress() } }
    }

    /// Selects the word at the pending press, if it is on this text.
    private func takePress() {
        guard let press = InlineSelection.pending, let window, bounds.height > 0 else { return }
        let point = convert(press, from: window)
        guard bounds.insetBy(dx: -6, dy: -6).contains(point) else { return }
        InlineSelection.pending = nil
        guard let position = closestPosition(to: point) else { return finish() }
        // On a space between words, the word beside it (a lone space selected had no Ask about this).
        let near = [position, self.position(from: position, offset: -1), self.position(from: position, offset: 1)].compactMap(\.self)
        let word = near.lazy.compactMap { at in
            self.tokenizer.rangeEnclosingPosition(at, with: .word, inDirection: .storage(.forward))
                ?? self.tokenizer.rangeEnclosingPosition(at, with: .word, inDirection: .storage(.backward))
        }.first
            ?? textRange(from: position, to: self.position(from: position, offset: 1) ?? position)
        guard let word, !word.isEmpty else { return finish() }
        becomeFirstResponder()
        selectedTextRange = word
        started = true
        InlineSelection.selected()
        #if DEBUG
        showSelectionToTests()
        #endif
        UISelectionFeedbackGenerator().selectionChanged()
        watchTaps()
        showMenu()
    }

    #if DEBUG
    /// For the UI tests (ReplyActionsUITests): the selection's length and where its end handle
    /// stands, in screen points, as "inline-selection|length|x|y".
    func showSelectionToTests() {
        guard let range = selectedTextRange else { return }
        let end = caretRect(for: range.end)
        let point = convert(CGPoint(x: end.midX, y: end.midY), to: nil)
        accessibilityIdentifier = "inline-selection|\(selectedRange.length)|\(Int(point.x))|\(Int(point.y))"
    }
    #endif

    /// The selection's menu, which the text view only shows by itself for a selection it made.
    func showMenu() {
        guard let menu = pressMenu, let range = selectedTextRange else { return }
        let rect = selectionRects(for: range).map(\.rect).reduce(CGRect.null) { $0.union($1) }
        menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.minY)))
    }

    /// A tap outside the text lets go of the selection, as in Notes; the tap still does its own
    /// thing. While a menu is up the first tap outside only closes it (`menuClosed`).
    fileprivate func watchTaps() {
        guard started, let scene = window?.windowScene else { return }
        for each in scene.windows where !tapElsewhere.contains(where: { $0.view === each }) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesEnded = false
            each.addGestureRecognizer(tap)
            tapElsewhere.append(tap)
            let count = TouchCount()
            each.addGestureRecognizer(count)
            windowTouches.append(count)
        }
    }

    /// A menu over the selection closed: a tap outside, or one of its actions (Copy, Ask about
    /// this). Unless a finger is still down in the app (on a handle, moving the selection), it
    /// ends. (A tap outside that only closes the menu lands in the menu's own window, where
    /// nothing here counts it.)
    fileprivate func menuClosed() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.started, self.touches.down == 0, self.windowTouches.allSatisfy({ $0.down == 0 }) else { return }
            self.finish()
        }
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        // The handles stand a little outside the text.
        guard !bounds.insetBy(dx: -16, dy: -16).contains(tap.location(in: self)) else { return }
        // After the tap's own action: Copy in the menu goes to this view while it is first responder.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.started else { return }
            self.finish()
        }
    }

    private func stopWatching() {
        for tap in tapElsewhere { tap.view?.removeGestureRecognizer(tap) }
        tapElsewhere = []
        for count in windowTouches { count.view?.removeGestureRecognizer(count) }
        windowTouches = []
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        // Look Up, Share and Translate take the screen for a moment; the swap ends with them.
        if resigned, started { finish() }
        return resigned
    }

    func finish() {
        started = false
        stopWatching()
        if isFirstResponder { _ = super.resignFirstResponder() }
        // After any view update this came from: a state change made during one is dropped.
        let onEnd = onEnd
        DispatchQueue.main.async { onEnd() }
    }
}

/// Counts the fingers down on a view and its subviews (the selection's handles), recognizing
/// nothing and holding no touch back.
private final class TouchCount: UIGestureRecognizer {
    private(set) var down = 0

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { down += touches.count }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches.count) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches.count) }
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    /// Counting on while the transcript scrolls or a handle is dragged.
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }

    private func lift(_ count: Int) {
        down = max(0, down - count)
        if down == 0 { state = .failed }
    }

    override func reset() { down = 0 }
}

/// A run of a reply's Markdown blocks as `MarkdownBlockView` draws them, for a text view: the
/// theme's faces and colours, the same spacing, lists with their markers in a column.
@MainActor
enum ReplyText {
    static func attributed(_ blocks: [MarkdownBlock], theme: ResolvedTheme, secondary: Bool) -> NSAttributedString {
        let fonts = Fonts(theme: theme)
        let colour = secondary ? UIColor.secondaryLabel : UIColor(theme.textColor)
        let out = NSMutableAttributedString()
        for (i, block) in blocks.enumerated() {
            let last = i == blocks.count - 1
            let after: CGFloat = last ? 0 : (secondary ? 6 : 8)
            switch block {
            case let .heading(level, text):
                let style = NSMutableParagraphStyle()
                style.paragraphSpacingBefore = i == 0 ? 0 : (level <= 2 ? 4 : 2)
                style.paragraphSpacing = after
                out.append(inline(text, font: fonts.heading(level), colour: colour, theme: theme, fonts: fonts, style: style))
            case let .paragraph(text):
                let style = NSMutableParagraphStyle()
                style.paragraphSpacing = after
                out.append(inline(text, font: fonts.body, colour: colour, theme: theme, fonts: fonts, style: style))
            case let .list(items):
                for (j, item) in items.enumerated() {
                    out.append(listItem(item, last: j == items.count - 1, after: after, colour: colour, theme: theme, fonts: fonts))
                    if j < items.count - 1 { out.append(NSAttributedString(string: "\n")) }
                }
            default:
                continue
            }
            if !last { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

    private static func listItem(_ item: MarkdownBlock.ListItem, last: Bool, after: CGFloat, colour: UIColor, theme: ResolvedTheme, fonts: Fonts) -> NSAttributedString {
        let lead = CGFloat(item.indent) * 16
        let marker: NSAttributedString
        if let checked = item.checked {
            let symbol = UIImage(systemName: checked ? "checkmark.square.fill" : "square",
                                 withConfiguration: UIImage.SymbolConfiguration(font: fonts.body))?
                .withTintColor(checked ? UIColor(theme.checkboxColor) : .secondaryLabel, renderingMode: .alwaysOriginal)
            let attachment = NSTextAttachment()
            attachment.image = symbol
            if let size = symbol?.size { attachment.bounds = CGRect(x: 0, y: fonts.body.descender + 1, width: size.width, height: size.height) }
            marker = NSAttributedString(attachment: attachment)
        } else {
            marker = NSAttributedString(string: item.marker, attributes: [.font: fonts.marker, .foregroundColor: UIColor.secondaryLabel])
        }
        // The marker's column: at least 22 points for numbers, 10 for bullets, its text 6 after.
        let column = max(item.checked == nil ? (item.ordered ? 22 : 10) : 0, ceil(marker.size().width))
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: lead + column), NSTextTab(textAlignment: .left, location: lead + column + 6)]
        style.headIndent = lead + column + 6
        style.paragraphSpacing = last ? after : 4
        let line = NSMutableAttributedString(string: "\t", attributes: [.font: fonts.body, .paragraphStyle: style])
        line.append(marker)
        line.append(NSAttributedString(string: "\t", attributes: [.font: fonts.body]))
        let done = item.checked == true
        let text = NSMutableAttributedString(attributedString: inline(item.text, font: fonts.body, colour: done ? .secondaryLabel : colour, theme: theme, fonts: fonts, style: style))
        if done { text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: text.length)) }
        line.append(text)
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        return line
    }

    /// Bold, italic, strikethrough, code spans and links, as `MarkdownView.styledInline` reads them.
    private static func inline(_ text: String, font: UIFont, colour: UIColor, theme: ResolvedTheme, fonts: Fonts, style: NSParagraphStyle) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour, .paragraphStyle: style]
        guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: text, attributes: base)
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var attributes = base
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                attributes[.font] = fonts.code
                attributes[.backgroundColor] = UIColor(theme.linkColor.opacity(0.12))
            } else {
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if !traits.isEmpty { attributes[.font] = font.adding(traits) }
            }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return out
    }

    /// The theme's faces as UIKit fonts, as `ResolvedTheme.messageFont`, `headingFont` and
    /// `codeFont` give them for SwiftUI on iPhone and iPad.
    struct Fonts {
        let body: UIFont
        let code: UIFont
        let marker: UIFont
        private let theme: ResolvedTheme

        init(theme: ResolvedTheme) {
            self.theme = theme
            body = Self.font(.body, custom: 17, name: theme.proseFontName, design: theme.palette.replyDesign)
            if let name = theme.palette.monoFontName, let mono = UIFont(name: name, size: 13) {
                code = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: mono)
            } else {
                code = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
            }
            marker = body.monospacedDigits()
        }

        func heading(_ level: Int) -> UIFont {
            if theme.promptPrefix != nil { return body.weighted(level <= 2 ? .bold : .semibold) }
            if let name = theme.proseFontName {
                switch level {
                case 1: return Self.font(.title3, custom: 20, name: name, design: .default).weighted(.bold)
                case 2: return Self.font(.headline, custom: 17, name: name, design: .default).weighted(.bold)
                default: return Self.font(.subheadline, custom: 15, name: name, design: .default).weighted(.semibold)
                }
            }
            let design = theme.palette.headingDesign
            switch level {
            case 1: return Self.font(.title3, custom: 20, name: nil, design: design).weighted(.semibold)
            case 2: return Self.font(.headline, custom: 17, name: nil, design: design)
            default: return Self.font(.subheadline, custom: 15, name: nil, design: design).weighted(.semibold)
            }
        }

        private static func font(_ style: UIFont.TextStyle, custom size: CGFloat, name: String?, design: Font.Design) -> UIFont {
            if let name, let face = UIFont(name: name, size: size) {
                return UIFontMetrics(forTextStyle: style).scaledFont(for: face)
            }
            let system = UIFont.preferredFont(forTextStyle: style)
            let systemDesign: UIFontDescriptor.SystemDesign = switch design {
            case .rounded: .rounded
            case .serif: .serif
            case .monospaced: .monospaced
            default: .default
            }
            guard systemDesign != .default, let descriptor = system.fontDescriptor.withDesign(systemDesign) else { return system }
            return UIFont(descriptor: descriptor, size: 0)
        }
    }
}

private extension UIFont {
    func adding(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }

    func weighted(_ weight: UIFont.Weight) -> UIFont {
        if weight == .bold, !fontDescriptor.symbolicTraits.contains(.traitUIOptimized) {
            // A named face: its bold, where it has one.
            if let bold = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(.traitBold)), bold.postscriptName != fontDescriptor.postscriptName {
                return UIFont(descriptor: bold, size: 0)
            }
        }
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: 0)
    }

    func monospacedDigits() -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.featureSettings: [[
            UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
            UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
        ]]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
#endif
