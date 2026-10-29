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

    func start(_ text: String) { self.text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)) }
}

/// The new-watch sheet a message's Watch This… asks for, over the chat.
struct WatchDraftSheet: ViewModifier {
    @State private var draft = WatchDraft.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { draft.text != nil }, set: { if !$0 { draft.text = nil } })) {
            NewWatchView(text: draft.text ?? "")
        }
    }
}

/// Settings → Agent → Watches & Follow-ups.
struct WatchesView: View {
    @State private var jobs: [CronJob] = []
    @State private var reports = WatchReport.all()
    @State private var loading = true
    @State private var problem: String?
    @State private var adding = false

    private var watches: [CronJob] { jobs.filter { $0.name.hasPrefix(Watches.watchTag) } }
    private var followUps: [CronJob] { jobs.filter { $0.name.hasPrefix(Watches.followUpTag) }.sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) } }

    var body: some View {
        List {
            Section {
                if watches.isEmpty, !loading {
                    Text("Ask your agent to keep an eye on something: a price, a parcel, a page, a pull request, a sensor at home. It looks on a schedule and tells you only when it changes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(watches) { watchRow($0) }
                Button("New Watch", systemImage: "plus") { adding = true }
            } header: { Text("Watches") }
            Section {
                if followUps.isEmpty, !loading {
                    Text("When you mention something to do later (\u{201C}I'll call the plumber tomorrow\u{201D}), your agent can set a follow-up: it comes back to you then as an idea card.")
                        .font(.footnote).foregroundStyle(.secondary)
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
        .sheet(isPresented: $adding, onDismiss: { Task { await load() } }) { NewWatchView(text: "") }
    }

    private func watchRow(_ job: CronJob) -> some View {
        let report = Watches.id(of: job).flatMap { reports[$0] }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Watches.title(of: job)).font(.body.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 6)
                if job.state == .paused { Text("Paused").font(.caption).foregroundStyle(.secondary) }
            }
            if let line = who(job) { Text(line).font(.caption).foregroundStyle(.secondary) }
            if let report {
                Text(report.text).font(.callout).foregroundStyle(report.failed ? .red : .primary).lineLimit(3)
                Text(report.at, style: .relative).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(job.lastRunAt == nil ? String(localized: "Not looked yet") : String(localized: "Nothing changed so far"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .swipeActions { Button("Stop", systemImage: "trash", role: .destructive) { remove(job) } }
        .contextMenu {
            Button("Check Now", systemImage: "arrow.clockwise") { run(job) }
            Button(job.state == .paused ? "Resume" : "Pause", systemImage: job.state == .paused ? "play" : "pause") { pause(job) }
            Button("Stop Watching", systemImage: "trash", role: .destructive) { remove(job) }
        }
    }

    private func followUpRow(_ job: CronJob) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Watches.title(of: job)).font(.body)
            if let next = job.nextRunAt { Text(next, format: .dateTime.weekday().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
        }
        .swipeActions { Button("Cancel", systemImage: "trash", role: .destructive) { remove(job) } }
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

/// A new watch: what to keep an eye on, and how often.
struct NewWatchView: View {
    @State var text: String
    @State private var often = Watches.Often.hourly
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
                    TextField("What should your agent watch?", text: $text, axis: .vertical)
                        .lineLimit(3 ... 8)
                } footer: {
                    Text("Say what to look at and what counts as a change: \u{201C}the price of the blue kettle on example.com, tell me if it drops under $40\u{201D}.")
                }
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
                if let problem { Section { Text(problem).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("New Watch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Watch") { save() }
                        .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
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
                try await Watches.create(text.trimmingCharacters(in: .whitespacesAndNewlines), often: often,
                                         watcher: watcher.isEmpty ? nil : watcher, then: chosen)
                dismiss()
            } catch {
                problem = error.localizedDescription
                saving = false
            }
        }
    }
}
