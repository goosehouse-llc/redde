import SwiftUI

/// Settings → Voice with "Hermes" chosen: whether there is a Dashboard to speak through, and a
/// test sentence that says which provider Hermes spoke it with, so it's plain where replies go.
struct HermesVoiceRows: View {
    private enum Trial: Equatable { case idle, speaking, spoke(provider: String), failed(String) }
    private static let sentence = "This is your Hermes, reading replies out with its own voice."

    @State private var trial: Trial = .idle
    @State private var player = KokoroPlayer()
    @State private var holdsSession = false

    var body: some View {
        if HermesSpeech.isAvailable {
            Button { trial == .speaking ? release() : test() } label: {
                LabeledContent(trial == .speaking ? String(localized: "Stop") : String(localized: "Say a test sentence")) {
                    switch trial {
                    case .idle: EmptyView()
                    case .speaking: ProgressView()
                    case let .spoke(provider): Text("Spoken by \(HermesSpeech.providerName(provider))").lineLimit(2)
                    case let .failed(why): Text(why).foregroundStyle(.red).lineLimit(3)
                    }
                }
            }
            .onDisappear { release() }
        } else {
            Text("Needs the Hermes Dashboard connection: its address and login, under Connection. Until then the on-device voice reads replies.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func test() {
        trial = .speaking
        Task {
            do {
                // Whole, not streamed: that answer names the provider.
                let said = try await HermesSpeech.whole(Self.sentence, client: .shared, format: KokoroPlayer.makeFormat())
                guard trial == .speaking else { return }   // stopped meanwhile
                // The shared helper, so the route bookkeeping the voice loop relies on stays right.
                try? AudioSessionController.shared.activateForPlayback()
                holdsSession = true
                player.onDrained = { release(keeping: true) }
                player.begin()
                player.enqueue(samples: said.samples, text: Self.sentence)
                player.finish()
                trial = .spoke(provider: said.provider ?? "")
            } catch {
                guard trial == .speaking else { return }
                trial = .failed(error.localizedDescription)
            }
        }
    }

    /// Stops the sentence and gives the audio session back; `keeping` leaves what was found shown.
    private func release(keeping: Bool = false) {
        player.release()   // stop() alone leaves the engine running and the session busy
        if holdsSession { AudioSessionController.shared.deactivate(); holdsSession = false }
        if !keeping, trial == .speaking { trial = .idle }
    }
}
