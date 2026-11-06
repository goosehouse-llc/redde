import SwiftUI

/// "Goals", at the top of the chat list (2.4): a card for each of the two goals checked in on
/// last, with how far along it is, what the last check-in said and the next step. Drawn from
/// `GoalsInbox` alone, which reads the app group: the list never waits on the server for it, and
/// nothing on it moves, so scrolling the chats costs nothing more. A tap opens the goal.
struct GoalsSection: View {
    /// A goal's card was tapped, or New Goal: the chat list shows the sheets, outside the list's rows.
    let open: (GoalReport) -> Void
    let add: () -> Void
    @State private var inbox = GoalsInbox.shared
    @AppStorage(ChatListCard.goals.foldKey) private var isOpen = true

    var body: some View {
        if !inbox.onList.isEmpty {
            Section {
                if isOpen {
                    VStack(spacing: 10) {
                        ForEach(inbox.onList) { goal in
                            Button { open(goal) } label: { GoalCard(goal: goal) }
                                .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } header: {
                FoldingHeader(title: ChatListCard.goals.title, count: inbox.onList.count, isOpen: $isOpen) {
                    Button { add() } label: {
                        Label { Text("New Goal", comment: "Button: opens the sheet to set a new goal") } icon: { Image(systemName: "plus") }
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

extension GoalCard {
    /// A bot whose colour is a pale one (Sol's ink in Paper White) would leave the card white on
    /// white and its ring unseen: the theme's accent stands in.
    static func readable(_ color: Color, or fallback: Color, in environment: EnvironmentValues) -> Color {
        let luminance = luminance(of: color, in: environment)
        return luminance > 0.5 ? fallback : color
    }

    /// The ring's and the flag's colour, on the card's near-white: the agent's own, darkened
    /// until it stands out (2026-11-04: Sol's pale sky ring and flag could hardly be seen).
    static func ringColor(_ color: Color, in environment: EnvironmentValues) -> Color {
        var shade = color
        for _ in 0 ..< 6 where luminance(of: shade, in: environment) > 0.18 {
            shade = shade.mix(with: .black, by: 0.18)
        }
        return shade
    }

    static func luminance(of color: Color, in environment: EnvironmentValues) -> Double {
        let c = color.resolve(in: environment)
        func lin(_ v: Float) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.red) + 0.7152 * lin(c.green) + 0.0722 * lin(c.blue)
    }
}

/// One goal on a card: its ring of steps done, its words, the last check-in's line and the next
/// step, on a pastel of its agent's colour, as an idea's card is.
struct GoalCard: View {
    let goal: GoalReport
    @Environment(\.theme) private var theme
    @Environment(\.self) private var environment

    var body: some View {
        let face = DeckCard.face(profile: goal.profile)
        let deep = Self.readable(BotAvatar.colors(of: face, theme: theme).deep, or: theme.accent, in: environment)
        HStack(alignment: .top, spacing: 14) {
            GoalRing(done: goal.done, total: goal.total, color: Self.ringColor(deep, in: environment), size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(goal.title)
                    .chatFont(.headline, weight: .bold, design: .rounded)
                    .lineLimit(2)
                if !goal.headline.isEmpty {
                    Text(goal.headline).chatFont(.subheadline).opacity(goal.failed ? 0.6 : 0.8).lineLimit(2)
                } else {
                    Text("No check-in yet", comment: "A goal's card before its agent first checked in").chatFont(.subheadline).opacity(0.6)
                }
                if let next = goal.next {
                    Label { Text(next).lineLimit(1) } icon: { Image(systemName: "arrow.forward.circle.fill") }
                        .chatFont(.footnote, weight: .semibold)
                        .labelStyle(GoalNextLabel())
                }
                HStack(spacing: 6) {
                    BotAvatar(face: face, name: goal.agent, size: 16)
                    Text(goal.agent.isEmpty ? Settings.shared.headerTitle : goal.agent)
                    if let target = goal.target {
                        Text(verbatim: "·")
                        Text("By \(target.formatted(.dateTime.month(.abbreviated).day()))", comment: "A goal's card: its target date, e.g. By Mar 1")
                    }
                }
                .font(.caption)
                .opacity(0.7)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(DeckCard.ink)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [deep.mix(with: .white, by: 0.84), deep.mix(with: .white, by: 0.68)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: .rect(cornerRadius: 20))
        .contentShape(.rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens the goal", comment: "VoiceOver hint on a goal's card"))
    }
}

/// The next step's arrow close to its words.
private struct GoalNextLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

/// Steps done of all of them, as a ring with the count inside. Drawn once; it doesn't animate.
struct GoalRing: View {
    let done: Int
    let total: Int
    let color: Color
    var size: CGFloat = 52

    var body: some View {
        let fraction = total > 0 ? min(1, Double(done) / Double(total)) : 0
        ZStack {
            Circle().stroke(color.opacity(0.22), lineWidth: size * 0.12)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if total > 0 {
                Text(verbatim: "\(done)/\(total)")
                    .font(.system(size: size * 0.27, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
            } else {
                Image(systemName: "flag.fill").font(.system(size: size * 0.3)).foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(total > 0 ? Text("\(done) of \(total) steps done", comment: "VoiceOver: a goal's progress")
                                      : Text("No plan yet", comment: "VoiceOver: a goal's progress before it has steps"))
    }
}

/// A new goal (2.4): the goal in the person's words, by when, how often to check in and which
/// agent. Start opens that agent's chat with it written out (`Goals.ask`), where the agent makes
/// the plan and asks before it starts, so the goal is set up the same way as one said in a chat.
struct NewGoalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var goal = ""
    @State private var hasTarget = false
    @State private var target = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now
    @State private var schedule = Goals.Schedule.weekly
    /// Picked by hand: a date chosen later no longer changes it.
    @State private var schedulePicked = false
    @State private var profile = "default"
    @FocusState private var focused: Bool

    private var bots: [HermesBot] { (BotDirectory.shared.roster?.bots ?? []).filter { !$0.isDefault && !$0.isHidden } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Run a 10K by March", comment: "New Goal: the example in the empty goal field"),
                              text: $goal, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($focused)
                } header: {
                    Text("Your Goal", comment: "New Goal: the section for the goal's words")
                } footer: {
                    Text("Your agent makes a plan of steps on your Kanban board and asks you before it starts on them.",
                         comment: "New Goal: under the goal's words")
                }
                Section {
                    Toggle(String(localized: "By a Date", comment: "New Goal: the goal has a target date"), isOn: $hasTarget.animation())
                    if hasTarget {
                        DatePicker(String(localized: "Date", comment: "New Goal: the target date"), selection: $target,
                                   in: Date.now..., displayedComponents: .date)
                    }
                    Picker(String(localized: "Check-ins", comment: "New Goal: how often the agent checks in"), selection: Binding(
                        get: { schedule }, set: { schedule = $0; schedulePicked = true })) {
                        ForEach(Goals.Schedule.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("Each check-in comes as a notification, and the goal's card at the top of your chats shows how far along it is.",
                         comment: "New Goal: under the date and the check-ins")
                }
                if !bots.isEmpty {
                    Section {
                        Picker(String(localized: "Agent", comment: "New Goal: which agent looks after the goal"), selection: $profile) {
                            Text(Settings.shared.headerTitle).tag("default")
                            ForEach(bots, id: \.name) { Text($0.label(mainName: Settings.shared.headerTitle)).tag($0.name) }
                        }
                    }
                }
            }
            .navigationTitle(Text("New Goal", comment: "The New Goal sheet's title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { start() } label: { Text("Start", comment: "New Goal: sends the goal to the agent") }
                        .fontWeight(.semibold)
                        .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: hasTarget) { suggest() }
            .onChange(of: target) { suggest() }
            .onAppear { focused = true }
        }
    }

    /// His default (2026-11-02): weekly; every other day for a goal less than two weeks away.
    private func suggest() {
        guard !schedulePicked else { return }
        schedule = Goals.Schedule.suggested(by: hasTarget ? target : nil)
    }

    private func start() {
        let message = Goals.ask(goal: goal, by: hasTarget ? target : nil, schedule: schedule)
        LaunchRouter.shared.requestGoalChat(profile: profile, message: message)
        dismiss()
    }
}

/// Settings → Your Day → Goals: every goal, and New Goal.
struct GoalsListView: View {
    @State private var inbox = GoalsInbox.shared
    @State private var adding = false
    @State private var loading = true

    var body: some View {
        List {
            Section {
                if inbox.goals.isEmpty, !loading {
                    Text("Name something you want to get done, and your agent turns it into a plan, checks in on a schedule and keeps track of how far along you are. Say it in any chat, or tap New Goal.",
                         comment: "Goals: the page before any goal is set")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(inbox.goals) { goal in
                    NavigationLink { GoalView(goalID: goal.id) } label: {
                        HStack(spacing: 12) {
                            GoalRing(done: goal.done, total: goal.total, color: .accentColor, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(goal.title).lineLimit(2)
                                if !goal.headline.isEmpty {
                                    Text(goal.headline).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            } footer: {
                if loading { ProgressView() }
            }
            Section {
                Button { adding = true } label: { Label { Text("New Goal", comment: "Button: opens the sheet to set a new goal") } icon: { Image(systemName: "plus") } }
            }
        }
        .navigationTitle(Text("Goals", comment: "The chat list's section of the person's goals, and its page in Settings"))
        .sheet(isPresented: $adding) { NewGoalSheet() }
        .task { await Goals.refresh(); loading = false }
        .refreshable { await Goals.refresh() }
    }
}
