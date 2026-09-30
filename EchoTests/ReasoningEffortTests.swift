import Foundation
import Testing
@testable import Echo

/// The effort picker's default and the typed `/reasoning <level>` route on the Hermes Dashboard.
struct ReasoningEffortTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "effort-test-\(UUID().uuidString)")! }

    @Test @MainActor func freshInstallStartsWithReasoningOff() {
        #expect(Settings(defaults: defaults()).reasoningEffort == "none")
        #expect(Settings.reasoningEfforts.contains { $0.value == Settings.defaultReasoningEffort })
    }

    @Test @MainActor func aStoredChoiceWins() {
        let d = defaults()
        Settings(defaults: d).reasoningEffort = ""
        #expect(Settings(defaults: d).reasoningEffort == "")
        Settings(defaults: d).reasoningEffort = "high"
        #expect(Settings(defaults: d).reasoningEffort == "high")
    }

    @Test @MainActor func resetGoesBackToReasoningOff() {
        let s = Settings(defaults: defaults())
        s.reasoningEffort = "max"
        s.reset()
        #expect(s.reasoningEffort == "none")
    }

    /// None never goes on the wire as a word: cloud models reject it, and locally the template
    /// switch turns thinking off. Default sends nothing either.
    @Test func noneAndDefaultStayOffTheWire() {
        #expect(ChatCompletionsTransport.wireEffort("none") == nil)
        #expect(ChatCompletionsTransport.wireEffort("None") == nil)
        #expect(ChatCompletionsTransport.wireEffort("") == nil)
        #expect(ChatCompletionsTransport.wireEffort(nil) == nil)
        #expect(ChatCompletionsTransport.wireEffort("High") == "high")
    }

    @Test func typedLevelsGoToConfigSet() {
        #expect(HermesServeTransport.reasoningLevel(inSlash: "reasoning high") == "high")
        #expect(HermesServeTransport.reasoningLevel(inSlash: "Reasoning XHIGH") == "xhigh")
        #expect(HermesServeTransport.reasoningLevel(inSlash: "reasoning  max  please") == "max")
        #expect(HermesServeTransport.reasoningLevel(inSlash: "reasoning none") == "none")
    }

    @Test func everythingElseStaysOnSlashExec() {
        #expect(HermesServeTransport.reasoningLevel(inSlash: "reasoning") == nil)
        #expect(HermesServeTransport.reasoningLevel(inSlash: "reasoning show") == nil)
        #expect(HermesServeTransport.reasoningLevel(inSlash: "reasoning clamp") == nil)
        #expect(HermesServeTransport.reasoningLevel(inSlash: "reasoning high --global") == nil)
        #expect(HermesServeTransport.reasoningLevel(inSlash: "reasoning hgih") == nil)
        #expect(HermesServeTransport.reasoningLevel(inSlash: "model high") == nil)
        #expect(HermesServeTransport.reasoningLevel(inSlash: "reasoningx high") == nil)
    }
}
