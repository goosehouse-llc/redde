import SwiftUI

// The root view's chat header helpers: its title, the model menu, Session Details and the keyboard shortcuts.

extension ContentView {
    /// Hardware-keyboard shortcuts (iPad, Mac). Zero-size buttons still receive key equivalents,
    /// and they show up in the ⌘ overlay with these titles.
    #if os(macOS)
    /// The iPad's keyboard shortcuts, as the Mac's menu bar has them (`ReddeCommands`).
    var chatCommands: ChatCommands {
        ChatCommands(
            newConversation: { conversation.reset() },
            newIncognito: conversation.isIncognito ? nil : { conversation.startIncognito() },
            voice: { openVoice(fromOutside: false) },
            focusComposer: { composerFocused = true },
            chooseModel: { showModelPicker = true },
            sessionDetails: conversation.isWorkerTranscript ? nil : { showSessionDetails = true },
            find: conversation.hasMessages ? { withAnimation { showSearch.toggle() } } : nil,
            stop: conversation.isStreaming ? { conversation.cancel() } : nil,
            export: conversation.hasMessages ? {
                if let url = try? TranscriptExporter.file(title: conversation.title, messages: conversation.messages) { shareItem = ShareItem(url: url) }
            } : nil)
    }
    #endif

    var keyboardShortcuts: some View {
        Group {
            Button("Settings") { showSettings = true }.keyboardShortcut(",", modifiers: .command)
            Button("Voice mode") { openVoice(fromOutside: false) }.keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Focus composer") { composerFocused = true }.keyboardShortcut("l", modifiers: .command)
            // ⌘N in a bot's chat, whose toolbar button is Start Fresh: a new conversation with the agent, as anywhere.
            Button("New conversation") { conversation.reset() }.keyboardShortcut("n", modifiers: .command).disabled(conversation.bot == nil)
            Button("Find in conversation") { withAnimation { showSearch.toggle() } }.keyboardShortcut("f", modifiers: .command)
                .disabled(!conversation.hasMessages)
            Button("Stop reply") { conversation.cancel() }.keyboardShortcut(".", modifiers: .command).disabled(!conversation.isStreaming)
            Button("Session Details") { showSessionDetails = true }.keyboardShortcut("i", modifiers: .command)
                .disabled(conversation.isWorkerTranscript)
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
    func terminalFolder() async -> String? {
        if let place = conversation.startsIn { return place.path }
        guard let id = conversation.serverSessionID, settings.serveBaseURL != nil else { return nil }
        return try? await HermesServeClient.shared.listSessions(limit: 200).first { $0.id == id }?.cwd?.nilIfEmpty
    }

    /// The header's first line: this conversation, or "New conversation" before the first message.
    func saveRename() {
        let name = renameText
        Task {
            do { try await conversation.rename(to: name) } catch { renameError = error.localizedDescription }
        }
    }

    /// In a bot's chat, the bot as the roster has it (for its face, and whether it is the main one).
    var chatBot: HermesBot? {
        guard let profile = conversation.bot?.profile, BotDirectory.shared.key == settings.connectionKey else { return nil }
        return BotDirectory.shared.roster?.bots.first { $0.name == profile }
    }

    /// In a bot's chat, the bot's face, as the chat list draws it.
    var botFace: BotFace? {
        conversation.bot.map { bot in
            (BotDirectory.shared.key == settings.connectionKey ? BotDirectory.shared.roster?.faces[bot.profile] : nil) ?? BotFace(seed: bot.profile)
        }
    }

    /// The chat's colours: the theme's, or with Settings → Appearance → Bot colors on, the bot's,
    /// and Redde's in a chat with it when its face has a colour of its own. (A group chat isn't
    /// this screen, and keeps the theme's.)
    var chatTheme: ResolvedTheme {
        guard settings.botColors, let colors = (botFace ?? BotDirectory.shared.mainFace).chatColors else { return theme }
        return settings.theme.resolved(with: colors, font: settings.chatFont)
    }

    var headerTitle: String {
        if let bot = conversation.bot { return bot.name }
        if conversation.isIncognito { return IncognitoNote.title }
        return !conversation.hasMessages && conversation.outbox.isEmpty ? String(localized: "New conversation") : conversation.title
    }

    /// The chat's Session Details page, read from its own connection when it opens. Another
    /// sheet from it (Rename, Export) waits for this one to go.
    var sessionDetails: some View {
        NavigationStack {
            detailsPage
        }
    }

    private var detailsPage: some View {
        let renames = conversation.bot == nil && !conversation.isIncognito && conversation.hasMessages
        return SessionDetailsView(
            info: sessionInfo(), activity: SessionActivity.from(conversation.messages), source: sessionDetailsSource,
            rename: renames ? {
                renameText = conversation.name ?? conversation.title
                Task { try? await Task.sleep(for: .milliseconds(450)); showRename = true }
            } : nil,
            export: {
                guard let url = try? TranscriptExporter.file(title: conversation.title, messages: conversation.messages) else { return }
                Task { try? await Task.sleep(for: .milliseconds(450)); shareItem = ShareItem(url: url) }
            },
            model: SessionDetailsModel())
    }

    /// Where the page reads the session: the conversation's own connection (a bot's chat, the
    /// bot's profile); nil on the fast lane, which keeps no session.
    private var sessionDetailsSource: SessionDetailsSource? {
        switch conversation.connection {
        case .hermesServe: .dashboard(.shared, profile: conversation.routeProfile)
        case .hermesSessions: conversation.ledgerAPI().map(SessionDetailsSource.api)
        case .chatCompletions, .acp: nil
        }
    }

    private func sessionInfo() -> SessionChatInfo {
        let picked = conversation.turnModel
        let choice: String? = if settings.transport == .chatCompletions {
            nil
        } else if conversation.ownModel != nil {
            String(localized: "Picked in this conversation", comment: "Session Details: how the model was chosen")
        } else if picked != nil {
            String(localized: "Picked in Redde", comment: "Session Details: how the model was chosen")
        } else if conversation.bot != nil {
            String(localized: "The bot's own model", comment: "Session Details: how the model was chosen")
        } else {
            String(localized: "Set on your server", comment: "Session Details: how the model was chosen")
        }
        return SessionChatInfo(
            title: headerTitle,
            agent: conversation.bot?.name ?? settings.headerTitle,
            face: botFace,
            server: settings.transport.hasLedger ? settings.activeServer?.name.nilIfEmpty : nil,
            connection: conversation.connection,
            model: modelChipLabel,
            modelChoice: choice,
            provider: picked?.provider?.nilIfEmpty,
            reasoningEffort: settings.transport.isHermes ? settings.reasoningEffort.nilIfEmpty : nil,
            context: conversation.contextUsage,
            project: projectName,
            sessionID: conversation.isIncognito ? nil : conversation.serverSessionID,
            isIncognito: conversation.isIncognito,
            startedHere: conversation.createdAt)
    }

    /// What the title chip shows: the model this conversation's turns ask for (Redde's pick, or
    /// with New Chats Use the Server's Model on its own), or the backend's default.
    /// The header's two lines: a tap opens the model picker; on the Mac, a right click the pinned
    /// models. Not a long press on iOS: the navigation bar takes any press there as a tap (a
    /// context menu, a menu with a tap of its own and a long-press gesture all opened the picker,
    /// iOS 27, 2026-11-07): there, they lead the picker the tap opens.
    @ViewBuilder
    func modelButton<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Button { showModelPicker = true } label: { label() }
            .buttonStyle(.plain)
            #if os(macOS)
            .contextMenu { pinnedModelsMenu }
            #endif
    }

    private func switchModel(to choice: ModelChoice) {
        Task {
            do { try await ModelPickerView.use(choice, in: conversation, settings: settings) }
            catch { conversation.show(error: String(localized: "Couldn't switch this conversation: \(error.localizedDescription)")) }
        }
    }

    /// The pinned models, for switching in a tap (asked 2026-11-07), and the whole list: the Mac
    /// header's right click. (Not in the … menu: taken out at his word, 11-07.)
    @ViewBuilder
    private var pinnedModelsMenu: some View {
        let pinned = settings.pinnedModelsHere
        if pinned.isEmpty {
            Text("No pinned models yet", comment: "Chat header's model menu: nothing pinned")
        }
        ForEach(pinned) { choice in
            Button { switchModel(to: choice) } label: {
                if ModelPickerView.isPicked(choice, in: conversation, settings: settings) {
                    Label(choice.name, systemImage: "checkmark")
                } else {
                    Text(choice.name)
                }
            }
        }
        Divider()
        Button(String(localized: "All Models…", comment: "Chat header's model menu: opens the model picker"), systemImage: "list.bullet") { showModelPicker = true }
    }

    var modelChipLabel: String {
        let picked = conversation.turnModel?.model
        // A bot's chat runs on the bot's own model, as its profile says (unless picked here).
        if let bot = conversation.bot, picked == nil,
           let model = BotDirectory.shared.bots(for: settings.connectionKey).first(where: { $0.name == bot.profile })?.model {
            return model
        }
        return switch settings.transport {
        case .chatCompletions: settings.fastLaneModel.nilIfEmpty ?? String(localized: "model", comment: "Under the chat's title when no model is named")
        default: picked ?? String(localized: "default model", comment: "Under the chat's title: the server's own model")
        }
    }
}
