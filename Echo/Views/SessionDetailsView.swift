import SwiftUI

/// What the page knows of the chat without asking the server: who it is with, where, on which
/// model, and how full its context is. Built by the chat screen when the page opens.
struct SessionChatInfo {
    var title: String
    /// The agent it is with: a bot's name, else the main agent's.
    var agent: String
    var face: BotFace?
    var server: String?
    var connection: Transport
    /// The model under the chat's title, and how it was chosen.
    var model: String
    var modelChoice: String?
    var provider: String?
    var reasoningEffort: String?
    var context: ContextUsage?
    var project: String?
    var sessionID: String?
    var isIncognito = false
    /// When this device first had the conversation, for one the server keeps nothing of.
    var startedHere: Date
}

/// The chat's Session Details (his ask 2026-11-02): what the conversation is, what it ran on,
/// how full it is, what it cost and what its replies did, from the server's record of the session
/// (`SessionDetailsModel`, read when the page opens) and what this device saw (`SessionActivity`).
/// Rows a connection can't fill are left out, and one line at the end says what isn't reported.
struct SessionDetailsView: View {
    let info: SessionChatInfo
    let activity: SessionActivity
    let source: SessionDetailsSource?
    var rename: (() -> Void)?
    var export: (() -> Void)?
    @State var model: SessionDetailsModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var facts: SessionFacts? { model.facts }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                overview
                modelSection
                contextSection.id("context")
                usageSection
                activitySection.id("end")
                actions
            }
            #if DEBUG
            // `-echo.demoSessionDetails usage|end`: the page scrolled there, for screenshots.
            .task {
                guard let anchor = DevHooks.value("-echo.demoSessionDetails"), ["context", "end"].contains(anchor) else { return }
                try? await Task.sleep(for: .milliseconds(600))
                proxy.scrollTo(anchor, anchor: anchor == "end" ? .bottom : .top)
            }
            #endif
        }
        .navigationTitle("Session Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .overlay {
            if model.loading, facts == nil { ProgressView() }
        }
        .refreshable { await model.load(id: info.sessionID, from: source) }
        .task {
            // Once per opening: a demo arrives filled in.
            if facts == nil { await model.load(id: info.sessionID, from: source) }
        }
    }

    // MARK: Sections

    private var overview: some View {
        Section {
            HStack(spacing: 12) {
                if let face = info.face {
                    BotAvatar(face: face, name: info.agent, size: 36)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(facts?.title ?? info.title).font(.headline).lineLimit(3)
                    Text(info.agent).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            if let server = info.server { row("Server", server) }
            row("Connection", connectionName)
            if let started = facts?.startedAt ?? (info.sessionID == nil ? info.startedHere : nil) {
                row("Started", started.formatted(date: .abbreviated, time: .shortened))
            }
            if let last = facts?.lastActive { row("Last active", last.formatted(.relative(presentation: .named))) }
            if let ended = facts?.endedAt, let reason = facts?.endReason, !(facts?.wasCompressed ?? false) {
                row("Ended", "\(ended.formatted(date: .abbreviated, time: .shortened)) · \(reason.replacingOccurrences(of: "_", with: " "))")
            }
            if let source = facts?.source { row("Started from", Self.sourceName(source)) }
            if let project = info.project { row("Project", project) }
            if let folder = facts?.folder { row("Folder", folder, mono: true) }
            if let branch = facts?.branch { row("Git branch", branch, mono: true) }
            if let id = info.sessionID {
                Button {
                    ChecklistExport.copy(id)
                    copied = true
                } label: {
                    HStack {
                        Text("Session ID").foregroundStyle(.primary)
                        Spacer(minLength: 12)
                        Text(id).font(.footnote.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Session ID, \(id)")
                .accessibilityHint("Copies it")
            }
        }
    }

    private var modelSection: some View {
        Section("Model") {
            row("Model", facts?.model ?? info.model, mono: true)
            if let choice = info.modelChoice { row("Chosen", choice) }
            if let provider = facts?.provider ?? info.provider { row("Provider", provider) }
            if let effort = facts?.reasoningEffort ?? info.reasoningEffort { row("Reasoning", effort.capitalized) }
        }
    }

    @ViewBuilder
    private var contextSection: some View {
        let lineage = model.lineage
        if info.context != nil || lineage.compressions > 0 || lineage.branchedFrom != nil {
            Section {
                if let context = info.context {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("In use", comment: "Session Details: how much of the model's context the conversation fills")
                            Spacer()
                            Text(ContextRing.sentence(used: context.used, window: context.window))
                                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ProgressView(value: min(1, Double(context.used) / Double(max(1, context.window))))
                            .tint(Self.contextTint(context))
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
                if lineage.compressions > 0 {
                    row("Summarised",
                        lineage.more ? String(localized: "\(lineage.compressions)+ times", comment: "Session Details: the conversation was summarised more times than counted")
                                     : String(localized: "\(lineage.compressions) times", comment: "Session Details: how often the conversation was summarised to fit"))
                }
                if let branched = lineage.branchedFrom { row("Branched from", branched) }
            } header: {
                Text("Context")
            } footer: {
                if lineage.compressions > 0 {
                    Text("When the conversation filled the model's context, Hermes summarised it and carried on in a new session. The summary is what the model reads now.")
                }
            }
        }
    }

    @ViewBuilder
    private var usageSection: some View {
        let cost = SessionCost(facts)
        if facts?.inputTokens != nil || facts?.outputTokens != nil || cost != .notReported {
            Section {
                if let input = facts?.inputTokens { tokens("Input", input) }
                if let output = facts?.outputTokens { tokens("Output", output) }
                if let cached = facts?.cacheReadTokens, cached > 0 {
                    let share = (facts?.inputTokens).flatMap { $0 > 0 ? Double(cached) / Double($0) : nil }
                    row("Read from cache", share.map { "\(cached.formatted()) · \($0.formatted(.percent.precision(.fractionLength(0))))" } ?? cached.formatted(), digits: true)
                }
                if let written = facts?.cacheWriteTokens, written > 0 { tokens("Written to cache", written) }
                if let reasoning = facts?.reasoningTokens, reasoning > 0 { tokens("Reasoning", reasoning) }
                if let calls = facts?.apiCallCount, calls > 0 { row("Model calls", calls.formatted(), digits: true) }
                row("Cost", Self.costText(cost), digits: cost.amount != nil)
            } header: {
                Text("Usage")
            } footer: {
                if let note = Self.costNote(cost) { Text(note) }
            }
        }
    }

    @ViewBuilder
    private var activitySection: some View {
        Section {
            row("Messages", (facts?.messageCount ?? activity.messages).formatted(), digits: true)
            if activity.yourMessages > 0 { row("Yours", activity.yourMessages.formatted(), digits: true) }
            let calls = facts?.toolCallCount ?? activity.toolCalls
            if calls > 0 {
                row("Tool calls", activity.toolFailures > 0
                    ? String(localized: "\(calls.formatted()) · \(activity.toolFailures.formatted()) failed", comment: "Session Details: tool calls and how many failed")
                    : calls.formatted(), digits: true)
            }
            if activity.timedReplies > 0 {
                row("Reply time", Duration.seconds(activity.replyTime).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)), digits: true)
                if let rate = activity.tokensPerSecond {
                    row("Average speed", String(localized: "\(Int(rate.rounded())) tokens a second", comment: "Session Details: how fast replies were written"), digits: true)
                }
            }
        } header: {
            Text("Activity")
        } footer: {
            if activity.timedReplies > 0 {
                Text("Reply time and speed count the \(activity.timedReplies) replies this device received as they were written.")
            }
        }
        if !activity.tools.isEmpty {
            Section("Tools Used") {
                ForEach(activity.tools) { tool in
                    HStack {
                        Text(tool.name).font(.callout.monospaced()).lineLimit(1)
                        Spacer(minLength: 12)
                        if tool.failed > 0 {
                            Text("\(tool.failed) failed", comment: "Session Details: a tool's failed calls")
                                .font(.caption).foregroundStyle(.red)
                        }
                        Text(tool.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Section {
            if let rename {
                Button("Rename", systemImage: "pencil") { dismiss(); rename() }
            }
            if let export, activity.messages > 0 {
                Button("Export as Markdown", systemImage: "square.and.arrow.up") { dismiss(); export() }
            }
            if let usage = UsageModel.Source(source) {
                NavigationLink { UsageView(model: UsageModel(source: usage)) } label: {
                    Label("See All Usage", systemImage: "chart.bar")
                }
            }
        } footer: {
            if let note = notReported { Text(note) }
            if let problem = model.problem {
                Text("Couldn't read the session from your server: \(problem)").foregroundStyle(.red)
            }
        }
    }

    // MARK: Pieces

    private func row(_ label: LocalizedStringKey, _ value: String, mono: Bool = false, digits: Bool = false) -> some View {
        LabeledContent {
            Text(value)
                .font(mono ? .callout.monospaced() : .body)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(mono ? 2 : 3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        } label: {
            Text(label)
        }
        .accessibilityElement(children: .combine)
    }

    private func tokens(_ label: LocalizedStringKey, _ count: Int) -> some View {
        row(label, count.formatted(), digits: true)
    }

    private var connectionName: String {
        switch info.connection {
        case .hermesServe: String(localized: "Hermes Dashboard", comment: "Session Details: the connection")
        case .hermesSessions: String(localized: "Hermes API", comment: "Session Details: the connection")
        case .chatCompletions: String(localized: "Straight to the model", comment: "Session Details: the fast lane connection")
        case .acp: String(localized: "Agent Client Protocol", comment: "Session Details: the connection to an ACP agent")
        }
    }

    /// What this connection leaves out, in a line, or nil when nothing is missing.
    private var notReported: String? {
        if info.isIncognito { return String(localized: "Incognito: nothing of this chat is kept, here or on your server.") }
        guard info.sessionID != nil else {
            return info.connection.hasLedger
                ? String(localized: "Your server keeps this conversation once its first message is sent.")
                : String(localized: "This conversation is kept on this device only; the model's server keeps no session for it.")
        }
        if model.missing { return String(localized: "Your server has no session with this ID any more.") }
        if source?.isDashboard == false {
            return String(localized: "The Hermes API doesn't report billing, the working folder or the model's settings; the Dashboard does.")
        }
        return nil
    }

    nonisolated static func sourceName(_ source: String) -> String {
        switch source {
        case "api_server", "api-server": String(localized: "Redde or another app (Hermes API)")
        case "desktop", "dashboard", "web": String(localized: "Redde or the Dashboard", comment: "Session Details: where the session started")
        case "cli": String(localized: "The command line")
        case "cron": String(localized: "A scheduled job")
        default: source.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    nonisolated static func costText(_ cost: SessionCost) -> String {
        let usd: (Double) -> String = { UsageMoney.text($0) }
        return switch cost {
        case .actual(let amount): usd(amount)
        case .estimated(let amount): String(localized: "about \(usd(amount))", comment: "Session Details: an estimated cost")
        case .included: String(localized: "Included in your plan", comment: "Session Details: cost of a subscription model")
        case .noCharge: String(localized: "None charged", comment: "Session Details: Hermes recorded no charge")
        case .unpriced: String(localized: "Unpriced", comment: "Session Details: Hermes has no price for the model")
        case .notReported: String(localized: "Not reported", comment: "Session Details: the server gave no cost")
        }
    }

    nonisolated static func costNote(_ cost: SessionCost) -> String? {
        switch cost {
        case .actual: String(localized: "What the provider billed for this session.")
        case .estimated: String(localized: "Hermes's estimate from the model's list price, not a bill.")
        case .unpriced: String(localized: "Hermes has no price for this model, so it can't say what it cost.")
        default: nil
        }
    }

    private static func contextTint(_ context: ContextUsage) -> Color {
        let share = Double(context.used) / Double(max(1, context.window))
        return share >= 0.9 ? .red : share >= 0.75 ? .orange : .accentColor
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        SessionDetailsView(info: SessionChatInfo(title: "Move the blog to the new site", agent: "Sol", server: "dchermes", connection: .hermesServe,
                                                 model: "qwen36-kapitsa", modelChoice: "Set on your server", context: ContextUsage(used: 84_600, window: 128_000),
                                                 sessionID: "20261102_081544_9f3c2a", startedHere: .now),
                           activity: SessionDetailsModel.demoActivity, source: nil, model: .demo)
    }
}
#endif
