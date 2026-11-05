import SwiftUI

/// A goal's page (2.4): how far along it is, what the last check-in said, the plan, and the goal's
/// controls. With the Dashboard login the plan is its cards on the Kanban board (tenant
/// `redde-goal-<id>`), and a card waiting on the person (in Triage before the plan is approved, in
/// Review, or Blocked) is approved or sent back here. Over the Hermes API alone, which has no
/// Kanban, the plan is the steps the plugin last reported. On either: Check In Now, Pause, the
/// check-ins' schedule and End Goal, through the check-in job.
struct GoalView: View {
    let goalID: String
    @State private var inbox = GoalsInbox.shared
    @State private var job: CronJob?
    @State private var cards: [KanbanTask]?
    @State private var loading = true
    @State private var working = false
    @State private var checkingIn = false
    @State private var problem: String?
    @State private var note: String?
    @State private var confirmEnd = false
    @State private var changing: KanbanTask?
    @State private var changes = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    private var goal: GoalReport? { inbox.goals.first { $0.id == goalID } }

    var body: some View {
        List {
            if let goal {
                summary(goal)
                plan(goal)
                controls(goal)
            } else if !loading {
                Text("This goal has ended.", comment: "A goal's page when the goal is gone").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(Text(goal?.title ?? ""))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(String(localized: "End this goal?", comment: "A goal's page: confirming End Goal"),
                            isPresented: $confirmEnd, titleVisibility: .visible) {
            Button(String(localized: "End Goal", comment: "A goal's page: the button that ends it"), role: .destructive) { end() }
        } message: {
            Text("The check-ins stop. Its cards stay on your Kanban board.", comment: "A goal's page: what ending a goal does")
        }
        .alert(String(localized: "Ask for Changes", comment: "A goal's plan card: send it back with what to change"),
               isPresented: Binding(get: { changing != nil }, set: { if !$0 { changing = nil } })) {
            TextField(String(localized: "What to change", comment: "A goal's plan card: the field for the changes asked for"), text: $changes)
            Button(String(localized: "Send", comment: "A goal's plan card: sends the changes asked for")) { if let card = changing { askForChanges(card) } }
            Button("Cancel", role: .cancel) { changing = nil }
        }
    }

    // MARK: Sections

    @ViewBuilder private func summary(_ goal: GoalReport) -> some View {
        let face = DeckCard.face(profile: goal.profile)
        Section {
            HStack(alignment: .center, spacing: 16) {
                GoalRing(done: goal.done, total: goal.total, color: BotAvatar.colors(of: face, theme: theme).deep, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(goal.title).font(.headline)
                    HStack(spacing: 6) {
                        BotAvatar(face: face, name: goal.agent, size: 18)
                        Text(goal.agent.isEmpty ? Settings.shared.headerTitle : goal.agent)
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    if let target = goal.target {
                        Text("By \(target.formatted(date: .long, time: .omitted))", comment: "A goal's page: its target date")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            if !goal.headline.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(goal.headline)
                    if let next = goal.next {
                        Label { Text(next) } icon: { Image(systemName: "arrow.forward.circle.fill") }
                            .font(.subheadline.weight(.semibold))
                    }
                    if goal.at > .distantPast {
                        Text(goal.at, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Last Check-in", comment: "A goal's page: the section with what the agent last said about it")
        }
    }

    @ViewBuilder private func plan(_ goal: GoalReport) -> some View {
        let waiting = (cards ?? []).filter { $0.status == "triage" }
        Section {
            if let cards {
                if cards.isEmpty {
                    Text("No plan yet. Your agent puts its steps on your Kanban board once you've talked it through.",
                         comment: "A goal's page: no plan cards on the board yet").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(cards) { card in cardRow(card) }
            } else if let steps = goal.steps, !steps.isEmpty {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    Label { Text(step.title).strikethrough(step.done) } icon: {
                        Image(systemName: step.done ? "checkmark.circle.fill" : "circle").foregroundStyle(step.done ? .green : .secondary)
                    }
                }
            } else if !loading {
                Text("The plan shows here after the first check-in.", comment: "A goal's page over the Hermes API, before any steps were reported")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Plan", comment: "A goal's page: the section with its steps")
                Spacer()
                if waiting.count > 1 {
                    Button { approve(waiting) } label: { Text("Approve All", comment: "A goal's page: approves every plan card waiting in Triage") }
                        .buttonStyle(.borderless)
                        .disabled(working)
                }
            }
        } footer: {
            if cards == nil, !KanbanClient.isAvailable {
                Text("Approving steps from Redde takes the Hermes Dashboard login. Over the Hermes API, answer your agent in the goal's chat.",
                     comment: "A goal's page: the plan without Kanban")
            } else if !waiting.isEmpty {
                Text("Steps in Triage wait for your OK before your agent starts on them.", comment: "A goal's page: under a plan with cards to approve")
            }
        }
    }

    private func cardRow(_ card: KanbanTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label { Text(card.title).strikethrough(card.status == "done") } icon: {
                Image(systemName: KanbanStatus.icon(card.status)).foregroundStyle(card.status == "done" ? .green : .secondary)
            }
            if waitsOnPerson(card) {
                HStack(spacing: 10) {
                    Button { approve([card]) } label: { Text(approveLabel(card)) }
                        .buttonStyle(.borderedProminent)
                    Button { changes = ""; changing = card } label: {
                        Text("Ask for Changes", comment: "A goal's plan card: send it back with what to change")
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
                .disabled(working)
            } else if card.status != "done" {
                Text(KanbanStatus.label(card.status)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func controls(_ goal: GoalReport) -> some View {
        Section {
            if let job {
                Button { checkIn(job) } label: {
                    HStack {
                        Label { Text("Check In Now", comment: "A goal's page: runs the check-in now") } icon: { Image(systemName: "arrow.clockwise") }
                        if checkingIn { Spacer(); ProgressView() }
                    }
                }
                .disabled(checkingIn || working)
                Picker(selection: Binding(get: { Goals.Schedule(job: job.schedule) }, set: { if let s = $0 { reschedule(job, to: s) } })) {
                    if Goals.Schedule(job: job.schedule) == nil { Text(job.schedule).tag(Goals.Schedule?.none) }
                    ForEach(Goals.Schedule.allCases) { Text($0.label).tag(Goals.Schedule?.some($0)) }
                } label: {
                    Label { Text("Check-ins", comment: "New Goal: how often the agent checks in") } icon: { Image(systemName: "calendar.badge.clock") }
                }
                .disabled(working)
                Toggle(isOn: Binding(get: { job.state == .paused }, set: { pause(job, $0) })) {
                    Label { Text("Pause Check-ins", comment: "A goal's page: pauses its check-in job") } icon: { Image(systemName: "pause.circle") }
                }
                .disabled(working)
            }
            Button(role: .destructive) { confirmEnd = true } label: {
                Label { Text("End Goal", comment: "A goal's page: the button that ends it") } icon: { Image(systemName: "flag.slash") }
            }
            .disabled(working)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let next = job?.nextRunAt, job?.state == .scheduled {
                    Text("Next check-in \(next.formatted(date: .abbreviated, time: .shortened)).", comment: "A goal's page: when the agent checks in next")
                }
                if job == nil, !loading {
                    Text("Redde can't see this goal's check-ins on this connection.", comment: "A goal's page: the check-in job wasn't found")
                }
                if let note { Text(note) }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
        }
    }

    // MARK: Kanban

    private func waitsOnPerson(_ card: KanbanTask) -> Bool { ["triage", "review", "blocked"].contains(card.status) }

    private func approveLabel(_ card: KanbanTask) -> String {
        card.status == "blocked" ? String(localized: "Unblock", comment: "A goal's plan card: lets a blocked step go on")
            : String(localized: "Approve", comment: "A goal's plan card: lets the agent start on a step, or accepts a finished one")
    }

    /// Triage → To do (Ready when an agent is on it, so the board starts it); Review → Done;
    /// Blocked → Ready.
    private func approve(_ list: [KanbanTask]) {
        working = true
        Task {
            defer { working = false }
            do {
                for card in list {
                    switch card.status {
                    case "review": try await KanbanClient.move(card.id, to: "done", summary: "Approved in Redde")
                    case "blocked": try await KanbanClient.move(card.id, to: "ready")
                    default: try await KanbanClient.move(card.id, to: card.assignee?.isEmpty == false ? "ready" : "todo")
                    }
                }
                await loadCards()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// A comment with what to change; a step in Review or Blocked goes back to Ready to be done
    /// again, one in Triage stays there for the agent to rework at its next check-in.
    private func askForChanges(_ card: KanbanTask) {
        let text = changes.trimmingCharacters(in: .whitespacesAndNewlines)
        changing = nil
        guard !text.isEmpty else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await KanbanClient.comment(card.id, text)
                if card.status == "review" || card.status == "blocked" { try await KanbanClient.move(card.id, to: "ready") }
                await loadCards()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    // MARK: Job

    private func checkIn(_ job: CronJob) {
        checkingIn = true
        problem = nil
        note = nil
        Task {
            defer { checkingIn = false }
            #if DEBUG
            if Goals.demo { return }
            #endif
            guard let backend = CronBackend.current() else { return }
            do {
                // The Dashboard waits for the run; the Hermes API starts it and answers at once.
                try await backend.runNow(job.id, profile: job.profile)
                if case .apiServer = backend {
                    note = String(localized: "Asked. The check-in comes as a notification when it's done.", comment: "A goal's page: Check In Now over the Hermes API")
                }
                await load()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func reschedule(_ job: CronJob, to schedule: Goals.Schedule) {
        guard schedule.rawValue != job.schedule else { return }
        change { backend in
            try await backend.update(job.id, name: job.name, schedule: schedule.rawValue, prompt: job.prompt, deliver: job.deliver, profile: job.profile)
        }
    }

    private func pause(_ job: CronJob, _ paused: Bool) {
        change { backend in try await backend.setPaused(job.id, paused, profile: job.profile) }
    }

    private func change(_ act: @escaping (CronBackend) async throws -> Void) {
        #if DEBUG
        if Goals.demo { return }
        #endif
        guard let backend = CronBackend.current() else { return }
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                try await act(backend)
                await load()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// The job goes (when there is one to reach), the goal off this device's list, and the page.
    private func end() {
        let job = job
        working = true
        Task {
            defer { working = false }
            #if DEBUG
            if Goals.demo { inbox.end(goalID); dismiss(); return }
            #endif
            if let job {
                do {
                    try await CronBackend.current()?.delete(job.id, profile: job.profile)
                } catch {
                    problem = error.localizedDescription
                    return
                }
            }
            inbox.end(goalID)
            dismiss()
        }
    }

    // MARK: Loading

    private func load() async {
        let jobs = await Goals.refresh()
        if let goal { job = Goals.job(of: goal, in: jobs) }
        await loadCards()
        loading = false
    }

    private func loadCards() async {
        #if DEBUG
        if Goals.demo { cards = demoCards(); return }
        #endif
        guard KanbanClient.isAvailable, let board = try? await KanbanClient.board() else { cards = nil; return }
        let tenant = Goals.tenant(goalID)
        cards = board.columns.flatMap(\.tasks).filter { $0.tenant == tenant && $0.status != "archived" }
            .sorted { (Self.order[$0.status] ?? 9, $0.createdAt ?? .distantPast) < (Self.order[$1.status] ?? 9, $1.createdAt ?? .distantPast) }
    }

    /// Done first, then what is being worked on, then what waits: the plan read top to bottom.
    private static let order = ["done": 0, "review": 1, "running": 2, "blocked": 3, "ready": 4, "todo": 5, "scheduled": 6, "triage": 7]

    #if DEBUG
    private func demoCards() -> [KanbanTask] {
        let steps = goal?.steps ?? []
        let firstOpen = steps.firstIndex { !$0.done }
        return steps.enumerated().compactMap { i, step in
            let status = step.done ? "done" : i == firstOpen ? "review" : "triage"
            return KanbanTask(.object(["id": .string(step.cardID ?? "k\(i)"), "title": .string(step.title), "status": .string(status),
                                       "tenant": .string(Goals.tenant(goalID)), "created_at": .number(Double(i))]))
        }
    }
    #endif
}
