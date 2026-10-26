import AVFoundation
import SwiftUI

/// Settings → Voice → Wake Phrase: listening for wake phrases on this device (`WakeListener`),
/// and each agent's phrase, on or off, its words "Hey <name>" unless others are typed.
struct WakePhraseSettings: View {
    @State private var settings = Settings.shared
    /// The microphone was refused: the switch went back off, and says why.
    @State private var micRefused = AVAudioApplication.shared.recordPermission == .denied
    @Environment(\.openURL) private var openURL

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    var body: some View {
        Form {
            Section {
                Toggle("Listen for wake phrases", isOn: Binding(
                    get: { settings.wakeListening },
                    set: { on in
                        settings.wakeListening = on
                        guard on else { return }
                        // iOS asks for the microphone here, not when Redde next opens.
                        Task {
                            guard await !AVAudioApplication.requestRecordPermission() else { micRefused = false; return }
                            settings.wakeListening = false
                            micRefused = true
                        }
                    }))
                if micRefused {
                    Button("Allow the microphone for Redde…") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            } footer: {
                Text(footer)
            }
            Section {
                ForEach(settings.wakeAgents, id: \.key) { agent in
                    WakePhraseRow(key: agent.key, name: agent.name)
                }
            } header: {
                Text("Phrases")
            } footer: {
                Text("A phrase left blank is “Hey” and the name. Two words or more wake it by mistake less often than one. The phrases are kept for each server, and sync with iCloud where that's on; listening is this \(device)'s own.")
            }
            .disabled(!settings.wakeListening)
        }
        .navigationTitle("Wake Phrase")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var footer: String {
        let car = device == "iPhone" ? ", or on your car's screen" : ""
        return "While Redde is open on this \(device)\(car), say an agent's phrase to talk to it: “Hey \(settings.headerTitle)” opens voice mode, and “Hey \(settings.headerTitle), what's on today?” asks at once. "
            + "Heard on this \(device) and nowhere else. While it listens the microphone stays on (the orange dot shows it), and music and other sound play on. "
            + "It waits while voice mode, a call or dictation has the microphone, and while Settings is open."
    }
}

/// One agent: its phrase on or off, and its words.
private struct WakePhraseRow: View {
    let key: String
    let name: String
    @State private var settings = Settings.shared

    private var phrase: WakePhrase { settings.wakePhrase(for: key) }

    var body: some View {
        Toggle(name, isOn: Binding(get: { phrase.on }, set: { on in store { $0.on = on } }))
        if phrase.on {
            TextField(Settings.defaultWakePhrase(for: name), text: Binding(
                get: { phrase.phrase ?? "" },
                set: { words in store { $0.phrase = words.isEmpty ? nil : words } }))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .accessibilityLabel("\(name)'s wake phrase")
        }
    }

    /// Kept only where it differs from nothing set.
    private func store(_ change: (inout WakePhrase) -> Void) {
        var changed = phrase
        change(&changed)
        settings.wakePhrasesHere[key] = changed == WakePhrase(on: key == "default") ? nil : changed
    }
}

extension View {
    /// Wake phrases held off while this is on screen (`WakeListener.Hold`).
    func holdsWakePhrases(_ reason: WakeListener.Hold) -> some View {
        onAppear { WakeListener.shared.hold(reason) }
            .onDisappear { WakeListener.shared.release(reason) }
    }
}
