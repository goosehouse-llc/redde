import SwiftUI

/// Plain, fully selectable copy of a reply, for grabbing a sentence rather than the whole thing.
struct SelectableTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Select text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
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
