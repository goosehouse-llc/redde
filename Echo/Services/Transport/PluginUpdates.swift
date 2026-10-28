import Foundation

/// Checking the Hermes plugins installed for each agent for updates (asked 2026-10-28: "a way to
/// search for hermes installed plugin updates"). Hermes checks its own (`hermes plugins
/// check-updates`, and once a day in its gateway), but tells only its log; its Dashboard says only
/// whether a catalog install has a newer pin. So the rest is worked out here, as Hermes's checker
/// works it out:
/// - a catalog install: what the Dashboard says (`update_available`, against the live catalog);
/// - one installed from git: its record in the plugins folder's `.install-metadata.json` (read
///   through the Dashboard's files) names the repository and the commit installed; GitHub says
///   whether newer commits change the plugin's folder. Asked by the phone, of api.github.com, with
///   the repository's name and nothing else;
/// - one whose manifest names an update feed (`update_url`): the feed's version;
/// - Redde's own plugin: the version this app was made with.
/// A pinned install (`--ref`) is kept where it is. Updating: a catalog install re-pins to the
/// catalog (`plugins.manage update`); a git one is installed again from its source (`install`,
/// `force`), switched on as it was.
nonisolated enum PluginUpdateState: Equatable, Sendable {
    /// Hermes's catalog pins a newer one (its version, when the catalog says).
    case catalog(String?)
    /// Newer commits in its repository change it.
    case commits(Int)
    /// Its update feed has a newer version.
    case feed(String)
    /// Redde's plugin: this app was made with a newer one, installed from Redde Plugin.
    case redde(String)
    case current
    /// Why it can't be checked.
    case unknown(String)

    var hasUpdate: Bool {
        switch self {
        case .catalog, .commits, .feed, .redde: true
        case .current, .unknown: false
        }
    }
}

nonisolated struct PluginUpdateCheck: Identifiable, Equatable, Sendable {
    /// The agent's profile; nil, the one Redde is on.
    var profile: String?
    var owner: String
    var plugin: InstalledPlugin
    var state: PluginUpdateState
    /// Where it was installed from, for a git one.
    var source: String?

    var id: String { (profile ?? "") + "/" + plugin.key }
}

/// A plugin's line in the plugins folder's `.install-metadata.json`.
nonisolated struct PluginInstallRecord: Decodable, Equatable, Sendable {
    var pinned: Bool?
    var revision: String?
    var source: String?
    var update_url: String?
    var catalog: JSONValue?
}

nonisolated enum PluginUpdates {
    /// Redde's plugin, by its folder's name.
    static let reddePlugin = "redde-push"

    /// A GitHub source as Hermes records it ("https://github.com/o/r.git#sub/dir").
    static func github(_ source: String) -> (owner: String, repo: String, subdir: String?)? {
        let (url, _, fragment) = source.partition("#")
        guard let comps = URLComponents(string: url), comps.host?.lowercased() == "github.com" else { return nil }
        let parts = comps.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        let subdir = fragment.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (parts[0], repo, subdir.isEmpty ? nil : subdir)
    }

    /// How many of `ahead` commits matter: all of them, or (a plugin in a folder of its repository)
    /// none unless one changes a file in that folder.
    static func behind(ahead: Int, changed files: [String], subdir: String?) -> Int {
        // GitHub lists 300 files at most: past that, the plugin's may be among those left out.
        guard let subdir, files.count < 300 else { return ahead }
        return files.contains { $0 == subdir || $0.hasPrefix(subdir + "/") } ? ahead : 0
    }

    /// An update feed's version (`version:` in its YAML).
    static func feedVersion(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("version:") else { continue }
            let value = trimmed.dropFirst("version:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func isNewer(_ latest: String, than current: String) -> Bool {
        let strip = { (v: String) in v.hasPrefix("v") ? String(v.dropFirst()) : v }
        return strip(latest).compare(strip(current), options: .numeric) == .orderedDescending
    }

    /// One plugin's state, from what Hermes says of it and its install record.
    static func state(of plugin: InstalledPlugin, record: PluginInstallRecord?, appPlugin: String = PushPlugin.version,
                      commitsBehind: (String, String, String?, String) async throws -> Int,
                      feed: (String) async throws -> String) async -> PluginUpdateState {
        if plugin.updateAvailable { return .catalog(plugin.catalogVersion) }
        if plugin.catalogName != nil { return .current }
        if plugin.name == reddePlugin || plugin.key == reddePlugin {
            return isNewer(appPlugin, than: plugin.version) ? .redde(appPlugin) : .current
        }
        guard let record else { return .unknown(String(localized: "Installed by hand, not from git: nothing says where a newer one would be.")) }
        if record.pinned == true { return .unknown(String(localized: "Pinned to a commit: it stays there until it is installed again.")) }
        if let url = record.update_url, url.hasPrefix("https://") {
            do {
                guard let latest = feedVersion(try await feed(url)) else { return .unknown(String(localized: "Its update feed names no version.")) }
                return isNewer(latest, than: plugin.version) ? .feed(latest) : .current
            } catch {
                return .unknown(String(localized: "Its update feed didn't answer: \(error.localizedDescription)"))
            }
        }
        guard let source = record.source, let revision = record.revision, !revision.isEmpty else {
            return .unknown(String(localized: "Its install record names no source."))
        }
        guard let repo = github(source) else { return .unknown(String(localized: "Only plugins from GitHub can be checked from here.")) }
        do {
            let count = try await commitsBehind(repo.owner, repo.repo, repo.subdir, revision)
            return count > 0 ? .commits(count) : .current
        } catch {
            return .unknown(String(localized: "GitHub didn't answer: \(error.localizedDescription)"))
        }
    }

    // MARK: Asking

    /// The newer commits in a GitHub repository that change the plugin (`subdir`, or all of it).
    static func commitsBehind(owner: String, repo: String, subdir: String?, revision: String,
                              session: URLSession = .shared) async throws -> Int {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/compare/\(revision)...HEAD") else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Redde", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            throw TransportError.malformed(http.statusCode == 403 ? String(localized: "GitHub's limit for checks is reached; try again in an hour.")
                                           : String(localized: "GitHub answered \(http.statusCode)."))
        }
        struct Compare: Decodable { var ahead_by: Int?; var files: [File]?; struct File: Decodable { var filename: String } }
        let compare = try JSONDecoder().decode(Compare.self, from: data)
        return behind(ahead: compare.ahead_by ?? 0, changed: (compare.files ?? []).map(\.filename), subdir: subdir)
    }

    static func fetchText(_ url: String, session: URLSession = .shared) async throws -> String {
        guard let url = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Redde", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        return String(decoding: data.prefix(1_000_000), as: UTF8.self)
    }

    /// The install records in a plugins folder, by plugin name.
    static func records(in text: String?) -> [String: PluginInstallRecord] {
        guard let text, let data = text.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: PluginInstallRecord].self, from: data)) ?? [:]
    }
}

extension HermesServeClient {
    /// The installed plugins of a profile, each with its update state.
    func checkPluginUpdates(profile: String?, owner: String) async throws -> [PluginUpdateCheck] {
        let installed = try await installedPlugins(profile: profile).filter { !$0.bundled }
        var seen = Set<String>()
        let plugins = installed.filter { seen.insert($0.key).inserted }
        // The plugins folder's install records, beside the plugins.
        var records: [String: PluginInstallRecord] = [:]
        if let folder = plugins.lazy.compactMap({ $0.installDir.nilIfEmpty }).first.map({ ($0 as NSString).deletingLastPathComponent }) {
            records = PluginUpdates.records(in: try? await readText(path: folder + "/.install-metadata.json"))
        }
        var checks: [PluginUpdateCheck] = []
        for plugin in plugins {
            let folderName = (plugin.installDir as NSString).lastPathComponent
            let record = records[folderName] ?? records[plugin.name]
            let state = await PluginUpdates.state(of: plugin, record: record,
                                                  commitsBehind: { try await PluginUpdates.commitsBehind(owner: $0, repo: $1, subdir: $2, revision: $3) },
                                                  feed: { try await PluginUpdates.fetchText($0) })
            checks.append(PluginUpdateCheck(profile: profile, owner: owner, plugin: plugin, state: state, source: record?.source))
        }
        return checks.sorted { ($0.state.hasUpdate ? 0 : 1, $0.plugin.name) < ($1.state.hasUpdate ? 0 : 1, $1.plugin.name) }
    }

    /// A git install, installed again from where it came from, switched on as it was.
    func reinstallPlugin(_ check: PluginUpdateCheck) async throws -> PluginOutcome {
        guard let source = check.source else { throw TransportError.malformed(String(localized: "It has no source to install from.")) }
        try await ensureConnected()
        var params: [String: JSONValue] = ["action": .string("install"), "identifier": .string(source), "force": .bool(true),
                                           "enable": .bool(check.plugin.enabled)]
        if let profile = check.profile { params["profile"] = .string(profile) }
        let result = try await call("plugins.manage", params: .object(params), timeout: 600)
        return PluginOutcome(result, name: check.plugin.name)
    }
}

nonisolated private extension String {
    func partition(_ separator: Character) -> (String, Character?, String) {
        guard let i = firstIndex(of: separator) else { return (self, nil, "") }
        return (String(self[..<i]), separator, String(self[index(after: i)...]))
    }
}
