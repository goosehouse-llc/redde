import Foundation
import Testing
@testable import Echo

/// Checking installed plugins for updates (asked 2026-10-28): what Hermes says of a catalog
/// install, a git install's record against GitHub, an update feed, Redde's own plugin.
struct PluginUpdatesTests {
    private func plugin(_ fields: [String: JSONValue]) throws -> InstalledPlugin {
        var row: [String: JSONValue] = ["name": .string("thing"), "version": .string("1.2.0"), "status": .string("enabled"),
                                        "source": .string("user"), "install_dir": .string("/home/h/.hermes/plugins/thing")]
        row.merge(fields) { $1 }
        return try #require(InstalledPlugin(.object(row)))
    }

    private func state(_ plugin: InstalledPlugin, _ record: PluginInstallRecord?, behind: Int = 0, feed: String = "",
                       asked: (@Sendable (String, String, String?, String) -> Void)? = nil) async -> PluginUpdateState {
        await PluginUpdates.state(of: plugin, record: record, appPlugin: "1.10.0",
                                  commitsBehind: { asked?($0, $1, $2, $3); return behind }, feed: { _ in feed })
    }

    @Test func aGitHubSourceIsReadAsHermesRecordsIt() {
        let found = PluginUpdates.github("https://github.com/goosehouse-llc/redde.git#companion/hermes-plugin/redde-push")
        #expect(found?.owner == "goosehouse-llc" && found?.repo == "redde" && found?.subdir == "companion/hermes-plugin/redde-push")
        #expect(PluginUpdates.github("https://github.com/acme/tool")?.subdir == nil)
        #expect(PluginUpdates.github("https://gitlab.com/acme/tool.git") == nil)
    }

    @Test func onlyCommitsThatChangeItsFolderCount() {
        #expect(PluginUpdates.behind(ahead: 5, changed: ["README.md", "app/x.swift"], subdir: "plugin") == 0)
        #expect(PluginUpdates.behind(ahead: 5, changed: ["plugin/core.py"], subdir: "plugin") == 5)
        #expect(PluginUpdates.behind(ahead: 3, changed: [], subdir: nil) == 3)
        #expect(PluginUpdates.behind(ahead: 2, changed: ["plugin-two/x.py"], subdir: "plugin") == 0, "a folder whose name starts the same isn't it")
        #expect(PluginUpdates.behind(ahead: 9, changed: Array(repeating: "app/x.swift", count: 300), subdir: "plugin") == 9, "a list GitHub cut short can't say")
    }

    @Test func versionsAndFeeds() {
        #expect(PluginUpdates.isNewer("1.10.0", than: "1.9.0") && !PluginUpdates.isNewer("1.9.0", than: "v1.9.0"))
        #expect(PluginUpdates.feedVersion("name: thing\nversion: \"2.0.1\"\nmin_hermes: 0.22\n") == "2.0.1")
        #expect(PluginUpdates.feedVersion("name: thing") == nil)
    }

    @Test func eachKindOfInstallIsChecked() async throws {
        // A catalog install: what Hermes says.
        let catalog = try plugin(["catalog_name": .string("thing"), "update_available": .bool(true), "catalog_version": .string("1.3.0")])
        #expect(await state(catalog, nil) == .catalog("1.3.0"))
        #expect(await state(try plugin(["catalog_name": .string("thing")]), nil) == .current)
        // From git: GitHub, from the commit installed, for its folder.
        let record = PluginInstallRecord(pinned: false, revision: "abc123", source: "https://github.com/acme/tools.git#plugins/thing")
        let asked = Asked()
        #expect(await state(try plugin([:]), record, behind: 4, asked: { asked.note("\($0)/\($1) \($2 ?? "") \($3)") }) == .commits(4))
        #expect(asked.said == ["acme/tools plugins/thing abc123"])
        #expect(await state(try plugin([:]), record, behind: 0) == .current)
        var pinned = record
        pinned.pinned = true
        #expect(await !state(try plugin([:]), pinned, behind: 4).hasUpdate, "a pinned install stays where it is")
        // An update feed.
        var fed = record
        fed.update_url = "https://example.com/thing.yml"
        #expect(await state(try plugin([:]), fed, feed: "version: 1.4.0") == .feed("1.4.0"))
        // Installed by hand: nothing to go by. Redde's own: this app's version.
        #expect(await !state(try plugin([:]), nil).hasUpdate)
        #expect(await state(try plugin(["name": .string("redde-push"), "version": .string("1.9.0")]), nil) == .redde("1.10.0"), "a 1.9.0 from before the bump is offered it")
        #expect(await state(try plugin(["name": .string("redde-push"), "version": .string("1.10.0")]), nil) == .current)
    }

    @Test func theInstallRecordsAreReadByFolder() {
        let text = #"{"thing": {"pinned": false, "revision": "abc", "source": "https://github.com/acme/tools.git"}, "other": {"source": "catalog"}}"#
        let records = PluginUpdates.records(in: text)
        #expect(records["thing"]?.revision == "abc" && records.count == 2)
        #expect(PluginUpdates.records(in: "not json").isEmpty && PluginUpdates.records(in: nil).isEmpty)
    }
}

nonisolated private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String] = []
    var said: [String] { lock.withLock { kept } }
    func note(_ line: String) { lock.withLock { kept.append(line) } }
}
