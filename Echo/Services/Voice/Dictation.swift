import Foundation
import Observation
import os

/// The composer's microphone: what is said becomes text in the draft, and nothing is sent. One
/// stretch of speech per tap: it ends when the speaker has been quiet for a moment, or at a
/// second tap. On the device, by the same recogniser as voice mode and in the same language.
@Observable
final class Dictation {
    enum Phase: Equatable { case idle, starting, listening }

    private(set) var phase: Phase = .idle
    /// What has been heard in this stretch so far; the whole of it once it has ended.
    private(set) var heard = ""
    /// Why it couldn't listen, said once.
    var problem: String?

    /// Made when first needed: a composer exists long before anyone taps its microphone.
    @ObservationIgnored private lazy var recognizer: any VoiceRecognizing = makeRecognizer()
    @ObservationIgnored private let makeRecognizer: () -> any VoiceRecognizing
    @ObservationIgnored private let audio: any VoiceAudioControlling
    @ObservationIgnored private let requestPermissions: () async -> Bool
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private let log = Logger(subsystem: "com.goosehouse.echo", category: "dictation")

    /// A recogniser of its own, patient with the pauses of someone composing a message.
    static func patientRecognizer() -> SpeechRecognizer {
        let recognizer = SpeechRecognizer()
        recognizer.silenceTimeout = 2.2
        recognizer.maxUtterance = 120
        return recognizer
    }

    init(recognizer: @escaping () -> any VoiceRecognizing = { Dictation.patientRecognizer() },
         audio: any VoiceAudioControlling = AudioSessionController.shared,
         requestPermissions: @escaping () async -> Bool = { await SpeechRecognizer.requestPermissions() }) {
        makeRecognizer = recognizer
        self.audio = audio
        self.requestPermissions = requestPermissions
    }

    var isActive: Bool { phase != .idle }

    func toggle() {
        if phase == .idle { start() } else { stop() }
    }

    func start() {
        guard phase == .idle else { return }
        attempt += 1
        let attempt = attempt
        phase = .starting
        heard = ""
        problem = nil
        Task { [weak self] in await self?.open(attempt) }
    }

    private func open(_ attempt: Int) async {
        do {
            guard await requestPermissions() else { throw SpeechRecognizer.Failure.permissionDenied }
            guard attempt == self.attempt, phase == .starting else { return }
            try audio.activateForVoice()
            try await recognizer.start { [weak self] text in
                Task { self?.ended(text, attempt: attempt) }
            }
            guard attempt == self.attempt, phase == .starting else { return }
            phase = .listening
            follow(attempt)
        } catch {
            guard attempt == self.attempt, phase != .idle else { return }
            if !(error is CancellationError) {
                log.error("dictation failed: \(error.localizedDescription)")
                problem = error.localizedDescription
            }
            phase = .idle
            audio.deactivate()
        }
    }

    /// A second tap: what was said so far is the text.
    func stop() {
        guard phase != .idle else { return }
        let attempt = attempt
        if phase == .starting {
            // The microphone hasn't opened yet: nothing to keep.
            recognizer.cancel()
            ended("", attempt: attempt)
            return
        }
        Task { [weak self] in
            guard let text = await self?.recognizer.stop() else { return }
            self?.ended(text, attempt: attempt)
        }
    }

    /// The composer went away, or voice mode wants the microphone.
    func cancel() {
        guard phase != .idle else { return }
        recognizer.cancel()
        ended(heard, attempt: attempt)
    }

    private func ended(_ text: String, attempt: Int) {
        guard attempt == self.attempt, phase != .idle else { return }
        self.attempt += 1
        if !text.isEmpty { heard = text }
        phase = .idle
        audio.deactivate()
    }

    private func follow(_ attempt: Int) {
        withObservationTracking {
            let text = recognizer.transcript
            if !text.isEmpty { heard = text }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, attempt == self.attempt, self.phase == .listening else { return }
                self.follow(attempt)
            }
        }
    }

    /// A draft with what was dictated added to it, after a space when the draft doesn't end in
    /// one (or in a line break).
    nonisolated static func joined(_ draft: String, _ heard: String) -> String {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else { return draft }
        guard let last = draft.last else { return heard }
        return last.isWhitespace ? draft + heard : draft + " " + heard
    }
}
