import CarPlay
import Observation
import UIKit

/// CarPlay, as a voice-based conversational app (entitlement
/// `com.apple.developer.carplay-voice-based-conversation`, iOS 26.4+). Opening Redde on the car
/// screen shows two tabs. Ask is a row of three cards: "Ask" (one question) and "Talk"
/// (hands-free) carry on the conversation the phone has open, "New Chat" starts another. Chats
/// lists the phone's conversations, the open one marked, and picking one carries it on. Each of
/// them ends in listening, on a voice-control card that shows Listening, Thinking, Speaking, with
/// End and Mute in its bar. Replies are spoken only: Apple's rules for the category allow no text
/// or imagery in responses, so the list is names and times, never what was said. When a reply
/// ends the card closes back onto the tab it came from. Requires the entitlement; inert without
/// it.
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

    /// The Ask tab: one row of three cards, under the name of the conversation they carry on.
    /// Not private, so the tests can read the cards and press them.
    func askSections() -> [CPListSection] {
        let cards = CarPlayArtwork.Start.allCases.map { start in
            CPListImageRowItemCardElement(image: CarPlayArtwork.startCard(start), showsImageFullHeight: false,
                                          title: Self.title(start), subtitle: Self.subtitle(start), tintColor: nil)
        }
        // Which conversation Ask and Talk carry on, so a pick (or a New Chat) shows it took.
        let open = conversation.flatMap { $0.hasMessages ? $0.title : nil }
        let row = CPListImageRowItem(text: open.map { "Now in “\($0)”" }, cardElements: cards, allowsMultipleLines: false)
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
        // Under the cards, the conversations last carried on. A card stays some 85 points wide on
        // any screen, so on a wide one this is what keeps the tab from standing mostly empty; on
        // a small one the cards fill the screen and these are a scroll away.
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
    /// Not private, so the tests can count them and press the buttons.
    func voiceTemplate() -> CPVoiceControlTemplate {
        // The waveform moves, unless Reduce Motion is on. Its pictures are drawn for the car's
        // screen, at two pixels a point at most: some eighty of them are kept while the car is
        // connected.
        let scale: CGFloat? = UIAccessibility.isReduceMotionEnabled ? nil : min(max(controller?.carTraitCollection.displayScale ?? 2, 1), 2)
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
