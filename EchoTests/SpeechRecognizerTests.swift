import AVFoundation
import Foundation
import Testing
@testable import Echo

/// The test machine has no microphone, so on-device STT is verified by pushing a synthesized WAV through
/// the same converter + SpeechAnalyzer pipeline the mic tap uses. One at a time: the system
/// allows only so many analyses at once, and there is one microphone.
@Suite(.serialized) struct SpeechRecognizerTests {
    /// Both transcribers, each where it exists. The simulator has only the dictation one, as an
    /// iPhone 11 does, so a run there is that phone's path; a device or the Mac has both.
    @Test(arguments: [Transcriber.Kind.speech, .dictation])
    func transcribesFixtureOnDevice(with kind: Transcriber.Kind) async throws {
        guard let url = Bundle(for: Marker.self).url(forResource: "capital-of-france", withExtension: "wav") else {
            Issue.record("fixture missing from test bundle")
            return
        }
        do {
            try await SpeechRecognizer.prepareAssets(with: kind)
        } catch {
            print("SKIP: \(kind) assets unavailable: \(error)")
            return
        }
        let started = Date()
        let text = try await SpeechRecognizer.transcribe(fileURL: url, with: kind)
        print(String(format: "STT fixture (\(kind)) → %@ (%.2fs)", text, Date().timeIntervalSince(started)))
        #expect(text.lowercased().contains("capital"))
        #expect(text.lowercased().contains("france"))
    }

    /// An iPhone 11 was told to pick another language, in a list that never loaded: its
    /// `SpeechTranscriber` knows none. Such a device listens with the dictation transcriber, and
    /// where a transcriber knows no language the device is named as the trouble.
    @Test func aTranscriberThatKnowsNoLanguageIsNotALanguageProblem() async {
        guard await Transcriber.Kind.speech.supportedLocales.isEmpty else {
            print("SKIP: this machine has the speech transcriber")
            return
        }
        #expect(Transcriber.Kind.onThisDevice == .dictation)
        await #expect(throws: SpeechRecognizer.Failure.unavailable) {
            _ = try await SpeechRecognizer.makeTranscriber(for: Locale(identifier: "en-US"), with: .speech)
        }
    }

    /// What the listening loop needs of either transcriber: tentative text while the words come
    /// (endpointing waits for it to settle), then the final text.
    @Test(arguments: [Transcriber.Kind.speech, .dictation])
    func tentativeTextComesBeforeTheFinal(with kind: Transcriber.Kind) async throws {
        guard let url = Bundle(for: Marker.self).url(forResource: "capital-of-france", withExtension: "wav") else {
            Issue.record("fixture missing from test bundle")
            return
        }
        do {
            try await SpeechRecognizer.prepareAssets(with: kind)
        } catch {
            print("SKIP: \(kind) assets unavailable: \(error)")
            return
        }
        let heard = try await SpeechRecognizer.results(fileURL: url, with: kind)
        print("STT results (\(kind)): \(heard.map { ($0.isFinal ? "final" : "tentative") + " “\($0.text)”" })")
        #expect(heard.contains { !$0.isFinal && !$0.text.isEmpty })
        #expect(heard.last?.isFinal == true)
    }

    /// A mic that is opened and closed without the recogniser hearing anything: held behind a
    /// reply that nobody talked over. The transcriber never ends its results then, and waiting
    /// for them left the recogniser finalizing for good, so after one spoken reply the next
    /// listen never started. Needs the speech assets and a microphone: a device, or the Mac.
    @Test(arguments: [Transcriber.Kind.speech, .dictation])
    func aMicThatHeardNothingClosesAndTheNextListenStarts(with kind: Transcriber.Kind) async throws {
        let recognizer = SpeechRecognizer(listeningWith: kind)
        do {
            try await recognizer.prepareAssets()
        } catch {
            print("SKIP: \(kind) assets unavailable: \(error)")
            return
        }
        // Not asked for here: the question is a system alert, and a run would wait at it for good.
        guard AVAudioApplication.shared.recordPermission == .granted else {
            print("SKIP: the microphone hasn't been allowed")
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
        print(String(format: "next listen (\(kind)) %@ after %.2fs", next.returned ? "opened" : "still waiting", Date().timeIntervalSince(asked)))
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
