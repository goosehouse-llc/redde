import CarPlay
import Observation
import UIKit

/// CarPlay, as a voice-based conversational app (entitlement
/// `com.apple.developer.carplay-voice-based-conversation`, iOS 26.4+). Opening Redde on the car
/// screen shows two tabs. Ask is a row of three cards: "Ask" (one question) and "Talk"
/// (hands-free) carry on the conversation the phone has open, "New Chat" starts another. Chats
/// lists the phone's conversations, the open one marked, and picking one carries it on. Each of
/// them ends in listening, on a voice-control card that shows Listening, Thinking, Speaking, with
/// Stop and Pause in its bar (both keep the card up; Done, once stopped or paused, closes it). Replies are spoken only: Apple's rules for the category allow no text
/// or imagery in responses, so the list is names and times, never what was said. When a reply
/// ends the card closes back onto the tab it came from. Requires the entitlement; inert without
/// it.
///
/// On the Dashboard connection, with Bots on, a third tab, Bots, lists the server's bots (Hermes's
/// Bot Mode): picking one opens its own chat and listens, as picking a chat does. Each is a card:
/// the bot's creature in its mood, its name and what it is doing, never what it said. The car
/// opens on the tab it was left on.
///
/// What CarPlay makes of a template can be drawn without a car: see `scripts/carplay-preview.sh`.
/// Two things learned that way shape this file. A grid button's picture is 40 points on every
/// screen, so the Ask tab is cards, the largest buttons there are. And a voice state that has
/// action buttons gets a third of what height is left for its picture, a speck on most screens
/// and nothing on a short one, so the card's controls are in its bar.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPTabBarTemplateDelegate, CPInterfaceControllerDelegate {
    private var controller: CPInterfaceController?
    private var tabs: CPTabBarTemplate?
    private var askTab: CPListTemplate?
    private var chatsTab: CPListTemplate?
    private var botsTab: CPListTemplate?
    /// Counts the loads of the Chats tab, so that a slow one can't write over a later one.
    private var chatsLoad = 0
    private var botsLoad = 0
    /// The phone's conversations as last read, for the few the Ask tab shows under its cards.
    private var chats: [CarPlayChat] = []
    private var observing = false

    /// Tests put their own voice session and conversation here; the app's one of each otherwise.
    var sessionOverride: VoiceSession?
    var conversationOverride: Conversation?
    /// Where the Chats tab lists from, and how a picked chat starts listening.
    var settings = Settings.shared
    var store = ConversationStore.shared
    /// Quick capture's notes, for the row that takes one and says how many are waiting.
    var notes = CaptureInbox.shared
    /// The server's bots, for the Bots tab.
    var bots = BotDirectory.shared
    var activity = ChatActivity.shared
    /// How a picked bot's chat is opened; the tests put their own here.
    var openBot: ((HermesBot) async throws -> Void)?

    private var session: VoiceSession? { sessionOverride ?? VoiceSession.current }
    private var conversation: Conversation? { conversationOverride ?? Conversation.current }

    /// The car is connected, whether or not Redde is on its screen right now.
    static var isConnected: Bool {
        UIApplication.shared.connectedScenes.contains { $0 is CPTemplateApplicationScene }
    }

    nonisolated func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        Task { @MainActor in
            controller = interfaceController
            interfaceController.delegate = self
            let tabs = rootTemplate()
            tabs.delegate = self
            interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
            pickRememberedTab()
            observe()
            reloadChats()
            reloadBots()
            // The voice card's pictures now, not at the first press.
            drawAhead()
            #if DEBUG
            noteScreen(of: scene, interfaceController)
            #endif
            note("connected")
            // The car just connected: have llama-swap load the model before the first question.
            if let conversation { ModelWarmer.warm(conversation) }
        }
    }

    nonisolated func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        Task { @MainActor in
            // The conversation keeps running on the phone; only the car UI goes away.
            note("disconnected")
            controller = nil
            tabs = nil
            askTab = nil
            chatsTab = nil
            botsTab = nil
            botsWatch?.cancel()
            botsWatch = nil
            botsShown = []
            chats = []
            listensOnceOpen = false
            drawingAhead?.cancel()
            drawingAhead = nil
            CarPlayArtwork.forget()
        }
    }

    /// Maps-category variant. Only the simulator preview uses it (scripts/carplay-simulator.sh with
    /// the maps key on an iOS 26.3 simulator); Redde draws nothing in the window.
    nonisolated func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController, to window: CPWindow) {
        templateApplicationScene(scene, didConnect: interfaceController)
    }

    nonisolated func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnect interfaceController: CPInterfaceController, from window: CPWindow) {
        templateApplicationScene(scene, didDisconnectInterfaceController: interfaceController)
    }

    #if DEBUG
    /// A development build writes down the car's screen as this app finds it: nothing in CarPlay
    /// is sized to the screen, so what a given car shows follows from its size in points, and
    /// that can't be read off a dashboard. The file is in Application Support, where a Mac can
    /// copy it off the phone (`devicectl device copy from`, domain appDataContainer).
    private func noteScreen(of scene: CPTemplateApplicationScene, _ controller: CPInterfaceController) {
        var lines = ["\(Date.now.formatted(.iso8601))", "traits: scale \(controller.carTraitCollection.displayScale)"]
        // Declared never nil, and nil all the same for an app that isn't a navigation app: asked by name.
        if let window = scene.value(forKey: "carWindow") as? UIWindow {
            lines.append("window: \(Int(window.bounds.width))x\(Int(window.bounds.height)) pt, safe area \(window.safeAreaInsets)")
        } else {
            lines.append("window: none")
        }
        let screens = NSSelectorFromString("screens")
        let all: AnyObject = UIScreen.self
        if all.responds(to: screens), let found = all.perform(screens)?.takeUnretainedValue() as? [UIScreen] {
            for screen in found {
                lines.append("screen: \(Int(screen.bounds.width))x\(Int(screen.bounds.height)) pt at \(screen.scale)x, idiom \(screen.traitCollection.userInterfaceIdiom.rawValue)")
            }
        }
        let folder = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: folder.appending(path: "carplay-screen.txt"), atomically: true, encoding: .utf8)
    }
    #endif

    // MARK: - Tabs

    /// What the car screen opens on: the Ask tab's cards, and the Chats tab. Not private, so the
    /// tests can look at it.
    func rootTemplate() -> CPTabBarTemplate {
        let ask = CPListTemplate(title: "Ask", sections: askSections())
        ask.tabImage = UIImage(systemName: "mic.fill")
        askTab = ask
        let chats = CPListTemplate(title: "Chats", sections: [])
        chats.tabImage = UIImage(systemName: "list.bullet")
        chats.emptyViewTitleVariants = ["Loading…"]
        chats.showsSpinnerWhileEmpty = true
        chatsTab = chats
        var templates: [CPTemplate] = [ask, chats]
        // Bots live on the Dashboard (on the Hermes API, through its login), while the chat list shows them.
        if BotDirectory.available(settings) {
            let bots = CPListTemplate(title: "Bots", sections: [])
            bots.tabImage = UIImage(systemName: "person.2.fill")
            bots.emptyViewTitleVariants = ["Loading…"]
            bots.showsSpinnerWhileEmpty = true
            botsTab = bots
            templates.append(bots)
        }
        let tabs = CPTabBarTemplate(templates: templates)
        self.tabs = tabs
        return tabs
    }

    /// The Chats or Bots tab was opened: the phone, or the server, may have moved on since.
    /// It is remembered too, and the car opens on it the next time it connects.
    nonisolated func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        let selected = ObjectIdentifier(selectedTemplate)
        Task { @MainActor in
            if let chatsTab, ObjectIdentifier(chatsTab) == selected { reloadChats() }
            if let botsTab, ObjectIdentifier(botsTab) == selected { reloadBots() }
            if let tab = tabName(selected) { settings.carPlayTab = tab }
        }
    }

    /// A tab's name as it is remembered: "ask", "chats" or "bots".
    private func tabName(_ template: ObjectIdentifier) -> String? {
        [("ask", askTab), ("chats", chatsTab), ("bots", botsTab)].first { $0.1.map(ObjectIdentifier.init) == template }?.0
    }

    /// The tab last picked, picked again: the car opens where it was left.
    private func pickRememberedTab() {
        guard let tabs, let remembered = rememberedTab() else { return }
        tabs.select(remembered)
    }

    /// The tab to open on: the one last picked, unless it is Ask (the first already) or gone
    /// (Bots, off the Dashboard). Not private, for the tests: a tab bar picks a tab only on a car.
    func rememberedTab() -> CPTemplate? {
        let remembered: CPTemplate? = switch settings.carPlayTab {
        case "chats": chatsTab
        case "bots": botsTab
        default: nil
        }
        guard let remembered, tabs?.templates.contains(where: { $0 === remembered }) == true else { return nil }
        return remembered
    }

    /// The Ask tab: one row of three cards, under the name of the conversation they carry on.
    /// Not private, so the tests can read the cards and press them.
    func askSections() -> [CPListSection] {
        // In the look picked in Settings → Appearance → CarPlay cards.
        let look = settings.carPlayCards
        let cards = CarPlayArtwork.Start.allCases.map { start in
            // A card made from a thumbnail takes the shape of its picture, which fills it: a wide
            // picture makes a card nearly twice as wide as one with a square picture set inside.
            if #available(iOS 26.4, *) {
                return CPListImageRowItemCardElement(thumbnail: CPThumbnailImage(image: CarPlayArtwork.startCard(start, look: look)),
                                                     title: Self.title(start), subtitle: Self.subtitle(start), tintColor: nil)
            }
            return CPListImageRowItemCardElement(image: CarPlayArtwork.startCard(start, look: look, wide: false), showsImageFullHeight: false,
                                                 title: Self.title(start), subtitle: Self.subtitle(start), tintColor: nil)
        }
        // Which conversation Ask and Talk carry on, so a pick (or a New Chat) shows it took.
        let open = conversation.flatMap { $0.hasMessages ? $0.title : nil }
        // A second line is allowed for the smallest screens (400 points across), where two wide
        // cards fill a line: New Chat goes under them there, not off the edge.
        let row = CPListImageRowItem(text: open.map { "Now in “\($0)”" }, cardElements: cards, allowsMultipleLines: true)
        row.listImageRowHandler = { [weak self] _, index, completion in
            let starts = CarPlayArtwork.Start.allCases
            if starts.indices.contains(index) { self?.chose(starts[index]) }
            completion()
        }
        // The car draws that line with an arrow after it: it leads to the other conversations.
        if open != nil {
            row.handler = { [weak self] _, completion in
                self?.showChats()
                completion()
            }
        }
        // Under the cards, the conversations last carried on. The cards are a strip some 85
        // points high at the top of any screen, so on a large one this is what keeps the tab from
        // standing mostly empty; on a small one the cards fill the screen and these are a scroll
        // away.
        let others = chats.filter { !$0.isCurrent }.prefix(Self.recentOnAsk).map { self.row(for: $0) }
        let top = CPListSection(items: [row, noteRow(), brevityRow()])
        guard !others.isEmpty else { return [top] }
        return [top, CPListSection(items: others, header: "Recent", sectionIndexTitle: nil)]
    }

    /// Quick capture: under the cards, a row that listens for a note and files it (`CaptureInbox`).
    /// It says so, or how many notes are still waiting for the server.
    private func noteRow() -> CPListItem {
        let waiting = notes.waiting.count
        let detail = waiting == 0 ? "Say it, and Redde files it. Nothing is said back." : waiting == 1 ? "1 note waiting to be sent" : "\(waiting) notes waiting to be sent"
        let item = CPListItem(text: "Take a Note", detailText: detail, image: CarPlayArtwork.noteMark, accessoryImage: nil, accessoryType: .none)
        item.handler = { [weak self] _, completion in
            self?.takeNote()
            completion()
        }
        return item
    }

    /// Settings → Voice → Short answers in the car, on the car's own screen: a row that says
    /// whether it is on, with a switch drawn at its end (CarPlay's lists have no switch), and
    /// flips it when pressed. The next question asked in the car goes by it; a reply already
    /// on its way is not cut short. Not private, so the tests can press it.
    func brevityRow() -> CPListItem {
        let on = settings.shortAnswersInCar
        let item = CPListItem(text: "Short Answers", detailText: on ? "On. Say “more” for the rest." : "Off. Replies are read in full.",
                              image: CarPlayArtwork.brevityMark, accessoryImage: CarPlayArtwork.switchMark(on: on), accessoryType: .none)
        item.handler = { [weak self] _, completion in
            self?.settings.shortAnswersInCar.toggle()
            completion()
        }
        return item
    }

    /// Listens for one note, on the voice card; "Noted." and the card closes. Not while Redde is
    /// in the middle of something: a note doesn't end a reply.
    func takeNote() {
        guard let session, !session.mightBeBusy else { return }
        showVoiceCard()
        session.beginListening(capturing: true)
    }

    /// How many conversations the Ask tab lists; the Chats tab has them all.
    static let recentOnAsk = 4

    private func showChats() {
        guard let tabs, let chatsTab else { return }
        tabs.select(chatsTab)
        reloadChats()
    }

    static func title(_ start: CarPlayArtwork.Start) -> String {
        switch start {
        case .ask: "Ask"
        case .talk: "Talk"
        case .newChat: "New Chat"
        }
    }

    static func subtitle(_ start: CarPlayArtwork.Start) -> String {
        switch start {
        case .ask: "One question"
        case .talk: "Hands-free"
        case .newChat: "Start fresh"
        }
    }

    /// Ask is one question and Talk is hands-free until "that's all", both in the conversation
    /// the phone has open; New Chat starts another.
    func chose(_ start: CarPlayArtwork.Start) {
        switch start {
        case .ask: listen(handsFree: false)
        case .talk: listen(handsFree: true)
        case .newChat: startNewChat()
        }
    }

    private func listen(handsFree: Bool) {
        guard let session else { return }
        session.continuous = handsFree
        showVoiceCard()
        session.beginListening()
    }

    /// New Chat and a picked chat don't name a mode, so they take Settings → Voice's, like the
    /// phone's voice button.
    private func listenAsSet() {
        listen(handsFree: settings.handsFreeByDefault)
    }

    /// A fresh conversation, then straight to listening. The one that was open stays in the list.
    private func startNewChat() {
        guard let conversation else { return }
        stopVoice()
        conversation.reset()
        reloadChats()
        listenAsSet()
    }

    /// The conversation is about to become another one: a reply still being thought about or
    /// spoken (one started on the phone; the car's own are behind the card) belongs to the old one.
    private func stopVoice() {
        if let session, session.mightBeBusy { session.cancel() }
    }

    // MARK: - Chats

    /// Reads the phone's conversations into the Chats tab. Rows already there stay until the
    /// new ones arrive, and stay if they can't be read.
    private func reloadChats() {
        guard let list = chatsTab else { return }
        chatsLoad += 1
        let load = chatsLoad
        Task {
            do {
                let rows = try await chatRows()
                guard load == chatsLoad else { return }
                list.emptyViewTitleVariants = ["No chats yet"]
                list.emptyViewSubtitleVariants = ["Ask Redde something to start one"]
                list.showsSpinnerWhileEmpty = false
                list.updateSections([CPListSection(items: rows)])
                askTab?.updateSections(askSections())
            } catch {
                guard load == chatsLoad else { return }
                list.emptyViewTitleVariants = ["Couldn't load your chats"]
                list.emptyViewSubtitleVariants = ["Check the connection on your iPhone"]
                list.showsSpinnerWhileEmpty = false
            }
        }
    }

    /// The phone's conversations as rows, as many as the car shows. Not private, for the tests.
    func chatRows() async throws -> [CPListItem] {
        guard let conversation else { return [] }
        let most = Int(CPListTemplate.maximumItemCount)
        chats = try await CarPlayChats.load(for: conversation, settings: settings, store: store, limit: most > 0 ? most : 12)
        return chats.map { row(for: $0) }
    }

    /// A conversation as a row that carries it on, the open one marked.
    private func row(for chat: CarPlayChat) -> CPListItem {
        let row = CPListItem(text: chat.title, detailText: chat.detail, image: nil,
                             accessoryImage: chat.isCurrent ? CarPlayArtwork.openChatMark : nil, accessoryType: .none)
        // The row spins until the completion is called: while the transcript loads.
        row.handler = { [weak self] _, completion in
            Task { @MainActor in
                await self?.carryOn(chat)
                completion()
            }
        }
        return row
    }

    /// Carry on the chat that was picked: it becomes the conversation the phone has open, the
    /// mark moves to its row, and Redde listens.
    private func carryOn(_ chat: CarPlayChat) async {
        guard let conversation else { return }
        stopVoice()
        do {
            try await CarPlayChats.open(chat, in: conversation, settings: settings, store: store)
        } catch {
            alert("Couldn't open that chat")
            return
        }
        if !chat.isCurrent { reloadChats() }
        listenAsSet()
    }

    // MARK: - Bots

    /// Reads the server's bots into the Bots tab: the ones the phone has, at once, then the
    /// server's own word. While the tab is up, what the bots are doing is asked after
    /// (`watchBots`), and a card changes when its bot does (`armBotsObservation`).
    private func reloadBots() {
        guard let list = botsTab else { return }
        botsLoad += 1
        let load = botsLoad
        if let roster = cachedRoster() { showBots(roster, in: list) }
        Task {
            let roster = await freshRoster()
            guard load == botsLoad else { return }
            showBots(roster, in: list)
        }
        watchBots()
        drawAhead()
    }

    /// The bots the phone last read for this connection; nil when it has none.
    private func cachedRoster() -> BotRoster? {
        guard bots.key == settings.connectionKey, let roster = bots.roster, !roster.listed.isEmpty else { return nil }
        return roster
    }

    /// The server's bots, read again; if that fails, the phone's as they are by then, not as they
    /// were before the read (they may have moved on while it was out, and the cards with them).
    private func freshRoster() async -> BotRoster? {
        if let fresh = try? await bots.refresh(settings: settings) { return fresh }
        return bots.key == settings.connectionKey ? bots.roster : nil
    }

    /// The server's bots as the tab shows them, read again first. Not private, for the tests.
    func botRows() async -> [any CPListTemplateItem] {
        await freshRoster().map { botRows($0).rows } ?? []
    }

    /// The Bots tab brought up to date with these bots, unless it shows them as they are already.
    private func showBots(_ roster: BotRoster?, in list: CPListTemplate) {
        let (rows, shown) = roster.map(botRows) ?? ([], [])
        armBotsObservation()
        guard shown != botsShown || rows.isEmpty != list.sections.isEmpty || botsShown.isEmpty else { return }
        botsShown = shown
        list.emptyViewTitleVariants = rows.isEmpty ? ["No bots yet"] : []
        list.emptyViewSubtitleVariants = rows.isEmpty ? ["Make one in Redde on your iPhone"] : []
        list.showsSpinnerWhileEmpty = false
        list.updateSections(rows.isEmpty ? [] : [CPListSection(items: rows)])
        drawAhead()
    }

    /// The bots as one row of cards, in the look Settings → Appearance → CarPlay bot cards names,
    /// each face in its bot's mood; and what the cards say, to tell whether anything changed.
    /// Above them, whose chat is open, as the Ask tab says which conversation it carries on.
    private func botRows(_ roster: BotRoster) -> (rows: [any CPListTemplateItem], shown: [String]) {
        let listed = Array(roster.listed(in: settings.botOrderHere).prefix(Self.mostBots))
        guard !listed.isEmpty else { return ([], []) }
        let faces = roster.faces
        let look = settings.carPlayBots
        var shown: [String] = []
        let cards = listed.map { bot in
            let name = bot.label(mainName: settings.headerTitle)
            let face = faces[bot.name] ?? BotFace(seed: bot.name)
            let mood = botMood(bot)
            let detail = botDetail(bot, mood)
            let picture = CarPlayArtwork.botCard(face, named: name, mood: mood, look: look)
            shown.append("\(bot.name)|\(name)|\(detail)|" + CarPlayArtwork.botCardKey(face, named: name, mood: mood, look: look))
            if #available(iOS 26.4, *) {
                let card = CPListImageRowItemCardElement(thumbnail: CPThumbnailImage(image: picture), title: name, subtitle: detail, tintColor: nil)
                card.accessibilityLabel = "\(name), \(botDetail(bot, mood, spoken: true))"
                return card
            }
            return CPListImageRowItemCardElement(image: picture, showsImageFullHeight: false, title: name, subtitle: detail, tintColor: nil)
        }
        let open = conversation?.bot.flatMap { open in listed.first { $0.name == open.profile } }?.label(mainName: settings.headerTitle)
        shown.append("open|\(open ?? "")")
        let row = CPListImageRowItem(text: open.map { "Now with \($0)" }, cardElements: cards, allowsMultipleLines: true)
        // The card spins until the completion is called: here, until the voice card is on its way up.
        row.listImageRowHandler = { [weak self] _, index, completion in
            Task { @MainActor in
                if listed.indices.contains(index) { await self?.talk(to: listed[index]) }
                completion()
            }
        }
        return ([row], shown)
    }

    /// At most this many bots on the tab: five fit across a car's screen of 568 points.
    private static let mostBots = 12

    /// What a bot is up to: what its chat is doing, or, quiet, how long it has been.
    func botMood(_ bot: HermesBot) -> CarPlayArtwork.BotMood {
        guard let conversation else { return .ready }
        switch activity.kind(of: bot, open: conversation, settings: settings) {
        case .working: return .working
        case .needsYou: return .needsYou
        case nil:
            guard let when = bot.lastActive else { return .ready }
            return Date.now.timeIntervalSince(when) > CarPlayArtwork.asleepAfter ? .asleep : .ready
        }
    }

    /// What a bot is doing, or when it was last talked to: never what was said (the category's
    /// rule). Short, as a card's second line is; `spoken` is what VoiceOver says of it.
    private func botDetail(_ bot: HermesBot, _ mood: CarPlayArtwork.BotMood, spoken: Bool = false) -> String {
        switch mood {
        case .working: return spoken ? "working" : "Working"
        case .needsYou: return spoken ? "needs you on your iPhone" : "Needs you"
        case .ready, .asleep:
            guard let when = bot.lastActive else { return spoken ? "no chat yet" : "No chat yet" }
            return spoken ? "last talked \(DateGroup.rowTime(when))" : DateGroup.rowTime(when)
        }
    }

    /// What the cards were drawn from when the tab was last brought up to date.
    private var botsShown: [String] = []
    /// Asks the host what the bots are doing while the Bots tab is up.
    private var botsWatch: Task<Void, Never>?
    private var botsArmed = 0
    /// How often the host is asked, as the phone's chat list asks it, and the bots read again (a
    /// bot's worker, and when each chat was last active, show only there).
    private static let botsLookEvery: Duration = .seconds(5)
    private static let botsReadEvery: TimeInterval = 30

    /// The Bots tab is the one picked on the car's screen.
    private var botsTabPicked: Bool {
        guard controller != nil, let botsTab, let tabs else { return false }
        return tabs.selectedTemplate === botsTab
    }

    /// Nothing is over the tabs: no voice card, no alert.
    private var tabsInView: Bool {
        guard let controller else { return false }
        return controller.presentedTemplate == nil && controller.templates.count <= 1
    }

    /// While the Bots tab is up: what the host is doing, every few seconds (a turn under way in a
    /// bot's chat, one waiting on you), and the bots read again now and then. Whatever changes
    /// shows through `armBotsObservation`. Under the voice card it waits; it stops when another
    /// tab is picked or the car goes.
    private func watchBots() {
        guard botsWatch == nil, botsTabPicked else { return }
        botsWatch = Task { [weak self] in
            var readAt = Date.now
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.botsLookEvery)
                guard let self, self.botsTabPicked else { break }
                guard self.tabsInView, let conversation = self.conversation else { continue }
                await self.activity.look(conversation, settings: self.settings)
                if Date.now.timeIntervalSince(readAt) >= Self.botsReadEvery {
                    readAt = .now
                    _ = try? await self.bots.refresh(settings: self.settings)
                }
            }
            self?.botsWatch = nil
        }
    }

    /// Anything the cards are drawn from changed: a turn started or ended in a bot's chat, or is
    /// waiting on you; the bots were read again; another look, theme or name was picked. The tab
    /// is brought up to date, which redraws only the cards that changed. CarPlay can't animate a
    /// list, so this is how the faces move.
    private func armBotsObservation() {
        botsArmed += 1
        let armed = botsArmed
        withObservationTracking {
            _ = settings.carPlayBots
            if let roster = cachedRoster() { _ = botRows(roster) }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, armed == self.botsArmed, let list = self.botsTab else { return }
                self.showBots(self.cachedRoster(), in: list)
            }
        }
    }

    /// A bot was picked: its chat becomes the conversation the phone has open, and Redde listens.
    /// The voice card goes up at once, in the bot's face, Thinking while the chat is opened behind
    /// it, and Redde listens once it is open. The card takes a second and a half to come up on the
    /// car, and the chat used to be opened before it started (asked 2026-10-24, "a bit of a lag
    /// between pressing the bot button and it switching to the listening/speaking screen").
    /// Returns once the card is on its way up; the chat opens on.
    private func talk(to bot: HermesBot) async {
        guard let conversation, let session else { return }
        stopVoice()
        note("pressed \(bot.name)")
        guard conversation.bot?.profile != bot.name else {
            reloadChats()
            reloadBots()
            listenAsSet()
            return
        }
        session.continuous = settings.handsFreeByDefault
        stopped = false
        chatOpening = true
        listensOnceOpen = true
        let started = Date.now
        let opening = Task { [weak self] in try await self?.openChat(of: bot) }
        // The request goes out first: making the card and handing it to the car hold the phone a
        // third of a second.
        await Task.yield()
        showVoiceCard(faced: bot.name == "default" ? nil : bot.name)
        Task { [weak self] in
            let opened = await opening.result
            guard let self else { return }
            self.chatOpening = false
            // Unless Stop, Pause, Done or the car's own Back came meanwhile.
            let listen = self.listensOnceOpen
            self.listensOnceOpen = false
            switch opened {
            case .failure:
                self.note("couldn't open \(bot.name)'s chat")
                self.alert("Couldn't open \(bot.label(mainName: self.settings.headerTitle))'s chat")
            case .success:
                self.note(String(format: "chat open in %.2f s", Date.now.timeIntervalSince(started)))
                self.reloadChats()
                self.reloadBots()
                if listen { session.beginListening() } else { self.phaseChanged() }
            }
        }
    }

    private func openChat(of bot: HermesBot) async throws {
        guard let conversation else { return }
        if let openBot { try await openBot(bot) } else { try await conversation.openBot(bot, mainName: settings.headerTitle) }
    }

    /// A bot's chat is being opened for the card that is up (`talk(to:)`).
    private(set) var chatOpening = false
    /// Redde listens once it is open, and till then the card says Thinking. Stop, Pause, Done or
    /// the car's own Back meanwhile, and it doesn't.
    private(set) var listensOnceOpen = false

    // MARK: - Drawn ahead

    /// The voice card's pictures, drawn ahead for the faces it is likeliest to wear next: the open
    /// chat's, and while the Bots tab is up the first bots on it. A card drawn at the press waited
    /// a second for its pictures in the face look (measured 2026-10-24); other looks draw one set
    /// for every chat.
    private var drawingAhead: Task<Void, Never>?
    /// Bots whose faces are drawn ahead: as many as fit across his car's screen (`mostBots`).
    /// About 30 MB a face, kept while the car is connected.
    private static let botsDrawnAhead = 5

    private func drawAhead() {
        guard controller != nil else { return }
        drawingAhead?.cancel()
        let look = settings.carPlayVoice, scale = pictureScale()
        var faces: [String?] = [facedBot]
        if look == .redde, botsTabPicked, let roster = cachedRoster() {
            for bot in roster.listed(in: settings.botOrderHere).prefix(Self.botsDrawnAhead) {
                let profile = bot.name == "default" ? nil : bot.name
                if !faces.contains(profile) { faces.append(profile) }
            }
        }
        drawingAhead = Task { [weak self] in
            let started = Date.now
            var drawn = 0
            for profile in faces {
                guard let self, !Task.isCancelled else { return }
                drawn += await CarPlayArtwork.drawVoiceAhead(look: look, face: self.face(of: profile), movingAt: scale)
            }
            if drawn > 0 { self?.note(String(format: "drew %d pictures ahead in %.1f s", drawn, Date.now.timeIntervalSince(started))) }
        }
    }

    // MARK: - Voice card

    /// CPVoiceControlTemplate is a modal template: present and dismiss it, never push it.
    private var voiceCard: CPVoiceControlTemplate? { controller?.presentedTemplate as? CPVoiceControlTemplate }

    private func showVoiceCard() {
        showVoiceCard(faced: facedBot)
    }

    /// The card in the face of `profile`'s bot, Redde's for nil: a picked bot's before its chat is open.
    private func showVoiceCard(faced profile: String?) {
        guard voiceCard == nil else { return }
        note("card up")
        barShown = nil
        cardFace = profile
        present(voiceTemplate(faced: profile)) { [weak self] in self?.phaseChanged() }
    }

    /// The bot whose face the voice card wears: the open chat's, the main agent's being Redde's own.
    private var facedBot: String? { conversation?.bot.flatMap { $0.profile == "default" ? nil : $0.profile } }
    /// Whose face the card up now was drawn with.
    private var cardFace: String?

    /// A spoken name ("Home, …") moved the conversation to another bot's chat while the card was
    /// up: the card is put up again in that bot's face, as a template's pictures can't be changed.
    /// It kept the face it opened with, and the reply seemed to come from that bot (2026-10-23,
    /// "Sol bot responded, it did not switch over to Home": Home had answered).
    private func botChanged() {
        guard voiceCard != nil, facedBot != cardFace else { return }
        note("card again for \(facedBot ?? "Redde")")
        barShown = nil
        cardFace = facedBot
        present(voiceTemplate(faced: facedBot), animated: false) { [weak self] in self?.phaseChanged() }
    }

    private func hideVoiceCard() {
        guard let controller, voiceCard != nil else { return }
        closingCard = true
        controller.dismissTemplate(animated: true, completion: nil)
    }

    /// Stopped on the card (Stop): nothing going on, the card up on Paused until Resume listens
    /// again or Done closes it.
    private(set) var stopped = false
    /// When one of the card's own buttons was last pressed, and whether Redde is taking the card
    /// down itself.
    private var pressedAt: Date?
    private var closingCard = false
    /// The card's bar as last set, so it is set only when it changes.
    private var barShown: [CardButton]?

    /// The car took a template down. The voice card, gone a moment after one of its own buttons
    /// (which all mean "stay", but Done) and not by Redde, is put back as the voice session
    /// stands: a press on the card's bar was taking it down ("Pause and Stop both kick me out").
    /// Gone any other way (the car's own Back), it stays gone.
    nonisolated func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        let kind = String(describing: type(of: aTemplate))
        Task { @MainActor in self.note("gone: \(kind)") }
        guard aTemplate is CPVoiceControlTemplate else { return }
        Task { @MainActor in self.voiceCardWentAway() }
    }

    nonisolated func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
        let kind = String(describing: type(of: aTemplate))
        Task { @MainActor in self.note("up: \(kind)") }
    }

    /// What happened on the car's screen, for working out what a drive did (DEBUG only): kept in
    /// `Library/Application Support/carplay-events.txt`, the last 400 lines, and copied off the
    /// phone with `xcrun devicectl device copy from --domain-type appDataContainer`.
    func note(_ event: String) {
        #if DEBUG
        let file = URL.applicationSupportDirectory.appending(path: "carplay-events.txt")
        let earlier = (try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n").suffix(399).map(String.init) ?? []
        let line = "\(Date.now.formatted(.iso8601.time(includingFractionalSeconds: true))) \(event)"
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? (earlier + [line]).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        #endif
    }

    private func voiceCardWentAway() {
        note("card went away: \(closingCard ? "Redde's doing" : "not Redde's"), \(pressedAt.map { String(format: "%.1f s after a press", Date.now.timeIntervalSince($0)) } ?? "no press")")
        barShown = nil
        watchBots()
        if closingCard { closingCard = false; return }
        guard let pressedAt, Date.now.timeIntervalSince(pressedAt) < 2, let session, voiceCard == nil else {
            // Gone by the car's own Back: a chat being opened opens, and nothing listens.
            listensOnceOpen = false
            return
        }
        if case .showing = Self.card(phase: session.phase, waitingOnPhone: session.activeTool == "waiting for you",
                                     muted: session.isMuted, paused: session.isPaused, stopped: stopped, opening: listensOnceOpen) {
            showVoiceCard()
        }
    }

    /// The card: one state per thing the voice session can be doing, with Stop and Pause in its
    /// bar (iOS 26.4, like the category). Five states is the most a voice-control template takes.
    /// Not private, so the tests can count them and press the buttons, and the preview can ask
    /// for the pictures standing still.
    func voiceTemplate(moving: Bool = !UIAccessibility.isReduceMotionEnabled) -> CPVoiceControlTemplate {
        voiceTemplate(moving: moving, faced: facedBot)
    }

    /// The pictures move, unless Reduce Motion is on. They are drawn for the car's screen, at two
    /// pixels a point at most: about a hundred of them are kept while the car is connected.
    private func pictureScale(moving: Bool = !UIAccessibility.isReduceMotionEnabled) -> CGFloat? {
        moving ? min(max(controller?.carTraitCollection.displayScale ?? 2, 1), 2) : nil
    }

    /// The face of whoever Redde is being: the bot whose chat it is (his ask 2026-10-22, "like on
    /// the phone"), else Redde's own (nil).
    private func face(of profile: String?) -> BotFace? {
        profile.flatMap { BotDirectory.shared.roster?.faces[$0] }
    }

    private func voiceTemplate(moving: Bool = !UIAccessibility.isReduceMotionEnabled, faced profile: String?) -> CPVoiceControlTemplate {
        // In the look picked in Settings → Appearance → CarPlay voice screen.
        let look = settings.carPlayVoice
        let scale = pictureScale(moving: moving)
        let face = self.face(of: profile)
        // Every look says what is going on over its picture, the face's too (his word 2026-10-22,
        // "I still want it to say speaking over the bot"), though the picture is 69 points high
        // under a title on a 568×263 car, and 89 without one.
        func state(_ id: CarPlayArtwork.VoiceState, _ titles: [String]) -> CPVoiceControlState {
            let image = CarPlayArtwork.voiceStateImage(id, look: look, face: face, movingAt: scale)
            // No action buttons on a state. With them CarPlay lays the card out title, picture,
            // buttons, and the picture gets a third of the height left over: ten points on a
            // 240-point screen, where it has ninety without them. That is how "Listening…" came
            // to stand there with nothing to look at.
            if #available(iOS 27.0, *) {
                return CPVoiceControlState(identifier: id.rawValue, titleVariants: titles, image: image,
                                           backgroundImage: CarPlayArtwork.voiceBackdrop(id, look: look), repeats: true)
            }
            return CPVoiceControlState(identifier: id.rawValue, titleVariants: titles, image: image, repeats: true)
        }
        let template = CPVoiceControlTemplate(voiceControlStates: [
            state(.listening, ["Listening…", "Go ahead"]),
            state(.thinking, ["Thinking…"]),
            // The face look's speaking face is bigger without a title over it (`CarPlayArtwork.speakingHeight`).
            state(.speaking, look == .redde ? [] : ["Speaking…"]),
            state(.paused, ["Paused"]),
            state(.phone, ["Needs your phone"]),
        ])
        setBar(of: template, for: .listening)
        return template
    }

    enum CardButton: Equatable { case pause, resume, stop, done }

    /// What the card's bar offers in a state: Stop and Pause while Redde listens, thinks or
    /// speaks, Done and Resume once it is held or stopped. Something is always at the leading
    /// edge, where a card that offers nothing gets a close button from the car, and that one
    /// takes the card down without telling anybody: the conversation would carry on unseen. (The
    /// car's own Back button still does that.)
    static func barButtons(for state: CarPlayArtwork.VoiceState) -> (leading: [CardButton], trailing: [CardButton]) {
        switch state {
        case .listening, .thinking, .speaking: ([.stop], [.pause])
        case .paused: ([.done], [.resume])
        case .phone: ([.stop], [])
        }
    }

    /// What the card's two bar buttons do now: the leading one's, then the trailing one's (nil
    /// while it has nothing to do, as waiting on the phone).
    private var barKinds: [CardButton?] = [nil, nil]

    /// Not private, so the preview can draw each state with its own bar. The card keeps the same
    /// two buttons for as long as it is up, and only what they say and do changes (Stop and Done,
    /// Pause and Resume): the car took the card down, and Redde with it, when a press put new
    /// buttons on it (2026-10-23, "the stop and pause buttons in carplay speaking screen kick me
    /// out of the app"; the card put back after a press, 10-22, had not been enough).
    func setBar(of template: CPVoiceControlTemplate, for state: CarPlayArtwork.VoiceState) {
        guard #available(iOS 26.4, *) else { return }
        let buttons = Self.barButtons(for: state)
        barKinds = [buttons.leading.first, buttons.trailing.first]
        if template.leadingNavigationBarButtons.count != 1 || template.trailingNavigationBarButtons.count != 1 {
            template.leadingNavigationBarButtons = [barButton(slot: 0)]
            template.trailingNavigationBarButtons = [barButton(slot: 1)]
        }
        for (button, kind) in zip([template.leadingNavigationBarButtons[0], template.trailingNavigationBarButtons[0]], barKinds) {
            if let kind, button.title != Self.title(of: kind) { button.title = Self.title(of: kind) }
            if button.isEnabled != (kind != nil) { button.isEnabled = kind != nil }
        }
        note("bar \(state.rawValue): \(barKinds.map { $0.map { Self.title(of: $0) } ?? "-" }.joined(separator: " / "))")
    }

    /// A bar button that does whatever its place on the bar does now (`barKinds`).
    private func barButton(slot: Int) -> CPBarButton {
        CPBarButton(title: " ") { [weak self] _ in
            guard let self, let kind = self.barKinds[slot] else { return }
            self.pressed(kind)
        }
    }

    static func title(of kind: CardButton) -> String {
        switch kind {
        case .pause: "Pause"
        case .resume: "Resume"
        case .stop: "Stop"
        case .done: "Done"
        }
    }

    /// Pause holds whatever Redde is at and keeps the conversation: the mic is shut while it
    /// listens, so nothing said in the car is taken for a question, and the reply is held while
    /// it thinks or speaks. The agent works on behind a held reply, which is said from where it
    /// was, or from its start, on Resume. Stop ends whatever Redde is doing (the reply, the
    /// agent's turn, the listening) and keeps the card up, as the phone's Stop keeps its voice
    /// screen: Resume listens again, hands-free still on if it was. Done ends it all, hands-free
    /// with it, and goes back to the tabs.
    func pressed(_ kind: CardButton) {
        guard let session else { return }
        note("pressed \(Self.title(of: kind)) while \(session.phase)")
        pressedAt = .now
        // A bot's chat still being opened: Stop and Pause both hold it there, open but not listened
        // in, and Resume listens once it is.
        if chatOpening, session.phase == .idle, kind == .stop || kind == .pause || (kind == .resume && stopped) {
            stopped = kind != .resume
            listensOnceOpen = kind == .resume
            phaseChanged()
            return
        }
        switch kind {
        case .pause: if session.phase == .listening { session.mute() } else { session.pauseSpeaking() }
        case .resume:
            if stopped {
                stopped = false
                session.beginListening()
            } else if session.isMuted {
                session.unmute()
            } else {
                session.resumeSpeaking()
            }
        case .stop:
            stopped = true
            session.cancel()
        case .done:
            stopped = false
            listensOnceOpen = false
            session.continuous = false
            session.cancel()
            hideVoiceCard()
        }
    }

    /// What the card does for where the voice session stands.
    enum Card: Equatable { case showing(CarPlayArtwork.VoiceState), closed, failed }

    /// `heard`: the reply's sound has reached the car (`heardInCar`). Until then a reply that has
    /// begun is still Thinking on the card: its mouth moved a second or more before its voice
    /// came (asked 2026-10-23, "wait a few seconds before the mouth starts moving"). `opening`: a
    /// picked bot's chat is being opened, and Redde listens once it is (`listensOnceOpen`).
    static func card(phase: VoiceSession.Phase, waitingOnPhone: Bool, muted: Bool, paused: Bool, stopped: Bool = false,
                     heard: Bool = true, opening: Bool = false) -> Card {
        switch phase {
        case .listening: .showing(.listening)
        // An approval request parks the turn on the phone, paused or not.
        case .thinking: .showing(waitingOnPhone ? .phone : paused ? .paused : .thinking)
        case .speaking: .showing(paused ? .paused : heard ? .speaking : .thinking)
        // Reply finished, or the question was dropped: back to the tabs, unless the mic is only
        // shut for a while (Pause while listening), or Stop was pressed (the card waits).
        case .idle: muted || stopped ? .showing(.paused) : opening ? .showing(.thinking) : .closed
        case .error: .failed
        }
    }

    /// Track the voice session and mirror it onto the card, and keep both tabs on what the
    /// phone has: which conversation is open, and what it is called. Observation tracking fires
    /// once per change, so re-arm after each callback.
    private func observe() {
        guard !observing else { return }
        observing = true
        armPhaseObservation()
        armBotObservation()
        armTitleObservation()
        armLookObservation()
        armVoiceLookObservation()
        armNotesObservation()
    }

    private func armPhaseObservation() {
        guard let session else { return }
        withObservationTracking {
            _ = session.phase
            _ = session.activeTool
            _ = session.isMuted
            _ = session.isPaused
            _ = session.soundStartedAt
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.phaseChanged()
                self?.armPhaseObservation()
            }
        }
    }

    private func armBotObservation() {
        guard let conversation else { return }
        withObservationTracking {
            _ = conversation.bot?.profile
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.botChanged()
                self?.armBotObservation()
            }
        }
    }

    private func armTitleObservation() {
        guard let conversation else { return }
        withObservationTracking {
            _ = conversation.title
            _ = conversation.hasMessages
        } onChange: { [weak self] in
            Task { @MainActor in
                if let self { self.askTab?.updateSections(self.askSections()) }
                self?.reloadChats()
                self?.armTitleObservation()
            }
        }
    }

    /// Another look for the cards, picked on the phone while the car shows them.
    /// The cards' look, or short answers, was changed, on the phone or with the row here: the
    /// Ask tab is drawn again.
    private func armLookObservation() {
        withObservationTracking {
            _ = settings.carPlayCards
            _ = settings.shortAnswersInCar
        } onChange: { [weak self] in
            Task { @MainActor in
                if let self { self.askTab?.updateSections(self.askSections()) }
                self?.armLookObservation()
            }
        }
    }

    /// Another look was picked for the voice card: the next card to open has it. The pictures
    /// of the old one are let go, and the new one's drawn now, not at the next press. A card
    /// that is up keeps its pictures until it closes; a template's states can't be changed.
    private func armVoiceLookObservation() {
        withObservationTracking {
            _ = settings.carPlayVoice
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                CarPlayArtwork.keepVoicePictures(only: self.settings.carPlayVoice)
                self.drawAhead()
                self.armVoiceLookObservation()
            }
        }
    }

    /// A note was taken or handed over: the row counts again.
    private func armNotesObservation() {
        withObservationTracking {
            _ = notes.waiting.count
        } onChange: { [weak self] in
            Task { @MainActor in
                if let self { self.askTab?.updateSections(self.askSections()) }
                self?.armNotesObservation()
            }
        }
    }

    /// How long after the phone starts playing a reply the car is taken to be playing it: the
    /// car's own audio comes a little behind the phone's.
    static let carSoundLag: TimeInterval = 1

    /// Whether the reply's sound has reached the car, `lag` after the phone first played it.
    static func heardInCar(since started: Date?, lag: TimeInterval = carSoundLag, now: Date = .now) -> Bool {
        guard let started else { return false }
        return now.timeIntervalSince(started) >= lag
    }

    private var heardCheck: Task<Void, Never>?

    private func phaseChanged() {
        guard let session else { return }
        // Going again from wherever it was asked to (the phone, a card): no longer stopped.
        if session.phase != .idle { stopped = false }
        guard let voiceCard else { return }
        let heard = Self.heardInCar(since: session.soundStartedAt)
        // Sound started, not yet in the car: looked at again once it is.
        heardCheck?.cancel()
        if !heard, let started = session.soundStartedAt {
            heardCheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, Self.carSoundLag - Date.now.timeIntervalSince(started)) + 0.05))
                guard !Task.isCancelled else { return }
                self?.phaseChanged()
            }
        }
        switch Self.card(phase: session.phase, waitingOnPhone: session.activeTool == "waiting for you", muted: session.isMuted,
                         paused: session.isPaused, stopped: stopped, heard: heard, opening: listensOnceOpen) {
        case .showing(let state):
            voiceCard.activateVoiceControlState(withIdentifier: state.rawValue)
            // The bar only when its buttons change: Listening, Thinking and Speaking share one.
            let buttons = Self.barButtons(for: state)
            if barShown != buttons.leading + buttons.trailing {
                barShown = buttons.leading + buttons.trailing
                setBar(of: voiceCard, for: state)
            }
        case .closed: hideVoiceCard()
        case .failed: alert("Couldn't reach Redde")
        }
    }

    // MARK: - Modals

    private func alert(_ title: String) {
        let ok = CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            self?.controller?.dismissTemplate(animated: true, completion: nil)
        }
        present(CPAlertTemplate(titleVariants: [title], actions: [ok]))
    }

    /// The car screen takes one modal template at a time: whatever is up comes down first.
    private func present(_ template: CPTemplate, animated: Bool = true, then shown: (@MainActor () -> Void)? = nil) {
        guard let controller else { return }
        let show = { @MainActor in
            controller.presentTemplate(template, animated: animated) { _, _ in
                Task { @MainActor in shown?() }
            }
        }
        if controller.presentedTemplate == nil {
            show()
        } else {
            if controller.presentedTemplate is CPVoiceControlTemplate { closingCard = true }   // (Redde's doing: it stays down)
            controller.dismissTemplate(animated: animated) { _, _ in
                Task { @MainActor in show() }
            }
        }
    }
}
