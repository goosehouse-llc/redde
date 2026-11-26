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
    /// This Week, Who Does What and Check-in Log (2026-11-25): the plan folded under This Week,
    /// the last check-in's whole report opened, what waits on them opened in the log, an answer of
    /// their own to the check-in's question, and a note for the agent being written.
    @State private var showPlan = false
    @State private var showDetails = false
    @State private var showWaiting = false
    @State private var replying = false
    @State private var reply = ""
    @State private var noteText = ""
    @State private var settings = Settings.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.self) private var environment

    private var goal: GoalReport? { inbox.goals.first { $0.id == goalID } }
    /// Trail or List, picked in the page's Layout menu (2026-11-25), on every device of theirs.
    private var layout: Settings.GoalLayout { settings.goalLayout(forGoal: goalID) }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if let goal {
                    let plan = GoalPlan(steps: goal.steps, cards: cards)
                    switch layout {
                    case .trail: trailPage(goal, plan, proxy: proxy)
                    case .week: weekPage(goal, plan)
                    case .lanes: lanesPage(goal, plan, proxy: proxy)
                    case .log: logPage(goal, plan)
                    case .list:
                        summary(goal, count: plan.count)
                        if goal.goneQuiet { quiet(goal) }
                        needsYou(goal, plan)
                        steps(goal, plan)
                        lastCheckIn(goal)
                        controls(goal)
                    }
                } else if !loading {
                    Text("This goal has ended.", comment: "A goal's page when the goal is gone").foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(layout == .list ? .automatic : .hidden)
            #if os(iOS)
            .listSectionSpacing(layout == .list ? .default : .compact)
            #endif
            .background { if layout != .list, let goal { trailBackdrop(goal) } }
            .safeAreaInset(edge: .bottom) { if layout == .log, let goal { noteComposer(goal) } }
        }
        // The Trail's and Who Does What's own title is large at their top.
        .navigationTitle(layout == .trail || layout == .lanes ? Text(verbatim: "") : Text(goal?.title ?? ""))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem(placement: .primaryAction) { layoutMenu } }
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
        .alert(goal?.question?.text ?? "", isPresented: $replying) {
            TextField(String(localized: "Your answer", comment: "A goal's blocked step: the field for the person's answer"), text: $reply)
            Button(String(localized: "Send", comment: "A goal's plan card: sends the changes asked for")) {
                if let goal { tell(goal, reply, answering: true) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Layout

    private var layoutMenu: some View {
        Menu {
            Picker(selection: Binding(get: { layout }, set: { settings.setGoalLayout($0, forGoal: goalID) })) {
                ForEach(Settings.GoalLayout.allCases, id: \.self) { layout in
                    Label { layout.name } icon: { Image(systemName: layout.symbol) }.tag(layout)
                }
            } label: {
                Text("Layout", comment: "A list's look: how a watch list is drawn")
            }
            .pickerStyle(.inline)
        } label: {
            Label { Text("Layout", comment: "A list's look: how a watch list is drawn") } icon: { Image(systemName: layout.symbol) }
        }
        .accessibilityIdentifier("goal-layout")
    }

    // MARK: Trail

    /// The agent's colour, as the trail draws it: readable as words and line on the page.
    private func trailMark(_ goal: GoalReport) -> (mark: Color, card: FilledCard, face: BotFace) {
        let face = DeckCard.face(profile: goal.profile)
        let tint = BotAvatar.colors(of: face, theme: theme).deep
        return (CardInk.readable(tint, drawnIn: scheme), FilledCard(tint, in: environment), face)
    }

    private func trailBackdrop(_ goal: GoalReport) -> some View {
        let mark = trailMark(goal).mark
        return ZStack(alignment: .top) {
            Color(.systemGroupedBackground)
            LinearGradient(colors: [mark.opacity(scheme == .dark ? 0.34 : 0.22), mark.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 380)
        }
        .ignoresSafeArea()
    }

    /// The Trail layout: the goal large with the days to its date, then its plan as a trail, what
    /// waits on them a card where the trail has got to; under it the last check-in and the controls.
    @ViewBuilder private func trailPage(_ goal: GoalReport, _ plan: GoalPlan, proxy: ScrollViewProxy) -> some View {
        let trail = GoalTrail(plan)
        Section {
            trailHeader(goal, plan, firstWaiting: trail.stops.first { $0.kind == .waiting }?.id, proxy: proxy)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 10, trailing: 20))
                .listRowSeparator(.hidden)
        }
        if goal.goneQuiet { quiet(goal) }
        if trail.stops.isEmpty && trail.folded.isEmpty {
            if !loading {
                Section {
                    Text("The plan shows here once you and your agent have agreed on it.", comment: "A goal's page before it has a plan")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } else {
            Section {
                trailStops(goal, trail)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            if !plan.extra.isEmpty {
                Section {
                    fold(String(localized: "\(agentName(goal))'s own tasks (\(plan.extra.count))", comment: "A goal's page: cards the agent made for itself outside the plan, folded away; the agent's name and how many"),
                         icon: "tray.full", tint: .secondary, open: $showExtra, id: "goal-own-tasks")
                    if showExtra { ForEach(plan.extra) { row in stepRow(goal, row, name: agentName(goal)) } }
                }
            }
        }
        lastCheckIn(goal)
        controls(goal)
    }

    private func trailHeader(_ goal: GoalReport, _ plan: GoalPlan, firstWaiting: String?, proxy: ScrollViewProxy) -> some View {
        let (mark, card, face) = trailMark(goal)
        let count = plan.count ?? (goal.done, goal.total)
        let schedule = job.flatMap { Goals.Schedule(job: $0.schedule) }
        let about = [agentName(goal),
                     count.total > 0 ? String(localized: "\(count.done) of \(count.total) steps done", comment: "VoiceOver: a goal's progress") : nil,
                     schedule?.label].compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 8) {
            Text(goal.title)
                .font(.largeTitle.weight(.heavy))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let target = goal.target {
                let days = GoalTrail.daysLeft(to: target)
                Group {
                    if days > 0 {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: "\(days)")
                                .font(.system(size: 44, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(mark)
                            Text(Self.daysWords(days))
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    } else {
                        Text(days == 0 ? String(localized: "Today's the day", comment: "A goal's trail: its date is today")
                                       : String(localized: "Its date has passed", comment: "A goal's trail: its date was before today"))
                            .font(.title2.weight(.bold))
                            .foregroundStyle(mark)
                    }
                }
                Text(goalBy(target.formatted(date: .long, time: .omitted)))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                BotAvatar(face: face, name: goal.agent, size: 18)
                Text(verbatim: about)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if let firstWaiting {
                let waiting = plan.waiting.count
                Button { withAnimation(.snappy) { proxy.scrollTo(firstWaiting, anchor: .center) } } label: {
                    Label { Text("\(waiting) waiting on you", comment: "A goal's trail: a button down to the steps that wait on the person; how many") } icon: {
                        Image(systemName: "arrow.down")
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(card.ink)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(card.fill, in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .accessibilityIdentifier("goal-trail-waiting")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The trail's rows, in order: "N done" when the start is folded (and what it folds, opened),
    /// then each stop, the line between them the agent's colour as far as the trail has got.
    @ViewBuilder private func trailStops(_ goal: GoalReport, _ trail: GoalTrail) -> some View {
        let (mark, card, face) = trailMark(goal)
        let name = agentName(goal)
        let opened = showDone ? trail.folded.map { GoalTrail.Stop(row: $0, kind: .done) } : []
        let stops = opened + trail.stops
        let lead = trail.folded.isEmpty ? 0 : 1
        let count = lead + stops.count
        let here = lead + opened.count + (trail.here ?? trail.stops.count)
        let ahead = Color.secondary.opacity(0.3)
        let into: (Int) -> Color? = { i in i == 0 ? nil : i <= here ? mark : ahead }
        let out: (Int) -> Color? = { i in i == count - 1 ? nil : i < here ? mark : ahead }
        if lead == 1 {
            TrailStop(markY: 26, into: nil, out: out(0)) {
                TrailMark.folded(card)
            } content: {
                Button { withAnimation(.snappy) { showDone.toggle() } } label: {
                    HStack {
                        Text("\(trail.folded.count) done", comment: "A goal's page: the finished steps, folded away; how many")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(showDone ? 90 : 0))
                    }
                    .frame(minHeight: 52)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("goal-done-steps")
                .accessibilityValue(showDone ? Text("Open", comment: "VoiceOver: a folded list is open") : Text("Closed", comment: "VoiceOver: a folded list is closed"))
            }
        }
        ForEach(Array(stops.enumerated()), id: \.element.id) { n, stop in
            let i = lead + n
            let finish = stop.id == trail.finish && stop.kind != .waiting
            Group {
                if stop.kind == .waiting, let task = stop.row.card {
                    TrailStop(markY: 30, into: into(i), out: out(i)) {
                        TrailMark.waiting(face: face, name: goal.agent, mark: mark)
                    } content: {
                        trailWaiting(stop.row, task, mark: mark, card: card, name: name)
                            .padding(.vertical, 6)
                    }
                } else {
                    TrailStop(markY: 26, into: into(i), out: out(i)) {
                        if finish {
                            TrailMark.finish(done: stop.kind == .done, card)
                        } else {
                            switch stop.kind {
                            case .done: TrailMark.done(card)
                            case .next: TrailMark.next
                            case .agent: TrailMark.agent(mark)
                            default: TrailMark.later
                            }
                        }
                    } content: {
                        trailStep(goal, stop, finish: finish, mark: mark, name: name)
                    }
                }
            }
            .id(stop.id)
        }
    }

    /// A stop that waits on them: why, and the two answers it takes, in a card on the trail.
    private func trailWaiting(_ row: GoalPlan.Row, _ task: KanbanTask, mark: Color, card: FilledCard, name: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                switch task.status {
                case "blocked": Text("\(name) asks", comment: "A goal's trail: over a step the agent is blocked on, waiting for the person's answer; the agent's name")
                case "review": Text("\(name) finished it", comment: "A goal's trail: over a step the agent finished, waiting for the person's look; the agent's name")
                default: Text("Waiting for your OK", comment: "A goal's trail: over a step in Triage, waiting to be approved")
                }
            }
            .font(.caption.weight(.heavy))
            .textCase(.uppercase)
            .foregroundStyle(mark)
            Text(row.title).font(.headline)
            Text(reasons[task.id] ?? Self.waitingWords(task.status))
                .font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    if task.status == "blocked" { changes = ""; answering = true; changing = task } else { approve([task]) }
                } label: {
                    Text(task.status == "blocked" ? String(localized: "Answer", comment: "A goal's blocked step: the button and sheet that answer what the agent is waiting on")
                                                  : approveLabel(task))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(card.ink)
                        .background(card.fill, in: .rect(cornerRadius: 12))
                        .contentShape(.rect(cornerRadius: 12))
                }
                Button {
                    if task.status == "blocked" { approve([task]) } else { changes = ""; answering = false; changing = task }
                } label: {
                    Text(task.status == "blocked" ? String(localized: "Go Ahead", comment: "A goal's blocked step: lets the agent carry on without an answer")
                                                  : String(localized: "Ask for Changes", comment: "A goal's plan card: send it back with what to change"))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.primary.opacity(0.1), in: .rect(cornerRadius: 12))
                        .contentShape(.rect(cornerRadius: 12))
                }
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.top, 8)
            .disabled(working)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(mark.opacity(0.16), in: .rect(cornerRadius: 18, style: .continuous))
    }

    /// A step on the trail: theirs ticked with a tap (the tick taken back the same way), the
    /// agent's with where its card stands, the last one the finish with the goal's date.
    @ViewBuilder private func trailStep(_ goal: GoalReport, _ stop: GoalTrail.Stop, finish: Bool, mark: Color, name: String) -> some View {
        let row = stop.row
        let label = HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(stop.kind == .next || finish ? .headline : .subheadline)
                    .foregroundStyle(stop.kind == .done && !finish ? .secondary : .primary)
                if stop.kind == .next {
                    Text("Next for you", comment: "A goal's trail: under the person's next step").font(.caption.weight(.semibold)).foregroundStyle(mark)
                } else if stop.kind == .agent {
                    Text("\(name) · \(KanbanStatus.label(row.card?.status ?? "todo"))", comment: "A goal's step: the agent's, and where its card stands; the agent's name and a Kanban column")
                        .font(.caption).foregroundStyle(.secondary)
                } else if finish, let target = goal.target {
                    Text(target.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if stop.kind == .next {
                Image(systemName: "circle").font(.title2).foregroundStyle(.secondary)
            } else if stop.kind != .agent, !finish {
                Text(row.yours ? String(localized: "You", comment: "A goal's trail: whose step it is, the person's") : name)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 52)
        .contentShape(.rect)
        if row.yours, let index = row.step {
            Button { tick(goal, index, !row.done) } label: { label }
                .buttonStyle(.plain)
                .disabled(ticking.contains(index))
                .accessibilityIdentifier("goal-step-\(index + 1)")
                .accessibilityValue(row.done ? Text("Done", comment: "VoiceOver: a goal's step is done") : Text("Not done", comment: "VoiceOver: a goal's step isn't done"))
        } else {
            label.accessibilityElement(children: .combine)
        }
    }

    /// "days to go", or "day to go" beside a 1.
    static func daysWords(_ days: Int) -> String {
        days == 1 ? String(localized: "day to go", comment: "A goal's trail: under its count of days to its date, when it's 1")
                  : String(localized: "days to go", comment: "A goal's trail: beside its count of days to its date, e.g. 118 days to go")
    }

    // MARK: This Week

    /// This Week (2026-11-25, the goal mockups' C): the agent's last check-in as a message, their
    /// next step large with I Did It, what the agent asks with its choices as buttons and what else
    /// waits on them, a row of how far, how long and when next, and the whole plan folded.
    @ViewBuilder private func weekPage(_ goal: GoalReport, _ plan: GoalPlan) -> some View {
        let (mark, card, face) = trailMark(goal)
        let name = agentName(goal)
        Section {
            if !goal.headline.isEmpty { weekBubble(goal, face: face, mark: mark, name: name).padding(.top, 4) }
            weekStep(goal, plan, card: card, name: name)
            asks(goal, mark: mark, name: name)
            ForEach(plan.waiting) { row in
                if let task = row.card { trailWaiting(row, task, mark: mark, card: card, name: name) }
            }
            weekStats(goal, plan)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        if goal.goneQuiet { quiet(goal) }
        wholePlan(goal, plan)
        controls(goal)
    }

    /// The last check-in, as a message from the agent; its whole report a tap away.
    private func weekBubble(_ goal: GoalReport, face: BotFace, mark: Color, name: String) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            BotAvatar(face: face, name: goal.agent, size: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text(GoalReport.plain(goal.headline)).font(.body).fixedSize(horizontal: false, vertical: true)
                if showDetails, let details = goal.details {
                    ReportView(text: DayBrief.withoutNarration(details)).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if goal.at > .distantPast {
                        Text("\(name) · \(goal.at, format: .relative(presentation: .named))", comment: "A goal's This Week: under the agent's last check-in; the agent's name and when, e.g. Sol · 5 hours ago")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if goal.details != nil {
                        Spacer()
                        Button { withAnimation(.snappy) { showDetails.toggle() } } label: {
                            Text(showDetails ? String(localized: "Show Less", comment: "A goal's This Week: folds the agent's whole check-in away again")
                                             : String(localized: "Read All", comment: "A goal's This Week: opens the agent's whole last check-in"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(mark)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(mark.opacity(0.18), in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 6, bottomTrailingRadius: 20,
                                                                        topTrailingRadius: 20, style: .continuous))
        }
    }

    /// Their next step, large, in the agent's colour, with I Did It.
    @ViewBuilder private func weekStep(_ goal: GoalReport, _ plan: GoalPlan, card: FilledCard, name: String) -> some View {
        if let next = goal.nextForYou {
            let total = goal.steps?.count ?? 0
            VStack(alignment: .leading, spacing: 6) {
                Text("Your next step", comment: "A goal's This Week: over the person's next step, large")
                    .font(.caption.weight(.heavy)).textCase(.uppercase)
                Text(next.step.title).font(.title.weight(.heavy)).fixedSize(horizontal: false, vertical: true)
                Group {
                    if next.index == total - 1, let target = goal.target {
                        Text(target.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    } else {
                        Text("Step \(next.index + 1) of \(total)", comment: "A goal's This Week: where the person's next step is in the plan")
                    }
                }
                .font(.subheadline.weight(.semibold))
                Button { tick(goal, next.index, true) } label: {
                    Text("I Did It", comment: "A goal's This Week: ticks off the person's next step")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(card.fill)
                        .background(card.ink, in: .rect(cornerRadius: 15, style: .continuous))
                        .contentShape(.rect(cornerRadius: 15))
                }
                .buttonStyle(.plain)
                .disabled(ticking.contains(next.index))
                .padding(.top, 10)
                .accessibilityIdentifier("goal-week-done")
            }
            .foregroundStyle(card.ink)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(card.fill, in: .rect(cornerRadius: 24, style: .continuous))
        } else if plan.isPlan, plan.open.isEmpty, plan.waiting.isEmpty {
            Text("Every step is done.", comment: "A goal's page: nothing left in the plan")
                .font(.title3.weight(.bold))
        }
    }

    /// The check-in's question with its choices as buttons, and Something Else; once answered,
    /// what they said, until the next check-in has heard it.
    @ViewBuilder private func asks(_ goal: GoalReport, mark: Color, name: String) -> some View {
        if let question = goal.question {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(name) asks", comment: "A goal's trail: over a step the agent is blocked on, waiting for the person's answer; the agent's name")
                    .font(.caption.weight(.heavy)).textCase(.uppercase).foregroundStyle(mark)
                Text(question.text).font(.headline).fixedSize(horizontal: false, vertical: true)
                PillFlow(spacing: 8) {
                    ForEach(question.choices, id: \.self) { choice in
                        Button { tell(goal, choice, answering: true) } label: {
                            Text(verbatim: choice)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .frame(minHeight: 40)
                                .overlay { Capsule().strokeBorder(mark, lineWidth: 1.5) }
                                .contentShape(.capsule)
                        }
                    }
                    Button { reply = ""; replying = true } label: {
                        Text("Something Else…", comment: "A goal's question from the agent: answer it in your own words")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 40)
                            .background(Color.primary.opacity(0.1), in: .capsule)
                            .contentShape(.capsule)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                .disabled(working)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
            .accessibilityIdentifier("goal-question")
        } else if let answered = goal.notes?.last(where: { $0.question != nil && $0.at > goal.at }) {
            Label {
                Text("You answered “\(answered.text)”. \(name) hears it at the next check-in.", comment: "A goal's page after the person answered the agent's question; their answer and the agent's name")
            } icon: {
                Image(systemName: "checkmark.bubble").foregroundStyle(mark)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        if let problem {
            Text(problem).font(.footnote).foregroundStyle(.red)
        }
    }

    private func weekStats(_ goal: GoalReport, _ plan: GoalPlan) -> some View {
        let count = plan.count ?? (goal.done, goal.total)
        let days = goal.target.map { GoalTrail.daysLeft(to: $0) }
        let next = job?.state == .scheduled ? job?.nextRunAt : nil
        return HStack(spacing: 10) {
            stat(Text(verbatim: "\(count.done)/\(count.total)"), Text("steps done", comment: "A goal's This Week: under how many of its steps are done, e.g. 3/7"))
            if let days, days >= 0 {
                stat(Text(verbatim: "\(days)"), Text(Self.daysWords(days)))
            }
            if let next {
                stat(Text(next, format: .dateTime.weekday(.abbreviated)), Text("next check-in", comment: "A goal's This Week: under the day the agent checks in next, e.g. Mon"))
            }
        }
    }

    private func stat(_ value: Text, _ label: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            value.font(.title2.weight(.heavy)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            label.font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Every step in its order, folded under This Week; the agent's own cards folded beside it.
    @ViewBuilder private func wholePlan(_ goal: GoalReport, _ plan: GoalPlan) -> some View {
        let name = agentName(goal)
        let rows = plan.isPlan ? (plan.waiting + plan.open + plan.done).filter { $0.step != nil }.sorted { ($0.step ?? 0) < ($1.step ?? 0) }
                               : plan.open + plan.done
        if !rows.isEmpty || !plan.extra.isEmpty {
            Section {
                if !rows.isEmpty {
                    fold(String(localized: "The Whole Plan", comment: "A goal's This Week: every step in its order, folded away"),
                         icon: "list.bullet", tint: .secondary, open: $showPlan, id: "goal-whole-plan")
                    if showPlan { ForEach(rows) { row in stepRow(goal, row, name: name) } }
                }
                if !plan.extra.isEmpty {
                    fold(String(localized: "\(name)'s own tasks (\(plan.extra.count))", comment: "A goal's page: cards the agent made for itself outside the plan, folded away; the agent's name and how many"),
                         icon: "tray.full", tint: .secondary, open: $showExtra, id: "goal-own-tasks")
                    if showExtra { ForEach(plan.extra) { row in stepRow(goal, row, name: name) } }
                }
            }
        }
    }

    private func tell(_ goal: GoalReport, _ text: String, answering: Bool) {
        working = true
        problem = nil
        Task {
            defer { working = false }
            if let why = await Goals.tell(goal, text, answering: answering) { problem = why }
        }
    }

    // MARK: Who Does What

    /// Who Does What (2026-11-25, the goal mockups' D): the plan in its order in two lanes, theirs
    /// and the agent's, so whose turn it is shows as it goes back and forth; a bar of each side's
    /// share done, and what waits on them under it.
    @ViewBuilder private func lanesPage(_ goal: GoalReport, _ plan: GoalPlan, proxy: ScrollViewProxy) -> some View {
        let (mark, _, face) = trailMark(goal)
        let card = trailMark(goal).card
        let name = agentName(goal)
        let stops = GoalTrail(plan, shown: 1_000).stops
        Section {
            lanesHeader(goal, stops: stops, mark: mark, face: face, name: name)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 6, trailing: 20))
            ForEach(stops) { stop in
                laneRow(goal, stop, mark: mark, name: name, proxy: proxy)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        if goal.goneQuiet { quiet(goal) }
        if !plan.waiting.isEmpty {
            Section {
                ForEach(plan.waiting) { row in
                    if let task = row.card { trailWaiting(row, task, mark: mark, card: card, name: name).id(row.id) }
                }
            } header: {
                Text("\(name) is waiting on you", comment: "A goal's Who Does What: over the steps that wait on the person; the agent's name")
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
        if !plan.extra.isEmpty {
            Section {
                fold(String(localized: "\(name)'s own tasks (\(plan.extra.count))", comment: "A goal's page: cards the agent made for itself outside the plan, folded away; the agent's name and how many"),
                     icon: "tray.full", tint: .secondary, open: $showExtra, id: "goal-own-tasks")
                if showExtra { ForEach(plan.extra) { row in stepRow(goal, row, name: name) } }
            }
        }
        lastCheckIn(goal)
        controls(goal)
    }

    private func lanesHeader(_ goal: GoalReport, stops: [GoalTrail.Stop], mark: Color, face: BotFace, name: String) -> some View {
        let planned = stops.filter { $0.row.step != nil }
        let yours = planned.filter(\.row.yours), agents = planned.filter { !$0.row.yours }
        let yoursDone = yours.filter(\.row.done).count, agentsDone = agents.filter(\.row.done).count
        return VStack(alignment: .leading, spacing: 10) {
            Text(goal.title)
                .font(.largeTitle.weight(.heavy))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let target = goal.target {
                let days = GoalTrail.daysLeft(to: target)
                HStack(spacing: 6) {
                    Text(goalBy(target.formatted(date: .long, time: .omitted)))
                    if days > 0 { Text(verbatim: "· \(days) \(Self.daysWords(days))") }
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
            if !planned.isEmpty {
                GeometryReader { space in
                    let gap: CGFloat = 4
                    let whole = max(1, space.size.width - (yours.isEmpty || agents.isEmpty ? 0 : gap))
                    HStack(spacing: gap) {
                        if !yours.isEmpty {
                            share(done: yoursDone, of: yours.count, color: .primary)
                                .frame(width: whole * CGFloat(yours.count) / CGFloat(planned.count))
                        }
                        if !agents.isEmpty {
                            share(done: agentsDone, of: agents.count, color: mark)
                                .frame(width: whole * CGFloat(agents.count) / CGFloat(planned.count))
                        }
                    }
                }
                .frame(height: 10)
                .padding(.top, 4)
                .accessibilityHidden(true)
                HStack {
                    Text("You · \(yoursDone) of \(yours.count)", comment: "A goal's Who Does What: the person's steps done, of theirs")
                    Spacer()
                    Text("\(name) · \(agentsDone) of \(agents.count)", comment: "A goal's Who Does What: the agent's steps done, of its; the agent's name")
                        .foregroundStyle(mark)
                }
                .font(.caption.weight(.semibold))
            }
            HStack(spacing: 24) {
                HStack(spacing: 6) {
                    Image(systemName: "person.fill").font(.system(size: 14))
                    Text("You", comment: "A goal's trail: whose step it is, the person's")
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    BotAvatar(face: face, name: goal.agent, size: 18)
                    Text(verbatim: name)
                }
                .foregroundStyle(mark)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.heavy))
            .textCase(.uppercase)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func share(done: Int, of total: Int, color: Color) -> some View {
        Capsule().fill(color.opacity(0.2))
            .overlay(alignment: .leading) {
                GeometryReader { bar in
                    Capsule().fill(color).frame(width: bar.size.width * CGFloat(done) / CGFloat(max(1, total)))
                }
            }
            .clipShape(.capsule)
    }

    /// A step in its lane, the other lane empty beside it, a line between the two.
    private func laneRow(_ goal: GoalReport, _ stop: GoalTrail.Stop, mark: Color, name: String, proxy: ScrollViewProxy) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Group { if stop.row.yours { laneCard(goal, stop, mark: mark, name: name, proxy: proxy) } else { Color.clear.frame(height: 1) } }
                .frame(maxWidth: .infinity, alignment: .leading)
            Group { if !stop.row.yours { laneCard(goal, stop, mark: mark, name: name, proxy: proxy) } else { Color.clear.frame(height: 1) } }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .background { Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 2).accessibilityHidden(true) }
        .id("lane-" + stop.id)
    }

    @ViewBuilder private func laneCard(_ goal: GoalReport, _ stop: GoalTrail.Stop, mark: Color, name: String, proxy: ScrollViewProxy) -> some View {
        let row = stop.row
        let doneAt = row.step.flatMap { goal.steps?.indices.contains($0) == true ? goal.steps?[$0].at : nil }
        let next = stop.kind == .next
        let face = VStack(alignment: .leading, spacing: 3) {
            Text(row.title)
                .font(.subheadline.weight(.bold))
                .strikethrough(row.done)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                switch stop.kind {
                case .done:
                    if let doneAt {
                        Text("Done \(doneAt.formatted(.dateTime.month(.abbreviated).day()))", comment: "A goal's Who Does What: when a step was done, e.g. Done Nov 2")
                    }
                case .waiting:
                    Text("Waiting on you", comment: "A goal's Who Does What: a step that can't go on without the person").fontWeight(.bold).foregroundStyle(mark)
                case .next:
                    Text("Next for you", comment: "A goal's trail: under the person's next step").fontWeight(.bold)
                case .agent:
                    Text(KanbanStatus.label(row.card?.status ?? "todo"))
                case .later:
                    if row.id == goal.steps.flatMap({ $0.isEmpty ? nil : "step-\($0.count - 1)" }), let target = goal.target {
                        Text(target.formatted(.dateTime.month(.wide).day()))
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(next ? AnyShapeStyle(Color(.systemBackground).opacity(0.8)) : AnyShapeStyle(.secondary))
        }
        .foregroundStyle(next ? AnyShapeStyle(Color(.systemBackground)) : row.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            switch stop.kind {
            case .next: shape.fill(Color.primary)
            case .waiting: shape.fill(mark.opacity(0.16)).overlay { shape.strokeBorder(mark, lineWidth: 2) }
            case .done: shape.fill(Color(.secondarySystemGroupedBackground).opacity(0.7))
            default: shape.fill(Color(.secondarySystemGroupedBackground)).overlay { shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1) }
            }
        }
        .contentShape(.rect(cornerRadius: 14))
        if row.yours, let index = row.step {
            Button { tick(goal, index, !row.done) } label: { face }
                .buttonStyle(.plain)
                .disabled(ticking.contains(index))
                .accessibilityIdentifier("goal-step-\(index + 1)")
                .accessibilityValue(row.done ? Text("Done", comment: "VoiceOver: a goal's step is done") : Text("Not done", comment: "VoiceOver: a goal's step isn't done"))
        } else if stop.kind == .waiting {
            Button { withAnimation(.snappy) { proxy.scrollTo(row.id, anchor: .center) } } label: { face }
                .buttonStyle(.plain)
        } else {
            face.accessibilityElement(children: .combine)
        }
    }

    // MARK: Check-in Log

    /// Check-in Log (2026-11-25, the goal mockups' E): how far along at the top, what waits on
    /// them folded behind one button, then each check-in, what they told the agent and the steps
    /// done, newest first; a field at the bottom to tell the agent how it's going.
    @ViewBuilder private func logPage(_ goal: GoalReport, _ plan: GoalPlan) -> some View {
        let (mark, card, face) = trailMark(goal)
        let name = agentName(goal)
        let count = plan.count ?? (goal.done, goal.total)
        Section {
            HStack(spacing: 12) {
                GoalRing(done: count.done, total: count.total, color: mark, size: 44, showsCount: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count.done) of \(count.total) steps done", comment: "VoiceOver: a goal's progress").font(.headline)
                    let schedule = job.flatMap { Goals.Schedule(job: $0.schedule) }?.label
                    let days = goal.target.map { GoalTrail.daysLeft(to: $0) }
                    let line = [days.flatMap { $0 > 0 ? "\($0) \(Self.daysWords($0))" : nil }, schedule].compactMap { $0 }.joined(separator: " · ")
                    if !line.isEmpty { Text(verbatim: line).font(.subheadline).foregroundStyle(.secondary) }
                }
            }
            if !plan.waiting.isEmpty {
                Button { withAnimation(.snappy) { showWaiting.toggle() } } label: {
                    HStack {
                        Text("\(plan.waiting.count) waiting on you", comment: "A goal's trail: a button down to the steps that wait on the person; how many")
                        Spacer()
                        Image(systemName: "chevron.right").rotationEffect(.degrees(showWaiting ? 90 : 0))
                    }
                    .font(.headline)
                    .foregroundStyle(card.ink)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                    .background(card.fill, in: .rect(cornerRadius: 15, style: .continuous))
                    .contentShape(.rect(cornerRadius: 15))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("goal-log-waiting")
                if showWaiting {
                    ForEach(plan.waiting) { row in
                        if let task = row.card { trailWaiting(row, task, mark: mark, card: card, name: name) }
                    }
                }
            }
            asks(goal, mark: mark, name: name)
            let entries = GoalLog.entries(goal)
            ForEach(entries) { entry in
                logRow(goal, entry, latest: entry.id == entries.first(where: { if case .checkIn = $0.kind { true } else { false } })?.id,
                       face: face, mark: mark, card: card, name: name)
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        if goal.goneQuiet { quiet(goal) }
        controls(goal)
    }

    private func logRow(_ goal: GoalReport, _ entry: GoalLog.Entry, latest: Bool, face: BotFace, mark: Color, card: FilledCard, name: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Text(entry.at, format: .dateTime.weekday(.abbreviated)).font(.caption.weight(.bold)).textCase(.uppercase)
                    .foregroundStyle(latest ? mark : .secondary)
                Text(entry.at, format: .dateTime.day()).font(.title3.weight(.heavy)).monospacedDigit()
            }
            .frame(width: 40)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(entry.at, format: .dateTime.weekday(.wide).month(.wide).day()))
            switch entry.kind {
            case let .checkIn(checkIn):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        BotAvatar(face: face, name: goal.agent, size: 20)
                        Text(GoalReport.plain(checkIn.headline))
                            .font(latest ? .headline : .subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if latest, let details = checkIn.details {
                        ReportView(text: DayBrief.withoutNarration(details)).fixedSize(horizontal: false, vertical: true)
                    }
                    if let next = checkIn.next {
                        Text("Next: \(next)", comment: "A goal's Check-in Log: the next step a check-in named").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(latest ? AnyShapeStyle(mark.opacity(0.18)) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                            in: .rect(cornerRadius: 18, style: .continuous))
            case let .note(note):
                VStack(alignment: .trailing, spacing: 4) {
                    if let asked = note.question {
                        Text(verbatim: asked).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                    Text(verbatim: note.text)
                        .font(.subheadline)
                        .foregroundStyle(card.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(card.fill, in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6,
                                                                          topTrailingRadius: 18, style: .continuous))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 30)
                .accessibilityElement(children: .combine)
            case let .step(title, yours):
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(mark)
                    Text(verbatim: title).font(.subheadline).foregroundStyle(.secondary).strikethrough()
                    Spacer(minLength: 8)
                    Text(yours ? String(localized: "You", comment: "A goal's trail: whose step it is, the person's") : name)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(minHeight: 40)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Check-in Log's field: a note for the agent, kept with the goal for its next check-in.
    private func noteComposer(_ goal: GoalReport) -> some View {
        let empty = noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            TextField(String(localized: "Tell \(agentName(goal)) how it's going", comment: "A goal's Check-in Log: the field for a note to the agent; the agent's name"),
                      text: $noteText, axis: .vertical)
                .lineLimit(1 ... 4)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
                .accessibilityIdentifier("goal-note")
            Button {
                tell(goal, noteText, answering: false)
                noteText = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)).foregroundStyle(empty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(trailMark(goal).mark))
            }
            .buttonStyle(.plain)
            .disabled(empty || working)
            .accessibilityLabel(Text("Send", comment: "A goal's plan card: sends the changes asked for"))
            .accessibilityIdentifier("goal-note-send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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
                        Text(goalBy(target.formatted(date: .long, time: .omitted)))
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
