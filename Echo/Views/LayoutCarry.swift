import SwiftUI
#if DEBUG
import notify
import os
#endif

/// What the chat screen is in the middle of, for the moment the layout changes under it. Opening or
/// closing an iPhone Duo (or an iPad window drawn narrower or wider past the line) swaps the
/// iPhone's layout for the wide one or back, and the chat screen, its composer and a group chat are
/// built afresh in the other. Each notes its state here as it goes, with the layout it is in; built
/// in the other layout for the same chat, it takes that back up. Built again in the same layout
/// (back from a group chat, another conversation opened) it starts afresh, as it always has.
@MainActor final class LayoutCarry {
    static let shared = LayoutCarry()

    struct Transcript {
        var conversation: UUID
        var wide: Bool
        var page: TranscriptPage.Window
        var searchText: String
        var matchIndex: Int
        var readingID: UUID?
        /// The message at the top of the screen while the reader is back in the conversation; nil
        /// while it follows the end.
        var readingFrom: UUID?
    }
    var transcript: Transcript?

    struct Composer {
        var conversation: UUID
        var wide: Bool
        var showEditor: Bool
        var dismissedContext: Set<String>
        var contextAttached: Set<UUID>
    }
    var composer: Composer?

    /// A group chat: its feed and its voice go over to the new screen whole, so talking with the
    /// group by voice carries on through the change, and so does what was being typed to it.
    struct Group {
        var room: String
        /// The screen that has them now: only that one lets them go.
        var owner: UUID
        var feed: GroupFeed
        var voice: GroupVoice
        var draft: String = ""
        var attachments: [Attachment] = []
        var finding = false
        var findText = ""
    }
    var group: Group?

    /// What the conversation list is searching for: the iPhone's panel and the wide layout's
    /// sidebar are two lists.
    struct ListSearch {
        var wide: Bool
        var query: String
    }
    var listSearch: ListSearch?

    /// The state a transcript left in the other layout for this conversation, once.
    func transcript(for conversation: UUID, wide: Bool) -> Transcript? {
        guard let carried = transcript, carried.conversation == conversation, carried.wide != wide else { return nil }
        transcript = nil
        return carried
    }

    func composer(for conversation: UUID, wide: Bool) -> Composer? {
        guard let carried = composer, carried.conversation == conversation, carried.wide != wide else { return nil }
        composer = nil
        return carried
    }
}

extension EnvironmentValues {
    /// The wide layout (the conversation list beside the chat) rather than the iPhone's.
    @Entry var wideLayout = false
    /// Opens Settings from the app's root, where it stays up when the layout changes; nil, the
    /// list's own sheet.
    @Entry var showSettingsSheet: SettingsOpener? = nil
}

/// The root's Settings, for the list to open. There is one root, so one opener: any two are equal.
struct SettingsOpener: Equatable {
    let open: @MainActor () -> Void
    @MainActor func callAsFunction() { open() }
    static func == (a: SettingsOpener, b: SettingsOpener) -> Bool { true }
}

#if DEBUG
/// `-echo.flipLayout [seconds]`: the layout swapped while Redde runs, as opening or closing an iPhone
/// Duo swaps it (the window keeps its size), to try what the chat screen keeps through it: each
/// time the Darwin notification `com.goosehouse.echo.debug.flipLayout` is posted (UI tests post it
/// at the moment they want), and every so many seconds if a number follows.
struct LayoutFlip: ViewModifier {
    static let notification = "com.goosehouse.echo.debug.flipLayout"
    @Environment(\.horizontalSizeClass) private var real
    @State private var flipped = false

    func body(content: Content) -> some View {
        if DevHooks.has("-echo.flipLayout") {
            content
                .environment(\.horizontalSizeClass, flipped ? (real == .regular ? .compact : .regular) : real)
                .task {
                    var token: Int32 = 0
                    notify_register_dispatch(Self.notification, &token, .main) { _ in
                        MainActor.assumeIsolated { flip() }
                    }
                    defer { notify_cancel(token) }
                    let every = DevHooks.value("-echo.flipLayout").flatMap(Double.init)
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(every ?? 3_600))
                        if every != nil, !Task.isCancelled { flip() }
                    }
                }
        } else {
            content
        }
    }

    private func flip() {
        flipped.toggle()
        Logger(subsystem: "com.goosehouse.echo", category: "layout").info("layout flipped: \(flipped ? "the other one" : "its own", privacy: .public)")
    }
}
#endif
