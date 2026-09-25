import CarPlay
import Observation
import UIKit

/// CarPlay, as a voice-based conversational app (entitlement
/// `com.apple.developer.carplay-voice-based-conversation`, iOS 26.4+). Opening Redde on the car
/// screen shows two rows, "Ask Redde" and "Talk with Redde" (hands-free); tapping one starts
/// listening, and a voice-control card shows Listening, Thinking, Speaking. Replies are spoken
/// only: Apple's rules for the category allow no text or imagery in responses. When a reply ends
/// the card closes back onto the rows. Requires the entitlement; inert without it.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CPInterfaceController?
    private var observing = false

    private var session: VoiceSession? { VoiceSession.current }

    nonisolated func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        Task { @MainActor in
            controller = interfaceController
            interfaceController.setRootTemplate(menu, animated: false, completion: nil)
            observePhase()
            // The car just connected: have llama-swap load the model before the first question.
            if let conversation = Conversation.current { ModelWarmer.warm(conversation) }
        }
    }

    nonisolated func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        Task { @MainActor in
            // The conversation keeps running on the phone; only the car UI goes away.
            controller = nil
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

    private var menu: CPListTemplate {
        let ask = CPListItem(text: "Ask Redde", detailText: "One question, answered out loud", image: CarPlayArtwork.rowIcon(.ask))
        ask.handler = { [weak self] _, completion in
            self?.session?.continuous = false
            self?.startListening()
            completion()
        }
        let handsFree = CPListItem(text: "Talk with Redde", detailText: "Hands-free until you say “that's all”", image: CarPlayArtwork.rowIcon(.talk))
        handsFree.handler = { [weak self] _, completion in
            self?.session?.continuous = true
            self?.startListening()
            completion()
        }
        let section = CPListSection(items: [ask, handsFree], header: "Your agent, by voice", sectionIndexTitle: nil)
        return CPListTemplate(title: "Redde", sections: [section])
    }

    private func startListening() {
        guard let session else { return }
        showVoiceCard()
        session.beginListening()
    }

    // MARK: - Voice card

    /// CPVoiceControlTemplate is a modal template: present and dismiss it, never push it.
    private var voiceCard: CPVoiceControlTemplate? { controller?.presentedTemplate as? CPVoiceControlTemplate }

    private func showVoiceCard() {
        guard let controller, voiceCard == nil else { return }
        controller.presentTemplate(voiceTemplate(), animated: true) { [weak self] _, _ in
            Task { @MainActor in self?.phaseChanged() }
        }
    }

    private func hideVoiceCard() {
        guard let controller, voiceCard != nil else { return }
        controller.dismissTemplate(animated: true, completion: nil)
    }

    private func voiceTemplate() -> CPVoiceControlTemplate {
        func state(_ id: CarPlayArtwork.VoiceState, _ titles: [String], repeats: Bool) -> CPVoiceControlState {
            CPVoiceControlState(identifier: id.rawValue, titleVariants: titles, image: CarPlayArtwork.voiceStateImage(id), repeats: repeats)
        }
        return CPVoiceControlTemplate(voiceControlStates: [
            state(.listening, ["Listening…", "Go ahead"], repeats: true),
            state(.thinking, ["Thinking…"], repeats: true),
            state(.speaking, ["Speaking…"], repeats: true),
            state(.idle, ["Done"], repeats: false),
            state(.error, ["Couldn't reach Redde"], repeats: false),
            state(.phone, ["Needs your phone"], repeats: false),
        ])
    }

    /// Track the voice session's phase and mirror it onto the card. Observation tracking fires
    /// once per change, so re-arm after each callback.
    private func observePhase() {
        guard !observing else { return }
        observing = true
        armPhaseObservation()
    }

    private func armPhaseObservation() {
        guard let session else { return }
        withObservationTracking {
            _ = session.phase
            _ = session.activeTool   // an approval request parks the turn on the phone
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.phaseChanged()
                self?.armPhaseObservation()
            }
        }
    }

    private func phaseChanged() {
        guard let session, controller != nil else { return }
        let state: CarPlayArtwork.VoiceState = switch session.phase {
        case .listening: .listening
        case .thinking: session.activeTool == "waiting for you" ? .phone : .thinking
        case .speaking: .speaking
        case .idle: .idle
        case .error: .error
        }
        voiceCard?.activateVoiceControlState(withIdentifier: state.rawValue)
        // Reply finished, or it failed: back to the two rows after a beat. The card has no
        // dismiss control of its own, so an error left up would strand the driver.
        let resting = session.phase == .idle && !session.continuous || state == .error
        if resting {
            let phase = session.phase
            Task { try? await Task.sleep(for: .seconds(1.5)); if session.phase == phase { hideVoiceCard() } }
        }
    }
}
