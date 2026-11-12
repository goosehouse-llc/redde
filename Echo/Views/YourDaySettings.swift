import SwiftUI

/// Settings → Your Day (2.4 tidy, asked 2026-11-05: "make the UX cleaner and easier to use with all
/// this new functionality"): what the agent does on its own through the day, which had grown to
/// fifteen rows of Settings → Agent. The daily jobs are one row (`DailyJobsView`), Coming Up and
/// Agent Activity one (they were the same screen on two tabs), and Places, Current Location and
/// Leave-By Alerts one page (`LocationSettingsView`).
struct YourDaySettings: View {
    /// An API key or a Dashboard login is stored: the jobs, goals and watches are on the server.
    let canReachGateway: Bool
    @State private var settings = Settings.shared

    var body: some View {
        Section {
            AheadOfYourDayRow()
            NavigationLink { GoalsListView() } label: {
                Label { Text("Goals", comment: "The chat list's section of the person's goals, and its page in Settings") } icon: { Image(systemName: "flag.checkered") }
            }
            .disabled(!canReachGateway)
            NavigationLink { AgentActivityView(tab: .comingUp) } label: {
                Label { Text("Activity", comment: "Settings › Your Day: what the agents will do next and what they did (Agent Activity)") } icon: { Image(systemName: "list.bullet.rectangle") }
            }
        } footer: {
            Text("Ahead of Your Day turns the day's helpers on in one step. Activity shows what your agents will do next, and what they did.",
                 comment: "Settings › Your Day: under Ahead of Your Day, Goals and Activity")
        }

        Section {
            NavigationLink { DailyJobsView() } label: {
                Label { Text("Daily Jobs", comment: "Settings › Your Day: Morning Ideas, Heads-Ups, the Evening Wrap-up, the Week Ahead and Routine Suggestions") } icon: { Image(systemName: "clock") }
            }
            .disabled(!canReachGateway)
            NavigationLink { BriefingsList() } label: { Label("Briefings", systemImage: "doc.text") }
            Toggle(isOn: $settings.briefingTapsOpenRun) {
                Label { Text("Briefing Taps Open the Run", comment: "Settings › Your Day: a briefing's notification opens the scheduled run's chat, not the briefing") } icon: { Image(systemName: "bubble.left.and.text.bubble.right") }
            }
        } header: {
            Text("Every Day", comment: "Settings › Your Day: the section of the daily jobs")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ideas each morning, a heads-up before events, a wrap-up each evening, the week ahead on Sundays. What they send stays in Briefings, at the top of your chats.",
                     comment: "Settings › Your Day › Every Day: footer")
                Text("With Briefing Taps Open the Run on, a briefing's notification opens the chat its run was in, to ask on there. The main agent's briefings, with Redde's plugin 1.21.1 or later.",
                     comment: "Settings › Your Day › Every Day: footer, about Briefing Taps Open the Run")
            }
        }

        Section {
            NavigationLink { WatchesView() } label: { Label("Watches & Follow-ups", systemImage: "eye") }
                .disabled(!canReachGateway)
            NavigationLink { TriggersView() } label: { Label("Triggers from Your iPhone", systemImage: "bolt.badge.clock") }
            NavigationLink { LocationSettingsView() } label: {
                Label { Text("Location", comment: "Settings › Your Day: Places, Current Location and Leave-By Alerts") } icon: { Image(systemName: "location") }
            }
            #if os(iOS)
            if HealthDays.available {
                NavigationLink { HealthDaysView() } label: { Label("Health", systemImage: "heart.text.square") }
            }
            #endif
        } header: {
            Text("Keeping Watch", comment: "Settings › Your Day: watches, triggers, location and health")
        } footer: {
            Text("Things your agent keeps an eye on and tells you only when they change, loose ends it brings back when they're due, and work it starts from your iPhone: arriving home, a time of day, a Focus.",
                 comment: "Settings › Your Day › Keeping Watch: footer")
        }

        Section {
            NavigationLink { BeforeActingView() } label: { Label("Before Acting", systemImage: "hand.raised") }
            NavigationLink { ApprovalHistoryView() } label: { Label("Approval History", systemImage: "checkmark.shield") }
        } header: {
            Text("Asking First", comment: "Settings › Your Day: Before Acting and Approval History")
        } footer: {
            Text("How much each agent may do without asking you, and every time it asked: what it was, why, and what you answered. The history is kept on this device only.",
                 comment: "Settings › Your Day › Asking First: footer")
        }
    }
}

/// Settings → Your Day → Daily Jobs: the five daily jobs in one list, each with whether it is on and
/// when it runs, read from the server's jobs; a row opens the job's own page (`DailyJobView`).
struct DailyJobsView: View {
    static let jobs: [DailyJob] = [MorningIdeas.job, HeadsUps.job, EveningWrapUp.job, WeekAhead.job, RoutineSuggestions.job]

    /// The server's jobs by name; nil until read (or when they can't be).
    @State private var found: [String: CronJob]?
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                ForEach(Self.jobs, id: \.name) { daily in
                    NavigationLink { DailyJobView(daily: daily) } label: {
                        LabeledContent {
                            if let found { status(found[daily.name], daily: daily) }
                        } label: {
                            Label { Text(daily.title) } icon: { Image(systemName: daily.symbol) }
                        }
                    }
                }
            } footer: {
                Text("Each runs on your Hermes at the time you pick and sends what it made as a notification. Open one to turn it on or off, change its time, or run it now.",
                     comment: "Settings › Your Day › Daily Jobs: footer")
            }
            if let problem {
                Section { Text(problem).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle(Text("Daily Jobs", comment: "Settings › Your Day › Daily Jobs: title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Again on coming back from a job's page, where it may have been turned on or moved.
        .onAppear { Task { await load() } }
        .refreshable { await load() }
    }

    /// "7:30 AM", "Sun 6:00 PM", or Off.
    private func status(_ job: CronJob?, daily: DailyJob) -> Text {
        guard let job else { return Text("Off") }
        guard let (hour, minute) = DailyJob.time(of: job),
              let at = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) else { return Text("On") }
        let time = at.formatted(date: .omitted, time: .shortened)
        let days = job.schedule.split(separator: " ").last.map(String.init) ?? daily.days
        if days == "0" {
            return Text("Sundays, \(time)", comment: "Settings › Daily Jobs: a weekly job's time, e.g. Sundays, 6:00 PM")
        }
        return Text(verbatim: time)
    }

    private func load() async {
        do {
            // One look at the server's jobs for all five.
            guard let backend = CronBackend.current() else { return }
            let names = Set(Self.jobs.map(\.name))
            found = Dictionary(try await backend.list().filter { names.contains($0.name) }.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Settings → Your Day → Location: the places the iPhone notices, the agent hearing roughly where
/// you are, and when to leave for events, which were three places on Settings → Agent.
struct LocationSettingsView: View {
    var body: some View {
        Form {
            #if os(iOS)
            Section {
                NavigationLink { PlacesView() } label: {
                    Label(String(localized: "places.title", defaultValue: "Places", comment: "Settings: places the iPhone notices arriving at or leaving"), systemImage: "mappin.and.ellipse")
                }
            } footer: {
                Text("Home, Work, the gym: arriving or leaving tells the agent you choose, with what you wrote for it.",
                     comment: "Settings › Your Day › Location: under Places")
            }
            #endif
            CurrentLocationSection()
            LeaveByAlertsSection()
        }
        .navigationTitle(Text("Location", comment: "Settings › Your Day › Location: title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
