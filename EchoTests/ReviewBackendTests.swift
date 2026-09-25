import Foundation
import Testing
@testable import Echo

/// Proves the App Review path end to end against the hosted provider in the review notes.
/// Skips unless the review key is supplied: store it in the Mac keychain
/// (`security add-generic-password -s hermetic-review -a openrouter -w`) and run
/// `TEST_RUNNER_ECHO_REVIEW_KEY=$(security find-generic-password -s hermetic-review -w) xcodebuild test …`.
struct ReviewBackendTests {
    /// The documented OpenRouter base, exactly as a reviewer would paste it.
    private static let base = Settings.normalizedBase("https://openrouter.ai/api/v1")!
    private static let model = "google/gemma-3-27b-it"

    // xcodebuild strips the TEST_RUNNER_ prefix and passes ECHO_REVIEW_KEY to the test host.
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["ECHO_REVIEW_KEY"] ?? "").isEmpty, "ECHO_REVIEW_KEY not set"))
    func hostedFastLaneAnswersAndReportsUsage() async throws {
        let key = ProcessInfo.processInfo.environment["ECHO_REVIEW_KEY"]!
        let probe = await ConnectionTester.fastLane(url: Self.base, apiKey: key, model: Self.model)
        #expect(probe.isOK, Comment(rawValue: probe.message))

        let transport = ChatCompletionsTransport(baseURL: Self.base, apiKey: key)
        let request = TurnRequest(userText: "Reply with exactly the word: pong", history: [], sessionID: nil,
                                  model: Self.model, instructions: nil)
        var text = ""; var usage: TokenUsage?; var done = false
        for try await event in transport.stream(request) {
            switch event {
            case let .textDelta(d): text += d
            case let .usage(u): usage = u
            case .done: done = true
            default: break
            }
        }
        print("review backend reply: \(text) usage: \(String(describing: usage))")
        #expect(done && text.lowercased().contains("pong"))
        #expect((usage?.output ?? 0) > 0, "hosted provider should report usage")
        let window = await ContextWindowProbe.window(fastLaneBase: Self.base, model: Self.model, apiKey: key)
        #expect(window == 131_072)
    }
}
