import SwiftUI

/// A delegated child's own conversation: stored history, then live reasoning, tools and text
/// while it runs (the gateway mirrors the child's stream onto a lazily resumed session).
/// Steer sends a nudge into the child; Stop interrupts it. A child of a Hermes API turn runs in
/// the gateway, not the Dashboard: its conversation is read through the Dashboard and read again
/// every few seconds while it works, and it can't be steered or stopped from here.
struct SubagentTranscriptView: View {
    let agent: SubagentActivity
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var messages: [Message] = []
    @State private var running = false
    @State private var error: String?
    @State private var loading = true
    @State private var listener: UUID?
    @State private var runtime: String?
    @State private var steer = ""
    @State private var toast: String?
    /// The turn ran over the Hermes API.
    private let viaAPI = Settings.shared.transport == .hermesSessions

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        header
                        if let error {
                            ContentUnavailableView("Couldn't open the subagent", systemImage: "wifi.exclamationmark", description: Text(error))
                        } else if messages.isEmpty, !loading {
                            ContentUnavailableView("Nothing yet", systemImage: "person.2.wave.2",
                                                   description: running ? Text("The subagent is starting.") : Text("This subagent left no transcript."))
                        }
                        ForEach(messages) { message in
                            MessageRow(message: message, isLive: running && message.id == messages.last?.id)
                                .equatable()
                                .id(message.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .onChange(of: messages.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .environment(\.lazyWebBlocks, true)
            }
            .safeAreaInset(edge: .bottom) { if running, !viaAPI { steerBar } }
            .overlay { if loading { ProgressView() } }
            .toast($toast, bottomPadding: running ? 64 : 12)
            .navigationTitle("Subagent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if running, !viaAPI {
                        Button("Stop", systemImage: "stop.circle", role: .destructive) { stop() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                await open()
                if viaAPI { await follow() }
            }
            .onDisappear { if let listener { HermesServeClient.shared.removeListener(listener) } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(agent.goal.isEmpty ? String(localized: "Delegated task") : agent.goal).font(.headline)
            HStack(spacing: 6) {
                Image(systemName: running ? "person.2.wave.2" : agent.status == .failed ? "xmark.circle" : "checkmark.circle")
                    .symbolEffect(.pulse, isActive: running)
                    .foregroundStyle(running ? theme.accent : agent.status == .failed ? .red : .green)
                running ? Text("Running") : agent.status == .failed ? Text("Failed") : Text("Finished")
                if let m = agent.model, !m.isEmpty { Text("·"); Text(m) }
                if agent.taskCount > 1 { Text("·"); Text("task \(agent.taskIndex + 1) of \(agent.taskCount)") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var steerBar: some View {
        HStack(spacing: 8) {
            TextField("Steer the subagent…", text: $steer, axis: .vertical).lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .onSubmit(sendSteer)
            Button("Send", systemImage: "arrow.turn.down.right", action: sendSteer)
                .labelStyle(.iconOnly)
                .disabled(steer.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Live

    private func open() async {
        guard let stored = agent.childSessionID else { error = String(localized: "No child session id."); loading = false; return }
        do {
            let (rt, isRunning, rows) = try await HermesServeClient.shared.resumeLazy(stored: stored)
            // Dismissed during the resume: onDisappear has already run with no listener to
            // remove, so one added now would outlive the sheet.
            guard !Task.isCancelled else { return }
            runtime = rt
            messages = Conversation.messages(fromServeRows: rows)
            running = isRunning || agent.status == .running
            if !viaAPI {
                listener = HermesServeClient.shared.addListener { event in
                    guard event.sessionID == rt else { return }
                    Task { @MainActor in handle(event) }
                }
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    /// A Hermes API turn's child, read again every few seconds while it works: the Dashboard has no
    /// live stream of a turn that runs in the gateway. Done once its reply is in and nothing changes.
    private func follow() async {
        guard let stored = agent.childSessionID, running else { return }
        var unchanged = 0
        while !Task.isCancelled, unchanged < 3 {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let rows = try? await HermesServeClient.shared.history(stored: stored) else { continue }
            let fresh = Conversation.messages(fromServeRows: rows)
            // Read again, each message has a new id: what it says is what tells.
            let said = { (all: [Message]) in all.map { "\($0.role)|\($0.text)|\($0.tools.count)" } }
            if said(fresh) == said(messages) {
                if fresh.last?.role == .assistant { unchanged += 1 }
            } else {
                unchanged = 0
                messages = fresh
            }
        }
        running = false
    }

    private func handle(_ event: HermesServeClient.Event) {
        let p = event.payload
        switch event.type {
        case "message.start":
            messages.append(Message(role: .assistant, text: ""))
            running = true
        case "reasoning.delta":
            if let t = p["text"]?.string { withLastReply { $0.reasoning += t } }
        case "message.delta":
            if let t = p["text"]?.string, !t.isEmpty { withLastReply { $0.text += t } }
        case "tool.start":
            withLastReply { $0.tools.append(ToolActivity(name: p["name"]?.string ?? "tool", preview: p["preview"]?.string ?? p["context"]?.string, status: .running)) }
        case "tool.complete":
            let failed = p["error"] != nil && !(p["error"]?.isNull ?? true)
            withLastReply { m in
                if let i = m.tools.lastIndex(where: { $0.status == .running }) { m.tools[i].status = failed ? .failed : .completed }
            }
        case "message.complete":
            if let t = p["text"]?.string, !t.isEmpty, messages.last?.text.isEmpty == true { withLastReply { $0.text = t } }
            running = false
        case "session.info":
            if p["running"]?.bool == false { running = false }
        default:
            break
        }
    }

    /// Mutate the trailing assistant message, creating one if the stream started mid-way.
    private func withLastReply(_ change: (inout Message) -> Void) {
        if let i = messages.indices.last, messages[i].role == .assistant {
            change(&messages[i])
        } else {
            var m = Message(role: .assistant, text: "")
            change(&m)
            messages.append(m)
        }
    }

    private func sendSteer() {
        let text = steer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        steer = ""
        Task {
            do {
                let queued = try await HermesServeClient.shared.subagentSteer(id: agent.id, text: text)
                show(queued ? String(localized: "Sent to the subagent") : String(localized: "The subagent isn't accepting steering right now"))
            } catch { show(error.localizedDescription) }
        }
    }

    private func stop() {
        Task {
            do {
                let found = try await HermesServeClient.shared.subagentInterrupt(id: agent.id)
                show(found ? String(localized: "Stopping…") : String(localized: "Subagent already finished"))
            } catch { show(error.localizedDescription) }
        }
    }

    private func show(_ text: String) { toast = text }
}
