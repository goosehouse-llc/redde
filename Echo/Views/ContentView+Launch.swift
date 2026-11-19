import StoreKit
import SwiftUI
import os

// The root view's voice mode, the work done as Redde opens, and the requests from Siri, links, controls and notifications.

extension ContentView {
    /// Voice mode, the work done as Redde opens, and the links it opens with.
    func launching(_ content: some View) -> some View {
        content
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
            TagRoster.shared.refreshIfStale(settings)   // who a tag can reach on the other servers
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
            if DevHooks.has("-echo.autoVoice") { await launchVoice(handsFree: DevHooks.has("-echo.handsFree"), fromOutside: true) }
            // `-echo.voiceAsk "…"`: voice mode asked that as if it were heard (a simulator has no speech to hear).
            if let asking = DevHooks.value("-echo.voiceAsk") { await launchVoice(handsFree: false, fromOutside: true, asking: asking) }
            // Once a demo conversation is in: one opened under the bar hangs up, as another chat does.
            if DevHooks.has("-echo.demoCallBar") { Task { try? await Task.sleep(for: .seconds(1.5)); voiceSession.poseBar() } }
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
    }

    /// Requests from Siri, controls, notifications and the lock, and what follows a chat changing.
    func routing(_ content: some View) -> some View {
        content
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
        .onChange(of: router.pendingGoalChat) { handleGoalChat() }
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
            if was, !now {
                replyFinished()
                handlePushRequests()   // a tap that waited for this reply (fast lane)
            }
            // A reply started (Ask Redde about a card, Siri, a share): show the chat it lands in.
            // Not for one the outbox sent by itself: a waiting message's retries shut the list
            // the person had open (2026-11-19).
            if now, !was, !conversation.turnFromOutbox {
                if sizeClass != .regular, showConversations { setDrawer(open: false) }
            }
        }
        // Another conversation opened (Siri, a notification, the list): it takes the group chat's place.
        .onChange(of: conversation.id) { groups.open = nil }
        .onChange(of: settings.connectionKey) { groups.open = nil }
        // A chat opened (a notification, the list): its notifications go; the others stay.
        .onChange(of: conversation.serverSessionID) { clearChatsNotifications() }
        .onChange(of: conversation.id) { clearChatsNotifications() }
        .onChange(of: groups.open?.id) { clearChatsNotifications() }
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
            clearChatsNotifications()
            ReadState.markConversationRead(conversation.id)
            conversation.noteSeen()   // and on the host, for the chat list's Unread
            HermesServeClient.shared.reconnectIfNeeded()
            ModelWarmer.warm(conversation)
            conversation.retryOutbox()   // back in the foreground: try anything still waiting to send
            conversation.deleteLeftIncognitoChats()   // ones the app couldn't delete as they were left
            consumeSharedItems()
            handleCallScreen()
            TagRoster.shared.refreshIfStale(settings)   // who a tag can reach on the other servers
            // (On an agent's call, voice mode is the call's: nothing new is started over it.)
            #if os(iOS)
            guard AgentCalls.shared.current == nil else { return }
            #endif
            guard Settings.shared.listenOnOpen, router.pendingVoice == nil, !voiceSession.mightBeBusy else { return }
            Task { await launchVoice(handsFree: showVoice ? voiceSession.continuous : settings.handsFreeByDefault, fromOutside: true) }
        }
    }

    /// A live call going on with the voice screen put away: its bar shows (`CallBar`).
    var callInBar: Bool { voiceSession.inBar && !showVoice }

    /// Voice mode as you'd open it by hand: Hands-free follows Settings → Voice.
    func openVoice(fromOutside: Bool) {
        // A call in its bar: the Talk button, Siri or a control opens its screen again, as it is.
        if voiceSession.inBar { showVoice = true; return }
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
            guard !showVoice, !voiceSession.isLive, !showConversations, !showSettings, !showSetup, !showModelPicker, whatsNew == nil,
                  !lock.isLocked, !conversation.isStreaming, scenePhase == .active else { return }
            prompt.markAsked(version: version)
            requestReview()
        }
    }

    /// Items handed over by the share extension become the draft and pending attachments, of a
    /// new conversation if the share sheet said so.
    func consumeSharedItems() {
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

    /// A goal to set up, from the New Goal sheet (`Goals`): its agent's chat (a new conversation
    /// for the main agent, a bot's Bot Chat), with the written-out ask sent, as taking an idea does.
    private func handleGoalChat() {
        guard !lock.isLocked, let request = router.consumeGoalChat() else { return }
        showSettings = false
        showVoice = false
        setDrawer(open: false)
        Task {
            do {
                if request.profile != "default", let bot = BotDirectory.shared.roster?.bots.first(where: { $0.name == request.profile }) {
                    try await conversation.openBot(bot, mainName: settings.headerTitle)
                } else if request.profile != (settings.profileName ?? ProfileCatalog.defaultID) {
                    ProfileCatalog.startConversation(on: request.profile, conversation: conversation, settings: settings)
                } else if conversation.bot != nil || conversation.elsewhere != nil || conversation.hasMessages || !conversation.outbox.isEmpty {
                    conversation.reset()
                }
                conversation.send(request.message)
            } catch {
                Logger(subsystem: "com.goosehouse.echo", category: "goals").error("couldn't open the goal's chat: \(error.localizedDescription)")
            }
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
        if let quote = request.quote.map(Quote.selection), !quote.isEmpty { conversation.quoting = QuotedText(text: quote) }
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
        // A tap while a reply streams (GitHub #61: it was taken and dropped): on a Hermes connection
        // the reply carries on there when the chat is left, as from the list, so it opens now; on
        // the fast lane, which would lose it, the tap waits for the reply's end (`isStreaming`).
        let canLeave = !conversation.isStreaming || conversation.connection.hasLedger
        if canLeave, let session = router.consumeSession() {
            let place = router.consumeSessionPlace()
            if sizeClass != .regular, showConversations { setDrawer(open: false) }
            // A note from another of the person's servers (a Claude Code reply while the app is on
            // Hermes): over to that server first, where the chat can be fetched.
            if let server = router.consumeServer(), server != settings.activeServerID,
               settings.servers.contains(where: { $0.id == server }), !conversation.isStreaming {
                ServerSwitcher.switchTo(server, conversation: conversation)
            }
            // Also when it is the conversation already on screen: what is here may be from before
            // the app was closed, without the reply or the question the notification is about.
            // A conversation on another server than the one the app is on can't be fetched: the
            // app then stays where it was. The one streaming now is here already, live.
            if !(conversation.isStreaming && conversation.serverSessionID == session) {
                Task { try? await conversation.open(serverSession: session, profile: place.profile, title: place.title, viaAPI: place.viaAPI) }
            }
        }
        if canLeave, let profile = router.consumeBot() {
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
                if showVoice || voiceSession.inBar { voiceSession.cancel() }   // what voice mode was saying in another chat is over
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
            // A conversation on that profile, the app staying on its own: "Ask Work in Redde" once
            // moved the whole app there for good, unseen (2026-10-29).
            if let profile = ProfileCatalog.find(asked, in: ProfileCatalog.known()) {
                if showVoice || voiceSession.inBar { voiceSession.cancel() }   // voice mode was open on another chat: what it was saying is over
                ProfileCatalog.startConversation(on: profile.name, conversation: conversation, settings: settings)
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
                if showVoice || voiceSession.inBar { voiceSession.cancel() }   // what voice mode was saying in another chat is over
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
    func launchVoice(handsFree: Bool, fromOutside: Bool, asking: String? = nil) async {
        // A call in its bar: its screen again, the call as it is (never a new conversation under it).
        if voiceSession.inBar, asking == nil { showVoice = true; return }
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
        if let asking {
            voiceSession.ask(asking)
        } else if conversation.isStreaming {
            voiceSession.joinReply()   // a typed reply under way: heard from where it has got to, not stopped
        } else {
            voiceSession.beginListening()
        }
    }

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
