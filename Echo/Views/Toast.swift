import SwiftUI

/// One toast for every screen: a capsule at the bottom that announces itself to VoiceOver and
/// clears after a few seconds. Set the bound text to show; the modifier handles the timer.
struct ToastModifier: ViewModifier {
    @Binding var text: String?
    var bottomPadding: CGFloat = 12
    var duration: Duration = .seconds(3)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let text {
                    Text(text)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: .capsule)
                        .padding(.horizontal, 24)
                        .padding(.bottom, bottomPadding)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .animation(.easeOut(duration: 0.2), value: text)
            .task(id: text) {
                guard let text else { return }
                AccessibilityNotification.Announcement(text).post()
                try? await Task.sleep(for: duration)
                if !Task.isCancelled, self.text == text { self.text = nil }
            }
    }
}

extension View {
    func toast(_ text: Binding<String?>, bottomPadding: CGFloat = 12, duration: Duration = .seconds(3)) -> some View {
        modifier(ToastModifier(text: text, bottomPadding: bottomPadding, duration: duration))
    }
}

extension Date {
    /// "2 hours ago", "in 5 minutes": the one relative-date rendering used across the app, with
    /// direction preserved (SwiftUI's `.relative` style drops it).
    var relativeLabel: String { Self.relativeFormatter.localizedString(for: self, relativeTo: .now) }

    /// One formatter: the callers are list rows, and building one per row is the slow part.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.dateTimeStyle = .named
        return f
    }()
}
