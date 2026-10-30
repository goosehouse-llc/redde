import SwiftUI

/// Scheduled jobs on the gateway: list, pause/resume, run now, create, edit, delete, run history.
struct CronView: View {
    @State private var jobs: [CronJob] = []
    @State private var error: String?
    @State private var loading = false
    @State private var editing: CronJob?
    @State private var creating = false
    @State private var browsingBlueprints = false
    @State private var detail: CronJob?
    @State private var busy: Set<String> = []
    @State private var toast: String?
    /// Resolved once per screen and again on each refresh, not on every body pass.
    @State private var backend = CronBackend.current()
    /// The conversation list's server and section switch, scrolling with the jobs.
    var topRow: AnyView?
    /// The iPhone's panel is out: it stays built while closed, so this is when to reload.
    var isShowing = true

    var body: some View {
        List {
            if let topRow { topRow }
            if backend == nil {
                ContentUnavailableView("No gateway configured", systemImage: "clock.badge.questionmark",
                                       description: Text("Cron jobs live on the Hermes gateway. Set up the Hermes Dashboard or the Hermes API in Settings."))
                    .listRowSeparator(.hidden)
            } else if let error {
                ContentUnavailableView("Couldn't load jobs", systemImage: "wifi.exclamationmark", description: Text(error))
                    .listRowSeparator(.hidden)
            } else if jobs.isEmpty && !loading {
                ContentUnavailableView("No jobs yet", systemImage: "clock",
                                       description: Text("Schedule Redde to run a prompt every hour, every weekday at 9am, or once at a time you pick."))
                    .listRowSeparator(.hidden)
            }
            ForEach(jobs) { job in
                Button { detail = job } label: { row(job) }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if job.state == .scheduled || job.state == .paused {
                            Button { setPaused(job, job.state != .paused) } label: {
                                Label(job.state == .paused ? String(localized: "Resume") : String(localized: "Pause"), systemImage: job.state == .paused ? "play" : "pause")
                            }
                            .tint(job.state == .paused ? .green : .orange)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { delete(job) } label: { Label("Delete", systemImage: "trash") }
                        Button { runNow(job) } label: { Label("Run now", systemImage: "bolt") }.tint(.blue)
                    }
                    .contextMenu {
                        Button("Run now", systemImage: "bolt") { runNow(job) }
                        Button(job.state == .paused ? String(localized: "Resume") : String(localized: "Pause"), systemImage: job.state == .paused ? "play" : "pause") { setPaused(job, job.state != .paused) }
                        Button("Edit", systemImage: "pencil") { editing = job }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(job) }
                    }
                    .disabled(busy.contains(job.id))
            }
        }
        .listStyle(.plain)
        .toast($toast)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if backend?.supportsBlueprints == true {
                    Menu("New", systemImage: "plus") {
                        Button("New job", systemImage: "square.and.pencil") { creating = true }
                        Button("From a blueprint…", systemImage: "doc.on.clipboard") { browsingBlueprints = true }
                    }
                } else {
                    Button("New job", systemImage: "plus") { creating = true }.disabled(backend == nil)
                }
            }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
        .onChange(of: isShowing) { _, showing in if showing { Task { await refresh() } } }
        .sheet(isPresented: $creating) { CronJobEditor(job: nil) { await refresh() } }
        .sheet(isPresented: $browsingBlueprints) { if let backend { BlueprintBrowser(backend: backend) { await refresh() } } }
        .sheet(item: $editing) { job in CronJobEditor(job: job) { await refresh() } }
        .sheet(item: $detail) { job in
            CronJobDetail(job: job, backend: backend) { action in
                switch action {
                case .edit: detail = nil; editing = job
                case .run: runNow(job)
                case .toggle: setPaused(job, job.state != .paused)
                case .delete: detail = nil; delete(job)
                }
            }
        }
    }

    private func row(_ job: CronJob) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color(job.state)).frame(width: 9, height: 9).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name.isEmpty ? job.prompt : job.title).chatFont(.body, weight: .medium).lineLimit(2)
                // A bot's: whose, and when in words.
                Text([job.profile.flatMap(BotRoutines.botName), RoutineWhen(schedule: job.schedule)?.summary ?? job.schedule]
                    .compactMap(\.self).joined(separator: " · "))
                    .chatFont(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if job.state == .paused { Text("Paused") }
                    else if job.state == .completed { Text("Completed") }
                    else if job.state == .error { Text("Error").foregroundStyle(.red) }
                    else if let next = job.nextRunAt { Text("Next \(next.relativeLabel)") }
                    if let status = job.lastStatus, let last = job.lastRunAt {
                        Text("· last \(status) \(last.relativeLabel)")
                    }
                }
                .chatFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if busy.contains(job.id) { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }

    private func color(_ s: CronJob.State) -> Color {
        switch s {
        case .scheduled: .green
        case .paused: .orange
        case .completed: .secondary
        case .error: .red
        }
    }

    private func refresh() async {
        backend = CronBackend.current()
        guard let backend else { return }
        loading = true
        defer { loading = false }
        do {
            jobs = try await backend.list().sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func perform(_ job: CronJob, _ note: String? = nil, _ op: @escaping (CronBackend) async throws -> Void) {
        guard let backend else { return }
        busy.insert(job.id)
        Task {
            defer { busy.remove(job.id) }
            do {
                try await op(backend)
                if let note { show(note) }
                await refresh()
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    // (In the job's own store: a bot's is found only there.)
    private func setPaused(_ job: CronJob, _ paused: Bool) { perform(job) { try await $0.setPaused(job.id, paused, profile: job.profile) } }
    private func runNow(_ job: CronJob) {
        perform(job, String(localized: "Run finished")) { try await $0.runNow(job.id, profile: job.profile) }
        show(String(localized: "Running…"))
    }
    private func delete(_ job: CronJob) { perform(job) { try await $0.delete(job.id, profile: job.profile) } }

    private func show(_ text: String) { toast = text }
}

/// Create or edit a job. Schedules use Hermes' own grammar, shown as hints.
struct CronJobEditor: View {
    let job: CronJob?
    let onSave: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var schedule = ""
    @State private var prompt = ""
    @State private var deliver = "local"
    @State private var customDeliver = ""
    @State private var targets: [CronDeliveryTarget] = CronDeliveryTarget.builtIn
    @State private var saving = false
    @State private var error: String?

    private var deliverValue: String { deliver == "__custom__" ? customDeliver.trimmingCharacters(in: .whitespaces) : deliver }

    private static let examples = ["every 30m", "every day at 9am", "weekdays at 9am", "every monday 8am", "0 */6 * * *", "in 2h", "2026-12-01T09:00"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Job") {
                    TextField("Name", text: $name)
                    TextField("Schedule", text: $schedule).autocorrectionDisabled().textInputAutocapitalization(.never)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Self.examples, id: \.self) { ex in
                                Button(ex) { schedule = ex }
                                    .chatFont(.caption).buttonStyle(.bordered).buttonBorderShape(.capsule)
                            }
                        }
                    }
                    .listRowInsets(.init(top: 4, leading: 12, bottom: 8, trailing: 12))
                }
                Section("Prompt") {
                    TextField("What should Redde do?", text: $prompt, axis: .vertical).lineLimit(4...12)
                }
                Section {
                    Picker("Deliver to", selection: $deliver) {
                        ForEach(targets) { t in
                            Text(t.homeTargetSet ? t.name : String(localized: "\(t.name) (no home channel)")).tag(t.id)
                        }
                        Text("Other…").tag("__custom__")
                    }
                    if deliver == "__custom__" {
                        TextField("platform:chat_id or bot-chat:profile", text: $customDeliver)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } footer: {
                    Text("Local keeps the output on the gateway. A platform sends it to that platform's cron home channel; “Other” takes an explicit target like telegram:123456.")
                }
                Section {
                    Text("Recurring: “30m”, “every hour”, “every day at 9am”, “weekdays at 9am”, or a cron expression. Once: “in 30m” or an ISO time. Bare “30m” repeats; “in 30m” runs once.")
                        .chatFont(.footnote).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).chatFont(.footnote).foregroundStyle(.red) } }
            }
            .navigationTitle(job == nil ? String(localized: "New job") : String(localized: "Edit job"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? String(localized: "Saving…") : String(localized: "Save")) { save() }
                        .disabled(saving || schedule.trimmingCharacters(in: .whitespaces).isEmpty || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let job { name = job.name; schedule = job.schedule; prompt = job.prompt }
            }
            .task {
                if let backend = CronBackend.current() { targets = await backend.deliveryTargets() }
                let current = job?.deliver ?? "local"
                if targets.contains(where: { $0.id == current }) { deliver = current }
                else if !current.isEmpty { deliver = "__custom__"; customDeliver = current }
            }
        }
    }

    private func save() {
        guard let backend = CronBackend.current() else { error = String(localized: "No gateway configured."); return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let n = name.trimmingCharacters(in: .whitespaces)
                let title = n.isEmpty ? String(prompt.prefix(50)) : n
                if let job { try await backend.update(job.id, name: title, schedule: schedule, prompt: prompt, deliver: deliverValue, profile: job.profile) }
                else { try await backend.create(name: title, schedule: schedule, prompt: prompt, deliver: deliverValue) }
                await onSave()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct CronJobDetail: View {
    enum Action { case edit, run, toggle, delete }
    let job: CronJob
    let backend: CronBackend?
    let onAction: (Action) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var runs: [CronRun] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Schedule", value: job.schedule)
                    LabeledContent("State", value: Self.stateName(job.state))
                    if let n = job.nextRunAt { LabeledContent("Next run") { Text(n, format: .dateTime.weekday().hour().minute()) } }
                    if let l = job.lastRunAt { LabeledContent("Last run") { Text("\(l.relativeLabel) · \(job.lastStatus ?? "")") } }
                    if let d = job.deliver, !d.isEmpty { LabeledContent("Deliver to", value: d) }
                    if let m = job.model, !m.isEmpty { LabeledContent("Model", value: m) }
                }
                Section("Prompt") {
                    Text(job.prompt).chatFont(.callout).textSelection(.enabled)
                }
                if let e = job.lastError, !e.isEmpty {
                    Section("Last error") { Text(e).chatFont(.footnote).foregroundStyle(.red).textSelection(.enabled) }
                }
                if backend?.supportsRunHistory == true {
                    Section("Recent runs") {
                        if runs.isEmpty { Text("No runs yet").foregroundStyle(.secondary) }
                        ForEach(runs) { run in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    if let s = run.startedAt { Text(s, format: .dateTime.month().day().hour().minute()) }
                                    if run.active { Text("running").chatFont(.caption).foregroundStyle(.green) }
                                }
                                .chatFont(.footnote, weight: .medium)
                                if let p = run.preview, !p.isEmpty { Text(p).chatFont(.caption).foregroundStyle(.secondary).lineLimit(3) }
                            }
                        }
                    }
                }
                Section {
                    Button("Run now", systemImage: "bolt") { onAction(.run) }
                    Button(job.state == .paused ? String(localized: "Resume") : String(localized: "Pause"), systemImage: job.state == .paused ? "play" : "pause") { onAction(.toggle) }
                    Button("Edit", systemImage: "pencil") { onAction(.edit) }
                    Button("Delete", systemImage: "trash", role: .destructive) { onAction(.delete) }
                }
            }
            .navigationTitle(job.name.isEmpty ? String(localized: "Job", comment: "A scheduled job with no name") : job.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { runs = (try? await backend?.runs(job.id, profile: job.profile)) ?? [] }
        }
    }

    /// A job's state, in words.
    private static func stateName(_ state: CronJob.State) -> String {
        switch state {
        case .scheduled: String(localized: "Scheduled", comment: "A scheduled job's state")
        case .paused: String(localized: "Paused", comment: "A scheduled job's state")
        case .completed: String(localized: "Completed", comment: "A scheduled job's state")
        case .error: String(localized: "Error", comment: "A scheduled job's state")
        }
    }
}


/// The gateway's blueprint catalog: pick one, fill its slots, and it becomes a job.
struct BlueprintBrowser: View {
    let backend: CronBackend
    let onCreated: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var blueprints: [CronBlueprint] = []
    @State private var error: String?
    @State private var loading = true
    @State private var chosen: CronBlueprint?

    private var grouped: [(String, [CronBlueprint])] {
        let groups = Dictionary(grouping: blueprints) {
            $0.category.isEmpty ? String(localized: "Other", comment: "Blueprints with no category") : $0.category.capitalized
        }
        return groups.keys.sorted().map { ($0, groups[$0]!) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    ContentUnavailableView("Couldn't load blueprints", systemImage: "wifi.exclamationmark", description: Text(error))
                } else if blueprints.isEmpty, !loading {
                    ContentUnavailableView("No blueprints", systemImage: "doc.on.clipboard")
                }
                ForEach(grouped, id: \.0) { category, items in
                    Section(category) {
                        ForEach(items) { bp in
                            Button { chosen = bp } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(bp.title).chatFont(.body, weight: .medium)
                                    if !bp.description.isEmpty { Text(bp.description).chatFont(.footnote).foregroundStyle(.secondary).lineLimit(3) }
                                    if !bp.scheduleHuman.isEmpty { Label(bp.scheduleHuman, systemImage: "clock").chatFont(.caption).foregroundStyle(.secondary) }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .overlay { if loading { ProgressView() } }
            .navigationTitle("Blueprints")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                do { blueprints = try await backend.blueprints(); error = nil } catch { self.error = error.localizedDescription }
                loading = false
            }
            .sheet(item: $chosen) { bp in
                BlueprintForm(blueprint: bp, backend: backend) {
                    await onCreated()
                    dismiss()
                }
            }
        }
    }
}

struct BlueprintForm: View {
    let blueprint: CronBlueprint
    let backend: CronBackend
    let onCreated: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var saving = false
    @State private var error: String?

    private func binding(_ f: CronBlueprint.Field) -> Binding<String> {
        Binding(get: { values[f.name] ?? f.defaultValue }, set: { values[f.name] = $0 })
    }

    private var complete: Bool {
        blueprint.fields.allSatisfy { $0.optional || !(values[$0.name] ?? $0.defaultValue).trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !blueprint.description.isEmpty {
                    Section { Text(blueprint.description).chatFont(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    ForEach(blueprint.fields) { f in
                        if f.type == "enum", !f.options.isEmpty {
                            Picker(f.label, selection: binding(f)) {
                                if f.optional { Text("None").tag("") }
                                ForEach(f.options, id: \.self) { Text(Self.pretty($0, field: f)).tag($0) }
                            }
                        } else if f.type == "text" {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(f.label).chatFont(.footnote).foregroundStyle(.secondary)
                                TextField(f.optional ? String(localized: "Optional") : String(localized: "Required"), text: binding(f), axis: .vertical)
                                    .lineLimit(1...5)
                            }
                        } else {
                            LabeledContent(f.label) {
                                TextField(f.type == "time" ? "9:00 am" : f.optional ? String(localized: "Optional") : String(localized: "Required"),
                                          text: binding(f))
                                    .multilineTextAlignment(.trailing)
                                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                            }
                        }
                        if let help = f.help, !help.isEmpty {
                            Text(help).chatFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if !blueprint.scheduleHuman.isEmpty { Text("Runs \(blueprint.scheduleHuman).") }
                }
                if let error { Section { Text(error).chatFont(.footnote).foregroundStyle(.red) } }
            }
            .navigationTitle(blueprint.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? String(localized: "Creating…") : String(localized: "Create job")) { create() }.disabled(saving || !complete)
                }
            }
        }
    }

    /// Enum options are raw ids ("telegram", "30"); show them a little friendlier.
    private static func pretty(_ option: String, field: CronBlueprint.Field) -> String {
        if field.name == "deliver" {
            switch option {
            case "local": return String(localized: "Local (save only)", comment: "Where a job's output goes: kept on the gateway")
            case "origin": return String(localized: "Where the job was created", comment: "Where a job's output goes")
            default: return option.capitalized
            }
        }
        if field.name.contains("min"), let n = Int(option) {
            // In minutes, or in hours when it is whole hours.
            let every = n >= 60 && n % 60 == 0
                ? Duration.seconds(n * 60).formatted(.units(allowed: [.hours], width: .abbreviated))
                : Duration.seconds(n * 60).formatted(.units(allowed: [.minutes], width: .abbreviated))
            return String(localized: "Every \(every)", comment: "How often a job runs, e.g. “Every 30 min”")
        }
        return option.capitalized
    }

    private func create() {
        saving = true
        Task {
            defer { saving = false }
            do {
                var filled: [String: String] = [:]
                for f in blueprint.fields {
                    let v = (values[f.name] ?? f.defaultValue).trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty { filled[f.name] = v }
                }
                try await backend.instantiate(blueprint: blueprint.key, values: filled)
                await onCreated()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
