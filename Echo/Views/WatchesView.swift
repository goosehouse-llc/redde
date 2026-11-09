import SwiftUI

/// Watches and follow-ups (asked 2026-10-28, after Meta's Muse): Hermes cron jobs Redde names with
/// a tag so it can find them again. A watch, `[redde-watch:<id>]`, has the main agent look at
/// something on a schedule and say what changed, which Redde's plugin sends to the phone (1.9,
/// `watches.py`); a follow-up, `[redde-followup:<id>]`, is one the agent set itself for a loose
/// end, and comes back once as an idea card (`followups.py`). On either connection, as scheduled
/// jobs are.
enum Watches {
    static let watchTag = "[redde-watch:"
    static let followUpTag = "[redde-followup:"

    enum Often: String, CaseIterable, Identifiable {
        case quarter = "*/15 * * * *", half = "*/30 * * * *", hourly = "0 * * * *", fourHours = "0 */4 * * *", morning = "0 8 * * *"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .quarter: String(localized: "Every 15 minutes")
            case .half: String(localized: "Every 30 minutes")
            case .hourly: String(localized: "Every hour")
            case .fourHours: String(localized: "Every 4 hours")
            case .morning: String(localized: "Every morning")
            }
        }
    }

    /// What happens when it sees a change (asked 2026-10-28, "bots that bring each other in"): the
    /// person is told, or called, or another agent is handed it, in its Bot Chat, to act on
    /// (`deliver: bot-chat:<profile>`; the watch answers [SILENT] when nothing changed, which
    /// Hermes delivers nowhere).
    enum Then: Hashable {
        case tell, call
        /// An agent's profile ("default", the main one), and what it is called.
        case hand(String, String)

        var deliver: String {
            if case let .hand(profile, _) = self { return "bot-chat:" + profile }
            return "local"
        }
    }

    /// What the agent is asked each time: look, and say NOTHING NEW or what changed. What it says
    /// is what the person is sent (the plugin tells it, as the run starts, what it said last), or
    /// what the agent it is handed to is given.
    static func prompt(_ id: String, what: String, then: Then = .tell) -> String {
        switch then {
        case .tell:
            """
            \(watchTag)\(id)] Watch, for the user: \(what). Check it now with your tools. If nothing has changed since \
            last time in a way they would want to know, answer with exactly NOTHING NEW. Otherwise answer with one or \
            two short lines saying what changed: that is what they are sent. If it can't wait and you may call them, \
            you can also use call_user.
            """
        case .call:
            """
            \(watchTag)\(id)] Watch, for the user: \(what). Check it now with your tools. If nothing has changed since \
            last time in a way they would want to know, answer with exactly NOTHING NEW. Otherwise call them with \
            call_user (find it with tool_search if it isn't among your tools) and say what changed, then answer with \
            one or two short lines saying what changed.
            """
        case let .hand(_, name):
            """
            \(watchTag)\(id)] Watch, for the user: \(what). Check it now with your tools. If nothing has changed since \
            last time in a way that matters, answer with exactly [SILENT]. Otherwise answer with what changed and what \
            should be done about it, in a few lines: your answer goes to \(name), another of the user's agents, who \
            will act on it.
            """
        }
    }

    /// Where a watch's answers go, from its job: nil, to the person.
    static func handedTo(_ job: CronJob) -> String? {
        guard let deliver = job.deliver, deliver.hasPrefix("bot-chat:") else { return nil }
        return String(deliver.dropFirst("bot-chat:".count))
    }

    static func id(of job: CronJob) -> String? {
        guard let open = job.name.range(of: job.name.hasPrefix(watchTag) ? watchTag : followUpTag),
              let close = job.name[open.upperBound...].firstIndex(of: "]") else { return nil }
        return String(job.name[open.upperBound ..< close])
    }

    static func title(of job: CronJob) -> String {
        guard let close = job.name.firstIndex(of: "]") else { return job.name }
        return job.name[job.name.index(after: close)...].trimmingCharacters(in: .whitespaces)
    }

    /// `watcher`: the agent that looks, a bot's profile; nil, the one Redde is on.
    static func create(_ what: String, often: Often, watcher: String? = nil, then: Then = .tell) async throws {
        guard let backend = CronBackend.current() else { throw TransportError.malformed(String(localized: "Scheduled jobs need the Hermes Dashboard or the Hermes API.")) }
        let id = String(UUID().uuidString.lowercased().prefix(8))
        let name = String(what.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(60) ?? "")
        try await backend.create(name: "\(watchTag)\(id)] \(name)", schedule: often.rawValue, prompt: prompt(id, what: what, then: then),
                                 deliver: then.deliver, profile: watcher)
    }

    /// The agents a watch can be another's: the Dashboard's bots, which keep their jobs in their
    /// own stores. Over the Hermes API only the agent Redde is on.
    static var watchers: [HermesBot] {
        #if DEBUG
        if DemoDay.on { return DemoDay.roster.listed }   // the day's video's agents
        #endif
        guard let backend = CronBackend.current(), case .serve = backend, BotDirectory.available(),
              BotDirectory.shared.key == Settings.shared.connectionKey else { return [] }
        return (BotDirectory.shared.roster?.listed ?? []).filter { !$0.viaAPI }
    }

    /// The bot new watches go to unless another is picked: one whose profile is "watcher" (the
    /// plugin's `WATCHER`; 2026-11-08, "Watcher handles all watches"). Nil without one, or when Redde
    /// is on it already: the watch stays with the agent Redde is on, as before.
    static var defaultWatcher: String? {
        watchers.first { $0.name == "watcher" && $0.name != Settings.shared.profileName }?.name
    }

    /// The agents a change can be handed to.
    static var takers: [HermesBot] {
        #if DEBUG
        if DemoDay.on { return DemoDay.roster.listed }
        #endif
        guard BotDirectory.available(), BotDirectory.shared.key == Settings.shared.connectionKey else { return [] }
        return (BotDirectory.shared.roster?.listed ?? []).filter { !$0.viaAPI }
    }
}

/// A watch to set up, asked for from a message's menu (Watch This…): the sheet opens over the chat.
@MainActor
@Observable
final class WatchDraft {
    static let shared = WatchDraft()
    var text: String?
    /// A watch's notification, tapped: the Watches list open over the chat.
    var showingWatches = false

    func start(_ text: String) { self.text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)) }
}

/// The new-watch sheet a message's Watch This… asks for, over the chat.
struct WatchDraftSheet: ViewModifier {
    @State private var draft = WatchDraft.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { draft.text != nil }, set: { if !$0 { draft.text = nil } })) {
            NewWatchView(text: draft.text ?? "")
        }
        .sheet(isPresented: $draft.showingWatches) { WatchesSheet() }
    }
}

/// Watches & Follow-ups on its own, with Done: what a watch's notification opens.
struct WatchesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WatchesView()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Settings → Your Day → Watches & Follow-ups.
struct WatchesView: View {
    @State private var jobs: [CronJob] = []
    @State private var reports = WatchReport.all()
    @State private var loading = true
    @State private var problem: String?
    @State private var adding = false
    /// A template tapped on the empty page.
    @State private var starting: WatchTemplate.Kind?
    /// A watch's or a follow-up's settings, from a hold on its row.
    @State private var settingsFor: CronJob?
    /// Reports opened whole, laid out (`ReportView`); closed, a few plain lines.
    @State private var open: Set<String> = []

    private var watches: [CronJob] { jobs.filter { $0.name.hasPrefix(Watches.watchTag) } }
    /// Updates whose watch isn't in the list (it couldn't be loaded, or is gone): shown on their
    /// own, so what a notification said can always be read here.
    private var unlisted: [WatchReport] {
        let listed = Set(watches.compactMap { Watches.id(of: $0) })
        return reports.values.filter { !listed.contains($0.id) }.sorted { $0.at > $1.at }
    }
    private var followUps: [CronJob] { jobs.filter { $0.name.hasPrefix(Watches.followUpTag) }.sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) } }

    var body: some View {
        List {
            Section {
                if watches.isEmpty, unlisted.isEmpty, !loading {
                    EmptyHint(symbol: "eye", title: String(localized: "Nothing Watched Yet", comment: "Watches: none set up"),
                              text: String(localized: "Ask your agent to keep an eye on something: a price, a parcel, a page, a pull request, a sensor at home. It looks on a schedule and tells you only when it changes."))
                    // The templates, to start from in a tap (11-06: the empty page was two
                    // paragraphs and a button).
                    ForEach(WatchTemplate.Kind.allCases) { kind in
                        Button { starting = kind } label: {
                            Label { Text(kind.title) } icon: { Image(systemName: kind.symbol) }
                        }
                    }
                }
                ForEach(watches) { watchRow($0) }
                if !loading { ForEach(unlisted, id: \.id) { reportRow($0) } }
                Button("New Watch", systemImage: "plus") { adding = true }
            } header: { Text("Watches") }
            Section {
                if followUps.isEmpty, !loading {
                    EmptyHint(symbol: "arrow.uturn.backward.circle", title: String(localized: "No Follow-ups", comment: "Watches: no follow-ups"),
                              text: String(localized: "When you mention something to do later (\u{201C}I'll call the plumber tomorrow\u{201D}), your agent can set a follow-up: it comes back to you then as an idea card."))
                }
                ForEach(followUps) { followUpRow($0) }
            } header: { Text("Follow-ups") }
            if let problem { Section { Text(problem).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("Watches & Follow-ups")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading, jobs.isEmpty { ProgressView() } }
        .refreshable { await load() }
        .task { await load() }
        #if DEBUG
        // The day's video: a watch's note that arrives with this open shows in its row, as Redde
        // coming forward would show it (`DemoDay`).
        .task {
            while DemoDay.on, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.5))
                let now = WatchReport.all()
                if now != reports { withAnimation(.snappy) { reports = now } }
            }
        }
        #endif
        .sheet(isPresented: $adding, onDismiss: { Task { await load() } }) { NewWatchView(text: "") }
        .sheet(item: $starting, onDismiss: { Task { await load() } }) { NewWatchView(text: "", template: $0) }
        .sheet(item: $settingsFor) { job in
            if job.name.hasPrefix(Watches.watchTag) {
                WatchSettingsView(job: job) { Task { await load() } }
            } else {
                FollowUpSettingsView(job: job) { Task { await load() } }
            }
        }
    }

    private func watchRow(_ job: CronJob) -> some View {
        let report = Watches.id(of: job).flatMap { reports[$0] }
        let paused = job.state == .paused
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                WatchIcon(symbol: paused ? "pause.fill" : "eye.fill", tint: paused ? .secondary : .accentColor, dimmed: paused)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Watches.title(of: job)).font(.body.weight(.semibold)).lineLimit(2)
                        .foregroundStyle(paused ? .secondary : .primary)
                    if let line = who(job) { Text(line).font(.footnote).foregroundStyle(.secondary) }
                    if report == nil {
                        Text(job.lastRunAt == nil ? String(localized: "Not looked yet") : String(localized: "Nothing changed so far"))
                            .font(.footnote).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 4)
                WatchPill(text: paused ? String(localized: "Paused") : ComingUp.cadence(job.schedule), muted: paused)
            }
            if let report, report.needsEmail {
                // A template that reads email, on a Hermes that can't (2.4).
                WatchPanel(at: report.at, tint: .orange) {
                    Label(WatchTemplate.needsEmailHint, systemImage: "envelope.badge.shield.half.filled")
                        .font(.callout).foregroundStyle(.orange)
                }
            } else if let report {
                said(report)
            }
        }
        .padding(.vertical, 6)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .swipeActions { Button("Stop", systemImage: "trash", role: .destructive) { remove(job) } }
        .contextMenu {
            Button("Settings…", systemImage: "slider.horizontal.3") { settingsFor = job }
            Button("Check Now", systemImage: "arrow.clockwise") { run(job) }
            Button(paused ? "Resume" : "Pause", systemImage: paused ? "play" : "pause") { pause(job) }
            Button("Stop Watching", systemImage: "trash", role: .destructive) { remove(job) }
        }
    }

    /// What a watch said, in a panel under it with when: a few plain lines, a tap away from the
    /// whole of it laid out as a report (asked 2026-11-08: "Do this for all reports"). A failure
    /// stays red words.
    @ViewBuilder private func said(_ report: WatchReport) -> some View {
        let words = DayBrief.withoutNarration(report.text)
        if report.failed {
            WatchPanel(at: report.at, tint: .red) {
                Label { Text(PlainText.display(words)).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(.callout).foregroundStyle(.red)
            }
        } else if open.contains(report.id) {
            WatchPanel(at: report.at) {
                ReportView(text: words)
                WatchFold(text: String(localized: "Show Less", comment: "Watches: folds a watch's report back to a few lines"), symbol: "chevron.up")
            }
            .contentShape(.rect)
            .onTapGesture { withAnimation(.snappy) { _ = open.remove(report.id) } }
        } else {
            let plain = PlainText.display(words)
            // Short and in one paragraph, it's all there already.
            let more = plain.count > 140 || words.contains("\n")
            WatchPanel(at: report.at) {
                Text(plain).font(.callout).lineLimit(3)
                if more {
                    WatchFold(text: String(localized: "Show More", comment: "Watches: opens a watch's whole report"), symbol: "chevron.down")
                }
            }
            .contentShape(.rect)
            .onTapGesture { if more { withAnimation(.snappy) { _ = open.insert(report.id) } } }
            .accessibilityHint(Text("Shows the whole report", comment: "Watches: what tapping a watch's report does"))
        }
    }

    private func reportRow(_ report: WatchReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                WatchIcon(symbol: "doc.text.fill", tint: .secondary, dimmed: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.title).font(.body.weight(.semibold)).lineLimit(2)
                    if !report.agent.isEmpty { Text(report.agent).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            said(report)
        }
        .padding(.vertical, 6)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .swipeActions { Button("Delete", systemImage: "trash", role: .destructive) { WatchReport.forget(report.id); reports = WatchReport.all() } }
    }

    private func followUpRow(_ job: CronJob) -> some View {
        HStack(spacing: 12) {
            WatchIcon(symbol: "arrow.uturn.backward", tint: .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(Watches.title(of: job)).font(.body.weight(.medium))
                if let next = job.nextRunAt {
                    Text(next, format: .dateTime.weekday().month().day().hour().minute()).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .swipeActions { Button("Cancel", systemImage: "trash", role: .destructive) { remove(job) } }
        .contextMenu {
            Button("Settings…", systemImage: "slider.horizontal.3") { settingsFor = job }
            Button("Bring It Back Now", systemImage: "arrow.uturn.backward") { run(job) }
            Button("Cancel Follow-up", systemImage: "trash", role: .destructive) { remove(job) }
        }
    }

    /// Who looks, and who is handed what it sees, when it isn't the agent Redde is on, telling you.
    private func who(_ job: CronJob) -> String? {
        let settings = Settings.shared
        func name(_ profile: String) -> String {
            profile == "default" ? settings.headerTitle : BotDirectory.shared.roster?.named(profile)?.label(mainName: settings.headerTitle) ?? profile
        }
        let watcher = job.profile.flatMap { $0 == "default" || $0 == settings.profileName ? nil : name($0) }
        let taker = Watches.handedTo(job).map(name)
        switch (watcher, taker) {
        case let (w?, t?): return String(localized: "\(w) watches · hands changes to \(t)")
        case let (w?, nil): return String(localized: "\(w) watches")
        case let (nil, t?): return String(localized: "Hands changes to \(t)")
        default: return nil
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        reports = WatchReport.all()
        #if DEBUG
        if DemoDay.on { jobs = DemoDay.watchJobs; return }   // the day's video's
        #endif
        do {
            jobs = try await CronBackend.current()?.list() ?? []
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func remove(_ job: CronJob) {
        Task {
            do {
                try await CronBackend.current()?.delete(job.id, profile: job.profile)
                if let id = Watches.id(of: job) { WatchReport.forget(id) }
                await load()
            } catch { problem = error.localizedDescription }
        }
    }

    private func pause(_ job: CronJob) {
        Task {
            do { try await CronBackend.current()?.setPaused(job.id, job.state != .paused, profile: job.profile); await load() } catch { problem = error.localizedDescription }
        }
    }

    private func run(_ job: CronJob) {
        Task {
            do { try await CronBackend.current()?.runNow(job.id, profile: job.profile); await load() } catch { problem = error.localizedDescription }
        }
    }
}

/// A watch's or a follow-up's symbol on a soft tile of its colour, at the head of its row.
private struct WatchIcon: View {
    var symbol: String
    var tint: Color
    var dimmed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(tint.opacity(dimmed ? 0.12 : 0.16), in: .rect(cornerRadius: 9))
            .accessibilityHidden(true)
    }
}

/// How often a watch looks, or that it's paused, as a small capsule at the right of its title.
private struct WatchPill: View {
    var text: String?
    var muted = false

    var body: some View {
        if let text {
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(muted ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.tint.opacity(0.12)), in: .capsule)
                .fixedSize()
        }
    }
}

/// Show More / Show Less under a watch's report.
private struct WatchFold: View {
    var text: String
    var symbol: String

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            Image(systemName: symbol).imageScale(.small)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.tint)
    }
}

/// What a watch said last, on a panel of its own under the watch, with how long ago.
private struct WatchPanel<Content: View>: View {
    var at: Date
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(at, format: .relative(presentation: .named))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.map { AnyShapeStyle($0.opacity(0.1)) } ?? AnyShapeStyle(.fill.quaternary), in: .rect(cornerRadius: 12))
    }
}

/// A new watch: what to keep an eye on, and how often; or one of the templates (2.4), which asks
/// only for what it needs (a tracking number, a link).
struct NewWatchView: View {
    @State var text: String
    @State private var template: WatchTemplate.Kind?
    @State private var from = ""
    @State private var tracking = ""
    @State private var link = ""
    @State private var below = ""
    /// The Hermes can read email (over the Dashboard, by its MCP servers); nil, can't be told.
    @State private var emailAccess: Bool?
    @State private var often = Watches.Often.hourly

    init(text: String, template: WatchTemplate.Kind? = nil) {
        _text = State(initialValue: text)
        _template = State(initialValue: template)
        _watcher = State(initialValue: Watches.defaultWatcher ?? "")
    }
    /// The bot that looks ("" for the agent Redde is on), and what happens when it sees a change.
    @State private var watcher = ""
    @State private var then = "tell"
    private let settings = Settings.shared
    @State private var saving = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    templateChips
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                } header: {
                    Text("Start from a Template", comment: "New Watch: the row of ready-made watches")
                }
                if let template {
                    templateFields(template)
                } else {
                    Section {
                        TextField("What should your agent watch?", text: $text, axis: .vertical)
                            .lineLimit(3 ... 8)
                    } footer: {
                        Text("Say what to look at and what counts as a change: \u{201C}the price of the blue kettle on example.com, tell me if it drops under $40\u{201D}.")
                    }
                }
                if template == nil {
                Section {
                    Picker("How often", selection: $often) {
                        ForEach(Watches.Often.allCases) { Text($0.label).tag($0) }
                    }
                    if !Watches.watchers.isEmpty {
                        Picker("Who Watches", selection: $watcher) {
                            Text(settings.headerTitle).tag("")
                            ForEach(Watches.watchers.filter { !$0.isDefault && $0.name != settings.profileName }) { bot in
                                Text(bot.label(mainName: settings.headerTitle)).tag(bot.name)
                            }
                        }
                    }
                    Picker("When It Changes", selection: $then) {
                        Text("Tell Me").tag("tell")
                        Text("Call Me").tag("call")
                        ForEach(takers) { bot in
                            Text("Hand It to \(bot.label(mainName: settings.headerTitle))").tag("hand:" + bot.name)
                        }
                    }
                } footer: {
                    Text("It looks this often and does something only when it changes: a notification, a call (with Calls from Agents on for it), or, handed to another agent, that agent takes it on in its own chat with its own tools, and you're told. Needs Redde's plugin 1.9 on your Hermes.")
                }
                }
                if let problem { Section { Text(problem).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("New Watch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Watch") { save() }
                        .disabled(saving || !ready)
                }
            }
        }
    }

    // MARK: Templates

    private var templateChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(WatchTemplate.Kind.allCases) { kind in
                    let on = template == kind
                    Button {
                        withAnimation(.snappy) { template = on ? nil : kind }
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: .capsule)
                            .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder private func templateFields(_ kind: WatchTemplate.Kind) -> some View {
        Section {
            switch kind {
            case .urgentEmail:
                EmptyView()
            case .schoolMessages:
                TextField(String(localized: "From (a school or a teacher; optional)", comment: "New Watch, School Messages: whose messages"), text: $from)
            case .package:
                TextField(String(localized: "Tracking number", comment: "New Watch, A Package"), text: $tracking)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            case .priceDrop:
                TextField(String(localized: "Link to the product", comment: "New Watch, A Price Drop"), text: $link)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(String(localized: "Tell me below (optional), e.g. $40", comment: "New Watch, A Price Drop: the price that counts"), text: $below)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(templateFooter(kind))
                if kind.needsEmail, emailAccess == false {
                    Label(WatchTemplate.needsEmailHint, systemImage: "envelope.badge.shield.half.filled").foregroundStyle(.orange)
                }
            }
        }
        .task(id: kind) {
            if kind.needsEmail, emailAccess == nil { emailAccess = await WatchTemplate.emailAccess() }
        }
    }

    private func templateFooter(_ kind: WatchTemplate.Kind) -> String {
        switch kind {
        case .urgentEmail:
            String(localized: "Every 15 minutes your agent looks at new email and tells you only about what can't wait: someone waiting on an answer, a deadline, a bill, a travel change. Needs an email connection on your Hermes.", comment: "New Watch: the Urgent Emails template")
        case .schoolMessages:
            String(localized: "Every 30 minutes your agent looks for new email from the school and tells you what it asks of you, with any dates. Needs an email connection on your Hermes.", comment: "New Watch: the School Messages template")
        case .package:
            String(localized: "Every 4 hours for two weeks your agent checks the carrier and tells you when it ships, is out for delivery, arrives or is delayed.", comment: "New Watch: the A Package template")
        case .priceDrop:
            String(localized: "Each morning for a month your agent reads the product's page and tells you when the price drops.", comment: "New Watch: the A Price Drop template")
        }
    }

    /// The template as filled in; nil until it has what it needs.
    private var filled: WatchTemplate? {
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch template {
        case .urgentEmail: return .urgentEmail
        case .schoolMessages: return .schoolMessages(from: trim(from))
        case .package: return trim(tracking).isEmpty ? nil : .package(tracking: trim(tracking))
        case .priceDrop: return trim(link).isEmpty ? nil : .priceDrop(url: trim(link), below: trim(below))
        case nil: return nil
        }
    }

    private var ready: Bool {
        template == nil ? !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : filled != nil
    }

    /// The agents a change can go to: any but the one that looks.
    private var takers: [HermesBot] {
        let looking = watcher.isEmpty ? (settings.profileName ?? "default") : watcher
        return Watches.takers.filter { $0.name != looking && !($0.isDefault && looking == "default") }
    }

    private var chosen: Watches.Then {
        if then == "call" { return .call }
        if then.hasPrefix("hand:"), let bot = takers.first(where: { "hand:" + $0.name == then }) {
            return .hand(bot.name, bot.label(mainName: settings.headerTitle))
        }
        return .tell
    }

    private func save() {
        saving = true
        Task {
            do {
                if let filled {
                    try await WatchTemplate.create(filled, emailKnown: filled.needsEmail ? emailAccess : true)
                } else {
                    try await Watches.create(text.trimmingCharacters(in: .whitespacesAndNewlines), often: often,
                                             watcher: watcher.isEmpty ? nil : watcher, then: chosen)
                }
                dismiss()
            } catch {
                problem = error.localizedDescription
                saving = false
            }
        }
    }
}

/// A watch's settings, from a hold on its row (asked 2026-11-05): what it looks at, how often, what
/// happens when it sees a change, and its Check Now, Pause and Stop. Saved over the job, its id
/// and anything a template added to its prompt kept.
struct WatchSettingsView: View {
    let job: CronJob
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var what = ""
    @State private var schedule = ""
    @State private var then = Watches.Then.tell
    @State private var saving = false
    @State private var problem: String?

    /// What the watch looks at, read back from its prompt ("Watch, for the user: <what>. Check it now").
    static func what(in prompt: String) -> String? {
        guard let start = prompt.range(of: "Watch, for the user: "),
              let end = prompt.range(of: ". Check it now with your tools.", range: start.upperBound ..< prompt.endIndex) else { return nil }
        return String(prompt[start.upperBound ..< end.lowerBound])
    }

    /// What it does on a change, from the job: handed on, a call, or told.
    static func then(of job: CronJob, takers: [HermesBot]) -> Watches.Then {
        if let profile = Watches.handedTo(job) {
            return .hand(profile, takers.first { $0.name == profile }?.label(mainName: Settings.shared.headerTitle) ?? profile)
        }
        return job.prompt.contains("Otherwise call them with call_user") ? .call : .tell
    }

    /// The prompt with `what` and `then` in place: the same words around them, a template's
    /// additions after them kept.
    static func prompt(for job: CronJob, id: String, what: String, then: Watches.Then, was: Watches.Then) -> String {
        let before = Self.what(in: job.prompt) ?? what
        let standard = Watches.prompt(id, what: before, then: was)
        let extra = job.prompt.hasPrefix(standard) ? String(job.prompt.dropFirst(standard.count)) : ""
        return Watches.prompt(id, what: what, then: then) + extra
    }

    private var id: String { Watches.id(of: job) ?? "" }
    private var takers: [HermesBot] { Watches.takers }
    private var original: (what: String, schedule: String, then: Watches.Then) {
        (Self.what(in: job.prompt) ?? Watches.title(of: job), job.schedule, Self.then(of: job, takers: takers))
    }
    private var edited: Bool {
        let o = original
        return what.trimmingCharacters(in: .whitespacesAndNewlines) != o.what || schedule != o.schedule || then != o.then
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if Self.what(in: job.prompt) != nil {
                        TextField("What to keep an eye on", text: $what, axis: .vertical).lineLimit(2...6)
                    } else {
                        Text(Watches.title(of: job))
                    }
                } header: { Text("Watching") }
                Section("How Often") {
                    Picker("How often", selection: $schedule) {
                        ForEach(Watches.Often.allCases) { Text($0.label).tag($0.rawValue) }
                        if !Watches.Often.allCases.map(\.rawValue).contains(job.schedule) {
                            Text(verbatim: job.schedule).tag(job.schedule)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    Picker("When it sees a change", selection: $then) {
                        Text("Tell Me").tag(Watches.Then.tell)
                        Text("Call Me").tag(Watches.Then.call)
                        ForEach(takers.filter { $0.name != job.profile }, id: \.name) { bot in
                            let name = bot.label(mainName: Settings.shared.headerTitle)
                            Text("Hand to \(name)").tag(Watches.Then.hand(bot.name, name))
                        }
                        if case let .hand(profile, name) = original.then, !takers.contains(where: { $0.name == profile }) {
                            Text("Hand to \(name)").tag(original.then)
                        }
                    }
                } header: { Text("When It Sees a Change") }
                Section {
                    if let last = job.lastRunAt { LabeledContent("Last looked") { Text(last, style: .relative) } }
                    if let next = job.nextRunAt, job.state != .paused { LabeledContent("Next look") { Text(next, format: .dateTime.weekday().hour().minute()) } }
                    if let error = job.lastError, !error.isEmpty { Text(error).font(.footnote).foregroundStyle(.red) }
                    Button("Check Now", systemImage: "arrow.clockwise") { act { try await $0.runNow(job.id, profile: job.profile) } }
                    Button(job.state == .paused ? "Resume" : "Pause", systemImage: job.state == .paused ? "play" : "pause") {
                        act { try await $0.setPaused(job.id, job.state != .paused, profile: job.profile) }
                    }
                    Button("Stop Watching", systemImage: "trash", role: .destructive) {
                        act {
                            try await $0.delete(job.id, profile: job.profile)
                            if let id = Watches.id(of: job) { WatchReport.forget(id) }
                        }
                    }
                }
                if let problem { Section { Text(problem).font(.footnote).foregroundStyle(.red) } }
            }
            .navigationTitle(Watches.title(of: job))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!edited || saving || what.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .disabled(saving)
            .onAppear {
                let o = original
                what = o.what; schedule = o.schedule; then = o.then
            }
        }
    }

    private func act(_ work: @escaping (CronBackend) async throws -> Void) {
        guard let backend = CronBackend.current() else { return }
        saving = true
        Task {
            defer { saving = false }
            do { try await work(backend); changed(); dismiss() } catch { problem = error.localizedDescription }
        }
    }

    private func save() {
        let what = what.trimmingCharacters(in: .whitespacesAndNewlines)
        let o = original
        let name: String
        if what == o.what {
            name = job.name
        } else {
            let line = String(what.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(60) ?? "")
            name = "\(Watches.watchTag)\(id)] \(line)"
        }
        let prompt = Self.what(in: job.prompt) == nil ? job.prompt : Self.prompt(for: job, id: id, what: what, then: then, was: o.then)
        act { try await $0.update(job.id, name: name, schedule: schedule, prompt: prompt, deliver: then.deliver, profile: job.profile) }
    }
}

/// A follow-up's settings, from a hold on its row: when it comes back, and its Bring It Back Now and
/// Cancel. Its words are the agent's, kept as they are.
struct FollowUpSettingsView: View {
    let job: CronJob
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var when = Date.now
    @State private var saving = false
    @State private var problem: String?

    /// The one-off's schedule for `when`, as Hermes takes it (local time, minutes).
    static func schedule(_ when: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.string(from: when)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(Watches.title(of: job)) } header: { Text("Follow-up") }
                Section {
                    DatePicker("Comes back", selection: $when, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                } footer: { Text("It comes back to you then as an idea card.") }
                Section {
                    Button("Bring It Back Now", systemImage: "arrow.uturn.backward") { act { try await $0.runNow(job.id, profile: job.profile) } }
                    Button("Cancel Follow-up", systemImage: "trash", role: .destructive) { act { try await $0.delete(job.id, profile: job.profile) } }
                }
                if let problem { Section { Text(problem).font(.footnote).foregroundStyle(.red) } }
            }
            .navigationTitle("Follow-up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        act { try await $0.update(job.id, name: job.name, schedule: Self.schedule(when), prompt: job.prompt, deliver: job.deliver, profile: job.profile) }
                    }
                    .disabled(saving || job.nextRunAt.map { abs($0.timeIntervalSince(when)) < 60 } ?? false)
                }
            }
            .disabled(saving)
            .onAppear { when = max(job.nextRunAt ?? .now.addingTimeInterval(3600), .now.addingTimeInterval(60)) }
        }
    }

    private func act(_ work: @escaping (CronBackend) async throws -> Void) {
        guard let backend = CronBackend.current() else { return }
        saving = true
        Task {
            defer { saving = false }
            do { try await work(backend); changed(); dismiss() } catch { problem = error.localizedDescription }
        }
    }
}

/// An empty section's word: a symbol, a line in bold and what would be here.
struct EmptyHint: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3).foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(.tint.opacity(0.12), in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
