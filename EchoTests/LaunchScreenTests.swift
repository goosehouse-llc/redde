import Foundation
import Testing
@testable import Echo

@Suite(.serialized)
struct LaunchScreenTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "launch-test-\(UUID().uuidString)")! }

    @Test func freshInstallsOpenTheLastConversation() {
        #expect(Settings(defaults: defaults()).launchScreen == .conversation)
    }

    /// "Open to the voice screen" was a switch before; someone who had it on still opens to voice.
    @Test func theOldVoiceSwitchCarriesOver() {
        let d = defaults()
        d.set(true, forKey: "openToVoiceScreen")
        let settings = Settings(defaults: d)
        #expect(settings.launchScreen == .voice)
        #expect(settings.openToVoiceScreen)
    }

    @Test func theChoiceIsKept() {
        let d = defaults()
        Settings(defaults: d).launchScreen = .conversations
        #expect(Settings(defaults: d).launchScreen == .conversations)
        #expect(!Settings(defaults: d).openToVoiceScreen)
    }
}
