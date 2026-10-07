import Foundation
import WatchConnectivity
import os

/// The phone's side of the Apple Watch app: keeps the watch supplied with a connection it can
/// use by itself (`WatchConnection`). The phone pushes whenever its settings may have changed and
/// answers the watch's own request for a copy. After that the watch talks to Hermes directly,
/// except where only the phone can: a phone on the Dashboard alone takes the watch's questions
/// here and runs them itself (`WatchRelayHost`).
@MainActor
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "watch")

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// The connection the watch should use. The watch itself speaks plain HTTP, so the Hermes
    /// API or the fast lane, never the Dashboard (see `WatchConnection`); what the Dashboard
    /// alone can reach, the phone asks for it (`.phone`, `WatchRelayHost`).
    ///
    /// A phone on the fast lane hands that over. A phone on either Hermes connection hands over
    /// the agent: by the Hermes API when that is set up, since the watch can then ask with the
    /// phone out of reach, else through the phone. Whatever isn't set up, the next stands in;
    /// nothing at all, and the watch says to set up the phone.
    static func connection(_ settings: Settings = .shared, gatewayKey: (() -> String?)? = nil,
                           dashboardPassword: () -> String? = { Keychain.read(.serveDashboardPassword) }) -> WatchConnection? {
        func made(_ kind: WatchConnection.Kind, url: String = "", key: String = "", model: String, provider: String = "") -> WatchConnection {
            WatchConnection(kind: kind, url: url, apiKey: key, model: model, provider: provider,
                            reasoningEffort: settings.reasoningEffort, replyLanguage: settings.replyLanguage,
                            agentName: settings.headerTitle)
        }
        let key: String? = if let gatewayKey { gatewayKey() } else { settings.gatewayAPIKey }
        let api: WatchConnection? = {
            guard let base = settings.gatewayBaseURL, let key, !key.isEmpty else { return nil }
            return made(.hermesAPI, url: base.absoluteString, key: key, model: settings.gatewayModel, provider: settings.gatewayProvider)
        }()
        let viaPhone: WatchConnection? = {
            guard settings.serveBaseURL != nil, !settings.serveUsername.isEmpty,
                  let password = dashboardPassword(), !password.isEmpty else { return nil }
            return made(.phone, model: settings.gatewayModel, provider: settings.gatewayProvider)
        }()
        let fastLane: WatchConnection? = Settings.normalizedBase(settings.fastLaneURL).map { base in
            made(.fastLane, url: base.absoluteString, key: Keychain.read(.fastLaneAPIKey) ?? "", model: settings.fastLaneModel)
        }
        guard var connection = settings.transport == .chatCompletions ? fastLane ?? api ?? viaPhone : api ?? viaPhone ?? fastLane else { return nil }
        if settings.useKokoro, let kokoro = settings.kokoroBaseURL {
            connection.kokoroURL = kokoro.absoluteString
            connection.kokoroVoice = settings.kokoroVoice
            connection.voiceSpeed = settings.voiceSpeed
        }
        return connection
    }

    /// Send the current connection over; an empty context tells the watch there is none.
    func push() {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        do {
            try session.updateApplicationContext(Self.connection()?.asContext() ?? [:])
        } catch {
            log.error("watch context not sent: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A relayed turn that has finished, sent without being asked for: queued, so it arrives
    /// when the watch's app next runs even if it had stopped polling (a lowered wrist).
    func deliver(_ snapshot: WatchRelay.Snapshot) {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        session.transferUserInfo(WatchRelay.message(snapshot))
    }

    // MARK: WCSessionDelegate (called off the main actor)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in self.push() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The person switched watches: the session must be activated again for the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.push() }
    }

    /// The watch asks for the connection and wants it in the reply, not whenever the context
    /// happens to land. The settings live on the main actor; the reply handler is called here.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        // A question the watch asks through the phone, or its "where has it got to?".
        if let request = WatchRelay.decode(WatchRelay.Request.self, from: message) {
            let snapshot = DispatchQueue.main.sync { MainActor.assumeIsolated { WatchRelayHost.shared.handle(request) } }
            return replyHandler(WatchRelay.message(snapshot))
        }
        guard message[WatchConnection.syncRequest] != nil else { return replyHandler([:]) }
        // Encoded on the main actor (Data crosses threads; a [String: Any] can't), unpacked here.
        let encoded: Data? = DispatchQueue.main.sync { MainActor.assumeIsolated { Self.connection().flatMap { try? JSONEncoder().encode($0) } } }
        replyHandler(encoded.map { [WatchConnection.contextKey: $0] } ?? [:])
    }
}
