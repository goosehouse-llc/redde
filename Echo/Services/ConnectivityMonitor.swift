import Foundation
import Network

/// Watches the device's network path and reports when a usable connection comes back, so held
/// messages can be retried at once instead of waiting for the next backoff tick. Reachability of the
/// device says nothing about the server (Tailscale can still be off), so this only triggers a retry;
/// the retry itself decides.
nonisolated final class ConnectivityMonitor: @unchecked Sendable {
    static let shared = ConnectivityMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.goosehouse.echo.connectivity", qos: .utility)
    private let lock = NSLock()
    private var started = false
    private var wasSatisfied = true
    private var handlers: [UUID: @MainActor @Sendable () -> Void] = [:]

    /// Calls `handler` on the main actor each time the path goes from unusable to usable.
    /// Returns a token for `remove(_:)`.
    @discardableResult
    func onRestored(_ handler: @escaping @MainActor @Sendable () -> Void) -> UUID {
        let token = UUID()
        lock.lock(); handlers[token] = handler; let needsStart = !started; started = true; lock.unlock()
        if needsStart { start() }
        return token
    }

    func remove(_ token: UUID) {
        lock.lock(); handlers[token] = nil; lock.unlock()
    }

    // The update handler runs on `queue`; it is formed here, in nonisolated code, so the runtime's
    // main-actor isolation check can't trap it (see the app's MainActor-default build setting).
    private func start() {
        monitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(path.status == .satisfied) }
        monitor.start(queue: queue)
    }

    private func pathChanged(_ satisfied: Bool) {
        lock.lock()
        let restored = satisfied && !wasSatisfied
        wasSatisfied = satisfied
        let current = Array(handlers.values)
        lock.unlock()
        guard restored else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { for handler in current { handler() } }
        }
    }
}
