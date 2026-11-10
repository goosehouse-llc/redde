import SwiftUI

/// Over a chat whose agent has workstreams going (`Workstreams`): how many are working and how
/// many wait on the person, and a tap for the Work sheet. Shows for an hour after the last ends.
struct WorkStrip: View {
    let conversation: Conversation
    @Environment(\.theme) private var theme
    @State private var store = Workstreams.shared
    @State private var followed: String?
    @State private var showing = false

    /// The agent the chat is with, when its workstreams can be read: over the Dashboard.
    private var profile: String? {
        #if DEBUG
        if Workstreams.demo { return conversation.bot?.profile ?? "default" }
        #endif
        guard Settings.shared.transport == .hermesServe, conversation.serverSessionID != nil else { return nil }
        return conversation.bot?.profile ?? conversation.elsewhere?.profile ?? "default"
    }

    var body: some View {
        let work = profile.map { store.of($0, chat: conversation.serverSessionID) } ?? []
        let open = work.filter(\.isOpen)
        let waiting = open.filter { $0.status == .needsYou }.count
        let recent = work.contains { !$0.isOpen && ($0.ended ?? $0.updated) > Date.now.addingTimeInterval(-3600) }
        Group {
            if !open.isEmpty || recent {
                Button { showing = true } label: { strip(working: open.count - waiting, waiting: waiting, done: work.count - open.count) }
                    .buttonStyle(.plain)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: open.map(\.status.rawValue))
        .onAppear {
            follow(profile)
            #if DEBUG
            if Workstreams.demo, DevHooks.has("-echo.showWork") { showing = true }
            #endif
        }
        .onDisappear { follow(nil) }
        .onChange(of: profile) { _, new in follow(new) }
        // A turn ended: it may have started one, or heard from one.
        .onChange(of: conversation.isStreaming) { _, streaming in
            if !streaming, let profile { Task { await store.refresh(profile) } }
        }
        .sheet(isPresented: $showing) {
            if let profile { WorkSheet(profile: profile, chat: conversation.serverSessionID, agent: agentName) }
        }
    }

    private var agentName: String {
        conversation.bot?.name ?? Settings.shared.headerTitle
    }

    private func strip(working: Int, waiting: Int, done: Int) -> some View {
        HStack(spacing: 8) {
            if working > 0 { ProgressView().controlSize(.mini) }
            Image(systemName: "square.stack.3d.up").foregroundStyle(theme.accent)
            Group {
                if working > 0 { Text("\(working) working", comment: "Over a chat: how many of the agent's workstreams are at work now") }
                if waiting > 0 {
                    if working > 0 { Text(verbatim: "·") }
                    Text("\(waiting) need you", comment: "Over a chat: how many of the agent's workstreams wait for the person's approval")
                        .foregroundStyle(.orange)
                }
                if working == 0, waiting == 0 { Text("\(done) finished", comment: "Over a chat: how many of the agent's workstreams have ended lately") }
            }
            .fontWeight(.semibold)
            Spacer(minLength: 4)
            Text("Work", comment: "Over a chat: opens the list of the agent's workstreams").foregroundStyle(theme.accent)
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .chatFont(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Shows the agent's workstreams", comment: "Over a chat: what tapping the workstreams strip does"))
    }

    private func follow(_ profile: String?) {
        guard profile != followed else { return }
        if let followed { store.unfollow(followed) }
        followed = profile
        if let profile { store.follow(profile) }
    }
}

/// An agent's workstreams from one chat, newest first: each one's title, how it stands, what it
/// waits on or last said, and Open (its own chat, where an approval is answered) and Stop.
struct WorkSheet: View {
    let profile: String
    let chat: String?
    /// Who started them, as the chat names it.
    let agent: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var store = Workstreams.shared
    @State private var stopping: String?
    @State private var problem: String?

    var body: some View {
        let work = store.of(profile, chat: chat)
        NavigationStack {
            Group {
                if work.isEmpty {
                    ContentUnavailableView {
                        Label { Text("No workstreams", comment: "The Work sheet, empty") } icon: { Image(systemName: "square.stack.3d.up") }
                    } description: {
                        Text("When \(agent) hands a job to a chat of its own, it shows here while it works.", comment: "The Work sheet, empty: what would show")
                    }
                } else {
                    List {
                        if let problem {
                            Text(problem).font(.footnote).foregroundStyle(.red)
                        }
                        ForEach(work) { item in card(item) }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(Text("Work", comment: "The Work sheet's title: the agent's workstreams"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("Done", comment: "Closes the Work sheet") }
                }
            }
            .refreshable { await store.refresh(profile) }
        }
        .presentationDetents([.medium, .large])
        .task { await store.refresh(profile) }
    }

    private func card(_ item: Workstream) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: item.id)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(theme.accent.opacity(0.15), in: .capsule)
                    .foregroundStyle(theme.accent)
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 4)
                status(item)
            }
            if item.status == .needsYou, !item.asked.isEmpty {
                let summary = ApprovalSummary(ApprovalRequest(id: "", command: item.asked, description: nil, choices: []), agent: agent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.headline).font(.footnote.weight(.semibold))
                    if let step = summary.steps.first { Text(step.text).font(.footnote).foregroundStyle(step.risky ? .red : .secondary) }
                }
            } else if !item.last.isEmpty {
                Text(PlainText.display(item.last)).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
            }
            HStack(spacing: 12) {
                Text(item.isOpen ? item.created.formatted(.relative(presentation: .named)) : (item.ended ?? item.updated).formatted(.relative(presentation: .named)))
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if item.isOpen {
                    Button(role: .destructive) { stop(item) } label: {
                        if stopping == item.id { ProgressView().controlSize(.small) } else { Text("Stop", comment: "The Work sheet: stops a workstream") }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(stopping != nil)
                }
                Button { open(item) } label: {
                    Text(item.status == .needsYou ? String(localized: "Answer", comment: "The Work sheet: opens a workstream that waits for approval, to answer it")
                         : String(localized: "Open", comment: "The Work sheet: opens a workstream's own chat"))
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func status(_ item: Workstream) -> some View {
        Group {
            switch item.status {
            case .starting, .working:
                Label { Text("Working", comment: "A workstream's status") } icon: { ProgressView().controlSize(.mini) }
                    .foregroundStyle(.secondary)
            case .needsYou:
                Label { Text("Needs you", comment: "A workstream's status: it waits for the person's approval") } icon: { Image(systemName: "hand.raised.fill") }
                    .foregroundStyle(.orange)
            case .done:
                Label { Text("Done", comment: "A workstream's status") } icon: { Image(systemName: "checkmark.circle.fill") }
                    .foregroundStyle(.green)
            case .failed:
                Label { Text("Didn't finish", comment: "A workstream's status: it ended with an error") } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .foregroundStyle(.red)
            case .stopped:
                Label { Text("Stopped", comment: "A workstream's status: it was stopped") } icon: { Image(systemName: "stop.circle") }
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.semibold))
        .labelStyle(.titleAndIcon)
    }

    private func stop(_ item: Workstream) {
        stopping = item.id
        Task {
            problem = await store.stop(item.id, of: profile)
            stopping = nil
        }
    }

    private func open(_ item: Workstream) {
        dismiss()
        LaunchRouter.shared.requestSession(item.session, profile: profile, title: "\(item.id) · \(item.title)")
    }
}
