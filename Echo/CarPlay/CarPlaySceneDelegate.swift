import CarPlay
import Observation
import UIKit

/// CarPlay, as a voice-based conversational app (entitlement
/// `com.apple.developer.carplay-voice-based-conversation`, iOS 26.4+). Opening Redde on the car
/// screen shows two tabs. Ask is a row of four cards: "Ask" (one question) and "Talk"
/// (hands-free) carry on the conversation the phone has open, "New Chat" starts another, and
/// "Catch Up" has Redde say what is new in the chats (`CatchUp`). Chats lists the phone's
/// conversations, the open one marked, and picking one carries it on. Each of the first three
/// ends in listening, on a voice-control card that shows Listening, Thinking, Speaking, with End
/// and Mute in its bar. Replies are spoken only: Apple's rules for the category allow no text
/// or imagery in responses, so the list is names and times, never what was said, and a catch-up
/// is said and not shown. When a reply ends the card closes back onto the tab it came from.
/// Requires the entitlement; inert without it.
///
/// What CarPlay makes of a template can be drawn without a car: see `scripts/carplay-preview.sh`.
/// Two things learned that way shape this file. A grid button's picture is 40 points on every
/// screen, so the Ask tab is cards, the largest buttons there are. And a voice state that has
/// action buttons gets a third of what height is left for its picture, a speck on most screens
/// and nothing on a short one, so the card's controls are in its bar.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPTabBarTemplateDelegate {
    private var controller: CPInterfaceController?
    private var tabs: CPTabBarTemplate?
    private var askTab: CPListTemplate?
    private var chatsTab: CPListTemplate?
    /// Counts the loads of the Chats tab, so that a slow one can't write over a later one.
    private var chatsLoad = 0
    /// The phone's conversations as last read, for the few the Ask tab shows under its cards.
    private var chats: [CarPlayChat] = []
    private var observing = false

    /// Tests put their own voice session and conversation here; the app's one of each otherwise.
    var sessionOverride: VoiceSession?
    var conversationOverride: Conversation?
    /// Where the Chats tab lists from, and how a picked chat starts listening.
    var settings = Settings.shared
    var store = ConversationStore.shared

    private var session: VoiceSession? { sessionOverride ?? VoiceSession.current }
    private var conversation: Conversation? { conversationOverride ?? Conversation.current }

    /// The car is connected, whether or not Redde is on its screen right now.
    static var isConnected: Bool {
        UIApplication.shared.connectedScenes.contains { $0 is CPTemplateApplicationScene }
    }

    nonisolated func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        Task { @MainActor in
            controller = interfaceController
            let tabs = rootTemplate()
            tabs.delegate = self
            interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
            observe()
            reloadChats()
            // Draw the voice card's pictures now, not at the first press.
            _ = voiceTemplate()
            #if DEBUG
            noteScreen(of: scene, interfaceController)
            #endif
            // The car just connected: have llama-swap load the model before the first question.
            if let conversation { ModelWarmer.warm(conversation) }
        }
    }

    nonisolated func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        Task { @MainActor in
            // The conversation keeps running on the phone; only the car UI goes away.
            controller = nil
            tabs = nil
            askTab = nil
            chatsTab = nil
            chats = []
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
        let tabs = CPTabBarTemplate(templates: [ask, chats])
        self.tabs = tabs
        return tabs
    }

    /// The Chats tab was opened: the phone may have been used since the list was read.
    nonisolated func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        let selected = ObjectIdentifier(selectedTemplate)
        Task { @MainActor in
            if let chatsTab, ObjectIdentifier(chatsTab) == selected { reloadChats() }
        }
    }

    /// The Ask tab: one row of four cards, under the name of the conversation they carry on.
    /// Not private, so the tests can read the cards and press them.
    func askSections() -> [CPListSection] {
        // In the look picked in Settings → Appearance → CarPlay cards.
        let look = settings.carPlayCards
        let cards = CarPlayArtwork.Start.allCases.map { start in
            // A card made from a thumbnail takes the shape of its picture, which fills it: a wide
            // picture makes a card nearly twice as wide as one with a square picture set inside.
            // Catch Up says how many chats have something new, as far as the list last read knows.
            let subtitle = start == .catchUp ? catchUpLine() : Self.subtitle(start)
            if #available(iOS 26.4, *) {
                return CPListImageRowItemCardElement(thumbnail: CPThumbnailImage(image: CarPlayArtwork.startCard(start, look: look)),
                                                     title: Self.title(start), subtitle: subtitle, tintColor: nil)
            }
            return CPListImageRowItemCardElement(image: CarPlayArtwork.startCard(start, look: look, wide: false), showsImageFullHeight: false,
                                                 title: Self.title(start), subtitle: subtitle, tintColor: nil)
        }
        // Which conversation Ask and Talk carry on, so a pick (or a New Chat) shows it took.
        let open = conversation.flatMap { $0.hasMessages ? $0.title : nil }
        // A second line is allowed: the car fits four wide cards to a line on a screen 770 points
        // across, three at 640 and two at 400, and the rest go under them, not off the edge.
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
        guard !others.isEmpty else { return [CPListSection(items: [row])] }
        return [CPListSection(items: [row]), CPListSection(items: others, header: "Recent", sectionIndexTitle: nil)]
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
        case .catchUp: "Catch Up"
        }
    }

    static func subtitle(_ start: CarPlayArtwork.Start) -> String {
        switch start {
        case .ask: "One question"
        case .talk: "Hands-free"
        case .newChat: "Start fresh"
        case .catchUp: "What's new"
        }
    }

    /// Ask is one question and Talk is hands-free until "that's all", both in the conversation
    /// the phone has open; New Chat starts another; Catch Up listens to nothing and tells.
    func chose(_ start: CarPlayArtwork.Start) {
        switch start {
        case .ask: listen(handsFree: false)
        case .talk: listen(handsFree: true)
        case .newChat: startNewChat()
        case .catchUp: catchMeUp()
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

    // MARK: - Catch me up

    /// Under "Catch Up" on its card: how many of the chats last read have something new.
    private func catchUpLine() -> String {
        guard !chats.isEmpty else { return Self.subtitle(.catchUp) }
        let new = CatchUp.moved(chats, marks: settings.catchUp).count
        return new == 0 ? "Nothing new" : "\(new) new"
    }

    /// Redde says what is new in the chats, on the voice card: Thinking while it reads them,
    /// then Speaking. Heard to its end, all of it counts as told; ended early, none of it.
    private func catchMeUp() {
        guard let session else { return }
        stopVoice()
        showVoiceCard()
        var read: Date?
        session.brief({ [weak self] in
            let now = Date.now
            read = now
            return await self?.catchUpScript(now: now) ?? ""
        }, heard: { [weak self] in
            guard let self, let read else { return }
            settings.catchUp.told = read
            reloadChats()
        })
    }

    /// How many chats' lists "Catch me up" looks through.
    private static let catchUpReach = 50

    /// What "Catch me up" says now. Not private, for the tests.
    func catchUpScript(now: Date = .now) async -> String {
        guard let conversation else { return "" }
        let marks = settings.catchUp
        let all: [CarPlayChat]
        do {
            all = try await CarPlayChats.load(for: conversation, settings: settings, store: store, limit: Self.catchUpReach)
        } catch {
            return "I couldn't reach your server to see what's new."
        }
        let moved = CatchUp.moved(all, marks: marks, now: now)
        let latest = Array(moved.prefix(CatchUp.most))
        // Each chat's own messages say what its news is; read side by side, told in the list's order.
        let reads = latest.map { chat in
            Task { @MainActor [settings, store] () -> CatchUp.Item? in
                guard let messages = try? await CarPlayChats.messages(of: chat, in: conversation, settings: settings, store: store) else {
                    // It moved, the list says so, and it can't be read just now: named, at least.
                    return chat.lastActive.map { CatchUp.Item(title: chat.title, when: $0, said: .nothing) }
                }
                return CatchUp.item(for: chat, messages: messages, working: chat.isCurrent && conversation.isStreaming, marks: marks, now: now)
            }
        }
        var found: [CatchUp.Item] = []
        for read in reads {
            if let item = await read.value { found.append(item) }
        }
        let waiting = conversation.pendingInterrupt != nil ? (conversation.hasMessages ? conversation.title : CarPlayChats.untitled) : nil
        return CatchUp.script(found, more: moved.count - latest.count, told: marks.told, waiting: waiting, now: now)
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

    // MARK: - Voice card

    /// CPVoiceControlTemplate is a modal template: present and dismiss it, never push it.
    private var voiceCard: CPVoiceControlTemplate? { controller?.presentedTemplate as? CPVoiceControlTemplate }

    private func showVoiceCard() {
        guard voiceCard == nil else { return }
        present(voiceTemplate()) { [weak self] in self?.phaseChanged() }
    }

    private func hideVoiceCard() {
        guard let controller, voiceCard != nil else { return }
        controller.dismissTemplate(animated: true, completion: nil)
    }

    /// The card: one state per thing the voice session can be doing, with End and Mute in its
    /// bar (iOS 26.4, like the category). Five states is the most a voice-control template takes.
    /// Not private, so the tests can count them and press the buttons, and the preview can ask
    /// for the pictures standing still.
    func voiceTemplate(moving: Bool = !UIAccessibility.isReduceMotionEnabled) -> CPVoiceControlTemplate {
        // The pictures move, unless Reduce Motion is on. They are drawn for the car's screen, at
        // two pixels a point at most: some eighty of them are kept while the car is connected.
        let scale: CGFloat? = moving ? min(max(controller?.carTraitCollection.displayScale ?? 2, 1), 2) : nil
        func state(_ id: CarPlayArtwork.VoiceState, _ titles: [String]) -> CPVoiceControlState {
            let image = CarPlayArtwork.voiceStateImage(id, movingAt: scale)
            // No action buttons on a state. With them CarPlay lays the card out title, picture,
            // buttons, and the picture gets a third of the height left over: ten points on a
            // 240-point screen, where it has ninety without them. That is how "Listening…" came
            // to stand there with nothing to look at.
            if #available(iOS 27.0, *) {
                return CPVoiceControlState(identifier: id.rawValue, titleVariants: titles, image: image,
                                           backgroundImage: CarPlayArtwork.voiceBackdrop(id), repeats: true)
            }
            return CPVoiceControlState(identifier: id.rawValue, titleVariants: titles, image: image, repeats: true)
        }
        let template = CPVoiceControlTemplate(voiceControlStates: [
            state(.listening, ["Listening…", "Go ahead"]),
            state(.thinking, ["Thinking…"]),
            state(.speaking, ["Speaking…"]),
            state(.muted, ["Muted"]),
            state(.phone, ["Needs your phone"]),
        ])
        setBar(of: template, for: .listening)
        return template
    }

    enum CardButton: Equatable { case mute, unmute, end }

    /// What the card's bar offers in a state: End always, and the microphone's switch while it
    /// applies. End is at the leading edge, where a card that offers nothing there gets a close
    /// button from the car, and that one takes the card down without telling anybody: the
    /// conversation would carry on unseen. (The car's own Back button still does that.)
    static func barButtons(for state: CarPlayArtwork.VoiceState) -> (leading: [CardButton], trailing: [CardButton]) {
        switch state {
        case .listening: ([.end], [.mute])
        case .muted: ([.end], [.unmute])
        case .thinking, .speaking, .phone: ([.end], [])
        }
    }

    /// Not private, so the preview can draw each state with its own bar.
    func setBar(of template: CPVoiceControlTemplate, for state: CarPlayArtwork.VoiceState) {
        guard #available(iOS 26.4, *) else { return }
        let buttons = Self.barButtons(for: state)
        template.leadingNavigationBarButtons = buttons.leading.map(barButton)
        template.trailingNavigationBarButtons = buttons.trailing.map(barButton)
    }

    private func barButton(_ kind: CardButton) -> CPBarButton {
        let title = switch kind {
        case .mute: "Mute"
        case .unmute: "Unmute"
        case .end: "End"
        }
        return CPBarButton(title: title) { [weak self] _ in self?.pressed(kind) }
    }

    /// Mute shuts the mic and keeps the conversation; End stops whatever Redde is doing, hands-free
    /// with it, and goes back to the tabs.
    func pressed(_ kind: CardButton) {
        guard let session else { return }
        switch kind {
        case .mute: session.mute()
        case .unmute: session.unmute()
        case .end:
            session.continuous = false
            session.cancel()
            hideVoiceCard()
        }
    }

    /// What the card does for where the voice session stands.
    enum Card: Equatable { case showing(CarPlayArtwork.VoiceState), closed, failed }

    static func card(phase: VoiceSession.Phase, waitingOnPhone: Bool, muted: Bool) -> Card {
        switch phase {
        case .listening: .showing(.listening)
        // An approval request parks the turn on the phone.
        case .thinking: .showing(waitingOnPhone ? .phone : .thinking)
        case .speaking: .showing(.speaking)
        // Reply finished, or the question was dropped: back to the tabs, unless the mic is only muted.
        case .idle: muted ? .showing(.muted) : .closed
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
        armTitleObservation()
        armLookObservation()
        armSeenObservation()
    }

    private func armPhaseObservation() {
        guard let session else { return }
        withObservationTracking {
            _ = session.phase
            _ = session.activeTool
            _ = session.isMuted
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.phaseChanged()
                self?.armPhaseObservation()
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
    private func armLookObservation() {
        withObservationTracking {
            _ = settings.carPlayCards
        } onChange: { [weak self] in
            Task { @MainActor in
                if let self { self.askTab?.updateSections(self.askSections()) }
                self?.armLookObservation()
            }
        }
    }

    /// A chat was seen on the phone, or heard: the Catch Up card counts one fewer.
    private func armSeenObservation() {
        withObservationTracking {
            _ = settings.catchUp
        } onChange: { [weak self] in
            Task { @MainActor in
                if let self { self.askTab?.updateSections(self.askSections()) }
                self?.armSeenObservation()
            }
        }
    }
    private func phaseChanged() {
        guard let session, let voiceCard else { return }
        switch Self.card(phase: session.phase, waitingOnPhone: session.activeTool == "waiting for you", muted: session.isMuted) {
        case .showing(let state):
            voiceCard.activateVoiceControlState(withIdentifier: state.rawValue)
            setBar(of: voiceCard, for: state)
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
    private func present(_ template: CPTemplate, then shown: (@MainActor () -> Void)? = nil) {
        guard let controller else { return }
        let show = { @MainActor in
            controller.presentTemplate(template, animated: true) { _, _ in
                Task { @MainActor in shown?() }
            }
        }
        if controller.presentedTemplate == nil {
            show()
        } else {
            controller.dismissTemplate(animated: true) { _, _ in
                Task { @MainActor in show() }
            }
        }
    }
}
