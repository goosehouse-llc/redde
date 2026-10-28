import StoreKit
import SwiftUI
import os

struct ContentView: View {
    @Environment(Conversation.self) private var conversation
    @Environment(VoiceSession.self) private var voiceSession
    @Environment(\.theme) private var theme
    @State private var settings = Settings.shared
    @State private var router = LaunchRouter.shared
    @State private var lock = AppLock.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var draft = ""
    /// Whose draft that is (`Drafts.key`), and the conversation it was read for: each chat keeps
    /// its own, and a new one's stays with it when its first message makes it a chat.
    @State private var draftKey = Drafts.newConversation
    @State private var draftConversation: UUID?
    /// What the composer held when "Edit & resend" took it over; it comes back when that ends.
    @State private var draftBeforeEditing: (text: String, attachments: [Attachment])?
    @State private var showSettings = false
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @State private var shareItem: ShareItem?
    /// Rename, from the header's menu.
    @State private var showRename = false
    @State private var renameText = ""
    @State private var renameError: String?
    /// "Add to Project" from the header's menu: the New Project prompt, and what went wrong.
    @State private var namingProject = false
    @State private var projectProblem: String?
    /// "Change Face…" in a bot's chat: that bot, its face being picked.
    @State private var facingBot: HermesBot?
    /// In a bot's chat, its voice being picked.
    @State private var voicingBot: HermesBot?
    /// The main agent's voice: the app's own, Settings → Voice, from its chat's menu.
    @State private var voicingMain = false
    @State private var schedulingBot: HermesBot?
    /// "Edit Bot…" in a bot's chat.
    @State private var editingBot: HermesBot?
    /// "Start Fresh…" in a bot's chat: being asked about, and what went wrong.
    @State private var confirmingFresh = false
    @State private var freshProblem: String?
    @State private var showSetup = false
    /// A setup link that was opened, up for confirmation.
    @State private var setupCode: SetupCodeOffer?
    @State private var pushOffer: PushOffer?
    @State private var showConversations = false
    /// iPhone: where the row of the conversation just opened was tapped (see `SidePanel`).
    @State private var openingFromRow: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What's New was up when voice mode was asked for: voice wins, and it comes back after.
    @State private var deferredWhatsNew: WhatsNew.Release?
    @State private var showVoice = false
    /// A group chat's voice screen, and the room it talks with.
    @State private var showGroupVoice = false
    @State private var groupVoice: GroupVoiceScene?
    /// An iPhone Duo half open, folded down the middle of the wide layout (`Fold`).
    @State private var splitFold: Fold?
    /// When the composer last lost the keyboard: the layout changing takes it away, and gives it back.
    @State private var focusLostAt: Date?
    @State private var showSearch = false
    @State private var showTerminal = false
    @State private var showModelPicker = false
    /// "Edit & resend": the message being replaced; sending truncates the transcript from it.
    @State private var editing: Message?
    @State private var pendingAttachments: [Attachment] = []
    @FocusState private var composerFocused: Bool
    @State private var groups = GroupDirectory.shared
    /// The update's highlights, shown once per version.
    @State private var whatsNew: WhatsNew.Release?
    #if DEBUG
    /// Dev hook: `-echo.screen profiles` opens the profile picker (screenshots, live tests).
    @State private var showProfilePicker = false
    /// Dev hook: `-echo.screen push` opens the pairings for notifications (UI tests, the lab).
    @State private var showPush = false
    @State private var showTips = false
    @State private var showServers = false
    /// Dev hooks: `-echo.screen gateway` and `files` open those screens of Settings (screenshots).
    @State private var showGateway = false
    #if DEBUG
    /// `-echo.screen botGallery`: every bot creature, large, to look them over.
    @State private var showBotGallery = false
    @State private var showDemoPatch = false
    #endif
    @State private var showFiles = false
    #endif

    var body: some View {
        // One container whatever the layout, so that what hangs off it (the sheets, the voice
        // screen, the work done as Redde opens) stays put when the layout changes under it:
        // opening or closing an iPhone Duo swaps one layout for the other while Redde runs, as
        // drawing an iPad window narrower does. On a Group each was the layout's own, and went
        // with it: the voice screen closed, the opening's work ran again.
        groupVoicePresentation(chatPresentations(ZStack {
            if sizeClass == .regular {
                // iPad: sessions in the sidebar, transcript in the detail column.
                NavigationSplitView {
                    // The stack is what lets a project folder push its session list *inside*
                    // the sidebar. Without it the NavigationLink has nowhere to go: the row
                    // does nothing and there is no back button to escape with.
                    NavigationStack {
                        ConversationsList(wideDetail: true)
                    }
                    // An iPhone Duo half open, folded down the middle: the list on the left page and the
                    // chat on the right, the line between them on the fold (as Apple's split views
                    // go), so that the chat and its message field are clear of it.
                    .navigationSplitViewColumnWidth(min: splitFold.map { $0.frame.midX } ?? 280,
                                                    ideal: splitFold.map { $0.frame.midX } ?? 340,
                                                    max: splitFold.map { $0.frame.midX } ?? 420)
                } detail: {
                    padDetail
                }
                .readingFold($splitFold, vertical: true)
            } else {
                #if os(iOS)
                phoneLayout
                #endif
            }
        }
        .environment(\.wideLayout, sizeClass == .regular)
        .environment(\.showSettingsSheet, SettingsOpener { showSettings = true })))
        #if os(iOS)
        .sheet(isPresented: $showSettings, onDismiss: { WatchLink.shared.push() }) { SettingsView() }
        #else
        // The Mac's Settings window, wherever the iPhone opens its sheet.
        .onChange(of: showSettings) { _, show in
            guard show else { return }
            showSettings = false
            openSettings()
        }
        .focusedSceneValue(\.chatCommands, chatCommands)
        #endif
        .sheet(isPresented: $showModelPicker) { NavigationStack { ModelPickerView() }.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showSetup, onDismiss: { WatchLink.shared.push() }) { SetupView() }
        .sheet(item: $setupCode, onDismiss: {
            // A first run the code didn't finish goes back to setup.
            if !settings.setupDone, !settings.isConfigured { showSetup = true }
        }) { SetupCodeSheet(offer: $0) }
        .sheet(item: $pushOffer) { PushPairingSheet(offer: $0) }
        .sheet(item: $whatsNew) { WhatsNewView(release: $0, wide: sizeClass == .regular) }
        #if DEBUG
        .sheet(isPresented: $showProfilePicker) { NavigationStack { ProfilePickerView() } }
        .modifier(WatchDraftSheet())
        .sheet(isPresented: $showTips) { NavigationStack { TipJarView() } }
        .sheet(isPresented: $showServers) { NavigationStack { ServersView() } }
        .sheet(isPresented: $showPush) { NavigationStack { PushSettingsView() } }
        .sheet(isPresented: $showGateway) { NavigationStack { GatewayView() } }
        #if DEBUG
        .fullScreenCover(isPresented: $showBotGallery) { BotGallery() }
        .sheet(isPresented: $showDemoPatch) { PatchView(title: "Lab change one", patch: PatchView.demo, notes: PatchView.demoNotes, notesTitle: "Steps left with it") }
        #endif
        .sheet(isPresented: $showFiles) { NavigationStack { FilesView() } }
        #endif
        .fullScreenCover(isPresented: $showVoice) {
            VoiceView(session: voiceSession, onSwitchToTyping: {
                // Once the cover is gone, raise the keyboard in the composer.
                Task { try? await Task.sleep(for: .milliseconds(450)); composerFocused = true }
            })
            // Handed over by hand: on a Mac (the iPad app running there) a full-screen cover
            // doesn't inherit the presenter's environment, and voice mode crashed on opening with
            // "No Observable object of type Conversation found". Sheets do inherit it.
            .environment(conversation)
            .environment(voiceSession)
            .environment(\.theme, chatTheme)
            // In a bot's chat, voice mode is with the bot: its name, and its creature as the orb.
            .environment(\.replySpeaker, conversation.bot?.name)
            .environment(\.replyFace, botFace)
            .environment(\.fileSource, conversation.fileSource)
            .environment(\.sendFromPage, PageSender(conversation: conversation.id, send: conversation.sendFromPage))
            .tint(chatTheme.accent)
        }
        .task {
            settings.applyLocalDefaultsIfPresent()
            // Opened by a setup link: its confirmation is the setup.
            if !settings.setupDone, !settings.isConfigured, setupCode == nil, router.pendingSetupCode == nil { showSetup = true }
            #if DEBUG
            applyDevHooks()
            #endif
            // Download the speech model early so the first voice turn isn't slow. In the background:
            // it can take a while (and never arrives in the simulator), and opening the voice
            // screen below must not wait on it. (It sat inside the DEBUG block from 2026-09-11,
            // so release builds skipped it.)
            Task { await warmSpeechAssets() }
            if Settings.shared.openToVoiceScreen, router.pendingVoice == nil, !showVoice { openVoice(fromOutside: true) }
            // "When Redde opens: Conversations": the iPhone's panel starts out, on its last tab. (On
            // iPad the list is always beside the chat.) A Siri or control request still wins.
            if settings.launchScreen == .conversations, sizeClass != .regular, router.pendingVoice == nil, !showVoice {
                showConversations = true
            }
            // After the voice screen may have opened: then it waits until that closes.
            presentWhatsNewIfDue()
            #if DEBUG
            if DevHooks.has("-echo.voiceView") { openVoice(fromOutside: true) }
            if DevHooks.has("-echo.autoVoice") { await launchVoice(handsFree: false, fromOutside: true) }
            // `-echo.livePreview <voice>`: that live voice's preview played (the engine whose voice
            // it is), how it went in the live-measure log (with `-echo.liveMeasure`).
            if let voice = DevHooks.value("-echo.livePreview") {
                let preview = LiveVoicePreview(), began = ContinuousClock.now
                let engine = LiveEngine.allCases.first { $0.voices.contains(voice) } ?? .gptLive
                preview.play(voice, of: engine, as: settings.headerTitle, in: "English")
                while preview.playing != nil { try? await Task.sleep(for: .milliseconds(100)) }
                LiveMeasure.write("preview \(voice): \(preview.problem ?? "played") after \((ContinuousClock.now - began).formatted(.units(allowed: [.milliseconds], width: .narrow)))")
            }
            // `-echo.voiceHandoff`: the voice screen's face handed to Scout, back, then to Quill, as
            // a spoken prefix does it (recording the transition).
            if DevHooks.has("-echo.voiceHandoff") {
                for bot in [BotRef(profile: "scout", name: "Scout"), nil, BotRef(profile: "writer", name: "Quill")] {
                    try? await Task.sleep(for: .seconds(2.5))
                    conversation.replaceForDemo(messages: conversation.messages, bot: bot)
                }
            }
            #endif
        }
        .onOpenURL { url in
            // Control Center / Lock Screen controls open the app through echo://listen.
            if let handsFree = EchoURL.parseListen(url) { router.requestVoice(handsFree: handsFree) }
            if url.scheme == EchoURL.scheme, url.host == "share" { consumeSharedItems() }
            // The "Needs you" widget: the conversation that waits, as a notification's tap opens it.
            if let session = EchoURL.parseSession(url) { router.requestSession(session) }
            // A setup link (redde.goosehouse.org/connect#… or redde://connect), from the Camera
            // or a tap: a setup code to confirm.
            // The same address carries a pairing link for notifications (`hermes redde-push pair`).
            if let offer = PushOffer(url: url) { router.requestPushPairing(offer) }
            else if let offer = SetupCodeOffer(url: url) { router.requestSetup(offer) }
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            // The web form is a universal link, which can arrive this way as well.
            guard let url = activity.webpageURL else { return }
            if let offer = PushOffer(url: url) { router.requestPushPairing(offer) }
            else if let offer = SetupCodeOffer(url: url) { router.requestSetup(offer) }
        }
        .onAppear { consumeControlRequest(); handleLaunchRequest(); handleWake(); handleCaptureRequest(); handleDraftRequest(); handleSetupCode(); handlePushRequests(); handleCallScreen() }
        .onChange(of: router.pendingVoice) { handleLaunchRequest() }
        .onChange(of: router.pendingWake) { handleWake() }
        .onChange(of: router.pendingCallScreen) { handleCallScreen() }
        .onChange(of: router.pendingCapture) { handleCaptureRequest() }
        .onChange(of: router.pendingDraft) { handleDraftRequest() }
        .onChange(of: router.pendingSetupCode) { handleSetupCode() }
        .onChange(of: router.pendingPushOffer) { handlePushRequests() }
        .onChange(of: router.pendingSession) { handlePushRequests() }
        .onChange(of: router.pendingRoom) { handlePushRequests() }
        .onChange(of: router.pendingBot) { handlePushRequests() }
        .onChange(of: lock.isLocked) { _, locked in
            // A Siri / control / share request that arrived while locked runs once unlocked.
            if !locked { consumeControlRequest(); handleLaunchRequest(); handleWake(); handleCaptureRequest(); consumeSharedItems(); handleDraftRequest(); handleSetupCode(); handlePushRequests(); handleCallScreen() }
            // An agent's call answered while Redde was locked: its microphone opens now.
            #if os(iOS)
            if !locked { AgentCalls.shared.unlocked() }
            #endif
            // "What's New" held back by the lock. A moment later, so a voice request opens first.
            if !locked { Task { try? await Task.sleep(for: .milliseconds(600)); presentWhatsNewIfDue() } }
        }
        .onChange(of: showVoice) { _, open in
            if !open { Task { try? await Task.sleep(for: .milliseconds(600)); presentWhatsNewIfDue() } }
        }
        .onChange(of: conversation.isStreaming) { was, now in
            if was, !now { replyFinished() }
            // A reply started (Ask Redde about a card, Siri, a share): show the chat it lands in.
            if now, !was {
                if sizeClass == .regular { section = .sessions } else if showConversations { setDrawer(open: false) }
            }
        }
        // Another conversation opened (Siri, a notification, the list): it takes the group chat's place.
        .onChange(of: conversation.id) { groups.open = nil }
        .onChange(of: settings.connectionKey) { groups.open = nil }
        .onChange(of: conversation.id) {
            // A fresh conversation: have llama-swap load its model before the first message.
            if conversation.messages.isEmpty { ModelWarmer.warm(conversation) }
            editing = nil
            ReadState.markConversationRead(conversation.id)   // on screen = read, for Siri
        }
        // Each conversation's draft: kept as it is typed, swapped when another one opens.
        .onChange(of: Drafts.key(for: conversation), initial: true) { _, key in bindDraft(to: key) }
        .background { DraftKeeper(draft: $draft, attachments: $pendingAttachments, key: draftKey, editing: editing != nil) }
        .onChange(of: editing?.id) { _, now in
            // Edit & resend is over, sent or cancelled: back to what was being written before it.
            guard now == nil, let before = draftBeforeEditing else { return }
            draftBeforeEditing = nil
            draft = before.text
            pendingAttachments = before.attachments
        }
        .onChange(of: settings.setupDone) { _, done in
            // "Erase everything" in Settings: back to first run once its sheet is gone.
            guard !done, !settings.isConfigured else { return }
            Task { try? await Task.sleep(for: .milliseconds(500)); showSetup = true }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            consumeControlRequest()
            Notifier.shared.clearDelivered()
            ReadState.markConversationRead(conversation.id)
            conversation.noteSeen()   // and on the host, for the chat list's Unread
            HermesServeClient.shared.reconnectIfNeeded()
            ModelWarmer.warm(conversation)
            conversation.retryOutbox()   // back in the foreground: try anything still waiting to send
            conversation.deleteLeftIncognitoChats()   // ones the app couldn't delete as they were left
            consumeSharedItems()
            handleCallScreen()
            // (On an agent's call, voice mode is the call's: nothing new is started over it.)
            #if os(iOS)
            guard AgentCalls.shared.current == nil else { return }
            #endif
            guard Settings.shared.listenOnOpen, router.pendingVoice == nil, !voiceSession.mightBeBusy else { return }
            Task { await launchVoice(handsFree: showVoice ? voiceSession.continuous : settings.handsFreeByDefault, fromOutside: true) }
        }
    }

    /// A group chat's voice screen, as the conversation's: on the root, so that it stays up when
    /// the group chat is built again in the other layout.
    private func groupVoicePresentation(_ content: some View) -> some View {
        content
            .fullScreenCover(isPresented: $showGroupVoice, onDismiss: { groupVoice?.voice.stop(); groupVoice = nil }) {
                if let scene = groupVoice {
                    VoiceView(session: voiceSession, onSwitchToTyping: {
                        Task { try? await Task.sleep(for: .milliseconds(450)); composerFocused = true }
                    }, group: scene)
                    // Handed over by hand: a full-screen cover on a Mac doesn't inherit the environment.
                    .environment(conversation)
                    .environment(voiceSession)
                    .environment(\.theme, theme)
                    .onAppear {
                        scene.voice.start(scene.feed, session: voiceSession)
                        #if DEBUG
                        if let who = DevHooks.value("-echo.groupVoice"), !who.hasPrefix("-") {
                            Task { try? await Task.sleep(for: .seconds(1.5)); scene.voice.demoSpeaking(who) }
                        }
                        #endif
                    }
                }
            }
            // Another conversation took the group chat's place (Siri, a notification): its voice goes.
            .onChange(of: groups.open?.id) { _, open in
                if showGroupVoice, groupVoice?.feed.room.id != open { showGroupVoice = false }
            }
    }

    /// The chat's sheets and dialogs (its menu's, the toolbar's): on the root, not on the chat
    /// screen, so that they stay up when the layout changes and the chat screen is built again in
    /// the other (an iPhone Duo opened or closed). The Terminal's connection with them. And what
    /// is done when the layout changes (`layoutChanged`).
    private func chatPresentations(_ content: some View) -> some View {
        content
            .onChange(of: sizeClass) { _, now in layoutChanged(wide: now == .regular) }
            .onChange(of: composerFocused) { _, focused in if !focused { focusLostAt = .now } }
            .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
            #if os(iOS)
            .fullScreenCover(isPresented: $showTerminal) { TerminalScreen(folderLookup: terminalFolder) }
            #endif
            .alert("Rename conversation", isPresented: $showRename) {
                TextField("Name", text: $renameText)
                    // Return on the keyboard saves, like the button.
                    .onSubmit { showRename = false; saveRename() }
                Button("Save") { saveRename() }
                Button("Cancel", role: .cancel) {}
            } message: {
                conversation.serverSessionID == nil ? Text("Leave it empty to go back to the first question.")
                                                    : Text("The session is renamed on your server too.")
            }
            .modifier(ChatProjectPrompt(naming: $namingProject, problem: $projectProblem))
            .confirmationDialog(conversation.bot.map { String(localized: "Start a fresh chat with \($0.name)?") }
                                    ?? String(localized: "Start a fresh chat with this bot?"),
                                isPresented: $confirmingFresh, titleVisibility: .visible) {
                Button("Start Fresh") {
                    Task {
                        do { try await conversation.startBotChatFresh(mainName: settings.headerTitle) } catch { freshProblem = error.localizedDescription }
                    }
                }
            } message: {
                Text("This chat is archived on your server with its messages, and the new one starts with no history. What the bot saved to its memory stays. To make this chat shorter instead, send /compress.")
            }
            .alert("Couldn't start fresh", isPresented: Binding(get: { freshProblem != nil }, set: { if !$0 { freshProblem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(freshProblem ?? "")
            }
            .sheet(item: $voicingBot) { BotVoicePicker(bot: $0, mainName: settings.headerTitle) }
            .sheet(isPresented: $voicingMain, onDismiss: { WatchLink.shared.push() }) {
                NavigationStack {
                    // Its sections, in a form as Settings has them: alone, each was laid out apart and each
                    // took the Done (2026-10-26, from Sol's ••• menu).
                    Form { VoiceSettings() }
                        .navigationTitle("\(settings.headerTitle)'s Voice")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { voicingMain = false } } }
                }
                .holdsWakePhrases(.voicePicker)
            }
            .sheet(item: $schedulingBot) { BotSchedulesView(bot: $0, mainName: settings.headerTitle) }
            .sheet(item: $facingBot) { bot in
                BotFacePicker(bot: bot, name: bot.label(mainName: settings.headerTitle), current: botFace ?? BotFace(seed: bot.name)) {
                    Task { _ = try? await BotDirectory.shared.refresh() }
                }
            }
            .sheet(item: $editingBot) { bot in
                BotEditor(mode: .edit(bot), mainName: settings.headerTitle) { outcome in
                    Task {
                        _ = try? await BotDirectory.shared.refresh()
                        if case let .deleted(name) = outcome, conversation.bot?.profile == name { conversation.reset() }
                    }
                }
            }
            .alert("Couldn't rename", isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(renameError ?? "")
            }
    }

    /// The chat's place: the conversation, or a group chat opened from the list.
    @ViewBuilder
    private func chatScreen(showListButton: Bool) -> some View {
        if let room = groups.open {
            GroupChatView(room: room, focused: $composerFocused,
                          openList: showListButton ? { setDrawer(open: true) } : nil,
                          openVoice: { groupVoice = $0; showGroupVoice = true }) { groups.forget(room.id) }
                .id(room.id)
        } else {
            transcriptScreen(showListButton: showListButton)
        }
    }

    private func transcriptScreen(showListButton: Bool) -> some View {
        TranscriptView(showSetup: $showSetup, showSearch: $showSearch, onEdit: beginEditing, onEditQueued: editQueued)
            .environment(\.replySpeaker, conversation.bot?.name)
            .environment(\.replyFace, botFace)
            .environment(\.fileSource, conversation.fileSource)
            .environment(\.sendFromPage, PageSender(conversation: conversation.id, send: conversation.sendFromPage))
            .chatTextSize()
            .background(theme.pageColor)
            .foregroundStyle(theme.textColor)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    FollowUpChips()
                    ComposerView(draft: $draft, pendingAttachments: $pendingAttachments, editing: $editing,
                                 focused: $composerFocused,
                                 openHandsFree: { Task { await launchVoice(handsFree: settings.handsFreeByDefault, fromOutside: false) } },
                                 openModelPicker: { showModelPicker = true })
                }
                    .animation(.snappy(duration: 0.3), value: conversation.followUps)
                    .frame(maxWidth: 820).frame(maxWidth: .infinity)
                    #if os(macOS)
                    .padding(.bottom, 10)   // clear of the window's edge, which a phone's home bar keeps it from
                    #endif
                    // Solid themes have no glass field to hide the transcript scrolling past the composer.
                    .background(theme.usesGlass ? AnyShapeStyle(.clear) : AnyShapeStyle(theme.pageColor))
            }
            // Pictures, files, links and text dropped anywhere on the chat go to the composer.
            .chatDropTarget(draft: $draft, attachments: $pendingAttachments) { composerFocused = true }
            .navigationTitle(headerTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The conversation on top; the agent and model beneath, tap to pick the model —
                // the /model sheet without typing /model.
                ToolbarItem(placement: .principal) {
                    // Two lines, both of which open the model picker; beside the second, how
                    // full the model's context is, which opens its own explanation.
                    VStack(spacing: 1) {
                        Button { showModelPicker = true } label: {
                            Group {
                                if let botFace {
                                    // A bot's chat: whose it is, by its face and name, side by side.
                                    HStack(spacing: 6) {
                                        BotAvatar(face: botFace, name: headerTitle, size: 22)
                                        Text(headerTitle).lineLimit(1)
                                    }
                                    .fixedSize(horizontal: true, vertical: false)
                                } else if conversation.isIncognito {
                                    // Kept nowhere: said where the title goes, its words not used for one.
                                    Label(IncognitoNote.title, systemImage: "eyeglasses")
                                        .labelStyle(.titleAndIcon)
                                        .fixedSize(horizontal: true, vertical: false)
                                } else {
                                    TypedTitle(title: headerTitle, conversationID: conversation.id,
                                               isPlaceholder: !conversation.hasMessages && conversation.outbox.isEmpty)
                                }
                            }
                            .font(.headline)
                            .foregroundStyle(theme.textColor)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(headerTitle). Model: \(modelChipLabel)")
                        .accessibilityHint("Choose which model answers")
                        HStack(spacing: 4) {
                            if let projectName {
                                // Its own width, a long name cut short in words: a frame with a
                                // most width took all of it and pushed the model off the line.
                                HStack(spacing: 2) {
                                    Image(systemName: "folder.fill").font(.system(size: 9, weight: .semibold))
                                    Text(projectName.count > 16 ? projectName.prefix(15) + "…" : projectName)
                                        .font(.caption.weight(.medium)).lineLimit(1)
                                }
                                .foregroundStyle(chatTheme.accent)
                                .fixedSize()
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Project: \(projectName)")
                            }
                            Button { showModelPicker = true } label: {
                                HStack(spacing: 3) {
                                    // A bot's chat names the bot's handle, what another bot's chat tags it with.
                                    Text("\(conversation.bot.map { "@" + $0.handle } ?? conversation.elsewhere.map { profileTitle($0.profile) } ?? settings.headerTitle) · \(modelChipLabel)").font(.caption).lineLimit(1)
                                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                                }
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHidden(true)   // the line above says it, with the same action
                            if runsWithoutAsking {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel("Commands run without asking")
                                    .accessibilityHint("Change it in the model menu")
                            }
                            if let context = conversation.contextUsage {
                                ContextRing(used: context.used, window: context.window)
                            }
                        }
                    }
                    .frame(maxWidth: 240)
                    #if os(macOS)
                    .fixedSize()   // a Mac toolbar sizes an item to its ideal width: without, it clipped the title
                    #endif
                }
                #if os(macOS)
                .sharedBackgroundVisibility(.hidden)   // a window's title, not a button in a capsule
                #endif
                ToolbarItem(placement: .topBarLeading) {
                    if showListButton {
                        Button("Conversations", systemImage: "list.bullet") { setDrawer(open: true) }
                            .keyboardShortcut("k", modifiers: .command)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("Find in conversation", systemImage: "magnifyingglass") { withAnimation { showSearch.toggle() } }
                            .disabled(!conversation.hasMessages)
                        // A bot's chat goes by its bot.
                        if conversation.bot == nil, !conversation.isIncognito {
                            Button("Rename", systemImage: "pencil") {
                                renameText = conversation.name ?? conversation.title
                                showRename = true
                            }
                            .disabled(!conversation.hasMessages)
                        }
                        Button("Export as Markdown", systemImage: "square.and.arrow.up") {
                            if let url = try? TranscriptExporter.file(title: conversation.title, messages: conversation.messages) {
                                shareItem = ShareItem(url: url)
                            }
                        }
                        .disabled(!conversation.hasMessages)
                        // The Dashboard's projects, for a conversation on the server (a bot's chat is its bot's).
                        if settings.transport == .hermesServe, conversation.serverSessionID != nil, conversation.bot == nil, !conversation.isIncognito {
                            ChatProjectMenu(naming: $namingProject, problem: $projectProblem)
                        }
                        // (A bot added for the Hermes API alone has its settings and face on the Dashboard.)
                        if let bot = chatBot, !bot.viaAPI {
                            Button("Edit Bot…", systemImage: "slider.horizontal.3") { editingBot = bot }
                            Button("Change Face…", systemImage: "face.smiling") { facingBot = bot }
                        }
                        // The main agent's voice is the app's (asked 2026-10-25: "Sol's three dot drop
                        // down does not have voice in it").
                        if chatBot?.isDefault ?? (conversation.bot == nil) {
                            Button("Voice…", systemImage: "waveform") { voicingMain = true }
                        }
                        if let bot = chatBot, !bot.isDefault {
                            Button("Voice…", systemImage: "waveform") { voicingBot = bot }
                            if !bot.viaAPI {
                                Button("Schedules…", systemImage: "clock") { schedulingBot = bot }
                            }
                        }
                        if let bot = conversation.bot, !conversation.isIncognito {
                            MuteMenu(item: "bot:" + bot.profile)
                        }
                        // A bot's chat: Start Fresh has the toolbar's button, and a new conversation
                        // with the agent is here.
                        if conversation.bot != nil {
                            Button("New Conversation with \(settings.headerTitle)", systemImage: "square.and.pencil") { conversation.reset() }
                        }
                        if !conversation.isIncognito {
                            Button("New Incognito Chat", systemImage: "eyeglasses") { conversation.startIncognito() }
                                .keyboardShortcut("n", modifiers: [.command, .shift])
                        }
                        #if os(iOS)
                        if settings.transport.hasLedger {
                            Button("Terminal", systemImage: "apple.terminal") { showTerminal = true }
                        }
                        #endif
                        Divider()
                        Button("Settings", systemImage: "gearshape") { showSettings = true }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    #if os(macOS)
                    .menuStyle(.automatic)   // the toolbar's own button, beside the next (not the app's plain menus)
                    .menuIndicator(.hidden)
                    #endif
                    if conversation.bot != nil {
                        // A bot has one chat: a new one is that chat started over (asked first).
                        Button("Start Fresh", systemImage: "arrow.counterclockwise") { confirmingFresh = true }
                            .disabled(conversation.isStreaming || !conversation.hasMessages)
                    } else {
                        Button("New conversation", systemImage: "square.and.pencil") {
                            conversation.reset()
                        }
                        .disabled(!conversation.hasMessages && !conversation.isIncognito)
                        .keyboardShortcut("n", modifiers: .command)
                    }
                }
            }
            // A bot's colours, with Bot colors on: the transcript, the composer and the toolbar
            // above (not its sheets, which aren't the chat: `chatPresentations`).
            .environment(\.theme, chatTheme)
            .tint(chatTheme.accent)
            .onChange(of: BotDirectory.shared.roster) { _, roster in
                if let roster, BotDirectory.shared.key == settings.connectionKey { conversation.followBotName(in: roster, mainName: settings.headerTitle) }
            }
            #if os(iOS)
            .background { keyboardShortcuts }   // (the Mac's are in its menus: `chatCommands`)
            #endif
    }

    // MARK: - iPad detail pane

    /// What the sidebar's Chats / Cron / Kanban switcher picked: the chat, or the cron jobs or
    /// Kanban board at full width (a board wants the room). Kept across launches.
    @AppStorage(ConversationsList.sectionKey) private var section: ConversationsList.Tab = .sessions

    @ViewBuilder private var padDetail: some View {
        switch section {
        case .sessions:
            chatScreen(showListButton: false)
        case .cron:
            NavigationStack { CronView().navigationTitle("Cron").navigationBarTitleDisplayMode(.inline) }
                .id(settings.connectionKey)
        case .kanban:
            NavigationStack { KanbanView().navigationTitle("Kanban").navigationBarTitleDisplayMode(.inline) }
                .id(settings.connectionKey)
        case .made:
            NavigationStack {
                MadeView { id in
                    Task {
                        if let full = await ConversationStore.shared.loadRecord(id: id) { conversation.load(full) }
                        section = .sessions
                    }
                }
                .navigationTitle("Made").navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    // MARK: - iPhone conversation list

    #if os(iOS)
    /// iPhone: the chat, with the conversation list in a panel that slides in from the left.
    private var phoneLayout: some View {
        SidePanel(isOpen: $showConversations, openingFrom: $openingFromRow, openingTitle: headerTitle,
                  onOpening: { composerFocused = false }) {
            NavigationStack { chatScreen(showListButton: true) }
        } panel: {
            ConversationsView(isShowing: showConversations, onOpened: { conversationOpened() })
        }
    }
    #endif

    /// A conversation was opened from the list (or a new one started there). Picked from a row,
    /// it opens out of that row; otherwise, and under Reduce Motion, the list slides away.
    private func conversationOpened() {
        if showConversations, !reduceMotion, let tap = ConversationTap.take() {
            openingFromRow = tap
        } else {
            setDrawer(open: false)
        }
    }

    /// The layout changed under the chat (an iPhone Duo opened or closed, an iPad window drawn
    /// across the line). The list's tab was the panel's on the iPhone and is the wide layout's
    /// main column: Cron or Kanban open in the panel stay open full width, and the other way round;
    /// one only picked in a closed panel doesn't take the chat's place. The keyboard, if it was up,
    /// comes back in the composer the other layout has.
    private func layoutChanged(wide: Bool) {
        if wide {
            if !showConversations { section = .sessions }
            showConversations = false
            openingFromRow = nil
        } else if section != .sessions {
            showConversations = true
        }
        let typing = composerFocused || focusLostAt.map { Date.now.timeIntervalSince($0) < 0.5 } == true
        if typing, !showConversations {
            Task { try? await Task.sleep(for: .milliseconds(350)); composerFocused = true }
        }
    }

    private func setDrawer(open: Bool) {
        if open { composerFocused = false }
        withAnimation(.sidePanel) { showConversations = open }
    }

    /// Hardware-keyboard shortcuts (iPad, Mac). Zero-size buttons still receive key equivalents,
    /// and they show up in the ⌘ overlay with these titles.
    #if os(macOS)
    /// The iPad's keyboard shortcuts, as the Mac's menu bar has them (`ReddeCommands`).
    private var chatCommands: ChatCommands {
        ChatCommands(
            newConversation: { conversation.reset() },
            newIncognito: conversation.isIncognito ? nil : { conversation.startIncognito() },
            voice: { openVoice(fromOutside: false) },
            focusComposer: { composerFocused = true },
            chooseModel: { showModelPicker = true },
            find: conversation.hasMessages ? { withAnimation { showSearch.toggle() } } : nil,
            stop: conversation.isStreaming ? { conversation.cancel() } : nil,
            export: conversation.hasMessages ? {
                if let url = try? TranscriptExporter.file(title: conversation.title, messages: conversation.messages) { shareItem = ShareItem(url: url) }
            } : nil)
    }
    #endif

    private var keyboardShortcuts: some View {
        Group {
            Button("Settings") { showSettings = true }.keyboardShortcut(",", modifiers: .command)
            Button("Voice mode") { openVoice(fromOutside: false) }.keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Focus composer") { composerFocused = true }.keyboardShortcut("l", modifiers: .command)
            // ⌘N in a bot's chat, whose toolbar button is Start Fresh: a new conversation with the agent, as anywhere.
            Button("New conversation") { conversation.reset() }.keyboardShortcut("n", modifiers: .command).disabled(conversation.bot == nil)
            Button("Find in conversation") { withAnimation { showSearch.toggle() } }.keyboardShortcut("f", modifiers: .command)
                .disabled(!conversation.hasMessages)
            Button("Stop reply") { conversation.cancel() }.keyboardShortcut(".", modifiers: .command).disabled(!conversation.isStreaming)
            Button("Export as Markdown") {
                if let url = try? TranscriptExporter.file(title: conversation.title, messages: conversation.messages) { shareItem = ShareItem(url: url) }
            }
            .keyboardShortcut("e", modifiers: .command).disabled(!conversation.hasMessages)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        .disabled(showConversations)   // the chat is behind the iPhone's conversation list then
    }

    /// The folder a terminal opened from this chat starts in: the project a new conversation is
    /// starting in, else the session's working folder as the Dashboard lists it; home without one.
    private func terminalFolder() async -> String? {
        if let place = conversation.startsIn { return place.path }
        guard let id = conversation.serverSessionID, settings.serveBaseURL != nil else { return nil }
        return try? await HermesServeClient.shared.listSessions(limit: 200).first { $0.id == id }?.cwd?.nilIfEmpty
    }

    /// The header's first line: this conversation, or "New conversation" before the first message.
    private func saveRename() {
        let name = renameText
        Task {
            do { try await conversation.rename(to: name) } catch { renameError = error.localizedDescription }
        }
    }

    /// In a bot's chat, the bot as the roster has it (for its face, and whether it is the main one).
    private var chatBot: HermesBot? {
        guard let profile = conversation.bot?.profile, BotDirectory.shared.key == settings.connectionKey else { return nil }
        return BotDirectory.shared.roster?.bots.first { $0.name == profile }
    }

    /// In a bot's chat, the bot's face, as the chat list draws it.
    private var botFace: BotFace? {
        conversation.bot.map { bot in
            (BotDirectory.shared.key == settings.connectionKey ? BotDirectory.shared.roster?.faces[bot.profile] : nil) ?? BotFace(seed: bot.profile)
        }
    }

    /// The chat's colours: the theme's, or with Settings → Appearance → Bot colors on, the bot's,
    /// and Redde's in a chat with it when its face has a colour of its own. (A group chat isn't
    /// this screen, and keeps the theme's.)
    private var chatTheme: ResolvedTheme {
        guard settings.botColors, let colors = (botFace ?? BotDirectory.shared.mainFace).chatColors else { return theme }
        return settings.theme.resolved(with: colors)
    }

    /// Another profile's chat (opened with All Profiles on) says whose it is where the agent's
    /// name goes.
    private func profileTitle(_ name: String) -> String {
        ProfileCatalog.known(settings: settings).first { $0.name == name }?.title ?? name
    }

    private var headerTitle: String {
        if let bot = conversation.bot { return bot.name }
        if conversation.isIncognito { return IncognitoNote.title }
        return !conversation.hasMessages && conversation.outbox.isEmpty ? String(localized: "New conversation") : conversation.title
    }

    /// What the title chip shows: the picked model, or the backend's default.
    private var modelChipLabel: String {
        // A bot's chat runs on the bot's own model, as its profile says (unless picked here).
        if let bot = conversation.bot, settings.gatewayModel.isEmpty,
           let model = BotDirectory.shared.bots(for: settings.connectionKey).first(where: { $0.name == bot.profile })?.model {
            return model
        }
        return switch settings.transport {
        case .chatCompletions: settings.fastLaneModel.nilIfEmpty ?? String(localized: "model", comment: "Under the chat's title when no model is named")
        default: settings.gatewayModel.nilIfEmpty ?? String(localized: "default model", comment: "Under the chat's title: the server's own model")
        }
    }

    /// Voice mode as you'd open it by hand: Hands-free follows Settings → Voice.
    private func openVoice(fromOutside: Bool) {
        voiceSession.continuous = settings.handsFreeByDefault
        if fromOutside { startFreshForVoice() }
        showVoice = true
    }

    /// Settings → Voice → "New conversation in voice mode": coming into voice mode from outside
    /// the chat (Siri, the Action button, a control, opening Redde) starts one; the Talk button
    /// in a chat carries that chat on (GitHub issue 14). Before the screen appears, so the old
    /// conversation doesn't flash up. Not while a reply is still coming or a message waits to
    /// send, and not when this one is empty anyway. At a cold launch the last conversation may
    /// still be loading from disk: it counts, and the reset drops the load.
    private func startFreshForVoice() {
        guard settings.newConversationForVoice, !showVoice,
              !conversation.messages.isEmpty || conversation.initialLoad != nil,
              !conversation.isStreaming, conversation.outbox.isEmpty else { return }
        conversation.reset()
    }

    /// A share or a Siri draft asked for a conversation of its own (GitHub issue 21): one is
    /// started, and the composer is handed to it before the text comes in, or the text would stay
    /// behind as the draft of the one being left. Not when this one is empty anyway, and not on
    /// the fast lane while a reply streams: leaving would stop it (a Hermes turn goes on).
    private func startFreshForDraft() {
        guard !conversation.messages.isEmpty || conversation.initialLoad != nil || !conversation.outbox.isEmpty,
              !conversation.isStreaming || settings.transport.hasLedger else { return }
        conversation.reset()
        bindDraft(to: Drafts.key(for: conversation))
    }

    /// A reply came back whole: count it toward the rating prompt, and ask a moment later if it's
    /// due (see `ReviewPrompt`), but only with nothing else on screen and no reply running.
    private func replyFinished() {
        guard let last = conversation.messages.last, last.role == .assistant, last.error == nil,
              !last.text.isEmpty else { return }
        let prompt = ReviewPrompt()
        prompt.recordReply()
        #if DEBUG
        if DevHooks.screenshotRun { return }
        #endif
        let version = WhatsNew.currentVersion
        guard prompt.isDue(version: version) else { return }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !showVoice, !showConversations, !showSettings, !showSetup, !showModelPicker, whatsNew == nil,
                  !lock.isLocked, !conversation.isStreaming, scenePhase == .active else { return }
            prompt.markAsked(version: version)
            requestReview()
        }
    }

    /// Items handed over by the share extension become the draft and pending attachments, of a
    /// new conversation if the share sheet said so.
    private func consumeSharedItems() {
        guard !lock.isLocked else { return }
        Task {
            // The inbox decodes off the main actor; the lock can have engaged meanwhile.
            guard let payload = await ShareInbox.takePending(), !payload.isEmpty, !lock.isLocked else { return }
            showVoice = false
            setDrawer(open: false)   // the composer is under the conversation list
            if payload.newConversation == true { startFreshForDraft() }
            let text = payload.draft
            if !text.isEmpty { draft = draft.isEmpty ? text : draft + "\n\n" + text }
            pendingAttachments += payload.attachments
            composerFocused = true
        }
    }

    /// Siri AI's "draft a message": the text lands in the open conversation's composer, or a new
    /// conversation's with "Drafts in a new conversation". (And a quote to ask about, in its own.)
    private func handleDraftRequest() {
        guard !lock.isLocked, let request = router.consumeDraftRequest() else { return }
        showVoice = false
        setDrawer(open: false)   // the composer is under the conversation list
        if request.newConversation { startFreshForDraft() }
        if !request.text.isEmpty { draft = draft.isEmpty ? request.text : draft + "\n\n" + request.text }
        pendingAttachments += request.attachments
        composerFocused = true
    }

    /// From a paired Hermes's notifications: a pairing link that was opened, confirmed in a sheet
    /// of its own (over the conversation, so other sheets make way as for a setup code), and a
    /// tapped notification's conversation, fetched from the server and shown.
    private func handlePushRequests() {
        guard !lock.isLocked else { return }
        if let offer = router.consumePushOffer() {
            let covered = showSetup || showSettings || showModelPicker || whatsNew != nil || showVoice || setupCode != nil
            showSetup = false
            showSettings = false
            showModelPicker = false
            whatsNew = nil
            Task {
                if covered { try? await Task.sleep(for: .milliseconds(600)) }
                pushOffer = offer
            }
        }
        if let session = router.consumeSession(), !conversation.isStreaming {
            if sizeClass != .regular, showConversations { setDrawer(open: false) }
            // Also when it is the conversation already on screen: what is here may be from before
            // the app was closed, without the reply or the question the notification is about.
            // A conversation on another server than the one the app is on can't be fetched: the
            // app then stays where it was.
            Task { try? await conversation.open(serverSession: session) }
        }
        if let profile = router.consumeBot(), !conversation.isStreaming {
            if sizeClass != .regular, showConversations { setDrawer(open: false) }
            // Its chat, where the schedule's answer is; read again first when the app was started for it.
            Task {
                let bots = BotDirectory.shared
                if !bots.bots(for: settings.connectionKey).contains(where: { $0.name == profile }) { _ = try? await bots.refresh() }
                guard let bot = bots.bots(for: settings.connectionKey).first(where: { $0.name == profile }) else { return }
                GroupDirectory.shared.open = nil
                try? await conversation.openBot(bot, mainName: settings.headerTitle)
            }
        }
        if let room = router.consumeRoom() {
            if sizeClass != .regular, showConversations { setDrawer(open: false) }
            // In the chat's place, as from the list; read again first when the app was started
            // for it. A room on another server than the one the app is on isn't there: it stays.
            Task {
                let groups = GroupDirectory.shared
                if !groups.rooms.contains(where: { $0.id == room }) { await groups.refresh() }
                if let found = groups.rooms.first(where: { $0.id == room }) { groups.open = found }
            }
        }
    }

    /// A setup link was opened: its confirmation comes up over the conversation, so whatever
    /// sheet is up makes way first (a second sheet can't present over one). Nothing is saved
    /// until the person agrees there.
    private func handleSetupCode() {
        guard !lock.isLocked, let offer = router.consumeSetupCode() else { return }
        let covered = showSetup || showSettings || showModelPicker || whatsNew != nil || showVoice || setupCode != nil
        guard covered else {
            setupCode = offer
            return
        }
        showSetup = false
        showSettings = false
        showModelPicker = false
        whatsNew = nil
        showVoice = false
        setupCode = nil
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            setupCode = offer
        }
    }

    /// Siri / Action Button entry: open voice mode and start listening at once.
    /// A control (Action Button, Control Center, Lock Screen) asked for voice via the App Group.
    private func consumeControlRequest() {
        if let handsFree = LaunchFlag.consumeVoice() { router.requestVoice(handsFree: handsFree) }
        if LaunchFlag.consumeCapture() { router.requestCapture() }
    }

    /// Quick capture's control: the voice screen opens listening for a note. The conversation is
    /// left as it is: no new one is started, and a reply under way carries on.
    private func handleCaptureRequest() {
        guard !lock.isLocked, router.consumeCaptureRequest() else { return }
        Task {
            if !showVoice {
                if let shown = whatsNew {
                    deferredWhatsNew = shown
                    whatsNew = nil
                    try? await Task.sleep(for: .milliseconds(450))
                }
                showVoice = true
                // Let the cover present before the audio session and mic spin up.
                try? await Task.sleep(for: .milliseconds(400))
            }
            voiceSession.beginListening(capturing: true)
        }
    }

    private func handleLaunchRequest() {
        guard !lock.isLocked, let request = router.consumeVoiceRequest() else { return }
        Logger(subsystem: "com.goosehouse.echo", category: "intent").info("UI consuming voice request handsFree=\(request.handsFree)")
        // "Ask Claude in Redde": on the Dashboard, a bot is talked to in its own chat; else (and
        // for the main profile) the app moves to that profile first. Here and not in the intent,
        // so it waits for the app lock like the listening does. A name the phone doesn't know
        // changes nothing.
        guard let asked = request.profile else {
            Task { await launchVoice(handsFree: request.handsFree, fromOutside: true) }
            return
        }
        Task {
            if conversation.bot?.profile != asked {
                if showVoice { voiceSession.cancel() }   // what voice mode was saying in another chat is over
                do {
                    if try await conversation.openBot(asked: asked, mainName: settings.headerTitle) != nil {
                        // In the bot's chat now: carry on in it, never a fresh conversation.
                        await launchVoice(handsFree: request.handsFree, fromOutside: false)
                        return
                    }
                } catch {
                    Logger(subsystem: "com.goosehouse.echo", category: "intent").error("couldn't open the bot's chat: \(error.localizedDescription)")
                }
            } else {
                await launchVoice(handsFree: request.handsFree, fromOutside: false)
                return
            }
            if let profile = ProfileCatalog.find(asked, in: ProfileCatalog.known()), ProfileCatalog.use(profile, conversation: conversation), showVoice {
                voiceSession.cancel()   // voice mode was open on the other profile: what it was saying is over
            }
            await launchVoice(handsFree: request.handsFree, fromOutside: true)
        }
    }

    /// A wake phrase was heard (`WakeListener`): voice mode in its agent's chat, the chat on screen
    /// carried on when it is that agent's (as the Talk button does), with what was said after the
    /// phrase asked at once. The main agent from a bot's chat: its own bot chat where there are
    /// bots (where a spoken prefix takes it), else a new conversation.
    private func handleWake() {
        guard !lock.isLocked, let wake = router.consumeWake() else { return }
        Task {
            #if os(iOS)
            defer { WakeListener.shared.release(.handoff) }
            #endif
            let here = conversation.bot?.profile
            let there = wake.profile.map { here == $0 } ?? (here == nil || here == "default")
            if !there {
                if showVoice { voiceSession.cancel() }   // what voice mode was saying in another chat is over
                do {
                    if let profile = wake.profile {
                        guard try await conversation.goToBot(profile, mainName: settings.headerTitle) else {
                            Logger(subsystem: "com.goosehouse.echo", category: "wake").error("no bot \(profile, privacy: .public) to wake here")
                            return
                        }
                    } else if try await !conversation.goToBot("default", mainName: settings.headerTitle) {
                        conversation.reset()
                    }
                } catch {
                    Logger(subsystem: "com.goosehouse.echo", category: "wake").error("couldn't open the woken agent's chat: \(error.localizedDescription)")
                    return
                }
            }
            await launchVoice(handsFree: settings.handsFreeByDefault, fromOutside: false, asking: wake.asking)
        }
    }

    /// An agent's call was answered (`AgentCalls`): voice mode runs in its chat already, and its
    /// screen comes up once Redde is in front and unlocked.
    private func handleCallScreen() {
        guard !lock.isLocked, scenePhase == .active, router.pendingCallScreen else { return }
        _ = router.consumeCallScreen()
        guard !showVoice else { return }
        // A cover can't present over a sheet: the sheet goes first.
        let covered = showSettings || whatsNew != nil
        if let shown = whatsNew {
            deferredWhatsNew = shown
            whatsNew = nil
        }
        showSettings = false
        Task {
            if covered { try? await Task.sleep(for: .milliseconds(500)) }
            showVoice = true
        }
    }

    /// Voice mode asked for in a specific mode (the Talk button, Siri, a control): that mode wins
    /// over the Settings default. `fromOutside`: not from a button in the chat. `asking`: asked at
    /// once instead of listening (`VoiceSession.ask`).
    private func launchVoice(handsFree: Bool, fromOutside: Bool, asking: String? = nil) async {
        voiceSession.continuous = handsFree
        if !showVoice {
            if fromOutside { startFreshForVoice() }
            if let shown = whatsNew {
                // A cover can't present over the sheet; without this, voice silently never opened.
                deferredWhatsNew = shown
                whatsNew = nil
                try? await Task.sleep(for: .milliseconds(450))
            }
            showVoice = true
            // Let the cover present before the audio session and mic spin up.
            try? await Task.sleep(for: .milliseconds(400))
        }
        if let asking { voiceSession.ask(asking) } else { voiceSession.beginListening() }
    }

    #if DEBUG
    /// The launch hooks that open this view's own sheets or fill its composer; the rest live in
    /// `DevHooks` (see there for every flag).
    /// `-echo.tour` (with `-echo.hitches`): what people do in the app, done by the app itself, each
    /// step measured (`FrameMonitor.report`): a new conversation, the composer focused, a question
    /// typed and sent and its reply streamed and scrolled through as it streams (from the fast
    /// lane: `scripts/smooth-model.py`), the list opened and closed, the long thread opened from
    /// it, a short one, the long one again, voice
    /// mode opened and closed, Settings opened and closed. Start it on a long thread
    /// (`-echo.demoHeavy`) with others in the list (`-echo.demoLibrary`).
    private func runTour() async {
        let monitor = FrameMonitor.shared
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        let long = conversation.id
        let store = ConversationStore.shared
        let short = store.summaries.filter { $0.id != long }.min { $0.turnCount < $1.turnCount }?.id
        func open(_ id: UUID?) async {
            guard let id, let full = await store.loadRecord(id: id) else { return }
            conversation.load(full)
            conversationOpened()
        }
        // `-echo.tour device`, on someone's own phone: nothing is sent and no setting is changed;
        // what is typed is cleared again. Otherwise a question goes first, on the fast lane the
        // launch names (settings synced from elsewhere can have put another there), and before
        // the long thread, a Hermes session, is opened.
        let mode = DevHooks.value("-echo.tour")
        let sends = mode != "device"
        if sends, let lane = DevHooks.value("-fastLaneURL") { settings.fastLaneURL = lane; settings.transport = .chatCompletions }
        await monitor.report("tour: new conversation") { conversation.reset(); await wait(1) }
        await monitor.report("tour: focus the composer") { composerFocused = true; await wait(1.5) }
        let unsent = draft   // a draft of the person's own, put back after
        let field = FrameMonitor.focusedTextInput()
        await monitor.report("tour: type") {
            for character in "Plan a hike for Saturday morning, with what to bring." {
                if let field { field.insertText(String(character)) } else { draft.append(character) }
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
        if sends {
            await monitor.report("tour: send") {
                conversation.send("Plan a hike for Saturday morning, with what to bring.")
                draft = ""
                await wait(1)
            }
            await monitor.report("tour: thinking") { await wait(3) }
            await monitor.report("tour: streaming") { await wait(4) }
            await monitor.report("tour: scroll while streaming") { monitor.autoScroll(for: 3); await wait(3.2) }
            await monitor.report("tour: streaming to the end") {
                for _ in 0 ..< 600 where conversation.isStreaming { await wait(0.1) }
            }
            // Another in the same launch: a reply's start once the app has drawn one already.
            await monitor.report("tour: send again") {
                conversation.send("And if it rains?")
                await wait(1)
            }
            await monitor.report("tour: second reply") {
                for _ in 0 ..< 600 where conversation.isStreaming { await wait(0.1) }
            }
        } else {
            draft = unsent
        }
        await monitor.report("tour: dismiss the keyboard") { composerFocused = false; await wait(1) }
        // `-echo.tour send`: only as far as the reply.
        if mode == "send" { await monitor.report("tour: done") {}; return }
        await monitor.report("tour: open the list") { setDrawer(open: true); await wait(1) }
        await monitor.report("tour: close the list") { setDrawer(open: false); await wait(1) }
        setDrawer(open: true); await wait(1)
        await monitor.report("tour: open the long one from the list") { await open(long); await wait(1.5) }
        setDrawer(open: true); await wait(1)
        await monitor.report("tour: open a short conversation from the list") { await open(short); await wait(1.5) }
        await monitor.report("tour: back to the long one") { await open(long); await wait(1.5) }
        await monitor.report("tour: scroll the long one") { monitor.autoScroll(for: 4); await wait(4.3) }
        await monitor.report("tour: open voice mode") { openVoice(fromOutside: false); await wait(2) }
        await monitor.report("tour: close voice mode") { showVoice = false; await wait(1.5) }
        await monitor.report("tour: open Settings") { showSettings = true; await wait(1.5) }
        await monitor.report("tour: close Settings") { showSettings = false; await wait(1.5) }
        await monitor.report("tour: done") {}
        if !sends {
            // Left as it was found: the conversations the launch's demo hooks made go again.
            for made in store.summaries where !DevHooks.conversationsAtLaunch.contains(made.id) { conversation.delete(id: made.id) }
            if !DevHooks.conversationsAtLaunch.contains(conversation.id) { conversation.reset() }
        }
    }

    private func applyDevHooks() {
        DevHooks.applyAtLaunch(conversation: conversation, settings: settings)
        if DevHooks.has("-echo.tour") {
            Task { try? await Task.sleep(for: .seconds(6)); await runTour() }
        }
        if DevHooks.has("-echo.clearDrafts") {
            draft = ""
            pendingAttachments = []
        }
        switch DevHooks.value("-echo.screen") {
        case "settings": showSettings = true
        case "sessions": showConversations = true
        case "setup": showSetup = true
        case "profiles": showProfilePicker = true
        case "servers": showServers = true
        case "model": showModelPicker = true
        case "tips": showTips = true
        case "push": showPush = true
        case "gateway": showGateway = true
        case "files": showFiles = true
        #if DEBUG
        case "botGallery": showBotGallery = true
        case "patch": showDemoPatch = true
        #endif
        default: break
        }
        if let text = DevHooks.value("-echo.draft") {
            draft = text
            Task { try? await Task.sleep(for: .milliseconds(450)); composerFocused = true }
        }
        if let text = DevHooks.value("-echo.autoType") {
            Task {
                try? await Task.sleep(for: .seconds(6))
                composerFocused = true
                try? await Task.sleep(for: .seconds(1.5))
                // Into the focused field, as the keyboard puts it there: set from outside, the
                // text would go back into the field on every letter, which typing never does.
                let field = FrameMonitor.focusedTextInput()
                await FrameMonitor.shared.report("autotype") {
                    for character in text {
                        if let field { field.insertText(String(character)) } else { draft.append(character) }
                        try? await Task.sleep(for: .milliseconds(90))
                    }
                }
            }
        }
        if let link = DevHooks.value("-echo.setupCode"), let url = URL(string: link), let offer = SetupCodeOffer(url: url) {
            router.requestSetup(offer)
        }
        if let link = DevHooks.value("-echo.pushLink"), let url = URL(string: link), let offer = PushOffer(url: url) {
            router.requestPushPairing(offer)
        }
        if DevHooks.has("-echo.fresh") { conversation.reset() }
        // Arriving as from the share sheet and from Siri, once the launch has settled.
        let share = DevHooks.value("-echo.share").map { ($0, false) } ?? DevHooks.value("-echo.shareNew").map { ($0, true) }
        let siriDraft = DevHooks.value("-echo.siriDraft")
        if share != nil || siriDraft != nil {
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                if let share {
                    try? ShareInbox.write(ShareInbox.Payload(note: "", text: share.0, urls: [], attachments: [], createdAt: .now, newConversation: share.1))
                    consumeSharedItems()
                }
                if let siriDraft {
                    router.requestDraft(text: siriDraft, attachments: [], newConversation: settings.siriDraftsInNewConversation)
                }
            }
        }
        if let text = DevHooks.value("-echo.ask") {
            Task { try? await Task.sleep(for: .milliseconds(800)); conversation.send(text) }
        }
    }
    #endif

    /// "What's New" once per version after an update. A fresh install goes through setup and
    /// starts out current. While the app is locked, in voice mode or answering Siri it waits, and
    /// comes up once that's over (unlock and closing voice mode call this again).
    private func presentWhatsNewIfDue() {
        guard whatsNew == nil else { return }
        if let deferred = deferredWhatsNew {
            guard !showVoice, !lock.isLocked else { return }
            whatsNew = deferred
            deferredWhatsNew = nil
            return
        }
        let current = WhatsNew.currentVersion
        let isNewInstall = !settings.setupDone && !settings.isConfigured
        #if DEBUG
        if DevHooks.has("-echo.whatsNew") { whatsNew = WhatsNew.highlights(of: current); return }
        if DevHooks.screenshotRun { return }   // App Store captures must not get a sheet on top
        #endif
        if isNewInstall { WhatsNew.markSeen(current); return }
        guard !lock.isLocked, !showVoice, router.pendingVoice == nil, !showSetup else { return }
        whatsNew = WhatsNew.pending(lastSeen: WhatsNew.lastSeen, current: current, isNewInstall: false)
        // Once shown it counts as seen, even if the app is quit before Continue.
        if whatsNew != nil { WhatsNew.markSeen(current) }
    }

    /// Download the on-device speech model early so the first voice turn isn't slow.
    private func warmSpeechAssets() async {
        try? await SpeechRecognizer().prepareAssets()
    }

    /// The project this conversation is in, on the Dashboard: as the server last said, or for a
    /// new one, the project it is about to start in.
    private var projectName: String? {
        guard settings.transport == .hermesServe else { return nil }
        if let said = ChatControlStore.shared.project(for: conversation.serverSessionID) { return said.name }
        return conversation.startsIn?.name
    }

    /// This conversation runs its commands without asking (the model menu's switch, or the
    /// server's own setting): worth a mark that stays in sight.
    private var runsWithoutAsking: Bool {
        var session = conversation.connection == .hermesServe ? conversation.serverSessionID : nil
        #if DEBUG
        if DevHooks.demoChatControls { session = DemoChatControls.session }
        #endif
        return ChatControlStore.shared.controls(for: session)?.autoApprove == true
    }

    /// The composer now belongs to the conversation `key` names: its draft comes in, and the one
    /// that was there stays behind under its own conversation.
    private func bindDraft(to key: String) {
        let drafts = Drafts.shared
        if draftConversation == conversation.id, draftKey == Drafts.newConversation, key != draftKey {
            // The same conversation, now with its first message: what is typed stays with it.
            drafts.forget(draftKey)
            drafts.set(text: draft, for: key)
            drafts.set(attachments: pendingAttachments, for: key)
        } else if draftConversation != nil {
            // Another conversation. (Not what an edit put in the field: what was there before it.)
            let leaving = draftBeforeEditing ?? (draft, pendingAttachments)
            draftBeforeEditing = nil
            // (A conversation that was just deleted takes its draft with it.)
            if draftKey == Drafts.newConversation || conversation.storeForContext.summaries.contains(where: { $0.id.uuidString == draftKey }) {
                drafts.set(text: leaving.text, for: draftKey)
                drafts.set(attachments: leaving.attachments, for: draftKey)
            } else {
                drafts.forget(draftKey)
            }
            draft = drafts.text(for: key)
            pendingAttachments = drafts.attachments(for: key)
        } else {
            // Launch: whatever arrived before this (a share, a dev hook) goes in front of the draft.
            let saved = drafts.text(for: key)
            if !saved.isEmpty { draft = draft.isEmpty ? saved : draft + "\n\n" + saved }
        }
        draftKey = key
        draftConversation = conversation.id
    }

    /// A message that hadn't been sent comes back into the composer to be changed and sent again.
    private func editQueued(_ message: Message) {
        editing = nil
        draft = message.text
        pendingAttachments = message.attachments
        composerFocused = true
    }

    /// Loads a sent message back into the composer; nothing changes until it is sent again.
    private func beginEditing(_ message: Message) {
        if editing == nil { draftBeforeEditing = (draft, pendingAttachments) }
        editing = message
        draft = message.text
        pendingAttachments = message.attachments
        composerFocused = true
    }
}

/// Keeps the composer's draft for its conversation as it is typed (`Drafts`). A view of its own,
/// handed the draft as a binding, so that a key pressed evaluates only it (and the composer)
/// again: read in the chat screen's body, the draft had the whole screen, the transcript and the
/// hidden conversation list with it, evaluated again on every letter.
private struct DraftKeeper: View {
    @Binding var draft: String
    @Binding var attachments: [Attachment]
    let key: String
    /// Edit & resend has the composer: what it holds isn't the draft.
    let editing: Bool

    var body: some View {
        Color.clear
            .onChange(of: draft) { if !editing { Drafts.shared.set(text: draft, for: key) } }
            .onChange(of: attachments) { if !editing { Drafts.shared.set(attachments: attachments, for: key) } }
    }
}
