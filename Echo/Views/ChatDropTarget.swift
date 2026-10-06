import SwiftUI

/// Makes a chat take drops: pictures and files join what is waiting to be sent, a link or a
/// dragged piece of text goes on the end of the draft (`DroppedItems` does the sorting). While
/// something is dragged over it, an outline says what letting go will do; what couldn't be taken
/// is named in a toast.
private struct ChatDropTarget: ViewModifier {
    @Binding var draft: String
    @Binding var attachments: [Attachment]
    /// Something was taken: the composer should have the keyboard.
    var onTaken: () -> Void

    @Environment(\.theme) private var theme
    @State private var targeted = false
    @State private var problem: String?

    func body(content: Content) -> some View {
        content
            .onDrop(of: DroppedItems.types, isTargeted: $targeted) { providers in
                Task { await take(providers) }
                return true
            }
            .overlay { if targeted || Self.previewsHint { hint } }
            .animation(.easeOut(duration: 0.15), value: targeted)
            .toast($problem, bottomPadding: 90, duration: .seconds(4))
    }

    /// `-echo.dropHint` shows the outline without a drag (the simulator can't make one).
    private static var previewsHint: Bool {
        #if DEBUG
        DevHooks.has("-echo.dropHint")
        #else
        false
        #endif
    }

    private var hint: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
            .background(theme.accent.opacity(0.08), in: .rect(cornerRadius: 22))
            .overlay {
                Label("Drop to attach", systemImage: "paperclip")
                    .font(.headline)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.regularMaterial, in: .capsule)
            }
            .padding(10)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityHidden(true)
    }

    private func take(_ providers: [NSItemProvider]) async {
        let dropped = await DroppedItems.load(providers)
        attachments += dropped.attachments
        let text = dropped.text.joined(separator: "\n")
        if !text.isEmpty { draft = draft.isEmpty ? text : draft + "\n" + text }
        problem = dropped.problems.first
        if !dropped.attachments.isEmpty || !text.isEmpty { onTaken() }
    }
}

extension View {
    /// Drops on this view go to the composer whose draft and pending attachments these are.
    func chatDropTarget(draft: Binding<String>, attachments: Binding<[Attachment]>, onTaken: @escaping () -> Void) -> some View {
        modifier(ChatDropTarget(draft: draft, attachments: attachments, onTaken: onTaken))
    }
}
