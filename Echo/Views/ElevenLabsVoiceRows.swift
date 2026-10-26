import SwiftUI

/// Settings → Voice with ElevenLabs reading replies (`ElevenLabsSpeech`): the key, the same one
/// live calls with ElevenLabs use, and the voice Redde reads in. Bots get voices of their own from
/// the same account (Edit Bot → Voice).
struct ElevenLabsVoiceRows: View {
    @State private var settings = Settings.shared
    @State private var hasKey = ElevenLabsSpeech.key != nil

    var body: some View {
        SecretField(item: LiveEngine.elevenLabs.keyItem, prompt: "ElevenLabs API key", replacePrompt: "Replace stored ElevenLabs key",
                    saveTitle: "Save key", removeTitle: "Remove key", optional: true, hasValue: $hasKey)
        NavigationLink {
            LiveVoiceList(engine: .elevenLabs, selection: Binding(
                get: { settings.elevenLabsVoice.nilIfEmpty },
                set: { settings.elevenLabsVoice = $0 ?? "" }),
                          name: settings.headerTitle, reading: true)
        } label: {
            LabeledContent("Voice", value: settings.elevenLabsVoice.nilIfEmpty.flatMap(ElevenLabsVoice.name) ?? "Your account's first")
        }
        .disabled(!hasKey)
    }
}
