import Foundation
import Observation

/// What `CloudSync` needs of iCloud's key-value store: `NSUbiquitousKeyValueStore`, or a stand-in
/// in tests.
protocol CloudValues: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    var dictionaryRepresentation: [String: Any] { get }
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: CloudValues {}

/// Sync with iCloud (Settings → iCloud): the person's settings and Hermes servers on every iPhone,
/// iPad and Mac signed in to the same Apple Account. Off until turned on, on each device.
///
/// The settings (`Settings.syncedKeys`) and each server's record go in iCloud's key-value store,
/// one key apiece, so two devices changing different things never undo each other; a server's
/// keys and passwords go in iCloud Keychain, end-to-end encrypted (`Keychain.syncable`). A server
/// removed on one device is removed on the others (a tombstone stays, so a device that was away
/// doesn't bring it back), unless one of them is on it. Each device keeps which server it is on,
/// and on each server the profile and model it is on.
///
/// Turned on where iCloud has nothing yet, this device's settings go up. Turned on where another
/// device's are there already, this one takes them, and adds its servers to theirs; a server this
/// device never set up (a new install that skipped setup) gives way to theirs.
@Observable
final class CloudSync {
    static let shared = CloudSync()

    enum Phase: Equatable {
        case off
        /// Turning on: waiting a moment for what another device put in iCloud to arrive.
        case looking
        case on
        /// Not signed in to iCloud (or iCloud Drive's documents and data are off for Redde).
        case noAccount
    }

    private(set) var phase: Phase = .off
    var isOn: Bool { defaults.bool(forKey: Keychain.syncKey) }

    /// Moves the app to another server (`ServerSwitcher`, with the open conversation).
    @ObservationIgnored var switchServer: (UUID) -> Void = { id in
        guard let conversation = Conversation.current else { return }
        ServerSwitcher.switchTo(id, conversation: conversation)
    }

    // Keys in iCloud.
    static let markerKey = "redde.sync"
    static let settingPrefix = "setting."
    static let serverPrefix = "server."
    static let removedKey = "servers.removed"
    /// Here: the servers this device has seen in iCloud. One of them gone from this device's list
    /// was removed here.
    private static let knownKey = "iCloudSync.knownServers"

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let cloud: CloudValues
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let signedIn: () -> Bool
    @ObservationIgnored private let lookFor: Duration
    /// Moves the syncable secrets to iCloud Keychain (true) or back (`Keychain.moveSecrets`).
    @ObservationIgnored private let moveSecrets: (Bool) -> Void
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// Set while another device's values are being taken: saving them here sends nothing back.
    @ObservationIgnored private var applying = false
    /// Turning on, waiting for iCloud's first answer.
    @ObservationIgnored private var firstAnswer: CheckedContinuation<Void, Never>?

    init(settings: Settings = .shared, cloud: CloudValues = NSUbiquitousKeyValueStore.default, defaults: UserDefaults = .standard,
         signedIn: @escaping () -> Bool = { FileManager.default.ubiquityIdentityToken != nil }, lookFor: Duration = .seconds(8),
         moveSecrets: @escaping (Bool) -> Void = { Keychain.moveSecrets(toICloud: $0) }) {
        self.settings = settings
        self.cloud = cloud
        self.defaults = defaults
        self.signedIn = signedIn
        self.lookFor = lookFor
        self.moveSecrets = moveSecrets
    }

    /// At launch: with sync on, what changed elsewhere since is taken, and changes are followed.
    func start() {
        guard isOn else { return }
        attach()
        cloud.synchronize()
        takeEverything()
        phase = signedIn() ? .on : .noAccount
    }

    /// Back in the foreground: secrets are read afresh (iCloud Keychain says nothing when another
    /// device changes one), and iCloud is asked for news.
    func cameForward() {
        guard isOn else { return }
        Keychain.forgetCache()
        cloud.synchronize()
    }

    func turnOn() async {
        guard !isOn || phase != .on else { return }
        guard signedIn() else {
            phase = .noAccount
            return
        }
        phase = .looking
        defaults.set(true, forKey: Keychain.syncKey)
        moveSecrets(true)
        attach()
        cloud.synchronize()
        // A device new to iCloud's store may not have what the others put there yet: it comes as
        // a first answer moments later. Without waiting for it, this device's settings would go
        // up as the first and overwrite theirs.
        if cloud.object(forKey: Self.markerKey) == nil {
            await withCheckedContinuation { continuation in
                firstAnswer = continuation
                Task {
                    try? await Task.sleep(for: lookFor)
                    answered()
                }
            }
        }
        guard isOn else { return }
        if cloud.object(forKey: Self.markerKey) != nil {
            // Another device's: taken, and this device's servers added.
            takeEverything()
            sendServers()
        } else {
            for key in Settings.syncedKeys { send(key) }
            sendServers()
            cloud.set(1, forKey: Self.markerKey)
        }
        cloud.synchronize()
        phase = .on
    }

    /// Off: nothing more goes up or comes down; the secrets come back to this device, and what is
    /// in iCloud stays for the other devices.
    func turnOff() {
        detach()
        answered()
        defaults.set(false, forKey: Keychain.syncKey)
        moveSecrets(false)
        defaults.removeObject(forKey: Self.knownKey)
        phase = .off
    }

    // MARK: - Following

    private func attach() {
        settings.onStore = { [weak self] key in self?.changedHere(key) }
        guard observer == nil, cloud === NSUbiquitousKeyValueStore.default else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main
        ) { [weak self] note in
            // The Sendable parts, before hopping.
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated { self?.changedElsewhere(reason: reason, keys: keys) }
        }
    }

    private func detach() {
        settings.onStore = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func answered() {
        firstAnswer?.resume()
        firstAnswer = nil
    }

    /// iCloud has news: values another device saved (`keys`), the first answer to a device new to
    /// it, or another Apple Account signed in (everything again).
    func changedElsewhere(reason: Int?, keys: [String]?) {
        answered()
        guard isOn, phase != .looking else { return }
        if reason == NSUbiquitousKeyValueStoreAccountChange || keys == nil {
            takeEverything()
            return
        }
        applying = true
        defer { applying = false }
        var servers = false
        for key in keys ?? [] {
            if key.hasPrefix(Self.settingPrefix) {
                take(String(key.dropFirst(Self.settingPrefix.count)))
            } else if key.hasPrefix(Self.serverPrefix) || key == Self.removedKey {
                servers = true
            }
        }
        if servers { takeServers() }
    }

    /// A setting saved here: sent, unless it is one this device keeps, or another device's being taken.
    func changedHere(_ key: String) {
        guard isOn, !applying, phase != .looking else { return }
        if key == Settings.serversKey { sendServers() } else { send(key) }
    }

    // MARK: - Settings

    private func send(_ key: String) {
        guard Settings.syncedKeys.contains(key) else { return }
        let value = settings.storedValue(key)
        let cloudKey = Self.settingPrefix + key
        if Self.same(value, cloud.object(forKey: cloudKey)) { return }
        if let value { cloud.set(value, forKey: cloudKey) } else { cloud.removeObject(forKey: cloudKey) }
    }

    private func take(_ key: String) {
        guard Settings.syncedKeys.contains(key) else { return }
        let value = cloud.object(forKey: Self.settingPrefix + key)
        guard value != nil, !Self.same(value, settings.storedValue(key)) else { return }
        settings.applySynced(key, value)
    }

    /// Everything in iCloud, taken: at launch, and when a device joins.
    private func takeEverything() {
        applying = true
        defer { applying = false }
        for key in Settings.syncedKeys { take(key) }
        takeServers()
    }

    nonisolated static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): (a as AnyObject).isEqual(b as AnyObject)
        default: false
        }
    }

    // MARK: - Servers

    private var removedInCloud: Set<UUID> {
        Set((cloud.object(forKey: Self.removedKey) as? [String] ?? []).compactMap(UUID.init(uuidString:)))
    }

    private var known: Set<UUID> {
        get { Set((defaults.stringArray(forKey: Self.knownKey) ?? []).compactMap(UUID.init(uuidString:))) }
        set { defaults.set(newValue.map(\.uuidString).sorted(), forKey: Self.knownKey) }
    }

    /// The servers in iCloud, other than removed ones.
    private var serversInCloud: [HermesServer] {
        let removed = removedInCloud
        return cloud.dictionaryRepresentation.compactMap { key, value -> HermesServer? in
            guard key.hasPrefix(Self.serverPrefix), let data = value as? Data,
                  let server = try? JSONDecoder().decode(HermesServer.self, from: data), !removed.contains(server.id) else { return nil }
            return server
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A server worth sending: one set up, not a new install's blank.
    private static func isSetUp(_ server: HermesServer) -> Bool {
        !server.name.isEmpty || !server.serveURL.isEmpty || !server.gatewayURL.isEmpty
    }

    /// This device's servers up to iCloud: each changed one sent, each one removed here since it
    /// was last seen there taken away, with a tombstone.
    private func sendServers() {
        let removedThere = removedInCloud
        let here = settings.servers.filter { Self.isSetUp($0) && !removedThere.contains($0.id) }
        for server in here {
            let key = Self.serverPrefix + server.id.uuidString
            let there = (cloud.object(forKey: key) as? Data).flatMap { try? JSONDecoder().decode(HermesServer.self, from: $0) }
            if there != server, let data = try? JSONEncoder().encode(server) { cloud.set(data, forKey: key) }
        }
        let ids = Set(settings.servers.map(\.id))
        let removedHere = known.subtracting(ids)
        if !removedHere.isEmpty {
            for id in removedHere { cloud.removeObject(forKey: Self.serverPrefix + id.uuidString) }
            cloud.set(removedThere.union(removedHere).map(\.uuidString).sorted(), forKey: Self.removedKey)
        }
        known = known.subtracting(removedHere).union(here.map(\.id))
    }

    /// iCloud's servers down to this device. When the one this device is on changed its
    /// connection, the app connects again; when this device is on a blank one, it moves to
    /// theirs and the blank goes.
    /// (Called with `applying` set: nothing of this goes back up.)
    private func takeServers() {
        let remote = serversInCloud
        let removed = removedInCloud
        let reconnect = settings.mergeSyncedServers(remote, removed: removed)
        known = Set(remote.map(\.id))
        Keychain.forgetCache()
        if reconnect { HermesServeClient.shared.resetForServerChange() }
        if settings.activeServerIsBlank, let blank = settings.activeServer?.id,
           let theirs = settings.servers.first(where: { $0.id != blank && Self.isSetUp($0) }) {
            switchServer(theirs.id)
            settings.forgetServerRecord(blank)
            if !settings.setupDone { settings.setupDone = true }
        }
    }
}
