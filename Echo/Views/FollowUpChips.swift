import SwiftUI

/// The follow-up questions for the last reply, as a row of chips above the composer; tapping
/// one sends it. They come in one after another and leave together.
struct FollowUpChips: View {
    @Environment(Conversation.self) private var conversation
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0

    var body: some View {
        let suggestions = conversation.followUps
        if !suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, text in
                        if index < shown {
                            Button {
                                conversation.send(text)
                            } label: {
                                Text(text)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(theme.surface ?? Color(.secondarySystemBackground), in: .capsule)
                                    .overlay(Capsule().strokeBorder(.quaternary))
                            }
                            .buttonStyle(.plain)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 10)
            }
            .scrollClipDisabled()
            .accessibilityLabel("Suggested follow-ups")
            .task(id: suggestions) {
                // Stagger: one chip every 90 ms, all at once under Reduce Motion.
                shown = 0
                for i in 1 ... suggestions.count {
                    if !reduceMotion { try? await Task.sleep(for: .milliseconds(i == 1 ? 40 : 90)) }
                    withAnimation(.snappy(duration: 0.35, extraBounce: 0.1)) { shown = i }
                }
            }
            .transition(.opacity)
        }
    }
}
