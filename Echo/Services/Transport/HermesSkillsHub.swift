import Foundation

/// A skill on Hermes's skills hub (`/api/skills/hub/*` on the Dashboard): the official catalog
/// that ships with Hermes, and what its sources (skills.sh, GitHub, ClawHub, LobeHub, the Hermes
/// index…) find. Installing one is Hermes's own `hermes skills install`, run on the server with
/// its security scan, for the main agent or a bot's profile.
nonisolated struct HubSkill: Identifiable, Equatable, Sendable {
    var name: String
    var description: String
    /// Where it comes from ("official", "skills-sh", "github", "clawhub"…).
    var source: String
    /// What Hermes installs it by ("official/<category>/<name>", "owner/repo/path"…).
    var identifier: String
    /// "builtin", "trusted" or "community": how far Hermes trusts its source.
    var trust: String
    var repo: String?
    var tags: [String]
    /// The official catalog's group ("general" for one that names none).
    var category: String?
    var id: String { identifier }

    init(name: String, description: String = "", source: String = "", identifier: String, trust: String = "community",
         repo: String? = nil, tags: [String] = [], category: String? = nil) {
        self.name = name; self.description = description; self.source = source; self.identifier = identifier
        self.trust = trust; self.repo = repo; self.tags = tags; self.category = category
    }

    init?(_ json: JSONValue) {
        guard let identifier = json["identifier"]?.string?.nilIfEmpty ?? json["name"]?.string?.nilIfEmpty else { return nil }
        self.init(name: json["name"]?.string?.nilIfEmpty ?? identifier, description: json["description"]?.string ?? "",
                  source: json["source"]?.string ?? "", identifier: identifier, trust: json["trust_level"]?.string ?? "community",
                  repo: json["repo"]?.string?.nilIfEmpty, tags: (json["tags"]?.array ?? []).compactMap(\.string),
                  category: json["category"]?.string?.nilIfEmpty)
    }

    /// Its name as installed on the server, from the hub's installed list: `identifier` there, or
    /// a ClawHub search hit's bare slug under its card id (`clawhub/<slug>`), as Hermes keys them.
    func installedName(in installed: [String: String]) -> String? {
        installed[identifier] ?? (source == "clawhub" && !identifier.contains("/") ? installed["clawhub/\(identifier)"] : nil)
    }
}

/// The hub as it stands for a profile: its sources, the featured skills (the Hermes index's
/// pick, where the index answers), and which skills it has installed from it.
nonisolated struct HubOverview: Equatable, Sendable {
    struct Source: Equatable, Sendable, Identifiable {
        var id: String
        var label: String
        var rateLimited = false
    }

    var sources: [Source] = []
    var featured: [HubSkill] = []
    /// Identifier → installed name.
    var installed: [String: String] = [:]

    init(sources: [Source] = [], featured: [HubSkill] = [], installed: [String: String] = [:]) {
        self.sources = sources; self.featured = featured; self.installed = installed
    }

    init(_ json: JSONValue) {
        sources = (json["sources"]?.array ?? []).compactMap { row in
            row["id"]?.string.map { Source(id: $0, label: row["label"]?.string ?? $0, rateLimited: row["rate_limited"]?.bool ?? false) }
        }
        featured = (json["featured"]?.array ?? []).compactMap(HubSkill.init)
        installed = Self.installed(json["installed"])
    }

    static func installed(_ json: JSONValue?) -> [String: String] {
        guard case let .object(rows)? = json else { return [:] }
        return rows.reduce(into: [:]) { out, row in out[row.key] = row.value["name"]?.string ?? row.key }
    }
}

/// A skill looked at before it is installed: its SKILL.md and the files that come with it.
nonisolated struct HubPreview: Equatable, Sendable {
    var skill: HubSkill
    var skillMarkdown: String
    var files: [String]

    init(_ json: JSONValue, identifier: String) {
        skill = HubSkill(json) ?? HubSkill(name: identifier, identifier: identifier)
        skillMarkdown = json["skill_md"]?.string ?? ""
        files = (json["files"]?.array ?? []).compactMap(\.string)
    }
}

/// Hermes's install-time security scan, run without installing: what it found, and whether an
/// install would go ahead ("allow"), need the person's say ("ask") or be refused ("block").
nonisolated struct HubScan: Equatable, Sendable {
    struct Finding: Equatable, Sendable, Identifiable {
        var severity: String
        var category: String
        var file: String
        var line: Int?
        var description: String
        var id: String { "\(file):\(line ?? 0):\(category):\(description)" }
    }

    var verdict: String
    var summary: String
    var policy: String
    var reason: String
    var findings: [Finding]

    init(verdict: String = "", summary: String = "", policy: String = "allow", reason: String = "", findings: [Finding] = []) {
        self.verdict = verdict; self.summary = summary; self.policy = policy; self.reason = reason; self.findings = findings
    }

    init(_ json: JSONValue) {
        verdict = json["verdict"]?.string ?? ""
        summary = json["summary"]?.string ?? ""
        policy = json["policy"]?.string ?? "ask"
        reason = json["policy_reason"]?.string ?? ""
        findings = (json["findings"]?.array ?? []).map { row in
            Finding(severity: row["severity"]?.string ?? "low", category: row["category"]?.string ?? "",
                    file: row["file"]?.string ?? "", line: row["line"]?.int, description: row["description"]?.string ?? "")
        }
        .sorted { HubScan.rank($0.severity) > HubScan.rank($1.severity) }
    }

    /// An install from the Dashboard runs with `--yes`: it goes ahead only where the scan allows it.
    var installs: Bool { policy == "allow" }

    static func rank(_ severity: String) -> Int {
        ["low": 0, "medium": 1, "high": 2, "critical": 3][severity] ?? 0
    }
}

extension HermesServeClient {
    /// The hub's sources, featured skills and what `profile` installed from it.
    func hubOverview(profile: String? = nil) async throws -> HubOverview {
        HubOverview(try await restJSON("GET", Self.naming("api/skills/hub/sources", profile: profile), timeout: 60))
    }

    /// Every skill in the official catalog that ships with Hermes, and which are installed.
    func hubOfficial(profile: String? = nil) async throws -> (skills: [HubSkill], installed: [String: Bool]) {
        let json = try await restJSON("GET", Self.naming("api/skills/hub/official", profile: profile), timeout: 60)
        let rows = json["skills"]?.array ?? []
        let skills = rows.compactMap(HubSkill.init)
        let installed = Dictionary(rows.compactMap { row in row["identifier"]?.string.map { ($0, row["installed"]?.bool ?? false) } },
                                   uniquingKeysWith: { a, _ in a })
        return (skills, installed)
    }

    /// A search across the hub's sources (network-bound on the server: up to half a minute).
    func hubSearch(_ query: String, profile: String? = nil) async throws -> (skills: [HubSkill], installed: [String: String], timedOut: [String]) {
        var comps = URLComponents()
        comps.path = "api/skills/hub/search"
        comps.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "30")]
        let json = try await restJSON("GET", Self.naming(comps.string ?? "api/skills/hub/search", profile: profile), timeout: 45)
        return ((json["results"]?.array ?? []).compactMap(HubSkill.init), HubOverview.installed(json["installed"]),
                (json["timed_out"]?.array ?? []).compactMap(\.string))
    }

    func hubPreview(_ identifier: String, profile: String? = nil) async throws -> HubPreview {
        HubPreview(try await restJSON("GET", Self.naming(Self.hubQuery("api/skills/hub/preview", identifier), profile: profile), timeout: 60),
                   identifier: identifier)
    }

    func hubScan(_ identifier: String, profile: String? = nil) async throws -> HubScan {
        HubScan(try await restJSON("GET", Self.naming(Self.hubQuery("api/skills/hub/scan", identifier), profile: profile), timeout: 90))
    }

    /// Starts Hermes's install of the skill on the server; the action to follow.
    func hubInstall(_ identifier: String, profile: String? = nil) async throws -> String {
        var body: [String: JSONValue] = ["identifier": .string(identifier)]
        if let profile { body["profile"] = .string(profile) }
        return try await restJSON("POST", "api/skills/hub/install", body: .object(body))["name"]?.string ?? ""
    }

    /// Starts its removal; the action to follow.
    func hubUninstall(name: String, profile: String? = nil) async throws -> String {
        var body: [String: JSONValue] = ["name": .string(name)]
        if let profile { body["profile"] = .string(profile) }
        return try await restJSON("POST", "api/skills/hub/uninstall", body: .object(body))["name"]?.string ?? ""
    }

    /// Follows an install or a removal until Hermes has done it (two minutes at most): how it
    /// ended, and what it printed.
    func hubFinish(_ action: String) async throws -> GatewayAction {
        guard !action.isEmpty else { return GatewayAction(running: false) }
        var last = GatewayAction(running: true)
        for _ in 0 ..< 120 {
            try await Task.sleep(for: .seconds(1))
            last = try await gatewayAction(action)
            if !last.running { break }
        }
        return last
    }

    nonisolated static func hubQuery(_ path: String, _ identifier: String) -> String {
        var comps = URLComponents()
        comps.path = path
        comps.queryItems = [URLQueryItem(name: "identifier", value: identifier)]
        return comps.string ?? path
    }
}
