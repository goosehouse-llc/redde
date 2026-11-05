import Charts
import SwiftUI

/// Usage and spend across every conversation (his pick 2026-11-02): the range's spend kept apart
/// by kind, its tokens, a bar a day, then by bot, by model and the conversations that cost most,
/// each opening its Session Details. Read when the page opens or the range changes, and on pull to
/// refresh (`UsageModel`). Rows a connection can't fill are left out, with one line saying so.
struct UsageView: View {
    @State var model: UsageModel
    @State private var range = UsageRange.week
    @State private var showCost = true

    private var report: UsageReport? { model.report?.range == range ? model.report : nil }

    var body: some View {
        List {
            Section {
                Picker("Range", selection: $range) {
                    ForEach(UsageRange.allCases) { Text(Self.name($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if let report {
                spendSection(report)
                tokensSection(report)
                daysSection(report)
                profilesSection(report)
                modelsSection(report)
                topSection(report)
                notes(report)
            } else if let problem = model.problem {
                Section {
                    Text("Couldn't read usage from your server: \(problem)").foregroundStyle(.red)
                }
            } else if model.source == nil, !model.demo {
                Section {
                    Text("Usage comes from your Hermes server: connect to one in Settings first.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Usage")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay {
            if model.loading, report == nil { ProgressView() }
        }
        .refreshable { await model.load(range, force: true) }
        .task(id: range) { await model.load(range) }
    }

    // MARK: Sections

    @ViewBuilder
    private func spendSection(_ report: UsageReport) -> some View {
        let spend = report.spend
        Section {
            if spend.estimated > 0 || spend.reported > 0 || spend.noCostModels.isEmpty {
                row("Estimated", spend.estimated > 0
                    ? String(localized: "about \(UsageMoney.text(spend.estimated))", comment: "Usage: Hermes's running cost for the range")
                    : UsageMoney.text(0), big: true)
            }
            if spend.reported > 0 {
                row("Reported by providers", UsageMoney.text(spend.reported))
            }
            if !spend.noCostModels.isEmpty {
                row("No cost recorded", ListFormatter.localizedString(byJoining: spend.noCostModels), mono: true)
            }
        } header: {
            Text("Spend")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hermes's running cost: each model's list price, or what the provider reported per call. A bill can differ.")
                if spend.reported > 0 {
                    Text("Reported by providers is what they reconciled for some of these sessions: part of the spend above, not added to it.")
                }
                if !spend.noCostModels.isEmpty {
                    Text("No cost recorded: models that ran with no price, such as a model on your own computer, a free one, or one in a subscription.")
                }
            }
        }
    }

    private func tokensSection(_ report: UsageReport) -> some View {
        Section("Tokens") {
            count("Input", report.tokens.input)
            count("Output", report.tokens.output)
            if report.tokens.cacheRead > 0 {
                let share = report.tokens.input > 0 ? Double(report.tokens.cacheRead) / Double(report.tokens.input) : nil
                row("Read from cache", share.map { "\(report.tokens.cacheRead.formatted()) · \($0.formatted(.percent.precision(.fractionLength(0))))" }
                    ?? report.tokens.cacheRead.formatted())
            }
            if report.tokens.reasoning > 0 { count("Reasoning", report.tokens.reasoning) }
            count("Sessions", report.sessions)
            if report.modelCalls > 0 { count("Model calls", report.modelCalls) }
        }
    }

    @ViewBuilder
    private func daysSection(_ report: UsageReport) -> some View {
        if report.days.count > 1 {
            let costs = report.days.contains { $0.cost > 0 }
            let byCost = costs && showCost
            Section {
                if costs {
                    Picker("Show", selection: $showCost) {
                        Text("Spend").tag(true)
                        Text("Tokens").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                Chart(report.days) { day in
                    BarMark(x: .value("Day", day.date, unit: .day),
                            y: .value(byCost ? "Spend" : "Tokens", byCost ? day.cost : Double(day.tokens)))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).month().day()))
                        .accessibilityValue(byCost ? UsageMoney.text(day.cost) : String(localized: "\(day.tokens.formatted()) tokens"))
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(byCost ? UsageMoney.text(amount) : Self.short(amount))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: report.days.count > 10 ? 7 : 1)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: report.days.count > 10 ? .dateTime.month(.abbreviated).day() : .dateTime.weekday(.narrow), centered: true)
                    }
                }
                .frame(height: 170)
                .padding(.vertical, 6)
            } header: {
                Text("By Day")
            } footer: {
                Text("Hermes counts a session on the day it started, all of it, however long it ran.")
            }
        }
    }

    @ViewBuilder
    private func profilesSection(_ report: UsageReport) -> some View {
        if report.profiles.count > 1 {
            Section("By Bot") {
                ForEach(report.profiles) { profile in
                    breakdown(profile.title, detail: String(localized: "\(profile.sessions.formatted()) sessions · \(Self.short(Double(profile.tokens.total))) tokens"),
                              cost: profile.cost, mono: false)
                }
            }
        }
    }

    @ViewBuilder
    private func modelsSection(_ report: UsageReport) -> some View {
        if !report.models.isEmpty {
            Section {
                ForEach(report.models) { row in
                    breakdown(row.model, detail: String(localized: "\(row.sessions.formatted()) sessions · \(Self.short(Double(row.tokens.total))) tokens"),
                              cost: row.noCost ? nil : row.cost, mono: true)
                }
            } header: {
                Text("By Model")
            } footer: {
                if report.origin == .dashboard {
                    Text(report.range == .today
                         ? "Models over the last 24 hours, with the helper models Hermes ran for summaries, titles and pictures."
                         : "Includes the helper models Hermes ran for summaries, titles and pictures.")
                }
            }
        }
    }

    @ViewBuilder
    private func topSection(_ report: UsageReport) -> some View {
        if !report.top.isEmpty {
            Section {
                ForEach(report.top, id: \.id) { session in
                    NavigationLink {
                        SessionDetailsView(info: Self.info(session, origin: report.origin), activity: SessionActivity(), source: detailsSource(session),
                                           model: SessionDetailsModel(facts: session))
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(session.title?.nilIfEmpty ?? String(localized: "Untitled conversation")).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(SessionDetailsView.costText(SessionCost(session))).monospacedDigit().foregroundStyle(.secondary)
                            }
                            Text([session.profile.flatMap { name in report.profiles.first { $0.profile == name }?.title ?? name },
                                  session.model, "\(Self.short(Double((session.inputTokens ?? 0) + (session.outputTokens ?? 0)))) tokens"]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } header: {
                Text("Top Conversations")
            } footer: {
                if report.capped {
                    Text("Only the most recent conversations were looked at; older ones in this range may be missing here, not from the totals.")
                }
            }
        }
    }

    @ViewBuilder
    private func notes(_ report: UsageReport) -> some View {
        Section {
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if report.origin == .api {
                    Text("Over the Hermes API: this profile's conversations only, without bots' chats or by-bot totals. The Hermes Dashboard login shows every bot.")
                }
                if report.origin == .api, report.capped {
                    Text("Stopped after \(UsageModel.sessionCap.formatted()) sessions: the oldest in this range aren't counted.")
                }
                if !report.unreadProfiles.isEmpty {
                    Text("Couldn't read: \(ListFormatter.localizedString(byJoining: report.unreadProfiles)).").foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: Pieces

    private func row(_ label: LocalizedStringKey, _ value: String, mono: Bool = false, big: Bool = false) -> some View {
        LabeledContent {
            Text(value)
                .font(big ? .title3.weight(.semibold) : mono ? .callout.monospaced() : .body)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .textSelection(.enabled)
        } label: {
            Text(label)
        }
        .accessibilityElement(children: .combine)
    }

    private func count(_ label: LocalizedStringKey, _ value: Int) -> some View {
        row(label, value.formatted())
    }

    private func breakdown(_ title: String, detail: String, cost: Double?, mono: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(mono ? .callout.monospaced() : .body).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            Text(cost.map { UsageMoney.text($0) } ?? String(localized: "no cost", comment: "Usage: a model that ran with no price"))
                .monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// The session's own connection, for its Session Details.
    private func detailsSource(_ session: SessionFacts) -> SessionDetailsSource? {
        switch model.source {
        case .dashboard(let client): .dashboard(client, profile: session.profile)
        case .api(let api, _): .api(api)
        case nil: nil
        }
    }

    private static func info(_ session: SessionFacts, origin: UsageReport.Origin) -> SessionChatInfo {
        SessionChatInfo(title: session.title?.nilIfEmpty ?? String(localized: "Untitled conversation"),
                        agent: session.profile ?? Settings.shared.headerTitle,
                        server: Settings.shared.activeServer?.name.nilIfEmpty,
                        connection: origin == .dashboard ? .hermesServe : .hermesSessions,
                        model: session.model ?? "",
                        sessionID: session.id,
                        startedHere: session.startedAt ?? .now)
    }

    static func name(_ range: UsageRange) -> LocalizedStringKey {
        switch range {
        case .today: "Today"
        case .week: "7 Days"
        case .month: "30 Days"
        case .thisMonth: "This Month"
        }
    }

    /// 1.2M, 840K: a count to read at a glance.
    static func short(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.notation(.compactName).precision(.significantDigits(1 ... 3)))
    }
}

#if DEBUG
#Preview {
    NavigationStack { UsageView(model: .demo) }
}
#endif
