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
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var draft = ""
    @State private var showSettings = false
    @State private var shareItem: ShareItem?
    @State private var showSetup = false
    @State private var showConversations = false
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
                        ConversationsList(inSidebar: true)
                    }
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
                } detail: {
                    transcriptScreen(showListButton: false)
                }
            } else {
                NavigationStack { transcriptScreen(showListButton: true) }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showModelPicker) { NavigationStack { ModelPickerView() }.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showSetup) { SetupView() }
        .sheet(isPresented: $showConversations) { ConversationsView() }
        .sheet(item: $whatsNew) { WhatsNewView(release: $0) }
        #if DEBUG
        .sheet(isPresented: $showProfilePicker) { NavigationStack { ProfilePickerView() } }
        .sheet(isPresented: $showServers) { NavigationStack { ServersView() } }
        #endif
        .fullScreenCover(isPresented: $showVoice) {
            VoiceView(session: voiceSession, onSwitchToTyping: {
                // Once the cover is gone, raise the keyboard in the composer.
                Task { try? await Task.sleep(for: .milliseconds(450)); composerFocused = true }
            })
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
                            Text(headerTitle)
                                .font(.headline)
                                .lineLimit(1)
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
                        Button("Conversations", systemImage: "list.bullet") { showConversations = true }
                            .keyboardShortcut("k", modifiers: .command)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("Find in conversation", systemImage: "magnifyingglass") { withAnimation { showSearch.toggle() } }
                            .disabled(conversation.messages.isEmpty)
                        Button("Export as Markdown", systemImage: "square.and.arrow.up") {
                            if let url = try? TranscriptExporter.file(title: conversation.title, messages: conversation.messages) {
                                shareItem = ShareItem(url: url)
                            }
                        }
                        .disabled(conversation.messages.isEmpty)
                        Divider()
                        Button("Settings", systemImage: "gearshape") { showSettings = true }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    Button("New conversation", systemImage: "square.and.pencil") {
                        conversation.reset()
                    }
                    .disabled(conversation.messages.isEmpty)
                    .keyboardShortcut("n", modifiers: .command)
                }
            }
            .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
            .background { keyboardShortcuts }
    }

    /// Hardware-keyboard shortcuts (iPad, Mac). Zero-size buttons still receive key equivalents,
    /// and they show up in the ⌘ overlay with these titles.
    private var keyboardShortcuts: some View {
        Group {
            Button("Settings") { showSettings = true }.keyboardShortcut(",", modifiers: .command)
            Button("Voice mode") { openVoice() }.keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Focus composer") { composerFocused = true }.keyboardShortcut("l", modifiers: .command)
            Button("Find in conversation") { withAnimation { showSearch.toggle() } }.keyboardShortcut("f", modifiers: .command)
                .disabled(conversation.messages.isEmpty)
            Button("Stop reply") { conversation.cancel() }.keyboardShortcut(".", modifiers: .command).disabled(!conversation.isStreaming)
            Button("Export as Markdown") {
                if let url = try? TranscriptExporter.file(title: conversation.title, messages: conversation.messages) { shareItem = ShareItem(url: url) }
            }
            .keyboardShortcut("e", modifiers: .command).disabled(conversation.messages.isEmpty)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// The header's first line: this conversation, or "New conversation" before the first message.
    private var headerTitle: String {
        conversation.messages.isEmpty && conversation.outbox.isEmpty ? "New conversation" : conversation.title
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
        showVoice = true
    }

    /// Items handed over by the share extension become the draft and pending attachments.
    private func consumeSharedItems() {
        guard !lock.isLocked else { return }
        Task {
            // The inbox decodes off the main actor; the lock can have engaged meanwhile.
            guard let payload = await ShareInbox.takePending(), !payload.isEmpty, !lock.isLocked else { return }
            showVoice = false
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
        default: break
        }
        if let text = DevHooks.value("-echo.draft") {
            draft = text
            Task { try? await Task.sleep(for: .milliseconds(450)); composerFocused = true }
        }
    }
    #endif

    /// "What's New" once per version after an update. A fresh install goes through setup and
    /// starts out current. While the app is locked, in voice mode or answering Siri it waits, and
    /// comes up once that's over (unlock and closing voice mode call this again).
    private func presentWhatsNewIfDue() {
        guard whatsNew == nil else { return }
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
