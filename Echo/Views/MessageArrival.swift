import SwiftUI

/// A message arriving in the transcript the moment it is sent.
///
/// Your own message rises out of the composer: it starts below its place, behind the field, and
/// comes up into it. The reply's waiting row holds back a beat, so the two don't cross on the way.
/// One short move of offset, scale and opacity on the one row; a conversation that loads, or a
/// message that has been there a while, doesn't move.
struct MessageArrival: ViewModifier {
    nonisolated enum Kind: Equatable, Sendable {
        case none
        /// Your message, just sent.
        case sent
        /// The reply's row, still waiting for its first word.
        case waitingReply
    }

    let kind: Kind
    /// Terminal themes set your messages on the left, as prompt lines.
    var leading = false

    /// It has come up into place, and it has become visible (sooner than it lands).
    @State private var landed = false
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How new a message has to be to arrive: longer ago than this and it was simply there.
    nonisolated static let freshness: TimeInterval = 1.5
    /// Far enough down to start behind the composer, whatever is between.
    static let travel: CGFloat = 96

    nonisolated static func kind(for message: Message, isLive: Bool, now: Date = .now) -> Kind {
        guard now.timeIntervalSince(message.createdAt) < freshness else { return .none }
        switch message.role {
        case .user: return .sent
        case .assistant: return isLive && message.text.isEmpty && message.reasoning.isEmpty && message.tools.isEmpty ? .waitingReply : .none
        }
    }

    func body(content: Content) -> some View {
        let rising = kind == .sent && !landed && !reduceMotion
        content
            .scaleEffect(rising ? 0.9 : 1, anchor: leading ? .bottomLeading : .bottomTrailing)
            .offset(y: rising ? Self.travel : 0)
            .opacity(kind == .none || visible ? 1 : 0)
            .onAppear {
                switch kind {
                case .none:
                    break
                case .sent:
                    withAnimation(.easeOut(duration: 0.16)) { visible = true }
                    withAnimation(.spring(duration: 0.44, bounce: 0.2)) { landed = true }
                case .waitingReply:
                    withAnimation(.easeOut(duration: 0.25).delay(reduceMotion ? 0 : 0.24)) { visible = true }
                }
            }
    }
}
