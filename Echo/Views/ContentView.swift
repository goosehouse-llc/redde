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
    @State private var showSettings = false
    @State private var shareItem: ShareItem?
    /// Rename, from the header's menu.
    @State private var showRename = false
    @State private var renameText = ""
    @State private var renameError: String?
    @State private var showSetup = false
    @State private var showConversations = false
    /// What's New was up when voice mode was asked for: voice wins, and it comes back after.
    @State private var deferredWhatsNew: WhatsNew.Release?
    @State private var showVoice = false
    @State private var showSearch = false
    @State private var showModelPicker = false
    /// "Edit & resend": the message being replaced; sending truncates the transcript from it.
    @State private var editing: Message?
    @State private var pendingAttachments: [Attachment] = []
    @FocusState private var composerFocused: Bool
    /// The update's highlights, shown once per version.
    @State private var whatsNew: WhatsNew.Release?
    #if DEBUG
    /// Dev hook: `-echo.screen profiles` opens the profile picker (screenshots, live tests).
    @State private var showProfilePicker = false
    @State private var showTips = false
    @State private var showServers = false
    #endif

    var body: some View {
        Group {
            if sizeClass == .regular {
                // iPad: sessions in the sidebar, transcript in the detail column.
                NavigationSplitView {
                    // The stack is what lets a project folder push its session list *inside*
                    // the sidebar. Without it the NavigationLink has nowhere to go: the row
                    // does nothing and there is no back button to escape with.
                    NavigationStack {
                        ConversationsList(wideDetail: true)
                    }
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
                } detail: {
                    padDetail
                }
            } else {
                phoneLayout
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: { WatchLink.shared.push() }) { SettingsView() }
        .sheet(isPresented: $showModelPicker) { NavigationStack { ModelPickerView() }.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showSetup, onDismiss: { WatchLink.shared.push() }) { SetupView() }
        .sheet(item: $whatsNew) { WhatsNewView(release: $0) }
        #if DEBUG
        .sheet(isPresented: $showProfilePicker) { NavigationStack { ProfilePickerView() } }
        .sheet(isPresented: $showTips) { NavigationStack { TipJarView() } }
        .sheet(isPresented: $showServers) { NavigationStack { ServersView() } }
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
            .environment(\.theme, theme)
            .tint(theme.accent)
        }
        .task {
            settings.applyLocalDefaultsIfPresent()
            if !settings.setupDone, !settings.isConfigured { showSetup = true }
            #if DEBUG
            applyDevHooks()
            #endif
            // Download the speech model early so the first voice turn isn't slow. In the background:
            // it can take a while (and never arrives in the simulator), and opening the voice
            // screen below must not wait on it. (It sat inside the DEBUG block from 2026-09-11,
            // so release builds skipped it.)
            Task { await warmSpeechAssets() }
            if Settings.shared.openToVoiceScreen, router.pendingVoice == nil, !showVoice { openVoice() }
            // "When Redde opens: Conversations": the iPhone's panel starts out, on its last tab. (On
            // iPad the list is always beside the chat.) A Siri or control request still wins.
            if settings.launchScreen == .conversations, sizeClass != .regular, router.pendingVoice == nil, !showVoice {
                showConversations = true
            }
            // After the voice screen may have opened: then it waits until that closes.
            presentWhatsNewIfDue()
            #if DEBUG
            if DevHooks.has("-echo.voiceView") { openVoice() }
            if DevHooks.has("-echo.autoVoice") { await launchVoice(handsFree: false) }
            #endif
        }
        .onOpenURL { url in
            // Control Center / Lock Screen controls open the app through echo://listen.
            if let handsFree = EchoURL.parseListen(url) { router.requestVoice(handsFree: handsFree) }
            if url.scheme == EchoURL.scheme, url.host == "share" { consumeSharedItems() }
        }
        .onAppear { consumeControlRequest(); handleLaunchRequest(); handleDraftRequest() }
        .onChange(of: router.pendingVoice) { handleLaunchRequest() }
        .onChange(of: router.pendingDraft) { handleDraftRequest() }
        .onChange(of: lock.isLocked) { _, locked in
            // A Siri / control / share request that arrived while locked runs once unlocked.
            if !locked { consumeControlRequest(); handleLaunchRequest(); consumeSharedItems(); handleDraftRequest() }
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
        .onChange(of: conversation.id) {
            // A fresh conversation: have llama-swap load its model before the first message.
            if conversation.messages.isEmpty { ModelWarmer.warm(conversation) }
            editing = nil
            ReadState.markConversationRead(conversation.id)   // on screen = read, for Siri
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
            HermesServeClient.shared.reconnectIfNeeded()
            ModelWarmer.warm(conversation)
            conversation.retryOutbox()   // back in the foreground: try anything still waiting to send
            consumeSharedItems()
            guard Settings.shared.listenOnOpen, router.pendingVoice == nil, !voiceSession.mightBeBusy else { return }
            Task { await launchVoice(handsFree: showVoice ? voiceSession.continuous : settings.handsFreeByDefault) }
        }
    }

    private func transcriptScreen(showListButton: Bool) -> some View {
        TranscriptView(showSetup: $showSetup, showSearch: $showSearch, onEdit: beginEditing, onEditQueued: editQueued)
            .background(theme.background ?? Color(.systemBackground))
            .foregroundStyle(theme.text ?? Color.primary)
            .safeAreaInset(edge: .bottom) {
                ComposerView(draft: $draft, pendingAttachments: $pendingAttachments, editing: $editing,
                             focused: $composerFocused,
                             openHandsFree: { Task { await launchVoice(handsFree: settings.handsFreeByDefault) } },
                             openModelPicker: { showModelPicker = true })
                    .frame(maxWidth: 820).frame(maxWidth: .infinity)
                    // Solid themes have no glass field to hide the transcript scrolling past the composer.
                    .background(theme.usesGlass ? AnyShapeStyle(.clear) : AnyShapeStyle(theme.background ?? Color(.systemBackground)))
            }
            .navigationTitle(headerTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The conversation on top; the agent and model beneath, tap to pick the model —
                // the /model sheet without typing /model.
                ToolbarItem(placement: .principal) {
                    Button { showModelPicker = true } label: {
                        VStack(spacing: 1) {
                            TypedTitle(title: headerTitle, conversationID: conversation.id,
                                       isPlaceholder: !conversation.hasMessages && conversation.outbox.isEmpty)
                                .font(.headline)
                                .foregroundStyle(theme.text ?? Color.primary)
                            HStack(spacing: 3) {
                                Text("\(settings.headerTitle) · \(modelChipLabel)").font(.caption).lineLimit(1)
                                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 220)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(headerTitle). Model: \(modelChipLabel)")
                    .accessibilityHint("Choose which model answers")
                }
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
                        Button("Rename", systemImage: "pencil") {
                            renameText = conversation.name ?? conversation.title
                            showRename = true
                        }
                        .disabled(!conversation.hasMessages)
                        Button("Export as Markdown", systemImage: "square.and.arrow.up") {
                            if let url = try? TranscriptExporter.file(title: conversation.title, messages: conversation.messages) {
                                shareItem = ShareItem(url: url)
                            }
                        }
                        .disabled(!conversation.hasMessages)
                        Divider()
                        Button("Settings", systemImage: "gearshape") { showSettings = true }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    Button("New conversation", systemImage: "square.and.pencil") {
                        conversation.reset()
                    }
                    .disabled(!conversation.hasMessages)
                    .keyboardShortcut("n", modifiers: .command)
                }
            }
            .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
            .alert("Rename conversation", isPresented: $showRename) {
                TextField("Name", text: $renameText)
                    // Return on the keyboard saves, like the button.
                    .onSubmit { showRename = false; saveRename() }
                Button("Save") { saveRename() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(conversation.serverSessionID == nil ? "Leave it empty to go back to the first question."
                                                         : "The session is renamed on your server too.")
            }
            .alert("Couldn't rename", isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(renameError ?? "")
            }
            .background { keyboardShortcuts }
    }

    // MARK: - iPad detail pane

    /// What the sidebar's Chats / Cron / Kanban switcher picked: the chat, or the cron jobs or
    /// Kanban board at full width (a board wants the room). Kept across launches.
    @AppStorage(ConversationsList.sectionKey) private var section: ConversationsList.Tab = .sessions

    @ViewBuilder private var padDetail: some View {
        switch section {
        case .sessions:
            transcriptScreen(showListButton: false)
        case .cron:
            NavigationStack { CronView().navigationTitle("Cron").navigationBarTitleDisplayMode(.inline) }
                .id(settings.connectionKey)
        case .kanban:
            NavigationStack { KanbanView().navigationTitle("Kanban").navigationBarTitleDisplayMode(.inline) }
                .id(settings.connectionKey)
        }
    }

    // MARK: - iPhone conversation list

    /// iPhone: the chat, with the conversation list in a panel that slides in from the left.
    private var phoneLayout: some View {
        SidePanel(isOpen: $showConversations, onOpening: { composerFocused = false }) {
            NavigationStack { transcriptScreen(showListButton: true) }
        } panel: {
            ConversationsView(isShowing: showConversations, onOpened: { setDrawer(open: false) })
        }
    }

    private func setDrawer(open: Bool) {
        if open { composerFocused = false }
        withAnimation(.sidePanel) { showConversations = open }
    }

    /// Hardware-keyboard shortcuts (iPad, Mac). Zero-size buttons still receive key equivalents,
    /// and they show up in the ⌘ overlay with these titles.
    private var keyboardShortcuts: some View {
        Group {
            Button("Settings") { showSettings = true }.keyboardShortcut(",", modifiers: .command)
            Button("Voice mode") { openVoice() }.keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Focus composer") { composerFocused = true }.keyboardShortcut("l", modifiers: .command)
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

    /// The header's first line: this conversation, or "New conversation" before the first message.
    private func saveRename() {
        let name = renameText
        Task {
            do { try await conversation.rename(to: name) } catch { renameError = error.localizedDescription }
        }
    }

    private var headerTitle: String {
        !conversation.hasMessages && conversation.outbox.isEmpty ? "New conversation" : conversation.title
    }

    /// What the title chip shows: the picked model, or the backend's default.
    private var modelChipLabel: String {
        switch settings.transport {
        case .chatCompletions: settings.fastLaneModel.nilIfEmpty ?? "model"
        default: settings.gatewayModel.nilIfEmpty ?? "default model"
        }
    }

    /// Voice mode as you'd open it by hand: Hands-free follows Settings → Voice.
    private func openVoice() {
        voiceSession.continuous = settings.handsFreeByDefault
        startFreshForVoice()
        showVoice = true
    }

    /// Settings → Voice → "New conversation in voice mode": every way into voice mode starts one,
    /// before the screen appears so the old conversation doesn't flash up. Not while a reply is
    /// still coming or a message waits to send, and not when this one is empty anyway. At a cold
    /// launch (Siri, the Action button) the last conversation may still be loading from disk: it
    /// counts, and the reset drops the load.
    private func startFreshForVoice() {
        guard settings.newConversationForVoice, !showVoice,
              !conversation.messages.isEmpty || conversation.initialLoad != nil,
              !conversation.isStreaming, conversation.outbox.isEmpty else { return }
        conversation.reset()
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

    /// Items handed over by the share extension become the draft and pending attachments.
    private func consumeSharedItems() {
        guard !lock.isLocked else { return }
        Task {
            // The inbox decodes off the main actor; the lock can have engaged meanwhile.
            guard let payload = await ShareInbox.takePending(), !payload.isEmpty, !lock.isLocked else { return }
            showVoice = false
            setDrawer(open: false)   // the composer is under the conversation list
            let text = payload.draft
            if !text.isEmpty { draft = draft.isEmpty ? text : draft + "\n\n" + text }
            pendingAttachments += payload.attachments
            composerFocused = true
        }
    }

    /// Siri AI's "draft a message": the text lands in the open conversation's composer.
    private func handleDraftRequest() {
        guard !lock.isLocked, let request = router.consumeDraftRequest() else { return }
        showVoice = false
        setDrawer(open: false)   // the composer is under the conversation list
        if !request.text.isEmpty { draft = draft.isEmpty ? request.text : draft + "\n\n" + request.text }
        pendingAttachments += request.attachments
        composerFocused = true
    }

    /// Siri / Action Button entry: open voice mode and start listening at once.
    /// A control (Action Button, Control Center, Lock Screen) asked for voice via the App Group.
    private func consumeControlRequest() {
        if let handsFree = LaunchFlag.consumeVoice() { router.requestVoice(handsFree: handsFree) }
    }

    private func handleLaunchRequest() {
        guard !lock.isLocked, let request = router.consumeVoiceRequest() else { return }
        Logger(subsystem: "com.goosehouse.echo", category: "intent").info("UI consuming voice request handsFree=\(request.handsFree)")
        Task { await launchVoice(handsFree: request.handsFree) }
    }

    /// Voice mode asked for in a specific mode (the hands-free button, Siri, a control): that mode
    /// wins over the Settings default.
    private func launchVoice(handsFree: Bool) async {
        voiceSession.continuous = handsFree
        if !showVoice {
            startFreshForVoice()
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
        voiceSession.beginListening()
    }

    #if DEBUG
    /// The launch hooks that open this view's own sheets or fill its composer; the rest live in
    /// `DevHooks` (see there for every flag).
    private func applyDevHooks() {
        DevHooks.applyAtLaunch(conversation: conversation, settings: settings)
        switch DevHooks.value("-echo.screen") {
        case "settings": showSettings = true
        case "sessions": showConversations = true
        case "setup": showSetup = true
        case "profiles": showProfilePicker = true
        case "servers": showServers = true
        case "model": showModelPicker = true
        case "tips": showTips = true
        default: break
        }
        if let text = DevHooks.value("-echo.draft") {
            draft = text
            Task { try? await Task.sleep(for: .milliseconds(450)); composerFocused = true }
        }
        if DevHooks.has("-echo.fresh") { conversation.reset() }
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
        if DevHooks.has("-echo.whatsNew") { whatsNew = WhatsNew.releases.first { $0.version == current } ?? WhatsNew.releases.first; return }
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

    /// A message that hadn't been sent comes back into the composer to be changed and sent again.
    private func editQueued(_ message: Message) {
        editing = nil
        draft = message.text
        pendingAttachments = message.attachments
        composerFocused = true
    }

    /// Loads a sent message back into the composer; nothing changes until it is sent again.
    private func beginEditing(_ message: Message) {
        editing = message
        draft = message.text
        pendingAttachments = message.attachments
        composerFocused = true
    }
}
