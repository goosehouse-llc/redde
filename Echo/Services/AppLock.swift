import Foundation
import LocalAuthentication
import Observation
import os

/// Biometric gate for the app. Locks when the app leaves the foreground for longer than the
/// grace period; unlocks with Face ID / Touch ID, falling back to the device passcode.
@Observable
final class AppLock {
    static let shared = AppLock()

    private(set) var isLocked = false
    /// Cover shown while the app is inactive (app switcher snapshot, Control Center pull-down)
    /// so the transcript isn't captured; lifts on return unless the grace period has passed.
    private(set) var isCovered = false
    private(set) var authenticating = false
    private(set) var lastError: String?

    private let log = Logger(subsystem: "com.goosehouse.echo", category: "lock")
    private var leftForegroundAt: Date?
    private var unlockedOnce = false

    var isEnabled: Bool { Settings.shared.requireBiometrics }

    /// What the device can do; used to word the Settings toggle. Resolved once: the check is
    /// an XPC to the biometric daemon, callers ask from view bodies, and the answer cannot
    /// change while the process runs.
    static let biometryName: String = biometry.name
    static let biometrySymbol: String = biometry.symbol

    private static let biometry: (name: String, symbol: String) = {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return ("Passcode", "lock") }
        switch context.biometryType {
        case .faceID: return ("Face ID", "faceid")
        case .touchID: return ("Touch ID", "touchid")
        case .opticID: return ("Optic ID", "opticid")
        default: return ("Passcode", "lock")
        }
    }()

    // MARK: - Lifecycle hooks

    func appDidLaunch() {
        guard isEnabled else { return }
        isLocked = true
        Task { await authenticate() }
    }

    func appWillResignActive() {
        // The Face ID sheet itself resigns active; don't count that as leaving.
        guard !authenticating else { return }
        leftForegroundAt = .now
        if isEnabled { isCovered = true }
    }

    func appDidBecomeActive() {
        isCovered = false
        guard isEnabled else { isLocked = false; return }
        if !unlockedOnce { isLocked = true }
        if let left = leftForegroundAt, Date.now.timeIntervalSince(left) > Settings.shared.lockGraceSeconds {
            isLocked = true
        }
        leftForegroundAt = nil
        if isLocked { Task { await authenticate() } }
    }

    /// Called when the user flips the toggle on: prove it works now, so a broken Face ID
    /// can't lock them out later.
    func enable() async -> Bool {
        let ok = await evaluate()
        if ok { unlockedOnce = true }
        return ok
    }

    func authenticate() async {
        guard isLocked, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        if await evaluate() {
            isLocked = false
            unlockedOnce = true
            lastError = nil
        }
    }

    private func evaluate() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            lastError = error?.localizedDescription ?? "No passcode set on this device."
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Redde")
        } catch {
            lastError = (error as? LAError)?.code == .userCancel ? nil : error.localizedDescription
            log.info("authentication failed: \(error.localizedDescription)")
            return false
        }
    }
}
