import SwiftUI
import UIKit

/// Inline selectable text view for the transcript. Uses a UITextView to allow arbitrary text
/// selection with drag handles for both cursors, and customizes the selection menu to include
/// "New chat as prompt" alongside the system defaults (Copy, Lookup, etc.). This replaces the
/// previous approach of opening a separate SelectableTextSheet for text selection.
#if os(iOS)
struct SelectableMarkdownView: UIViewRepresentable {
    let text: String
    let onNewChatAsPrompt: ((String) -> Void)?
    let monospaced: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.adjustsFontForContentSizeCategory = true
        view.alwaysBounceVertical = true
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onNewChatAsPrompt = onNewChatAsPrompt
        if view.text != text { view.text = text }
        view.font = monospaced
            ? UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
            : .preferredFont(forTextStyle: .body)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onNewChatAsPrompt: ((String) -> Void)?

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0 else { return nil }
            let selection = (textView.text as NSString).substring(with: range)
            guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let actions = suggestedActions
            if let onNewChatAsPrompt {
                let newChat = UIAction(title: String(localized: "New chat as prompt"), image: UIImage(systemName: "plus.bubble")) { _ in
                    onNewChatAsPrompt(selection)
                }
                return UIMenu(children: [newChat] + actions)
            }
            return UIMenu(children: actions)
        }
    }
}
#else
/// The same on the Mac: a text view that selects as any Mac text does, and "New chat as prompt"
/// heads the menu a right-click on a selection brings up. This replaces the previous approach of
/// opening a separate SelectableTextSheet for text selection.
struct SelectableMarkdownView: NSViewRepresentable {
    let text: String
    let onNewChatAsPrompt: ((String) -> Void)?
    let monospaced: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: 12, height: 16)
            view.delegate = context.coordinator
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onNewChatAsPrompt = onNewChatAsPrompt
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        view.font = monospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .preferredFont(forTextStyle: .body)
        view.textColor = .labelColor
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onNewChatAsPrompt: ((String) -> Void)?

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            let range = view.selectedRange()
            guard range.length > 0 else { return menu }
            let selection = (view.string as NSString).substring(with: range)
            guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return menu }
            let actions = menu.items.filter { $0.title != "" }
            if let onNewChatAsPrompt {
                let newChat = NSMenuItem(title: String(localized: "New chat as prompt"), action: #selector(newChat(_:)), keyEquivalent: "")
                newChat.target = self
                newChat.representedObject = selection
                newChat.image = NSImage(systemSymbolName: "plus.bubble", accessibilityDescription: nil)
                let menu = NSMenu()
                menu.addItem(newChat)
                menu.addItem(.separator())
                for item in actions { menu.addItem(item) }
                return menu
            }
            return menu
        }

        @objc private func newChat(_ item: NSMenuItem) {
            if let selection = item.representedObject as? String { onNewChatAsPrompt?(selection) }
        }
    }
}
#endif
