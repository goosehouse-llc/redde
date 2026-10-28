import Foundation

/// A plugin in Hermes's curated catalog: `plugin-catalog.json` on Nous Research's docs site, the one
/// Hermes reads itself for `hermes plugins install <name>`. Installed by name through the Dashboard
/// (`plugins.manage`, Hermes 0.21.3 and later), which resolves the pinned commit on the server.
nonisolated struct CatalogPlugin: Identifiable, Equatable, Sendable {
    /// Nous's own, checked by Nous, and everyone else's.
    enum Tier: String, Sendable, CaseIterable, Comparable {
        case official, verified, community

        var label: String {
            switch self {
            case .official: String(localized: "Official", comment: "A plugin's tier: Nous's own")
            case .verified: String(localized: "Verified", comment: "A plugin's tier: checked by Nous")
            case .community: String(localized: "Community", comment: "A plugin's tier: anyone else's")
            }
        }

        static func < (a: Tier, b: Tier) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
    }

    var name: String
    var title: String
    var description: String
    var maintainer: String
    var tier: Tier
    var category: String
    var version: String?
    /// The Hermes it needs, as the catalog writes it (">=0.22.0").
    var requiresHermes: String?
    /// The systems it runs on; empty, any.
    var platforms: [String]
    var docs: URL?
    var repo: String
    var image: URL?
    /// What it adds to the agent, and the keys it needs, as far as the catalog says.
    var tools: [String]
    var hooks: [String]
    var middleware: [String]
    var keys: [String]
    var knownIssues: [String]

    var id: String { name }

    init?(_ json: JSONValue) {
        guard let name = json["name"]?.string?.nilIfEmpty, let repo = json["repo"]?.string?.nilIfEmpty else { return nil }
        func strings(_ value: JSONValue?) -> [String] { (value?.array ?? []).compactMap { $0.string?.nilIfEmpty } }
        self.name = name
        self.repo = repo
        title = json["title"]?.string?.nilIfEmpty ?? Self.title(for: name)
        description = json["description"]?.string ?? ""
        maintainer = json["maintainer"]?.string ?? ""
        tier = json["tier"]?.string.flatMap(Tier.init(rawValue:)) ?? .community
        category = json["category"]?.string?.nilIfEmpty ?? "general"
        version = json["version"]?.string?.nilIfEmpty
        requiresHermes = json["requires_hermes"]?.string?.nilIfEmpty
        platforms = strings(json["platforms"])
        docs = json["docs_url"]?.string.flatMap(URL.init(string:))
        image = json["image"]?.string.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        let capabilities = json["capabilities"]
        tools = strings(capabilities?["provides_tools"])
        hooks = strings(capabilities?["provides_hooks"])
        middleware = strings(capabilities?["provides_middleware"])
        keys = strings(capabilities?["requires_env"])
        knownIssues = strings(json["known_issues"])
    }

    /// "elevenlabs-sound-effects" → "Elevenlabs Sound Effects", for an entry with no title.
    static func title(for name: String) -> String {
        name.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The description up to its "Disclosure:" sentences, and those: what it sends where, and what
    /// it costs, which the catalog asks each entry to say.
    var summary: String { parts.summary }
    var disclosure: String? { parts.disclosure }

    private var parts: (summary: String, disclosure: String?) {
        guard let range = description.range(of: "Disclosure:") else { return (description, nil) }
        let before = description[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let after = description[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (before, after.nilIfEmpty)
    }

    /// Whether a Hermes of `version` is new enough for it; nil when either can't be told (a build
    /// from source says 0.0.0), and Hermes decides at install.
    func runs(onHermes version: String) -> Bool? {
        guard let requiresHermes else { return true }
        return HermesVersion.meets(requiresHermes, version: version)
    }
}

/// Comparing Hermes releases with a catalog entry's `requires_hermes` (">=0.22.0", ">=0.21.6,<0.23").
nonisolated enum HermesVersion {
    static func parts(_ version: String) -> [Int]? {
        let digits = version.trimmingCharacters(in: .whitespaces).split(separator: ".").prefix(3).map { part in
            Int(part.prefix(while: \.isNumber))
        }
        guard digits.count >= 2, !digits.contains(nil) else { return nil }
        let numbers = digits.compactMap { $0 }
        return numbers == [0, 0, 0] || numbers == [0, 0] ? nil : numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    /// Nil where `version` isn't a release (unknown) or a clause can't be read.
    static func meets(_ requirement: String, version: String) -> Bool? {
        guard let have = parts(version) else { return nil }
        for clause in requirement.split(separator: ",") {
            let clause = clause.trimmingCharacters(in: .whitespaces)
            guard let op = ["==", ">=", "<=", ">", "<"].first(where: clause.hasPrefix),
                  let want = parts(String(clause.dropFirst(op.count))) else { return nil }
            let order = have.lexicographicallyPrecedes(want) ? -1 : (have == want ? 0 : 1)
            let ok = switch op {
            case ">=": order >= 0
            case "<=": order <= 0
            case ">": order > 0
            case "<": order < 0
            default: order == 0
            }
            if !ok { return false }
        }
        return true
    }
}

/// The catalog, as fetched: every entry still offered (removed ones dropped, as Hermes refuses
/// them), and when Nous made it.
nonisolated struct PluginCatalog: Equatable, Sendable {
    var plugins: [CatalogPlugin]
    var generated: String?

    static func parse(_ data: Data) -> PluginCatalog? {
        guard let json = try? JSONValue.parse(data), let entries = json["entries"]?.array else { return nil }
        let removed = Set((json["removed"]?.array ?? []).compactMap { $0["name"]?.string })
        let plugins = entries.compactMap(CatalogPlugin.init).filter { !removed.contains($0.name) }
        return PluginCatalog(plugins: plugins, generated: json["generated_at"]?.string)
    }

    /// The categories, the commonest first.
    var categories: [String] {
        Dictionary(grouping: plugins, by: \.category).sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }.map(\.key)
    }

    /// Plugins of `tiers` (and `category`) whose words hold every word of `query`, best first: the
    /// name, then the title, then who made it, then what it does; Nous's own before the rest.
    func search(_ query: String, tiers: Set<CatalogPlugin.Tier>, category: String? = nil) -> [CatalogPlugin] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let scored: [(plugin: CatalogPlugin, score: Int)] = plugins.compactMap { plugin in
            guard tiers.contains(plugin.tier), category == nil || plugin.category == category else { return nil }
            var score = 0
            let name = plugin.name.lowercased(), title = plugin.title.lowercased()
            let maintainer = plugin.maintainer.lowercased(), about = plugin.description.lowercased()
            for word in words {
                if name == word || title == word { score += 100 }
                else if name.hasPrefix(word) || title.hasPrefix(word) { score += 60 }
                else if name.contains(word) || title.contains(word) { score += 40 }
                else if maintainer.contains(word) { score += 20 }
                else if about.contains(word) { score += 10 }
                else { return nil }
            }
            return (plugin, score)
        }
        return scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.plugin.tier != $1.plugin.tier { return $0.plugin.tier < $1.plugin.tier }
            return $0.plugin.name < $1.plugin.name
        }.map(\.plugin)
    }
}

/// Where the catalog comes from: the phone fetches it from Nous's docs site (public, the same file
/// Hermes reads; the Dashboard can look up one entry, not list them), and keeps the last copy for
/// six hours, as Hermes does, and for when the site can't be reached.
nonisolated enum PluginCatalogStore {
    static let url = URL(string: "https://hermes-agent.nousresearch.com/docs/api/plugin-catalog.json")!
    static let freshFor: TimeInterval = 6 * 60 * 60
    private static var file: URL { URL.cachesDirectory.appending(path: "plugin-catalog.json") }

    static func load(refresh: Bool = false) async throws -> PluginCatalog {
        let cached = try? Data(contentsOf: file)
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date.now.timeIntervalSince($0) }
        if !refresh, let cached, let age, age < freshFor, let catalog = PluginCatalog.parse(cached) { return catalog }
        do {
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let catalog = PluginCatalog.parse(data) else { throw URLError(.cannotParseResponse) }
            try? data.write(to: file, options: .atomic)
            return catalog
        } catch {
            if let cached, let catalog = PluginCatalog.parse(cached) { return catalog }
            throw error
        }
    }
}

/// A plugin installed on the server for a profile (`plugins.manage list`).
nonisolated struct InstalledPlugin: Identifiable, Equatable, Sendable {
    var name: String
    var key: String
    var version: String
    var description: String
    /// "bundled" (comes with Hermes: switched on and off, never removed) or where it was installed from.
    var source: String
    /// "enabled", "disabled" or "not enabled".
    var status: String
    var catalogName: String?
    var catalogTier: CatalogPlugin.Tier?
    var updateAvailable: Bool
    /// The catalog's version of it, when it is a catalog install the catalog has.
    var catalogVersion: String?
    /// Where it is on the server (Hermes 0.22; empty before).
    var installDir: String
    var settings: [PluginSetting]
    /// Its servers (an MCP server it runs, an app it talks to), each with how it stands.
    var servers: [(name: String, state: String, sentence: String)]

    var id: String { key }
    var enabled: Bool { status == "enabled" }
    var bundled: Bool { source == "bundled" }

    init?(_ json: JSONValue) {
        guard let name = json["name"]?.string?.nilIfEmpty else { return nil }
        self.name = name
        key = json["key"]?.string?.nilIfEmpty ?? name
        version = json["version"]?.string ?? ""
        description = json["description"]?.string ?? ""
        source = json["source"]?.string ?? ""
        status = json["status"]?.string ?? (json["enabled"]?.bool == true ? "enabled" : "not enabled")
        catalogName = json["catalog_name"]?.string?.nilIfEmpty
        catalogTier = json["catalog_tier"]?.string.flatMap(CatalogPlugin.Tier.init(rawValue:))
        updateAvailable = json["update_available"]?.bool ?? false
        catalogVersion = json["catalog_version"]?.string?.nilIfEmpty
        installDir = json["install_dir"]?.string ?? ""
        settings = (json["settings_schema"]?.array ?? []).compactMap(PluginSetting.init)
        servers = (json["servers"]?.array ?? []).compactMap { row in
            row["name"]?.string.map { ($0, row["state"]?.string ?? "", row["sentence"]?.string ?? "") }
        }
    }

    static func == (a: InstalledPlugin, b: InstalledPlugin) -> Bool {
        a.key == b.key && a.status == b.status && a.version == b.version && a.updateAvailable == b.updateAvailable
            && a.settings == b.settings && a.servers.map(\.state) == b.servers.map(\.state)
    }
}

/// One setting a plugin declares. A secret one is kept in the profile's .env, its value never
/// shown: only whether it is set.
nonisolated struct PluginSetting: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case string, number, boolean, `enum`, secret, json }

    var key: String
    var kind: Kind
    var label: String
    var description: String
    var required: Bool
    var value: JSONValue?
    var choices: [String]
    /// A secret's .env name, and whether it has a value.
    var env: String?
    var isSet: Bool

    var id: String { key }

    init?(_ json: JSONValue) {
        guard let key = json["key"]?.string?.nilIfEmpty else { return nil }
        self.key = key
        kind = json["type"]?.string.flatMap(Kind.init(rawValue:)) ?? .string
        label = json["label"]?.string?.nilIfEmpty ?? key
        description = json["description"]?.string ?? ""
        required = json["required"]?.bool ?? false
        value = json["value"].flatMap { $0 == .null ? nil : $0 } ?? json["default"].flatMap { $0 == .null ? nil : $0 }
        choices = (json["choices"]?.array ?? []).compactMap(\.string)
        env = json["env"]?.string?.nilIfEmpty
        isSet = json["has_value"]?.bool ?? false
    }
}

/// What an install, an update or switching one on did, in words for the person.
nonisolated struct PluginOutcome: Equatable, Sendable {
    var name: String
    /// What works now (its MCP servers, skills, commands) and what from the agent's next chat (tools).
    var liveNow: [String] = []
    var nextChat: [String] = []
    /// No running gateway took it up: it starts with the next restart.
    var restartRequired = false
    /// Keys it needs that the profile hasn't got (.env names).
    var missingKeys: [String] = []
    var notes: [String] = []

    init(name: String) { self.name = name }

    init(_ json: JSONValue, name fallback: String) {
        name = json["plugin_name"]?.string?.nilIfEmpty ?? json["name"]?.string?.nilIfEmpty ?? fallback
        restartRequired = json["restart_required"]?.bool == true && json["gateway_reloaded"]?.bool != true
        missingKeys = (json["missing_env"]?.array ?? []).compactMap(\.string)
        notes = ((json["warnings"]?.array ?? []) + (json["known_issues"]?.array ?? [])).compactMap(\.string)
        if let activation = json["activation"] {
            let live = activation["live_now"]
            liveNow = (live?["mcp_servers"]?.array ?? []).compactMap { server in
                guard let name = server["name"]?.string else { return nil }
                if server["connected"]?.bool == true {
                    let tools = (server["tools"]?.array ?? []).compactMap(\.string)
                    return tools.isEmpty ? String(localized: "\(name) (connected)", comment: "An MCP server a plugin added") : "\(name): \(tools.joined(separator: ", "))"
                }
                let why = server["error"]?.string ?? String(localized: "no reason given")
                return String(localized: "\(name) didn't connect: \(why)")
            } + (live?["skills"]?.array ?? []).compactMap { $0["name"]?.string.map { String(localized: "the \($0) skill") } }
            for (kind, names) in (activation["activated_now"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
                let list = (names.array ?? []).compactMap(\.string)
                if !list.isEmpty { liveNow.append("\(kind.replacingOccurrences(of: "_", with: " ")): \(list.joined(separator: ", "))") }
            }
            for (kind, names) in (activation["deferred"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
                let list = (names.array ?? []).compactMap(\.string)
                if !list.isEmpty { nextChat.append("\(kind == "tools" ? "tools" : kind): \(list.joined(separator: ", "))") }
            }
        }
    }
}

/// Plugins over the Dashboard (`plugins.manage`; the Hermes API has no plugin calls). Each for
/// `profile`, a bot's; nil, the profile Redde is on.
extension HermesServeClient {
    func installedPlugins(profile: String?) async throws -> [InstalledPlugin] {
        try await ensureConnected()
        let result = try await call("plugins.manage", params: Self.plugins(["action": .string("list")], profile: profile), timeout: 60)
        return (result["plugins"]?.array ?? []).compactMap(InstalledPlugin.init)
    }

    /// A catalog plugin installed and switched on. Hermes clones it at the commit its catalog pins
    /// (never what a client names), refuses what the catalog has removed, scans it and installs its
    /// Python dependencies: minutes, some of them.
    func installPlugin(_ name: String, profile: String?) async throws -> PluginOutcome {
        try await ensureConnected()
        let result = try await call("plugins.manage", params: Self.plugins(
            ["action": .string("install"), "catalog_name": .string(name), "enable": .bool(true)], profile: profile), timeout: 600)
        return PluginOutcome(result, name: name)
    }

    func switchPlugin(_ plugin: InstalledPlugin, on: Bool, profile: String?) async throws -> PluginOutcome {
        try await ensureConnected()
        let result = try await call("plugins.manage", params: Self.plugins(
            ["action": .string("toggle"), "key": .string(plugin.key), "enable": .bool(on)], profile: profile), timeout: 120)
        return PluginOutcome(result, name: plugin.name)
    }

    enum PluginUpdate: Equatable, Sendable {
        case updated(PluginOutcome)
        case unchanged
        /// The new pin does more than the installed one (`lines` say what): nothing changed until
        /// asked again with `accepting`.
        case wantsMore([String])
    }

    func updatePlugin(_ name: String, accepting: Bool = false, profile: String?) async throws -> PluginUpdate {
        try await ensureConnected()
        var params: [String: JSONValue] = ["action": .string("update"), "name": .string(name)]
        if accepting { params["accept_capabilities"] = .bool(true) }
        let result = try await call("plugins.manage", params: Self.plugins(params, profile: profile), timeout: 600)
        if result["consent_required"]?.bool == true {
            let lines = (result["delta_lines"]?.array ?? []).compactMap(\.string)
            return .wantsMore(lines.isEmpty ? [result["error"]?.string ?? String(localized: "It does more than before.")] : lines)
        }
        return result["unchanged"]?.bool == true ? .unchanged : .updated(PluginOutcome(result, name: name))
    }

    /// Removes a plugin installed for the profile (not one that comes with Hermes; 0.21.5 and later).
    func removePlugin(_ name: String, profile: String?) async throws {
        try await ensureConnected()
        _ = try await call("plugins.manage", params: Self.plugins(["action": .string("remove"), "name": .string(name)], profile: profile), timeout: 120)
    }

    /// Its settings that aren't secret (0.21.5 and later).
    func setPluginSettings(_ plugin: InstalledPlugin, _ values: [String: JSONValue], profile: String?) async throws {
        try await ensureConnected()
        _ = try await call("plugins.manage", params: Self.plugins(
            ["action": .string("settings"), "key": .string(plugin.key), "values": .object(values)], profile: profile), timeout: 60)
    }

    /// A secret setting, or a key a plugin needs: into the profile's .env, as the Dashboard's own
    /// Keys page puts it there. Typed by the person on this phone; never shown again.
    func setPluginKey(_ name: String, value: String, profile: String?) async throws {
        var body: [String: JSONValue] = ["key": .string(name), "value": .string(value)]
        if let profile = profile ?? selectedProfile { body["profile"] = .string(profile) }
        _ = try await restJSON("PUT", "api/env", body: .object(body))
    }

    /// The Hermes release the Dashboard runs ("0.22.2"), nil when it can't be told.
    func hermesRelease() async -> String? {
        (try? await restJSON("GET", "api/status"))?["version"]?.string?.nilIfEmpty
    }

    private static func plugins(_ params: [String: JSONValue], profile: String?) -> JSONValue {
        var params = params
        if let profile { params["profile"] = .string(profile) }
        return .object(params)
    }
}
