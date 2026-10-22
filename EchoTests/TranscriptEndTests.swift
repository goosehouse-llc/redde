import SwiftUI
import Testing
@testable import Echo

/// Whether the transcript is at its end, from what the scroll view says about itself. The
/// numbers are the ones an iPhone 17 Pro Max gave on iOS 26.3 and an iPhone 18 Pro Max on iOS
/// 27.0: a 956-point screen with 158 points of bars above the transcript and 98 below.
struct TranscriptEndTests {
    private func geometry(offset: CGFloat, content: CGFloat = 11_964, room: CGFloat = 699, above: CGFloat = 158, below: CGFloat = 98) -> ScrollGeometry {
        ScrollGeometry(contentOffset: CGPoint(x: 0, y: offset), contentSize: CGSize(width: 440, height: content),
                       contentInsets: EdgeInsets(top: above, leading: 0, bottom: below, trailing: 0), containerSize: CGSize(width: 440, height: room))
    }

    /// Scrolled to the end by hand, the transcript is at its end. It wasn't: the sum came out
    /// short by both insets, so "Jump to latest" stayed and new text was not followed.
    @Test func theEndIsReachedWhereTheLastMessageIsOnScreen() {
        // As far down as the transcript goes: its last point sits on top of the composer.
        let end = geometry(offset: 11_964 - 699 - 158)
        #expect(TranscriptEnd.readableBottom(end) == 11_964)
        #expect(TranscriptEnd.isReached(end) && !TranscriptEnd.isPassed(end))
        // Where a fling left it in the measurement, fifteen points short.
        #expect(TranscriptEnd.isReached(geometry(offset: 11_091)))
        // Within reach of the end counts; farther up doesn't.
        #expect(TranscriptEnd.isReached(geometry(offset: 11_107 - 119)))
        #expect(!TranscriptEnd.isReached(geometry(offset: 11_107 - 121)))
        #expect(!TranscriptEnd.isReached(geometry(offset: 4_000)))
        // The keyboard takes room and adds to the inset below: the end is still the end.
        let typing = geometry(offset: 11_964 - 363 - 158, room: 363, below: 434)
        #expect(TranscriptEnd.isReached(typing) && !TranscriptEnd.isPassed(typing))
    }

    @Test func blankSpaceUnderTheLastMessageIsPastTheEnd() {
        // A bounce, or rows that shrank: the reader sees past the last message.
        #expect(!TranscriptEnd.isPassed(geometry(offset: 11_107 + 24)))
        #expect(TranscriptEnd.isPassed(geometry(offset: 11_107 + 25)))
        #expect(TranscriptEnd.isReached(geometry(offset: 11_107 + 60)))
    }

    /// A conversation that is all on screen is at its end wherever it sits, and never past it.
    @Test func aShortConversationIsAlwaysAtItsEnd() {
        let short = geometry(offset: -158, content: 420)
        #expect(TranscriptEnd.fits(short) && TranscriptEnd.isReached(short) && !TranscriptEnd.isPassed(short))
        // Pulled down by a finger.
        #expect(TranscriptEnd.isReached(geometry(offset: -260, content: 420)))
        #expect(!TranscriptEnd.isPassed(geometry(offset: 80, content: 420)))
        // One point more than fits has somewhere to scroll.
        #expect(!TranscriptEnd.fits(geometry(offset: -158, content: 700)))
    }

    /// Jump to latest stops a fling first, through the UIKit scroll view under the SwiftUI one:
    /// the probe in the transcript's content finds it once it is on screen.
    @MainActor @Test func theTranscriptsScrollViewIsFoundToStopAFling() async throws {
        let handle = ScrollHandle()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: ScrollView {
            Color.clear.frame(height: 3000).background(ScrollHandle.Finder(handle: handle))
        })
        window.makeKeyAndVisible()
        for _ in 0 ..< 20 where !handle.isAttached { try await Task.sleep(for: .milliseconds(50)) }
        #expect(handle.isAttached)
        handle.stopCoasting()   // not coasting: nothing to do, and nothing breaks
        window.isHidden = true
    }
}
