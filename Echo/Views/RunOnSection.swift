import SwiftUI

/// Run On (`RunOn`): which model a scheduled job runs on, the main model or one picked from the
/// server's list. On a daily job's page, a job's detail and a bot's schedule. The list is read when
/// the section first shows, nothing more.
struct RunOnSection: View {
    let job: CronJob
    /// After a change, to read the job again.
    var changed: () async -> Void = {}

    @State private var choices: [ModelChoice] = []
    @State private var picked: RunOn.Pick = .main
    @State private var loaded = false
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        Section {
            Picker(selection: Binding(get: { picked }, set: { new in
                let old = picked
                picked = new
                Task { await set(new, from: old) }
            })) {
                Text("Main Model").tag(RunOn.Pick.main)
                ForEach(choices) { choice in
                    Text(label(choice)).tag(RunOn.Pick(model: choice.model, provider: choice.provider))
                }
                // One set elsewhere that the list doesn't have, so the picker still says it.
                if !picked.isMain, RunOn.choice(for: picked, in: choices) == nil {
                    Text(picked.model).tag(picked)
                }
            } label: {
                Label { Text("Run On") } icon: { Image(systemName: "cpu") }
            }
            .disabled(!loaded || working)
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
        } footer: {
            footer
        }
        .task(id: job.id) { await load() }
    }

    @ViewBuilder private var footer: some View {
        if job.askedModel != nil, RunOnMarks.unheard(job) {
            VStack(alignment: .leading, spacing: 6) {
                Text("The Redde plugin on your Hermes hasn't taken this up. Over the Hermes API, Run On needs plugin \(RunOn.pluginVersion) or later (Settings › Redde Plugin), or the Hermes Dashboard login.")
                Button("Take It Back") { Task { await takeBack() } }.font(.footnote)
            }
        } else if job.askedModel != nil {
            Text("Your Hermes takes this up within half a minute.")
        } else if picked.isMain {
            Text("Runs on the model your server is set to use. A small model that stays loaded answers sooner and doesn't swap the main one out while you chat.")
        } else {
            Text("Runs on \(picked.model), even when your chats use another model.")
        }
    }

    /// The list's name, with its provider's when two providers have a model of that name.
    private func label(_ choice: ModelChoice) -> String {
        choices.filter { $0.model == choice.model }.count > 1 ? "\(choice.name) (\(choice.providerName))" : choice.name
    }

    private func load() async {
        picked = RunOn.current(job)
        guard !loaded else { return }
        #if DEBUG
        if DevHooks.has("-echo.demoRunOn") { choices = RunOnDemo.choices; loaded = true; return }
        #endif
        choices = (try? await CronBackend.current()?.modelOptions()) ?? []
        loaded = true
    }

    private func set(_ pick: RunOn.Pick, from old: RunOn.Pick) async {
        #if DEBUG
        if DevHooks.has("-echo.demoRunOn") { return }
        #endif
        guard let backend = CronBackend.current() else { return }
        working = true
        defer { working = false }
        do {
            let atOnce = try await backend.setModel(job, pick)
            if !atOnce { RunOnMarks.noted(job) }
            // A quick job's small model is the one Ahead of Your Day offers next time.
            if RunOn.quickJobs.contains(job.name), !pick.isMain { RunOn.rememberedQuick = pick }
            problem = nil
            await changed()
        } catch {
            picked = old
            problem = error.localizedDescription
        }
    }

    private func takeBack() async {
        guard let backend = CronBackend.current() else { return }
        working = true
        defer { working = false }
        do {
            try await backend.rename(job.id, to: job.name, profile: job.profile)
            RunOnMarks.forget(job)
            await changed()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// When this device marked a job's model for the plugin (Hermes API), so a mark nothing takes up is
/// told after `RunOn.markUnheardAfter`.
enum RunOnMarks {
    private static let key = "runOnMarks"
    private static func id(_ job: CronJob) -> String { (job.profile ?? "") + "/" + job.id }

    static func noted(_ job: CronJob, at now: Date = .now) {
        var marks = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        marks[id(job)] = now.timeIntervalSince1970
        UserDefaults.standard.set(marks, forKey: key)
    }

    static func forget(_ job: CronJob) {
        var marks = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        marks[id(job)] = nil
        UserDefaults.standard.set(marks, forKey: key)
    }

    static func unheard(_ job: CronJob, now: Date = .now) -> Bool {
        guard job.askedModel != nil else { return false }
        let marks = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        // A mark set from another device, or before this one kept them: its time isn't known, so
        // the page waits for the next look rather than call it unheard at once.
        guard let at = marks[id(job)] else { return false }
        return now.timeIntervalSince1970 - at >= RunOn.markUnheardAfter
    }
}

/// Ahead of Your Day's offer, once (Run On): when the server has a small model and quick daily jobs
/// on the main model, "Run quick jobs on <model>" moves Heads-Ups, the Evening Wrap-up and the Week
/// Ahead to it. Taken or put off, it isn't offered again (each job's page still has Run On).
struct QuickJobsOffer: View {
    @State private var small: ModelChoice?
    @State private var targets: [CronJob] = []
    @State private var working = false
    @State private var done = false
    @State private var problem: String?

    var body: some View {
        Group {
            if let small, !targets.isEmpty, !done {
                Section {
                    Button { Task { await use(small) } } label: {
                        Label { Text("Run Quick Jobs on \(small.name)") } icon: { Image(systemName: "hare") }
                    }
                    .disabled(working)
                    Button("Not Now", role: .cancel) { RunOn.quickOffered = true; done = true }
                        .disabled(working)
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                } header: {
                    Text("Quick Jobs")
                } footer: {
                    Text("Heads-Ups, the Evening Wrap-up and the Week Ahead can run on \(small.name), a small model, so they don't wait behind your chats or swap your main model out. Morning Ideas stays on your main model. Change any of them on its own page.")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard !RunOn.quickOffered, let backend = CronBackend.current() else { return }
        guard let jobs = try? await backend.list() else { return }
        let found = RunOn.quickTargets(in: jobs)
        guard !found.isEmpty, let choices = try? await backend.modelOptions(),
              let model = RunOn.smallModel(in: choices) else { return }
        targets = found
        small = model
    }

    private func use(_ model: ModelChoice) async {
        guard let backend = CronBackend.current() else { return }
        working = true
        defer { working = false }
        let pick = RunOn.Pick(model: model.model, provider: model.provider)
        do {
            for job in targets {
                if !(try await backend.setModel(job, pick)) { RunOnMarks.noted(job) }
            }
            RunOn.rememberedQuick = pick
            RunOn.quickOffered = true
            done = true
        } catch {
            problem = error.localizedDescription
        }
    }
}

#if DEBUG
/// `-echo.demoRunOn` (with `-echo.screen wrapUp`): a daily job on a small model of its own, and a
/// made-up model list, for the pictures.
enum RunOnDemo {
    static let choices = [
        ModelChoice(provider: "custom:local", providerName: "Local", model: "qwen3.6-35b-a3b", name: "qwen3.6-35b-a3b", isCurrent: true),
        ModelChoice(provider: "custom:local", providerName: "Local", model: "gemma-3-12b", name: "gemma-3-12b", isCurrent: false),
        ModelChoice(provider: "custom:local", providerName: "Local", model: "qwen3-4b", name: "qwen3-4b", isCurrent: false),
    ]

    static func job(named name: String) -> CronJob? {
        CronJob(.object(["id": .string("demo-\(name.hashValue)"), "name": .string(name), "schedule": .string("0 21 * * *"),
                         "model": .string("qwen3-4b"), "provider": .string("custom:local"),
                         "last_run_at": .string(ISO8601DateFormatter().string(from: .now.addingTimeInterval(-20 * 3600))),
                         "last_status": .string("ok")]))
    }
}
#endif
