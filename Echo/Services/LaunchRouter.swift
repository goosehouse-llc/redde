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
}
