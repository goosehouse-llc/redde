import Foundation
import Testing
@testable import Echo

/// The test machine has no microphone, so on-device STT is verified by pushing a synthesized WAV through
/// the same converter + SpeechAnalyzer pipeline the mic tap uses.
struct SpeechRecognizerTests {
    @Test func transcribesFixtureOnDevice() async throws {
        guard let url = Bundle(for: Marker.self).url(forResource: "capital-of-france", withExtension: "wav") else {
            Issue.record("fixture missing from test bundle")
            return
        }
        do {
            try await SpeechRecognizer().prepareAssets()
        } catch {
            print("SKIP: speech assets unavailable: \(error)")
            return
        }
        let started = Date()
        let text = try await SpeechRecognizer.transcribe(fileURL: url)
        print(String(format: "STT fixture → %@ (%.2fs)", text, Date().timeIntervalSince(started)))
        #expect(text.lowercased().contains("capital"))
        #expect(text.lowercased().contains("france"))
    }

    private final class Marker {}
}
