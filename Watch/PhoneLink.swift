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
        session.sendMessage([WatchConnection.syncRequest: true], replyHandler: { [weak self] reply in
            let connection = WatchConnection.from(context: reply)
            Task { @MainActor in self?.store?.apply(connection) }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in self?.log.error("sync request failed: \(error.localizedDescription, privacy: .public)") }
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
}

