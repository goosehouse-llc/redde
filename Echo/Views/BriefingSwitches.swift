import SwiftUI

/// Settings › Your Day: every briefing switched on and off where it's seen (asked 2026-11-20: "turning
/// briefings on/off is not clear in Your Day settings"). The five daily ones were a page away, each
/// behind its own page; a job of the person's own was stopped only from a card's hold menu.
/// Here: the daily ones as switches with their time under them, the times and options a tap away
/// (`DailyJobsView`), and every other job that sends briefings with how its runs reach the person
/// (Notify Me, Drawer Only, Off: `JobNotices`).
struct BriefingSwitches: View {
    /// An API key or a Dashboard login is stored: the jobs are on the server.
    let canReachGateway: Bool
    /// The server's daily jobs by name; nil until read.
    @State private var found: [String: CronJob]?
    @State private var working: Set<String> = []
    @State private var problem: String?
    @State private var inbox = BriefingsInbox.shared
    /// Bumped when a job's choice changes, for its row to read it again.
    @State private var changed = 0

    var body: some View {
        Section {
            ForEach(DailyJobsView.jobs, id: \.name) { daily in
                Toggle(isOn: Binding(get: { found?[daily.name] != nil }, set: { on in Task { await set(daily, on: on) } })) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(daily.title)
                            if let job = found?[daily.name] {
                                DailyJobsView.status(job, daily: daily).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: { Image(systemName: daily.symbol) }
                }
                .disabled((!canReachGateway && !Self.demo) || found == nil || working.contains(daily.name))
            }
            NavigationLink { DailyJobsView() } label: {
                Label { Text("Times & Options", comment: "Settings › Your Day: the daily briefings' times, options and Run Now") } icon: { Image(systemName: "clock") }
            }
            .disabled(!canReachGateway)
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Briefings", comment: "The chat list's deck of briefings")
        } footer: {
            Text("Ideas each morning, a heads-up before events, a wrap-up each evening, the week ahead on Sundays. Each runs on your Hermes and comes as a notification; it also stays at the top of your chats.",
                 comment: "Settings › Your Day › Briefings: footer")
        }
        .task { await load() }

        let others = otherJobs
        if !others.isEmpty {
            Section {
                ForEach(others, id: \.key) { job in
                    let _ = changed
                    Picker(selection: Binding(get: { JobNotices.choice(for: job.key) }, set: {
                        inbox.setNotice($0, jobKey: job.key, title: job.title)
                        changed += 1
                    })) {
                        Text("Notify Me").tag(JobNotices.Choice.notify)
                        Text("Drawer Only").tag(JobNotices.Choice.drawerOnly)
                        Text("Off").tag(JobNotices.Choice.hidden)
                    } label: {
                        Text(verbatim: job.title)
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("From Your Other Jobs", comment: "Settings › Your Day: jobs of the person's own that send briefings, each with how its runs reach them")
            } footer: {
                Text("Jobs you or your agents set up that send briefings. Drawer Only keeps them at the top of your chats with no notification; Off stops them coming.",
                     comment: "Settings › Your Day › From Your Other Jobs: footer")
            }
        }
    }

    /// `-echo.demoBriefings` (Debug): sample daily jobs, switched here without a server, for screenshots.
    static var demo: Bool {
        #if DEBUG
        DevHooks.has("-echo.demoBriefings")
        #else
        false
        #endif
    }

    static func demoJob(_ daily: DailyJob) -> CronJob? {
        CronJob(.object(["id": .string("demo-" + daily.name), "name": .string(daily.name),
                         "schedule": .string("\(daily.minute) \(daily.hour) * * \(daily.days)")]))
    }

    /// Every job that has sent a briefing, but the five daily ones, newest first, and the ones turned
    /// off (their runs are gone) by the name kept for them.
    private var otherJobs: [(key: String, title: String)] {
        let _ = changed
        let daily = Set((found ?? [:]).values.map { "default|" + $0.id })
        var seen = Set<String>()
        var out: [(key: String, title: String)] = []
        for briefing in (AgentBriefing.all() + inbox.briefings).sorted(by: { $0.at > $1.at })
        where !daily.contains(briefing.jobKey) && !MailBriefPage.isMail(briefing) && seen.insert(briefing.jobKey).inserted {
            out.append((briefing.jobKey, briefing.heading))
        }
        for (key, entry) in JobNotices.hidden().sorted(by: { $0.value.title < $1.value.title })
        where !daily.contains(key) && seen.insert(key).inserted {
            out.append((key, entry.title.isEmpty ? key : entry.title))
        }
        return out
    }

    private func load() async {
        #if DEBUG
        if Self.demo {
            if found == nil {
                found = Dictionary(uniqueKeysWithValues: DailyJobsView.jobs.prefix(4).enumerated().filter { $0.offset != 2 }.compactMap { _, daily in
                    Self.demoJob(daily).map { (daily.name, $0) }
                })
            }
            return
        }
        #endif
        guard canReachGateway, let backend = CronBackend.current() else { return }
        do {
            let names = Set(DailyJobsView.jobs.map(\.name))
            found = Dictionary(try await backend.list().filter { names.contains($0.name) }.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// On at its usual time (or the one it had), off by removing the job, as its own page does.
    private func set(_ daily: DailyJob, on: Bool) async {
        #if DEBUG
        if Self.demo {
            found?[daily.name] = on ? Self.demoJob(daily) : nil
            return
        }
        #endif
        working.insert(daily.name)
        defer { working.remove(daily.name) }
        do {
            if on {
                try await daily.set(at: daily.hour, daily.minute, option: daily.defaultOption, replacing: nil)
            } else if let job = found?[daily.name] {
                try await CronBackend.current()?.delete(job.id)
            }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        await load()
        NotificationCenter.default.post(name: DailyJob.changed, object: nil)
    }
}
