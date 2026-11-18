// The message field on the iPhone and iPad: a UITextView that tells SwiftUI its height only when
// its number of lines changes (2026-11-18).
#if os(iOS)
import SwiftUI
import UIKit

/// The composer's text field. SwiftUI's `TextField(axis: .vertical)` asked its text view for its
/// size after every letter (`_intrinsicSizeWithinSize`, a TextKit layout of the whole draft: ~5 ms
/// a letter in the simulator, most of what typing still cost once the composer stopped being
/// updated per letter). Here the view measures itself in its own layout pass, which typing runs
/// anyway, and SwiftUI hears of it only when the height changes (a line more or less, up to
/// `maxLines`, then it scrolls). `-echo.swiftUIField` puts the SwiftUI field back, to compare.
struct ComposerField: View {
    @Binding var text: String
    let placeholder: String
    var focused: FocusState<Bool>.Binding
    /// Return's label: Send when Return sends (`ReturnSends`), else a line break.
    let returnSends: Bool
    /// The caret and selection: the theme's accent, as SwiftUI's field took from `.tint`.
    var accent: Color = .accentColor
    var maxLines = 5
    @State private var height: CGFloat = 0

    var body: some View {
        FieldRepresentable(text: $text, height: $height, placeholder: placeholder, isFocused: focused.wrappedValue,
                           setFocused: { focused.wrappedValue = $0 }, returnSends: returnSends, accent: accent, maxLines: maxLines)
            .frame(height: max(height, Self.oneLine))
    }

    /// `-echo.swiftUIField` (Debug): SwiftUI's own field, to measure one against the other.
    static let swiftUIFieldForComparison: Bool = {
        #if DEBUG
        DevHooks.has("-echo.swiftUIField")
        #else
        false
        #endif
    }()

    /// One line of the body font, before the first layout says.
    static var oneLine: CGFloat { ceil(UIFont.preferredFont(forTextStyle: .body).lineHeight) }
}

private struct FieldRepresentable: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    let isFocused: Bool
    let setFocused: (Bool) -> Void
    let returnSends: Bool
    let accent: Color
    let maxLines: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> FieldTextView {
        let view = FieldTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = true
        view.showsVerticalScrollIndicator = false
        view.alwaysBounceVertical = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.text = text
        view.maxLines = maxLines
        view.onHeight = { [weak coordinator = context.coordinator] fitted in
            // After this layout pass: SwiftUI is told outside its own update.
            DispatchQueue.main.async { coordinator?.parent.height = fitted }
        }
        return view
    }

    func updateUIView(_ view: FieldTextView, context: Context) {
        context.coordinator.parent = self
        // Set from outside (sent, a mention completed, dictation, a draft put back): the text
        // view takes it, its cursor at the end. Typing itself comes the other way and is equal.
        if view.text != text {
            view.text = text
            view.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            view.textDidChangeFromOutside()
        }
        view.placeholder = placeholder
        let tint = UIColor(accent)
        if view.tintColor != tint { view.tintColor = tint }
        let key: UIReturnKeyType = returnSends ? .send : .default
        if view.returnKeyType != key {
            view.returnKeyType = key
            if view.isFirstResponder { view.reloadInputViews() }
        }
        if view.maxLines != maxLines { view.maxLines = maxLines }
        // The composer asked for the keyboard, or to put it away: only when what it asks changes,
        // so the field never takes the keyboard back from another one (the editor page's).
        let coordinator = context.coordinator
        if coordinator.asked != isFocused {
            coordinator.asked = isFocused
            if isFocused, !view.isFirstResponder {
                DispatchQueue.main.async { if view.window != nil, !view.isFirstResponder { view.becomeFirstResponder() } }
            } else if !isFocused, view.isFirstResponder {
                DispatchQueue.main.async { if view.isFirstResponder { view.resignFirstResponder() } }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: FieldTextView, context: Context) -> CGSize? {
        // The height is the one ComposerField sets; nothing is measured here.
        CGSize(width: proposal.width ?? 200, height: max(height, ComposerField.oneLine))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: FieldRepresentable
        /// What the composer last asked: the keyboard (true) or not.
        var asked = false

        init(_ parent: FieldRepresentable) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            if parent.text != textView.text { parent.text = textView.text }
            (textView as? FieldTextView)?.updatePlaceholder()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            asked = true
            if !parent.isFocused { parent.setFocused(true) }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            asked = false
            if parent.isFocused { parent.setFocused(false) }
        }
    }
}

/// The text view: a placeholder, and its height worked out in its own layout pass.
final class FieldTextView: UITextView {
    var onHeight: ((CGFloat) -> Void)?
    var maxLines = 5 { didSet { setNeedsLayout() } }
    private var lastHeight: CGFloat = 0
    private let placeholderLabel = UILabel()

    var placeholder: String {
        get { placeholderLabel.text ?? "" }
        set {
            guard placeholderLabel.text != newValue else { return }
            placeholderLabel.text = newValue
            accessibilityLabel = newValue   // as SwiftUI's field: its prompt is its name
        }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.numberOfLines = 1
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)
        accessibilityIdentifier = "composer"
    }

    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    // A picture on the clipboard pastes as an attachment, long text as a file beside the
    // message (`ComposerPaste`; SwiftUI's field was taught this at run time).
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), ComposerPaste.shared.takesPictures { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if ComposerPaste.shared.takesPictures {
            ComposerPaste.shared.pastePictures()
        } else if !ComposerPaste.shared.pasteLongText() {
            super.paste(sender)
        }
    }

    func updatePlaceholder() { placeholderLabel.isHidden = !text.isEmpty }

    func textDidChangeFromOutside() {
        updatePlaceholder()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.frame = CGRect(x: 0, y: 0, width: bounds.width, height: ceil(placeholderLabel.font.lineHeight))
        updatePlaceholder()
        // As tall as the text, from one line up to `maxLines`; past that it scrolls. contentSize
        // is the layout typing has just done, for the lines on screen (all of them, up to there).
        let line = ceil(font?.lineHeight ?? 20)
        let fitted = min(max(ceil(contentSize.height), line), ceil(line * CGFloat(maxLines)))
        if abs(fitted - lastHeight) > 0.5 {
            lastHeight = fitted
            onHeight?(fitted)
        }
    }
}
#endif
