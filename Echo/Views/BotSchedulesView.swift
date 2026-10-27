import SwiftUI

/// A bot's schedules (`BotRoutines`): what it does when, each run's answer coming into its chat.
/// Swipe to pause or delete, tap to change or run now, New Schedule to add one.
struct BotSchedulesView: View {
    let bot: HermesBot
    let mainName: String
    @Environment(\.dismiss) private var dismiss
    @State private var jobs: [CronJob] = []
    @State private var loading = true
    @State private var problem: String?
    @State private var editing: CronJob?
    @State private var creating = false
    @State private var busy: Set<String> = []

    private var name: String { bot.label(mainName: mainName) }

    /// The Dashboard, or the sample bots' look (`-echo.demoBots`).
    private var reachable: Bool {
        #if DEBUG
        if DevHooks.demoBots { return true }
        #endif
        return BotRoutines.backend != nil
    }

    var body: some View {
        NavigationStack {
            List {
                if !reachable {
                    ContentUnavailableView("Needs the Hermes Dashboard", systemImage: "clock.badge.questionmark",
                                           description: Text("A bot's schedules are kept with its other settings on your server, through the Dashboard. Add its login in Settings → Hermes server."))
                } else if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if jobs.isEmpty, !loading {
                    ContentUnavailableView("No schedules yet", systemImage: "clock",
                                           description: Text("Give \(name) something to do at a time: every weekday at 7, check the weather and your calendar and say what to wear. Its answer comes into its chat."))
                }
                ForEach(jobs) { job in
                    Button { editing = job } label: { row(job) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) { act(job) { try await $0.delete(job.id, profile: bot.name) } }
                        }
                        .swipeActions(edge: .leading) {
                            if job.state == .scheduled || job.state == .paused {
                                Button(job.state == .paused ? String(localized: "Resume") : String(localized: "Pause"), systemImage: job.state == .paused ? "play" : "pause") {
                                    act(job) { try await $0.setPaused(job.id, job.state != .paused, profile: bot.name) }
                                }
                                .tint(job.state == .paused ? .green : .orange)
                            }
                        }
                        .contextMenu {
                            Button("Run Now", systemImage: "bolt") { runNow(job) }
                            Button(job.state == .paused ? String(localized: "Resume") : String(localized: "Pause"), systemImage: job.state == .paused ? "play" : "pause") {
                                act(job) { try await $0.setPaused(job.id, job.state != .paused, profile: bot.name) }
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) { act(job) { try await $0.delete(job.id, profile: bot.name) } }
                        }
                }
                if reachable {
                    Section {
                        Button("New Schedule", systemImage: "plus") { creating = true }
                    } footer: {
                        Text("Each run is \(name)'s, with its own personality and tools, and its answer comes into its chat, with a notification, while your phone is off. Times are your server's. Hermes 0.21.5 and later run a bot's schedules by themselves; earlier ones only with gateway.multiplex_profiles on.")
                    }
                }
            }
            .overlay { if loading && jobs.isEmpty { ProgressView() } }
            .navigationTitle("\(name)'s Schedules")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .refreshable { await load() }
            .sheet(item: $editing) { job in RoutineEditor(bot: bot, mainName: mainName, job: job) { Task { await load() } } }
            .sheet(isPresented: $creating) { RoutineEditor(bot: bot, mainName: mainName, job: nil) { Task { await load() } } }
        }
    }

    private func row(_ job: CronJob) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: job.state == .paused ? "pause.circle" : BotRoutines.missed(job) ? "exclamationmark.circle" : "clock")
                .foregroundStyle(job.state == .paused ? Color.secondary : BotRoutines.missed(job) ? .orange : .accentColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title.isEmpty ? job.prompt : job.title).font(.body.weight(.medium)).lineLimit(2)
                Text(RoutineWhen(schedule: job.schedule)?.summary ?? job.schedule).font(.footnote).foregroundStyle(.secondary)
                Group {
                    if busy.contains(job.id) {
                        Text("Running…")
                    } else if job.state == .paused {
                        Text("Paused")
                    } else if BotRoutines.missed(job), let next = job.nextRunAt {
                        Text("Didn't run \(next.relativeLabel): your server isn't running \(name)'s schedules").foregroundStyle(.orange)
                    } else if let next = job.nextRunAt {
                        Text("Next \(next.relativeLabel)")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if busy.contains(job.id) { ProgressView().controlSize(.small) }
        }
        .contentShape(.rect)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        #if DEBUG
        if DevHooks.demoBots { jobs = Self.demoJobs; return }
        #endif
        do {
            jobs = try await BotRoutines.list(bot.name)
            problem = nil
        } catch {
            problem = String(localized: "Couldn't read \(name)'s schedules: \(error.localizedDescription)")
        }
    }

    private func act(_ job: CronJob, _ work: @escaping (CronBackend) async throws -> Void) {
        guard let backend = BotRoutines.backend else { return }
        busy.insert(job.id)
        Task {
            defer { busy.remove(job.id) }
            do { try await work(backend) } catch { problem = error.localizedDescription }
            await load()
        }
    }

    /// Hermes runs it there and then, its answer coming into the bot's chat; the Dashboard waits
    /// for the run to end.
    private func runNow(_ job: CronJob) { act(job) { try await $0.runNow(job.id, profile: bot.name) } }

    #if DEBUG
    /// `-echo.demoBots`: a bot's schedules, one paused, for a look at the screen.
    static let demoJobs: [CronJob] = {
        func job(_ id: String, _ name: String, _ prompt: String, _ schedule: String, enabled: Bool, next: TimeInterval?) -> CronJob? {
            var fields: [String: JSONValue] = ["id": .string(id), "name": .string(name), "prompt": .string(prompt),
                                               "schedule_display": .string(schedule), "deliver": .string("bot-chat:scout"), "enabled": .bool(enabled)]
            if let next { fields["next_run_at"] = .number(Date.now.addingTimeInterval(next).timeIntervalSince1970) }
            return CronJob(.object(fields))
        }
        return [job("a1", "[bot:scout] What to wear", "Check the weather and my calendar, and tell me what to wear", "0 7 * * 1-5",
                    enabled: true, next: 14 * 3600),
                job("a2", "[bot:scout] Trail report", "Check the trail conditions for the weekend", "30 18 * * 5", enabled: true, next: 3 * 86400),
                job("a3", "[bot:scout] Pollen", "Tell me the pollen count", "every 4h", enabled: false, next: nil)].compactMap(\.self)
    }()
    #endif
}

/// Making or changing one of a bot's schedules: what to call it, what to do, and when.
struct RoutineEditor: View {
    let bot: HermesBot
    let mainName: String
    let job: CronJob?
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var prompt = ""
    @State private var when = RoutineWhen()
    /// A schedule Redde can't put in its own words (made on the server): kept as it is unless changed.
    @State private var custom: String?
    @State private var working = false
    @State private var problem: String?

    private var name: String { bot.label(mainName: mainName) }
    private var schedule: String { custom ?? when.schedule }
    private var canSave: Bool {
        !working && !title.trimmingCharacters(in: .whitespaces).isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("What to wear", text: $title).textInputAutocapitalization(.sentences)
                }
                Section {
                    TextField("Check the weather and my calendar, and tell me what to wear", text: $prompt, axis: .vertical)
                        .lineLimit(3 ... 8)
                } header: {
                    Text("What \(name) does")
                } footer: {
                    Text("As you would ask it in its chat. Its answer comes into the chat, with a notification.")
                }
                Section("When") {
                    if let custom {
                        LabeledContent("Schedule", value: custom)
                        Button("Pick a Time Instead") { self.custom = nil }
                    } else {
                        Picker("Repeat", selection: $when.repeats) {
                            ForEach(RoutineWhen.Repeat.allCases) { Text($0.title).tag($0) }
                        }
                        switch when.repeats {
                        case .hours:
                            Stepper(String(localized: "Every \(when.everyHours) hours"), value: $when.everyHours, in: 1 ... 23)
                        case .once:
                            DatePicker("At", selection: $when.once, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                        default:
                            DatePicker("At", selection: timeOfDay, displayedComponents: .hourAndMinute)
                            if when.repeats == .weekly { weekdays }
                        }
                    }
                }
                if let job {
                    Section {
                        if let last = job.lastRunAt {
                            LabeledContent("Last run", value: last.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let error = job.lastError, job.lastStatus == "error" {
                            Text(error).font(.footnote).foregroundStyle(.orange)
                        }
                    }
                }
                if let problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
            }
            .navigationTitle(job == nil ? String(localized: "New Schedule") : String(localized: "Schedule"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button(job == nil ? String(localized: "Add") : String(localized: "Save")) { save() }.disabled(!canSave)
                    }
                }
            }
            .onAppear(perform: fill)
        }
        .interactiveDismissDisabled(working)
    }

    /// The hour and minute, as a time picker shows them.
    private var timeOfDay: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: when.hour, minute: when.minute, second: 0, of: .now) ?? .now
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            when.hour = parts.hour ?? 7
            when.minute = parts.minute ?? 0
        })
    }

    private var weekdays: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< 7, id: \.self) { day in
                let on = when.days.contains(day)
                Button(Calendar.current.veryShortWeekdaySymbols[day]) {
                    if on, when.days.count > 1 { when.days.remove(day) } else { when.days.insert(day) }
                }
                .buttonStyle(.bordered)
                .tint(on ? .accentColor : .secondary)
                .accessibilityLabel(Calendar.current.weekdaySymbols[day])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func fill() {
        guard let job, title.isEmpty else { return }
        title = job.title
        prompt = job.prompt
        if let read = RoutineWhen(schedule: job.schedule) { when = read } else { custom = job.schedule }
    }

    private func save() {
        working = true
        problem = nil
        Task {
            defer { working = false }
            let title = title.trimmingCharacters(in: .whitespaces)
            do {
                if let job {
                    try await BotRoutines.update(job, bot: bot.name, title: title, prompt: prompt, when: schedule)
                } else {
                    try await BotRoutines.create(bot.name, title: title, prompt: prompt, when: schedule)
                }
                onDone()
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
