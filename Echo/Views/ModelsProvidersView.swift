import SwiftUI

/// Settings → Models & Providers, and the same for each bot: its provider keys, sign-ins and
/// endpoints of its own, the model new chats start on, the models it falls back to and the
/// models its side jobs run on (`ModelSetup`).
struct ModelsProvidersView: View {
    let profile: String
    /// Whose they are, for the title's footers: "Sol", "Lookout".
    let owner: String

    @State private var model: ModelsProvidersModel

    init(profile: String, owner: String) {
        self.profile = profile
        self.owner = owner
        _model = State(initialValue: ModelsProvidersModel(service: ModelSetup.service(profile: profile)))
    }

    var body: some View {
        List {
            if let problem = model.problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            if model.loaded {
                defaultSection
                fallbackSection
                helperSection
                keysSection
                endpointsSection
                signInSection
            } else if model.problem == nil {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("Models & Providers")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load(refresh: true) }
        .task { await model.load(refresh: false) }
        .disabled(model.busy)
        .overlay { if model.busy { ProgressView().controlSize(.large) } }
        .alert("Use this model?", isPresented: Binding(get: { model.confirming != nil }, set: { if !$0 { model.confirming = nil } })) {
            Button("Use It") { Task { await model.confirmMain() } }
            Button("Cancel", role: .cancel) { model.confirming = nil }
        } message: {
            Text(model.confirming?.message ?? "")
        }
        .alert("Helper models", isPresented: Binding(get: { !model.staleHelpers.isEmpty }, set: { if !$0 { model.staleHelpers = [] } })) {
            Button("Use the Default Model") { Task { await model.resetHelpers() } }
            Button("Keep Them", role: .cancel) { model.staleHelpers = [] }
        } message: {
            Text("Some helper models were picked for the old default model's provider. Put them all back on the new default model?")
        }
    }

    // MARK: Sections

    private var defaultSection: some View {
        Section {
            NavigationLink {
                SetupModelList(title: String(localized: "Default Model"), choices: model.setup.choices,
                               picked: { $0.provider == model.setup.mainProvider && $0.model == model.setup.mainModel }) { choice in
                    Task { await model.setMain(choice) }
                }
            } label: {
                LabeledContent("Default Model") {
                    Text(model.setup.mainModel.isEmpty ? String(localized: "Not set") : model.setup.mainModel)
                        .lineLimit(1)
                }
            }
        } footer: {
            Text("New chats with \(owner) start on it. A chat that has its own model, picked from its menu, keeps that one.")
        }
    }

    private var fallbackSection: some View {
        Section {
            ForEach(model.setup.fallbacks) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.model)
                    Text(model.setup.providerName(entry.provider)).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .onDelete { offsets in
                var list = model.setup.fallbacks
                list.remove(atOffsets: offsets)
                Task { await model.setFallbacks(list) }
            }
            .onMove { from, to in
                var list = model.setup.fallbacks
                list.move(fromOffsets: from, toOffset: to)
                Task { await model.setFallbacks(list) }
            }
            NavigationLink {
                SetupModelList(title: String(localized: "Add a Fallback"), choices: model.setup.choices, picked: { _ in false }) { choice in
                    let entry = ModelSetup.Fallback(provider: choice.provider, model: choice.model)
                    guard !model.setup.fallbacks.contains(entry) else { return }
                    Task { await model.setFallbacks(model.setup.fallbacks + [entry]) }
                }
            } label: {
                Label("Add a Model", systemImage: "plus")
            }
        } header: {
            HStack {
                Text("Fallback Models")
                Spacer()
                if model.setup.fallbacks.count > 1 { EditButton().font(.footnote).textCase(nil) }
            }
        } footer: {
            Text(fallbackFooter)
        }
    }

    private var fallbackFooter: String {
        let base = String(localized: "When the default model fails (a rate limit, an outage, an empty answer), Hermes tries these in order, and goes back to the default with the next message.")
        guard !model.service.canSignIn else { return base }
        return base + " " + String(localized: "Over the Hermes API, a chat that has its own model doesn't fall back.")
    }

    private var helperSection: some View {
        Section {
            NavigationLink {
                HelperModelsView(model: model)
            } label: {
                LabeledContent("Helper Models", value: helperSummary)
            }
        } footer: {
            Text("The models Hermes uses for side jobs: chat titles, reading pictures, summing up a long chat, checking approvals.")
        }
    }

    private var helperSummary: String {
        let own = model.setup.helpers.filter { !$0.followsMain }.count
        return own == 0 ? String(localized: "Same as Default") : String(localized: "\(own) of their own")
    }

    private var keysSection: some View {
        Section {
            ForEach(model.setup.addedKeys) { key in
                NavigationLink {
                    ProviderKeyView(model: model, key: key)
                } label: {
                    LabeledContent {
                        Text(key.preview ?? String(localized: "Added")).lineLimit(1)
                    } label: {
                        Text(key.name)
                    }
                }
            }
            if !model.setup.missingKeys.isEmpty {
                NavigationLink {
                    AddKeyList(model: model)
                } label: {
                    Label("Add a Key", systemImage: "plus")
                }
            }
        } header: {
            Text("API Keys")
        } footer: {
            Text("Each key goes into \(owner)'s .env on your server. Redde never reads one back: Hermes shows only its first and last letters.")
        }
    }

    private var endpointsSection: some View {
        Section {
            ForEach(model.setup.endpoints) { endpoint in
                NavigationLink {
                    EndpointEditor(model: model, existing: endpoint)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(endpoint.name)
                            if endpoint.isCurrent {
                                Text("Default").font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                            }
                        }
                        Text(endpoint.baseURL).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            NavigationLink {
                EndpointEditor(model: model, existing: nil)
            } label: {
                Label("Add an Endpoint", systemImage: "plus")
            }
        } header: {
            Text("Your Endpoints")
        } footer: {
            Text("Any server that speaks the OpenAI API: llama.cpp, LM Studio, Ollama, vLLM, or a hosted one.")
        }
    }

    @ViewBuilder private var signInSection: some View {
        if model.service.canSignIn {
            if !model.signIns.isEmpty {
                Section {
                    ForEach(model.signIns) { signIn in SignInRow(model: model, signIn: signIn) }
                } header: {
                    Text("Sign-Ins")
                } footer: {
                    Text("Subscriptions that sign in rather than take a key. Some sign in only on your server, with the command shown.")
                }
            }
        } else {
            Section {
            } header: {
                Text("Sign-Ins")
            } footer: {
                Text(APIModelSetup.signInElsewhere)
            }
        }
    }
}

// MARK: - The page's state

@MainActor @Observable
final class ModelsProvidersModel {
    let service: any ModelSetupService
    var setup = ModelSetup.empty
    var signIns: [ProviderSignIn] = []
    var loaded = false
    var busy = false
    var problem: String?
    /// The model waiting for a yes, and Hermes's question.
    var confirming: (choice: ModelChoice, message: String)?
    var staleHelpers: [String] = []

    init(service: any ModelSetupService) { self.service = service }

    func load(refresh: Bool) async {
        do {
            setup = try await service.load(refresh: refresh)
            if service.canSignIn { signIns = (try? await service.signIns()) ?? [] }
            loaded = true
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Does one change, then reads everything again: Hermes may have changed more than it was asked
    /// (a key also sets the provider up; an endpoint can become the default).
    func run(_ change: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await change()
            await load(refresh: false)
        } catch {
            problem = error.localizedDescription
        }
    }

    func setMain(_ choice: ModelChoice, confirmed: Bool = false) async {
        busy = true
        defer { busy = false }
        do {
            switch try await service.setMain(provider: choice.provider, model: choice.model, confirmed: confirmed) {
            case let .confirm(message):
                confirming = (choice, message)
            case let .done(stale):
                await load(refresh: false)
                staleHelpers = stale
            }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    func confirmMain() async {
        guard let choice = confirming?.choice else { return }
        confirming = nil
        await setMain(choice, confirmed: true)
    }

    func resetHelpers() async {
        staleHelpers = []
        await run { try await service.setHelper(task: "__reset__", provider: "auto", model: "") }
    }

    func setFallbacks(_ list: [ModelSetup.Fallback]) async {
        setup.fallbacks = list   // shown at once; read again after
        await run { try await service.setFallbacks(list) }
    }
}

// MARK: - Picking a model

/// Hermes's models grouped by provider, with a search box: OpenRouter alone lists hundreds.
struct SetupModelList: View {
    let title: String
    let choices: [ModelChoice]
    /// A first row that isn't a model ("Same as Default Model"), and whether it is the one now.
    var leading: (label: String, picked: Bool)? = nil
    let picked: (ModelChoice) -> Bool
    /// Nil for the leading row.
    let chose: (ModelChoice?) -> Void
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    init(title: String, choices: [ModelChoice], leading: (label: String, picked: Bool)? = nil,
         picked: @escaping (ModelChoice) -> Bool, chose: @escaping (ModelChoice?) -> Void) {
        self.title = title
        self.choices = choices
        self.leading = leading
        self.picked = picked
        self.chose = chose
    }

    init(title: String, choices: [ModelChoice], picked: @escaping (ModelChoice) -> Bool, chose: @escaping (ModelChoice) -> Void) {
        self.init(title: title, choices: choices, leading: nil, picked: picked) { if let choice = $0 { chose(choice) } }
    }

    private var shown: [ModelChoice] {
        let words = search.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return choices }
        return choices.filter { $0.name.localizedCaseInsensitiveContains(words) || $0.model.localizedCaseInsensitiveContains(words)
            || $0.providerName.localizedCaseInsensitiveContains(words) }
    }

    var body: some View {
        List {
            if let leading, search.isEmpty {
                Section { row(leading.label, picked: leading.picked) { chose(nil) } }
            }
            ForEach(ModelPickerView.grouped(shown), id: \.provider) { group in
                Section(group.name) {
                    ForEach(group.models) { choice in
                        row(choice.name, picked: picked(choice)) { chose(choice) }
                    }
                }
            }
            if choices.isEmpty {
                Section { Text("Hermes offered no models. Add a key or an endpoint first.").foregroundStyle(.secondary) }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ label: String, picked: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack {
                Text(label).foregroundStyle(.primary)
                Spacer()
                if picked { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
            }
            .contentShape(.rect)
        }
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

// MARK: - Helper models

private struct HelperModelsView: View {
    let model: ModelsProvidersModel

    var body: some View {
        List {
            Section {
                ForEach(model.setup.helpers) { helper in
                    NavigationLink {
                        SetupModelList(title: Self.name(helper), choices: model.setup.choices,
                                       leading: (String(localized: "Same as Default Model"), helper.followsMain),
                                       picked: { !helper.followsMain && $0.provider == helper.provider && $0.model == helper.model }) { choice in
                            Task {
                                await model.run {
                                    try await model.service.setHelper(task: helper.task, provider: choice?.provider ?? "auto", model: choice?.model ?? "")
                                }
                            }
                        }
                    } label: {
                        LabeledContent {
                            Text(helper.followsMain ? String(localized: "Same as Default") : helper.model).lineLimit(1)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.name(helper))
                                if let hint = helper.hint ?? Self.hint(helper.task) {
                                    Text(hint).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } footer: {
                Text("A small, fast model is often enough for these, and cheaper.")
            }
            if model.setup.helpers.contains(where: { !$0.followsMain }) {
                Section {
                    Button("Put All Back on the Default Model") { Task { await model.resetHelpers() } }
                }
            }
        }
        .navigationTitle("Helper Models")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(model.busy)
    }

    static func name(_ helper: ModelSetup.Helper) -> String {
        if let label = helper.label { return label }
        switch helper.task {
        case "vision": return String(localized: "Pictures", comment: "Helper model task: reading images")
        case "compression": return String(localized: "Long Chats", comment: "Helper model task: summing up a long conversation")
        case "title_generation": return String(localized: "Chat Titles", comment: "Helper model task")
        case "approval": return String(localized: "Approvals", comment: "Helper model task: judging risky commands")
        case "review": return String(localized: "Reviews", comment: "Helper model task")
        case "mcp": return String(localized: "MCP Tools", comment: "Helper model task")
        case "skills_hub": return String(localized: "Skills Hub", comment: "Helper model task")
        case "voice_chat": return String(localized: "Voice", comment: "Helper model task")
        case "triage_specifier": return String(localized: "Kanban Triage", comment: "Helper model task")
        case "kanban_decomposer": return String(localized: "Kanban Planning", comment: "Helper model task")
        case "profile_describer": return String(localized: "Describing Bots", comment: "Helper model task")
        case "curator": return String(localized: "Curator", comment: "Helper model task: tidies skills and memory")
        default: return helper.task.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func hint(_ task: String) -> String? {
        switch task {
        case "vision": String(localized: "Reads pictures for a model that can't see.")
        case "compression": String(localized: "Sums up a long chat so it fits.")
        case "approval": String(localized: "Judges whether a command is safe to run.")
        case "title_generation": String(localized: "Names new chats.")
        default: nil
        }
    }
}

// MARK: - A provider's key

/// The providers that have no key yet, each to add one to.
private struct AddKeyList: View {
    let model: ModelsProvidersModel
    @State private var search = ""

    private var shown: [ModelSetup.ProviderKey] {
        let words = search.trimmingCharacters(in: .whitespaces)
        return model.setup.missingKeys.filter { words.isEmpty || $0.name.localizedCaseInsensitiveContains(words) }
    }

    var body: some View {
        List(shown) { key in
            NavigationLink(key.name) { ProviderKeyView(model: model, key: key) }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle("Add a Key")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ProviderKeyView: View {
    let model: ModelsProvidersModel
    let key: ModelSetup.ProviderKey
    @State private var value = ""
    @State private var confirmingRemove = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                SecureField(key.isSet ? String(localized: "New key") : String(localized: "Key"), text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
            } header: {
                Text(verbatim: key.env)
            } footer: {
                if key.isSet, let preview = key.preview {
                    Text("Now: \(preview). A new one takes its place.")
                }
            }
            Section {
                Button("Save Key") {
                    let typed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await model.run { try await model.service.setKey(key.env, value: typed) }
                        if model.problem == nil { dismiss() }
                    }
                }
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if key.isSet {
                Section {
                    Button("Remove Key", role: .destructive) { confirmingRemove = true }
                }
            }
            if let problem = model.problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
        .navigationTitle(key.name)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(model.busy)
        .confirmationDialog("Remove the \(key.name) key?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive) {
                Task {
                    await model.run { try await model.service.removeKey(key.env) }
                    if model.problem == nil { dismiss() }
                }
            }
        } message: {
            Text("Models from \(key.name) stop working until a key is added again. Its sign-in, if it has one, stays.")
        }
    }
}

// MARK: - An endpoint of your own

private struct EndpointEditor: View {
    let model: ModelsProvidersModel
    let existing: ModelSetup.Endpoint?
    @State private var name = ""
    @State private var address = ""
    @State private var key = ""
    @State private var removeKey = false
    @State private var modelName = ""
    @State private var found: [String] = []
    @State private var makeDefault = false
    @State private var testing = false
    @State private var tested: EndpointTest?
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Address", text: $address, prompt: Text(verbatim: "http://192.168.1.20:8080/v1"))
                    .urlFieldStyle()
                SecureField(existing?.hasKey == true ? String(localized: "API key (leave empty to keep it)") : String(localized: "API key (if it needs one)"), text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if existing?.hasKey == true {
                    Toggle("Remove Its Key", isOn: $removeKey)
                }
            }
            Section {
                Button {
                    test()
                } label: {
                    HStack {
                        Text("Test and List Models")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(trimmedAddress.isEmpty || testing)
                if let tested {
                    Label(tested.message.isEmpty ? (tested.reachable ? String(localized: "It answered.") : String(localized: "It didn't answer.")) : tested.message,
                          systemImage: tested.reachable ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(tested.reachable ? Color.green : Color.orange)
                }
            } footer: {
                Text("Hermes asks the address for its models, from your server, so it has to reach it from there.")
            }
            Section {
                if found.isEmpty {
                    TextField("Model", text: $modelName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    Picker("Model", selection: $modelName) {
                        ForEach(found, id: \.self) { Text($0).tag($0) }
                    }
                }
                if existing?.isCurrent != true {
                    Toggle("Make It the Default Model", isOn: $makeDefault)
                }
            }
            if let problem = model.problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            if let existing {
                Section {
                    Button("Delete Endpoint", role: .destructive) { confirmingDelete = true }
                        .disabled(existing.isCurrent)
                } footer: {
                    if existing.isCurrent {
                        Text("It is the default model's. Pick another default model before deleting it.")
                    }
                }
            }
        }
        .navigationTitle(existing?.name ?? String(localized: "New Endpoint"))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(model.busy)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || trimmedAddress.isEmpty
                              || modelName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .confirmationDialog("Delete \(existing?.name ?? "")?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Endpoint", role: .destructive) {
                guard let id = existing?.id else { return }
                Task {
                    await model.run { try await model.service.deleteEndpoint(id) }
                    if model.problem == nil { dismiss() }
                }
            }
        } message: {
            Text("Its key goes too. Fallback and helper models that use it stop working.")
        }
        .onAppear {
            guard let existing, name.isEmpty else { return }
            name = existing.name
            address = existing.baseURL
            modelName = existing.model
            found = existing.models.contains(existing.model) || existing.models.isEmpty ? existing.models : [existing.model] + existing.models
        }
    }

    private func test() {
        testing = true
        tested = nil
        let typedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        Task {
            defer { testing = false }
            do {
                let result = try await model.service.testEndpoint(baseURL: trimmedAddress, apiKey: typedKey, apiMode: existing?.apiMode ?? "")
                tested = result
                if let resolved = result.resolvedBaseURL { address = resolved }
                if !result.models.isEmpty {
                    found = result.models
                    if !found.contains(modelName) { modelName = found[0] }
                }
            } catch {
                tested = EndpointTest(reachable: false, message: error.localizedDescription, models: [])
            }
        }
    }

    private func save() {
        let typedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = EndpointDraft(id: existing?.id, name: name.trimmingCharacters(in: .whitespaces), baseURL: trimmedAddress,
                                  model: modelName.trimmingCharacters(in: .whitespaces),
                                  apiKey: removeKey ? "" : typedKey.nilIfEmpty,
                                  apiMode: existing?.apiMode ?? "", makeDefault: makeDefault)
        Task {
            await model.run { try await model.service.saveEndpoint(draft) }
            if model.problem == nil { dismiss() }
        }
    }
}

// MARK: - Sign-ins (the Dashboard's)

private struct SignInRow: View {
    let model: ModelsProvidersModel
    let signIn: ProviderSignIn
    @State private var code: SignInCode?
    @State private var waiting: Task<Void, Never>?
    @State private var failed: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(signIn.name)
                    if signIn.signedIn {
                        Text(signIn.account.map { String(localized: "Signed in · \($0)") } ?? String(localized: "Signed in"))
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if signIn.flow != "device_code", let command = signIn.command {
                        Text(command).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer()
                if signIn.signedIn {
                    Button("Sign Out", role: .destructive) {
                        Task { await model.run { try await model.service.signOut(signIn.id) } }
                    }
                    .buttonStyle(.borderless)
                } else if signIn.flow == "device_code" {
                    if code == nil {
                        Button("Sign In") { start() }.buttonStyle(.borderless)
                    } else {
                        Button("Cancel") { stop() }.buttonStyle(.borderless)
                    }
                }
            }
            if let code {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enter this code at \(code.url.host() ?? code.url.absoluteString):").font(.footnote)
                    HStack {
                        Text(code.code).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled)
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = code.code }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                        Button("Open") { openURL(code.url) }.buttonStyle(.borderless)
                    }
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for you to sign in…").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if let failed {
                Label(failed, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
        }
        .onDisappear { waiting?.cancel() }
    }

    private func start() {
        failed = nil
        waiting = Task {
            do {
                let started = try await model.service.startSignIn(signIn.id)
                code = started
                UIPasteboard.general.string = started.code
                openURL(started.url)
                while !Task.isCancelled {
                    switch try await model.service.pollSignIn(signIn.id, session: started.session) {
                    case .pending:
                        continue
                    case .approved:
                        code = nil
                        await model.load(refresh: true)
                        return
                    case let .failed(reason):
                        code = nil
                        failed = reason
                        return
                    }
                }
            } catch {
                if !Task.isCancelled { failed = error.localizedDescription }
                code = nil
            }
        }
    }

    private func stop() {
        waiting?.cancel()
        waiting = nil
        code = nil
    }
}
