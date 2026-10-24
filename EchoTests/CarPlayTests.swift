import CarPlay
import Foundation
import Testing
import UIKit
@testable import Echo

/// The car screen without a car: the tabs, the Ask cards, the Chats list and the voice card are
/// built and pressed directly, against a fake microphone and a scripted transport. What CarPlay
/// draws with them is `EchoTests/CarPlayPreviewTests.swift`'s business (`scripts/carplay-preview.sh`).
@MainActor
struct CarPlayTests {
    // MARK: Harness

    struct Harness {
        let delegate = CarPlaySceneDelegate()
        let defaults = UserDefaults(suiteName: "carplay-\(UUID().uuidString)")!
        let settings: Settings
        let store: ConversationStore
        let conversation: Conversation
        let session: VoiceSession
        let recognizer = VoiceSessionTests.FakeRecognizer()
        let speaker = VoiceSessionTests.FakeSpeaker()
        let audio = VoiceSessionTests.FakeAudio()
        /// Notes taken by voice (quick capture), in order.
        let taken = Taken()

        @MainActor final class Taken {
            private(set) var notes: [String] = []
            func add(_ note: String) { notes.append(note) }
        }

        init(transport: any HermesTransport = ConversationLifecycleTests.ScriptedTransport([.textDelta("Hello."), .done])) {
            settings = Settings(defaults: defaults)
            settings.transport = .chatCompletions
            settings.fastLaneURL = "http://example.invalid:11500"
            settings.fastLaneModel = "test"
            store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "carplay-\(UUID().uuidString)"))
            conversation = Conversation(settings: settings, store: store, transportOverride: transport)
            let taken = taken
            session = VoiceSession(conversation: conversation, recognizer: recognizer, output: speaker, audio: audio,
                                   requestPermissions: { true }, earcon: { _ in }, keepAwake: { _ in }, talkOver: { .off }, interruption: { .speech },
                                   takeNote: { taken.add($0) })
            delegate.sessionOverride = session
            delegate.conversationOverride = conversation
            delegate.settings = settings
            delegate.store = store
            delegate.notes = CaptureInbox(defaults: defaults, settings: settings, deliver: { _ in throw URLError(.notConnectedToInternet) })
        }

        /// One typed turn, start to finish, so the conversation is worth keeping.
        func ask(_ question: String) async {
            for await _ in conversation.send(question) {}
            while conversation.isStreaming { try? await Task.sleep(for: .milliseconds(5)) }
        }

        /// What the car's card shows for where the voice session stands now.
        var card: CarPlaySceneDelegate.Card {
            CarPlaySceneDelegate.card(phase: session.phase, waitingOnPhone: session.activeTool == "waiting for you",
                                      muted: session.isMuted, paused: session.isPaused, stopped: delegate.stopped)
        }
    }

    /// Presses a row the way the car does, and waits for it to say it's done (the row's spinner).
    private func press(_ row: CPListItem?) async throws {
        let row = try #require(row)
        let handler = try #require(row.handler)
        await withCheckedContinuation { done in handler(row) { done.resume() } }
    }

    private func waitUntil(_ what: String, timeout: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { Issue.record("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func session(_ id: String, title: String? = nil, preview: String? = nil, lastActive: Double, pinned: Bool? = nil,
                         source: String? = nil) -> HermesSessionsAPI.SessionSummary {
        var s = HermesSessionsAPI.SessionSummary(id: id)
        s.title = title; s.preview = preview; s.last_active = lastActive; s.pinned = pinned; s.source = source
        return s
    }

    // MARK: Which chats, in what order

    /// The car's card is Thinking until the reply is heard in the car, a little after the phone
    /// starts playing it: its mouth moved a second or more before the voice came (asked
    /// 2026-10-23, "wait a few seconds before the mouth starts moving").
    @Test func theMouthWaitsForTheSound() {
        let speaking = { (heard: Bool) in
            CarPlaySceneDelegate.card(phase: .speaking, waitingOnPhone: false, muted: false, paused: false, heard: heard)
        }
        #expect(speaking(false) == .showing(.thinking))
        #expect(speaking(true) == .showing(.speaking))
        #expect(CarPlaySceneDelegate.card(phase: .speaking, waitingOnPhone: false, muted: false, paused: true, heard: false) == .showing(.paused))
        let started = Date.now
        #expect(!CarPlaySceneDelegate.heardInCar(since: nil, now: started.addingTimeInterval(10)), "no sound yet")
        #expect(!CarPlaySceneDelegate.heardInCar(since: started, now: started.addingTimeInterval(0.5)))
        #expect(CarPlaySceneDelegate.heardInCar(since: started, now: started.addingTimeInterval(CarPlaySceneDelegate.carSoundLag)))
    }

    @Test func serverSessionsListPinnedFirstThenNewest() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = CarPlayChats.rows(sessions: [
            session("old", title: "Older", lastActive: now.timeIntervalSince1970 - 7200),
            session("new", title: "Newer", lastActive: now.timeIntervalSince1970 - 60),
            session("pin", title: "Kept", lastActive: now.timeIntervalSince1970 - 86_400 * 30, pinned: true),
        ], currentSessionID: "new", limit: 12, now: now)
        #expect(rows.map(\.title) == ["Kept", "Newer", "Older"])
        #expect(rows.map(\.isCurrent) == [false, true, false])
        #expect(rows[0].detail.hasPrefix("Pinned · "))
        #expect(rows[1].detail == CarPlayChats.currentDetail)
    }

    @Test func aSessionNobodyNamedNeverShowsWhatWasSaid() {
        let rows = CarPlayChats.rows(sessions: [session("a", preview: "Your door code is 4417.", lastActive: 100)],
                                     currentSessionID: nil, limit: 12)
        #expect(rows.map(\.title) == [CarPlayChats.untitled])
        #expect(!rows[0].detail.contains("4417"))
    }

    @Test func theListIsCutToWhatTheCarShows() {
        let sessions = (0 ..< 30).map { session("s\($0)", title: "Chat \($0)", lastActive: Double($0)) }
        let rows = CarPlayChats.rows(sessions: sessions, currentSessionID: nil, limit: 12)
        #expect(rows.count == 12)
        #expect(rows.first?.title == "Chat 29")
    }

    /// GitHub issue 19: every run of a scheduled job is a session, and they filled the list.
    @Test func scheduledRunsStayOutUnlessPinnedOrOpen() {
        let runs = (0 ..< 20).map { session("run\($0)", title: "Briefing \($0)", lastActive: Double(100 + $0), source: "cron") }
        let rows = CarPlayChats.rows(sessions: runs + [
            session("chat", title: "Kitchen", lastActive: 50, source: "api_server"),
            session("kept", title: "Pinned run", lastActive: 10, pinned: true, source: "cron"),
        ], currentSessionID: "run3", limit: 12)
        #expect(rows.map(\.title) == ["Pinned run", "Briefing 3", "Kitchen"])
    }

    // MARK: The tabs

    /// The Ask tab's row of cards.
    private func cards(_ delegate: CarPlaySceneDelegate) throws -> CPListImageRowItem {
        try #require(delegate.askSections().first?.items.first as? CPListImageRowItem)
    }

    /// Presses a card the way the car does, by its place in the row.
    private func press(card index: Int, of delegate: CarPlaySceneDelegate) async throws {
        let row = try cards(delegate)
        let handler = try #require(row.listImageRowHandler)
        await withCheckedContinuation { done in handler(row, index) { done.resume() } }
    }

    /// Settings → Appearance → CarPlay cards: the tab draws its cards in the look picked there,
    /// and in the colour one until something else is.
    @Test func theCardsAreDrawnInTheLookPickedInSettings() throws {
        guard #available(iOS 26.4, *) else { return }
        let h = Harness()
        func pictures() throws -> [Data] {
            try cards(h.delegate).elements.compactMap { ($0 as? CPListImageRowItemCardElement)?.thumbnail?.image.pngData() }
        }
        #expect(h.settings.carPlayCards == .color)
        var drawn: Set<[Data]> = []
        for look in CarPlayCardLook.allCases {
            h.settings.carPlayCards = look
            let three = try pictures()
            #expect(three.count == 3)
            #expect(drawn.insert(three).inserted, "\(look) draws what another look does")
        }
        h.settings.carPlayCards = .glow
        // The pick outlives the app.
        #expect(Settings(defaults: h.defaults).carPlayCards == .glow)
    }

    @Test func theScreenOpensOnTwoTabsAskFirst() throws {
        let tabs = Harness().delegate.rootTemplate()
        #expect(tabs.templates.count == 2)
        #expect(tabs.templates.count <= CPTabBarTemplate.maximumTabCount, "the car refuses a tab bar with more tabs than it allows")
        let ask = try #require(tabs.templates.first as? CPListTemplate)
        let chats = try #require(tabs.templates.last as? CPListTemplate)
        #expect(ask.title == "Ask")
        #expect(chats.title == "Chats")
        #expect(ask.tabImage != nil && chats.tabImage != nil)
        #expect(ask !== chats)
    }

    @Test func theAskTabIsThreeCardsAndSaysWhichConversationIsOpen() async throws {
        let h = Harness()
        // Cards, not a grid: a grid button's picture is 40 points on any screen, which is what
        // "very small" on a car's screen was (2026-10-10).
        let row = try cards(h.delegate)
        let elements = row.elements.compactMap { $0 as? CPListImageRowItemCardElement }
        #expect(elements.map(\.title) == ["Ask", "Talk", "New Chat"])
        #expect(elements.map(\.subtitle) == ["One question", "Hands-free", "Start fresh"])
        // Wide cards: the car gives a card the shape of its thumbnail, and a square picture
        // set inside a card makes one half as wide.
        if #available(iOS 26.4, *) {
            let pictures = elements.compactMap { $0.thumbnail?.image }
            #expect(pictures.count == 3, "a card without a thumbnail is the small kind")
            #expect(pictures.allSatisfy { $0.size.width > $0.size.height * 1.7 })
        }
        #expect(row.allowsMultipleLines, "on the smallest screens two wide cards fill a line, and the third must not fall off it")
        #expect(row.text == nil, "nothing is open yet")
        #expect(row.handler == nil)
        await h.ask("Plan the lake trip")
        let named = try cards(h.delegate)
        #expect(named.text == "Now in “Plan the lake trip”")
        #expect(named.handler != nil, "the car puts an arrow after that line: it has to lead somewhere")
    }

    @Test func theAskTabListsAFewOtherChatsUnderItsCards() async throws {
        let h = Harness()
        for title in ["One", "Two", "Three", "Four", "Five", "Six"] {
            await h.ask(title)
            h.conversation.reset()
        }
        await h.ask("Plan the lake trip")
        let open = h.conversation.id
        #expect(h.delegate.askSections().count == 1, "nothing has been read from the phone yet")
        _ = try await h.delegate.chatRows()
        let sections = h.delegate.askSections()
        #expect(sections.count == 2)
        #expect(sections.last?.header == "Recent")
        let recent = sections.last?.items.compactMap { $0 as? CPListItem } ?? []
        // The newest four of the others: the open one is named above the cards already.
        #expect(recent.map(\.text) == ["Six", "Five", "Four", "Three"])
        #expect(recent.count == CarPlaySceneDelegate.recentOnAsk)
        #expect(recent.allSatisfy { $0.accessoryImage == nil })

        try await press(recent.last)
        #expect(h.conversation.id != open)
        #expect(h.conversation.messages.first?.text == "Three")
        try await waitUntil("listening") { h.recognizer.starts == 1 }
    }

    // MARK: Take a note

    private func row(_ title: String, of delegate: CarPlaySceneDelegate) throws -> CPListItem {
        try #require(delegate.askSections().first?.items.compactMap { $0 as? CPListItem }.first { $0.text == title })
    }

    private func noteRow(_ delegate: CarPlaySceneDelegate) throws -> CPListItem { try row("Take a Note", of: delegate) }

    /// Short answers can be switched from the car's screen, without picking up the phone.
    @Test func theShortAnswersRowIsASwitch() async throws {
        let h = Harness()
        #expect(h.delegate.askSections().first?.items.count == 3, "the cards, Take a Note and Short Answers")
        let off = try row("Short Answers", of: h.delegate)
        #expect(off.detailText == "Off. Replies are read in full.")
        #expect(off.image != nil)
        let offSwitch = try #require(off.accessoryImage?.pngData())
        // A picture at the end of a row has to fit the list's own limit, or CarPlay blows it up.
        let size = try #require(off.accessoryImage?.size), most = CPListItem.maximumImageSize
        #expect(size.width <= most.width && size.height <= most.height, "the switch is \(size), the limit \(most)")

        try await press(off)
        #expect(h.settings.shortAnswersInCar)
        // The pick outlives the app, as one made in Settings does.
        #expect(Settings(defaults: h.defaults).shortAnswersInCar)
        let on = try row("Short Answers", of: h.delegate)
        #expect(on.detailText == "On. Say “more” for the rest.")
        #expect(try #require(on.accessoryImage?.pngData()) != offSwitch, "the switch looks the same on as off")

        // Turned off on the phone, the row says so too.
        h.settings.shortAnswersInCar = false
        #expect(try row("Short Answers", of: h.delegate).detailText == "Off. Replies are read in full.")
        try await press(try row("Short Answers", of: h.delegate))
        try await press(try row("Short Answers", of: h.delegate))
        #expect(!h.settings.shortAnswersInCar, "pressed twice, it is back where it was")
    }

    @Test func theNoteRowListensForANoteAndSaysNothingBack() async throws {
        let h = Harness()
        let row = try noteRow(h.delegate)
        #expect(row.text == "Take a Note" && row.detailText == "Say it, and Redde files it. Nothing is said back.")
        #expect(row.image != nil)

        try await press(row)
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        #expect(h.session.isCapturing)
        h.recognizer.deliver("The plumber comes Thursday at ten.")
        try await waitUntil("noted") { h.session.phase == .speaking }
        #expect(h.taken.notes == ["The plumber comes Thursday at ten."])
        #expect(h.speaker.spoken == ["Noted."])
        #expect(h.conversation.messages.isEmpty && !h.conversation.isStreaming, "nothing went to the conversation")
        h.speaker.finishSpeaking()
        #expect(h.session.phase == .idle && h.recognizer.starts == 1)
    }

    @Test func theNoteRowCountsWhatIsStillWaiting() async throws {
        let h = Harness()
        h.delegate.notes.retryDelays = [600]
        h.delegate.notes.add("Renew the car registration")
        #expect(try noteRow(h.delegate).detailText == "1 note waiting to be sent")
        h.delegate.notes.add("Call the school on Monday")
        #expect(try noteRow(h.delegate).detailText == "2 notes waiting to be sent")
    }

    @Test func askAndTalkListenInTheirOwnModes() async throws {
        let h = Harness()
        try await press(card: 1, of: h.delegate)
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        #expect(h.session.continuous)
        h.delegate.pressed(.stop)
        try await press(card: 0, of: h.delegate)
        try await waitUntil("listening again") { h.recognizer.starts == 2 }
        #expect(!h.session.continuous)
        // A press the row can't place is nothing, not a crash.
        try await press(card: 7, of: h.delegate)
        #expect(h.recognizer.starts == 2)
    }

    @Test(arguments: [false, true]) func newChatStartsFreshAndListens(handsFreeByDefault: Bool) async throws {
        let h = Harness()
        h.settings.handsFreeByDefault = handsFreeByDefault
        await h.ask("Plan the lake trip")
        let before = h.conversation.id
        try await press(card: 2, of: h.delegate)
        #expect(h.conversation.id != before)
        #expect(!h.conversation.hasMessages)
        #expect(h.store.sorted.map(\.id) == [before], "the one that was open stays in the list")
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        #expect(h.session.phase == .listening)
        #expect(h.session.continuous == handsFreeByDefault)
    }

    // MARK: The Chats tab

    @Test func onlyTheOpenChatIsMarked() async throws {
        let h = Harness()
        await h.ask("Plan the lake trip")
        h.conversation.reset()
        await h.ask("What's for dinner")
        let rows = try await h.delegate.chatRows()
        #expect(rows.map(\.text) == ["What's for dinner", "Plan the lake trip"])
        #expect(rows.map { $0.accessoryImage != nil } == [true, false])
        #expect(rows.allSatisfy { $0.image == nil }, "a picture on one row alone would push its name out of line with the others")
    }

    @Test func pickingAChatOpensItAndListens() async throws {
        let h = Harness()
        await h.ask("Plan the lake trip")
        let lake = h.conversation.id
        h.conversation.reset()
        await h.ask("What's for dinner")
        let rows = try await h.delegate.chatRows()
        #expect(rows.map(\.text) == ["What's for dinner", "Plan the lake trip"])
        #expect(rows.first?.detailText == CarPlayChats.currentDetail)

        try await press(rows.last)
        #expect(h.conversation.id == lake)
        #expect(h.conversation.messages.first?.text == "Plan the lake trip")
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        #expect(h.session.phase == .listening)
    }

    @Test func pickingTheOpenChatJustListens() async throws {
        let h = Harness()
        await h.ask("Plan the lake trip")
        let open = h.conversation.id
        try await press(try await h.delegate.chatRows().first)
        #expect(h.conversation.id == open)
        #expect(h.conversation.messages.count == 2)
        try await waitUntil("listening") { h.recognizer.starts == 1 }
    }

    // MARK: Bots

    @MainActor final class Opened {
        var bots: [String] = []
    }

    /// On the Dashboard, a Bots tab: each bot by its name and its creature, what it is doing or
    /// when it was last talked to (never what was said), and picking one opens its chat and listens.
    @Test func onTheDashboardABotsTabListsTheBotsAndPickingOneTalksToIt() async throws {
        let h = Harness()
        #expect(h.delegate.rootTemplate().templates.count == 2, "no Bots tab off the Dashboard")
        h.settings.transport = .hermesServe
        h.settings.showBots = true
        let directory = BotDirectory()
        directory.set(BotRoster(bots: [
            HermesBot(name: "default", isDefault: true, lastActive: .now.addingTimeInterval(-3_600)),
            HermesBot(name: "scout", title: "Scout", chatID: "s-scout", lastActive: .now.addingTimeInterval(-600), preview: "Three trails under two hours"),
            HermesBot(name: "writer", displayName: "Quill"),
        ]), key: h.settings.connectionKey)
        h.delegate.bots = directory
        let opened = Opened()
        h.delegate.openBot = { opened.bots.append($0.name) }

        let tabs = h.delegate.rootTemplate()
        #expect(tabs.templates.count == 3 && tabs.templates.count <= CPTabBarTemplate.maximumTabCount)
        #expect((tabs.templates.last as? CPListTemplate)?.title == "Bots")
        let row = try #require(await h.delegate.botRows().first as? CPListImageRowItem, "one row of cards")
        let cards = row.elements.compactMap { $0 as? CPListImageRowItemCardElement }
        #expect(cards.map(\.title) == [h.settings.headerTitle, "Scout", "Quill"], "the main agent first, then the most recently talked to")
        if #available(iOS 26.4, *) { #expect(cards.allSatisfy { $0.thumbnail != nil }, "each with its creature") }
        #expect(cards[1].subtitle == DateGroup.rowTime(.now.addingTimeInterval(-600)) && cards[2].subtitle == "No chat yet")
        #expect(!cards.contains { ($0.subtitle ?? "").contains("trails") }, "never what was said")
        #expect(row.text == nil, "no bot's chat is open")

        try await press(card: 1, in: row)
        #expect(opened.bots == ["scout"])
        try await waitUntil("listening") { h.recognizer.starts == 1 }
    }

    /// Presses a card the way the car does, by its place in the row.
    private func press(card index: Int, in row: CPListImageRowItem) async throws {
        let handler = try #require(row.listImageRowHandler)
        await withCheckedContinuation { done in handler(row, index) { done.resume() } }
    }

    /// The cards of the Bots tab as it shows them now.
    private func shownBots(_ tabs: CPTabBarTemplate) -> [CPListImageRowItemCardElement] {
        let bots = tabs.templates.last as? CPListTemplate
        return ((bots?.sections.first?.items.first as? CPListImageRowItem)?.elements ?? []).compactMap { $0 as? CPListImageRowItemCardElement }
    }

    private func botsHarness(_ bots: [HermesBot]) -> (Harness, BotDirectory) {
        let h = Harness()
        h.settings.transport = .hermesServe
        h.settings.showBots = true
        let directory = BotDirectory()
        directory.set(BotRoster(bots: bots), key: h.settings.connectionKey)
        h.delegate.bots = directory
        return (h, directory)
    }

    /// A bot's face shows what it is up to (asked 2026-10-22, "make the bot tab a bit more fun"):
    /// at work, waiting on you, or asleep after a quiet day; its card's second line says it in a
    /// word or two.
    @Test func eachBotsCardShowsItsMood() async throws {
        let (h, _) = botsHarness([
            HermesBot(name: "scout", chatID: "s-scout", lastActive: .now.addingTimeInterval(-600)),
            HermesBot(name: "fixit", chatID: "s-fixit", lastActive: .now.addingTimeInterval(-600), workerActive: .now),
            HermesBot(name: "quill", chatID: "s-quill", lastActive: .now.addingTimeInterval(-3 * 86_400)),
            HermesBot(name: "new"),
        ])
        let roster = try #require(h.delegate.bots.roster)
        let moods = roster.bots.map { h.delegate.botMood($0) }
        #expect(moods == [.ready, .working, .asleep, .ready], "no chat yet is not asleep")
        let row = try #require(await h.delegate.botRows().first as? CPListImageRowItem)
        let cards = row.elements.compactMap { $0 as? CPListImageRowItemCardElement }
        let byName = Dictionary(uniqueKeysWithValues: cards.map { ($0.title, $0.subtitle ?? "") })
        #expect(byName["fixit"] == "Working" && byName["new"] == "No chat yet")
        if #available(iOS 26.4, *) {
            #expect(cards.first { $0.title == "fixit" }?.accessibilityLabel == "fixit, working")
        }
        // Each mood its own picture, in every look.
        let face = BotFace(seed: "scout")
        for look in CarPlayBotLook.allCases {
            let pictures = CarPlayArtwork.BotMood.allCases.compactMap { CarPlayArtwork.botCard(face, named: "scout", mood: $0, look: look).pngData() }
            #expect(Set(pictures).count == CarPlayArtwork.BotMood.allCases.count, "\(look): two moods look alike")
        }
    }

    /// The cards keep up while the tab is up: a bot that starts work shows it without the tab
    /// being opened again.
    @Test func theBotsCardsChangeWhenTheBotsDo() async throws {
        let (h, directory) = botsHarness([HermesBot(name: "scout", chatID: "s-scout", lastActive: .now.addingTimeInterval(-600))])
        let tabs = h.delegate.rootTemplate()
        let bots = try #require(tabs.templates.last)
        h.delegate.tabBarTemplate(tabs, didSelect: bots)
        try await waitUntil("the card") { shownBots(tabs).count == 1 }
        #expect(shownBots(tabs).first?.subtitle == DateGroup.rowTime(.now.addingTimeInterval(-600)))
        directory.set(BotRoster(bots: [HermesBot(name: "scout", chatID: "s-scout", lastActive: .now, workerActive: .now)]), key: h.settings.connectionKey)
        try await waitUntil("working") { shownBots(tabs).first?.subtitle == "Working" }
        // And another look, picked on the phone (a card's picture can be read back from iOS 26.4).
        let before = shownBotPicture(tabs)
        h.settings.carPlayBots = .stage
        if before != nil { try await waitUntil("the stage") { shownBotPicture(tabs) != before } }
        #expect(Settings(defaults: h.defaults).carPlayBots == .stage, "the pick outlives the app")
    }

    private func shownBotPicture(_ tabs: CPTabBarTemplate) -> Data? {
        guard #available(iOS 26.4, *) else { return nil }
        return shownBots(tabs).first?.thumbnail?.image.pngData()
    }

    /// The tab picked last is the one the car opens on next time (asked 2026-10-22: "make the tab
    /// selected sticky"), and Ask when that tab has gone.
    @Test func theCarOpensOnTheTabLeftLastTime() async throws {
        let (h, _) = botsHarness([HermesBot(name: "scout")])
        #expect(h.settings.carPlayTab == "ask")
        let tabs = h.delegate.rootTemplate()
        h.delegate.tabBarTemplate(tabs, didSelect: tabs.templates[2])
        try await waitUntil("remembered") { h.settings.carPlayTab == "bots" }
        #expect(Settings(defaults: h.defaults).carPlayTab == "bots", "kept for the next time")

        let again = h.delegate.rootTemplate()
        #expect(h.delegate.rememberedTab() === again.templates[2])
        h.delegate.tabBarTemplate(again, didSelect: again.templates[1])
        try await waitUntil("chats") { h.settings.carPlayTab == "chats" }
        #expect(h.delegate.rememberedTab() === again.templates[1])
        // Off the Dashboard there is no Bots tab: the car opens on Ask.
        h.settings.carPlayTab = "bots"
        h.settings.transport = .chatCompletions
        let off = h.delegate.rootTemplate()
        #expect(off.templates.count == 2 && h.delegate.rememberedTab() == nil)
    }

    // MARK: The voice card

    /// The face look says what is going on over the face, as the others do (his word
    /// 2026-10-22, "I still want it to say speaking over the bot", after a round without titles),
    /// except while it speaks: then the face is bigger with no title over it, and its mouth and
    /// green aura say so (his pick 2026-10-23, "the b size is good").
    @Test func theFaceLookSaysWhatIsGoingOnOverTheFace() throws {
        let h = Harness()
        h.settings.carPlayVoice = .redde
        let faces = h.delegate.voiceTemplate(moving: false).voiceControlStates.map(\.titleVariants)
        h.settings.carPlayVoice = .bars
        let bars = h.delegate.voiceTemplate(moving: false).voiceControlStates.map(\.titleVariants)
        #expect(bars[2] == ["Speaking…"])
        #expect((faces[2] ?? []).isEmpty)
        #expect(faces.enumerated().filter { $0.offset != 2 }.map(\.element) == bars.enumerated().filter { $0.offset != 2 }.map(\.element))
    }

    /// In a bot's chat the face look draws that bot, not Redde.
    @Test func aBotsChatShowsTheBotsFace() throws {
        let redde = CarPlayArtwork.voicePicture(.speaking, look: .redde, face: nil).pngData()
        let scout = CarPlayArtwork.voicePicture(.speaking, look: .redde, face: BotFace(seed: "scout")).pngData()
        #expect(redde != scout)
        #expect(CarPlayArtwork.voicePicture(.speaking, look: .redde, face: BotFace(seed: "scout")).pngData() == scout)
    }

    /// Settings → Appearance → CarPlay voice screen: the card shows its five states in the look
    /// picked there, and in solid bars until something else is.
    @Test func theVoiceCardIsDrawnInTheLookPickedInSettings() throws {
        let h = Harness()
        #expect(h.settings.carPlayVoice == .bars)
        var drawn: Set<Data> = []
        for look in CarPlayVoiceLook.allCases {
            h.settings.carPlayVoice = look
            let states = h.delegate.voiceTemplate(moving: false).voiceControlStates
            #expect(states.map(\.identifier) == ["listening", "thinking", "speaking", "paused", "phone"])
            // What the card is seen doing is drawn in no other look's way. (The phone it waits
            // for is the same phone in lamps as in solid bars.)
            for state in states.prefix(4) {
                let picture = try #require(state.image?.pngData())
                #expect(drawn.insert(picture).inserted, "\(look) \(state.identifier) is drawn as something else already is")
            }
        }
        #expect(drawn.count == 20)
        h.settings.carPlayVoice = .orb
        // The pick outlives the app.
        #expect(Settings(defaults: h.defaults).carPlayVoice == .orb)
    }

    @Test func theCardStaysWithinFiveStatesAndEachHasAWayOut() {
        let template = Harness().delegate.voiceTemplate()
        let states = template.voiceControlStates
        #expect(states.map(\.identifier) == ["listening", "thinking", "speaking", "paused", "phone"])
        #expect(states.count <= 5, "a voice-control template drops any state past its fifth")
        typealias D = CarPlaySceneDelegate
        for state in CarPlayArtwork.VoiceState.allCases {
            #expect(D.barButtons(for: state).leading == (state == .paused ? [.done] : [.stop]), "\(state) has no way out")
        }
        // Pause whatever Redde is at, and Resume once it is held.
        for state in [CarPlayArtwork.VoiceState.listening, .thinking, .speaking] {
            #expect(D.barButtons(for: state).trailing == [.pause], "\(state) can't be paused")
        }
        #expect(D.barButtons(for: .paused).trailing == [.resume])
        #expect(D.barButtons(for: .phone).trailing.isEmpty, "a request waiting on the phone is not something to pause")
        if #available(iOS 26.4, *) {
            // The card opens listening.
            #expect(template.leadingNavigationBarButtons.map(\.title) == ["Stop"])
            #expect(template.trailingNavigationBarButtons.map(\.title) == ["Pause"])
        }
    }

    @Test func noStateHasActionButtonsSoThePictureHasRoom() {
        // With action buttons on a state CarPlay gives its picture a third of the height that
        // is left: 10 points on a 240-point screen, 58 on a 480-point one, where it has 90 and
        // 150 without them (drawn with CarPlay's own view, scripts/carplay-preview.sh). Builds
        // 260 and 261 had Mute and End there, and the car showed "Listening…" with no picture.
        guard #available(iOS 26.4, *) else { return }
        for state in Harness().delegate.voiceTemplate().voiceControlStates {
            #expect(state.actionButtons.isEmpty, "\(state.identifier) would squeeze its picture out")
        }
    }

    @Test func everyStateHasAPictureThatLoops() {
        // A loop that plays once would leave its first picture standing still for the rest of a
        // state that can last minutes.
        let states = Harness().delegate.voiceTemplate().voiceControlStates
        for state in states {
            #expect(state.repeats, "\(state.identifier) would stop moving after one loop")
            let image = state.image
            #expect(image != nil, "\(state.identifier) has no picture")
            // CarPlay takes at most 150 by 150 points.
            #expect((image?.size.width ?? 999) <= 150 && (image?.size.height ?? 999) <= 150, "\(state.identifier)'s picture is larger than the card takes")
        }
        #expect(CarPlayArtwork.voiceImageSide == 150)
    }

    @Test func theWaveformMovesAndTheCardHasItsBackdrop() {
        let states = Harness().delegate.voiceTemplate().voiceControlStates
        let moving = states.filter { ($0.image?.images?.count ?? 0) > 1 }.map(\.identifier)
        #expect(moving == (UIAccessibility.isReduceMotionEnabled ? [] : ["listening", "thinking", "speaking"]))
        if #available(iOS 27.0, *) {
            #expect(states.allSatisfy { $0.backgroundImage != nil })
        }
    }

    @Test func pauseWhileListeningShutsTheMicAndKeepsTheConversation() async throws {
        let h = Harness()
        try await press(card: 1, of: h.delegate)
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.delegate.pressed(.pause)
        #expect(h.session.phase == .idle)
        #expect(h.session.isMuted)
        #expect(h.card == .showing(.paused))
        #expect(h.session.continuous, "hands-free is still on for when the mic comes back")
        #expect(h.recognizer.cancels == 1)
        h.recognizer.deliver("something said in the car")
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.conversation.messages.isEmpty, "nothing heard while paused is sent")

        h.delegate.pressed(.resume)
        try await waitUntil("listening again") { h.recognizer.starts == 2 }
        #expect(h.session.phase == .listening)
        #expect(!h.session.isMuted)
        #expect(h.card == .showing(.listening))
    }

    /// The agent works on behind a pause; what it says waits, whole, for Resume.
    @Test func pauseWhileThinkingHoldsTheReplyUntilResume() async throws {
        let transport = PhoneToolsTests.HeldTransport([], then: [.textDelta("It finished at nine."), .done])
        let h = Harness(transport: transport)
        try await press(card: 0, of: h.delegate)
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("Is the backup done?")
        try await waitUntil("thinking") { h.session.phase == .thinking }
        #expect(h.card == .showing(.thinking))

        h.delegate.pressed(.pause)
        #expect(h.session.isPaused)
        #expect(h.speaker.pauses == 1, "the voice is held before it has said anything")
        #expect(h.card == .showing(.paused))

        transport.letGo()
        try await waitUntil("the reply") { h.session.phase == .speaking }
        #expect(h.session.isPaused, "still held at its first word")
        #expect(h.speaker.resumes == 0)
        #expect(h.card == .showing(.paused))

        h.delegate.pressed(.resume)
        #expect(!h.session.isPaused)
        #expect(h.speaker.resumes == 1)
        #expect(h.card == .showing(.speaking))
        try await waitUntil("the reply streamed") { !h.conversation.isStreaming }
        h.speaker.finishSpeaking()
        #expect(h.card == .closed)
    }

    /// The car goes away with a reply held: nothing is left waiting for a Resume that can't be
    /// pressed, the agent's turn is not ended, and its reply is in the conversation, unsaid.
    @Test func aReplyHeldWhenTheCarGoesIsLetGoUnsaid() async throws {
        let transport = PhoneToolsTests.HeldTransport([], then: [.textDelta("It finished at nine."), .done])
        let h = Harness(transport: transport)
        try await press(card: 0, of: h.delegate)
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("Is the backup done?")
        try await waitUntil("thinking") { h.session.phase == .thinking }
        h.delegate.pressed(.pause)

        h.audio.onOutputDeviceLost?()
        #expect(h.session.phase == .idle)
        #expect(!h.session.isPaused)
        #expect(h.conversation.isStreaming, "the turn is still the agent's")
        transport.letGo()
        try await waitUntil("the reply") { !h.conversation.isStreaming }
        #expect(h.conversation.messages.last?.text == "It finished at nine.")
        #expect(h.speaker.spoken.isEmpty)
    }

    @Test func pauseWhileSpeakingHoldsTheReplyWhereItIs() async throws {
        let h = Harness()
        try await press(card: 0, of: h.delegate)
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("What's the weather in Lisbon?")
        try await waitUntil("the reply") { h.session.phase == .speaking }
        h.delegate.pressed(.pause)
        #expect(h.session.isPaused && h.speaker.pauses == 1)
        #expect(h.card == .showing(.paused))
        h.delegate.pressed(.resume)
        #expect(!h.session.isPaused && h.speaker.resumes == 1)
        #expect(h.card == .showing(.speaking))

        // Stop ends a held reply like any other, and the card waits.
        h.delegate.pressed(.pause)
        h.delegate.pressed(.stop)
        #expect(h.session.phase == .idle)
        #expect(!h.session.isPaused)
        #expect(h.card == .showing(.paused))
        h.delegate.pressed(.done)
        #expect(h.card == .closed)
    }

    @Test func aNotePausedIsStillANoteOnResume() async throws {
        let h = Harness()
        h.delegate.takeNote()
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.delegate.pressed(.pause)
        h.delegate.pressed(.resume)
        try await waitUntil("listening again") { h.recognizer.starts == 2 }
        #expect(h.session.isCapturing)
        h.recognizer.deliver("The plumber comes Thursday at ten.")
        try await waitUntil("noted") { h.session.phase == .speaking }
        #expect(h.taken.notes == ["The plumber comes Thursday at ten."])
        #expect(h.conversation.messages.isEmpty, "it did not go to the agent as a question")
    }

    /// Stop ends what Redde is doing and keeps the card up, as the phone's Stop keeps its voice
    /// screen ("the pause and stop buttons both kick me out of the screen"): Resume listens
    /// again, hands-free still on; Done ends everything, hands-free with it.
    @Test func stopKeepsTheCardAndDoneEndsEverything() async throws {
        let h = Harness()
        try await press(card: 1, of: h.delegate)
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.delegate.pressed(.stop)
        #expect(h.session.phase == .idle && !h.session.isMuted)
        #expect(h.card == .showing(.paused), "stopped, the card waits")
        #expect(CarPlaySceneDelegate.barButtons(for: .paused) == ([.done], [.resume]))
        #expect(h.session.continuous)
        h.delegate.pressed(.resume)
        try await waitUntil("listening again") { h.recognizer.starts == 2 }
        #expect(h.card == .showing(.listening) && !h.delegate.stopped)

        h.delegate.pressed(.pause)
        h.delegate.pressed(.done)
        #expect(h.session.phase == .idle)
        #expect(!h.session.isMuted)
        #expect(!h.session.continuous)
        #expect(h.card == .closed)
    }

    @Test func stopWhileSpeakingEndsTheReplyAndWaits() async throws {
        let h = Harness()
        try await press(card: 0, of: h.delegate)
        try await waitUntil("listening") { h.recognizer.starts == 1 }
        h.recognizer.deliver("What's the weather in Lisbon?")
        try await waitUntil("the reply") { h.session.phase == .speaking }
        h.delegate.pressed(.stop)
        #expect(h.session.phase == .idle && h.speaker.stops > 0)
        #expect(h.card == .showing(.paused))
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.recognizer.starts == 1, "nothing listens until Resume")
    }

    @Test func theCardFollowsTheVoiceSession() {
        typealias D = CarPlaySceneDelegate
        #expect(D.card(phase: .listening, waitingOnPhone: false, muted: false, paused: false) == .showing(.listening))
        #expect(D.card(phase: .thinking, waitingOnPhone: false, muted: false, paused: false) == .showing(.thinking))
        #expect(D.card(phase: .thinking, waitingOnPhone: true, muted: false, paused: false) == .showing(.phone))
        #expect(D.card(phase: .speaking, waitingOnPhone: false, muted: false, paused: false) == .showing(.speaking))
        // Held: the mic shut, or the reply kept back.
        #expect(D.card(phase: .idle, waitingOnPhone: false, muted: true, paused: false) == .showing(.paused))
        #expect(D.card(phase: .thinking, waitingOnPhone: false, muted: false, paused: true) == .showing(.paused))
        #expect(D.card(phase: .speaking, waitingOnPhone: false, muted: false, paused: true) == .showing(.paused))
        #expect(D.card(phase: .thinking, waitingOnPhone: true, muted: false, paused: true) == .showing(.phone), "a request on the phone comes first")
        #expect(D.card(phase: .idle, waitingOnPhone: false, muted: false, paused: false) == .closed)
        #expect(D.card(phase: .error("no route"), waitingOnPhone: false, muted: false, paused: false) == .failed)
    }
}
