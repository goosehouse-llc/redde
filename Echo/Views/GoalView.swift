import SwiftUI

/// A goal's page (2.4): how far along it is, what the last check-in said, the plan, and the goal's
/// controls. The plan is the person's steps, a checklist ticked here (plugin 1.35), and the agent's:
/// with the Dashboard login its cards on the Kanban board (tenant `redde-goal-<id>`), one finished
/// (Review) or Blocked looked at or sent back here. Over the Hermes API alone, which has no Kanban,
/// the agent's steps are as the plugin last reported them. On either: Check In Now, Pause, the
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
    /// The person's steps being said to the plugin.
    @State private var ticking: Set<Int> = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    private var goal: GoalReport? { inbox.goals.first { $0.id == goalID } }

    var body: some View {
        List {
            if let goal {
                summary(goal)
                if goal.goneQuiet { quiet(goal) }
                plan(goal)
                lastCheckIn(goal)
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
        }
    }

    /// A goal that went quiet (plugin 1.36): its check-in asked whether they still want it, or
    /// paused for the quiet. Keep Going starts the quiet again; End Goal is the other answer.
    @ViewBuilder private func quiet(_ goal: GoalReport) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(goal.faded == true
                         ? String(localized: "Check-ins paused", comment: "A goal's page: the goal went quiet and its check-ins were paused")
                         : String(localized: "Still want this?", comment: "A goal's page: the goal went quiet and the agent asked whether to keep it"))
                        .font(.headline)
                } icon: { Image(systemName: "moon.zzz") }
                if let days = goal.quietDays {
                    Text("Nothing has happened on this goal for \(days) days.", comment: "A goal's page: how long the goal has been quiet")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            Button { keepGoing(goal) } label: {
                HStack {
                    Label { Text("Keep Going", comment: "A goal's page: keeps a quiet goal, its check-ins running again") } icon: { Image(systemName: "play.circle") }
                    if working { Spacer(); ProgressView() }
                }
            }
            .disabled(working)
            .accessibilityIdentifier("goal-keep-going")
            Button(role: .destructive) { confirmEnd = true } label: {
                Label { Text("End Goal", comment: "A goal's page: the button that ends it") } icon: { Image(systemName: "flag.slash") }
            }
            .disabled(working)
        }
    }

    private func keepGoing(_ goal: GoalReport) {
        working = true
        problem = nil
        Task {
            defer { working = false }
            if let why = await Goals.keep(goal) { problem = why; return }
            await load()
        }
    }

    /// What the last check-in said, under the plan: the steps are what's done here.
    @ViewBuilder private func lastCheckIn(_ goal: GoalReport) -> some View {
        let face = DeckCard.face(profile: goal.profile)
        if !goal.headline.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(GoalReport.plain(goal.headline)).font(.body.weight(.semibold))
                        .foregroundStyle(goal.failed ? .secondary : .primary)
                    if goal.at > .distantPast {
                        Text(goal.at, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                // A check-in kept by Redde before 2026-11-06 has its whole report run into the
                // next step: shown as the report it is, not as a step.
                let runOn = goal.details == nil && (goal.next?.count ?? 0) > 160
                if let next = goal.next, !runOn {
                    nextStep(next, color: BotAvatar.colors(of: face, theme: theme).deep)
                }
                if let details = goal.details ?? (runOn ? goal.next : nil) {
                    ReportView(text: DayBrief.withoutNarration(details)).fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
                }
            } header: {
                Text("Last Check-in", comment: "A goal's page: the section with what the agent last said about it")
            }
        }
    }

    /// The next step, set apart: a small "Next" over the step, its mark at the first line.
    private func nextStep(_ step: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.forward.circle.fill").font(.title3).foregroundStyle(color).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Next", comment: "A goal's page: over the next step the agent named").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary).textCase(.uppercase)
                MarkdownView.styledInline(step, codeFont: .subheadline.monospaced(), accent: color)
                    .font(.subheadline.weight(.medium))
            }
        }
        .padding(.vertical, 2)
    }

    /// The plan in two (2026-11-22, "not sure the current makes sense": every step had been a
    /// card for the agent, so the person's own sat Blocked on the board and nothing could be ticked here):
    /// the person's steps, a checklist to tick, and the agent's, its cards on the board.
    @ViewBuilder private func plan(_ goal: GoalReport) -> some View {
        let steps = goal.steps ?? []
        let yours = steps.enumerated().filter { $0.element.isYours }
        let agents = cards.map { list in list.filter { card in !yours.contains { $0.element.cardID == card.id } } }
        if !yours.isEmpty {
            Section {
                ForEach(yours, id: \.offset) { index, step in
                    Button { tick(goal, index, !step.done) } label: {
                        Label { Text(step.title).strikethrough(step.done).foregroundStyle(step.done ? .secondary : .primary) } icon: {
                            Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(step.done ? .green : .secondary).font(.title3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(ticking.contains(index))
                    .accessibilityIdentifier("goal-step-\(index + 1)")
                    .accessibilityValue(step.done ? Text("Done", comment: "VoiceOver: a goal's step is done") : Text("Not done", comment: "VoiceOver: a goal's step isn't done"))
                }
            } header: {
                Text("Your Steps", comment: "A goal's page: the steps the person does, a checklist")
            } footer: {
                Text("Tap a step when you've done it. At its check-ins your agent asks about the rest.", comment: "A goal's page: under the person's steps")
            }
        }
        let theirs = steps.filter { !$0.isYours }
        if agents?.isEmpty == false || !theirs.isEmpty || (yours.isEmpty && !loading) {
            Section {
                if let agents, !agents.isEmpty {
                    ForEach(agents) { card in cardRow(card) }
                } else if !theirs.isEmpty {
                    ForEach(Array(theirs.enumerated()), id: \.offset) { _, step in
                        Label { Text(step.title).strikethrough(step.done) } icon: {
                            Image(systemName: step.done ? "checkmark.circle.fill" : "circle").foregroundStyle(step.done ? .green : .secondary)
                        }
                    }
                } else if steps.isEmpty {
                    Text("The plan shows here once you and your agent have agreed on it.", comment: "A goal's page before it has a plan")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                if !theirs.isEmpty || agents?.isEmpty == false {
                    Text("\(goal.agent.isEmpty ? Settings.shared.headerTitle : goal.agent)'s Steps", comment: "A goal's page: the steps the agent does itself; the agent's name")
                } else {
                    Text("Plan", comment: "A goal's page: the section with its steps")
                }
            } footer: {
                if !theirs.isEmpty || agents?.isEmpty == false {
                    Text("Your agent works on these on the Kanban board, and asks you to look when one is done.", comment: "A goal's page: under the agent's steps")
                }
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
                        .prominentButton()
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

    private func tick(_ goal: GoalReport, _ index: Int, _ done: Bool) {
        ticking.insert(index)
        problem = nil
        Task {
            defer { ticking.remove(index) }
            if let why = await Goals.tick(goal, step: index, done: done) { problem = why }
        }
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
        switch card.status {
        case "blocked": String(localized: "Unblock", comment: "A goal's plan card: lets a blocked step go on")
        case "review": String(localized: "Looks Good", comment: "A goal's plan card: accepts a step the agent finished")
        default: String(localized: "Approve", comment: "A goal's plan card: lets the agent start on a step, or accepts a finished one")
        }
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
        let firstOpen = steps.firstIndex { !$0.done && !$0.isYours }
        return steps.enumerated().compactMap { i, step in
            guard !step.isYours else { return nil }
            let status = step.done ? "done" : i == firstOpen ? "review" : "ready"
            return KanbanTask(.object(["id": .string(step.cardID ?? "k\(i)"), "title": .string(step.title), "status": .string(status),
                                       "tenant": .string(Goals.tenant(goalID)), "created_at": .number(Double(i))]))
        }
    }
    #endif
}
