import SwiftUI

/// Settings → Agent → Agent Activity (asked 2026-10-28, after Meta's Muse, which keeps a record of
/// what it did): what your agents did on their own, the last week of it, newest first. Hermes says
/// what its scheduled jobs ran (every run, on the Dashboard; each job's last, over the Hermes API)
/// and what the board's workers finished or got stuck on; this phone adds what reached it (ideas
/// offered, a watch's change, a briefing, a call: `AgentActivityNote`), and a run's answer where it
/// has one. A watch that looked and found nothing is one line a day, not one a look.
nonisolated struct ActivityEntry: Identifiable, Equatable, Sendable {
    enum Source: String, Equatable, Sendable { case job, watch, brief, ideas, call, finished, blocked }
    var id: String
    var source: Source
    /// The agent's profile ("default", the main one).
    var profile: String
    var title: String
    var detail: String
    var at: Date
    var failed = false

    var symbol: String {
        switch source {
        case .job: "clock"
        case .watch: "eye"
        case .brief: "doc.text"
        case .ideas: "lightbulb"
        case .call: "phone"
        case .finished: "checkmark.rectangle"
        case .blocked: "exclamationmark.octagon"
        }
    }
}

nonisolated enum AgentActivity {
    static let window: TimeInterval = 7 * 86_400

    /// A job's name as the person knows it, and what kind of job it is.
    static func describe(_ name: String) -> (title: String, source: ActivityEntry.Source) {
        if name.hasPrefix("[redde-watch:") || name.hasPrefix("[redde-followup:") {
            let title = name.firstIndex(of: "]").map { name[name.index(after: $0)...].trimmingCharacters(in: .whitespaces) } ?? name
            return (title, name.hasPrefix("[redde-watch:") ? .watch : .job)
        }
        for tag in ["[redde-notify] ", "[redde] "] where name.hasPrefix(tag) {
            return (String(name.dropFirst(tag.count)), tag == "[redde-notify] " ? .brief : .job)
        }
        return (BotRoutines.untagged(name), .job)
    }

    /// Everything, newest first: `runs` by job id (the Dashboard's history; empty over the Hermes
    /// API, where a job's last run stands for it).
    static func merge(jobs: [CronJob], runs: [String: [Date]], tasks: [KanbanTask], notes: [AgentActivityNote],
                      now: Date = .now, calendar: Calendar = .current) -> [ActivityEntry] {
        let since = now.addingTimeInterval(-window)
        var entries: [ActivityEntry] = []
        // What reached the phone of a job's run, by its title: the answer, where the run has none.
        var told = notes.filter { [.routine, .brief, .watch].contains($0.kind) }
        func note(for title: String, near at: Date) -> AgentActivityNote? {
            guard let i = told.firstIndex(where: { $0.title == title && abs($0.at.timeIntervalSince(at)) < 600 }) else { return nil }
            return told.remove(at: i)
        }
        for job in jobs {
            let (title, source) = describe(job.name)
            let profile = job.profile ?? "default"
            let times = (runs[job.id] ?? job.lastRunAt.map { [$0] } ?? []).filter { $0 >= since && $0 <= now.addingTimeInterval(60) }
                .sorted(by: >)
            var quiet: [String: (count: Int, at: Date)] = [:]   // a watch's looks that found nothing, by day
            for (i, at) in times.enumerated() {
                let failed = i == 0 && (job.lastStatus == "error" || job.state == .error)
                if let said = note(for: title, near: at) {
                    entries.append(ActivityEntry(id: "\(job.id)/\(Int(at.timeIntervalSince1970))", source: source, profile: profile,
                                                 title: title, detail: said.detail, at: at, failed: failed || said.failed))
                } else if source == .watch, !failed {
                    let day = calendar.startOfDay(for: at).timeIntervalSince1970.description
                    let before = quiet[day]
                    quiet[day] = ((before?.count ?? 0) + 1, max(before?.at ?? at, at))
                } else {
                    entries.append(ActivityEntry(id: "\(job.id)/\(Int(at.timeIntervalSince1970))", source: source, profile: profile, title: title,
                                                 detail: failed ? (job.lastError ?? String(localized: "It didn't finish.")) : "",
                                                 at: at, failed: failed))
                }
            }
            for (day, looks) in quiet {
                entries.append(ActivityEntry(id: "\(job.id)/quiet/\(day)", source: .watch, profile: profile, title: title,
                                             detail: String(localized: "Looked \(looks.count) times: nothing new"), at: looks.at))
            }
        }
        // What only the phone knows: ideas, calls, and notes no listed job accounts for.
        for left in told + notes.filter({ [.ideas, .call].contains($0.kind) }) where left.at >= since {
            let source: ActivityEntry.Source = switch left.kind {
            case .ideas: .ideas
            case .call: .call
            case .watch: .watch
            case .brief: .brief
            case .routine: .job
            }
            entries.append(ActivityEntry(id: "note/" + left.id, source: source, profile: left.profile, title: left.title,
                                         detail: left.detail, at: left.at, failed: left.failed))
        }
        // The board's workers.
        for task in tasks {
            if let done = task.completedAt, done >= since, ["done", "review"].contains(task.status) {
                entries.append(ActivityEntry(id: "task/\(task.id)/done", source: .finished, profile: task.assignee ?? "default",
                                             title: task.title, detail: task.latestSummary ?? task.result ?? "", at: done))
            } else if task.status == "blocked", let why = task.lastFailure, let at = task.startedAt ?? task.createdAt, at >= since {
                entries.append(ActivityEntry(id: "task/\(task.id)/blocked", source: .blocked, profile: task.assignee ?? "default",
                                             title: task.title, detail: why, at: at, failed: true))
            }
        }
        return entries.sorted { $0.at > $1.at }
    }
}

struct AgentActivityView: View {
    @State private var entries: [ActivityEntry] = []
    @State private var loading = true
    @State private var problem: String?
    @State private var open: Set<String> = []
    @State private var settings = Settings.shared

    private var days: [(day: Date, entries: [ActivityEntry])] {
        let calendar = Calendar.current
        return Dictionary(grouping: entries) { calendar.startOfDay(for: $0.at) }
            .map { ($0.key, $0.value) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        List {
            if loading, entries.isEmpty {
                HStack(spacing: 10) { ProgressView(); Text("Reading…").foregroundStyle(.secondary) }
            } else if entries.isEmpty {
                Text("Nothing in the last week. What your agents do on their own comes here: scheduled jobs, watches, briefings, ideas they offered, calls, and cards the board's workers finished.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
            ForEach(days, id: \.day) { day in
                Section {
                    ForEach(day.entries) { row($0) }
                } header: {
                    Text(heading(day.day)).textCase(nil)
                }
            }
            Section {
            } footer: {
                Text("Hermes keeps what its scheduled jobs ran and what the board's workers did; this iPhone keeps what reached it. Over the Hermes API, each job shows only its last run.")
            }
        }
        .navigationTitle("Agent Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The whole week as text, to paste into a chat or a note (asked 2026-10-30).
            ToolbarItem(placement: .primaryAction) {
                Button("Copy All", systemImage: "doc.on.doc") { UIPasteboard.general.string = everything }
                    .disabled(entries.isEmpty)
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func row(_ entry: ActivityEntry) -> some View {
        Button {
            if open.contains(entry.id) { open.remove(entry.id) } else { open.insert(entry.id) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: entry.symbol)
                    .foregroundStyle(entry.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.title).lineLimit(2)
                        Spacer(minLength: 6)
                        Text(entry.at, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text(name(entry.profile)).font(.caption).foregroundStyle(.secondary)
                    if !entry.detail.isEmpty {
                        Text(PlainText.display(entry.detail)).font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(open.contains(entry.id) ? nil : 2)
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Held (on the Mac, the right click): one entry, whole, its answer not cut short.
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text(entry) }
        }
    }

    /// One entry as text: its time, agent and title, then what it said.
    private func text(_ entry: ActivityEntry) -> String {
        let line = "\(entry.at.formatted(.dateTime.hour().minute())) · \(name(entry.profile)) · \(entry.title)"
        let detail = PlainText.display(entry.detail).trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? line : line + "\n" + detail
    }

    /// Every entry, by day as the screen has them.
    private var everything: String {
        days.map { day in
            ([heading(day.day)] + day.entries.map(text)).joined(separator: "\n\n")
        }
        .joined(separator: "\n\n\n")
    }

    private func heading(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }

    private func name(_ profile: String) -> String {
        if profile == "default" || profile == settings.profileName { return settings.headerTitle }
        return BotDirectory.shared.roster?.named(profile)?.label(mainName: settings.headerTitle) ?? profile
    }

    private func load() async {
        loading = true
        defer { loading = false }
        #if DEBUG
        if DemoDay.on { entries = DemoDay.activity; return }   // the day's video's
        #endif
        let notes = AgentActivityNote.all()
        var jobs: [CronJob] = [], runs: [String: [Date]] = [:], tasks: [KanbanTask] = []
        var failed: [String] = []
        if let backend = CronBackend.current() {
            do {
                jobs = try await backend.list()
                if backend.supportsRunHistory {
                    let since = Date.now.addingTimeInterval(-AgentActivity.window)
                    let recent = jobs.filter { ($0.lastRunAt ?? .distantPast) >= since }.prefix(30)
                    runs = await withTaskGroup(of: (String, [Date]).self) { group in
                        for job in recent {
                            group.addTask {
                                let history = (try? await backend.runs(job.id, limit: 50, profile: job.profile)) ?? []
                                return (job.id, history.compactMap(\.startedAt))
                            }
                        }
                        var all: [String: [Date]] = [:]
                        for await (id, dates) in group where !dates.isEmpty { all[id] = dates }
                        return all
                    }
                }
            } catch {
                failed.append(String(localized: "Couldn't read the scheduled jobs: \(error.localizedDescription)"))
            }
        }
        if KanbanClient.isAvailable, let board = try? await KanbanClient.board() {
            tasks = board.columns.flatMap(\.tasks)
        }
        entries = AgentActivity.merge(jobs: jobs, runs: runs, tasks: tasks, notes: notes)
        problem = failed.first
    }
}
