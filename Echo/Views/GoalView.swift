import SwiftUI

/// A goal's page (2.4): how far along it is, what waits on the person, the plan, what the last
/// check-in said, and the goal's controls. The plan is the goal's steps in their order (`GoalPlan`):
/// the person's, ticked here (plugin 1.35), and the agent's, with the Dashboard login its cards on
/// the Kanban board (tenant `redde-goal-<id>`). One Blocked is answered or let go ahead, one finished
/// (Review) looked at or sent back, in Needs You at the top with why it waits. Over the Hermes API alone, which has no Kanban,
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
    /// The words go to a Blocked card as an answer, not as changes asked for.
    @State private var answering = false
    /// Why each card waiting on the person waits: its block reason, or what it finished.
    @State private var reasons: [String: String] = [:]
    @State private var showDone = false
    @State private var showExtra = false
    /// The person's steps being said to the plugin.
    @State private var ticking: Set<Int> = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    private var goal: GoalReport? { inbox.goals.first { $0.id == goalID } }

    var body: some View {
        List {
            if let goal {
                let plan = GoalPlan(steps: goal.steps, cards: cards)
                summary(goal, count: plan.count)
                if goal.goneQuiet { quiet(goal) }
                needsYou(goal, plan)
                steps(goal, plan)
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
        .alert(answering ? String(localized: "Answer", comment: "A goal's blocked step: the button and sheet that answer what the agent is waiting on")
                         : String(localized: "Ask for Changes", comment: "A goal's plan card: send it back with what to change"),
               isPresented: Binding(get: { changing != nil }, set: { if !$0 { changing = nil } })) {
            TextField(answering ? String(localized: "Your answer", comment: "A goal's blocked step: the field for the person's answer")
                                : String(localized: "What to change", comment: "A goal's plan card: the field for the changes asked for"), text: $changes)
            Button(String(localized: "Send", comment: "A goal's plan card: sends the changes asked for")) { if let card = changing { askForChanges(card) } }
            Button("Cancel", role: .cancel) { changing = nil }
        }
    }

    // MARK: Sections

    @ViewBuilder private func summary(_ goal: GoalReport, count: (done: Int, total: Int)?) -> some View {
        let face = DeckCard.face(profile: goal.profile)
        Section {
            HStack(alignment: .center, spacing: 16) {
                GoalRing(done: count?.done ?? goal.done, total: count?.total ?? goal.total, color: BotAvatar.colors(of: face, theme: theme).deep, size: 64)
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

    private func agentName(_ goal: GoalReport) -> String { goal.agent.isEmpty ? Settings.shared.headerTitle : goal.agent }

    /// What can't go on without the person, first (2026-11-22: two Blocked steps sat under eight
    /// struck-through ones with Unblock and no reason): each with why it waits, and buttons that
    /// say what they do.
    @ViewBuilder private func needsYou(_ goal: GoalReport, _ plan: GoalPlan) -> some View {
        if !plan.waiting.isEmpty {
            Section {
                ForEach(plan.waiting) { row in
                    if let card = row.card { waitingRow(row, card) }
                }
            } header: {
                Text("Needs You", comment: "A goal's page: the steps waiting on the person")
            } footer: {
                Text("\(agentName(goal)) can't go on with these without you.", comment: "A goal's page: under the steps waiting on the person; the agent's name")
            }
        }
    }

    private func waitingRow(_ row: GoalPlan.Row, _ card: KanbanTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label { Text(row.title).font(.body.weight(.medium)) } icon: {
                Image(systemName: KanbanStatus.icon(card.status)).foregroundStyle(.orange)
            }
            Text(reasons[card.id] ?? Self.waitingWords(card.status))
                .font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(6)
                .padding(.leading, 34)
            HStack(spacing: 10) {
                if card.status == "blocked" {
                    Button { changes = ""; answering = true; changing = card } label: {
                        Text("Answer", comment: "A goal's blocked step: the button and sheet that answer what the agent is waiting on")
                    }
                    .prominentButton()
                    Button { approve([card]) } label: {
                        Text("Go Ahead", comment: "A goal's blocked step: lets the agent carry on without an answer")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button { approve([card]) } label: { Text(approveLabel(card)) }
                        .prominentButton()
                    Button { changes = ""; answering = false; changing = card } label: {
                        Text("Ask for Changes", comment: "A goal's plan card: send it back with what to change")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
            .padding(.leading, 34)
            .disabled(working)
        }
        .padding(.vertical, 2)
    }

    /// What a waiting card says when its reason couldn't be read.
    static func waitingWords(_ status: String) -> String {
        switch status {
        case "blocked": String(localized: "Waiting on you. Answer, or let it go ahead.", comment: "A goal's blocked step with no reason given")
        case "review": String(localized: "Finished: have a look.", comment: "A goal's step the agent finished, waiting for the person's look")
        default: String(localized: "Waiting for your OK to start.", comment: "A goal's step in Triage, waiting to be approved")
        }
    }

    /// The plan, in its order: the person's steps to tick, the agent's with how each stands.
    /// Finished steps, and the agent's own cards outside the plan, fold away beneath.
    @ViewBuilder private func steps(_ goal: GoalReport, _ plan: GoalPlan) -> some View {
        let name = agentName(goal)
        if plan.open.isEmpty && plan.done.isEmpty && plan.waiting.isEmpty && plan.extra.isEmpty {
            if !loading {
                Section {
                    Text("The plan shows here once you and your agent have agreed on it.", comment: "A goal's page before it has a plan")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Plan", comment: "A goal's page: the section with its steps") }
            }
        } else {
            Section {
                ForEach(plan.open) { row in stepRow(goal, row, name: name) }
                if plan.open.isEmpty {
                    Text(plan.waiting.isEmpty ? String(localized: "Every step is done.", comment: "A goal's page: nothing left in the plan")
                                              : String(localized: "Only what needs you is left.", comment: "A goal's page: the open steps all wait on the person"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if !plan.done.isEmpty {
                    fold(String(localized: "\(plan.done.count) done", comment: "A goal's page: the finished steps, folded away; how many"),
                         icon: "checkmark.circle", tint: .green, open: $showDone, id: "goal-done-steps")
                    if showDone { ForEach(plan.done) { row in stepRow(goal, row, name: name) } }
                }
                if !plan.extra.isEmpty {
                    fold(String(localized: "\(name)'s own tasks (\(plan.extra.count))", comment: "A goal's page: cards the agent made for itself outside the plan, folded away; the agent's name and how many"),
                         icon: "tray.full", tint: .secondary, open: $showExtra, id: "goal-own-tasks")
                    if showExtra { ForEach(plan.extra) { row in stepRow(goal, row, name: name) } }
                }
            } header: {
                Text(plan.isPlan ? String(localized: "Plan", comment: "A goal's page: the section with its steps")
                                 : String(localized: "\(name)'s Tasks", comment: "A goal's page: the agent's cards for a goal with no plan from the plugin; the agent's name"))
            } footer: {
                Text(plan.isPlan ? String(localized: "Tap your steps when you've done them. \(name) works on its own on the Kanban board and asks about yours at check-ins.", comment: "A goal's page: under the plan; the agent's name")
                                 : String(localized: "Your agent works on these on the Kanban board, and asks you to look when one is done.", comment: "A goal's page: under the agent's steps"))
            }
        }
    }

    /// A row that opens what's folded beneath it.
    private func fold(_ title: String, icon: String, tint: Color, open: Binding<Bool>, id: String) -> some View {
        Button { withAnimation(.snappy) { open.wrappedValue.toggle() } } label: {
            HStack {
                Label { Text(title).foregroundStyle(.primary) } icon: { Image(systemName: icon).foregroundStyle(tint).font(.title3) }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityValue(open.wrappedValue ? Text("Open", comment: "VoiceOver: a folded list is open") : Text("Closed", comment: "VoiceOver: a folded list is closed"))
    }

    @ViewBuilder private func stepRow(_ goal: GoalReport, _ row: GoalPlan.Row, name: String) -> some View {
        if row.yours, let index = row.step {
            Button { tick(goal, index, !row.done) } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).strikethrough(row.done).foregroundStyle(row.done ? .secondary : .primary)
                        if !row.done {
                            Text("Yours", comment: "A goal's step: the person's to do").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: row.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(row.done ? .green : .secondary).font(.title3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(ticking.contains(index))
            .accessibilityIdentifier("goal-step-\(index + 1)")
            .accessibilityValue(row.done ? Text("Done", comment: "VoiceOver: a goal's step is done") : Text("Not done", comment: "VoiceOver: a goal's step isn't done"))
        } else {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).strikethrough(row.done).foregroundStyle(row.done ? .secondary : .primary)
                    if !row.done {
                        Text("\(name) · \(KanbanStatus.label(row.card?.status ?? "todo"))", comment: "A goal's step: the agent's, and where its card stands; the agent's name and a Kanban column")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: row.done ? "checkmark.circle.fill" : KanbanStatus.icon(row.card?.status ?? "todo"))
                    .foregroundStyle(row.done ? .green : .secondary).font(.title3)
            }
        }
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
        if Goals.demo {
            cards = demoCards()
            reasons = ["kpace": "Which pace do you want on race day: 6:00/km to finish comfortably, or 5:40/km for a time under an hour?"]
            return
        }
        #endif
        guard KanbanClient.isAvailable, let board = try? await KanbanClient.board() else { cards = nil; return }
        let tenant = Goals.tenant(goalID)
        let found = board.columns.flatMap(\.tasks).filter { $0.tenant == tenant && $0.status != "archived" }
        cards = found
        // Why each waits: a Blocked card's reason, what a card in Review finished (a few, read at once).
        let waiting = found.filter { ["blocked", "review"].contains($0.status) }.prefix(8)
        var said: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for card in waiting {
                group.addTask {
                    let reason = (try? await KanbanClient.detail(card.id))?.waitingReason?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (card.id, reason?.isEmpty == false ? reason : nil)
                }
            }
            for await (id, reason) in group { if let reason { said[id] = reason } }
        }
        reasons = said
    }

    #if DEBUG
    private func demoCards() -> [KanbanTask] {
        let steps = goal?.steps ?? []
        let firstOpen = steps.firstIndex { !$0.done && !$0.isYours }
        return steps.enumerated().compactMap { i, step in
            guard !step.isYours else { return nil }
            let status = step.done ? "done" : i == firstOpen ? "review" : "ready"
            return KanbanTask(.object(["id": .string(step.cardID ?? "k\(i)"), "title": .string(step.title), "status": .string(status),
                                       "tenant": .string(Goals.tenant(goalID)), "created_at": .number(Double(i))]))
        } + (goalID == "g10k" ? [  // the agent's own cards beside the plan: one waits on the person, two are done
            ("kpace", "Choose a race-day pace", "blocked"), ("krem", "Set a reminder for Saturday's long run", "done"),
            ("klog", "Log this week's runs", "done"),
        ].enumerated().compactMap { n, card in
            KanbanTask(.object(["id": .string(card.0), "title": .string(card.1), "status": .string(card.2),
                                "tenant": .string(Goals.tenant(goalID)), "created_at": .number(Double(20 + n))]))
        } : [])
    }
    #endif
}
