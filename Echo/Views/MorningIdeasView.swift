import SwiftUI

/// Morning Ideas: a schedule on the person's Hermes, set up from here, that each morning has the
/// main agent look at the day and offer what it could do, as cards (`suggest_to_user`, Redde's
/// plugin 1.9). A Hermes job like any other (Cron lists it), found again by its name; on either
/// connection, as scheduled jobs are.
enum MorningIdeas {
    static let name = "[redde] Morning ideas"
    static let prompt = """
        Morning ideas. Look at the user's day: today's calendar and reminders, anything waiting on the kanban \
        board, and what they have asked you about lately. Think of up to five things you could do for them today \
        that would save them time or that they would likely want done, and offer them with suggest_to_user, the \
        most useful first, each with a short reason why now. Don't do any of them yet, and don't offer what they \
        have already asked you to do. If nothing is worth offering, offer nothing and stop. If suggest_to_user \
        isn't among your tools, find it with tool_search first (Hermes keeps plugin tools there until asked for).
        """

    static func job() async throws -> CronJob? {
        guard let backend = CronBackend.current() else { return nil }
        return try await backend.list().first { $0.name == name }
    }

    /// The hour and minute of a "M H * * *" schedule.
    static func time(of job: CronJob) -> (hour: Int, minute: Int)? {
        let parts = job.schedule.split(separator: " ")
        guard parts.count == 5, let minute = Int(parts[0]), let hour = Int(parts[1]) else { return nil }
        return (hour, minute)
    }

    static func set(at hour: Int, _ minute: Int, replacing job: CronJob?) async throws {
        guard let backend = CronBackend.current() else { throw TransportError.malformed(String(localized: "Scheduled jobs need the Hermes Dashboard or the Hermes API.")) }
        let schedule = "\(minute) \(hour) * * *"
        if let job {
            try await backend.update(job.id, name: name, schedule: schedule, prompt: prompt, deliver: "local")
        } else {
            try await backend.create(name: name, schedule: schedule, prompt: prompt, deliver: "local")
        }
    }
}

/// Settings → Agent → Morning Ideas.
struct MorningIdeasView: View {
    @State private var job: CronJob?
    @State private var loaded = false
    @State private var on = false
    @State private var time = Calendar.current.date(bySettingHour: 7, minute: 30, second: 0, of: .now) ?? .now
    @State private var working = false
    @State private var problem: String?
    @State private var sent = false

    var body: some View {
        Form {
            Section {
                Toggle("Morning Ideas", isOn: Binding(get: { on }, set: { new in on = new; Task { await apply() } }))
                    .disabled(!loaded || working)
                if on {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        .onChange(of: time) { Task { await apply() } }
                        .disabled(working)
                    Button("Send Ideas Now", systemImage: "lightbulb") { Task { await runNow() } }
                        .disabled(working || job == nil)
                }
            } footer: {
                Text("Each morning your agent looks at your day (your calendar, reminders, the board, what you asked it lately) and offers up to five things it could do, as cards at the top of your chats and a notification. Swipe one right to have it done, left to put it away. Nothing is done until you take one. Needs Redde's plugin 1.9 on your Hermes, and notifications from it turned on.")
            }
            if sent {
                Section { Label("Asked. The ideas come as a notification when your agent is done.", systemImage: "checkmark.circle") }
            }
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
        .navigationTitle("Morning Ideas")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        do {
            job = try await MorningIdeas.job()
            on = job != nil
            if let job, let (hour, minute) = MorningIdeas.time(of: job),
               let at = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) { time = at }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }

    private func apply() async {
        guard loaded else { return }
        working = true
        defer { working = false }
        do {
            if on {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                try await MorningIdeas.set(at: parts.hour ?? 7, parts.minute ?? 30, replacing: job)
            } else if let job {
                try await CronBackend.current()?.delete(job.id)
            }
            job = try await MorningIdeas.job()
            problem = nil
        } catch {
            problem = error.localizedDescription
            on = job != nil
        }
    }

    private func runNow() async {
        guard let job else { return }
        working = true
        sent = true
        defer { working = false }
        do {
            try await CronBackend.current()?.runNow(job.id)
            self.job = try await MorningIdeas.job()
        } catch { problem = error.localizedDescription }
    }
}
