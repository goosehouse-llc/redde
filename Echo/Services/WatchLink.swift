import Foundation
import WatchConnectivity
import os

/// The phone's side of the Apple Watch app: keeps the watch supplied with a connection it can
/// use by itself (`WatchConnection`). The phone pushes whenever its settings may have changed and
/// answers the watch's own request for a copy; nothing else crosses, the watch talks to Hermes
/// directly after that.
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

    /// The connection the watch should use: the one the phone talks through, when it is set up,
    /// else the agent by whichever route is (Dashboard, Hermes API), else the fast lane, else
    /// nothing (the watch then says to set up the phone first).
    static func connection(_ settings: Settings = .shared,
                           dashboardPassword: () -> String? = { Keychain.read(.serveDashboardPassword) }) -> WatchConnection? {
        let dashboard: WatchConnection? = {
            guard let base = settings.serveBaseURL, !settings.serveUsername.isEmpty,
                  let password = dashboardPassword(), !password.isEmpty else { return nil }
            var c = WatchConnection(kind: .dashboard, url: base.absoluteString, apiKey: password,
                                    model: settings.gatewayModel, provider: settings.gatewayProvider,
                                    reasoningEffort: settings.reasoningEffort, replyLanguage: settings.replyLanguage,
                                    agentName: settings.headerTitle)
            c.username = settings.serveUsername
            c.profile = settings.profileName
            c.accessHeaders = settings.accessHeaders.isEmpty ? nil : settings.accessHeaders
            return c
        }()
        let api: WatchConnection? = {
            guard let base = settings.gatewayBaseURL, let key = settings.gatewayAPIKey, !key.isEmpty else { return nil }
            return WatchConnection(kind: .hermesAPI, url: base.absoluteString, apiKey: key,
                                   model: settings.gatewayModel, provider: settings.gatewayProvider,
                                   reasoningEffort: settings.reasoningEffort, replyLanguage: settings.replyLanguage,
                                   agentName: settings.headerTitle)
        }()
        let fastLane: WatchConnection? = Settings.normalizedBase(settings.fastLaneURL).map { base in
            WatchConnection(kind: .fastLane, url: base.absoluteString, apiKey: Keychain.read(.fastLaneAPIKey) ?? "",
                            model: settings.fastLaneModel, provider: "",
                            reasoningEffort: settings.reasoningEffort, replyLanguage: settings.replyLanguage,
                            agentName: settings.headerTitle)
        }
        let own: WatchConnection? = switch settings.transport {
        case .hermesServe: dashboard
        case .hermesSessions: api
        case .chatCompletions: fastLane
        }
        guard var connection = own ?? api ?? dashboard ?? fastLane else { return nil }
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
        guard message[WatchConnection.syncRequest] != nil else { return replyHandler([:]) }
        // Encoded on the main actor (Data crosses threads; a [String: Any] can't), unpacked here.
        let encoded: Data? = DispatchQueue.main.sync { MainActor.assumeIsolated { Self.connection().flatMap { try? JSONEncoder().encode($0) } } }
        replyHandler(encoded.map { [WatchConnection.contextKey: $0] } ?? [:])
    }
}
