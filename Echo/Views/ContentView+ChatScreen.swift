import SwiftUI

// The root view's chat screen: the transcript, its composer and toolbar, and the iPhone's list beside it.

extension ContentView {
    /// The chat's place: the conversation, or a group chat opened from the list.
    /// Each behind AnyView, so neither keeps a copy of the other on the stack (see `body`).
    func chatScreen(showListButton: Bool) -> AnyView {
        if let room = groups.open {
            AnyView(GroupChatView(room: room, focused: $composerFocused,
                                  openList: showListButton ? { setDrawer(open: true) } : nil,
                                  openVoice: { groupVoice = $0; showGroupVoice = true }) { groups.forget(room.id) }
                .id(room.id))
        } else {
            AnyView(transcriptScreen(showListButton: showListButton))
        }
    }

    /// The transcript and its composer behind AnyView, then the title and toolbar: in one chain an
    /// unoptimized build kept 80 KB of the phone's stack here (see `body`).
    private func transcriptScreen(showListButton: Bool) -> some View {
        transcriptChrome(AnyView(transcriptPage), showListButton: showListButton)
    }

    private var transcriptPage: some View {
        TranscriptView(showSetup: $showSetup, showSearch: $showSearch, onEdit: beginEditing, onEditQueued: editQueued)
            .modifier(TapHidesKeyboard(focused: $composerFocused))
            .environment(\.replySpeaker, conversation.bot?.name)
            .environment(\.replyFace, botFace)
            .environment(\.fileSource, conversation.fileSource)
            .environment(\.sendFromPage, PageSender(conversation: conversation.id, send: conversation.sendFromPage))
            .environment(\.answerCard, conversation.isWorkerTranscript ? nil
                         : CardAnswerer(answer: conversation.answerCard, busy: conversation.isStreaming))
            .environment(\.sayToAgent, conversation.isWorkerTranscript ? nil
                         : AgentSayer { [conversation] text in _ = conversation.send(text) })
            .chatTextSize()
            .background(theme.pageColor)
            .foregroundStyle(theme.textColor)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    if conversation.isWorkerTranscript {
                        WorkerRunNote()
                    } else {
                        FollowUpChips()
                        ComposerView(draft: $draft, pendingAttachments: $pendingAttachments, editing: $editing,
                                     focused: $composerFocused,
                                     openHandsFree: { Task { await launchVoice(handsFree: settings.handsFreeByDefault, fromOutside: false) } },
                                     openModelPicker: { showModelPicker = true })
                    }
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
    }

    private func transcriptChrome(_ content: some View, showListButton: Bool) -> some View {
        content
            .navigationTitle(headerTitle)
            .navigationBarTitleDisplayMode(.inline)
            #if os(macOS)
            // The Mac's toolbar is glass: replies scrolled under the name and model showed through
            // and covered them (11-03). The page's own colour behind it there.
            .toolbarBackground(theme.pageColor, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            #endif
            .toolbar {
                // The conversation on top; the agent and model beneath, tap to pick the model —
                // the /model sheet without typing /model.
                ToolbarItem(placement: .principal) {
                    // Two lines, both of which open the model picker; beside the second, how
                    // full the model's context is, which opens its own explanation.
                    VStack(spacing: 1) {
                        modelButton {
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
                            .chatFont(.headline)
                            .foregroundStyle(theme.textColor)
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel("\(headerTitle). Model: \(modelChipLabel)")
                        .accessibilityHint("Choose which model answers")
                        HStack(spacing: 4) {
                            if let projectName {
                                // Its own width, a long name cut short in words: a frame with a
                                // most width took all of it and pushed the model off the line.
                                HStack(spacing: 2) {
                                    Image(systemName: "folder.fill").chatFont(size: 9, weight: .semibold)
                                    Text(projectName.count > 16 ? projectName.prefix(15) + "…" : projectName)
                                        .chatFont(.caption, weight: .medium).lineLimit(1)
                                }
                                .foregroundStyle(chatTheme.accent)
                                .fixedSize()
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Project: \(projectName)")
                            }
                            modelButton {
                                HStack(spacing: 3) {
                                    // A bot's chat names the tag another chat reaches it by.
                                    Text("\(conversation.bot.map { "@" + BotMentions.shownTag(profile: $0.profile, handle: $0.handle, roster: BotDirectory.shared.roster) } ?? ProfileCatalog.agentName(conversation.elsewhere?.profile ?? settings.profileName, settings: settings)) · \(modelChipLabel)").chatFont(.caption).lineLimit(1)
                                    Image(systemName: "chevron.down").chatFont(size: 8, weight: .bold)
                                }
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                            }
                            .accessibilityHidden(true)   // the line above says it, with the same action
                            if runsWithoutAsking {
                                Image(systemName: "bolt.fill")
                                    .chatFont(size: 9, weight: .bold)
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel("Commands run without asking")
                                    .accessibilityHint("Change it in the model menu")
                            }
                            if let context = conversation.contextUsage {
                                ContextRing(used: context.used, window: context.window) { showSessionDetails = true }
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
                            .accessibilityIdentifier("chat.conversations")
                            .keyboardShortcut("k", modifiers: .command)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        // Asked 2026-11-03 ("too long and too many items"): the conversation's three
                        // as one row of icons, the bot's own in a menu named after it, new chats in one.
                        ControlGroup {
                            Button("Find", systemImage: "magnifyingglass") { withAnimation { showSearch.toggle() } }
                                .disabled(!conversation.hasMessages)
                            Button("Details", systemImage: "info.circle") { showSessionDetails = true }
                                .disabled(conversation.isWorkerTranscript)
                            Button("Export", systemImage: "square.and.arrow.up") {
                                if let url = try? TranscriptExporter.file(title: conversation.title, messages: conversation.messages) {
                                    shareItem = ShareItem(url: url)
                                }
                            }
                            .disabled(!conversation.hasMessages)
                        }
                        if let bot = conversation.bot {
                            Menu {
                                // (A bot added for the Hermes API alone has its settings and face on the Dashboard.)
                                if let roster = chatBot, !roster.viaAPI {
                                    Button("Edit Bot…", systemImage: "slider.horizontal.3") { editingBot = roster }
                                    Button("Change Face…", systemImage: "face.smiling") { facingBot = roster }
                                }
                                if let roster = chatBot, !roster.isDefault {
                                    Button("Voice…", systemImage: "waveform") { voicingBot = roster }
                                    if !roster.viaAPI {
                                        Button("Schedules…", systemImage: "clock") { schedulingBot = roster }
                                    }
                                } else {
                                    Button("Voice…", systemImage: "waveform") { voicingMain = true }
                                }
                                if !conversation.isIncognito {
                                    MuteMenu(item: "bot:" + bot.profile)
                                }
                            } label: {
                                Label(chatBot?.title ?? chatBot?.displayName ?? bot.name, systemImage: "face.smiling")
                            }
                        } else {
                            if !conversation.isIncognito {
                                Button("Rename", systemImage: "pencil") {
                                    renameText = conversation.name ?? conversation.title
                                    showRename = true
                                }
                                .disabled(!conversation.hasMessages)
                            }
                            // The Dashboard's projects, for a conversation on the server.
                            if settings.transport == .hermesServe, conversation.serverSessionID != nil, !conversation.isIncognito {
                                ChatProjectMenu(naming: $namingProject, problem: $projectProblem)
                            }
                            // The main agent's voice is the app's (asked 2026-10-25).
                            Button("Voice…", systemImage: "waveform") { voicingMain = true }
                        }
                        if conversation.connection.isHermes, !conversation.isIncognito, !conversation.isWorkerTranscript {
                            Button("Make This a Routine…", systemImage: "repeat") { makingRoutine = true }
                                .disabled(!conversation.hasMessages || conversation.isStreaming)
                        }
                        // Watching the agent work: its Bot Desktop, on the Dashboard (the view says why not elsewhere).
                        if settings.transport.isHermes, !conversation.isIncognito {
                            Button("Agent's Screen", systemImage: "display") { showAgentScreen = true }
                        }
                        Menu {
                            // A bot's chat: Start Fresh has the toolbar's button, and a new conversation
                            // with the agent is here.
                            if conversation.bot != nil {
                                Button("Conversation with \(settings.headerTitle)", systemImage: "square.and.pencil") { conversation.reset() }
                            }
                            if AcpAgentChoices.asks(settings) {
                                AcpAgentChoices(settings: settings) { conversation.reset() }
                            }
                            if !conversation.isIncognito {
                                Button("Incognito Chat", systemImage: "eyeglasses") { conversation.startIncognito() }
                                    .keyboardShortcut("n", modifiers: [.command, .shift])
                            }
                            #if os(iOS)
                            if settings.transport.isHermes {
                                Button("Terminal", systemImage: "apple.terminal") { showTerminal = true }
                            }
                            #endif
                        } label: {
                            Label("New", systemImage: "plus")
                        }
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
                    } else if AcpAgentChoices.asks(settings) {
                        // Every agent on the bridge in one list: New Chat asks which (an empty chat
                        // can be moved to another agent this way too).
                        Menu {
                            AcpAgentChoices(settings: settings) { conversation.reset() }
                            NewChatElsewhere(settings: settings, conversation: conversation) {}
                        } label: {
                            Label("New conversation", systemImage: "square.and.pencil")
                        }
                        #if os(macOS)
                        .menuIndicator(.hidden)
                        #endif
                    } else if !NewChatElsewhere.choices(settings).isEmpty {
                        // Held: a chat on another connection (Claude Code from Hermes).
                        Menu {
                            NewChatElsewhere(settings: settings, conversation: conversation) {}
                        } label: {
                            Label("New conversation", systemImage: "square.and.pencil")
                        } primaryAction: {
                            conversation.reset()
                        }
                        .accessibilityIdentifier("new-chat-elsewhere")
                        .keyboardShortcut("n", modifiers: .command)
                        #if os(macOS)
                        .menuIndicator(.hidden)
                        #endif
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

    // MARK: - iPhone conversation list

    #if os(iOS)
    /// iPhone: the chat, with the conversation list in a panel that slides in from the left.
    var phoneLayout: some View {
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
    func conversationOpened() {
        if showConversations, !reduceMotion, let tap = ConversationTap.take() {
            openingFromRow = tap
        } else {
            setDrawer(open: false)
        }
    }

    /// The layout changed under the chat (an iPhone Duo opened or closed, an iPad window drawn
    /// across the line): the wide layout has the list beside the chat, so the panel closes. The
    /// keyboard, if it was up, comes back in the composer the other layout has.
    func layoutChanged(wide: Bool) {
        if wide {
            showConversations = false
            openingFromRow = nil
        }
        let typing = composerFocused || focusLostAt.map { Date.now.timeIntervalSince($0) < 0.5 } == true
        if typing, !showConversations {
            Task { try? await Task.sleep(for: .milliseconds(350)); composerFocused = true }
        }
    }

    func setDrawer(open: Bool) {
        if open { composerFocused = false }
        withAnimation(.sidePanel) { showConversations = open }
    }

    /// The project this conversation is in, on the Dashboard: as the server last said, or for a
    /// new one, the project it is about to start in.
    var projectName: String? {
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

/// In place of the composer under a Kanban worker's run (GitHub issue 37): there to read; going on
/// with it is the board's to do.
private struct WorkerRunNote: View {
    var body: some View {
        Label("A Kanban worker's run, to read. To go on with it, retry or unblock its card on the board.",
              systemImage: "rectangle.split.3x1")
            .chatFont(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.regularMaterial, in: .rect(cornerRadius: 18))
            .padding(.horizontal, 12).padding(.bottom, 8)
    }
}
