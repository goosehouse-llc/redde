import SwiftUI

/// The conversation's title in the header. When a new conversation gets its title (its first
/// question), "New conversation" lifts away and the title types itself in behind a caret, as if
/// someone were naming the chat. Opening another conversation just shows its title, and so does
/// everything under Reduce Motion.
struct TypedTitle: View {
    let title: String
    /// Whose title it is: only a change within one conversation is typed.
    let conversationID: UUID
    /// `title` is the stand-in for a conversation with nothing in it yet.
    let isPlaceholder: Bool

    /// What is on screen while typing; nil shows `title` whole.
    @State private var typed: String?
    /// The stand-in on its way out.
    @State private var leaving: String?
    /// The caret, once the stand-in has gone and until the title is all there.
    @State private var caret = false
    @State private var typing: Task<Void, Never>?
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Key: Equatable {
        var id: UUID
        var title: String
        var placeholder: Bool
    }

    /// A header shows about this many characters; the rest of a long title arrives at once.
    private static let typedCharacters = 26

    var body: some View {
        ZStack {
            if let leaving {
                Text(leaving)
                    .lineLimit(1)
                    .transition(.asymmetric(insertion: .identity, removal: .move(edge: .top).combined(with: .opacity)))
            }
            HStack(spacing: 1) {
                Text(typed ?? title).lineLimit(1)
                if caret { Caret(color: theme.accent) }
            }
        }
        // The header's whole width, so the old title is cut off only at the top as it lifts
        // away, not at the sides when the typed text under it is still short.
        .frame(maxWidth: .infinity)
        .clipped()
        .onChange(of: Key(id: conversationID, title: title, placeholder: isPlaceholder)) { old, new in
            typing?.cancel()
            guard old.id == new.id, old.placeholder, !new.placeholder, !reduceMotion else {
                typed = nil
                leaving = nil
                caret = false
                return
            }
            typing = Task { await type(new.title, over: old.title) }
        }
        .onDisappear { typing?.cancel() }
    }

    private func type(_ title: String, over old: String) async {
        typed = ""
        leaving = old
        try? await Task.sleep(for: .milliseconds(30))
        withAnimation(.easeIn(duration: 0.22)) { leaving = nil }
        try? await Task.sleep(for: .milliseconds(240))
        guard !Task.isCancelled else { return }
        caret = true
        let characters = Array(title.prefix(Self.typedCharacters))
        for count in 1 ... max(1, characters.count) {
            guard !Task.isCancelled else { return }
            typed = String(characters.prefix(count))
            try? await Task.sleep(for: .milliseconds(28))
        }
        // The caret rests a moment at the end, then the whole title takes over.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        typed = nil
        caret = false
    }
}

/// A text caret in the accent colour, blinking.
private struct Caret: View {
    let color: Color
    @State private var on = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: 2, height: 17)
            .opacity(on ? 1 : 0.15)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) { on = false }
            }
            .accessibilityHidden(true)
    }
}
