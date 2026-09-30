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
                            Text(Self.summary(rule)).font(.callout.monospaced()).lineLimit(1)
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
                Text("Applies to voice mode and Siri only: when a message starts with one of these words, the word is replaced with its prefix before sending, and the conversation switches to the rule's model if it names one. Typed messages are never changed. The first matching prefix wins.")
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

    /// The row's right side: the prefix, the model, or both.
    static func summary(_ rule: SpokenPrefix) -> String {
        let model = (rule.model ?? "").isEmpty ? nil : rule.model
        switch (rule.prefix.isEmpty, model) {
        case (true, nil): return "—"
        case (true, let model?): return "→ \(model)"
        case (false, nil): return shown(rule.prefix)
        case (false, let model?): return "\(shown(rule.prefix)) → \(model)"
        }
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
                Text("What replaces the word. Spaces count, including a space at the end. Leave it empty to only switch the model.")
            }
            Section {
                NavigationLink {
                    SpokenPrefixModelPicker(rule: $rule)
                } label: {
                    LabeledContent("Model") {
                        Text((rule.model ?? "").isEmpty ? "Keep current" : rule.model ?? "")
                            .font(.callout.monospaced()).lineLimit(1)
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Switches the conversation to this model before sending, and it stays there until you pick another. Models come from the connection you're on now.")
            }
            Section("Preview") {
                Text("\u{201C}\(example)\u{201D}").foregroundStyle(.secondary)
                if let route = VoiceRouting.route(example, rules: [rule]) {
                    Text(route.text).font(.body.monospaced())
                    if let model = route.model { Text("Model → \(model)").font(.callout).foregroundStyle(.secondary) }
                } else {
                    Text("Unchanged: add a word, then a prefix or a model.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(rule.word.isEmpty ? "New prefix" : rule.word)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Picks the model a rule switches to, from the active backend's list, the way the model
/// picker shows them. "Keep current" leaves the model alone.
struct SpokenPrefixModelPicker: View {
    @Binding var rule: SpokenPrefix
    @Environment(Conversation.self) private var conversation
    @State private var settings = Settings.shared
    @State private var choices: [ModelChoice] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        List {
            Section {
                row(title: "Keep current", model: nil, selected: (rule.model ?? "").isEmpty) {
                    rule.model = nil; rule.provider = nil
                }
            }
            if let error {
                Section { Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary).font(.footnote) }
            } else if loading {
                Section { ProgressView("Loading models…") }
            }
            ForEach(ModelPickerView.grouped(choices), id: \.provider) { group in
                Section(group.name) {
                    ForEach(group.models) { choice in
                        row(title: choice.name, model: choice.model,
                            selected: rule.model == choice.model && (rule.provider ?? "").isEmpty || rule.provider == choice.provider && rule.model == choice.model) {
                            rule.model = choice.model
                            rule.provider = settings.transport == .chatCompletions ? nil : choice.provider
                        }
                    }
                }
            }
        }
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(title: String, model: String?, selected: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let model, model != title { Text(model).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            choices = try await ModelPickerView.loadChoices(conversation: conversation, settings: settings)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
