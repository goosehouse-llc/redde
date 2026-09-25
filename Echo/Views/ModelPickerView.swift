import SwiftUI

/// Which model answers, and how hard it thinks. Lists come from the active backend: the
/// gateway's model options for the Hermes transports, llama-swap's loaded models for the fast lane.
struct ModelPickerView: View {
    @Environment(Conversation.self) private var conversation
    @State private var settings = Settings.shared
    @State private var choices: [ModelChoice] = []
    @State private var error: String?
    @State private var loading = true
    /// Provider sections folded shut. Seeded once per open: cloud sections start collapsed
    /// unless they hold the current selection; Local stays open.
    @State private var collapsed: Set<String> = []
    @State private var collapsedSeeded = false

    private var isFastLane: Bool { settings.transport == .chatCompletions }

    private var byProvider: [(provider: String, name: String, models: [ModelChoice])] {
        Self.grouped(choices)
    }

    /// One "Local" section leads: every custom endpoint serves the same llama-swap catalog, so
    /// their groups fold together, deduped by model id and keyed to the current endpoint's slug.
    /// Cloud providers follow alphabetically.
    static func grouped(_ choices: [ModelChoice]) -> [(provider: String, name: String, models: [ModelChoice])] {
        let grouped = Dictionary(grouping: choices, by: \.provider)
        var out: [(provider: String, name: String, models: [ModelChoice])] = []
        let customKeys = grouped.keys.filter { $0.hasPrefix("custom") }.sorted()
        if !customKeys.isEmpty {
            let slug = customKeys.first { grouped[$0]?.contains(where: \.isCurrent) ?? false } ?? customKeys[0]
            var seen: Set<String> = []
            var models: [ModelChoice] = []
            for key in [slug] + customKeys.filter({ $0 != slug }) {
                for var choice in grouped[key] ?? [] where seen.insert(choice.model).inserted {
                    choice.provider = slug
                    models.append(choice)
                }
            }
            out.append((slug, "Local", models.sorted { $0.name < $1.name }))
        }
        for key in grouped.keys.filter({ !$0.hasPrefix("custom") }).sorted() {
            guard let models = grouped[key], let first = models.first else { continue }
            out.append((key, first.providerName, models.sorted { $0.name < $1.name }))
        }
        return out
    }

    var body: some View {
        List {
            Section {
                Picker("Reasoning effort", selection: $settings.reasoningEffort) {
                    Text("Default").tag("")
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
                .adaptiveSegmented()
            } header: {
                Text("Reasoning effort")
            } footer: {
                if isFastLane {
                    Text("On a self-hosted Qwen model, High switches extended thinking on for new turns; other levels answer without thinking. Models that don't support the switch ignore it.")
                } else {
                    Text("How much the model thinks before answering. Default leaves it to the gateway. Applies to new turns on the Hermes API and to new sessions on the Hermes Dashboard.")
                }
            }

            Section {
                Button { select(nil) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isFastLane ? Settings.defaultFastLaneModel : "Gateway default")
                            Text(isFastLane ? "llama-swap's configured default" : "Whatever Redde is configured to use")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if currentIsDefault { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("Model")
            } footer: {
                if !isFastLane { Text("Applies to this conversation and to new ones.") }
            }

            if let error {
                Section { Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary).font(.footnote) }
            } else if loading {
                Section { ProgressView("Loading models…") }
            }

            ForEach(byProvider, id: \.provider) { group in
                Section {
                    if !collapsed.contains(group.provider) {
                        modelRows(group.models)
                    }
                } header: {
                    Button {
                        withAnimation(.snappy) {
                            if collapsed.contains(group.provider) { collapsed.remove(group.provider) }
                            else { collapsed.insert(group.provider) }
                        }
                    } label: {
                        HStack {
                            Text(group.name)
                            Spacer()
                            if collapsed.contains(group.provider) {
                                Text("\(group.models.count)").foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .rotationEffect(.degrees(collapsed.contains(group.provider) ? -90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func modelRows(_ models: [ModelChoice]) -> some View {
        ForEach(models) { choice in
                        Button { select(choice) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(choice.name)
                                    if choice.name != choice.model {
                                        Text(choice.model).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if isSelected(choice) { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
                                else if choice.isCurrent { Text("current").font(.caption2).foregroundStyle(.secondary) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
        }
    }

    private var currentIsDefault: Bool {
        isFastLane ? settings.fastLaneModel == Settings.defaultFastLaneModel : settings.gatewayModel.isEmpty
    }

    private func isSelected(_ choice: ModelChoice) -> Bool {
        if isFastLane { return settings.fastLaneModel == choice.model }
        return settings.gatewayModel == choice.model && (settings.gatewayProvider.isEmpty || settings.gatewayProvider == choice.provider)
    }

    private func select(_ choice: ModelChoice?) {
        if isFastLane {
            settings.fastLaneModel = choice?.model ?? Settings.defaultFastLaneModel
            return
        }
        settings.gatewayModel = choice?.model ?? ""
        settings.gatewayProvider = choice?.provider ?? ""
        applyToOpenConversation(choice)
    }

    /// Both hermes backends pin a conversation's model once it has one, so a picker change must
    /// also re-pin the open conversation: sessions via the model-lock route, serve via
    /// `config.set`. "Gateway default" re-pins to the option the backend marks current — a
    /// pin can't be cleared, only moved.
    private func applyToOpenConversation(_ choice: ModelChoice?) {
        guard let sid = conversation.serverSessionID,
              let target = choice ?? choices.first(where: \.isCurrent) else { return }
        let transport = settings.transport
        Task {
            do {
                switch transport {
                case .hermesSessions:
                    guard let api = conversation.ledgerAPI() else { return }
                    try await api.lockSessionModel(id: sid, model: target.model, provider: target.provider)
                case .hermesServe:
                    let (runtime, _) = try await HermesServeClient.shared.openSession(stored: sid)
                    try await HermesServeClient.shared.setSessionModel(runtimeSession: runtime, model: target.model)
                case .chatCompletions:
                    break
                }
            } catch {
                self.error = "Couldn't switch this conversation: \(error.localizedDescription)"
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            if isFastLane {
                choices = try await Self.fastLaneModels(base: settings.activeBaseURL)
            } else if let backend = SessionBackend.available(conversation).first {
                choices = try await backend.modelOptions()
            } else {
                error = SessionBackend.notConfiguredMessage
                return
            }
            error = nil
            if !collapsedSeeded {
                collapsedSeeded = true
                collapsed = Set(byProvider.filter { group in
                    !group.provider.hasPrefix("custom") && !group.models.contains(where: isSelected)
                }.map(\.provider))
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// llama-swap lists every model it can load, with the ones already loaded flagged.
    static func fastLaneModels(base: URL?) async throws -> [ModelChoice] {
        guard let base else { throw TransportError.badURL }
        var request = URLRequest(url: base.appending(path: "v1/models"))
        request.timeoutInterval = 6
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        // Named after the server's host, not anyone's machine name.
        let providerName = base.host().map { "llama-swap · \($0)" } ?? "llama-swap"
        return (json["data"]?.array ?? []).compactMap { entry in
            guard let id = entry["id"]?.string else { return nil }
            let loaded = entry["status"]?["value"]?.string == "loaded"
            return ModelChoice(provider: "llama-swap", providerName: providerName, model: id,
                               name: loaded ? "\(id)  ·  loaded" : id, isCurrent: loaded)
        }
    }
}
