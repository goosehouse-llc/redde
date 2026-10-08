import SwiftUI

/// Settings → Voice → Stop phrases: the person's own ways of ending a hands-free conversation,
/// beside the built-in English ones. Whole phrases, as they'd be said; `StopPhrase` does the
/// hearing.
struct StopPhrasesView: View {
    @State private var settings = Settings.shared
    @State private var draft = ""
    @FocusState private var typing: Bool

    /// What a phrase is compared as, or nil when it can't be added: empty, there already, one
    /// of the built-in ones, or the list is full.
    static func addable(_ phrase: String, to own: [String]) -> String? {
        let cleaned = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = StopPhrase.normalize(cleaned)
        guard !heard.isEmpty, cleaned.count <= StopPhrase.longestOwn, own.count < StopPhrase.mostOwn,
              !StopPhrase.phrases.contains(heard), !StopPhrase.own(own).contains(heard) else { return nil }
        return cleaned
    }

    private var canAdd: Bool { Self.addable(draft, to: settings.stopPhrases) != nil }

    var body: some View {
        List {
            Section {
                ForEach(settings.stopPhrases, id: \.self) { phrase in
                    Text(phrase)
                }
                .onDelete { settings.stopPhrases.remove(atOffsets: $0) }
                HStack {
                    TextField("Add a phrase", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($typing)
                        .submitLabel(.done)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(!canAdd)
                        .accessibilityLabel("Add phrase")
                }
            } header: {
                Text("Your phrases")
            } footer: {
                Text("Say one of these on its own in hands-free mode and Redde stops listening, without sending it to the agent. Add the words you'd use, or the ones for the language you speak to Redde in: write them the way they are said. A phrase inside a longer sentence doesn't count."
                     + (settings.talkOver != .off && settings.interruption == .stopWord
                        ? " With “Interrupt with” set to Only “stop”, these stop a reply too." : ""))
            }
            Section {
                Text(Self.builtIn)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Always heard")
            } footer: {
                Text("With or without “okay”, “Redde”, “please” or “thanks” around them.")
            }
        }
        .navigationTitle("Stop phrases")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if !settings.stopPhrases.isEmpty { EditButton() } }
    }

    /// A few of the built-in ones, enough to show the kind.
    static let builtIn = "“stop”, “stop listening”, “that's all”, “that's enough”, “goodbye”, “good night”, “end conversation”, “we're done”, “never mind”, “cancel”, “thank you”"

    private func add() {
        guard let phrase = Self.addable(draft, to: settings.stopPhrases) else { return }
        settings.stopPhrases.append(phrase)
        draft = ""
        typing = true   // the next one can be typed straight away
    }
}
