import SwiftUI

struct ProjectSessionsView: View {
    let project: HermesServeClient.Project
    let open: (HermesSessionsAPI.SessionSummary) async throws -> Void
    let currentID: String?
    /// Starts a conversation in this project (its folder); nil where that isn't offered.
    var startNew: ((HermesServeClient.Project) -> Void)? = nil
    /// Asks the Dashboard for the project's chats again; an ACP folder's are the list's already.
    var refreshes = true
    @Environment(\.sidePanelParked) private var panelParked
    @State private var lanes: [HermesServeClient.Project.Lane] = []
    @State private var error: String?
    @State private var loading = true
    @State private var query = ""
    /// Which row is being resumed, and why it failed. Without these the screen looks inert
    /// while a long transcript loads, and says nothing at all when the load fails.
    @State private var opening: String?
    @State private var openError: String?
    @Environment(Conversation.self) private var conversation
    @State private var activity = ChatActivity.shared

    var body: some View {
        List {
            if let error {
                ContentUnavailableView("Couldn't load the project", systemImage: "wifi.exclamationmark", description: Text(error))
                    .listRowSeparator(.hidden)
            } else if lanes.allSatisfy(\.sessions.isEmpty), !loading {
                ContentUnavailableView {
                    Label("No conversations yet", systemImage: "folder")
                } description: {
                    if canStart, let path = project.path {
                        VStack(spacing: 6) {
                            Text("Conversations started here work in its folder on your server:")
                            Text(path).chatFont(.footnote, design: .monospaced).textSelection(.enabled)
                        }
                    }
                } actions: {
                    if canStart { Button("New Conversation") { startNew?(project) }.buttonStyle(.borderedProminent) }
                }
                .listRowSeparator(.hidden)
            }
            ForEach(lanes) { lane in
                let rows = filtered(lane.sessions)
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { session in
                            Button { openRow(session) } label: { row(session) }
                                .buttonStyle(.plain)
                                .opensConversation()
                                .disabled(opening != nil)
                                .listRowBackground(session.id == currentID ? Settings.shared.resolvedTheme.accent.opacity(0.08) : Settings.shared.theme.listPage)
                        }
                    } header: {
                        if lanes.count > 1 || lane.label != "main" {
                            HStack(spacing: 4) {
                                if let r = lane.repoLabel, r != project.label { Text(r); Text("/") }
                                Text(lane.label)
                            }
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.plain)
        #endif
        .themedPage(Settings.shared.theme.listPage)
        .navigationTitle(project.label)
        .toolbarVisibility(panelParked ? .hidden : .automatic, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canStart {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Conversation", systemImage: "square.and.pencil") { startNew?(project) }
                        .accessibilityHint("Starts a conversation in \(project.label)")
                }
            }
        }
        .searchable(text: $query, prompt: "Search in \(project.label)")
        .overlay { if loading { ProgressView() } }
        .alert("Couldn't open the session", isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            Button("OK", role: .cancel) { openError = nil }
        } message: {
            Text(openError ?? "")
        }
        .task {
            // The list already handed us this project's lanes: show them at once, then refresh.
            // A refresh that fails must not blank a folder we could already display.
            if lanes.isEmpty {
                lanes = project.lanes.filter { !$0.sessions.isEmpty }
                loading = lanes.isEmpty
            }
            #if DEBUG
            // The fixture's projects have no server behind them: what the list handed over is all.
            if DevHooks.demoProjects { loading = false; return }
            #endif
            guard refreshes else { loading = false; return }
            do {
                let full = try await HermesServeClient.shared.projectSessions(project.id)
                lanes = (full?.lanes ?? []).filter { !$0.sessions.isEmpty }
                error = nil
            } catch {
                if lanes.isEmpty { self.error = error.localizedDescription }
            }
            loading = false
        }
    }

    /// A conversation can start here: a project with a folder, not the catch-all for none.
    private var canStart: Bool { startNew != nil && project.path != nil && !project.isHome }

    private func openRow(_ session: HermesSessionsAPI.SessionSummary) {
        guard opening == nil else { return }
        opening = session.id
        Task {
            do { try await open(session) } catch { openError = error.localizedDescription }
            opening = nil
        }
    }

    private func filtered(_ rows: [HermesSessionsAPI.SessionSummary]) -> [HermesSessionsAPI.SessionSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? rows : rows.filter { $0.displayTitle.lowercased().contains(q) || ($0.shownPreview ?? "").lowercased().contains(q) }
        return list.sorted { ($0.lastActiveDate ?? .distantPast) > ($1.lastActiveDate ?? .distantPast) }
    }

    private func row(_ session: HermesSessionsAPI.SessionSummary) -> some View {
        let marks = ChatMarks(kind: activity.kind(of: session.id, open: conversation),
                              unread: activity.isUnread(session, open: conversation))
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.displayTitle).chatFont(.body).lineLimit(1)
                Spacer()
                if opening == session.id || marks.kind == .working {
                    ProgressView().controlSize(.small)
                } else if session.id == currentID {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
            HStack(spacing: 6) {
                if marks.kind == .needsYou { NeedsYouTag() }
                Text(session.sourceLabel).chatFont(.caption2, weight: .semibold)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: .capsule)
                if let when = session.lastActiveDate { Text(when, format: .relative(presentation: .named)) }
                if let n = session.message_count { Text("·"); Text("\(n) messages") }
            }
            .chatFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let p = session.shownPreview { Text(ServeMedia.preview(p)).chatFont(.footnote).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .unreadDot(marks.unread)
        .accessibilityElement(children: .combine)
        .accessibilityValue(marks.spoken)
        .accessibilityHint("Opens this session")
    }
}
