import SwiftUI

/// Hermes's skills hub for a profile (`HubSkill`): the official catalog that ships with Hermes,
/// the hub's featured picks, and a search across its sources (skills.sh, GitHub, ClawHub…); each
/// skill looked at, checked by Hermes's own security scan, then installed or removed on the
/// server. `profile` nil: the one Redde is on; a bot's from Edit Bot → Skills. Asked 2026-11-16:
/// "browse and install skills from hub". Dashboard only: the Hermes API has no hub.
struct SkillsHubView: View {
    let profile: String?
    /// Whose they are, in words ("Sol", "Home").
    let owner: String
    /// Something was installed or removed: the skills lists read again.
    var changed: () -> Void = {}

    @State private var overview = HubOverview()
    @State private var official: [HubSkill] = []
    @State private var officialInstalled: [String: Bool] = [:]
    @State private var loading = true
    @State private var problem: String?
    @State private var query = ""
    @State private var found: [HubSkill]?
    @State private var searching = false
    @State private var timedOut: [String] = []
    private let client = HermesServeClient.shared

    var body: some View {
        List {
            if !client.hasCredentials {
                ContentUnavailableView("Needs the Hermes Dashboard", systemImage: "square.grid.3x3.square",
                                       description: Text("Skills are installed from the hub through the Hermes Dashboard: add its address and login in Settings. The Hermes API has no way to."))
            } else {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
                if !words.isEmpty { searchResults }
                if words.isEmpty, !overview.featured.isEmpty {
                    Section("Featured") { ForEach(overview.featured) { link($0) } }
                }
                if loading, official.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(officialByCategory, id: \.category) { group in
                    Section {
                        ForEach(group.skills) { link($0) }
                    } header: {
                        Label("\(group.category.capitalized) · \(group.skills.count)", systemImage: ItemIcon.symbol(skillCategory: group.category))
                    }
                }
                if words.isEmpty, !loading {
                    Section {
                    } footer: {
                        Text("Official skills come with Hermes. Search also looks in the hub's other sources\(sourceList), where anyone can publish: Hermes checks each skill before it installs it, and refuses one its check finds risky.")
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search the hub")
        .onSubmit(of: .search) { Task { await search() } }
        .task(id: words) {
            // A search across the sources once typing pauses (the server's takes seconds).
            guard !words.isEmpty else { found = nil; timedOut = []; return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await search()
        }
        .navigationTitle("Skills Hub")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private var words: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var sourceList: String {
        let names = overview.sources.map(\.label).filter { $0 != "Official" && !$0.isEmpty }
        return names.isEmpty ? "" : " (\(names.formatted(.list(type: .and))))"
    }

    @ViewBuilder
    private var searchResults: some View {
        Section {
            if searching, found == nil {
                HStack { ProgressView(); Text("Searching the hub…").foregroundStyle(.secondary) }
            } else if let found, found.isEmpty {
                Text("Nothing on the hub for “\(words)”.").foregroundStyle(.secondary)
            }
            ForEach(found ?? []) { link($0) }
        } header: {
            HStack {
                Text("On the Hub")
                if searching, found != nil { ProgressView().controlSize(.mini) }
            }
        } footer: {
            if !timedOut.isEmpty {
                Text("Didn't answer in time: \(timedOut.formatted(.list(type: .and))).")
            }
        }
    }

    /// The official catalog, narrowed by what's typed.
    private var officialByCategory: [(category: String, skills: [HubSkill])] {
        let needle = words.lowercased()
        let shown = official.filter {
            needle.isEmpty || $0.name.lowercased().contains(needle) || $0.description.lowercased().contains(needle)
                || $0.tags.contains { $0.lowercased().contains(needle) }
        }
        let grouped = Dictionary(grouping: shown) { $0.category ?? "general" }
        return grouped.keys.sorted().compactMap { key in grouped[key].map { (key, $0.sorted { $0.name < $1.name }) } }
    }

    private func installedName(_ skill: HubSkill) -> String? {
        if officialInstalled[skill.identifier] == true { return overview.installed[skill.identifier] ?? skill.name }
        return skill.installedName(in: overview.installed)
    }

    private func link(_ skill: HubSkill) -> some View {
        let installed = installedName(skill)
        return NavigationLink {
            HubSkillView(skill: skill, profile: profile, owner: owner, installedName: installed) {
                Task { await load() }
                changed()
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.name)
                    HubTrustBadge(trust: skill.trust)
                    if installed != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Installed")
                    }
                }
                if !skill.description.isEmpty {
                    Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if skill.source != "official", !skill.source.isEmpty {
                    Text(HubSkillView.sourceName(skill.source, overview: overview)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func load() async {
        guard client.hasCredentials else { loading = false; return }
        loading = true
        defer { loading = false }
        async let catalog = client.hubOfficial(profile: profile)
        async let hub = client.hubOverview(profile: profile)
        do {
            let read = try await catalog
            official = read.skills
            officialInstalled = read.installed
            problem = nil
        } catch { problem = error.localizedDescription }
        // The featured list needs the Hermes index online; the catalog stands without it.
        if let read = try? await hub { overview = read }
    }

    private func search() async {
        let asked = words
        guard !asked.isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            let result = try await client.hubSearch(asked, profile: profile)
            guard asked == words else { return }
            // The official ones already show below, from the catalog.
            let listed = Set(official.map(\.identifier))
            found = result.skills.filter { $0.source != "official" || !listed.contains($0.identifier) }
            timedOut = result.timedOut
            overview.installed.merge(result.installed) { _, new in new }
        } catch {
            guard asked == words else { return }
            found = []
            problem = String(localized: "The hub search failed: \(error.localizedDescription)")
        }
    }
}

/// How far Hermes trusts a skill's source, as a small mark.
struct HubTrustBadge: View {
    let trust: String

    var body: some View {
        switch trust {
        case "builtin":
            Text("Official").font(.caption2.weight(.semibold)).foregroundStyle(.tint)
        case "trusted":
            Text("Trusted").font(.caption2.weight(.semibold)).foregroundStyle(.green)
        default:
            Text("Community").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
        }
    }
}

/// One hub skill: what it says it does, its SKILL.md and files, Hermes's security check of it,
/// and the button that installs or removes it.
struct HubSkillView: View {
    let skill: HubSkill
    let profile: String?
    let owner: String
    let installedName: String?
    let changed: () -> Void

    @State private var preview: HubPreview?
    @State private var scan: HubScan?
    @State private var scanProblem: String?
    @State private var working = false
    @State private var outcome: String?
    @State private var failed = false
    @State private var installedNow: String??
    @State private var confirmRemove = false
    private let client = HermesServeClient.shared

    private var installed: String? { installedNow ?? installedName }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(skill.name).font(.title3.weight(.semibold)); HubTrustBadge(trust: skill.trust) }
                    if !skill.description.isEmpty { Text(skill.description).font(.subheadline) }
                    if !skill.tags.isEmpty {
                        Text(skill.tags.map { "#\($0)" }.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Source", value: Self.sourceName(skill.source, overview: nil))
                if let repo = skill.repo, let url = URL(string: repo.hasPrefix("http") ? repo : "https://github.com/\(repo)") {
                    Link(destination: url) { LabeledContent("Repository", value: repo) }
                }
            }
            Section {
                if installed != nil {
                    Button(role: .destructive) { confirmRemove = true } label: {
                        Label(working ? "Removing…" : "Remove from \(owner)", systemImage: "trash")
                    }
                    .disabled(working)
                } else {
                    Button { Task { await install() } } label: {
                        Label(working ? "Installing…" : "Install for \(owner)", systemImage: "arrow.down.circle")
                    }
                    .disabled(working || scan?.installs == false)
                }
                if let outcome {
                    Text(outcome).font(.footnote).foregroundStyle(failed ? .orange : .green)
                }
            } footer: {
                if installed != nil {
                    Text("Installed for \(owner). New chats can use it; an ongoing chat once it starts fresh.")
                } else if scan?.installs == false {
                    Text("Hermes won't install this skill: its check found something it calls risky.")
                } else {
                    Text("Hermes installs it on your server for \(owner) alone; each bot has its own skills.")
                }
            }
            safety
            if let preview {
                if !preview.skillMarkdown.isEmpty {
                    Section("SKILL.md") {
                        NavigationLink {
                            ScrollView {
                                Text(preview.skillMarkdown).font(.footnote.monospaced()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding()
                            }
                            .navigationTitle("SKILL.md").navigationBarTitleDisplayMode(.inline)
                        } label: {
                            Text(preview.skillMarkdown.prefix(600)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(8)
                        }
                    }
                }
                if preview.files.count > 1 {
                    Section("Files · \(preview.files.count)") {
                        ForEach(preview.files, id: \.self) { Text($0).font(.caption.monospaced()) }
                    }
                }
            }
        }
        .navigationTitle(skill.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove \(skill.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await remove() } }
        } message: {
            Text("\(owner) stops having it. You can install it again from the hub.")
        }
        .task {
            async let look = try? client.hubPreview(skill.identifier, profile: profile)
            if installed == nil { await check() }
            preview = await look
        }
    }

    /// Hermes's install-time check, run before anything is installed.
    @ViewBuilder
    private var safety: some View {
        if installed == nil {
            Section {
                if let scan {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.verdict(scan))
                            if !scan.summary.isEmpty { Text(scan.summary).font(.caption).foregroundStyle(.secondary) }
                        }
                    } icon: {
                        Image(systemName: scan.installs ? (scan.findings.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill") : "xmark.shield.fill")
                            .foregroundStyle(scan.installs ? (scan.findings.isEmpty ? .green : .orange) : .red)
                    }
                    ForEach(scan.findings.prefix(20)) { finding in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(finding.severity.capitalized) · \(finding.category)").font(.caption.weight(.semibold))
                                .foregroundStyle(HubScan.rank(finding.severity) >= 2 ? .red : .orange)
                            Text(finding.description).font(.caption)
                            Text(finding.line.map { "\(finding.file):\($0)" } ?? finding.file).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                } else if let scanProblem {
                    Label(scanProblem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                } else {
                    HStack { ProgressView(); Text("Checking…").foregroundStyle(.secondary) }
                }
            } header: {
                Text("Safety Check")
            } footer: {
                Text("Hermes's own scan of the skill's files, the one it runs before every install.")
            }
        }
    }

    static func verdict(_ scan: HubScan) -> String {
        if !scan.installs { return String(localized: "Blocked", comment: "A hub skill Hermes's scan won't install") }
        if scan.findings.isEmpty { return String(localized: "Nothing found", comment: "A hub skill Hermes's scan found nothing in") }
        return String(localized: "Findings: \(scan.findings.count)", comment: "A hub skill's scan: how many things it found that don't stop the install")
    }

    static func sourceName(_ id: String, overview: HubOverview?) -> String {
        if let label = overview?.sources.first(where: { $0.id == id })?.label { return label }
        switch id {
        case "official": return String(localized: "Official (comes with Hermes)")
        case "skills-sh": return "skills.sh"
        case "github": return "GitHub"
        case "clawhub": return "ClawHub"
        case "lobehub": return "LobeHub"
        case "hermes-index": return String(localized: "Hermes index")
        default: return id
        }
    }

    private func check() async {
        do { scan = try await client.hubScan(skill.identifier, profile: profile) }
        catch { scanProblem = String(localized: "Couldn't check it: \(error.localizedDescription)") }
    }

    private func install() async {
        working = true
        defer { working = false }
        do {
            let action = try await client.hubInstall(skill.identifier, profile: profile)
            let done = try await client.hubFinish(action)
            // Installed or not is the hub's own list, not what the run printed.
            let now = try await client.hubOverview(profile: profile)
            let official = skill.source == "official" ? (try? await client.hubOfficial(profile: profile))?.installed[skill.identifier] == true : false
            if let name = skill.installedName(in: now.installed) ?? (official ? skill.name : nil) {
                installedNow = .some(name)
                failed = false
                outcome = String(localized: "Installed.")
                changed()
            } else {
                failed = true
                outcome = Self.why(done) ?? String(localized: "Hermes didn't install it.")
            }
        } catch {
            failed = true
            outcome = error.localizedDescription
        }
    }

    private func remove() async {
        guard let name = installed else { return }
        working = true
        defer { working = false }
        do {
            let done = try await client.hubFinish(try await client.hubUninstall(name: name, profile: profile))
            if done.exitCode ?? 0 == 0 {
                installedNow = .some(nil)
                failed = false
                outcome = String(localized: "Removed.")
                changed()
                if scan == nil { await check() }
            } else {
                failed = true
                outcome = Self.why(done) ?? String(localized: "Hermes didn't remove it.")
            }
        } catch {
            failed = true
            outcome = error.localizedDescription
        }
    }

    /// The lines of Hermes's run that say why it stopped: from "Not installed:" or an error on.
    nonisolated static func why(_ action: GatewayAction) -> String? {
        let lines = action.lines
        if let start = lines.firstIndex(where: { $0.localizedCaseInsensitiveContains("not installed") || $0.localizedCaseInsensitiveContains("error") }) {
            return lines[start...].prefix(4).joined(separator: "\n")
        }
        return lines.suffix(3).joined(separator: "\n").nilIfEmpty
    }
}
