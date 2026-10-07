import Foundation
import Observation

/// Bridges App Intents (and later widgets/controls) to the UI. An intent can't touch views, so it
/// posts a request here and `ContentView` reacts.
@Observable
final class LaunchRouter {
    static let shared = LaunchRouter()

    struct VoiceRequest: Equatable {
        var handsFree: Bool
        var issuedAt: Date
    }

    /// Set by an intent; consumed once by the UI.
    private(set) var pendingVoice: VoiceRequest?

    func requestVoice(handsFree: Bool) {
        pendingVoice = VoiceRequest(handsFree: handsFree, issuedAt: .now)
    }

    func consumeVoiceRequest() -> VoiceRequest? {
        defer { pendingVoice = nil }
        return pendingVoice
    }

    /// Siri's "draft a message to Sol …": open with this in the composer, not sent.
    struct DraftRequest: Equatable {
        var text: String
        var attachments: [Attachment]
        var issuedAt: Date
    }

    private(set) var pendingDraft: DraftRequest?

    func requestDraft(text: String, attachments: [Attachment]) {
        pendingDraft = DraftRequest(text: text, attachments: attachments, issuedAt: .now)
    }

    func consumeDraftRequest() -> DraftRequest? {
        defer { pendingDraft = nil }
        return pendingDraft
    }

    /// A setup link that was opened: shown for confirmation, never applied here.
    private(set) var pendingSetupCode: SetupCodeOffer?
    @ObservationIgnored private var lastSetupRequest: (result: Result<SetupCode, SetupCode.ParseError>, at: Date)?

    func requestSetup(_ offer: SetupCodeOffer) {
        // A universal link can be delivered twice, as a URL and as a web-browsing activity.
        if let last = lastSetupRequest, last.result == offer.result, Date.now.timeIntervalSince(last.at) < 2 { return }
        lastSetupRequest = (offer.result, .now)
        pendingSetupCode = offer
    }

    func consumeSetupCode() -> SetupCodeOffer? {
        defer { pendingSetupCode = nil }
        return pendingSetupCode
    }

    /// A pairing link for notifications that was opened (`PushOffer`): confirmed before anything
    /// is sent anywhere.
    private(set) var pendingPushOffer: PushOffer?
    @ObservationIgnored private var lastPushOffer: (offer: PushOffer, at: Date)?

    func requestPushPairing(_ offer: PushOffer) {
        // A universal link can be delivered twice, as a URL and as a web-browsing activity.
        if let last = lastPushOffer, last.offer == offer, Date.now.timeIntervalSince(last.at) < 2 { return }
        lastPushOffer = (offer, .now)
        pendingPushOffer = offer
    }

    func consumePushOffer() -> PushOffer? {
        defer { pendingPushOffer = nil }
        return pendingPushOffer
    }

    /// A notification from a paired Hermes was tapped: open the conversation with this Hermes
    /// session id.
    private(set) var pendingSession: String?

    func requestSession(_ id: String) { pendingSession = id }

    func consumeSession() -> String? {
        defer { pendingSession = nil }
        return pendingSession
    }
}
