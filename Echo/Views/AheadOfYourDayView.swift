import SwiftUI

/// Ahead of Your Day's sheet (asked 2026-10-30): the proactive features ticked, each with its
/// line, and one Turn On that sets them all up in order, each row saying how it went
/// (`AheadOfYourDaySetup`). Opened once from What's New and from Settings → Agent → Your Day; the
/// same on an iPhone, an iPad and the Mac.
struct AheadOfYourDayView: View {
    typealias Part = AheadOfYourDay.Part
    typealias Row = AheadOfYourDaySetup.Row
    typealias Status = AheadOfYourDaySetup.Status

    @State private var setup = AheadOfYourDaySetup()
    @State private var pairing = false
    @State private var pairingByCode = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Section { header }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                    Section {
                        ForEach(Part.allCases) { part in
                            partRow(part)
                            options(for: part)
                        }
                    } footer: {
                        Text("Each has its own page in Settings → Agent, to change its time or turn it off.", comment: "Ahead of Your Day: under the list of features")
                    }
                    Section {
                        if wantsJobs { connectionRow }
                        pluginRow
                        pairingRow
                    } header: {
                        Text("What It Takes", comment: "Ahead of Your Day: the section with the connection, the plugin and notifications")
                    }
                    .id("takes")
                }
                #if DEBUG
                // `-echo.demoAheadRun bottom`: the steps' results in view, for the pictures.
                .onChange(of: setup.phase) { _, phase in
                    if phase == .finished, DevHooks.value("-echo.demoAheadRun") == "bottom" { withAnimation { proxy.scrollTo("takes", anchor: .top) } }
                }
                #endif
            }
            .navigationTitle(Text("Ahead of Your Day", comment: "The one-step setup of Morning Ideas, Heads-Ups, Leave-By Alerts, the Evening Wrap-up and the Week Ahead"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if setup.phase != .finished {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Not Now")) { dismiss() }.disabled(setup.phase == .running)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 640, idealHeight: 720)
        #endif
        .interactiveDismissDisabled(setup.phase == .running)
        .task {
            AheadOfYourDay.markAnswered()
            await setup.load()
            #if DEBUG
            if DevHooks.has("-echo.demoAheadRun") {
                try? await Task.sleep(for: .seconds(1))
                await setup.turnOn()
            }
            #endif
        }
        .sheet(isPresented: $pairing, onDismiss: { setup.pairingChanged() }) {
            PushPairingSheet(offer: nil, server: serverName)
        }
        .sheet(isPresented: $pairingByCode, onDismiss: { setup.pairingChanged() }) {
            NavigationStack {
                PushSettingsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { pairingByCode = false } } }
            }
        }
    }

    // MARK: The top

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "sunrise.fill")
                .font(.system(size: 38, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(theme.accent)
                .accessibilityHidden(true)
            Text("Your agent looks at your day before you do: ideas in the morning, a heads-up before events, a nudge when it's time to leave, a wrap-up at night. Pick what you want, and Redde sets it up on your Hermes and on this device.",
                 comment: "Ahead of Your Day: the sheet's opening line")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The features

    private func partRow(_ part: Part) -> some View {
        let picked = setup.picked.contains(part)
        let alreadyOn = setup.situation.on.contains(part)
        let line = status(of: .part(part))
        return Button {
            // Turned on already: its own page turns it off; this sheet only turns things on.
            guard setup.phase == .ready, !alreadyOn else { return }
            withAnimation(.snappy) { if picked { setup.picked.remove(part) } else { setup.picked.insert(part) } }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: picked || alreadyOn ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(picked || alreadyOn ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Label { Text(title(part)).foregroundStyle(.primary) } icon: { Image(systemName: symbol(part)).foregroundStyle(theme.accent) }
                        .font(.body.weight(.medium))
                    Text(blurb(part)).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let line { StatusLine(status: line) }
                }
                Spacer(minLength: 4)
                StatusMark(status: line)
            }
            .contentShape(.rect)
            .opacity(picked || alreadyOn || setup.phase == .ready ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked || alreadyOn ? .isSelected : [])
    }

    /// Under a ticked feature that isn't on yet, before Turn On: Morning Ideas' time, Leave-By's way.
    @ViewBuilder private func options(for part: Part) -> some View {
        if setup.phase == .ready, setup.picked.contains(part), !setup.situation.on.contains(part) {
            switch part {
            case .morningIdeas:
                DatePicker(selection: $setup.morningTime, displayedComponents: .hourAndMinute) {
                    Text("Time").padding(.leading, 44)
                }
            case .leaveBy:
                Picker(selection: $setup.way) {
                    Text("By Car").tag(LeaveTime.Mode.driving)
                    Text("By Transit").tag(LeaveTime.Mode.transit)
                    Text("On Foot").tag(LeaveTime.Mode.walking)
                } label: {
                    Text("Getting There").padding(.leading, 44)
                }
            default:
                EmptyView()
            }
        }
    }

    // MARK: What it takes

    private var wantsJobs: Bool { setup.picked.contains { $0.isJob } }

    private var connectionRow: some View {
        let line = status(of: .connection)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Label { Text("Connection") } icon: { Image(systemName: "server.rack") }
                Spacer(minLength: 4)
                StatusMark(status: line)
            }
            if let line { StatusLine(status: line).padding(.leading, 40) }
        }
    }

    private var pluginRow: some View {
        let line = status(of: .plugin)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Label { Text("Redde Plugin") } icon: { Image(systemName: "shippingbox") }
                Spacer(minLength: 4)
                StatusMark(status: line)
            }
            if let line { StatusLine(status: line).padding(.leading, 40) }
            if setup.plan.plugin == .skip(.needsDashboard) || setup.plan.plugin == .skip(.unreadable) {
                CommandRow(title: "On the machine that runs Hermes, install the plugin, then restart Hermes", command: PushSettingsView.installCommand + " --force")
                    .padding(.leading, 40)
            }
            if setup.situation.restartPending {
                CommandRow(title: "On that machine", command: "hermes gateway restart").padding(.leading, 40)
            }
        }
    }

    private var pairingRow: some View {
        let line = status(of: .pairing)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Label { Text("Notify When Redde Is Closed") } icon: { Image(systemName: "bell.badge") }
                Spacer(minLength: 4)
                StatusMark(status: line)
            }
            if let line { StatusLine(status: line).padding(.leading, 40) }
            if setup.plan.pairing == .byCode, !setup.situation.paired {
                Button { pairingByCode = true } label: {
                    Text("Pair with a Code…", comment: "Ahead of Your Day: opens Settings → Notifications → Notify When Redde Is Closed to pair with the plugin's code")
                }
                .padding(.leading, 40)
            }
        }
    }

    // MARK: The bottom

    private var bottomBar: some View {
        VStack(spacing: 10) {
            switch setup.phase {
            case .loading, .ready:
                Button { Task { await setup.turnOn() } } label: {
                    Group {
                        if setup.phase == .loading { ProgressView() } else { Text("Turn On", comment: "Ahead of Your Day: the button that sets everything up") }
                    }
                    .font(.headline).foregroundStyle(theme.userText).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(setup.phase == .loading || setup.picked.isEmpty)
            case .running:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Setting up…", comment: "Ahead of Your Day: while Turn On works").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            case .finished:
                if setup.offersPairing {
                    Button { pairing = true } label: {
                        Text(serverName.map { String(localized: "Pair with \($0)") } ?? String(localized: "Pair with this Hermes"))
                            .font(.headline).foregroundStyle(theme.userText).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(String(localized: "Done")) { dismiss() }
                        .font(.headline)
                        .buttonStyle(.borderless)
                } else {
                    Button { dismiss() } label: {
                        Text("Done").font(.headline).foregroundStyle(theme.userText).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .tint(theme.accent)
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: Words

    /// A row's status: what Turn On said, or, before it runs, what it will do.
    private func status(of row: Row) -> Status? {
        if let said = setup.status[row] { return said }
        guard setup.phase == .ready else { return nil }
        let plan = setup.plan
        switch row {
        case .part(let part):
            guard setup.situation.on.contains(part) else { return nil }
            if let job = setup.found[part], let daily = part.job, let at = DailyJob.time(of: job) {
                return .skipped(AheadOfYourDay.when(daily, hour: at.hour, minute: at.minute))
            }
            return .skipped(String(localized: "Already on.", comment: "Ahead of Your Day: a feature that was on before"))
        case .connection:
            if let problem = setup.listProblem { return .failed(problem) }
            return setup.situation.jobs ? nil
                : .failed(String(localized: "Your agent's daily jobs need the Hermes Dashboard login or the Hermes API key. Add one in Settings → Connection details.", comment: "Ahead of Your Day: no connection that can make Hermes jobs"))
        case .plugin:
            switch plan.plugin {
            case .run, .skip(.upToDate):
                return setup.situation.plugin.map { .skipped(PushSettingsView.pluginLine($0, restart: false)) }
            case .skip(.needsDashboard):
                return .needsYou(String(localized: "Redde checks the plugin through the Hermes Dashboard login. Without it, install or update it on the machine that runs Hermes.", comment: "Ahead of Your Day: the plugin can't be checked over the Hermes API alone"))
            case .skip(.unreadable):
                if case let .unknown(why) = setup.plugin.phase { return .needsYou(why) }
                return nil
            case .skip:
                return .skipped(String(localized: "Not needed for what you picked.", comment: "Ahead of Your Day: the plugin or a pairing, when only Leave-By Alerts are picked"))
            }
        case .pairing:
            switch plan.pairing {
            case .skip(.alreadyPaired): return .skipped(String(localized: "Paired"))
            case .skip(.notNeeded): return .skipped(String(localized: "Not needed for what you picked.", comment: "Ahead of Your Day: the plugin or a pairing, when only Leave-By Alerts are picked"))
            case .direct: return .skipped(String(localized: "Not paired yet. Redde offers it at the end, so ideas and briefings arrive with Redde closed.", comment: "Ahead of Your Day: pairing over the Dashboard comes after Turn On"))
            case .byCode: return .needsYou(String(localized: "So ideas and briefings arrive with Redde closed, pair this device with a code in Settings → Notifications → Notify When Redde Is Closed.", comment: "Ahead of Your Day: pairing over the Hermes API takes the plugin's code"))
            case .skip: return nil
            }
        }
    }

    private var serverName: String? {
        Settings.shared.activeServer.flatMap { $0.name.isEmpty ? nil : $0.name }
    }

    private func title(_ part: Part) -> String {
        switch part {
        case .morningIdeas: String(localized: "Morning Ideas")
        case .headsUps: String(localized: "Heads-Ups Before Events")
        case .leaveBy: String(localized: "Leave-By Alerts")
        case .wrapUp: String(localized: "Evening Wrap-up")
        case .weekAhead: String(localized: "Week Ahead")
        case .routines: String(localized: "Routine Suggestions")
        }
    }

    private func symbol(_ part: Part) -> String {
        if part == .leaveBy { return setup.way == .transit ? "tram" : setup.way == .walking ? "figure.walk" : "car" }
        return part.job?.symbol ?? "sparkles"
    }

    private func blurb(_ part: Part) -> String {
        switch part {
        case .morningIdeas: String(localized: "A few things your agent could do today, as cards to swipe.", comment: "Ahead of Your Day: Morning Ideas in a line")
        case .headsUps: String(localized: "Where, who's coming and what to bring, before each event.", comment: "Ahead of Your Day: Heads-Ups in a line")
        case .leaveBy: String(localized: "When to leave, worked out on this device with Apple Maps.", comment: "Ahead of Your Day: Leave-By Alerts in a line")
        case .wrapUp: String(localized: "What got done, what's waiting on you, what carries over. At 9 PM.", comment: "Ahead of Your Day: the Evening Wrap-up in a line")
        case .weekAhead: String(localized: "The week to come, each Sunday evening.", comment: "Ahead of Your Day: the Week Ahead in a line")
        case .routines: String(localized: "Things you ask again and again, offered as routines. Weekly.", comment: "Ahead of Your Day: Routine Suggestions in a line")
        }
    }
}

/// The mark at a row's end: working, done, nothing to do, or a step left.
private struct StatusMark: View {
    let status: AheadOfYourDaySetup.Status?

    var body: some View {
        Group {
            switch status {
            case .working: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .skipped: EmptyView()
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .needsYou, .needsSettings: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case nil: EmptyView()
            }
        }
        .font(.body)
        .frame(minWidth: 22)
        .transition(.scale.combined(with: .opacity))
        .accessibilityHidden(true)
    }
}

/// A row's status in words, under it.
private struct StatusLine: View {
    let status: AheadOfYourDaySetup.Status
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch status {
        case .working(let text):
            if let text { Text(text).font(.footnote).foregroundStyle(.secondary) }
        case .done(let text), .skipped(let text):
            Text(text).font(.footnote).foregroundStyle(.secondary)
        case .failed(let text):
            Text(text).font(.footnote).foregroundStyle(.red)
        case .needsYou(let text):
            Text(text).font(.footnote).foregroundStyle(.orange)
        case .needsSettings(let text):
            // Leave-By's missing permissions, "… Open Settings…": a tap goes there.
            Button { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } } label: {
                Text(text).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.footnote)
            .buttonStyle(.borderless)
        }
    }
}

/// Settings → Agent → Your Day's first row: On when what the person picked is on; the sheet.
struct AheadOfYourDayRow: View {
    @State private var on: Bool?
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            LabeledContent {
                if let on { on ? Text("On") : Text("Off") }
            } label: {
                Label { Text("Ahead of Your Day", comment: "The one-step setup of Morning Ideas, Heads-Ups, Leave-By Alerts, the Evening Wrap-up and the Week Ahead") } icon: { Image(systemName: "sunrise") }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .task(id: open) { if !open { on = await Self.isOn() } }
        .sheet(isPresented: $open) { AheadOfYourDayView() }
    }

    /// One look at the server's jobs and this device's Leave-By switch; unknown (no mark) when the
    /// jobs can't be listed.
    private static func isOn() async -> Bool? {
        let picked = AheadOfYourDay.picked()
        var on: Set<AheadOfYourDay.Part> = Settings.shared.leaveByAlerts ? [.leaveBy] : []
        if picked.contains(where: \.isJob) {
            guard let backend = CronBackend.current(), let jobs = try? await backend.list() else { return nil }
            let names = Set(jobs.map(\.name))
            on.formUnion(AheadOfYourDay.Part.allCases.filter { $0.job.map { names.contains($0.name) } == true })
        }
        return AheadOfYourDay.isOn(picked: picked, on: on)
    }
}
