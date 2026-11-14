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

    static let needsPlugin = String(localized: "Skipping one run of a repeating job needs the Redde plugin 1.16 on your Hermes. Update it in Settings → Redde Plugin, or pause the job instead.",
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
                   PushPlugin.isOlder(version, than: "1.16.0") {
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

    /// A job run now, from its details.
    func runNow(_ job: CronJob) async {
        do {
            try await CronBackend.current()?.runNow(job.id, profile: job.profile)
            await load()
        } catch {
            problem = error.localizedDescription
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
    /// The iPhone's panel is out: it stays built while closed, so this is when to read again.
    var isShowing = true
    @State private var model = ComingUpModel()
    @Environment(\.openURL) private var openURL
    @State private var settings = Settings.shared
    /// A one-off to cancel, or a run too near to skip, waiting on the person's word.
    @State private var asking: ComingUp.Item?
    /// A job's full details (its sheet), and one being edited from them.
    @State private var details: CronJob?
    @State private var editing: CronJob?
    /// A job whose time is being changed (Change Time, 2026-11-11).
    @State private var retiming: CronJob?
    /// Every scheduled job, from the header's Jobs counter or the link at the end (Planned).
    @State private var showingJobs = false

    private var upcoming: [ComingUp.Item] { model.items.filter { !$0.paused } }
    private var paused: [ComingUp.Item] { model.items.filter(\.paused) }

    private var days: [(day: Date, items: [ComingUp.Item])] { ComingUp.byDay(upcoming, now: .now) }

    var body: some View {
        let tone = DrawerTone(settings.resolvedTheme)
        let next = ComingUp.nextUp(upcoming, now: .now)
        ScrollViewReader { proxy in List {
            if model.loading, model.items.isEmpty {
                HStack(spacing: 10) { ProgressView(); Text("Reading…").foregroundStyle(.secondary) }
                    .plannedRow(top: 12, bottom: 12)
            } else if upcoming.isEmpty {
                AnyView(PlannedEmpty(planned: planned, tone: tone)).plannedRow(top: 8, bottom: 10)
            } else {
                AnyView(PlannedHero(counts: ComingUp.counts(model.items, now: .now), next: next, nextTitle: next.map(title),
                                    planned: planned, tone: tone, openJobs: { showingJobs = true }))
                    .plannedRow(top: 8, bottom: 6)
            }
            if let notice = model.notice {
                Label(notice, systemImage: "info.circle").font(.footnote).foregroundStyle(tone.warm).plannedRow(top: 4, bottom: 4)
            }
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(tone.warm).plannedRow(top: 4, bottom: 4)
            }
            ForEach(days, id: \.day) { day in
                AnyView(PlannedDayHeader(heading: heading(day.day), date: dateLine(day.day), count: day.items.count, tone: tone))
                    .plannedRow(top: 16, bottom: 4)
                ForEach(Array(day.items.enumerated()), id: \.element.id) { i, item in
                    row(item, tone: tone, isNext: item.id == next?.id, first: i == 0, last: i == day.items.count - 1)
                }
            }
            if !paused.isEmpty {
                AnyView(PlannedDayHeader(heading: String(localized: "Paused", comment: "Coming Up: the section of paused jobs"),
                                         date: nil, count: paused.count, tone: tone))
                    .plannedRow(top: 16, bottom: 4)
                ForEach(Array(paused.enumerated()), id: \.element.id) { i, item in
                    row(item, tone: tone, isNext: false, first: i == 0, last: i == paused.count - 1)
                }
            }
            if planned {
                // Every job on the server, as the Cron tab had them.
                Button { showingJobs = true } label: {
                    PlannedJobsLink(tone: tone)
                }
                .buttonStyle(DrawerSquish())
                .plannedRow(top: 16, bottom: 4)
            }
            Text("Skip passes over one run; Pause stops a job until you resume it. Skipping a run of a repeating job needs the Redde plugin 1.16 on your Hermes. Leave-By Alerts are skipped on this device.",
                 comment: "Coming Up: the footer")
                .font(.system(.footnote, design: tone.design)).foregroundStyle(.secondary)
                .plannedRow(top: 10, bottom: 24)
                .id(Self.endID)
        }
        .listStyle(.plain)
        .themedPage(settings.theme.listPage)
        .task(id: model.items.count) {
            guard Self.startsAtEnd, !model.items.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(400))
            proxy.scrollTo(Self.endID, anchor: .bottom)
        }
        }
        .navigationDestination(isPresented: $showingJobs) {
            CronView().navigationTitle(String(localized: "Scheduled Jobs", comment: "Planned: the page of every scheduled job (cron jobs)"))
        }
        .refreshable { await model.load() }
        .task {
            if planned { model.span = ComingUp.week; model.withPhone = true }
            await model.load()
        }
        .onChange(of: isShowing) { _, showing in if showing { Task { await model.load() } } }
        .sheet(item: $details) { job in
            CronJobDetail(job: job, backend: CronBackend.current()) { action in
                let item = model.items.first { $0.job?.id == job.id && $0.job?.profile == job.profile }
                switch action {
                case .edit: details = nil; editing = job
                case .run: Task { await model.runNow(job) }
                case .toggle: if let item { details = nil; Task { await model.setPaused(item, job.state != .paused) } }
                case .delete: if let item { details = nil; Task { await model.cancel(item) } }
                }
            }
        }
        .sheet(item: $editing) { job in CronJobEditor(job: job) { await model.load() } }
        .sheet(item: $retiming) { job in JobTimeSheet(job: job) { Task { await model.load() } } }
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

    /// `-echo.plannedEnd`: the page opened at its end, for pictures of what is paused and the link
    /// to every job.
    private static let endID = "planned.end"
    private static var startsAtEnd: Bool {
        #if DEBUG
        DevHooks.has("-echo.plannedEnd")
        #else
        false
        #endif
    }

    private var dialogTitle: String {
        guard let asking else { return "" }
        return ComingUp.skipWay(asking, now: .now) == .cancel
            ? String(localized: "Skip \(asking.title)?", comment: "Coming Up: confirming Skip on a job that runs once, by its title")
            : String(localized: "\(asking.title) runs in a moment", comment: "Coming Up: a run too near to skip, by its title")
    }

    private func row(_ item: ComingUp.Item, tone: DrawerTone, isNext: Bool, first: Bool, last: Bool) -> some View {
        PlannedTimelineRow(item: item, symbol: item.kind == .leaveBy ? leaveSymbol : item.kind.symbol,
                           title: title(item), subtitle: subtitle(item), state: state(item),
                           face: item.profile.flatMap(face), faceName: item.profile.map(name),
                           working: model.working == item.id, isNext: isNext, first: first, last: last, tone: tone)
        .plannedRow(top: 0, bottom: 0, leading: 8)
        .contentShape(.rect)
        .onTapGesture { if item.kind == .event { open(item) } }
        .swipeActions(edge: .trailing) { actions(item, swipe: true) }
        // A long press holds up its details (asked 2026-11-07), over the same actions; a job's
        // full page (its runs, Edit) is a tap more.
        .contextMenu {
            if let job = item.job {
                Button(String(localized: "Details"), systemImage: "info.circle") { details = job }
                Button { retiming = job } label: {
                    Label { Text("Change Time…", comment: "A briefing's menu: pick when its job runs") } icon: { Image(systemName: "clock.arrow.circlepath") }
                }
                Divider()
            }
            actions(item, swipe: false)
        } preview: {
            PlannedPreview(item: item, symbol: item.kind == .leaveBy ? leaveSymbol : item.kind.symbol,
                           title: title(item), subtitle: subtitle(item), state: state(item))
        }
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

    /// The agent's face, when the server's bots are known.
    private func face(_ profile: String) -> BotFace? {
        let faces = BotDirectory.shared.roster?.faces ?? [:]
        if let face = faces[profile] { return face }
        return profile == settings.profileName ? faces["default"] : nil
    }

    /// Under a day's name: its date ("Fri, Nov 13"), or for a day of the week just "Nov 15".
    private func dateLine(_ day: Date) -> String {
        let calendar = Calendar.current
        return calendar.isDateInToday(day) || calendar.isDateInTomorrow(day)
            ? day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            : day.formatted(.dateTime.month(.abbreviated).day())
    }

    private func name(_ profile: String) -> String {
        if profile == "default" || profile == settings.profileName { return settings.headerTitle }
        return BotDirectory.shared.roster?.named(profile)?.label(mainName: settings.headerTitle) ?? profile
    }
}

/// A Planned item's details, held up by a long press: when, how often, what the agent is told to
/// do, and how its last run went.
private struct PlannedPreview: View {
    let item: ComingUp.Item
    let symbol: String
    let title: String
    let subtitle: String?
    let state: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                    if let state { Text(state).font(.caption.weight(.medium)).foregroundStyle(.orange) }
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                if item.paused {
                    line(String(localized: "When"), String(localized: "Paused"))
                } else if item.untimed {
                    line(String(localized: "When"), String(localized: "Today"))
                } else {
                    line(item.job == nil ? String(localized: "When") : String(localized: "Next run"),
                         item.at.formatted(.dateTime.weekday().hour().minute()) + " · " + item.at.relativeLabel)
                }
                if let job = item.job {
                    // How often is in the subtitle already when it could be put in words.
                    if item.cadence == nil {
                        line(String(localized: "Schedule"), RoutineWhen(schedule: job.schedule)?.summary ?? job.schedule)
                    }
                    if let last = job.lastRunAt {
                        line(String(localized: "Last run"), [last.relativeLabel, job.lastStatus].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                    }
                    if let model = job.model, !model.isEmpty { line(String(localized: "Model"), model) }
                }
            }
            .font(.footnote)
            if let detail = item.detail { Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let job = item.job, !job.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Prompt")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    // (a preview is laid out at its ideal size: without fixedSize the text stops at two lines)
                    Text(job.prompt.trimmingCharacters(in: .whitespacesAndNewlines)).font(.footnote).lineLimit(16)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error = item.job?.lastError, !error.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Last error")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(width: 340, alignment: .leading)
    }

    private func line(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - The page's look (2026-11-13)

/// Planned's own hue (the drawer's second place) and the colours drawn from it.
extension DrawerTone {
    var planned: Color { places[1] }
    /// The hue a step toward the ink, for words and digits on the cards (the fill itself is for
    /// the icons), so they read on the surface in every theme.
    var plannedInk: Color { places[1].mix(with: ink, by: 0.22) }
}

private extension View {
    /// A row that draws its own look: no separator, no row background.
    func plannedRow(top: CGFloat, bottom: CGFloat, leading: CGFloat = 16) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// The top of the page: the alarm in Planned's hue, what's next and when, and three counters.
private struct PlannedHero: View {
    let counts: ComingUp.Counts
    let next: ComingUp.Item?
    let nextTitle: String?
    let planned: Bool
    let tone: DrawerTone
    let openJobs: () -> Void
    @State private var rang = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "alarm.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tone.page)
                    .symbolEffect(.bounce, value: rang)
                    .frame(width: 60, height: 60)
                    .background(tone.planned, in: .rect(cornerRadius: 19, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    if let next, let nextTitle {
                        Text(String(localized: "Up Next", comment: "Today strip: the tile with the next event on the calendar").localizedUppercase)
                            .font(.system(size: 11, weight: .heavy, design: tone.design))
                            .tracking(1)
                            .foregroundStyle(tone.plannedInk)
                        Text(verbatim: nextTitle)
                            .font(.system(.title3, design: tone.design, weight: .heavy))
                            .foregroundStyle(tone.ink)
                            .lineLimit(2)
                        // Once a minute, so "in 25 min" counts down while the page is up.
                        TimelineView(.everyMinute) { _ in
                            Text(verbatim: (Calendar.current.isDateInToday(next.at) ? next.at.formatted(.dateTime.hour().minute())
                                            : next.at.formatted(.dateTime.weekday().hour().minute())) + " · " + next.at.relativeLabel)
                                .font(.system(.subheadline, design: tone.design, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } else {
                        Text(verbatim: Date.now.formatted(.dateTime.weekday(.wide).month().day()))
                            .font(.system(.title3, design: tone.design, weight: .heavy))
                            .foregroundStyle(tone.ink)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                stat(counts.today, String(localized: "Today", comment: "An agenda card's day"), tone.plannedInk)
                if planned {
                    stat(counts.ahead, String(localized: "This week"), tone.ink)
                    Button(action: openJobs) {
                        stat(counts.jobs, String(localized: "Jobs", comment: "Planned: a counter's label, how many scheduled jobs there are (shown in capitals); opens them"),
                             tone.accent, opens: true)
                    }
                    .buttonStyle(DrawerSquish())
                } else {
                    stat(counts.tomorrow, String(localized: "Tomorrow", comment: "An agenda card's day"), tone.ink)
                    stat(counts.jobs, String(localized: "Jobs", comment: "Planned: a counter's label, how many scheduled jobs there are (shown in capitals); opens them"),
                         tone.accent)
                }
            }
        }
        .task { rang.toggle() }
    }

    private func stat(_ count: Int, _ label: String, _ color: Color, opens: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "\(count)")
                    .font(.system(size: 26, weight: .heavy, design: tone.design))
                    .monospacedDigit()
                    .foregroundStyle(count > 0 ? color : Color.secondary)
                    .contentTransition(.numericText())
                Text(verbatim: label.localizedUppercase)
                    .font(.system(size: 10, weight: .bold, design: tone.design))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            if opens {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(tone.surface, in: shape)
        .overlay { shape.strokeBorder(color.opacity(count > 0 ? 0.35 : 0.1), lineWidth: 1) }
        .contentShape(shape)
        .accessibilityElement(children: .combine)
    }
}

/// A day's name over its part of the timeline, its date beside it and how many there are.
private struct PlannedDayHeader: View {
    let heading: String
    let date: String?
    let count: Int
    let tone: DrawerTone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: heading)
                .font(.system(.title3, design: tone.design, weight: .heavy))
                .foregroundStyle(tone.ink)
            if let date {
                Text(verbatim: date)
                    .font(.system(.footnote, design: tone.design, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(verbatim: "\(count)")
                .font(.system(.caption, design: tone.design, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(tone.plannedInk)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(tone.planned.opacity(0.15), in: .capsule)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One thing on the timeline: its time big in the hue, a dot on the line with what kind it is,
/// and a card with what, who and how often. The next one is lit, with its countdown.
private struct PlannedTimelineRow: View {
    let item: ComingUp.Item
    let symbol: String
    let title: String
    let subtitle: String?
    let state: String?
    let face: BotFace?
    let faceName: String?
    let working: Bool
    let isNext: Bool
    let first: Bool
    let last: Bool
    let tone: DrawerTone

    private var dim: Bool { item.paused || item.skipped || item.skipping }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            time
                .frame(width: 60, alignment: .trailing)
                .padding(.top, 15)
            rail
            card
                .padding(.vertical, 5)
        }
    }

    @ViewBuilder private var time: some View {
        VStack(alignment: .trailing, spacing: 1) {
            if item.paused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.secondary)
            } else if item.untimed {
                Text(verbatim: "–")
                    .font(.system(size: 19, weight: .heavy, design: tone.design))
                    .foregroundStyle(.secondary)
            } else {
                let clock = ComingUp.clock(item.at)
                Text(verbatim: clock.time)
                    .font(.system(size: 19, weight: .heavy, design: tone.design))
                    .monospacedDigit()
                    .foregroundStyle(dim ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.plannedInk))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let period = clock.period {
                    Text(verbatim: period)
                        .font(.system(size: 10, weight: .bold, design: tone.design))
                        .foregroundStyle(.secondary)
                }
                if isNext {
                    TimelineView(.everyMinute) { _ in
                        Text(verbatim: item.at.relativeLabel)
                            .font(.system(size: 11, weight: .heavy, design: tone.design))
                            .foregroundStyle(tone.plannedInk)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                            .padding(.top, 2)
                    }
                }
            }
        }
    }

    /// The line through the day, broken at its ends, with this one's dot on it.
    private var rail: some View {
        let line = dim ? Color.secondary.opacity(0.2) : tone.planned.opacity(0.28)
        return ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle().fill(first ? Color.clear : line).frame(width: 2, height: 25)
                Rectangle().fill(last ? Color.clear : line).frame(width: 2).frame(maxHeight: .infinity)
            }
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isNext ? tone.page : dim ? Color.secondary : tone.planned)
                .frame(width: 28, height: 28)
                .background(isNext ? tone.planned : dim ? Color.secondary.opacity(0.14) : tone.planned.opacity(0.16), in: .circle)
                .padding(.top, 11)
        }
        .frame(width: 28)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(true)
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: title)
                    .font(.system(isNext ? .headline : .body, design: tone.design, weight: isNext ? .bold : .semibold))
                    .foregroundStyle(dim ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.ink))
                    .strikethrough(item.skipped || item.skipping, color: .secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if working { ProgressView().controlSize(.small) }
            }
            if let subtitle {
                HStack(spacing: 6) {
                    if let face {
                        BotAvatar(face: face, name: faceName, size: 18)
                    } else if item.profile == nil {
                        Image(systemName: "iphone")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: subtitle)
                        .font(.system(.caption, design: tone.design, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if let detail = item.detail {
                Text(verbatim: detail).font(.footnote).foregroundStyle(.secondary)
            }
            if let state {
                Text(verbatim: state)
                    .font(.system(.caption, design: tone.design, weight: .bold))
                    .foregroundStyle(tone.warm)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(tone.surface)
            if isNext { shape.fill(tone.planned.opacity(0.1)) }
        }
        .overlay {
            if isNext { shape.strokeBorder(tone.planned.opacity(0.45), lineWidth: 1) }
        }
    }
}

/// Nothing coming: the alarm resting, what would come here in words, and its kinds as a row of
/// small icons.
private struct PlannedEmpty: View {
    let planned: Bool
    let tone: DrawerTone
    @State private var rang = false

    private static let kinds: [String] = [ComingUp.Kind.headsUp, .leaveBy, .routine, .watch, .followUp, .goal, .alarm, .reminder, .event]
        .map(\.symbol)

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "alarm.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(tone.page)
                .symbolEffect(.bounce, value: rang)
                .frame(width: 84, height: 84)
                .background(tone.planned, in: .rect(cornerRadius: 26, style: .continuous))
                .accessibilityHidden(true)
            Text("Nothing planned yet", comment: "Planned and Coming Up: the title when nothing is planned")
                .font(.system(.title3, design: tone.design, weight: .heavy))
                .foregroundStyle(tone.ink)
            Group {
                if planned {
                    Text("Nothing planned for the next 7 days. What your agents will do comes here: heads-ups, leave times, routines, watches, follow-ups, goal check-ins, and the alarms, reminders and events they set on this device.",
                         comment: "Planned, when nothing is planned")
                } else {
                    Text("Nothing planned for the next 24 hours. What your agents will do on their own comes here: heads-ups, leave times, routines, watches, follow-ups and daily jobs.",
                         comment: "Coming Up, when nothing is planned")
                }
            }
            .font(.system(.footnote, design: tone.design))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                ForEach(Self.kinds, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tone.planned)
                        .frame(width: 25, height: 25)
                        .background(tone.planned.opacity(0.14), in: .circle)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 16).padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .background(tone.surface, in: .rect(cornerRadius: 22, style: .continuous))
        .task { rang.toggle() }
    }
}

/// The way to every scheduled job, at the end of Planned.
private struct PlannedJobsLink: View {
    let tone: DrawerTone

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tone.planned)
                .frame(width: 34, height: 34)
                .background(tone.planned.opacity(0.16), in: .rect(cornerRadius: 11, style: .continuous))
            Text(String(localized: "All Scheduled Jobs", comment: "Planned: opens the full list of scheduled jobs"))
                .font(.system(.body, design: tone.design, weight: .semibold))
                .foregroundStyle(tone.ink)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(tone.surface, in: .rect(cornerRadius: 16, style: .continuous))
        .contentShape(.rect)
    }
}

#if DEBUG
/// `-echo.demoComingUp`: a made-up day for the pictures, around now.
enum ComingUpDemo {
    static func items(now: Date, planned: Bool = false) -> [ComingUp.Item] {
        func job(_ id: String, _ name: String, _ schedule: String, in minutes: Double, profile: String? = nil,
                 enabled: Bool = true, times: Int? = nil, prompt: String? = nil, ranAgo hours: Double? = nil) -> CronJob {
            var fields: [String: JSONValue] = ["id": .string(id), "name": .string(name), "schedule": .string(schedule),
                                               "enabled": .bool(enabled), "next_run_at": .number(now.addingTimeInterval(minutes * 60).timeIntervalSince1970)]
            if let profile { fields["profile"] = .string(profile) }
            // What the long press's details show.
            if let prompt { fields["prompt"] = .string(prompt) }
            if let hours {
                fields["last_run_at"] = .number(now.addingTimeInterval(-hours * 3600).timeIntervalSince1970)
                fields["last_status"] = .string("ok")
            }
            if let times { fields["repeat"] = .object(["times": .number(Double(times)), "completed": .number(0)]) }
            return CronJob(.object(fields))!
        }
        let jobs = [
            job("w1", "[redde-watch:kettle01] The price of the blue kettle", "*/30 * * * *", in: 12,
                prompt: "Check the price of the blue Smeg kettle at the three shops in my notes. Tell me only if it drops below $120, with the shop and a link.",
                ranAgo: 0.3),
            job("h1", "[redde-notify] Heads-up: Dentist", "once at 2:15 PM", in: 95, times: 1),
            job("f1", "[redde-followup:plumb001] Call the plumber about the quote", "once", in: 300, times: 1),
            job("r1", "[redde-notify] What to wear for the weather", "0 7 * * 1-5", in: 60 * 15,
                prompt: "Look up today's weather where I am and tell me in one line what to wear, and whether to take an umbrella.",
                ranAgo: 9),
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
