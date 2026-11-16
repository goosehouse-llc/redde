import SwiftUI

// The root view's dev hooks: the tour and the launch arguments for screenshots and tests (Debug builds only).

extension ContentView {
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
        if mode == "calendar" { await runCalendarTour(open: { await open(long) }); return }
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

    /// `-echo.tour calendar`: what the phone's calendar costs the screen, with access to it given
    /// (`simctl privacy <sim> grant calendar com.goosehouse.echo`, reminders too) and events on it
    /// (`-echo.demoCalendarEvents n`): a new conversation from a chat, three times (the start
    /// screen reads the day's events), then Keep a Copy's refresh three times, which reads two
    /// months of events and the reminders to hand them to the server ("copy ms": how long each
    /// took). Settings changed: phone tools on with the calendar and reminders, and Keep a Copy.
    private func runCalendarTour(open long: () async -> Void) async {
        let monitor = FrameMonitor.shared
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        var tools = settings.phoneTools
        tools.on = true
        tools.copy = true
        tools.set(.calendar, .allow)
        tools.set(.reminders, .allow)
        settings.phoneTools = tools
        await wait(1)
        for _ in 0 ..< 3 {
            await long()
            await wait(1.5)
            await monitor.report("tour: calendar: new conversation") { conversation.reset(); await wait(1.5) }
        }
        for _ in 0 ..< 3 {
            await monitor.report("tour: calendar: keep a copy") {
                let began = ContinuousClock.now
                await DeviceToolsService.shared.refreshCopies()
                FrameMonitor.count("copy ms", by: Int((ContinuousClock.now - began) / .milliseconds(1)))
                await wait(0.5)
            }
        }
        await monitor.report("tour: done") {}
    }

    func applyDevHooks() {
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
        case "roleFaces": showRoleFaces = true
        case "patch": showDemoPatch = true
        case "activity", "comingUp", "pluginUpdates", "triggers", "calendars", "headsUps", "wrapUp", "watches", "goal", "goals", "phoneTools", "health", "usage", "memory", "memoryImport", "memoryManifest", "inbox", "mailSetup", "mailAdd", "mailRules", "mailLabels", "mailReader", "inboxCard", "mailBrief", "dailyJobs", "location", "chatListCards", "models": demoDayPage = DevHooks.value("-echo.screen")
        case "aheadOfYourDay": showAheadOfYourDay = true
        #endif
        default: break
        }
        // `-echo.demoDay routine`: Make This a Routine over the chat it seeded (`DemoDay`).
        if DemoDay.scene == "routine" {
            Task { try? await Task.sleep(for: .seconds(1.5)); makingRoutine = true }
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
}
