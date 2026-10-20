import Foundation
import Testing
@testable import Echo

/// Sync with iCloud between two devices: each its own Settings and CloudSync, sharing a stand-in
/// for iCloud's key-value store. What iCloud tells the other device is said to it by hand.
@MainActor
struct CloudSyncTests {
    /// iCloud's store, as both devices see it once it has synced.
    final class Cloud: CloudValues {
        var values: [String: Any] = [:]
        /// Keys written since `drain()`: what iCloud would tell the other device about.
        private(set) var written: [String] = []
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value; written.append(key) }
        func removeObject(forKey key: String) { values[key] = nil; written.append(key) }
        var dictionaryRepresentation: [String: Any] { values }
        func synchronize() -> Bool { true }
        func drain() -> [String] { defer { written = [] }; return written }
    }

    struct Device {
        let settings: Settings
        let sync: CloudSync
    }

    private func device(_ cloud: Cloud) throws -> Device {
        let defaults = try #require(UserDefaults(suiteName: "cloud-sync-\(UUID().uuidString)"))
        let settings = Settings(defaults: defaults)
        let sync = CloudSync(settings: settings, cloud: cloud, defaults: defaults, signedIn: { true }, lookFor: .milliseconds(20),
                             moveSecrets: { _ in })
        sync.switchServer = { settings.activateServer($0) }
        return Device(settings: settings, sync: sync)
    }

    /// The iPhone, set up: its own server named "Home" and one more, a theme and a spoken prefix.
    private func phone(_ cloud: Cloud) throws -> Device {
        let phone = try device(cloud)
        phone.settings.serveURL = "https://home.example:9119"
        phone.settings.serveUsername = "admin"
        phone.settings.renameServer(phone.settings.activeServerID, to: "Home")
        phone.settings.addServer(name: "Lab")
        phone.settings.theme = .slate
        phone.settings.spokenPrefixes = [SpokenPrefix(word: "Ops", prefix: "", bot: "ops")]
        phone.settings.requireBiometrics = true
        return phone
    }

    @Test func theFirstDeviceOnPutsItsSettingsAndServersInICloud() async throws {
        let cloud = Cloud()
        let phone = try phone(cloud)
        await phone.sync.turnOn()
        #expect(phone.sync.phase == .on && cloud.values[CloudSync.markerKey] != nil)
        #expect(cloud.values["setting.theme"] as? String == "slate")
        #expect(cloud.values["setting.spokenPrefixes"] is Data)
        #expect(cloud.values["setting.requireBiometrics"] == nil, "App Lock stays on each device")
        let servers = cloud.values.keys.filter { $0.hasPrefix(CloudSync.serverPrefix) }
        #expect(servers.count == 2, "both servers, each under a key of its own")
    }

    @Test func aNewDeviceTakesTheOthersAndMovesToTheirServer() async throws {
        let cloud = Cloud()
        let phone = try phone(cloud)
        await phone.sync.turnOn()
        _ = cloud.drain()

        // A new iPad that skipped setup: one blank server.
        let pad = try device(cloud)
        pad.settings.chatTextSize = 1
        await pad.sync.turnOn()
        #expect(pad.settings.theme == .slate && pad.settings.spokenPrefixes.first?.bot == "ops", "the iPhone's settings")
        #expect(pad.settings.servers.map(\.name).sorted() == ["Home", "Lab"], "the iPhone's servers, and the blank one gone")
        #expect(pad.settings.activeServer?.name == "Home" && pad.settings.serveURL == "https://home.example:9119"
                && pad.settings.serveUsername == "admin", "on one of them, its connection in the working copy")
        #expect(!pad.settings.requireBiometrics)
        #expect(pad.settings.setupDone)
    }

    @Test func aChangeOnOneDeviceReachesTheOtherAndGoesNoFurther() async throws {
        let cloud = Cloud()
        let phone = try phone(cloud)
        await phone.sync.turnOn()
        let pad = try device(cloud)
        await pad.sync.turnOn()
        _ = cloud.drain()

        phone.settings.theme = .amber
        phone.settings.stopPhrases = ["basta"]
        let changed = cloud.drain()
        #expect(Set(changed) == ["setting.theme", "setting.stopPhrases"])
        pad.sync.changedElsewhere(reason: NSUbiquitousKeyValueStoreServerChange, keys: changed)
        #expect(pad.settings.theme == .amber && pad.settings.stopPhrases == ["basta"])
        #expect(cloud.drain().isEmpty, "taking them sends nothing back")

        phone.settings.listenOnOpen = true
        #expect(cloud.drain().isEmpty, "what Redde does on opening stays on each device")
    }

    @Test func eachDeviceKeepsItsOwnProfileOnAServerAndFollowsItsConnection() async throws {
        let cloud = Cloud()
        let phone = try phone(cloud)
        await phone.sync.turnOn()
        let pad = try device(cloud)
        await pad.sync.turnOn()
        pad.settings.hermesProfile = "work"
        _ = cloud.drain()

        phone.settings.hermesProfile = "personal"
        phone.settings.serveURL = "https://home.example:9443"
        pad.sync.changedElsewhere(reason: NSUbiquitousKeyValueStoreServerChange, keys: cloud.drain())
        #expect(pad.settings.serveURL == "https://home.example:9443", "the server's new address")
        #expect(pad.settings.hermesProfile == "work", "the iPad stays on its own profile")
    }

    @Test func aServerRemovedOnOneDeviceGoesFromTheOtherUnlessItIsOnIt() async throws {
        let cloud = Cloud()
        let phone = try phone(cloud)
        await phone.sync.turnOn()
        let pad = try device(cloud)
        await pad.sync.turnOn()
        _ = cloud.drain()

        let lab = try #require(phone.settings.servers.first { $0.name == "Lab" }?.id)
        phone.settings.removeServer(lab)
        let news = cloud.drain()
        #expect(cloud.values[CloudSync.serverPrefix + lab.uuidString] == nil)
        #expect((cloud.values[CloudSync.removedKey] as? [String]) == [lab.uuidString], "a tombstone")

        // The iPad was away: it still has Lab, and renames it. It doesn't come back.
        pad.settings.renameServer(lab, to: "Old lab")
        #expect(cloud.values[CloudSync.serverPrefix + lab.uuidString] == nil)
        pad.sync.changedElsewhere(reason: NSUbiquitousKeyValueStoreServerChange, keys: news)
        #expect(!pad.settings.servers.contains { $0.id == lab }, "gone from the iPad once it hears")

        // A device on the server removed keeps it.
        let mac = try device(cloud)
        await mac.sync.turnOn()
        let home = try #require(phone.settings.servers.first { $0.name == "Home" }?.id)
        #expect(mac.settings.activeServerID == home)
        mac.settings.addServer(name: "Spare")
        pad.sync.changedElsewhere(reason: NSUbiquitousKeyValueStoreServerChange, keys: cloud.drain())
        let spare = try #require(pad.settings.servers.first { $0.name == "Spare" }?.id)
        pad.settings.removeServer(spare)
        let tombstone = cloud.drain()
        mac.settings.activateServer(spare)
        mac.sync.changedElsewhere(reason: NSUbiquitousKeyValueStoreServerChange, keys: tombstone)
        #expect(mac.settings.servers.contains { $0.id == spare } && mac.settings.activeServerID == spare)
    }

    @Test func turnedOffNothingMoreGoesUp() async throws {
        let cloud = Cloud()
        let phone = try phone(cloud)
        await phone.sync.turnOn()
        phone.sync.turnOff()
        _ = cloud.drain()
        phone.settings.theme = .paper
        #expect(cloud.drain().isEmpty && phone.sync.phase == .off)
        #expect(cloud.values["setting.theme"] as? String == "slate", "what is in iCloud stays for the other devices")
    }

    @Test func notSignedInToICloudItStaysOff() async throws {
        let defaults = try #require(UserDefaults(suiteName: "cloud-sync-\(UUID().uuidString)"))
        let sync = CloudSync(settings: Settings(defaults: defaults), cloud: Cloud(), defaults: defaults, signedIn: { false },
                             moveSecrets: { _ in Issue.record("no secrets move") })
        await sync.turnOn()
        #expect(sync.phase == .noAccount && !sync.isOn)
    }
}
