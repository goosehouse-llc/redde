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

    /// A mic that is opened and closed without the recogniser hearing anything: held behind a
    /// reply that nobody talked over. The transcriber never ends its results then, and waiting
    /// for them left the recogniser finalizing for good, so after one spoken reply the next
    /// listen never started. Needs the speech assets and a microphone: a device, or the Mac.
    @Test func aMicThatHeardNothingClosesAndTheNextListenStarts() async throws {
        let recognizer = SpeechRecognizer()
        do {
            try await recognizer.prepareAssets()
        } catch {
            print("SKIP: speech assets unavailable: \(error)")
            return
        }
        guard await SpeechRecognizer.requestPermissions() else {
            print("SKIP: no permission for the microphone or for speech recognition")
            return
        }
        do {
            try AudioSessionController.shared.activateForVoice()
            try await recognizer.startHeld { _ in }
        } catch {
            print("SKIP: no microphone to open: \(error)")
            return
        }
        defer { AudioSessionController.shared.deactivate() }
        #expect(recognizer.state == .holding)
        recognizer.cancel()

        let next = Listen()
        Task {
            do { try await recognizer.start { _ in } } catch { next.error = error }
            next.returned = true
        }
        let asked = Date()
        while !next.returned, Date().timeIntervalSince(asked) < 10 { try await Task.sleep(for: .milliseconds(50)) }
        print(String(format: "next listen %@ after %.2fs", next.returned ? "opened" : "still waiting", Date().timeIntervalSince(asked)))
        #expect(next.returned, "the next listen never started")
        #expect(next.error == nil)
        #expect(recognizer.state == .listening)

        // And closed again at once, which may also be before any audio has come in.
        recognizer.cancel()
        let closed = Date()
        while recognizer.state != .idle, Date().timeIntervalSince(closed) < 5 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(recognizer.state == .idle)
    }

    private final class Listen {
        var returned = false
        var error: (any Error)?
    }

    private final class Marker {}
}
