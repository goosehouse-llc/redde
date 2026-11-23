import SwiftUI

/// Settings → Your Day (2.4 tidy, asked 2026-11-05: "make the UX cleaner and easier to use with all
/// this new functionality"): what the agent does on its own through the day, which had grown to
/// fifteen rows of Settings → Agent. The daily jobs are one row (`DailyJobsView`), Coming Up and
/// Agent Activity one (they were the same screen on two tabs), and Places, Current Location and
/// Leave-By Alerts one page (`LocationSettingsView`, on the first screen since 2026-11-15).
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

        BriefingSwitches(canReachGateway: canReachGateway)

        Section {
            NavigationLink { BriefingsList() } label: {
                Label { Text("Past Briefings", comment: "Settings › Your Day: the list of every briefing kept, and the hidden jobs") } icon: { Image(systemName: "doc.text") }
            }
            Toggle(isOn: $settings.briefingTapsOpenRun) {
                Label { Text("Briefing Taps Open the Run", comment: "Settings › Your Day: a briefing's notification opens the scheduled run's chat, not the briefing") } icon: { Image(systemName: "bubble.left.and.text.bubble.right") }
            }
        } footer: {
            Text("With Briefing Taps Open the Run on, a briefing's notification opens the chat its run was in, to ask on there. The main agent's briefings, with Redde's plugin 1.21.1 or later.",
                 comment: "Settings › Your Day › Every Day: footer, about Briefing Taps Open the Run")
        }

        Section {
            NavigationLink { WatchesView() } label: { Label("Watches & Follow-ups", systemImage: "eye") }
                .disabled(!canReachGateway)
            NavigationLink { TriggersView() } label: { Label("Triggers from Your iPhone", systemImage: "bolt.badge.clock") }
            NavigationLink { KeepInMindView() } label: {
                Label { Text("Things to Keep in Mind", comment: "Settings › Your Day: facts about the person that Heads-Ups and Morning Ideas check") } icon: { Image(systemName: "pin") }
            }
            .disabled(!canReachGateway)
            NavigationLink { FollowThroughView() } label: {
                Label { Text("Follow-Through", comment: "Settings › Your Day: what the agent follows up on from mail and watch lists") } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
            }
            .disabled(!canReachGateway)
            .accessibilityIdentifier("follow-through")
            // Location: a page of the first screen since 2026-11-15 (`LocationSettingsView`).
            #if os(iOS)
            if HealthDays.available {
                NavigationLink { HealthDaysView() } label: { Label("Health", systemImage: "heart.text.square") }
            }
            #endif
        } header: {
            Text("Keeping Watch", comment: "Settings › Your Day: watches, triggers and health")
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
    static let jobs: [DailyJob] = [MorningIdeas.job, HeadsUps.job, EveningWrapUp.job, WeekAhead.job, RoutineSuggestions.job, GoneQuiet.job]

    /// The server's jobs by name; nil until read (or when they can't be).
    @State private var found: [String: CronJob]?
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                ForEach(Self.jobs, id: \.name) { daily in
                    NavigationLink { DailyJobView(daily: daily) } label: {
                        LabeledContent {
                            if let found { Self.status(found[daily.name], daily: daily) }
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
    static func status(_ job: CronJob?, daily: DailyJob) -> Text {
        guard let job else { return Text("Off") }
        if daily.hourly {
            return Text("After \(daily.option(in: job)) hours", comment: "Settings › Daily Jobs: When You've Gone Quiet's wait, e.g. After 24 hours")
        }
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

/// Settings → Location: the places the iPhone notices, the agent hearing roughly where you are, and
/// when to leave for events, which were three places on Settings → Agent, then a page of Your Day
/// (until 2026-11-15).
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
                     comment: "Settings › Location: under Places")
            }
            #endif
            CurrentLocationSection()
            LeaveByAlertsSection()
        }
        .navigationTitle(Text("Location", comment: "Settings › Location: title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}


/// Things to keep in mind (plugin 1.36, `facts.py`; 2026-11-22, after "whenever I drive across the
/// border I need 3-day car insurance"): what is always true for the person, kept on their Hermes
/// for every agent. Heads-Ups, Morning Ideas and the Week Ahead check each one against the days
/// around every event, and say when something is missing or runs out. The agent adds them too, when
/// the person tells it one (`redde_fact`).
enum KeptFacts {
    @MainActor
    static func list() async -> [String]? {
        guard let reply = try? await PushService.command(over: .shared)("facts list") else { return nil }
        return parse(reply)
    }

    static func parse(_ reply: String) -> [String]? {
        let prefix = "redde-push facts "
        let rest = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rest.hasPrefix(prefix), let data = PushSeal.data(base64URL: String(rest.dropFirst(prefix.count))) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    static func line(_ verb: String, _ text: String) -> String {
        "facts \(verb) \(PushSeal.base64URL(Data(text.utf8)))"
    }

    /// Nil when it was done; else why not.
    @MainActor
    static func change(_ verb: String, _ text: String) async -> String? {
        guard let raw = try? await PushService.command(over: .shared)(line(verb, text)) else {
            return String(localized: "Couldn't reach your Hermes. Try again in a moment.", comment: "A goal's step couldn't be ticked: the server didn't answer")
        }
        let reply = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if reply == "redde-push facts added" || reply == "redde-push facts removed" { return nil }
        if reply.hasPrefix("redde-push facts refused ") { return String(reply.dropFirst("redde-push facts refused ".count)) }
        return String(localized: "Things to Keep in Mind takes the Redde plugin 1.36: update it in Settings › Redde Plugin.", comment: "Things to Keep in Mind: the plugin is too old")
    }
}

struct KeepInMindView: View {
    @State private var facts: [String]?
    @State private var draft = ""
    @State private var working = false
    @State private var problem: String?
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                ForEach(facts ?? [], id: \.self) { Text($0) }
                    .onDelete { rows in
                        for text in rows.compactMap({ facts?[$0] }) { remove(text) }
                    }
                HStack {
                    TextField(String(localized: "Driving into France, I need 3-day car insurance", comment: "Things to Keep in Mind: the example in the empty field"),
                              text: $draft, axis: .vertical)
                        .onSubmit(add)
                        .accessibilityIdentifier("keep-in-mind-field")
                    Button(action: add) { Image(systemName: "plus.circle.fill") }
                        .disabled(working || draft.trimmingCharacters(in: .whitespacesAndNewlines).count < 4)
                        .accessibilityLabel(Text("Add", comment: "Things to Keep in Mind: adds the fact typed"))
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What's always true for you, said once. Heads-Ups, Morning Ideas and the Week Ahead check each one against the days around every event, and tell you when something is missing or runs out: a policy that ends before you're back, a booking you haven't made. Your agents add to this list when you tell them something like it. Kept on your Hermes, for all your agents.",
                         comment: "Things to Keep in Mind: footer")
                    if loaded, facts == nil {
                        Text("Your Hermes can't say. Things to Keep in Mind takes the Redde plugin 1.36.", comment: "Things to Keep in Mind: the list couldn't be read")
                    }
                    if let problem { Text(problem).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle(Text("Things to Keep in Mind", comment: "Settings › Your Day: facts about the person that Heads-Ups and Morning Ideas check"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        facts = await KeptFacts.list()
        loaded = true
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 4, !working else { return }
        working = true
        problem = nil
        Task {
            defer { working = false }
            if let why = await KeptFacts.change("add", text) { problem = why; return }
            draft = ""
            await load()
        }
    }

    private func remove(_ text: String) {
        facts?.removeAll { $0 == text }
        problem = nil
        Task {
            if let why = await KeptFacts.change("remove", text) { problem = why }
            await load()
        }
    }
}
