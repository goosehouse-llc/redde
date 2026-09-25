import Foundation
import os

/// Asks llama-swap to load the model a new conversation will use, so the first message doesn't
/// pay a cold model load. It only ever loads a model llama-swap lists and hasn't loaded yet —
/// warming the wrong one could evict the model Hermes is actually using.
///
/// The model: the fast lane's pick; on the Hermes backends, the gateway model picked in the app,
/// else the one the gateway reports as current. It warms the model only — the Hermes system
/// prompt is built on the gateway, which the phone can't prefill.
@MainActor
enum ModelWarmer {
    private static let log = Logger(subsystem: "com.goosehouse.echo", category: "warm")
    private static var inFlight: Task<Void, Never>?
    /// Last model asked for and when, so launch + new conversation + foreground don't stack up.
    private static var lastWarm: (model: String, at: Date)?

    static func warm(_ conversation: Conversation, settings: Settings = .shared) {
        guard inFlight == nil, let base = Settings.normalizedBase(settings.fastLaneURL) else { return }
        // The de-dupe comes before the lookup: launch, new conversation and foreground all
        // arrive within a minute, and resolving the model can mean a gateway round trip.
        if let last = lastWarm, Date.now.timeIntervalSince(last.at) < 60 { return }
        inFlight = Task {
            defer { inFlight = nil }
            guard let model = await targetModel(conversation, settings: settings) else { return }
            if let last = lastWarm, last.model == model, Date.now.timeIntervalSince(last.at) < 60 { return }
            do {
                let models = try await ModelPickerView.fastLaneModels(base: base)
                guard let entry = models.first(where: { $0.model == model }) else {
                    log.info("warm: \(model, privacy: .public) isn't a llama-swap model; skipping")
                    return
                }
                lastWarm = (model, .now)
                if entry.isCurrent { return }   // already loaded
                log.info("warm: loading \(model, privacy: .public)")
                // llama-swap starts the upstream for any /upstream/<model>/… request.
                var request = URLRequest(url: base.appending(path: "upstream/\(model)/health"))
                request.timeoutInterval = 120
                _ = try await URLSession.shared.data(for: request)
                log.info("warm: \(model, privacy: .public) ready")
            } catch {
                log.info("warm: skipped (\(error.localizedDescription, privacy: .public))")
            }
        }
    }

    private static func targetModel(_ conversation: Conversation, settings: Settings) async -> String? {
        if settings.transport == .chatCompletions { return settings.fastLaneModel.nilIfEmpty }
        if let picked = settings.gatewayModel.nilIfEmpty { return picked }
        guard let backend = SessionBackend.current(conversation),
              let options = try? await backend.modelOptions() else { return nil }
        return options.first(where: \.isCurrent)?.model
    }
}
