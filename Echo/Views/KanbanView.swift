import SwiftUI

/// The Hermes kanban board (dashboard plugin on hermes serve): one column at a time on the
/// phone, cards as rows, moves via a status picker.
struct KanbanView: View {
    @Environment(\.theme) private var theme
    /// Last kanban live-event id seen; the live socket resumes from here.
    @State private var latestEventID = 0
    @State private var columns: [KanbanColumn] = []
    @State private var assignees: [String] = []
    @State private var selected = "todo"
    @State private var error: String?
    @State private var loading = false
    @State private var creating = false
    @State private var detailID: String?
    @State private var editing: KanbanTask?
    @State private var moving: (task: KanbanTask, status: String)?
    @State private var moveNote = ""
    @State private var toast: String?
    @State private var live = KanbanClient.LiveBoard()
    /// Serve login present; read once per screen and per refresh, not per row.
    @State private var available = KanbanClient.isAvailable
    /// On screen. A scene-phase task that lands after the view left must not reopen the socket.
    @State private var visible = false
    @Environment(\.scenePhase) private var scenePhase

    private var column: KanbanColumn? { columns.first { $0.name == selected } }

    var body: some View {
        List {
            // A pinned header, not a row above the list: the sheet's toolbar gave its top inset to
            // the first scroll view it found, the columns' own, which pushed them out of sight.
            Section {
                if !available {
                    ContentUnavailableView("Needs Redde serve", systemImage: "rectangle.split.3x1",
                                           description: Text("The kanban board is part of the Redde dashboard. Add your Redde serve address and login in Settings."))
                        .listRowSeparator(.hidden)
                } else if let error {
                    ContentUnavailableView("Couldn't load the board", systemImage: "wifi.exclamationmark", description: Text(error))
                        .listRowSeparator(.hidden)
                } else if let column, column.tasks.isEmpty, !loading {
                    ContentUnavailableView("Nothing in \(KanbanStatus.label(column.name))", systemImage: KanbanStatus.icon(column.name))
                        .listRowSeparator(.hidden)
                }
                ForEach(column?.tasks ?? []) { task in
                    Button { detailID = task.id } label: { row(task) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if let next = nextStatus(for: task.status) {
                                Button { move(task, to: next) } label: { Label(KanbanStatus.label(next), systemImage: KanbanStatus.icon(next)) }
                                    .tint(theme.accent)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { delete(task) } label: { Label("Delete", systemImage: "trash") }
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editing = task }
                            Menu("Move to", systemImage: "arrow.right.square") {
                                ForEach(KanbanStatus.movable.filter { $0 != task.status }, id: \.self) { s in
                                    Button(KanbanStatus.label(s), systemImage: KanbanStatus.icon(s)) { move(task, to: s) }
                                }
                            }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) { delete(task) }
                        }
                }
            } header: {
                if !columns.isEmpty { columnPicker.listRowInsets(EdgeInsets()) }
            }
        }
        .listStyle(.plain)
        .toast($toast, duration: .seconds(4))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("New card", systemImage: "plus") { creating = true }.disabled(!available)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if available {
                    Image(systemName: live.isLive ? "dot.radiowaves.left.and.right" : "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(live.isLive ? .green : .secondary)
                        .accessibilityLabel(live.isLive ? "Live updates on" : "Polling for updates")
                }
            }
        }
        .task {
            await refresh()
            // Cancelled mid-fetch (tab switched, sheet closed): onDisappear already stopped
            // the socket, and starting it now would leave a loop running for the process.
            guard !Task.isCancelled else { return }
            startLive()
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; live.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh(); if visible { startLive() } } } else { live.stop() }
        }
        .refreshable { await refresh() }
        .sheet(isPresented: $creating) { KanbanCardEditor(task: nil, assignees: assignees) { await refresh() } }
        .sheet(item: $editing) { task in KanbanCardEditor(task: task, assignees: assignees) { await refresh() } }
        .sheet(item: Binding(get: { detailID.map { IDBox(id: $0) } }, set: { detailID = $0?.id })) { box in
            KanbanCardDetail(taskID: box.id, assignees: assignees) { await refresh() }
        }
        .alert(moveTitle, isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } })) {
            TextField(movePlaceholder, text: $moveNote)
            Button("Move") { if let m = moving { commitMove(m.task, to: m.status, note: moveNote) } }
            Button("Cancel", role: .cancel) { moving = nil }
        } message: { Text(moveMessage) }
    }

    private var moveTitle: String { "Move to \(KanbanStatus.label(moving?.status ?? ""))" }
    private var movePlaceholder: String {
        switch moving?.status { case "blocked", "scheduled": "Reason"; default: "Summary" }
    }
    private var moveMessage: String {
        switch moving?.status {
        case "blocked": "What is it waiting on?"
        case "scheduled": "Why is it deferred?"
        case "review": "What should the reviewer look at?"
        default: "What was the outcome?"
        }
    }

    private func startLive() {
        guard available else { return }
        #if DEBUG
        if KanbanClient.isDemo { live.showLiveForDemo(); return }
        #endif
        live.onChange = { _ in Task { await refresh() } }
        live.start(since: latestEventID)
    }

    private struct IDBox: Identifiable { let id: String }

    private var columnPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(columns) { col in
                    let on = col.name == selected
                    Button {
                        selected = col.name
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: KanbanStatus.icon(col.name))
                            Text(KanbanStatus.label(col.name))
                            if !col.tasks.isEmpty {
                                Text("\(col.tasks.count)").font(.caption2.weight(.semibold)).monospacedDigit()
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background((on ? Color.white.opacity(0.25) : theme.accent.opacity(0.15)), in: .capsule)
                            }
                        }
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(on ? theme.accent : Color.primary.opacity(0.06), in: .capsule)
                        .foregroundStyle(on ? theme.userText : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func row(_ task: KanbanTask) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.title).font(.body.weight(.medium)).lineLimit(2)
                Spacer(minLength: 0)
                if task.priority != 0 {
                    Text("P\(task.priority)").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background((task.priority > 0 ? Color.orange : Color.secondary).opacity(0.15), in: .capsule)
                        .foregroundStyle(task.priority > 0 ? Color.orange : Color.secondary)
                }
            }
            if let s = task.latestSummary ?? task.body, !s.isEmpty {
                Text(s).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 6) {
                if let a = task.assignee, !a.isEmpty { Label(a, systemImage: "person").labelStyle(.titleAndIcon) }
                if let c = task.createdAt { Text(c.relativeLabel) }
                if task.commentCount > 0 { Label("\(task.commentCount)", systemImage: "text.bubble") }
                if task.lastFailure != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }

    private func nextStatus(for s: String) -> String? {
        switch s {
        case "triage": "todo"
        case "todo": "ready"
        case "blocked": "ready"
        case "review": "done"
        case "done": "archived"
        default: nil
        }
    }

    private func refresh() async {
        available = KanbanClient.isAvailable
        guard available else { return }
        loading = true
        defer { loading = false }
        do {
            let board = try await KanbanClient.board()
            columns = board.columns
            assignees = board.assignees
            latestEventID = max(latestEventID, board.latestEventID)
            if !columns.contains(where: { $0.name == selected }) { selected = columns.first?.name ?? "todo" }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Blocked, Scheduled, Review and Done take a note; the rest move straight away.
    private func move(_ task: KanbanTask, to status: String) {
        if ["blocked", "scheduled", "review", "done"].contains(status) {
            moveNote = ""
            moving = (task, status)
        } else {
            commitMove(task, to: status, note: "")
        }
    }

    private func commitMove(_ task: KanbanTask, to status: String, note: String) {
        moving = nil
        Task {
            do {
                let isReason = status == "blocked" || status == "scheduled"
                try await KanbanClient.move(task.id, to: status, reason: isReason ? note : nil, summary: isReason ? nil : note)
                await refresh()
            } catch { show(error.localizedDescription) }
        }
    }

    private func delete(_ task: KanbanTask) {
        Task {
            do { try await KanbanClient.delete(task.id); await refresh() }
            catch { show(error.localizedDescription) }
        }
    }

    private func show(_ text: String) { toast = text }
}

struct KanbanCardEditor: View {
    let task: KanbanTask?
    /// Assignees the board already knows; a fresh list is fetched only if this is empty.
    let assignees: [String]
    let onSave: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var priority = 0
    @State private var assignee = ""
    @State private var fetched: [String]?
    @State private var startReady = false
    private var assigneeChoices: [String] { fetched ?? assignees }
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Card") {
                    TextField("Title", text: $title)
                    TextField("Details for the worker", text: $details, axis: .vertical).lineLimit(3...10)
                }
                Section {
                    Stepper("Priority \(priority)", value: $priority, in: -5...10)
                    if assigneeChoices.isEmpty {
                        TextField("Assignee (profile)", text: $assignee)
                    } else {
                        Picker("Assignee", selection: $assignee) {
                            Text("Unassigned").tag("")
                            ForEach(assigneeChoices, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    if task == nil { Toggle("Start right away (Ready)", isOn: $startReady) }
                } footer: {
                    if task == nil { Text("Ready cards with an assignee are picked up by the dispatcher; others wait in Triage.") }
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
            }
            .navigationTitle(task == nil ? "New card" : "Edit card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { save() }.disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let task {
                    title = task.title; details = task.body ?? ""; priority = task.priority; assignee = task.assignee ?? ""
                }
            }
            .task { if assignees.isEmpty { fetched = try? await KanbanClient.assignees() } }
        }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                if let task {
                    try await KanbanClient.edit(task.id,
                                                title: title != task.title ? title : nil,
                                                body: details != (task.body ?? "") ? details : nil,
                                                priority: priority != task.priority ? priority : nil,
                                                assignee: assignee != (task.assignee ?? "") ? assignee : nil)
                } else {
                    _ = try await KanbanClient.create(title: title, body: details, priority: priority, assignee: assignee, ready: startReady)
                }
                await onSave()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct KanbanCardDetail: View {
    let taskID: String
    var assignees: [String] = []
    let onChange: () async -> Void
    @State private var editing = false
    @State private var pendingStatus: String?
    @State private var note = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(Conversation.self) private var conversation
    @State private var task: KanbanTask?
    @State private var comments: [KanbanComment] = []
    @State private var status = ""
    @State private var newComment = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let task {
                    Section {
                        Picker("Status", selection: $status) {
                            ForEach(Array(Set(KanbanStatus.movable + [task.status])).sorted { KanbanStatus.columns.firstIndex(of: $0) ?? 99 < KanbanStatus.columns.firstIndex(of: $1) ?? 99 }, id: \.self) {
                                Text(KanbanStatus.label($0)).tag($0)
                            }
                        }
                        .disabled(task.status == "running")
                        LabeledContent("Priority", value: "\(task.priority)")
                        if let a = task.assignee, !a.isEmpty { LabeledContent("Assignee", value: a) }
                        if let c = task.createdAt { LabeledContent("Created") { Text(c, format: .dateTime.month().day().hour().minute()) } }
                        if let d = task.completedAt { LabeledContent("Completed") { Text(d, format: .dateTime.month().day().hour().minute()) } }
                    }
                    if let b = task.body, !b.isEmpty { Section("Details") { MarkdownView(text: b) } }
                    if let r = task.result, !r.isEmpty { Section("Result") { MarkdownView(text: r) } }
                    else if let s = task.latestSummary, !s.isEmpty { Section("Latest") { Text(s).font(.callout) } }
                    if let f = task.lastFailure, !f.isEmpty { Section("Last failure") { Text(f).font(.footnote).foregroundStyle(.red) } }
                    Section("Comments") {
                        ForEach(comments) { c in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack { Text(c.author).font(.caption.weight(.semibold)); if let d = c.createdAt { Text(d, style: .relative).font(.caption).foregroundStyle(.secondary) } }
                                Text(c.body).font(.callout)
                            }
                        }
                        HStack {
                            TextField("Add a comment", text: $newComment, axis: .vertical)
                            Button("Post") { post() }.disabled(newComment.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    Section {
                        Button("Ask Redde about this card", systemImage: "bubble.left.and.text.bubble.right") {
                            dismiss()
                            conversation.send("About kanban card “\(task.title)” (\(task.id)): \(task.body ?? "")\n\nWhat's the status, and what should happen next?")
                        }
                    }
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(task?.title ?? "Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Edit", systemImage: "pencil") { editing = true }.disabled(task == nil) }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await load() }
            .sheet(isPresented: $editing) {
                if let task { KanbanCardEditor(task: task, assignees: assignees) { await load(); await onChange() } }
            }
            .onChange(of: status) { _, new in
                guard let task, !new.isEmpty, new != task.status else { return }
                if ["blocked", "scheduled", "review", "done"].contains(new) {
                    note = ""; pendingStatus = new
                } else {
                    apply(new, note: "")
                }
            }
            .alert("Move to \(KanbanStatus.label(pendingStatus ?? ""))", isPresented: Binding(get: { pendingStatus != nil }, set: { if !$0 { cancelMove() } })) {
                TextField(pendingStatus == "blocked" || pendingStatus == "scheduled" ? "Reason" : "Summary", text: $note)
                Button("Move") { if let s = pendingStatus { apply(s, note: note) } }
                Button("Cancel", role: .cancel) { cancelMove() }
            }
        }
    }

    private func cancelMove() {
        pendingStatus = nil
        if let task { status = task.status }
    }

    private func apply(_ new: String, note: String) {
        pendingStatus = nil
        guard let task else { return }
        Task {
            do {
                let isReason = new == "blocked" || new == "scheduled"
                try await KanbanClient.move(task.id, to: new, reason: isReason ? note : nil, summary: isReason ? nil : note)
                await load(); await onChange()
            } catch { status = task.status; self.error = error.localizedDescription }
        }
    }

    private func load() async {
        do {
            let (t, c) = try await KanbanClient.task(taskID)
            task = t; comments = c; status = t.status; error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func post() {
        let text = newComment.trimmingCharacters(in: .whitespacesAndNewlines)
        newComment = ""
        Task {
            do { try await KanbanClient.comment(taskID, text); await load() }
            catch { self.error = error.localizedDescription }
        }
    }
}
