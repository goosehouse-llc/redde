import SwiftUI

/// Forget a Topic (plugin 1.58.0, `forget.py`; asked 2026-11-27, "now build the muse gaps", after
/// Meta's Muse's "forget this topic"): what every agent remembers about one topic, and Things to Keep
/// in Mind, found by its words on the server and let go of exactly as ticked here. Works over either
/// connection, the plugin edits Hermes's memory files itself. A memory provider (Honcho, Mem0…) only
/// the agent can reach, so that part is a message to it.
enum ForgetTopic {
    struct Agent: Decodable, Identifiable, Equatable {
        var profile: String
        var name: String
        var user: [String]
        var memory: [String]
        var id: String { profile }
    }

    struct Found: Decodable, Equatable {
        var topic: String
        var agents: [Agent]
        var facts: [String]
        var provider: String?

        var count: Int { agents.reduce(facts.count) { $0 + $1.user.count + $1.memory.count } }
    }

    struct Forgot: Decodable, Equatable {
        var removed: Int
        var missed: Int
        var blocked: Bool
    }

    /// One thing found, as the page ticks it.
    struct Pick: Hashable {
        enum Place: Hashable { case user(String), memory(String), fact }
        var place: Place
        var text: String
    }

    enum Failure: Error, Equatable { case tooOld, unreachable }

    static func find(_ topic: String, through plugin: PushService.PluginCommand) async throws(Failure) -> Found {
        try await ask("memory find \(PushSeal.base64URL(Data(topic.utf8)))", answer: "memory found", through: plugin)
    }

    /// Lets go of the picks; `block`: ideas about the topic aren't suggested again.
    static func forget(_ picks: Set<Pick>, topic: String, block: Bool, through plugin: PushService.PluginCommand) async throws(Failure) -> Forgot {
        try await ask("memory forget \(PushSeal.base64URL(request(picks, topic: topic, block: block)))", answer: "memory forgot", through: plugin)
    }

    static func request(_ picks: Set<Pick>, topic: String, block: Bool) -> Data {
        var agents: [String: [String: [String]]] = [:]
        var facts: [String] = []
        for pick in picks.sorted(by: { $0.text < $1.text }) {
            switch pick.place {
            case .user(let profile): agents[profile, default: [:]]["user", default: []].append(pick.text)
            case .memory(let profile): agents[profile, default: [:]]["memory", default: []].append(pick.text)
            case .fact: facts.append(pick.text)
            }
        }
        let body: [String: Any] = ["topic": topic, "block": block, "facts": facts,
                                   "agents": agents.keys.sorted().map { ["profile": $0, "user": agents[$0]?["user"] ?? [], "memory": agents[$0]?["memory"] ?? []] }]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// Everything found, ticked as it starts.
    static func picks(_ found: Found) -> Set<Pick> {
        var all = Set(found.facts.map { Pick(place: .fact, text: $0) })
        for agent in found.agents {
            all.formUnion(agent.user.map { Pick(place: .user(agent.profile), text: $0) })
            all.formUnion(agent.memory.map { Pick(place: .memory(agent.profile), text: $0) })
        }
        return all
    }

    /// What the main agent is asked, for a provider's memories only it can reach.
    static func providerMessage(_ topic: String, provider: String) -> String {
        String(localized: "Forget everything about “\(topic)” in your long-term memory (\(provider)): delete each memory about it with \(provider)'s own tools, then tell me in a line how many you deleted.",
               comment: "Forget a Topic: the message to the agent for a memory provider; the topic, then the provider's name twice")
    }

    private static func ask<T: Decodable>(_ line: String, answer: String, through plugin: PushService.PluginCommand) async throws(Failure) -> T {
        let reply: String
        do { reply = try await plugin(line) } catch PushError.noPlugin { throw .tooOld } catch { throw .unreachable }
        let prefix = "redde-push \(answer) "
        guard reply.hasPrefix(prefix), let value = try? JSONDecoder().decode(T.self, from: Data(reply.dropFirst(prefix.count).utf8)) else {
            throw .tooOld
        }
        return value
    }
}

struct ForgetTopicView: View {
    var plugin: PushService.PluginCommand = PushService.command(over: Settings.shared)
    /// Told once something was let go, to read the memory again.
    var forgotten: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var topic = ""
    @State private var found: ForgetTopic.Found?
    @State private var picked: Set<ForgetTopic.Pick> = []
    @State private var block = true
    @State private var askProvider = true
    @State private var working = false
    @State private var problem: String?
    @State private var done: ForgetTopic.Forgot?
    @FocusState private var typing: Bool

    var body: some View {
        Form {
            Section {
                TextField(String(localized: "A person, a place, an old job…", comment: "Forget a Topic: the topic field's placeholder"), text: $topic)
                    .focused($typing)
                    .submitLabel(.search)
                    .onSubmit(look)
                    .disabled(working || done != nil)
                Button(String(localized: "Find What They Remember", comment: "Forget a Topic: looks for the topic in every agent's memory"), action: look)
                    .disabled(topic.trimmingCharacters(in: .whitespaces).isEmpty || working || done != nil)
            } footer: {
                Text("Looks through what every agent remembers about you and your Things to Keep in Mind. Nothing goes until you choose Forget.",
                     comment: "Forget a Topic: under the topic field")
            }
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote) }
            }
            if let done {
                Section {
                    Label(String(localized: "Forgot \(done.removed).", comment: "Forget a Topic: how many memories were let go"), systemImage: "checkmark.circle")
                    if done.missed > 0 {
                        Text("\(done.missed) had already changed or gone.", comment: "Forget a Topic: memories that weren't there any more")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("New conversations won't know it. Chats already open keep what they started with until they end.",
                         comment: "Forget a Topic: after forgetting")
                }
            } else if let found {
                results(found)
            }
        }
        .navigationTitle(Text("Forget a Topic", comment: "The page that lets every agent forget one topic"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(done == nil ? String(localized: "Cancel") : String(localized: "Done")) { dismiss() }
            }
        }
        .onAppear { typing = true }
    }

    @ViewBuilder
    private func results(_ found: ForgetTopic.Found) -> some View {
        if found.count == 0 {
            Section {
                Text("Nothing your agents remember mentions “\(found.topic)”.", comment: "Forget a Topic: no match")
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(found.agents) { agent in
            Section {
                ForEach(agent.user, id: \.self) { row(ForgetTopic.Pick(place: .user(agent.profile), text: $0)) }
                ForEach(agent.memory, id: \.self) { row(ForgetTopic.Pick(place: .memory(agent.profile), text: $0)) }
            } header: {
                Text(agent.name)
            }
        }
        if !found.facts.isEmpty {
            Section {
                ForEach(found.facts, id: \.self) { row(ForgetTopic.Pick(place: .fact, text: $0)) }
            } header: {
                Text("Things to Keep in Mind")
            }
        }
        Section {
            Toggle(String(localized: "Don't Suggest Ideas About It", comment: "Forget a Topic: also block ideas about the topic"), isOn: $block)
            if let provider = found.provider {
                Toggle(String(localized: "Also Ask Your Agent to Forget It in \(provider)", comment: "Forget a Topic: a message to the agent for its memory provider; the provider's name"),
                       isOn: $askProvider)
            }
            Button(role: .destructive, action: forget) {
                Text(picked.isEmpty ? String(localized: "Forget", comment: "Forget a Topic: the button, nothing ticked")
                                    : String(localized: "Forget \(picked.count)", comment: "Forget a Topic: the button, with how many are ticked"))
            }
            .disabled(working || (picked.isEmpty && !block && !(askProvider && found.provider != nil)))
        } footer: {
            if found.provider != nil {
                Text("Only your agent can reach its long-term memory, so it gets a message in a new chat.", comment: "Forget a Topic: under the provider switch")
            }
        }
    }

    private func row(_ pick: ForgetTopic.Pick) -> some View {
        Button {
            if picked.contains(pick) { picked.remove(pick) } else { picked.insert(pick) }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: picked.contains(pick) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(picked.contains(pick) ? Color.red : Color.secondary)
                Text(pick.text).foregroundStyle(.primary)
            }
        }
        .accessibilityAddTraits(picked.contains(pick) ? .isSelected : [])
    }

    private func look() {
        let words = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                let answer = try await ForgetTopic.find(words, through: plugin)
                found = answer
                picked = ForgetTopic.picks(answer)
            } catch {
                problem = Self.words(error as? ForgetTopic.Failure ?? .unreachable)
            }
        }
    }

    private func forget() {
        guard let found else { return }
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                done = try await ForgetTopic.forget(picked, topic: found.topic, block: block, through: plugin)
                forgotten()
                if askProvider, let provider = found.provider {
                    LaunchRouter.shared.requestGoalChat(profile: Settings.shared.profileName ?? ProfileCatalog.defaultID,
                                                        message: ForgetTopic.providerMessage(found.topic, provider: provider))
                    dismiss()
                }
            } catch {
                problem = Self.words(error as? ForgetTopic.Failure ?? .unreachable)
            }
        }
    }

    private static func words(_ error: ForgetTopic.Failure) -> String {
        switch error {
        case .tooOld: String(localized: "Forget a Topic takes the Redde plugin 1.58: update it in Settings › Redde Plugin.", comment: "Forget a Topic: the plugin is too old")
        case .unreachable: String(localized: "Couldn't reach your Hermes. Try again in a moment.")
        }
    }
}
