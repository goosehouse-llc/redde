import SwiftUI

/// Spoken prefixes: a word that leads a voice or Siri message becomes a text prefix before the
/// message is sent. Rules are tried in order; the first that matches wins. Typed messages are
/// never changed.
struct SpokenPrefixesView: View {
    @State private var settings = Settings.shared

    var body: some View {
        List {
            Section {
                ForEach($settings.spokenPrefixes) { $rule in
                    NavigationLink {
                        SpokenPrefixEditor(rule: $rule)
                    } label: {
                        LabeledContent(rule.word.isEmpty ? "New prefix" : rule.word) {
                            Text(Self.shown(rule.prefix)).font(.callout.monospaced()).lineLimit(1)
                        }
                    }
                }
                .onDelete { settings.spokenPrefixes.remove(atOffsets: $0) }
                .onMove { settings.spokenPrefixes.move(fromOffsets: $0, toOffset: $1) }
                Button {
                    settings.spokenPrefixes.append(SpokenPrefix(word: "", prefix: ""))
                } label: {
                    Label("Add prefix", systemImage: "plus")
                }
            } header: {
                Text("Prefixes")
            } footer: {
                Text("Applies to voice mode and Siri only: when a message starts with one of these words, the word is replaced with its prefix before sending. Typed messages are never changed. The first matching prefix wins.")
            }
        }
        .navigationTitle("Spoken prefixes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    /// Trailing spaces are part of a prefix; show them so they're not invisible.
    static func shown(_ prefix: String) -> String {
        prefix.isEmpty ? "—" : prefix.replacingOccurrences(of: " ", with: "␣")
    }
}

/// One rule: the word, its aliases, the prefix, and what an example sentence becomes.
struct SpokenPrefixEditor: View {
    @Binding var rule: SpokenPrefix
    @State private var aliases: String

    init(rule: Binding<SpokenPrefix>) {
        _rule = rule
        _aliases = State(initialValue: rule.wrappedValue.aliases.joined(separator: ", "))
    }

    private var example: String {
        let word = rule.word.trimmingCharacters(in: .whitespaces)
        return (word.isEmpty ? "Claude" : word) + ", what's using port 8880?"
    }

    var body: some View {
        Form {
            Section {
                TextField("Word", text: $rule.word)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                TextField("Aliases, comma-separated", text: $aliases)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .onChange(of: aliases) { _, text in
                        rule.aliases = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
            } header: {
                Text("Spoken word")
            } footer: {
                Text("Aliases catch the ways speech recognition tends to hear the word.")
            }
            Section {
                // Spaces are kept as typed: a trailing space is usually the point.
                TextField("Prefix", text: $rule.prefix)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            } header: {
                Text("Text prefix")
            } footer: {
                Text("What replaces the word. Spaces count, including a space at the end.")
            }
            Section("Preview") {
                Text("\u{201C}\(example)\u{201D}").foregroundStyle(.secondary)
                Text(VoiceRouting.routed(example, rules: [rule]) ?? "Unchanged: add a word and a prefix.")
                    .font(.body.monospaced())
            }
        }
        .navigationTitle(rule.word.isEmpty ? "New prefix" : rule.word)
        .navigationBarTitleDisplayMode(.inline)
    }
}
