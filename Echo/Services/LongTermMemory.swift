import Foundation

/// Where imported facts can go besides About You (USER.md, read into every conversation): the
/// long-term store this Hermes has, found in this order (asked 2026-11-03, "add the third option for
/// users using things other than BM too"):
///  1. its memory provider (`memory.provider`: Honcho, Mem0, Supermemory, …), whose tools only the
///     agent can call: one message, which the plugin's note (`longterm.py`) holds to exactly these;
///  2. a memory MCP server (Basic Memory, the "memory" knowledge graph), written to by the plugin with
///     no model call (`/redde-push memory save`), or by the agent when its tools aren't loaded;
///  3. nothing: a Markdown file in the profile's home (`notes/imported-<source>.md`), read when the
///     agent is asked to, and never searched on its own.
nonisolated enum LongTermMemory {
    enum Store: Equatable, Sendable {
        case provider(id: String, name: String)
        case server(kind: String, name: String, server: String)
        case notesFile

        /// "Basic Memory", "Honcho", or nil for the notes file.
        var name: String? {
            switch self {
            case let .provider(_, name), let .server(_, name, _): name
            case .notesFile: nil
            }
        }

        var buttonTitle: String {
            name.map { String(localized: "Save to \($0)") } ?? String(localized: "Save as a Notes File")
        }
    }

    /// Provider names as Hermes calls them (`memory.provider`), for the button.
    static let providerNames = [
        "honcho": "Honcho", "mem0": "Mem0", "supermemory": "Supermemory", "hindsight": "Hindsight",
        "holographic": "Holographic", "retaindb": "RetainDB", "byterover": "ByteRover", "openviking": "OpenViking",
        "qdrant-memory": "Qdrant Memory",
    ]

    static func providerName(_ id: String) -> String {
        providerNames[id.lowercased()] ?? id.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// A memory MCP server by its name in Hermes's list, when the plugin couldn't say (its tools not
    /// loaded in the Dashboard yet): Basic Memory, or the reference knowledge-graph server.
    static func serverStore(named names: [String]) -> Store? {
        let folded = names.map { ($0, $0.lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")) }
        if let basic = folded.first(where: { $0.1.contains("basic-memory") }) {
            return .server(kind: "basic-memory", name: "Basic Memory", server: basic.0)
        }
        if let graph = folded.first(where: { $0.1 == "memory" || $0.1.contains("memory-graph") || $0.1.contains("server-memory") || $0.1 == "knowledge-graph" }) {
            return .server(kind: "memory-graph", name: String(localized: "Memory Graph"), server: graph.0)
        }
        return nil
    }

    /// The store, from the provider the Dashboard names, then the plugin's look at the loaded tools
    /// (`memory stores`'s "best"), then the MCP servers' names.
    static func pick(provider: String?, pluginBest: JSONValue?, mcpServers: [String]) -> Store {
        if let provider = provider?.trimmingCharacters(in: .whitespaces), !provider.isEmpty {
            return .provider(id: provider, name: providerName(provider))
        }
        if let best = pluginBest, let kind = best["kind"]?.string {
            if kind == "provider", let id = best["provider"]?.string { return .provider(id: id, name: best["name"]?.string ?? providerName(id)) }
            if let server = best["server"]?.string { return .server(kind: kind, name: best["name"]?.string ?? kind, server: server) }
        }
        return serverStore(named: mcpServers) ?? .notesFile
    }

    // MARK: Saving

    /// The message the agent gets for a provider (or a server whose tools the plugin can't reach):
    /// the plugin's note holds it to exactly these, with its long-term store's tool.
    static func agentMessage(_ facts: [String], notes: [Note] = [], store: Store, from source: MemoryImport.Source) -> String {
        let from = source == .unknown ? String(localized: "another assistant") : source.rawValue
        var body = ""
        for fact in facts.prefix(60) {
            let line = "- " + fact.replacingOccurrences(of: "\n", with: " ") + "\n"
            if body.count + line.count > 4_000 { break }
            body += line
        }
        // Notes in full can run to kilobytes each: each shortened, the whole capped, the rest named.
        var left = 0
        for note in notes {
            let text = note.content.count > 1_500 ? String(note.content.prefix(1_500)) + " …" : note.content
            let block = "\n## \(note.title)\n\(text)\n"
            if body.count + block.count > 9_000 { left += 1; continue }
            body += block
        }
        if left > 0 { body += "\n(\(left) more notes didn't fit; I'll send them separately.)\n" }
        let named = store.name.map { " (\($0))" } ?? ""
        return "Save to long-term memory\(named): what I told \(from).\n" + body
    }

    /// A whole note to keep: Claude's memory file.
    struct Note: Equatable, Sendable {
        var title: String
        var content: String
        var folder: String
    }

    /// The notes file's text: a heading, when, and the facts as a list.
    static func notesFile(_ facts: [String], notes: [Note] = [], from source: MemoryImport.Source, on day: Date = .now) -> String {
        let from = source == .unknown ? "another assistant" : source.rawValue
        let when = day.formatted(.iso8601.year().month().day())
        var text = "# Imported from \(from)\n\nSaved by Redde on \(when). Not loaded into conversations; ask your agent to read this file when it's useful.\n"
        if !facts.isEmpty { text += "\n" + facts.map { "- " + $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n") + "\n" }
        for note in notes { text += "\n## \(note.title)\n\n\(note.content)\n" }
        return text
    }

    /// The ticked candidates as facts (lines) and notes (whole files).
    static func split(_ picked: [MemoryImport.Candidate]) -> (facts: [String], notes: [Note]) {
        var facts: [String] = [], notes: [Note] = []
        for candidate in picked {
            if candidate.kind == .note, let body = candidate.body {
                notes.append(Note(title: candidate.text, content: body, folder: candidate.folder ?? ""))
            } else {
                facts.append(candidate.text)
            }
        }
        return (facts, notes)
    }

    static func fileSource(_ source: MemoryImport.Source) -> String {
        switch source {
        case .chatGPT: "chatgpt"
        case .claude: "claude"
        case .unknown: "import"
        }
    }

    /// What `memory save` said: stored, or why not (nil when the agent should do it instead).
    enum Saved: Equatable, Sendable {
        case stored(Int)
        case useAgent
        case failed(String)
    }

    static func readSave(_ json: JSONValue) -> Saved {
        if let count = json["stored"]?.int { return .stored(count) }
        switch json["error"]?.string {
        case "not_loaded"?: return .useAgent
        case let code?: return .failed(json["message"]?.string ?? code)
        case nil: return .failed(String(localized: "Your Hermes didn't say whether it saved them."))
        }
    }
}

/// Finding the store and saving to it, for the import sheet.
@MainActor @Observable
final class LongTermMemoryModel {
    var store: LongTermMemory.Store?
    @ObservationIgnored var plugin: PushService.PluginCommand = PushService.command(over: .shared)
    let profile: String?
    let demo: Bool

    init(profile: String?, demo: Bool = false) {
        self.profile = profile
        self.demo = demo
    }

    func detect(provider: String?) async {
        if demo { store = .server(kind: "basic-memory", name: "Basic Memory", server: "basic-memory"); return }
        var best: JSONValue?
        if let said = try? await plugin("memory stores"), let json = Self.parse(said) { best = json["best"] }
        let servers = (try? await HermesServeClient.shared.mcpServers())?.filter(\.enabled).map(\.name) ?? []
        store = LongTermMemory.pick(provider: provider, pluginBest: best, mcpServers: servers)
    }

    /// Saves the facts: true when they're saved; a message for the agent when it has to do it.
    func save(_ picked: [MemoryImport.Candidate], from source: MemoryImport.Source) async throws -> (saved: Bool, agentMessage: String?) {
        guard let store else { return (false, nil) }
        let (facts, notes) = LongTermMemory.split(picked)
        switch store {
        case .provider:
            return (false, LongTermMemory.agentMessage(facts, notes: notes, store: store, from: source))
        case let .server(_, _, server):
            if demo { return (true, nil) }
            let request: JSONValue = .object(["server": .string(server.replacingOccurrences(of: "-", with: "_")),
                                              "items": .array(facts.map(JSONValue.string)),
                                              "notes": .array(notes.map { .object(["title": .string($0.title), "content": .string($0.content), "folder": .string($0.folder)]) }),
                                              "source": .string(LongTermMemory.fileSource(source))])
            let body = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
            guard let said = try? await plugin("memory save " + body), let json = Self.parse(said) else {
                return (false, LongTermMemory.agentMessage(facts, notes: notes, store: store, from: source))
            }
            switch LongTermMemory.readSave(json) {
            case .stored: return (true, nil)
            case .useAgent: return (false, LongTermMemory.agentMessage(facts, notes: notes, store: store, from: source))
            case let .failed(why): throw TransportError.malformed(why)
            }
        case .notesFile:
            if demo { return (true, nil) }
            let home = await AgentMemoryModel.home(of: profile)
            _ = try? await HermesServeClient.shared.makeFolder("notes", in: home)
            let path = home + "/notes/imported-\(LongTermMemory.fileSource(source)).md"
            let earlier = (try? await HermesServeClient.shared.readText(path: path)) ?? nil
            let text = LongTermMemory.notesFile(facts, notes: notes, from: source)
            try await HermesServeClient.shared.writeText(path: path, content: earlier.map { $0 + "\n" + text } ?? text)
            return (true, nil)
        }
    }

    static func parse(_ said: String) -> JSONValue? {
        PluginReply.json(said, "memory")
    }
}
