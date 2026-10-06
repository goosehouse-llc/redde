import Foundation
import WatchConnectivity
import os

/// The watch's side of the pairing: takes the connection the phone pushes, and asks for one when
/// it has none and the phone is in reach.
@MainActor
final class PhoneLink: NSObject, WCSessionDelegate {
    static let shared = PhoneLink()
    private let log = Logger(subsystem: "com.goosehouse.echo.watch", category: "phone")
    private weak var store: WatchStore?

    func attach(_ store: WatchStore) {
        self.store = store
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Ask the phone for its connection now. Works only while the phone is reachable.
    func requestSync() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        Self.ask(session, for: self)
    }

    /// WatchConnectivity calls both handlers on a queue of its own. Written in `requestSync`
    /// they would be the main actor's, and the runtime traps the moment one is entered from
    /// anywhere else: the app died when the request failed (seen in the simulator), and the
    /// answer's handler was made the same way. So they are made here, outside the main actor,
    /// and hop onto it for what they do.
    private nonisolated static func ask(_ session: WCSession, for link: PhoneLink) {
        session.sendMessage([WatchConnection.syncRequest: true], replyHandler: { reply in
            let connection = WatchConnection.from(context: reply), needsAPI = WatchConnection.needsAPI(context: reply)
            Task { @MainActor in link.store?.apply(connection, needsAPI: needsAPI) }
        }, errorHandler: { error in
            let message = error.localizedDescription
            Task { @MainActor in link.log.error("sync request failed: \(message, privacy: .public)") }
        })
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        // Whatever the phone sent last is already here; a missing one is asked for.
        let context = session.receivedApplicationContext
        let connection = WatchConnection.from(context: context), needsAPI = WatchConnection.needsAPI(context: context)
        Task { @MainActor in
            if connection != nil || needsAPI { self.store?.apply(connection, needsAPI: needsAPI) }
            if self.store?.connection == nil { self.requestSync() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let connection = WatchConnection.from(context: applicationContext), needsAPI = WatchConnection.needsAPI(context: applicationContext)
        Task { @MainActor in self.store?.apply(connection, needsAPI: needsAPI) }
    }
}

