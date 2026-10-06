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

    /// The connection the watch should use: plain HTTP only, so the Hermes API or the fast lane,
    /// never the Dashboard (see `WatchConnection`). A phone on the fast lane hands that over; a
    /// phone on either Hermes connection hands over the Hermes API, which is the same agent.
    /// Whichever of the two isn't set up, the other stands in; neither, and there is nothing
    /// (the watch then says what to do on the phone).
    static func connection(_ settings: Settings = .shared, gatewayKey: (() -> String?)? = nil) -> WatchConnection? {
        let key: String? = if let gatewayKey { gatewayKey() } else { settings.gatewayAPIKey }
        let api: WatchConnection? = {
            guard let base = settings.gatewayBaseURL, let key, !key.isEmpty else { return nil }
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
        guard var connection = settings.transport == .chatCompletions ? fastLane ?? api : api ?? fastLane else { return nil }
        if settings.useKokoro, let kokoro = settings.kokoroBaseURL {
            connection.kokoroURL = kokoro.absoluteString
            connection.kokoroVoice = settings.kokoroVoice
            connection.voiceSpeed = settings.voiceSpeed
        }
        return connection
    }

    /// The phone has an agent, but by the Dashboard alone: nothing the watch can use. The watch
    /// is told so, and asks for the Hermes API instead of saying the phone isn't set up.
    static func needsAPI(_ settings: Settings = .shared, gatewayKey: (() -> String?)? = nil,
                         dashboardPassword: () -> String? = { Keychain.read(.serveDashboardPassword) }) -> Bool {
        guard connection(settings, gatewayKey: gatewayKey) == nil else { return false }
        guard settings.serveBaseURL != nil, !settings.serveUsername.isEmpty, let password = dashboardPassword() else { return false }
        return !password.isEmpty
    }

    /// Send the current connection over, or why there is none; an empty context is a phone that
    /// isn't set up at all.
    func push() {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        do {
            let context = Self.connection()?.asContext() ?? (Self.needsAPI() ? [WatchConnection.needsAPIKey: true] : [:])
            try session.updateApplicationContext(context)
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
        // Worked out on the main actor (Data and Bool cross threads; a [String: Any] can't), packed here.
        let (encoded, needsAPI): (Data?, Bool) = DispatchQueue.main.sync {
            MainActor.assumeIsolated { (Self.connection().flatMap { try? JSONEncoder().encode($0) }, Self.needsAPI()) }
        }
        replyHandler(encoded.map { [WatchConnection.contextKey: $0] } ?? (needsAPI ? [WatchConnection.needsAPIKey: true] : [:]))
    }
}
