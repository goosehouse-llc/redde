import SwiftUI

struct TranscriptView: View {
    @Environment(Conversation.self) private var conversation
    @Environment(VoiceSession.self) private var voiceSession
    @Environment(\.theme) private var theme
    @Binding var showSetup: Bool
    /// Find in conversation (⌘F / the gear menu). Owned by the parent so the toolbar can toggle it.
    @Binding var showSearch: Bool
    /// "Edit & resend" from a message's menu: the parent loads it into the composer.
    var onEdit: (Message) -> Void = { _ in }
    /// "Edit" on a message that hasn't been sent: it leaves the queue and goes back to the composer.
    var onEditQueued: (Message) -> Void = { _ in }
    @State private var searchText = ""
    @State private var matchIndex = 0
    @FocusState private var searchFocused: Bool
    /// Long sessions render only the newest page; earlier messages load on demand.
    private static let pageSize = 60
    @State private var visibleCount = TranscriptView.pageSize

    private var hiddenCount: Int { max(0, conversation.messages.count - visibleCount) }
    private var visibleMessages: ArraySlice<Message> { conversation.messages.suffix(visibleCount) }
    /// Following = the transcript tracks new text. A scroll gesture stops it and shows the
    /// arrow; tapping the arrow (or scrolling back to the end) resumes it.
    @State private var following = true
    @State private var atBottom = true
    @State private var scrollPhase: ScrollPhase = .idle
    /// The visible bottom edge is below the end of the content: blank space after the last
    /// message, left behind when rows shrink after a jump.
    @State private var pastEnd = false
    /// Keeps the jump arrow's scroll going until the newest message is actually on screen.
    @State private var jumpTask: Task<Void, Never>?
    @State private var serve = HermesServeClient.shared
    @State private var store = ConversationStore.shared
    /// The reply the speaker button is reading, so only its button turns into Stop.
    @State private var readingID: UUID?
    /// The pick-up card's line: the last thing you sent in that conversation.
    @State private var pickUpLine: String?

    /// "Today" / "Yesterday" / a date where the day changes between messages. Computed once per
    /// message-count change rather than by searching the array from every row.
    @State private var dayLabels: [UUID: String] = [:]

    private func recomputeDayLabels() {
        let cal = Calendar.current
        var out: [UUID: String] = [:]
        var previous: Date?
        for m in conversation.messages {
            defer { previous = m.createdAt }
            if let previous, cal.isDate(previous, inSameDayAs: m.createdAt) { continue }
            if previous == nil, cal.isDateInToday(m.createdAt) { continue }
            out[m.id] = cal.isDateInToday(m.createdAt) ? "Today"
                : cal.isDateInYesterday(m.createdAt) ? "Yesterday"
                : m.createdAt.formatted(.dateTime.weekday(.wide).month().day())
        }
        dayLabels = out
    }

    /// Messages whose text contains the query, oldest first. Recomputed when the query or the
    /// message count changes, not per row per body pass (the bar stays open while streaming).
    @State private var matches: [UUID] = []

    private func recomputeMatches() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        matches = showSearch && !q.isEmpty ? conversation.messages.filter { $0.text.localizedCaseInsensitiveContains(q) }.map(\.id) : []
    }

    private func highlight(for id: UUID) -> MessageRow.Highlight {
        guard let i = matches.firstIndex(of: id) else { return .none }
        return i == matchIndex ? .current : .match
    }

    /// Moves to a match, paging in earlier messages if it's above the visible window.
    private func goToMatch(_ index: Int, _ proxy: ScrollViewProxy) {
        let list = matches
        guard !list.isEmpty else { return }
        matchIndex = ((index % list.count) + list.count) % list.count
        let id = list[matchIndex]
        if let position = conversation.messages.firstIndex(where: { $0.id == id }), position < hiddenCount {
            visibleCount = conversation.messages.count - position + Self.pageSize / 2
        }
        following = false
        Task { withAnimation { proxy.scrollTo(id, anchor: .center) } }
    }

    /// The jump arrow. Mid-fling only an unanimated jump stops the momentum. Rows that finish
    /// loading async content (images, diagrams) can still grow after the jump and leave it
    /// short, so keep jumping until the end is on screen (or the reader touches the list again).
    private func jumpToEnd(_ proxy: ScrollViewProxy) {
        following = true
        if scrollPhase == .idle {
            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
        jumpTask?.cancel()
        jumpTask = Task {
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, following else { return }
                guard scrollPhase == .idle else { continue }
                if atBottom { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// Out of the blank space below the last message, back onto it.
    private func settleAtEnd(_ proxy: ScrollViewProxy) {
        following = true
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, force: Bool = false) {
        guard force || following else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Deliberately NOT lazy: a lazy stack materializes rows above the viewport at
                // their real heights as you scroll back, and every materialization shifts the
                // content under your finger — the page-sized jumps that kept happening. Pagination
                // (visibleCount) already bounds the row count, and MessageRow is Equatable, so
                // laying the whole page out upfront is affordable and makes backward scrolling
                // pixel-stable. If a session pages in enough history to feel heavy, cap
                // visibleCount rather than reintroducing laziness here.
                VStack(alignment: .leading, spacing: 14) {
                    if conversation.messages.isEmpty, conversation.outbox.isEmpty { emptyState }
                    if hiddenCount > 0 {
                        Button {
                            let anchor = visibleMessages.first?.id
                            visibleCount += Self.pageSize
                            if let anchor { Task { proxy.scrollTo(anchor, anchor: .top) } }
                        } label: {
                            Label("Show earlier messages (\(hiddenCount))", systemImage: "arrow.up.circle")
                                .font(.footnote)
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .accessibilityHint("Loads the previous \(min(Self.pageSize, hiddenCount)) messages")
                    }
                    ForEach(visibleMessages) { message in
                        messageCell(message)
                    }
                    if let pending = conversation.pendingInterrupt {
                        InterruptCard(interrupt: pending.interrupt)
                    }
                    if let status = conversation.statusLine {
                        Label(status, systemImage: "ellipsis.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 6)
                    }
                    // Row identity is prefixed: a message moving between the transcript and the outbox
                    // keeps its UUID, and the stack would otherwise reuse the old bubble for it.
                    ForEach(Array(conversation.outbox.enumerated()), id: \.element.rowID) { index, item in
                        QueuedMessageRow(item: item, isFirst: index == 0,
                                         onSend: { conversation.sendQueuedNow(item.id) },
                                         onEdit: { if let m = conversation.removeQueued(item.id) { onEditQueued(m) } },
                                         onDelete: { conversation.removeQueued(item.id) })
                            .transition(.opacity)
                            .id(item.rowID)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(conversation.messages.isEmpty ? .top : .bottom, for: .initialOffset)
            // A blanket bottom anchor also re-aims on every content-size change. Scrolling back
            // through history, lazy rows above the viewport materialize at their real heights
            // (markdown, images, diagrams) and each change re-anchored the scroll to keep the
            // BOTTOM stable — yanking the reading position up and down by page-sized deltas.
            // Anchor size changes to the bottom only while following the live stream (where it
            // keeps the newest text pinned); reading back keeps the default offset behavior.
            .defaultScrollAnchor(following ? .bottom : nil, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { g in
                // Visible bottom edge in content space, insets (composer, nav bar) excluded.
                let visibleBottom = g.contentOffset.y + g.containerSize.height - g.contentInsets.bottom
                let fits = g.contentSize.height <= g.containerSize.height - g.contentInsets.top - g.contentInsets.bottom
                return fits || visibleBottom >= g.contentSize.height - 120
            } action: { _, isAtBottom in
                atBottom = isAtBottom
                // Drifting back to the end by hand counts as catching up, but only at rest:
                // mid-fling the content height can still shift (async images/diagrams) and
                // briefly read as "at the end", which hid the jump arrow while it was being
                // reached for.
                if isAtBottom, !following, scrollPhase == .idle { following = true }
            }
            // Rows that shrink after the jump (diagrams, math, images) can leave blank space below
            // the last message; once the scroll view is at rest, settle back onto it.
            .onScrollGeometryChange(for: Bool.self) { g in
                let visibleBottom = g.contentOffset.y + g.containerSize.height - g.contentInsets.bottom
                let fits = g.contentSize.height <= g.containerSize.height - g.contentInsets.top - g.contentInsets.bottom
                return !fits && visibleBottom > g.contentSize.height + 24
            } action: { _, isPastEnd in
                pastEnd = isPastEnd
                if isPastEnd, scrollPhase == .idle { settleAtEnd(proxy) }
            }
            .onScrollPhaseChange { _, phase in
                scrollPhase = phase
                // A finger on the transcript means "let me read"; stop tracking new text.
                if phase == .interacting { following = false; jumpTask?.cancel() }
                if phase == .idle, pastEnd {
                    settleAtEnd(proxy)
                } else if phase == .idle, atBottom, !following {
                    following = true
                }
            }
            .environment(\.lazyWebBlocks, true)
            .overlay(alignment: .bottomTrailing) { jumpButton(proxy) }
            .animation(.easeOut(duration: 0.2), value: following)
            .safeAreaInset(edge: .top, spacing: 0) { reconnectBanner }
            .safeAreaInset(edge: .top, spacing: 0) { if showSearch { searchBar(proxy) } }
            .onChange(of: showSearch) { _, on in
                if on { searchFocused = true } else { searchText = ""; matchIndex = 0 }
                recomputeMatches()
            }
            .onChange(of: searchText) { recomputeMatches(); matchIndex = 0; goToMatch(0, proxy) }
            .animation(.easeOut(duration: 0.25), value: reconnectText)
            .modifier(TurnFeedback(conversation: conversation))
            // Opening the screen, or loading a session's history: start at the newest message.
            .onAppear { scrollToBottom(proxy, force: true) }
            .onChange(of: conversation.id) { visibleCount = Self.pageSize; following = true; recomputeDayLabels(); recomputeMatches(); scrollToBottom(proxy, force: true) }
            .onChange(of: conversation.messages.count, initial: true) { recomputeDayLabels(); recomputeMatches(); scrollToBottom(proxy) }
            // Sending your own message (send, steer, or send-now on a held message) jumps to the
            // end from wherever you are; a reply appended while you read does not.
            .onChange(of: conversation.userSendCount) { jumpToEnd(proxy) }
            // The streaming reply grows without changing the count; its matches append at the end.
            .onChange(of: conversation.messages.last?.text) { if showSearch { recomputeMatches() }; scrollToBottom(proxy) }
            .onChange(of: conversation.outbox.count) { old, new in
                if new > old { following = true }
                scrollToBottom(proxy)
            }
            .animation(.easeOut(duration: 0.2), value: conversation.outbox)
            .onChange(of: conversation.messages.last?.reasoning.count) { scrollToBottom(proxy) }
            // Keyboard rising: keep the newest message in view above the composer, unless the
            // reader has scrolled up on purpose. Re-check once the system's own animation ends.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                guard following else { return }
                let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
                withAnimation(.easeOut(duration: duration)) { proxy.scrollTo("bottom", anchor: .bottom) }
                Task {
                    try? await Task.sleep(for: .seconds(duration + 0.05))
                    withAnimation { scrollToBottom(proxy) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { _ in
                scrollToBottom(proxy)
            }
        }
    }

    @ViewBuilder
    private func messageCell(_ message: Message) -> some View {
        if let day = dayLabels[message.id] {
            Text(day).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.quaternary, in: .capsule)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
        }
        let live = conversation.isStreaming && message.id == conversation.messages.last?.id
        let reading = readingID == message.id && voiceSession.phase == .speaking
        MessageRow(message: message, isLive: live,
                   onRegenerate: message.role == .assistant && !conversation.isStreaming
                       ? { @MainActor @Sendable in Task { await conversation.regenerate(replyID: message.id) } } : nil,
                   onEdit: message.role == .user && !message.isSteer && !conversation.isStreaming
                       ? { @MainActor @Sendable in onEdit(message) } : nil,
                   onReadAloud: message.role == .assistant
                       ? { @MainActor @Sendable in readAloud(message) } : nil,
                   isReading: reading,
                   highlight: highlight(for: message.id))
            .equatable()
            .siriMessage(conversationID: conversation.id, messageID: message.id)
            .id(message.id)
    }

    /// The speaker button: read this reply, or stop if it's the one being read.
    private func readAloud(_ message: Message) {
        if voiceSession.phase == .speaking {
            let wasThis = readingID == message.id
            voiceSession.stopSpeaking()
            readingID = nil
            if wasThis { return }
        }
        guard voiceSession.phase == .idle || { if case .error = voiceSession.phase { true } else { false } }() else { return }
        readingID = message.id
        voiceSession.readAloud(message.text)
    }

    @ViewBuilder
    private func jumpButton(_ proxy: ScrollViewProxy) -> some View {
        if !following, !conversation.messages.isEmpty {
            Button {
                jumpToEnd(proxy)
            } label: {
                Image(systemName: conversation.isStreaming ? "arrow.down.to.line" : "arrow.down")
                    .font(.callout.weight(.semibold))
                    .padding(10)
            }
            .buttonStyle(.glass)
            .padding(.trailing, 16).padding(.bottom, 10)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel(conversation.isStreaming ? "Jump to the live reply" : "Jump to the newest message")
        }
    }

    /// Find in conversation: a field, the match count, and arrows to step through matches.
    private func searchBar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in conversation", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused($searchFocused)
                .onSubmit { goToMatch(matchIndex + 1, proxy) }
                .submitLabel(.search)
            if !searchText.isEmpty {
                Text(matches.isEmpty ? "0" : "\(matchIndex + 1) of \(matches.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(matches.isEmpty ? "No matches" : "Match \(matchIndex + 1) of \(matches.count)")
            }
            Button("Previous match", systemImage: "chevron.up") { goToMatch(matchIndex - 1, proxy) }
                .disabled(matches.count < 2)
            Button("Next match", systemImage: "chevron.down") { goToMatch(matchIndex + 1, proxy) }
                .disabled(matches.count < 2)
            Button("Done") { showSearch = false }
                .font(.body.weight(.semibold))
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Reconnect strip for hermes serve; disappears on its own.
    @ViewBuilder
    private var reconnectBanner: some View {
        if Settings.shared.transport == .hermesServe, let text = reconnectText {
            Label(text, systemImage: "wifi.exclamationmark")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(.orange.opacity(0.15))
                .foregroundStyle(.orange)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var reconnectText: String? {
        switch serve.state {
        case let .reconnecting(attempt): "Reconnecting to Redde serve… (try \(attempt))"
        case let .failed(reason): "Redde serve: \(reason)"
        default: nil
        }
    }

    /// A new conversation: a greeting at the top, and a way back into the last one.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.greeting(for: .now))
                Text("What should \(Settings.shared.headerTitle) look into?")
                    .foregroundStyle(.secondary)
            }
            .font(.system(.title, weight: .bold))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if !Settings.shared.isConfigured {
                Button("Connect to your assistant…") { showSetup = true }
                    .buttonStyle(.borderedProminent)
            } else if let last = pickUp {
                Button {
                    if let record = store.record(id: last.id) { conversation.load(record) }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Pick up where you left off")
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                            Text(pickUpLine ?? last.title)
                                .font(.body)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.surface ?? Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens your most recent conversation")
                .task(id: last.id) {
                    // One line: the newest thing you sent there, newlines folded into spaces.
                    // Decoded off the main actor: it can be a long session the reader never opens.
                    let sent = await store.loadRecord(id: last.id)?.messages.last { $0.role == .user && !$0.text.isEmpty }?.text
                    pickUpLine = sent?.split(whereSeparator: \.isNewline).joined(separator: " ")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 36)
    }

    /// The most recent other conversation on this phone, if there is one.
    private var pickUp: ConversationSummary? {
        store.sorted.first { $0.id != conversation.id && $0.turnCount > 0 }
    }

    private static func greeting(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning."
        case 12..<17: "Good afternoon."
        case 17..<22: "Good evening."
        default: "Hello."
        }
    }
}
