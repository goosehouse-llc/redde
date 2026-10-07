import Foundation
import WatchConnectivity
import os

/// The watch's side of the pairing: takes the connection the phone pushes, asks for one when
/// it has none and the phone is in reach, and carries the questions the watch asks through
/// the phone (`WatchRelay`).
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
            let connection = WatchConnection.from(context: reply)
            Task { @MainActor in link.store?.apply(connection) }
        }, errorHandler: { error in
            let message = error.localizedDescription
            Task { @MainActor in link.log.error("sync request failed: \(message, privacy: .public)") }
        })
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        // Whatever the phone sent last is already here; a missing one is asked for.
        let connection = WatchConnection.from(context: session.receivedApplicationContext)
        Task { @MainActor in
            if let connection { self.store?.apply(connection) }
            if self.store?.connection == nil { self.requestSync() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let connection = WatchConnection.from(context: applicationContext)
        Task { @MainActor in self.store?.apply(connection) }
    }

    /// A relayed turn the phone finished and sent on its own, for a watch that had stopped asking.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let snapshot = WatchRelay.decode(WatchRelay.Snapshot.self, from: userInfo) else { return }
        Task { @MainActor in self.store?.relayDelivered(snapshot) }
    }

    // MARK: Asking through the phone

    /// One message of a relayed question, and the phone's answer to it (`WatchRelay`). The phone's
    /// app is woken for it if it isn't running; out of range, this throws.
    func relay(_ request: WatchRelay.Request) async throws -> WatchRelay.Snapshot {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { throw WatchRelay.Failure.phoneOutOfReach }
        return try await Self.send(request)
    }

    /// Nonisolated for the same reason as `ask` above: the handlers are called on
    /// WatchConnectivity's queue.
    private nonisolated static func send(_ request: WatchRelay.Request) async throws -> WatchRelay.Snapshot {
        try await withCheckedThrowingContinuation { continuation in
            WCSession.default.sendMessage(WatchRelay.message(request), replyHandler: { reply in
                if let snapshot = WatchRelay.decode(WatchRelay.Snapshot.self, from: reply) {
                    continuation.resume(returning: snapshot)
                } else {
                    // An iPhone on an older Redde doesn't know the question.
                    continuation.resume(throwing: WatchRelay.Failure.phone("Update Redde on your iPhone: it can't take the watch's questions yet."))
                }
            }, errorHandler: { error in
                continuation.resume(throwing: error)
            })
        }
    }
}

