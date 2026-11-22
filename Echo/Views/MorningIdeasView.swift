import SwiftUI

/// A job on the person's Hermes that Redde sets up and finds again by its name, run once a day at
/// the time they pick: Morning Ideas, the Evening Wrap-up, the morning's heads-ups. A Hermes job
/// like any other (Cron lists it); on either connection, as scheduled jobs are.
struct DailyJob {
    var name: String
    /// What the agent is asked each day, given the page's option (a heads-up's lead, in minutes).
    var prompt: (Int) -> String
    var hour: Int
    var minute: Int
    var title: LocalizedStringResource
    var toggle: LocalizedStringResource
    var timeLabel: LocalizedStringResource = "Time"
    var footer: LocalizedStringResource
    var symbol: String
    var runNow: LocalizedStringResource
    var asked: LocalizedStringResource
    /// A choice of minutes kept in the prompt (`option(in:)` reads it back), and its picker.
    var options: [Int] = []
    var optionLabel: LocalizedStringResource = ""
    var defaultOption = 0
    /// The cron schedule's days of the week: "*" every day, "0" Sundays.
    var days = "*"
    /// Heads-ups: how the person gets about, for when to leave (`LeaveTime`).
    var travel = false
    /// What the person said of what it made, put in its prompt (`AgentFeedback`, `FeedbackFold`).
    var heard: Set<AgentFeedback.Topic> = []
    /// Hears how the person slept and moved, when they turned that on (`HealthSummary`).
    var health = false
    /// Its page offers which calendars it reads (Heads-Ups, asked 2026-11-21: "I'd like a way for
    /// heads up to be on only certain calendars"); none picked is every one the agent may read.
    var calendars = false
    /// Its page lists the ideas the person said not to suggest (Morning Ideas, plugin 1.36).
    var notSuggested = false
    /// Runs every hour, its option a number of hours (When You've Gone Quiet, plugin 1.36): no time
    /// to pick, the plugin lets a run through only once the person has been quiet that long.
    var hourly = false

    /// The prompt as set: the job's, then the calendars it reads when only some, then what the
    /// person said of earlier ones, then their day's health, if they share it.
    func fullPrompt(_ option: Int, calendars picked: [String] = []) -> String {
        let only = calendars && !picked.isEmpty ? Self.calendarsLine(picked) : nil
        let more = [only, AgentFeedback.note(for: heard), health ? HealthSummary.note() : nil].compactMap(\.self)
        return ([prompt(option)] + more).joined(separator: "\n\n")
    }

    /// Posted when Redde has turned a daily job on, off or moved it, for what shows whether it is on.
    static let changed = Notification.Name("redde.dailyJobChanged")

    /// The calendars picked on this device, by name (kept here too: a job list may send only the
    /// prompt's first line, so the job's prompt doesn't always have them).
    var pickedCalendars: [String] {
        get { UserDefaults.standard.stringArray(forKey: "dailyJob.calendars." + name) ?? [] }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "dailyJob.calendars." + name) }
    }

    /// How the prompt names the calendars to read: for the agent, and as JSON the page reads back.
    static func calendarsLine(_ names: [String]) -> String {
        let list = (try? JSONEncoder().encode(names)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "Only events in these calendars count: \(list). Give the calendar tool \"calendars\": \(list) so it reads only those."
    }

    /// The calendars a job's prompt names; nil when it names none (or was cut short of them).
    static func calendars(in prompt: String) -> [String]? {
        guard let found = prompt.firstMatch(of: /Only events in these calendars count: (\[[^\]]*\])\./),
              let names = try? JSONDecoder().decode([String].self, from: Data(found.output.1.utf8)) else { return nil }
        return names
    }

    /// How to read the calendar, for a job that does (2026-10-31: Morning Ideas and Heads-ups guessed
    /// at the tool's arguments, `end_date`, and batched calls without names until Hermes stopped them).
    static func calendarCall(_ what: String, _ arguments: String) -> String {
        "Read the calendar with one call to your calendar tool for \(what) (a list_events tool takes \(arguments)), giving " +
        "only the arguments its description lists. Call each tool on its own, never several batched in one tool_call, " +
        "and don't use manage_connections: if the calendar can't be read, go on without it."
    }

    static func time(of job: CronJob) -> (hour: Int, minute: Int)? {
        let parts = job.schedule.split(separator: " ")
        guard parts.count == 5, let minute = Int(parts[0]), let hour = Int(parts[1]) else { return nil }
        return (hour, minute)
    }

    func find() async throws -> CronJob? {
        guard let backend = CronBackend.current() else { return nil }
        return try await backend.list().first { $0.name == name }
    }

    /// `calendars`: the ones it reads, for a job that offers them; nil for those it reads now (as
    /// its prompt says, or as picked on this device), so a job set again elsewhere keeps them.
    func set(at hour: Int, _ minute: Int, option: Int, calendars picked: [String]? = nil, replacing job: CronJob?) async throws {
        let prompt = fullPrompt(option, calendars: picked ?? job.flatMap { Self.calendars(in: $0.prompt) } ?? pickedCalendars)
        guard let backend = CronBackend.current() else { throw TransportError.malformed(String(localized: "Scheduled jobs need the Hermes Dashboard or the Hermes API.")) }
        let schedule = hourly ? "\(minute) * * * *" : "\(minute) \(hour) * * \(days)"
        if let job {
            // (a Run On choice still waiting for the plugin keeps its mark)
            let named = job.askedModel.flatMap { RunOn.marked(name, $0) } ?? name
            try await backend.update(job.id, name: named, schedule: schedule, prompt: prompt, deliver: "local")
        } else {
            try await backend.create(name: name, schedule: schedule, prompt: prompt, deliver: "local")
        }
    }

    /// The option a job's prompt was made with: its opening says it ("Heads-ups, 30 minutes
    /// before."), so a list that sends only the prompt's first lines still has it.
    func option(in job: CronJob) -> Int {
        if hourly {
            guard let found = job.prompt.prefix(40).firstMatch(of: /\[redde-quiet:(\d+)h\]/), let hours = Int(found.output.1),
                  options.contains(hours) else { return defaultOption }
            return hours
        }
        guard let found = job.prompt.prefix(80).firstMatch(of: /(\d+) minutes before/), let minutes = Int(found.output.1),
              options.contains(minutes) else { return defaultOption }
        return minutes
    }
}

/// Morning Ideas: each morning the main agent looks at the day and offers what it could do, as
/// cards (`suggest_to_user`, Redde's plugin 1.9; its written-out ideas from 1.10).
enum MorningIdeas {
    static let name = "[redde] Morning ideas"
    static let prompt = """
        Morning ideas. Look at the user's day: today's calendar and reminders, anything waiting on the kanban \
        board, and what they have asked you about lately. \(DailyJob.calendarCall("today's events", #"{"date": "today", "days": 1}"#)) \
        Think of up to five things you could do for them today \
        that would save them time or that they would likely want done, the most useful first, each with a short \
        reason why now. Don't do any of them yet, and don't offer what they have already asked you to do. Write \
        them as your answer, one per line, exactly "IDEA: <title> | <why now> | <the request, as they would say it>", \
        and nothing else: Redde turns those lines into the cards. Don't call suggest_to_user for these. If nothing is \
        worth offering, answer NOTHING NEW.
        """

    static let job = DailyJob(
        name: name, prompt: { _ in prompt }, hour: 7, minute: 30, title: "Morning Ideas", toggle: "Morning Ideas",
        footer: "Each morning your agent looks at your day (your calendar, reminders, the board, what you asked it lately) and offers up to five things it could do, as cards at the top of your chats and a notification. Swipe one right to have it done, left to put it away. Nothing is done until you take one. Needs Redde's plugin 1.10 on your Hermes, and notifications from it turned on.",
        symbol: "lightbulb", runNow: "Send Ideas Now", asked: "Asked. The ideas come as a notification when your agent is done.",
        heard: [.idea], health: true, notSuggested: true)
}

/// When You've Gone Quiet (2026-11-22, after Heartbeat 2.0's "when silent 24h" wakes): once the
/// person hasn't written to any agent for so many hours, the main agent looks at what may need them
/// and says so only if something does. Runs every hour; the plugin (1.36, `silence.py`) answers
/// each run that isn't due without the model, and lets one through per quiet stretch.
enum GoneQuiet {
    static let name = "[redde-notify] When you've gone quiet"
    static func prompt(hours: Int) -> String {
        """
        [redde-quiet:\(hours)h] The user hasn't written to you for over \(hours) hours. Look at what may need them: \
        approvals and questions waiting, kanban cards waiting on them, follow-ups and reminders coming due, tomorrow's \
        calendar, and anything you were doing for them. Only if something is worth their attention now, tell them in \
        two or three short lines, the most important first. Don't ask how they are or say you noticed they were quiet. \
        If nothing is worth it, answer exactly [SILENT].
        """
    }

    static let job = DailyJob(
        name: name, prompt: { prompt(hours: $0) }, hour: 0, minute: 7, title: "When You've Gone Quiet", toggle: "When You've Gone Quiet",
        footer: "When you haven't written to any of your agents for a while, your agent looks at what may need you (approvals waiting, things coming due, tomorrow) and tells you only if something does. Once each time you go quiet. The hourly checks don't use your model. Needs Redde's plugin 1.36 on your Hermes.",
        symbol: "moon.zzz", runNow: "Send Ideas Now", asked: "Asked. The ideas come as a notification when your agent is done.",
        options: [12, 24, 48, 72], optionLabel: "After", defaultOption: 24, hourly: true)
}

/// The Evening Wrap-up (asked 2026-10-28, after Meta's Muse): what got done today, what waits on
/// the person, what carries over, as a briefing. Its name is the plugin's notify tag, so its
/// answer is what reaches the phone (`routines.py`); what carries over it may set as follow-ups
/// for the morning, which come back as idea cards.
enum EveningWrapUp {
    static let title = "Evening wrap-up"
    static let name = "[redde-notify] " + title
    static let prompt = """
        Evening wrap-up for the user. Look back at today with the tools you have: what they asked you and what got \
        done (today's conversations, the kanban board, scheduled jobs that ran), what is waiting on them (approvals, \
        blocked cards, questions you asked them), and what carries over to tomorrow. Answer in at most 120 words, in \
        three short parts headed Done, Waiting on you and Tomorrow; leave out a part with nothing in it. For anything \
        that carries over that you could help with in the morning, set a follow-up for tomorrow morning with \
        follow_up_later (find it with tool_search if it isn't among your tools). Your answer is what they read. If \
        the day had nothing in it, say so in one line.
        """

    static let job = DailyJob(
        name: name, prompt: { _ in prompt }, hour: 21, minute: 0, title: "Evening Wrap-up", toggle: "Evening Wrap-up",
        footer: "Each evening your agent sums up your day: what got done, what's waiting on you, and what carries over. It comes as a notification and stays in Briefings, at the top of your chats. What carries over it can bring back tomorrow morning as idea cards. Needs Redde's plugin 1.10 on your Hermes.",
        symbol: "moon.stars", runNow: "Send a Wrap-up Now", asked: "Asked. The wrap-up comes as a notification when your agent is done.",
        heard: [.briefing], health: true)
}

/// Heads-ups before events (asked 2026-10-28): each morning the main agent looks at the day's
/// calendar and sets a heads-up before each event worth one (`heads_up_before`, `headsup.py`),
/// which comes the chosen minutes before it starts. This job's own answer goes nowhere.
enum HeadsUps {
    static let name = "[redde] Heads-ups"
    static func prompt(minutes: Int) -> String {
        """
        Heads-ups, \(minutes) minutes before. Look at the user's calendar for the rest of today. \
        \(DailyJob.calendarCall("today's events", #"{"date": "today", "days": 1}"#)) For each event worth a heads-up (one with a \
        place, other people, or something to bring or prepare; not all-day, not already started), call \
        heads_up_before with the event's title, when it starts (ISO 8601 with its UTC offset), minutes \(minutes), \
        where (its address, when it has one), and a few words on what to check then. Don't tell the user anything now: your answer here is not sent. If \
        nothing is worth one, stop. If heads_up_before isn't among your tools, find it with tool_search first.
        """
    }

    static let job = DailyJob(
        name: name, prompt: { prompt(minutes: $0) }, hour: 6, minute: 30, title: "Heads-Ups", toggle: "Heads-Ups Before Events",
        timeLabel: "Plan the Day At",
        footer: "Each morning your agent looks at the day's calendar and, before each event that needs it, sends you a heads-up: where it is, who's coming, what to bring, the weather if it's outdoors. They come as notifications and stay in Briefings. Events added later in the day are picked up the next time it plans. Needs Redde's plugin 1.10 on your Hermes and a calendar your agent can read.",
        symbol: "bell.badge", runNow: "Plan Today Now", asked: "Asked. Heads-ups come before each event.",
        options: [10, 15, 30, 45, 60], optionLabel: "How Long Before", defaultOption: 45, travel: true, heard: [.headsUp],
        calendars: true)
}

/// "Make this a routine?" (asked 2026-10-28, "Proactive"): once a week the main agent looks for
/// what the person asks again and again, on a rhythm, and offers each as an idea card; taken, the
/// card's request has the agent set it up as a scheduled job that notifies.
enum RoutineSuggestions {
    static let name = "[redde] Routine suggestions"
    static let prompt = """
        Routine suggestions. Look over the user's conversations from the last two weeks (search them with your session \
        search tool) for things they asked you more than once on a rhythm: each morning, before a run, on Mondays, after \
        work. For up to three that aren't scheduled already (look at your scheduled jobs), offer each as a line of your \
        answer: the title saying what and when ("Weather before your run, weekdays 6:30"), why saying how often \
        they asked ("You asked on four mornings"), and the request: "Make this a routine: <what to do>, <when>. Set it up \
        as a scheduled job with cronjob_manage, its name starting [redde-notify] and delivered local, so its answer \
        reaches my iPhone." Write each exactly "IDEA: <title> | <why> | <the request>", one per line and nothing else: \
        Redde turns those lines into the cards. Don't call suggest_to_user for these, and don't set anything up now. If \
        nothing repeats, answer NOTHING NEW and stop.
        """

    static let job = DailyJob(
        name: name, prompt: { _ in prompt }, hour: 17, minute: 0, title: "Routine Suggestions", toggle: "Routine Suggestions",
        timeLabel: "Sundays At",
        footer: "Once a week your agent looks for things you ask it again and again (the weather before a run, the board on Mondays) and offers each as an idea card. Take one and it becomes a routine that runs by itself and tells you. Needs Redde's plugin 1.10 on your Hermes.",
        symbol: "repeat", runNow: "Look Now", asked: "Asked. Suggestions come as idea cards when your agent is done.", days: "0",
        heard: [.idea])
}

/// The week ahead (asked 2026-10-28, "Proactive"): on Sunday evening, the coming week as a briefing.
enum WeekAhead {
    static let title = "Week ahead"
    static let name = "[redde-notify] " + title
    static let prompt = """
        Week ahead for the user. Look at the coming week with the tools you have: their calendar for the seven days from \
        tomorrow, reminders and tasks coming due, kanban cards waiting on them, and anything they said they would do. \
        \(DailyJob.calendarCall("the seven days from tomorrow", #"{"date": "tomorrow", "days": 7}"#)) \
        Your answer is what they read, drawn by Redde as a calendar, so write it in exactly this shape. First one line \
        on the week as a whole. Then, for each day with something on it, a line "## <weekday>, <month> <day>" \
        ("## Friday, Oct 30") and under it one line per thing, "- <start time> <what>" ("- 11:30 AM Planning \
        session") or "- <what>" for something all day or due that day, a few words each; a day's own note \
        ("Payday", "Jackie is off") on a line starting "> ". Leave out empty days and the routine blocks they have \
        every day. Last, for what is due or to get ready for (a trip, a deadline, a dinner), a line or two starting \
        "Get ready: ". At most 40 lines in all. If the week is empty, say so in one line.
        """

    static let job = DailyJob(
        name: name, prompt: { _ in prompt }, hour: 18, minute: 0, title: "Week Ahead", toggle: "Week Ahead",
        timeLabel: "Sundays At",
        footer: "Each Sunday evening your agent looks at the week to come (your calendar, what's due, what's waiting on you) and sends you a short briefing. It stays in Briefings, at the top of your chats. Needs Redde's plugin 1.10 on your Hermes.",
        symbol: "calendar", runNow: "Send It Now", asked: "Asked. The week ahead comes as a notification when your agent is done.", days: "0",
        heard: [.briefing], health: true)
}

/// Settings → Your Day → Morning Ideas, Evening Wrap-up, Heads-Ups, Routine Suggestions, Week Ahead.
struct DailyJobView: View {
    let daily: DailyJob
    @State private var job: CronJob?
    @State private var loaded = false
    @State private var on = false
    @State private var time = Date.now
    @State private var option = 0
    @State private var working = false
    @State private var problem: String?
    @State private var sent = false
    /// The calendars it reads, for a job that offers them; empty for all.
    @State private var picked: [String] = []
    /// Saving the calendars picked, a moment after the last tap (one change to the job, not one a tap).
    @State private var savingCalendars: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { on }, set: { new in on = new; Task { await apply() } })) {
                    Label { Text(daily.toggle) } icon: { Image(systemName: daily.symbol) }
                }
                .disabled(!loaded || working)
                if on {
                    if !daily.hourly {
                        DatePicker(selection: $time, displayedComponents: .hourAndMinute) { Text(daily.timeLabel) }
                            .onChange(of: time) { Task { await apply() } }
                            .disabled(working)
                    }
                    if !daily.options.isEmpty {
                        Picker(selection: $option) {
                            ForEach(daily.options, id: \.self) { n in
                                if daily.hourly {
                                    Text("\(n) hours", comment: "A number of hours: how long you've been quiet before the job runs").tag(n)
                                } else {
                                    Text("\(n) min", comment: "A number of minutes").tag(n)
                                }
                            }
                        } label: { Text(daily.optionLabel) }
                        .onChange(of: option) { Task { await apply() } }
                        .disabled(working)
                    }
                    // (a run now would find them about, and the plugin keep it quiet)
                    if !daily.hourly {
                        Button { Task { await runNow() } } label: { Label { Text(daily.runNow) } icon: { Image(systemName: "play") } }
                            .disabled(working || job == nil)
                    }
                }
            } footer: {
                Text(daily.footer)
            }
            if daily.calendars, on {
                Section {
                    NavigationLink {
                        JobCalendarsView(picked: Binding(get: { picked }, set: { picked = $0; saveCalendarsSoon() }))
                    } label: {
                        LabeledContent {
                            Text(picked.isEmpty ? String(localized: "All", comment: "Heads-Ups: reads every calendar") : picked.joined(separator: ", "))
                                .lineLimit(1)
                        } label: {
                            Label { Text("Calendars", comment: "Heads-Ups: which calendars it reads") } icon: { Image(systemName: "calendar") }
                        }
                    }
                    .disabled(working)
                } footer: {
                    Text("Heads-ups come only for events in these calendars.", comment: "Heads-Ups: under Calendars")
                }
            }
            // Which model it runs on (Run On, 2026-11-03).
            if on, let job {
                RunOnSection(job: job) { self.job = try? await daily.find() }
            }
            if daily.travel, on {
                Section {
                    Picker("Getting There", selection: Binding(get: { LeaveTime.mode() }, set: {
                        LeaveTime.setMode($0)
                        LeaveByAlerts.shared.wayChanged()
                    })) {
                        Text("By Car").tag(LeaveTime.Mode.driving)
                        Text("By Transit").tag(LeaveTime.Mode.transit)
                        Text("On Foot").tag(LeaveTime.Mode.walking)
                        Text("Don't Work It Out").tag(LeaveTime.Mode.off)
                    }
                } footer: {
                    Text("When an event has an address, your iPhone works out when to leave from where you are, with traffic, adds it to the heads-up and reminds you when it's time. Where you are stays on your iPhone. Needs Location for Redde.")
                }
            }
            // Leave-By Alerts, worked out on this device whether heads-ups are on or not; their own
            // Getting There while the one above isn't there.
            if daily.travel {
                LeaveByAlertsSection(showsWay: !on)
            }
            if sent {
                Section { Label { Text(daily.asked) } icon: { Image(systemName: "checkmark.circle") } }
            }
            if daily.notSuggested { NotSuggestedSection() }
            // How the last run went: a refusal or an error shows here, not only in the job's output.
            if let job, let ran = job.lastRunAt {
                Section("Last run") {
                    LabeledContent("When") { Text(ran, format: .dateTime.weekday().hour().minute()) }
                    if job.lastStatus == "error" || job.state == .error {
                        Text(job.lastError ?? String(localized: "It didn't finish."))
                            .font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            if let problem {
                Section { Text(problem).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle(Text(daily.title))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        time = Calendar.current.date(bySettingHour: daily.hour, minute: daily.minute, second: 0, of: .now) ?? .now
        option = daily.defaultOption
        do {
            job = try await daily.find()
            on = job != nil
            if let job {
                if let (hour, minute) = DailyJob.time(of: job),
                   let at = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) { time = at }
                if !daily.options.isEmpty { option = daily.option(in: job) }
            }
            // As the job's prompt names them; one cut short in the list, as picked here.
            if daily.calendars {
                picked = job.flatMap { DailyJob.calendars(in: $0.prompt) }
                    ?? (job.map { $0.prompt.count > 300 } == true ? [] : daily.pickedCalendars)
            }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        // Loading set the pickers: what they set off isn't a change of the person's.
        try? await Task.sleep(for: .milliseconds(50))
        loaded = true
    }

    private func apply() async {
        guard loaded else { return }
        working = true
        defer { working = false }
        do {
            if on {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                if daily.calendars { daily.pickedCalendars = picked }
                try await daily.set(at: parts.hour ?? daily.hour, parts.minute ?? daily.minute, option: option,
                                    calendars: daily.calendars ? picked : nil, replacing: job)
            } else if let job {
                try await CronBackend.current()?.delete(job.id)
            }
            job = try await daily.find()
            problem = nil
        } catch {
            problem = error.localizedDescription
            on = job != nil
        }
        NotificationCenter.default.post(name: DailyJob.changed, object: nil)
    }

    private func saveCalendarsSoon() {
        savingCalendars?.cancel()
        savingCalendars = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await apply()
        }
    }

    private func runNow() async {
        guard let job else { return }
        working = true
        sent = true
        defer { working = false }
        do {
            try await CronBackend.current()?.runNow(job.id)
            self.job = try await daily.find()
        } catch { problem = error.localizedDescription }
    }
}

/// Settings › Your Day › Heads-Ups › Calendars: the calendars a daily job reads, by name (asked
/// 2026-11-21). Offered are this device's calendars by account, as Calendar lists them, less those
/// the agent may not read (Settings › Calendars); none picked is all of them.
struct JobCalendarsView: View {
    @Binding var picked: [String]
    @State private var accounts: [CalendarsSettingsView.Account] = []
    @State private var allowed = true

    var body: some View {
        Form {
            Section {
                Button { picked = [] } label: {
                    LabeledContent {
                        if picked.isEmpty { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    } label: {
                        Text("All Calendars", comment: "Heads-Ups › Calendars: every calendar the agent may read")
                    }
                }
                .foregroundStyle(.primary)
            } footer: {
                Text("Or pick the ones heads-ups are for: only their events get one.", comment: "Heads-Ups › Calendars: under All Calendars")
            }
            ForEach(accounts) { account in
                Section(account.title) {
                    ForEach(account.calendars) { calendar in
                        Button { toggle(calendar.title) } label: {
                            LabeledContent {
                                if picked.contains(where: { $0.caseInsensitiveCompare(calendar.title) == .orderedSame }) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            } label: {
                                Label { Text(verbatim: calendar.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(calendar.color) }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            if !allowed {
                Section {
                    Text("Redde can't see this device's calendars. Allow it in Settings › Calendars.",
                         comment: "Heads-Ups › Calendars: no calendar access")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(Text("Calendars", comment: "Heads-Ups › Calendars: title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    private func toggle(_ title: String) {
        if let i = picked.firstIndex(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) {
            picked.remove(at: i)
        } else {
            picked.append(title)
        }
    }

    private func load() async {
        allowed = await CalendarReader.shared.allowed(.event)
        guard allowed else { return }
        let chosen = CalendarChoice.chosen
        accounts = await CalendarReader.shared.read { store in CalendarsSettingsView.deviceAccounts(in: store) }
            .map { account in
                var account = account
                account.calendars = account.calendars.filter { CalendarChoice.shows($0.title, among: chosen) }
                return account
            }
            .filter { !$0.calendars.isEmpty }
    }
}

