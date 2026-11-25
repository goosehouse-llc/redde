import Foundation
import Testing
@testable import Echo

/// Settings search (2026-11-25): every setting it lists is on a screen to scroll to, and a search
/// finds it by its name, the words it might be looked for by, and what is behind it.
@MainActor
struct SettingsSearchTests {
    private func settings() throws -> Settings {
        Settings(defaults: try #require(UserDefaults(suiteName: "settings-search-\(UUID().uuidString)")))
    }

    /// A row the index names but no screen marks would open its page and scroll nowhere.
    @Test func everySettingItFindsIsOnAScreen() throws {
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Echo/Views")
        var marked: [String: Int] = [:]
        for case let file as URL in FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil)!
        where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in source.matches(of: /\.settingRow\(\.(\w+)\)/) { marked[String(match.1), default: 0] += 1 }
        }
        let missing = SettingsRow.allCases.map(\.rawValue).filter { marked[$0] == nil }
        #expect(missing.isEmpty, "not on any screen: \(missing)")
        // Up Next and Reminders on Their Day are on Chat List and on Calendars, from one view each.
        let twice = marked.filter { $0.value > 1 }.map(\.key)
        #expect(twice.isEmpty, "marked in two places: \(twice)")
    }

    @Test func aSettingIsFoundByItsNameFirst() throws {
        let hits = SettingsSearch.hits(for: "wake", settings: try settings())
        #expect(hits.first?.row == .wakePhrase)
        #expect(hits.first?.page == .voice && hits.first?.place == SettingsPage.voice.title)
    }

    @Test func otherWordsFindItToo() throws {
        let settings = try settings()
        #expect(SettingsSearch.hits(for: "dark mode", settings: settings).contains { $0.row == .theme })
        #expect(SettingsSearch.hits(for: "passcode", settings: settings).contains { $0.row == .appLock })
        #expect(SettingsSearch.hits(for: "TTS", settings: settings).contains { $0.row == .readingVoice })
        #expect(SettingsSearch.hits(for: "wake word", settings: settings).contains { $0.row == .wakePhrase })
    }

    @Test func caseAndAccentsAside() throws {
        let settings = try settings()
        #expect(SettingsSearch.hits(for: "QUIET hours", settings: settings).first?.row == .quietHours)
        #expect(SettingsSearch.hits(for: "Quíet", settings: settings).first?.row == .quietHours)
    }

    @Test func whatIsBehindARowIsFoundAndSaysWhere() throws {
        let hits = SettingsSearch.hits(for: "keep calls on", settings: try settings())
        let hit = try #require(hits.first)
        #expect(hit.row == .voiceMode && hit.title == String(localized: "Keep Calls On When Locked"))
        #expect(hit.place == "\(SettingsPage.voice.title) › \(String(localized: "Voice mode"))")
    }

    @Test func pagesAreFoundAndOpenWithNoRow() throws {
        let hit = try #require(SettingsSearch.hits(for: "notifications", settings: try settings()).first)
        #expect(hit.page == .notifications && hit.row == nil)
    }

    @Test func aRowOfTheFirstScreenHasNoPage() throws {
        let hit = try #require(SettingsSearch.hits(for: "acknowledgements", settings: try settings()).first)
        #expect(hit.row == .acknowledgements && hit.page == nil)
    }

    @Test func whatThisConnectionHasNotIsLeftOut() throws {
        let settings = try settings()
        settings.transport = .chatCompletions
        #expect(!SettingsSearch.hits(for: "server", settings: settings).contains { $0.row == .server })
        #expect(!SettingsSearch.hits(for: "profile", settings: settings).contains { $0.row == .profile })
        settings.transport = .hermesServe
        #expect(SettingsSearch.hits(for: "server", settings: settings).contains { $0.row == .server })
        #expect(SettingsSearch.hits(for: "models & providers", settings: settings).first?.row == .modelsProviders)
    }

    @Test func aSwitchThatShowsOnlyWithAnotherOnIsFoundOnlyThen() throws {
        let settings = try settings()
        settings.requireBiometrics = false
        #expect(!SettingsSearch.hits(for: "lock after", settings: settings).contains { $0.row == .lockAfter })
        settings.requireBiometrics = true
        #expect(SettingsSearch.hits(for: "lock after", settings: settings).first?.row == .lockAfter)
    }

    @Test func nothingForNothing() throws {
        let settings = try settings()
        #expect(SettingsSearch.hits(for: "   ", settings: settings).isEmpty)
        #expect(SettingsSearch.hits(for: "zzqx", settings: settings).isEmpty)
    }
}
