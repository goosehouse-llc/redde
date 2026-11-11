import SwiftUI

/// Change Time (asked 2026-11-11: "I can't seem to change the runtime of the daily briefings"):
/// when a scheduled job runs, picked as a bot's routine is (`RoutineWhenSection`), with nothing
/// else about the job changed. From a briefing's tile and sheet (`BriefingTimeSheet`) and from a
/// job on Planned.
struct JobTimeSheet: View {
    let job: CronJob
    var onDone: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var when = RoutineWhen()
    @State private var custom: String?
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            JobTimeForm(job: job, when: $when, custom: $custom, problem: problem)
                .navigationTitle(ComingUp.describe(job).title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if working { ProgressView() } else {
                            Button("Save") { save() }.disabled(custom != nil)
                        }
                    }
                }
        }
        .onAppear {
            if let read = RoutineWhen(schedule: job.schedule) { when = read } else { custom = job.schedule }
        }
        .interactiveDismissDisabled(working)
    }

    private func save() {
        guard let backend = CronBackend.current() else { problem = String(localized: "No gateway configured."); return }
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                try await backend.reschedule(job.id, schedule: when.schedule, profile: job.profile)
                onDone()
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// The form itself: the job's next run, and when it runs.
private struct JobTimeForm: View {
    let job: CronJob
    @Binding var when: RoutineWhen
    @Binding var custom: String?
    let problem: String?

    var body: some View {
        Form {
            RoutineWhenSection(when: $when, custom: $custom)
            if let next = job.nextRunAt {
                Section {
                    LabeledContent("Next run") { Text(next, format: .dateTime.weekday().hour().minute()) }
                } footer: {
                    Text("Only when it runs changes; what it does stays as it is.", comment: "Change Time: under the next run")
                }
            }
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
    }
}

/// Change Time for a briefing: its job found on the server first (the briefing knows only its id).
struct BriefingTimeSheet: View {
    let briefing: AgentBriefing
    @Environment(\.dismiss) private var dismiss
    @State private var job: CronJob?
    @State private var problem: String?

    var body: some View {
        if let job {
            JobTimeSheet(job: job)
        } else {
            NavigationStack {
                Group {
                    if let problem {
                        ContentUnavailableView(String(localized: "Can't Change the Time", comment: "Change Time on a briefing whose job wasn't found"),
                                               systemImage: "clock.badge.questionmark", description: Text(problem))
                    } else {
                        ProgressView()
                    }
                }
                .navigationTitle(briefing.heading)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            }
            .task { await find() }
        }
    }

    private func find() async {
        guard let id = briefing.job, let backend = CronBackend.current() else {
            problem = String(localized: "No gateway configured.")
            return
        }
        do {
            let jobs = try await backend.list()
            let profile = briefing.profile ?? "default"
            if let found = jobs.first(where: { $0.id == id && ($0.profile ?? "default") == profile }) ?? jobs.first(where: { $0.id == id }) {
                job = found
            } else {
                problem = String(localized: "Its job isn't on your Hermes any more, or it is a bot's that only the Hermes Dashboard lists.",
                                 comment: "Change Time on a briefing: its job wasn't found")
            }
        } catch {
            problem = error.localizedDescription
        }
    }
}
