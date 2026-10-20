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
                // A rule for a bot in one go: its name as the word ("Home, turn off the lights").
                let unruled = Self.botsWithoutRules(settings)
                if !unruled.isEmpty {
                    Menu {
                        ForEach(unruled, id: \.name) { bot in
                            Button(bot.label(mainName: settings.headerTitle)) {
                                settings.spokenPrefixes.append(SpokenPrefix(word: bot.label(mainName: settings.headerTitle), prefix: "", bot: bot.name))
                            }
                        }
                    } label: {
                        Label("Add a bot", systemImage: "person.2")
                    }
                }
            } header: {
                Text("Prefixes")
            } footer: {
                Text("Applies to voice mode and Siri only: when a message starts with one of these words, the word is replaced with its prefix before sending, the conversation goes to the rule's bot if it names one (and stays with it), and switches to the rule's model if it names one. Typed messages are never changed. The first matching prefix wins.")
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

    /// The row's right side: the bot, the prefix, the model, as the rule has them.
    static func summary(_ rule: SpokenPrefix) -> String {
        let model = (rule.model ?? "").isEmpty ? nil : rule.model
        let bot = (rule.bot ?? "").isEmpty ? nil : "@" + (botName(rule.bot ?? "") ?? rule.bot ?? "")
        let text = rule.prefix.isEmpty ? nil : shown(rule.prefix)
        let parts = [bot, text, model.map { "→ \($0)" }].compactMap(\.self)
        return parts.isEmpty ? "—" : parts.joined(separator: " ")
    }

    /// A bot's name by its profile, as the roster last had it.
    static func botName(_ profile: String) -> String? {
        BotDirectory.shared.roster?.bots.first { $0.name == profile }?.label(mainName: Settings.shared.headerTitle)
    }

    /// The bots on this server (the main agent too) that no rule goes to yet.
    static func botsWithoutRules(_ settings: Settings) -> [HermesBot] {
        guard settings.transport == .hermesServe, settings.showBots, BotDirectory.shared.key == settings.connectionKey,
              let bots = BotDirectory.shared.roster?.bots else { return [] }
        let ruled = Set(settings.spokenPrefixes.compactMap(\.bot))
        return bots.filter { !$0.isHidden && !ruled.contains($0.name) }.sorted { a, b in a.isDefault != b.isDefault ? a.isDefault : a.name < b.name }
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
                Picker("Bot", selection: Binding(get: { rule.bot ?? "" }, set: { rule.bot = $0.isEmpty ? nil : $0 })) {
                    Text("Stay where I am").tag("")
                    ForEach(BotDirectory.shared.roster?.bots.filter { !$0.isHidden } ?? []) { bot in
                        Text(bot.label(mainName: Settings.shared.headerTitle)).tag(bot.name)
                    }
                    // A rule kept for a bot not on this server now.
                    if let bot = rule.bot, !bot.isEmpty, BotDirectory.shared.roster?.bots.contains(where: { $0.name == bot }) != true {
                        Text(bot).tag(bot)
                    }
                }
            } header: {
                Text("Bot")
            } footer: {
                Text("Goes to this bot's chat before sending, and voice stays with it until another rule moves it. On the Dashboard connection.")
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
                    if let bot = route.bot { Text("To \(SpokenPrefixesView.botName(bot) ?? bot)").font(.callout).foregroundStyle(.secondary) }
                    Text(route.text).font(.body.monospaced())
                    if let model = route.model { Text("Model → \(model)").font(.callout).foregroundStyle(.secondary) }
                } else {
                    Text("Unchanged: add a word, then a bot, a prefix or a model.").foregroundStyle(.secondary)
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
