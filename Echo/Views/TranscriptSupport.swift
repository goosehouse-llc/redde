import SwiftUI

/// Plain, fully selectable copy of a reply, for grabbing a sentence rather than the whole thing:
/// to copy it, or to ask about it. In the transcript, the selection's menu starts with "Ask about
/// this", which puts the selection in the composer as a quote for the next message.
struct SelectableTextSheet: View {
    let text: String
    var title = "Select text"
    /// For a tool's input and output, which are data, not prose.
    var monospaced = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.asksAboutSelection) private var asksAbout

    var body: some View {
        NavigationStack {
            SelectableTextView(text: text, monospaced: monospaced, onAsk: asksAbout ? { ask(about: $0) } : nil)
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .bottom) {
                    if asksAbout {
                        Label("Select some of it and choose Ask about this to quote it in your next message.", systemImage: "quote.bubble")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.bar)
                    }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func ask(about selection: String) {
        dismiss()
        Task {
            // Once the sheet is out of the way, so the composer can take the keyboard.
            try? await Task.sleep(for: .milliseconds(350))
            LaunchRouter.shared.requestDraft(text: Quote.markdown(selection), attachments: [])
        }
    }
}

/// A piece of earlier text, set as a Markdown quote with room after it for the question.
nonisolated enum Quote {
    static func markdown(_ text: String) -> String {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.allSatisfy(\.isEmpty) else { return "" }
        return lines.map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n") + "\n\n"
    }
}

/// Text that can be selected a word, a sentence, a paragraph at a time. SwiftUI's own selectable
/// `Text` has no say in the selection's menu, which is where "Ask about this" goes.
struct SelectableTextView: UIViewRepresentable {
    let text: String
    var monospaced = false
    /// Heads the selection's menu with "Ask about this"; nil leaves the menu as the system's.
    var onAsk: ((String) -> Void)?

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
        context.coordinator.onAsk = onAsk
        if view.text != text { view.text = text }
        view.font = monospaced
            ? UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
            : .preferredFont(forTextStyle: .body)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onAsk: ((String) -> Void)?

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let onAsk, range.length > 0 else { return nil }
            let selection = (textView.text as NSString).substring(with: range)
            guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let ask = UIAction(title: "Ask about this", image: UIImage(systemName: "quote.bubble")) { _ in onAsk(selection) }
            return UIMenu(children: [ask] + suggestedActions)
        }
    }
}

/// Settings → Appearance → Chat text size: the conversation set a few steps larger or smaller
/// than the iPhone's own text size, on the system's scale, so it still follows that setting.
/// Everything in the transcript is sized by text style and moves together; the composer and
/// the bars around it stay as the system has them.
struct ChatTextSize: ViewModifier {
    @Environment(\.dynamicTypeSize) private var system
    @State private var settings = Settings.shared

    func body(content: Content) -> some View {
        let size = Self.size(system, steps: settings.chatTextSize)
        content
            .dynamicTypeSize(size)
            .environment(\.chatFontPoints, settings.chatTextSize == 0 ? nil : Self.bodyPoints(at: size))
    }

    /// `steps` along the system's scale from `system`, stopping at either end of it.
    nonisolated static func size(_ system: DynamicTypeSize, steps: Int) -> DynamicTypeSize {
        let scale = DynamicTypeSize.allCases
        guard let index = scale.firstIndex(of: system) else { return system }
        return scale[min(max(index + steps, 0), scale.count - 1)]
    }

    /// The body font's size in points at a text size, for what isn't drawn by SwiftUI (formulas).
    static func bodyPoints(at size: DynamicTypeSize) -> CGFloat {
        UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))).pointSize
    }

    /// What Settings calls each step.
    nonisolated static func label(_ steps: Int) -> String {
        switch steps {
        case ...(-2): "Smallest"
        case -1: "Smaller"
        case 0: "Same as iPhone"
        case 1: "Larger"
        default: "Largest"
        }
    }
}

extension View {
    func chatTextSize() -> some View { modifier(ChatTextSize()) }
}

extension EnvironmentValues {
    /// The body text size in points inside a conversation whose text size was changed in
    /// Settings; nil where it is the system's.
    @Entry var chatFontPoints: CGFloat?
}

extension EnvironmentValues {
    /// True in the transcript, where there is a composer for a quote to go to. Sheets it presents
    /// inherit it; a subagent's transcript and voice mode leave it off.
    @Entry var asksAboutSelection = false
}


/// Haptics and a VoiceOver announcement around a turn: a nudge when Hermes needs you, a tick
/// when the reply lands, a buzz on failure.
struct TurnFeedback: ViewModifier {
    let conversation: Conversation
    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.warning, trigger: conversation.pendingInterrupt?.interrupt.id) { _, new in new != nil }
            .sensoryFeedback(.success, trigger: conversation.isStreaming) { old, new in old && !new && conversation.lastError == nil }
            .sensoryFeedback(.error, trigger: conversation.lastError) { _, new in new != nil }
            .onChange(of: conversation.isStreaming) { old, new in
                if old, !new, UIAccessibility.isVoiceOverRunning {
                    AccessibilityNotification.Announcement(conversation.lastError == nil ? "Redde replied" : "Redde couldn't reply").post()
                }
            }
    }
}
