import SwiftUI

// The root view's sheets, dialogs and full-screen covers, the dev hooks' screens among them.

extension ContentView {
    /// Settings, setup and the sheets any screen can bring up.
    func sheets(_ content: some View) -> some View {
        content
        #if os(iOS)
        .sheet(isPresented: $showSettings, onDismiss: { WatchLink.shared.push() }) { SettingsView() }
        #else
        // The Settings window (`ReddeMacApp`), wherever the iPhone opens its sheet.
        .onChange(of: showSettings) { _, show in
            guard show else { return }
            showSettings = false
            openWindow(id: ReddeMacApp.settingsWindow)
        }
        .focusedSceneValue(\.chatCommands, chatCommands)
        #endif
        .sheet(isPresented: $showModelPicker) {
            NavigationStack { ModelPickerView() }
                .presentationDetents([.medium, .large])
                #if os(macOS)
                // A Mac sheet takes its content's size, and a list has none: it came up a sliver (11-03).
                .frame(minWidth: 460, idealWidth: 520, minHeight: 560, idealHeight: 680)
                #endif
        }
        .sheet(isPresented: $showSetup, onDismiss: { WatchLink.shared.push() }) { SetupView() }
        .sheet(item: $setupCode, onDismiss: {
            // A first run the code didn't finish goes back to setup.
            if !settings.setupDone, !settings.isConfigured { showSetup = true }
        }) { SetupCodeSheet(offer: $0) }
        .sheet(item: $pushOffer) { PushPairingSheet(offer: $0) }
        .sheet(item: $whatsNew) { WhatsNewView(release: $0, wide: sizeClass == .regular) }
        .modifier(MailSheets())   // the Inbox and email setup, over everything (a mail note, Ahead of Your Day)
        // In every build (11-04): these five sat inside the DEBUG block below since they were added,
        // so a Release build never opened a briefing, a key asked for, a pinned card, a watch draft
        // or Make This a Routine.
        .modifier(WatchDraftSheet())
        .modifier(ListDraftSheet())
        .modifier(BriefingSheets())
        .modifier(KeyRequestSheets())
        .modifier(PinnedCardSheets { id in
            // A pinned card's chat, from wherever it was pinned: the copy on the iPhone.
            if id != conversation.id, !conversation.isStreaming, let record = conversation.storeForContext.record(id: id) { conversation.load(record) }
            setDrawer(open: false)
        })
        .sheet(isPresented: $makingRoutine, onDismiss: { routineAsk.reply = nil }) {
            RoutineSheet(conversation: conversation, reply: routineAsk.reply)
        }
        // From a reply's ⋯ menu: the same sheet, for that reply.
        .onChange(of: routineAsk.reply) { _, reply in if reply != nil { makingRoutine = true } }
    }

    /// The screens the dev hooks open (screenshots, UI tests); none in a Release build.
    @ViewBuilder
    func debugSheets(_ content: some View) -> some View {
        #if DEBUG
        content
        .sheet(isPresented: $showProfilePicker) { NavigationStack { ProfilePickerView() } }
        .sheet(isPresented: $showTips) { NavigationStack { TipJarView() } }
        .sheet(isPresented: $showServers) { NavigationStack { ServersView() } }
        .sheet(isPresented: $showPush) { NavigationStack { PushSettingsView() } }
        .sheet(isPresented: $showGateway) { NavigationStack { GatewayView() } }
        #if DEBUG
        .fullScreenCover(isPresented: $showBotGallery) { BotGallery() }
        .fullScreenCover(isPresented: $showRoleFaces) { RoleFaces() }
        .sheet(isPresented: $showDemoPatch) { PatchView(title: "Lab change one", patch: PatchView.demo, notes: PatchView.demoNotes, notesTitle: "Steps left with it") }
        .sheet(isPresented: Binding(get: { demoDayPage != nil }, set: { if !$0 { demoDayPage = nil } })) {
            NavigationStack {
                switch demoDayPage {
                case "activity": AgentActivityView(tab: .done)
                case "models": ModelsProvidersView(profile: settings.profileName ?? "default", owner: settings.headerTitle)
                case "comingUp": AgentActivityView(tab: .comingUp)   // with -echo.demoComingUp for its made-up day
                case "pluginUpdates": PluginUpdatesView(agents: DemoDay.on ? DemoDay.pluginAgents : PluginUpdatesView.everyAgent())
                case "calendars": CalendarsSettingsView()
                case "headsUps": DailyJobView(daily: HeadsUps.job)
                case "wrapUp": DailyJobView(daily: EveningWrapUp.job)
                case "watches": WatchesView()
                case "goal": GoalView(goalID: "g10k")   // with -echo.demoGoals
                case "goals": GoalsListView()
                case "phoneTools": PhoneToolsSettingsView()
                case "health": HealthShareView()
                case "usage": UsageView(model: .demo)   // -echo.demoUsage's made-up month
                case "memory": MemoryView()   // with -echo.demoMemory
                case "memoryImport": MemoryImportView(profile: nil, model: AgentMemoryModel(demo: true))
                case "memoryManifest": MemoryImportView(profile: nil, model: AgentMemoryModel(demo: true), showingManifest: true)
                case "inbox": InboxView()   // with -echo.demoInbox
                case "mailSetup": MailSettingsView()
                case "mailAdd": MailAccountSetup(done: {})
                case "mailRules": MailRulesView()
                case "mailPiles": MailPilesView()   // with -echo.demoInbox
                case "mailLabels": MailTaggingView(accountID: "main")   // with -echo.demoInbox
                case "mailReader": MailReaderView(thread: MailDemo.readerThread)
                case "inboxCard": ScrollView { ReplyCardsView(cards: MailDemo.cards).padding() }
                case "mailBrief": List { InboxSection(open: {}); BriefingsSection() }   // the deck's email page
                case "dailyJobs": DailyJobsView()
                case "location": LocationSettingsView()
                case "chatListCards": ChatListCardsSettingsView()
                default: TriggersView()
                }
            }
        }
        .sheet(isPresented: $showAheadOfYourDay) { AheadOfYourDayView() }
        #endif
        .sheet(isPresented: $showFiles) { NavigationStack { FilesView() } }
        #else
        content
        #endif
    }

    /// A group chat's voice screen, as the conversation's: on the root, so that it stays up when
    /// the group chat is built again in the other layout.
    func groupVoicePresentation(_ content: some View) -> some View {
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

    /// The notifications about the chat on screen go, as in Messages; every other chat's stay in
    /// Notification Center. Coming back to Redde cleared them all, so a notification glanced at
    /// and not tapped was gone (GitHub #63).
    func clearChatsNotifications() {
        guard scenePhase == .active else { return }
        Notifier.shared.clearDelivered(session: conversation.serverSessionID, conversation: conversation.id.uuidString,
                                       room: groups.open?.id)
    }

    /// The chat's sheets and dialogs (its menu's, the toolbar's): on the root, not on the chat
    /// screen, so that they stay up when the layout changes and the chat screen is built again in
    /// the other (an iPhone Duo opened or closed). The Terminal's connection with them. And what
    /// is done when the layout changes (`layoutChanged`).
    func chatPresentations(_ content: some View) -> some View {
        content
            .onChange(of: sizeClass) { _, now in layoutChanged(wide: now == .regular) }
            .onChange(of: composerFocused) { _, focused in if !focused { focusLostAt = .now } }
            .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
            .sheet(isPresented: $showSessionDetails) { sessionDetails }
            #if os(iOS)
            .fullScreenCover(isPresented: $showTerminal) { TerminalScreen(folderLookup: terminalFolder) }
            #endif
            .sheet(isPresented: $showAgentScreen) {
                BotScreenView(profile: conversation.fileSource.profile) { _ = conversation.send(AgentWorkStrip.continueWord) }
                    #if os(macOS)
                    .frame(minWidth: 720, minHeight: 520)
                    #endif
            }
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
                Text("This chat is archived on your server with its messages, under Earlier Chats in the bot's menu, and the new one starts with no history. What the bot saved to its memory stays. To make this chat shorter instead, send /compress.")
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
}
