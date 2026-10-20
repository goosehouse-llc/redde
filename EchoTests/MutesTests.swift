import Foundation
import Testing
import UserNotifications
@testable import Echo

/// Muting a bot's chat or a group chat (`Mutes`, `MutedChats`): for how long, what it covers, and
/// what a muted chat's notification does.
@MainActor
struct MutesTests {
    private let noon = Date(timeIntervalSince1970: 1_791_288_000)   // 2026-10-06 12:00 UTC

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func eachSpanEndsWhenItSays() {
        #expect(MuteSpan.hour.until(from: noon) == noon.addingTimeInterval(3600))
        #expect(MuteSpan.eightHours.until(from: noon) == noon.addingTimeInterval(8 * 3600))
        let tomorrow = MuteSpan.untilTomorrow.until(from: noon, calendar: utc)
        #expect(utc.component(.day, from: tomorrow) == 7 && utc.component(.hour, from: tomorrow) == 8, "eight the next morning")
        // Just before midnight, tomorrow is still the next day's morning.
        let late = MuteSpan.untilTomorrow.until(from: noon.addingTimeInterval(11 * 3600 + 59 * 60), calendar: utc)
        #expect(utc.component(.day, from: late) == 7)
        #expect(MuteSpan.untilUnmuted.until(from: noon) == .distantFuture)
    }

    @Test func aMuteIsKeptPerServerAndRunsOut() {
        let settings = Settings(defaults: UserDefaults(suiteName: "mutes-\(UUID().uuidString)")!)
        Mutes.mute("bot:scout", for: .hour, settings: settings, now: noon)
        #expect(Mutes.isMuted("bot:scout", settings: settings, now: noon.addingTimeInterval(60)))
        #expect(!Mutes.isMuted("bot:scout", settings: settings, now: noon.addingTimeInterval(3601)), "ran out")
        #expect(!Mutes.isMuted("room:redde-1", settings: settings, now: noon))
        Mutes.mute("room:redde-1", for: .untilUnmuted, settings: settings, now: noon.addingTimeInterval(7200))
        #expect(settings.mutesHere.keys.sorted() == ["room:redde-1"], "one run out goes when another is set")
        Mutes.unmute("room:redde-1", settings: settings)
        #expect(settings.mutesHere.isEmpty)
    }

    @Test func aMutedBotCoversEveryChatItHasAndARoomItsRoom() {
        let keys = Mutes.keys(muted: ["bot:scout": .distantFuture, "room:redde-1": noon.addingTimeInterval(60),
                                      "bot:writer": noon.addingTimeInterval(-60)],
                              now: noon, botChats: ["scout": "bot-chat-1", "writer": "bot-chat-2"],
                              kept: [("scout", "api-chat-9"), ("default", "chat-3")])
        #expect(keys == ["s:bot-chat-1": .distantFuture, "s:api-chat-9": .distantFuture, "g:redde-1": noon.addingTimeInterval(60)])
    }

    @Test func theExtensionKnowsWhatIsMutedAndDeliversItQuietly() {
        let defaults = UserDefaults(suiteName: "muted-\(UUID().uuidString)")!
        MutedChats.save(["s:bot-chat-1": .distantFuture, "g:redde-1": noon.addingTimeInterval(60)], defaults)
        #expect(MutedChats.isMuted(session: "bot-chat-1", room: nil, now: noon, in: defaults))
        #expect(MutedChats.isMuted(session: nil, room: "redde-1", now: noon, in: defaults))
        #expect(!MutedChats.isMuted(session: nil, room: "redde-1", now: noon.addingTimeInterval(61), in: defaults))
        #expect(!MutedChats.isMuted(session: "another", room: nil, now: noon, in: defaults))
        let content = UNMutableNotificationContent()
        content.sound = .default
        MutedChats.quiet(content)
        #expect(content.sound == nil && content.interruptionLevel == .passive)
    }

    @Test func thePluginIsToldWhatIsMutedWhenItChanges() {
        let pairing = PushPairing(id: "dev-1", sendKey: "s", key: Data(repeating: 1, count: 32), relay: "https://relay.example", confirmed: true)
        let service = PushService(defaults: UserDefaults(suiteName: "mutes-\(UUID().uuidString)")!, session: RelayStub.session,
                                  vault: ({ [pairing] }, { _ in true }), askForToken: {}, allowed: { true })
        let keys: [String: Date] = ["s:bot-chat-1": .distantFuture, "g:redde-1": Date(timeIntervalSince1970: 1_791_330_000)]
        #expect(service.muteCommand(keys, server: "A") == "mutes dev-1 g:redde-1=1791330000,s:bot-chat-1=0")
        #expect(service.muteCommand(keys, server: "A") == nil, "said already")
        #expect(service.muteCommand([:], server: "A") == "mutes dev-1", "none muted now")
    }

    @Test func aMutedChatsNoteIsInTheListNotOverTheScreen() {
        let h = NotifierTests.Harness(appActive: true)
        let saved = MutedChats.load()
        defer { MutedChats.save(saved) }
        MutedChats.save(["g:redde-1": .distantFuture])
        #expect(h.notifier.presentation(pushKind: "group", sessionID: nil, room: "redde-1") == [.list])
        #expect(h.notifier.presentation(pushKind: "group", sessionID: nil, room: "redde-2").contains(.banner))
    }

    @Test func untilWhenReadsPlainly() {
        #expect(Mutes.describe(until: .distantFuture, now: noon) == "Muted")
        #expect(Mutes.describe(until: noon.addingTimeInterval(3600), now: noon).hasPrefix("Muted until "))
        #expect(Mutes.describe(until: noon.addingTimeInterval(86400), now: noon).hasPrefix("Muted until tomorrow"))
    }
}
