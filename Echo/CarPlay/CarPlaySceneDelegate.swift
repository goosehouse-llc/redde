import CarPlay
import Observation
import UIKit

/// CarPlay, as a voice-based conversational app (entitlement
/// `com.apple.developer.carplay-voice-based-conversation`, iOS 26.4+). Opening Redde on the car
/// screen shows four rows. "Ask Redde" and "Talk with Redde" (hands-free) carry on the
/// conversation the phone has open, "New Chat" starts another, and "Recent Chats" lists the
/// phone's conversations to pick one from. Each of them ends in listening, on a voice-control
/// card that shows Listening, Thinking, Speaking, with Mute and End on it. Replies are spoken
/// only: Apple's rules for the category allow no text or imagery in responses, so the list is
/// names and times, never what was said. When a reply ends the card closes back onto the rows.
/// Requires the entitlement; inert without it.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CPInterfaceController?
    private var menu: CPListTemplate?
    private var observing = false

    /// Tests put their own voice session and conversation here; the app's one of each otherwise.
    var sessionOverride: VoiceSession?
    var conversationOverride: Conversation?
    /// Where Recent Chats are listed from, and how a picked chat starts listening.
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
            let menu = CPListTemplate(title: "Redde", sections: menuSections())
            self.menu = menu
            interfaceController.setRootTemplate(menu, animated: false, completion: nil)
            observe()
            // The car just connected: have llama-swap load the model before the first question.
            if let conversation { ModelWarmer.warm(conversation) }
        }
    }

    nonisolated func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        Task { @MainActor in
            // The conversation keeps running on the phone; only the car UI goes away.
            controller = nil
            menu = nil
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

    // MARK: - Menu

    /// The rows the car screen opens on. Not private, so the tests can press them.
    func menuSections() -> [CPListSection] {
        let ask = CPListItem(text: "Ask Redde", detailText: "One question, answered out loud", image: CarPlayArtwork.rowIcon(.ask))
        ask.handler = { [weak self] _, completion in
            self?.listen(handsFree: false)
            completion()
        }
        let handsFree = CPListItem(text: "Talk with Redde", detailText: "Hands-free until you say “that's all”", image: CarPlayArtwork.rowIcon(.talk))
        handsFree.handler = { [weak self] _, completion in
            self?.listen(handsFree: true)
            completion()
        }
        let newChat = CPListItem(text: "New Chat", detailText: "Start a fresh conversation", image: CarPlayArtwork.rowIcon(.newChat))
        newChat.handler = { [weak self] _, completion in
            self?.startNewChat()
            completion()
        }
        // Which conversation Ask and Talk carry on, so a pick (or a New Chat) shows it took.
        let open = conversation.flatMap { $0.hasMessages ? $0.title : nil }
        let chats = CPListItem(text: "Recent Chats", detailText: open.map { "Now in “\($0)”" } ?? "Carry on an earlier conversation",
                               image: CarPlayArtwork.rowIcon(.chats), accessoryImage: nil, accessoryType: .disclosureIndicator)
        chats.handler = { [weak self] _, completion in
            self?.showChats()
            completion()
        }
        return [CPListSection(items: [ask, handsFree], header: "Your agent, by voice", sectionIndexTitle: nil),
                CPListSection(items: [newChat, chats], header: "Conversations", sectionIndexTitle: nil)]
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
        listenAsSet()
    }

    /// The conversation is about to become another one: a reply still being thought about or
    /// spoken (one started on the phone; the car's own are behind the card) belongs to the old one.
    private func stopVoice() {
        if let session, session.mightBeBusy { session.cancel() }
    }

    // MARK: - Recent chats

    private func showChats() {
        let list = CPListTemplate(title: "Recent Chats", sections: [])
        list.emptyViewTitleVariants = ["Loading…"]
        list.showsSpinnerWhileEmpty = true
        controller?.pushTemplate(list, animated: true, completion: nil)
        Task {
            do {
                let rows = try await chatRows()
                list.emptyViewTitleVariants = ["No chats yet"]
                list.emptyViewSubtitleVariants = ["Ask Redde something to start one"]
                list.showsSpinnerWhileEmpty = false
                list.updateSections([CPListSection(items: rows)])
            } catch {
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
        let chats = try await CarPlayChats.load(for: conversation, settings: settings, store: store, limit: most > 0 ? most : 12)
        return chats.map { chat in
            let row = CPListItem(text: chat.title, detailText: chat.detail)
            // The row spins until the completion is called: while the transcript loads.
            row.handler = { [weak self] _, completion in
                Task { @MainActor in
                    await self?.carryOn(chat)
                    completion()
                }
            }
            return row
        }
    }

    /// Carry on the chat that was picked: it becomes the conversation the phone has open, the
    /// car goes back to the rows, and Redde listens.
    private func carryOn(_ chat: CarPlayChat) async {
        guard let conversation else { return }
        stopVoice()
        do {
            try await CarPlayChats.open(chat, in: conversation, settings: settings, store: store)
        } catch {
            alert("Couldn't open that chat")
            return
        }
        guard let controller else { listenAsSet(); return }
        controller.popToRootTemplate(animated: true) { [weak self] _, _ in
            Task { @MainActor in self?.listenAsSet() }
        }
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

    /// The card: one state per thing the voice session can be doing, each with its buttons
    /// (iOS 26.4, like the category). Five states is the most a voice-control template takes.
    /// Not private, so the tests can count them and press the buttons.
    func voiceTemplate() -> CPVoiceControlTemplate {
        func state(_ id: CarPlayArtwork.VoiceState, _ titles: [String], _ buttons: [CardButton]) -> CPVoiceControlState {
            let state = CPVoiceControlState(identifier: id.rawValue, titleVariants: titles, image: CarPlayArtwork.voiceStateImage(id), repeats: false)
            if #available(iOS 26.4, *) { state.actionButtons = buttons.map(button) }
            return state
        }
        return CPVoiceControlTemplate(voiceControlStates: [
            state(.listening, ["Listening…", "Go ahead"], [.mute, .end]),
            state(.thinking, ["Thinking…"], [.end]),
            state(.speaking, ["Speaking…"], [.end]),
            state(.muted, ["Muted"], [.unmute, .end]),
            state(.phone, ["Needs your phone"], [.end]),
        ])
    }

    enum CardButton { case mute, unmute, end }

    private func button(_ kind: CardButton) -> CPButton {
        let (symbol, title) = switch kind {
        case .mute: ("mic.slash.fill", "Mute")
        case .unmute: ("mic.fill", "Unmute")
        case .end: ("xmark", "End")
        }
        let button = CPButton(image: UIImage(systemName: symbol) ?? UIImage()) { [weak self] _ in self?.pressed(kind) }
        button.title = title
        return button
    }

    /// Mute shuts the mic and keeps the conversation; End stops whatever Redde is doing, hands-free
    /// with it, and goes back to the rows. Before these the card had no control of its own.
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
        // Reply finished, or the question was dropped: back to the rows, unless the mic is only muted.
        case .idle: muted ? .showing(.muted) : .closed
        case .error: .failed
        }
    }

    /// Track the voice session and mirror it onto the card, and keep the rows' "Now in" line on
    /// the conversation the phone has open. Observation tracking fires once per change, so
    /// re-arm after each callback.
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
                self?.menu?.updateSections(self?.menuSections() ?? [])
                self?.armTitleObservation()
            }
        }
    }

    private func phaseChanged() {
        guard let session, let voiceCard else { return }
        switch Self.card(phase: session.phase, waitingOnPhone: session.activeTool == "waiting for you", muted: session.isMuted) {
        case .showing(let state): voiceCard.activateVoiceControlState(withIdentifier: state.rawValue)
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
