import SwiftUI
import UserNotifications

/// What Coming Up reads and does (`ComingUp`): the server's jobs once, this device's Leave-By
/// Alerts, and Skip, Pause and Resume. Read when the tab appears and when pulled; nothing polls.
@MainActor
@Observable
final class ComingUpModel {
    private(set) var items: [ComingUp.Item] = []
    private(set) var loading = true
    /// Something went wrong reading or doing.
    var problem: String?
    /// Something to say that isn't a failure: a skip that needs the plugin's update.
    var notice: String?
    /// The item an action is under way for.
    private(set) var working: String?
    /// Coming Up's day, or Planned's week with what the agent set on this device (`PhoneMade`).
    var span: TimeInterval = ComingUp.window
    var withPhone = false

    /// When each skip mark was set, by job (its profile and id), so one nothing takes up is taken off
    /// again (`ComingUp.markUnheard`).
    private static let marksKey = "comingUp.marks"
    private var marks: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: Self.marksKey) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.marksKey) }
    }

    static let needsPlugin = String(localized: "Skipping one run of a repeating job needs the Redde plugin 1.15 on your Hermes. Update it in Settings → Redde Plugin, or pause the job instead.",
                                    comment: "Coming Up: Skip on a server whose Redde plugin is older than 1.15")

    func load() async {
        loading = true
        defer { loading = false }
        #if DEBUG
        if DevHooks.has("-echo.demoComingUp") || DevHooks.has("-echo.demoPlanned") {
            items = ComingUpDemo.items(now: .now, planned: withPhone); return
        }
        #endif
        var jobs: [CronJob] = []
        if let backend = CronBackend.current() {
            do {
                jobs = try await backend.list()
                problem = nil
            } catch {
                problem = String(localized: "Couldn't read the scheduled jobs: \(error.localizedDescription)")
            }
            jobs = await takeUnheardMarks(off: jobs, backend: backend)
        }
        let leave = LeaveBy.isOn ? LeaveBy.worked() : [:]
        let now = Date.now
        let phone = withPhone ? await PhoneMade.read(now: now, within: span) : []
        items = ComingUp.plan(jobs: jobs, leave: leave, skippedLeave: LeaveTime.skipped(), now: now, within: span, phone: phone)
    }

    /// Marks set a while ago that are still there: no plugin took them up. Taken off, and said why.
    private func takeUnheardMarks(off jobs: [CronJob], backend: CronBackend) async -> [CronJob] {
        var jobs = jobs
        var marks = self.marks
        let now = Date.now
        for i in jobs.indices where jobs[i].skipping != nil {
            let key = Self.key(jobs[i])
            guard ComingUp.markUnheard(jobs[i], asked: marks[key].map { Date(timeIntervalSince1970: $0) }, now: now) else { continue }
            if (try? await backend.unmarkSkip(jobs[i])) != nil {
                jobs[i].skipping = nil
                if marks[key] != nil { notice = Self.needsPlugin }
                marks[key] = nil
            }
        }
        // Marks the plugin took up (gone from the names) are forgotten.
        let marked = Set(jobs.filter { $0.skipping != nil }.map(Self.key))
        for key in marks.keys where !marked.contains(key) { marks[key] = nil }
        self.marks = marks
        return jobs
    }

    private static func key(_ job: CronJob) -> String { (job.profile ?? "") + "/" + job.id }

    // MARK: Doing

    /// Skip for a Leave-By Alert or a repeating job (a one-off is `cancel`, after the page asks).
    func skip(_ item: ComingUp.Item) async {
        working = item.id
        defer { working = nil }
        notice = nil
        if let alert = item.alertID {
            await LeaveByAlerts.shared.skip(alert)
            await load()
            return
        }
        guard let job = item.job, let backend = CronBackend.current() else { return }
        let run = item.at
        if case .serve = backend {
            // The plugin's command does it at once (1.15); an older plugin doesn't know it.
            let command = PushService.command(over: .shared)
            do {
                let answer = try await command("skip \(job.profile ?? "default") \(job.id) \(Int(run.timeIntervalSince1970))")
                if ComingUp.pluginSkipped(answer) { await load(); return }
                if let state = try? await HermesServeClient.shared.pushPlugin(), let version = state.version,
                   PushPlugin.isOlder(version, than: "1.15.0") {
                    notice = Self.needsPlugin
                    return
                }
            } catch PushError.noPlugin {
                notice = Self.needsPlugin
                return
            } catch {
                // The command couldn't be said: the mark, which the plugin reads from the jobs.
            }
        }
        do {
            try await backend.markSkip(job, run: run)
            marks[Self.key(job)] = Date.now.timeIntervalSince1970
            await load()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// A Leave-By Alert's skip taken back.
    func unskip(_ item: ComingUp.Item) async {
        guard let alert = item.alertID else { return }
        working = item.id
        defer { working = nil }
        await LeaveByAlerts.shared.skip(alert, false)
        await load()
    }

    /// A job that runs once, taken off.
    func cancel(_ item: ComingUp.Item) async {
        guard let job = item.job else { return }
        working = item.id
        defer { working = nil }
        do {
            try await CronBackend.current()?.delete(job.id, profile: job.profile)
            await load()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// An alarm or timer Redde set, cancelled; a reminder the agent added, done. Both on this device.
    func finish(_ item: ComingUp.Item) async {
        guard let id = item.phoneID else { return }
        working = item.id
        defer { working = nil }
        do {
            switch item.kind {
            #if os(iOS)
            case .alarm, .timer: _ = try await DeviceAlarms().cancel(.object(["id": .string(id)]))
            #endif
            case .reminder:
                _ = try await DeviceCalendar.completeReminder(.object(["id": .string(id)]))
                PhoneMade.forget([id])
            default: return
            }
            await load()
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func setPaused(_ item: ComingUp.Item, _ paused: Bool) async {
        guard let job = item.job else { return }
        working = item.id
        defer { working = nil }
        do {
            try await CronBackend.current()?.setPaused(job.id, paused, profile: job.profile)
            await load()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Agent Activity's Coming Up tab: the next day, soonest first, then what is paused. With
/// `planned`, the drawer's Planned tab (2026-11-03): the week, with what the agent set on this
/// device (alarms, timers, reminders, events) and the full list of scheduled jobs at the end.
struct ComingUpList: View {
    var planned = false
    /// The drawer's server and section switch, scrolling with the list (Planned).
    var topRow: AnyView?
    /// The iPhone's panel is out: it stays built while closed, so this is when to read again.
    var isShowing = true
    @State private var model = ComingUpModel()
    @Environment(\.openURL) private var openURL
    @State private var settings = Settings.shared
    /// A one-off to cancel, or a run too near to skip, waiting on the person's word.
    @State private var asking: ComingUp.Item?

    private var upcoming: [ComingUp.Item] { model.items.filter { !$0.paused } }
    private var paused: [ComingUp.Item] { model.items.filter(\.paused) }

    private var days: [(day: Date, items: [ComingUp.Item])] { ComingUp.byDay(upcoming, now: .now) }

    var body: some View {
        List {
            if let topRow { topRow }
            if model.loading, model.items.isEmpty {
                HStack(spacing: 10) { ProgressView(); Text("Reading…").foregroundStyle(.secondary) }
            } else if upcoming.isEmpty {
                if planned {
                    Text("Nothing planned for the next 7 days. What your agents will do comes here: heads-ups, leave times, routines, watches, follow-ups, goal check-ins, and the alarms, reminders and events they set on this device.",
                         comment: "Planned, when nothing is planned")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Nothing planned for the next 24 hours. What your agents will do on their own comes here: heads-ups, leave times, routines, watches, follow-ups and daily jobs.",
                         comment: "Coming Up, when nothing is planned")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let notice = model.notice {
                Label(notice, systemImage: "info.circle").font(.footnote).foregroundStyle(.orange)
            }
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
            ForEach(days, id: \.day) { day in
                Section {
                    ForEach(day.items) { row($0) }
                } header: {
                    Text(heading(day.day)).textCase(nil)
                }
            }
            if !paused.isEmpty {
                Section {
                    ForEach(paused) { row($0) }
                } header: {
                    Text("Paused", comment: "Coming Up: the section of paused jobs").textCase(nil)
                }
            }
            if planned {
                Section {
                    // Every job on the server, as the Cron tab had them.
                    NavigationLink { CronView().navigationTitle(String(localized: "Scheduled Jobs", comment: "Planned: the page of every scheduled job (cron jobs)")) } label: {
                        Label(String(localized: "All Scheduled Jobs", comment: "Planned: opens the full list of scheduled jobs"), systemImage: "clock")
                    }
                }
            }
            Section {
            } footer: {
                Text("Skip passes over one run; Pause stops a job until you resume it. Skipping a run of a repeating job needs the Redde plugin 1.15 on your Hermes. Leave-By Alerts are skipped on this device.",
                     comment: "Coming Up: the footer")
            }
        }
        .refreshable { await model.load() }
        .task {
            if planned { model.span = ComingUp.week; model.withPhone = true }
            await model.load()
        }
        .onChange(of: isShowing) { _, showing in if showing { Task { await model.load() } } }
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            titleVisibility: .visible, presenting: asking) { item in
            if ComingUp.skipWay(item, now: .now) == .cancel {
                Button(String(localized: "Skip It", comment: "Coming Up: confirming Skip on a job that runs once (it is cancelled)"), role: .destructive) {
                    Task { await model.cancel(item) }
                }
            } else {
                Button(String(localized: "Pause", comment: "Coming Up: a run too near to skip; pause the job instead")) {
                    Task { await model.setPaused(item, true) }
                }
            }
        } message: { item in
            if ComingUp.skipWay(item, now: .now) == .cancel {
                Text("It runs only once, so skipping it cancels it.", comment: "Coming Up: confirming Skip on a job that runs once")
            } else {
                Text("It runs in a moment, too soon to skip just this run. Pause it, and resume it here when you want it back.",
                     comment: "Coming Up: a run less than two minutes away")
            }
        }
    }

    private var dialogTitle: String {
        guard let asking else { return "" }
        return ComingUp.skipWay(asking, now: .now) == .cancel
            ? String(localized: "Skip \(asking.title)?", comment: "Coming Up: confirming Skip on a job that runs once, by its title")
            : String(localized: "\(asking.title) runs in a moment", comment: "Coming Up: a run too near to skip, by its title")
    }

    private func row(_ item: ComingUp.Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind == .leaveBy ? leaveSymbol : item.kind.symbol)
                .foregroundStyle(item.paused || item.skipped || item.skipping ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title(item)).lineLimit(2)
                        .strikethrough(item.skipped || item.skipping, color: .secondary)
                    Spacer(minLength: 6)
                    if model.working == item.id {
                        ProgressView().controlSize(.small)
                    } else if !item.paused, !item.untimed {
                        Text(item.at, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if let line = subtitle(item) { Text(line).font(.caption).foregroundStyle(.secondary) }
                if let detail = item.detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                if let state = state(item) { Text(state).font(.caption.weight(.medium)).foregroundStyle(.orange) }
            }
        }
        .contentShape(.rect)
        .onTapGesture { if item.kind == .event { open(item) } }
        .swipeActions(edge: .trailing) { actions(item, swipe: true) }
        .contextMenu { actions(item, swipe: false) }
        .accessibilityElement(children: .combine)
        .accessibilityActions { actions(item, swipe: false) }
    }

    @ViewBuilder private func actions(_ item: ComingUp.Item, swipe: Bool) -> some View {
        if item.phoneID != nil {
            switch item.kind {
            case .alarm, .timer:
                Button(String(localized: "Cancel", comment: "Planned: cancels an alarm or timer Redde set"), systemImage: "xmark", role: .destructive) {
                    Task { await model.finish(item) }
                }
            case .reminder:
                Button(String(localized: "Done", comment: "Planned: marks a reminder the agent added as done"), systemImage: "checkmark") {
                    Task { await model.finish(item) }
                }
                .tint(.green)
            case .event:
                Button(String(localized: "Open in Calendar", comment: "Planned: opens an event the agent added"), systemImage: "calendar") { open(item) }
            default:
                EmptyView()
            }
        } else if item.paused {
            Button("Resume", systemImage: "play") { Task { await model.setPaused(item, false) } }.tint(.green)
        } else if item.skipped {
            Button(String(localized: "Don't Skip", comment: "Coming Up: takes back a skipped Leave-By Alert"), systemImage: "arrow.uturn.backward") {
                Task { await model.unskip(item) }
            }
        } else {
            switch ComingUp.skipWay(item, now: .now) {
            case .leave, .mark:
                Button(String(localized: "Skip", comment: "Coming Up: pass over this one run"), systemImage: "forward") { Task { await model.skip(item) } }
                    .tint(.orange)
            case .cancel, .pauseInstead:
                Button(String(localized: "Skip", comment: "Coming Up: pass over this one run"), systemImage: "forward") { asking = item }
                    .tint(.orange)
            case .none:
                EmptyView()
            }
            if item.job != nil {
                Button("Pause", systemImage: "pause") { Task { await model.setPaused(item, true) } }
                    .tint(.gray)
            }
        }
    }

    private var leaveSymbol: String {
        switch LeaveTime.mode() {
        case .transit: "tram"
        case .walking: "figure.walk"
        default: "car"
        }
    }

    /// An event the agent added, in the Calendar app, at its day.
    private func open(_ item: ComingUp.Item) {
        if let url = URL(string: "calshow:\(Int(item.at.timeIntervalSinceReferenceDate))") { openURL(url) }
    }

    private func title(_ item: ComingUp.Item) -> String {
        item.kind == .leaveBy ? String(localized: "Leave for \(item.title)", comment: "Coming Up: a Leave-By Alert, by its event's title") : item.title
    }

    /// Who does it and how often: "Sol · Every 15 minutes", "Heads-up", "This iPhone".
    private func subtitle(_ item: ComingUp.Item) -> String? {
        let who = item.profile.map(name) ?? String(localized: "On this device", comment: "Coming Up: a Leave-By Alert is worked out on the device")
        let what: String? = switch item.kind {
        case .alarm: String(localized: "Alarm", comment: "Planned: an alarm the agent set on this device")
        case .timer: String(localized: "Timer", comment: "Planned: a timer the agent set on this device")
        case .reminder: [String(localized: "Reminder", comment: "Planned: a reminder the agent added"), item.cadence].compactMap(\.self).joined(separator: ", ")
        case .event: String(localized: "Event", comment: "Planned: a calendar event the agent added")
        case .headsUp: String(localized: "Heads-up", comment: "Coming Up: a heads-up before an event")
        case .followUp: String(localized: "Follow-up", comment: "Coming Up: a follow-up the agent set")
        case .goal: String(localized: "Goal check-in", comment: "Coming Up: a goal's scheduled check-in")
        case .watch: item.cadence.map { String(localized: "Watch, \($0.lowercased())", comment: "Coming Up: a watch and how often it looks, e.g. Watch, every 15 minutes") }
            ?? String(localized: "Watch", comment: "Coming Up: a watch")
        default: item.cadence
        }
        return ([who] + [what].compactMap(\.self)).joined(separator: " · ")
    }

    private func state(_ item: ComingUp.Item) -> String? {
        if item.skipped { return String(localized: "Skipped", comment: "Coming Up: a Leave-By Alert skipped on this device") }
        if item.skipping { return String(localized: "Skipping this run", comment: "Coming Up: a repeating job whose next run will be passed over") }
        return nil
    }

    private func heading(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInTomorrow(day) { return String(localized: "Tomorrow") }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }

    private func name(_ profile: String) -> String {
        if profile == "default" || profile == settings.profileName { return settings.headerTitle }
        return BotDirectory.shared.roster?.named(profile)?.label(mainName: settings.headerTitle) ?? profile
    }
}

#if DEBUG
/// `-echo.demoComingUp`: a made-up day for the pictures, around now.
enum ComingUpDemo {
    static func items(now: Date, planned: Bool = false) -> [ComingUp.Item] {
        func job(_ id: String, _ name: String, _ schedule: String, in minutes: Double, profile: String? = nil,
                 enabled: Bool = true, times: Int? = nil) -> CronJob {
            var fields: [String: JSONValue] = ["id": .string(id), "name": .string(name), "schedule": .string(schedule),
                                               "enabled": .bool(enabled), "next_run_at": .number(now.addingTimeInterval(minutes * 60).timeIntervalSince1970)]
            if let profile { fields["profile"] = .string(profile) }
            if let times { fields["repeat"] = .object(["times": .number(Double(times)), "completed": .number(0)]) }
            return CronJob(.object(fields))!
        }
        let jobs = [
            job("w1", "[redde-watch:kettle01] The price of the blue kettle", "*/30 * * * *", in: 12),
            job("h1", "[redde-notify] Heads-up: Dentist", "once at 2:15 PM", in: 95, times: 1),
            job("f1", "[redde-followup:plumb001] Call the plumber about the quote", "once", in: 300, times: 1),
            job("r1", "[redde-notify] What to wear for the weather", "0 7 * * 1-5", in: 60 * 15),
            job("d1", "[redde] Morning ideas", "30 7 * * *", in: 60 * 15.5),
            job("g1", "[redde-goal:10k] Run a 10K by March", "0 9 * * 1", in: 60 * 17),
            job("w2", "[redde-watch:nas00001] The NAS's free space", "0 */4 * * *", in: 150, profile: "ops"),
            job("d2", "[redde-notify] Evening wrap-up", "0 21 * * *", in: 60 * 9),
            job("p1", "[redde-watch:school01] Messages from the school", "*/15 * * * *", in: 5, enabled: false),
        ]
        let start = now.addingTimeInterval(4 * 3600)
        let worked = LeaveBy.Worked(title: "Lunch with Ana", start: start, place: "1 Main St", mode: .driving,
                                    fromLatitude: 0, fromLongitude: 0, toLatitude: 0, toLongitude: 0, travel: 25 * 60, at: now,
                                    alertAt: LeaveTime.leave(for: start, travel: 25 * 60, mode: .driving))
        guard planned else { return ComingUp.plan(jobs: jobs, leave: ["redde.leave.event.demo.1": worked], now: now) }
        let tomorrow = Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
        let records = [PhoneMade.Record(kind: .reminder, id: "r1", title: "Call the vet", at: now.addingTimeInterval(3 * 3600), added: now),
                       PhoneMade.Record(kind: .reminder, id: "r2", title: "Pack the swim bag", at: nil, added: now),
                       PhoneMade.Record(kind: .event, id: "e1", title: "Dinner with Ana and Jo", at: tomorrow.addingTimeInterval(19.5 * 3600), added: now)]
        let live = Dictionary(uniqueKeysWithValues: records.map { ($0.id, PhoneMade.Now(title: $0.title, at: $0.at)) })
        let alarms = [PhoneMade.Alarm(id: "a1", title: "Wake up", rings: tomorrow.addingTimeInterval(6.75 * 3600), timer: false),
                      PhoneMade.Alarm(id: "a2", title: "Pasta", rings: now.addingTimeInterval(11 * 60), timer: true)]
        let phone = PhoneMade.items(alarms: alarms, records: records, live: live, now: now, within: ComingUp.week).items
        return ComingUp.plan(jobs: jobs, leave: ["redde.leave.event.demo.1": worked], now: now, within: ComingUp.week, phone: phone)
    }
}
#endif
