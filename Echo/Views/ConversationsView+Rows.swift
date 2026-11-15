import SwiftUI

// The chat list's sections and rows: the server's chats, message search, saved copies and local chats.

extension ConversationsList {
    // MARK: - Ledger (gateway)

    @ViewBuilder
    var ledgerSection: some View {
        if let ledgerError, ledger.isEmpty {
            ConnectionProblemCard(message: ledgerError,
                                  retry: { Task { await refresh() } },
                                  openSettings: { openSettings() })
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            // The server can't be reached: what this iPhone kept of its conversations can still be read.
            savedCopiesSection
        } else if let ledgerError {
            // A failed rename/pin/delete must not blank the loaded list; show it inline.
            Label(ledgerError, systemImage: "exclamationmark.triangle")
                .chatFont(.footnote).foregroundStyle(.orange).listRowSeparator(.hidden)
            if let id = savedCopyOffered, let copy = store.summaries.first(where: { $0.id == id }) {
                Button("Open the copy on this iPhone, from \(DateGroup.rowTime(copy.updatedAt))", systemImage: "internaldrive") { openSaved(copy) }
                    .chatFont(.footnote)
                    .listRowSeparator(.hidden)
            }
        } else if ledger.isEmpty && !loading {
            ContentUnavailableView("No conversations yet", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Conversations from every platform appear here."))
                .listRowSeparator(.hidden)
        }
        if !serversUnreachable.isEmpty {   // (empty unless All Servers is on)
            Label(serversUnreachable.count == 1
                  ? String(localized: "\(serversUnreachable.formatted()) didn't answer, so its chats aren't here.", comment: "%@ is one server's name")
                  : String(localized: "\(serversUnreachable.formatted()) didn't answer, so their chats aren't here.", comment: "%@ is a list of servers' names"),
                  systemImage: "wifi.exclamationmark")
                .chatFont(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
        }
        let rows = visibleLedger
        let pinned = rows.filter { $0.pinned == true }
        let runs = rows.filter(Self.isFoldable)
        let drafted = draftedSessions
        if !pinned.isEmpty {
            Section { ForEach(pinned) { ledgerButton($0, hasDraft: drafted.contains($0.id)) } } header: { groupHeader(String(localized: "Pinned")) }
        }
        ForEach(DateGroup.group(rows.filter { $0.pinned != true && !$0.isScheduledRun }, by: { $0.lastActiveDate }), id: \.title) { group in
            Section { ForEach(group.items) { ledgerButton($0, hasDraft: drafted.contains($0.id)) } } header: { groupHeader(group.title) }
        }
        // Hermes makes a session of every run of a scheduled job, and a busy schedule buried
        // the conversations (GitHub issue 19): the runs wait at the end, folded unless opened.
        if !runs.isEmpty {
            Section {
                if showScheduled { ForEach(runs) { ledgerButton($0, hasDraft: drafted.contains($0.id)) } }
            } header: {
                foldingHeader(String(localized: "Scheduled runs"), count: runs.count, isOpen: $showScheduled)
            }
        }
    }

    // MARK: - Searching inside messages

    /// Conversations that match only inside their messages: the ones the search field's own
    /// filter (titles, previews) already lists above are left out.
    @ViewBuilder
    var messageHitsSection: some View {
        let typed = query.trimmingCharacters(in: .whitespaces)
        let listed = Set(visibleLedger.map(\.id))
        let hits = messageHits.filter { !listed.contains($0.id) }
        if typed.count >= Self.messageSearchMinimum, searchingMessages || !hits.isEmpty || messageSearchProblem != nil {
            Section {
                ForEach(hits) { hit in
                    Button { open(hit.session, find: hit.findText(typed: typed)) } label: { messageHitRow(hit) }
                        .buttonStyle(.plain)
                        .opensConversation()
                        .disabled(opening != nil)
                }
                if let messageSearchProblem {
                    Label(messageSearchProblem, systemImage: "exclamationmark.triangle")
                        .chatFont(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
                }
            } header: {
                HStack(spacing: 6) {
                    groupHeader(String(localized: "In messages"))
                    if searchingMessages { ProgressView().controlSize(.mini) }
                }
            }
        }
    }

    /// Title and when, then who said it and the matching words, marked.
    private func messageHitRow(_ hit: MessageSearchHit) -> some View {
        let session = hit.session
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(session.displayTitle).chatFont(.body, weight: .semibold).lineLimit(1)
                Spacer(minLength: 8)
                if opening == session.id {
                    ProgressView().controlSize(.small)
                } else if let when = session.lastActiveDate {
                    Text(DateGroup.rowTime(when)).chatFont(.caption).foregroundStyle(.secondary)
                }
            }
            Text(Self.snippetText(hit, accent: Settings.shared.resolvedTheme.accent))
                .chatFont(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if hit.archived || !["api_server", "api-server", ""].contains(session.source ?? "") {
                HStack(spacing: 6) {
                    if !["api_server", "api-server", ""].contains(session.source ?? "") { capsule(session.sourceLabel) }
                    if hit.archived { capsule(String(localized: "Archived", comment: "A conversation that was archived")) }
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this conversation at the match")
    }

    private func capsule(_ text: String) -> some View {
        Text(text)
            .chatFont(.caption2, weight: .semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.quaternary, in: .capsule)
    }

    /// "You: …the >>>words<<< that matched…", the matched words in the accent and bold.
    static func snippetText(_ hit: MessageSearchHit, accent: Color) -> AttributedString {
        var out = AttributedString()
        if let speaker = hit.speaker {
            var who = AttributedString(speaker + ": ")
            who.font = .subheadline.weight(.semibold)
            out += who
        }
        for run in hit.runs {
            var piece = AttributedString(run.text)
            if run.matched {
                piece.font = .subheadline.weight(.semibold)
                piece.foregroundColor = accent
            }
            out += piece
        }
        return out
    }

    static let messageSearchMinimum = 2

    /// The search behind "In messages", a moment after typing stops. Quiet about a Hermes
    /// without the route (it predates 0.21): the titles above are then all there is.
    func searchMessages() async {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard searchesMessages, typed.count >= Self.messageSearchMinimum else {
            messageHits = []
            messageSearchProblem = nil
            searchingMessages = false
            return
        }
        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
        searchingMessages = true
        defer { if !Task.isCancelled { searchingMessages = false } }
        do {
            let hits = try await HermesServeClient.shared.searchMessages(typed)
            guard !Task.isCancelled else { return }
            messageHits = hits
            messageSearchProblem = nil
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            messageHits = []
            if case let .http(status, _) = error as? TransportError, status == 404 {
                messageSearchProblem = nil
            } else {
                messageSearchProblem = String(localized: "Couldn't search inside messages: \(error.localizedDescription)")
            }
        }
    }

    /// Quick capture's notes that haven't reached the server yet (`CaptureInbox`): shown until
    /// they have, so that a note is never somewhere nobody can see it. A swipe throws one away.
    @ViewBuilder
    var waitingNotesSection: some View {
        let notes = CaptureInbox.shared.waiting
        if !notes.isEmpty {
            Section {
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.text).lineLimit(3)
                        Text(DateGroup.rowTime(note.at)).chatFont(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .selectionDisabled()
                    .swipeActions { Button("Delete", role: .destructive) { CaptureInbox.shared.remove(note.id) } }
                }
            } header: {
                groupHeader(String(localized: "Notes waiting to be sent"))
            } footer: {
                Text("Filed as soon as your server can be reached, in a chat called Notes.")
            }
        }
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .chatFont(.footnote, weight: .semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func marks(_ session: HermesSessionsAPI.SessionSummary) -> ChatMarks {
        ChatMarks(kind: activity.kind(of: session.id, open: conversation),
                  unread: activity.isUnread(session, open: conversation))
    }

    private func ledgerButton(_ session: HermesSessionsAPI.SessionSummary, hasDraft: Bool) -> some View {
        Group {
            if let bot = botChatRows[session.id] {
                botRow(bot, face: botDirectory.roster?.faces[bot.name] ?? BotFace(seed: bot.name), labelled: true)
            } else if let server = session.otherServer {
                remoteButton(session, on: server, hasDraft: hasDraft)
            } else {
                ownButton(session, hasDraft: hasDraft)
            }
        }
    }

    /// Another server's row (All Servers): it opens on its server, and is changed there.
    private func remoteButton(_ session: HermesSessionsAPI.SessionSummary, on server: ServerTag, hasDraft: Bool) -> some View {
        Button { if !selecting { open(session) } } label: { ledgerRow(session, hasDraft: hasDraft, marks: ChatMarks(kind: nil, unread: session.unread == true)) }
            .buttonStyle(.plain)
            .opensConversation()
            .tag(session.id)
            .selectionDisabled()
            .disabled(opening != nil)
            .contextMenu {
                Button("Open on \(server.name)", systemImage: "server.rack") { open(session) }
            }
            .accessibilityHint("Opens it on \(server.name); Redde moves to that server")
    }

    private func ownButton(_ session: HermesSessionsAPI.SessionSummary, hasDraft: Bool) -> some View {
        let marks = marks(session)
        // The open conversation is read whatever it is marked: leaving it marks it read again.
        // Another server's row (All Servers): what it can do is its own server's, done there
        // (`SessionBackend.owning`); what goes by the server in use (marks, usage, forks) is left out.
        let own = session.otherServer.flatMap { tag in settings.servers.first { $0.id == tag.id } }
        let kind = own?.transport ?? settings.transport
        let home = session.otherServer == nil
        let canMark = home && session.id != conversation.serverSessionID && settings.transport.isHermes
        // ACP version 1 has no pins, archive or forks for a chat (`SessionBackend.acp`).
        let hermes = kind.isHermes
        return Button { if !selecting { open(session) } } label: { ledgerRow(session, hasDraft: hasDraft, marks: marks) }
            .buttonStyle(.plain)
            .opensConversation()
            .tag(session.id)
            .listRowBackground(groups.open == nil && session.id == conversation.serverSessionID ? Settings.shared.resolvedTheme.accent.opacity(0.08) : Settings.shared.theme.listPage)
            .disabled(opening != nil)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if canMark {
                    Button { setUnread(session, !marks.unread) } label: {
                        Label(marks.unread ? String(localized: "Read", comment: "Swipe action that marks the conversation as read (“read” as in “has been read”)")
                                           : String(localized: "Unread", comment: "A conversation not yet read; also the swipe action that marks it so"),
                              systemImage: marks.unread ? "checkmark.message" : "message.badge")
                    }
                    .tint(Settings.shared.resolvedTheme.accent)
                }
                if hermes {
                    Button { setPinned(session, !(session.pinned ?? false)) } label: {
                        Label(session.pinned == true ? String(localized: "Unpin") : String(localized: "Pin", comment: "Pins the conversation to the top of the list"),
                              systemImage: session.pinned == true ? "pin.slash" : "pin")
                    }
                    .tint(.orange)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { delete(session) } label: { Label("Delete", systemImage: "trash") }
                if hermes, home {
                    Button { archive(session) } label: { Label("Archive", systemImage: "archivebox") }
                        .tint(.gray)
                }
            }
            .contextMenu {
                if canMark {
                    Button(marks.unread ? String(localized: "Mark as Read") : String(localized: "Mark as Unread"),
                           systemImage: marks.unread ? "checkmark.message" : "message.badge") {
                        setUnread(session, !marks.unread)
                    }
                }
                if hermes {
                    if home { Button("Usage & cost", systemImage: "chart.bar") { usageFor = session } }
                    Button("Rename", systemImage: "pencil") { renameText = session.title ?? ""; renaming = session }
                    Button(session.pinned == true ? String(localized: "Unpin") : String(localized: "Pin", comment: "Pins the conversation to the top of the list"),
                           systemImage: "pin") { setPinned(session, !(session.pinned ?? false)) }
                    if home { Button("Fork", systemImage: "arrow.triangle.branch") { fork(session) } }
                } else if kind == .acp {
                    // Every bridge chat can be named: on the agent where it keeps names (or the
                    // bridge keeps them for it), on this device where neither does (`AcpTitles`).
                    Button("Rename", systemImage: "pencil") { renameText = session.title ?? ""; renaming = session }
                    if home, AcpClient.current(settings)?.info?.canFork == true {
                        Button("Fork", systemImage: "arrow.triangle.branch") { fork(session) }
                    }
                }
                if home { moveMenu(for: session) }
                Button("Export as Markdown", systemImage: "square.and.arrow.up") { export(session) }
                if hermes, home { Button("Archive", systemImage: "archivebox") { archive(session) } }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { delete(session) }
            }
    }

    private func ledgerRow(_ session: HermesSessionsAPI.SessionSummary, hasDraft: Bool, marks: ChatMarks) -> some View {
        rowBody(session, hasDraft: hasDraft, marks: marks)
            .unreadDot(marks.unread && !selecting)
            .accessibilityElement(children: .combine)
            .accessibilityValue(marks.spoken)
            .accessibilityHint("Opens this session")
    }

    /// Title and when on the first line, the last thing said beneath; where it came from when
    /// it wasn't this app.
    private func rowBody(_ session: HermesSessionsAPI.SessionSummary, hasDraft: Bool, marks: ChatMarks) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if session.pinned == true {
                    Image(systemName: "pin.fill").chatFont(.caption2).foregroundStyle(.orange).accessibilityLabel("Pinned")
                }
                Text(session.displayTitle).chatFont(.body, weight: .semibold).lineLimit(1)
                Spacer(minLength: 8)
                if opening == session.id || marks.kind == .working {
                    ProgressView().controlSize(.small)
                } else if let when = session.lastActiveDate {
                    Text(DateGroup.rowTime(when)).chatFont(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                if marks.kind == .needsYou { NeedsYouTag() }
                if hasDraft { draftMark }
                // Another server's, with All Servers on: which.
                if let server = session.otherServer {
                    Label(server.name, systemImage: "server.rack")
                        .labelStyle(.titleAndIcon)
                        .chatFont(.caption2, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                        .lineLimit(1)
                        .fixedSize()
                }
                // With every agent in one list: which agent it's with.
                if let agent = session.acpAgent {
                    let bridge = session.otherServer.flatMap { tag in settings.servers.first { $0.id == tag.id }?.acpURL } ?? settings.acpURL
                    Label(AcpAgents.name(of: agent, address: bridge), systemImage: "terminal")
                        .labelStyle(.titleAndIcon)
                        .chatFont(.caption2, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                        .lineLimit(1)
                        .fixedSize()
                }
                // Another profile's, with All Profiles on: whose it is.
                if let route = session.elsewhere {
                    Text(profileLabel(route.profile))
                        .chatFont(.caption2, weight: .semibold)
                        .foregroundStyle(Settings.shared.resolvedTheme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Settings.shared.resolvedTheme.accent.opacity(0.14), in: .capsule)
                        .lineLimit(1)
                        .fixedSize()
                }
                if let source = session.source, !["api_server", "api-server"].contains(source) {
                    Text(session.sourceLabel)
                        .chatFont(.caption2, weight: .semibold)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }
                Text(session.shownPreview.map(ServeMedia.preview) ?? session.message_count.map { String(localized: "\($0) messages") } ?? " ")
                    .lineLimit(1)
            }
            .chatFont(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// "Draft", in front of a row's second line: something was written there and not sent.
    private var draftMark: some View {
        Text("Draft")
            .chatFont(.subheadline, weight: .semibold)
            .foregroundStyle(Settings.shared.resolvedTheme.accent)
            .accessibilityLabel("Has a draft")
    }

    /// The server conversations with a draft waiting, by their id on the server. Drafts are kept
    /// by a conversation's id on this iPhone; the server's list knows only its own.
    private var draftedSessions: Set<String> {
        Self.drafted(drafts.waiting, in: store.summaries)
    }

    static func drafted(_ waiting: Set<String>, in summaries: [ConversationSummary]) -> Set<String> {
        guard !waiting.isEmpty else { return [] }
        return Set(summaries.filter { waiting.contains($0.id.uuidString) }.compactMap(\.serverSessionID))
    }

    // MARK: - Saved copies (the server can't be reached)

    /// This server's conversations as this iPhone last saw them: every one that was opened or
    /// held here is kept on the device (`ConversationStore`), so it can be read with no
    /// connection. Newest first, as the store has them.
    static func savedCopies(in summaries: [ConversationSummary], server: UUID, matching query: String) -> [ConversationSummary] {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        return summaries.filter {
            $0.serverSessionID != nil && $0.transport != .chatCompletions && ($0.serverID ?? server) == server
                && (wanted.isEmpty || $0.title.localizedCaseInsensitiveContains(wanted))
        }
    }

    @ViewBuilder
    private var savedCopiesSection: some View {
        let copies = Self.savedCopies(in: store.sorted, server: settings.activeServerID, matching: query)
        if !copies.isEmpty {
            Section {
                ForEach(copies) { copy in
                    Button { openSaved(copy) } label: { savedRow(copy) }
                        .buttonStyle(.plain)
                        .opensConversation()
                        .listRowBackground(copy.id == conversation.id ? Settings.shared.resolvedTheme.accent.opacity(0.08) : Settings.shared.theme.listPage)
                }
            } header: {
                groupHeader(String(localized: "On this iPhone"))
            } footer: {
                Text("As each conversation was when it was last open here. A message you send now waits, and goes when the connection is back.")
            }
        }
    }

    private func savedRow(_ copy: ConversationSummary) -> some View {
        keptRow(copy, caption: String(localized: "Saved copy · \(Self.turns(copy))", comment: "A conversation kept on this iPhone, and how many turns it has"))
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the copy kept on this iPhone")
    }

    private func openSaved(_ copy: ConversationSummary) {
        guard !selecting else { return }
        Task {
            guard let full = await store.loadRecord(id: copy.id) else { return }
            conversation.load(full)
            savedCopyOffered = nil
            opened()
        }
    }

    // MARK: - Local (fast lane)

    @ViewBuilder
    var localSection: some View {
        if store.sorted.isEmpty {
            ContentUnavailableView("No conversations yet", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Finished conversations show up here."))
                .listRowSeparator(.hidden)
        }
        ForEach(DateGroup.group(visibleLocal, by: { $0.updatedAt }), id: \.title) { group in
            Section { ForEach(group.items) { localButton($0) } } header: { groupHeader(group.title) }
        }
    }

    private func localButton(_ record: ConversationSummary) -> some View {
            Button {
                if selecting { return }
                // Decoded off the main actor (a long transcript is a big file), and opened once it
                // is, so the conversation before doesn't show in the meantime.
                Task {
                    if let full = await store.loadRecord(id: record.id) { conversation.load(full) }
                    opened()
                }
            } label: {
                localRow(record)
            }
            .buttonStyle(.plain)
            .opensConversation()
            .tag(record.id.uuidString)
            .listRowBackground(record.id == conversation.id ? Settings.shared.resolvedTheme.accent.opacity(0.08) : Settings.shared.theme.listPage)
            .contextMenu {
                Button("Export as Markdown", systemImage: "square.and.arrow.up") {
                    Task {
                        // Decode and write off the main actor; a long transcript is a big file.
                        guard let full = await store.loadRecord(id: record.id),
                              let url = try? await TranscriptExporter.export(title: record.title, messages: full.messages) else { return }
                        shareItem = ShareItem(url: url)
                    }
                }
                Button("Delete", systemImage: "trash", role: .destructive) { conversation.delete(id: record.id) }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { conversation.delete(id: record.id) } label: { Label("Delete", systemImage: "trash") }
            }
    }

    private func localRow(_ record: ConversationSummary) -> some View {
        keptRow(record, caption: "\(Self.turns(record)) · \(record.transport == .chatCompletions ? String(localized: "OpenAI-compatible") : "Hermes")")
    }

    /// A conversation kept on this iPhone, as a row: its title and when it was last used, then
    /// the "Draft" mark if it has one and what there is to say about it.
    private func keptRow(_ record: ConversationSummary, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(record.title).chatFont(.body, weight: .semibold).lineLimit(1)
                Spacer(minLength: 8)
                Text(DateGroup.rowTime(record.updatedAt)).chatFont(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if drafts.isWaiting(record.id) { draftMark }
                Text(caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .chatFont(.subheadline)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// "1 turn", "12 turns".
    private static func turns(_ record: ConversationSummary) -> String {
        String(localized: "\(record.turnCount) turns", comment: "How many turns (a message and its reply) a conversation has")
    }
}

/// Today, Yesterday, This week, then month by month: how the conversation list is sectioned.
enum DateGroup {
    struct Group<Item> { let title: String; let items: [Item] }

    static func group<Item>(_ items: [Item], by date: (Item) -> Date?, now: Date = .now) -> [Group<Item>] {
        var order: [String] = []
        var buckets: [String: [Item]] = [:]
        for item in items {
            let title = title(for: date(item), now: now)
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(item)
        }
        return order.map { Group(title: $0, items: buckets[$0] ?? []) }
    }

    static func title(for date: Date?, now: Date = .now) -> String {
        guard let date else { return String(localized: "Earlier", comment: "The conversation list's section for conversations with no date") }
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return String(localized: "Yesterday") }
        if let week = cal.date(byAdding: .day, value: -7, to: now), date > week { return String(localized: "This week") }
        if cal.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.month(.wide)) }
        return date.formatted(.dateTime.month(.wide).year())
    }

    /// The time on a row: a clock time today, a weekday this week, a date before that.
    static func rowTime(_ date: Date, now: Date = .now) -> String {
        #if DEBUG
        // The agents video: what happens while it's filmed, at its 9:41 morning.
        if DemoAgents.on, let shown = DemoAgents.shown(date) { return shown.formatted(date: .omitted, time: .shortened) }
        #endif
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let week = cal.date(byAdding: .day, value: -6, to: now), date > week { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - The rows' marks

/// What a conversation's row shows of it (`ChatActivity`): the agent working (a spinner where
/// the time goes), waiting on the person ("Needs you"), or a reply not yet seen (a dot).
struct ChatMarks: Equatable {
    var kind: ChatActivity.Kind?
    var unread: Bool
    /// A bot's chat or a group chat the person muted (`Mutes`).
    var muted = false

    /// Read out with the row.
    var spoken: String {
        [unread ? String(localized: "Unread", comment: "A conversation not yet read; also the swipe action that marks it so") : nil,
         muted ? String(localized: "Muted", comment: "A chat whose notifications are muted") : nil,
         kind == .working ? String(localized: "Agent working") : kind == .needsYou ? String(localized: "Needs you") : nil]
            .compactMap(\.self).joined(separator: ", ")
    }
}

/// "Needs you", in front of a row's second line: the agent waits on an answer, an approval or a
/// password.
struct NeedsYouTag: View {
    var body: some View {
        Text("Needs you")
            .chatFont(.caption2, weight: .semibold)
            .foregroundStyle(.orange)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.orange.opacity(0.15), in: .capsule)
            .fixedSize()
    }
}

extension View {
    /// A dot in the row's leading margin, as Messages marks an unread conversation. In the
    /// margin, so the titles of read and unread rows still line up.
    func unreadDot(_ shown: Bool) -> some View {
        overlay(alignment: .leading) {
            if shown {
                Circle()
                    .fill(Settings.shared.resolvedTheme.accent)
                    .frame(width: 9, height: 9)
                    .offset(x: -14)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// "Bot Chat", in the bot's colour: a bot's chat among the conversations.
struct BotChatLabel: View {
    let face: BotFace
    var body: some View {
        let colour = BotAvatar.colors(of: face, theme: Settings.shared.resolvedTheme).deep
        Text("Bot Chat", comment: "Marks a bot's chat in the list of conversations")
            .chatFont(.caption2, weight: .semibold)
            .foregroundStyle(colour)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(colour.opacity(0.14), in: .capsule)
            .lineLimit(1)
            .fixedSize()
    }
}
