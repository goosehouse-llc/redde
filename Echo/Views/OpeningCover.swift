import SwiftUI

/// Something opening out of what was tapped, where there is no pushed page or sheet for the
/// system's zoom transition to attach to: a conversation picked in the side panel, a card on the
/// start screen. A surface grows from the tapped thing until it covers what is behind it, what
/// was opened is swapped in underneath, and the surface clears away over it as it comes forward
/// (the host scales its content by `Opening.contentScale`).
///
/// It is a cover, not a mask on the screen being opened. A mask draws that screen off screen
/// for as long as it is on, and putting one on and taking it off rebuilds the screen under it.
struct OpeningCover: View {
    /// One opening as it goes: starting at `source` (screen coordinates), grown over everything,
    /// what was opened swapped in underneath, then clearing.
    struct Opening: Equatable {
        var source: CGRect
        /// What the tapped thing said, kept where it was while the surface grows round it, and
        /// how far in from the surface's leading edge it sat.
        var title = ""
        var titleInset: CGFloat = 16
        var expanded = false
        var swapped = false
        var clearing = false

        /// What was opened sits a little back under the cover and comes forward as it clears.
        /// Never anything but 1 before the swap: what is there until then must not move.
        var contentScale: CGFloat { swapped && !clearing ? 0.95 : 1 }
    }

    let opening: Opening
    /// The surface as it starts (the tapped thing's own colour) and once it covers.
    var from: Color
    var to: Color
    var text: Color = .primary

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            let start = opening.source.offsetBy(dx: -origin.x, dy: -origin.y)
            let rect = opening.expanded ? CGRect(origin: .zero, size: geo.size) : start
            RoundedRectangle(cornerRadius: opening.expanded ? 0 : 16, style: .continuous)
                .fill(opening.expanded ? to : from)
                .shadow(color: .black.opacity(opening.expanded ? 0 : 0.28), radius: 20, y: 8)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            if !opening.title.isEmpty {
                Text(opening.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(text)
                    .lineLimit(1)
                    .frame(width: max(0, start.width - opening.titleInset - 16), height: start.height, alignment: .leading)
                    .offset(x: start.minX + opening.titleInset, y: start.minY)
                    // Gone by the time the conversation is underneath.
                    .opacity(opening.swapped ? 0 : 1)
            }
        }
        .ignoresSafeArea()
        .opacity(opening.clearing ? 0 : 1)
        // Nothing underneath is tapped while it opens.
        .contentShape(.rect)
        .onTapGesture {}
        .accessibilityHidden(true)
    }

    /// Runs an opening: the cover grows from `source`; once it covers, `swap` puts what was
    /// opened in place underneath; then the cover clears and `opening` goes back to nil.
    @MainActor
    static func run(_ opening: Binding<Opening?>, from source: CGRect, title: String = "", titleInset: CGFloat = 16,
                    swap: @escaping @MainActor () -> Void) {
        opening.wrappedValue = Opening(source: source, title: title, titleInset: titleInset)
        var slow = 1.0
        #if DEBUG
        // `-echo.slowMotion <factor>` stretches it, for looking at it a frame at a time.
        slow = DevHooks.value("-echo.slowMotion").flatMap(Double.init) ?? 1
        #endif
        Task { @MainActor in
            // A frame at the starting size first, or it would simply appear grown.
            try? await Task.sleep(for: .milliseconds(20))
            // A curve with an end, not a spring: a spring is "done" well after it looks done, and
            // the cover would sit there, a blank screen, until then.
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.28 * slow)) {
                opening.wrappedValue?.expanded = true
            } completion: {
                withTransaction(Transaction(animation: nil)) { swap() }
                withAnimation(.easeOut(duration: 0.12 * slow)) { opening.wrappedValue?.swapped = true }
                Task { @MainActor in
                    // A frame for what was opened to be laid out under the cover.
                    try? await Task.sleep(for: .milliseconds(30))
                    withAnimation(.easeOut(duration: 0.24 * slow)) {
                        opening.wrappedValue?.clearing = true
                    } completion: {
                        opening.wrappedValue = nil
                    }
                }
            }
        }
    }
}

/// Where a row that opens a conversation was tapped, for the opening to start from. Rows note
/// it (`opensConversation`); whoever closes the list for the opened conversation takes it. A
/// plain note, not view state: nothing is redrawn for it, and a session that loads from the
/// server opens some moments after its row was tapped.
enum ConversationTap {
    private static var last: (point: CGPoint, at: Date)?

    static func note(_ point: CGPoint) { last = (point, .now) }

    /// The tap, once, if there was one lately.
    static func take() -> CGPoint? {
        defer { last = nil }
        guard let last, Date.now.timeIntervalSince(last.at) < 15 else { return nil }
        return last.point
    }
}

extension View {
    /// On a row that opens a conversation: notes where it was tapped.
    func opensConversation() -> some View {
        simultaneousGesture(SpatialTapGesture(coordinateSpace: .global).onEnded { ConversationTap.note($0.location) })
    }
}
