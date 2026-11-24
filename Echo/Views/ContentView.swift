import StoreKit
import SwiftUI
import os

struct ContentView: View {
    @Environment(Conversation.self) var conversation
    @Environment(VoiceSession.self) var voiceSession
    @Environment(\.theme) var theme

    /// The side panel's width: the fold's, on a half-open Duo; else the width given, which widens
    /// on the Mac with the text zoom (`textScale`).
    private func sidebarWidth(_ width: CGFloat) -> CGFloat {
        #if os(macOS)
        splitFold.map { $0.frame.midX } ?? width * theme.textScale
        #else
        splitFold.map { $0.frame.midX } ?? width
        #endif
    }
    @State var settings = Settings.shared
    @State var router = LaunchRouter.shared
    @State var lock = AppLock.shared
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.requestReview) var requestReview
    @Environment(\.horizontalSizeClass) var sizeClass
    @State var draft = ""
    /// Whose draft that is (`Drafts.key`), and the conversation it was read for: each chat keeps
    /// its own, and a new one's stays with it when its first message makes it a chat.
    @State var draftKey = Drafts.newConversation
    @State var draftConversation: UUID?
    /// What the composer held when "Edit & resend" took it over; it comes back when that ends.
    @State var draftBeforeEditing: (text: String, attachments: [Attachment])?
    @State var showSettings = false
    #if os(macOS)
    @Environment(\.openWindow) var openWindow
    #endif
    @State var shareItem: ShareItem?
    /// Rename, from the header's menu.
    @State var showRename = false
    /// ··· → Make This a Routine… (`RoutineSheet`).
    @State var makingRoutine = false
    @State var routineAsk = RoutineAsk.shared
    @State var renameText = ""
    @State var renameError: String?
    /// "Add to Project" from the header's menu: the New Project prompt, and what went wrong.
    @State var namingProject = false
    @State var projectProblem: String?
    /// "Change Face…" in a bot's chat: that bot, its face being picked.
    @State var facingBot: HermesBot?
    /// In a bot's chat, its voice being picked.
    @State var voicingBot: HermesBot?
    /// The main agent's voice: the app's own, Settings → Voice, from its chat's menu.
    @State var voicingMain = false
    @State var schedulingBot: HermesBot?
    /// "Edit Bot…" in a bot's chat.
    @State var editingBot: HermesBot?
    /// "Start Fresh…" in a bot's chat: being asked about, and what went wrong.
    @State var confirmingFresh = false
    @State var freshProblem: String?
    /// A bot's chat asked for from outside (Your Agents, a notification) that couldn't open: why.
    @State var botProblem: String?
    @State var showSetup = false
    /// A setup link that was opened, up for confirmation.
    @State var setupCode: SetupCodeOffer?
    @State var pushOffer: PushOffer?
    @State var showConversations = false
    /// iPhone: where the row of the conversation just opened was tapped (see `SidePanel`).
    @State var openingFromRow: CGPoint?
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// What's New was up when voice mode was asked for: voice wins, and it comes back after.
    @State var deferredWhatsNew: WhatsNew.Release?
    @State var showVoice = false
    /// A group chat's voice screen, and the room it talks with.
    @State var showGroupVoice = false
    @State var groupVoice: GroupVoiceScene?
    /// An iPhone Duo half open, folded down the middle of the wide layout (`Fold`).
    @State private var splitFold: Fold?
    /// When the composer last lost the keyboard: the layout changing takes it away, and gives it back.
    @State var focusLostAt: Date?
    @State var showSearch = false
    @State var showTerminal = false
    /// ··· → Agent's Screen: the chat's agent's Bot Desktop (`BotScreenView`, the Dashboard's).
    @State var showAgentScreen = false
    @State var showModelPicker = false
    /// The chat's Session Details, from its menu, the context ring or ⌘I.
    @State var showSessionDetails = false
    /// "Edit & resend": the message being replaced; sending truncates the transcript from it.
    @State var editing: Message?
    @State var pendingAttachments: [Attachment] = []
    @FocusState var composerFocused: Bool
    @State var groups = GroupDirectory.shared
    /// The update's highlights, shown once per version.
    @State var whatsNew: WhatsNew.Release?
    #if DEBUG
    /// Dev hook: `-echo.screen profiles` opens the profile picker (screenshots, live tests).
    @State var showProfilePicker = false
    /// Dev hook: `-echo.screen push` opens the pairings for notifications (UI tests, the lab).
    @State var showPush = false
    @State var showTips = false
    @State var showServers = false
    /// Dev hooks: `-echo.screen gateway` and `files` open those screens of Settings (screenshots).
    @State var showGateway = false
    #if DEBUG
    /// `-echo.screen botGallery`: every bot creature, large, to look them over.
    @State var showBotGallery = false
    @State var showRoleFaces = false
    @State var showDemoPatch = false
    /// `-echo.screen activity|pluginUpdates|triggers|watches`: that page, in a sheet (the day's video, `DemoDay`);
    /// `goal` and `goals` (with `-echo.demoGoals`) a goal's page and the list, for screenshots.
    @State var demoDayPage: String?
    /// `-echo.screen aheadOfYourDay`: Ahead of Your Day's sheet (screenshots).
    @State var showAheadOfYourDay = false
    #endif
    @State var showFiles = false
    #endif

    /// The wide layout or the iPhone's, one container either way (see `body`).
    private var layouts: some View {
        ZStack {
            if sizeClass == .regular {
                // iPad: sessions in the sidebar, transcript in the detail column.
                AnyView(NavigationSplitView {
                    // The stack is what lets a project folder push its session list *inside*
                    // the sidebar. Without it the NavigationLink has nowhere to go: the row
                    // does nothing and there is no back button to escape with.
                    NavigationStack {
                        ConversationsList(wideDetail: true)
                    }
                    // An iPhone Duo half open, folded down the middle: the list on the left page and the
                    // chat on the right, the line between them on the fold (as Apple's split views
                    // go), so that the chat and its message field are clear of it.
                    .navigationSplitViewColumnWidth(min: sidebarWidth(280), ideal: sidebarWidth(340), max: sidebarWidth(420))
                } detail: {
                    chatScreen(showListButton: false)
                }
                .readingFold($splitFold, vertical: true))
            } else {
                #if os(iOS)
                AnyView(phoneLayout)
                #endif
            }
        }
    }

    var body: some View {
        // One container whatever the layout, so that what hangs off it (the sheets, the voice
        // screen, the work done as Redde opens) stays put when the layout changes under it:
        // opening or closing an iPhone Duo swaps one layout for the other while Redde runs, as
        // drawing an iPad window narrower does. On a Group each was the layout's own, and went
        // with it: the voice screen closed, the opening's work ran again.
        //
        // Each stretch of what hangs off it is a function of its own, and the screen goes in
        // behind AnyView: in one chain, an unoptimized (Debug) build kept every step's copy on the
        // stack until body returned, 842 KB of the iPhone's 1 MB main-thread stack, and Debug
        // builds crashed at launch (measured 2026-11-13). A function's copies go when it returns.
        routing(launching(debugSheets(sheets(AnyView(screen)))))
    }

    /// The chat or the split layout, under a call put away to a bar.
    private var screen: some View {
        groupVoicePresentation(chatPresentations(AnyView(VStack(spacing: 0) {
            // A live call put away from the voice screen (`CallBar`): over the chat and the list
            // alike, everything else moved down under it. A row above them and not a safe-area
            // inset: a navigation bar takes no notice of one, and the call's bar lay on the chat's.
            if callInBar {
                CallBar(session: voiceSession, name: conversation.bot?.name ?? settings.headerTitle,
                        face: botFace ?? BotDirectory.shared.mainFace) { showVoice = true }
                    .environment(\.theme, chatTheme)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            layouts
        }
        // The page's colour behind the bar and the clock above it; nothing new behind the rest.
        .background { if callInBar { chatTheme.pageColor.ignoresSafeArea() } }
        .animation(.snappy(duration: 0.3), value: callInBar)
        // The call is that chat's: another one opened ends it (its answers would land in the wrong one).
        .onChange(of: conversation.id) { if voiceSession.inBar { voiceSession.cancel() } }
        .environment(\.wideLayout, sizeClass == .regular)
        .environment(\.showSettingsSheet, SettingsOpener { showSettings = true }))))
    }
}
