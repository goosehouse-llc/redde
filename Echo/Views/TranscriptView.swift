import SwiftUI

struct TranscriptView: View {
    @Environment(Conversation.self) private var conversation
    @Environment(VoiceSession.self) private var voiceSession
    @Environment(\.theme) private var theme
    @Environment(\.wideLayout) private var wide
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
    /// Long sessions render only the newest page (`TranscriptPage`: sized by how much it holds);
    /// earlier messages load on demand. The page is settled when messages are added or the
    /// conversation changes, never while a reply streams: a page that shrank as the reply grew
    /// would pull messages off the top under the reader. It is kept as where it starts, so a
    /// message added at the end never disturbs the rows above (`TranscriptPage.Window`).
    @State private var page = TranscriptPage.Window()

    private var hiddenCount: Int { page.hiddenCount(in: conversation.messages) }
    private var visibleMessages: ArraySlice<Message> { conversation.messages.dropFirst(hiddenCount) }
    /// Following = the transcript tracks new text. A scroll gesture stops it and shows the
    /// arrow; tapping the arrow (or scrolling back to the end) resumes it.
    @State private var following = true
    @State private var atBottom = true
    @State private var scrollPhase: ScrollPhase = .idle
    /// The visible bottom edge is below the end of the content: blank space after the last
    /// message, left behind when rows shrink after a jump.
    @State private var pastEnd = false
    /// Keeps the jump to the end going until the newest message is actually on screen.
    @State private var jumpTask: Task<Void, Never>?
    /// The UIKit scroll view under the transcript: a jump stops its coasting first.
    @State private var scrollHandle = ScrollHandle()
    /// How much conversation there was when the reader scrolled away: messages, and the length of
    /// the last one.
    @State private var leftAt: (messages: Int, lastLength: Int)?
    @State private var serve = HermesServeClient.shared
    @State private var store = ConversationStore.shared
    /// The reply the speaker button is reading, so only its button turns into Stop.
    @State private var readingID: UUID?
    /// "Copied", from a row.
    @State private var toaster = Toaster()
    /// The start screen's "Continue" card opening into its conversation.
    @State private var cardOpening: OpeningCover.Opening?
    /// The message at the top of the screen, for the other layout (`LayoutCarry`). Not state: it
    /// changes as the reader scrolls, and nothing on screen shows it.
    @State private var topRow = TopRow()

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

    /// The streaming reply grew: only it can have come to match, or (written over) stopped.
    private func recomputeLastMatch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard showSearch, !q.isEmpty, let last = conversation.messages.last else { return }
        let matched = last.text.localizedCaseInsensitiveContains(q)
        if matched, matches.last != last.id { matches.append(last.id) }
        if !matched, matches.last == last.id { matches.removeLast() }
    }

    private func highlight(for id: UUID) -> MessageRow.Highlight {
        guard let i = matches.firstIndex(of: id) else { return .none }
        return i == matchIndex ? .current : .match
    }

    /// Sizes the page for the conversation as it is now. `reset` also lets go of earlier messages
    /// the reader had loaded.
    private func settlePage(reset: Bool = false) {
        page.settle(conversation.messages, release: reset)
    }

    /// Moves to a match, paging in earlier messages if it's above the visible window.
    private func goToMatch(_ index: Int, _ proxy: ScrollViewProxy) {
        let list = matches
        guard !list.isEmpty else { return }
        matchIndex = ((index % list.count) + list.count) % list.count
        let id = list[matchIndex]
        if let position = conversation.messages.firstIndex(where: { $0.id == id }) {
            // From a little before the match to the end.
            page.reveal(position, in: conversation.messages)
        }
        following = false
        Task { withAnimation { proxy.scrollTo(id, anchor: .center) } }
    }

    /// "Jump to latest": at once, and it stops a fling where it is. An animated scroll down a long
    /// conversation took its time, and was reported as a delay (Reddit, 2026-10-21). Rows that
    /// finish loading async content (images, diagrams) can still grow after the jump and leave it
    /// short, so keep jumping until the end is on screen (or the reader touches the list again).
    private func jumpToEnd(_ proxy: ScrollViewProxy) {
        following = true
        // A fling still coasting carried on past the jump, and the corrections below waited for it
        // to end: stopped where it is first (Reddit, 2026-10-22: "a signal to terminate scroll").
        scrollHandle.stopCoasting()
        proxy.scrollTo("bottom", anchor: .bottom)
        jumpTask?.cancel()
        jumpTask = Task {
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
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

    /// Notes where the reader is and what they have open, for the other layout (`LayoutCarry`).
    private func noteForLayout() {
        LayoutCarry.shared.transcript = .init(conversation: conversation.id, wide: wide, page: page, searchText: searchText,
                                              matchIndex: matchIndex, readingID: readingID, readingFrom: following ? nil : topRow.id)
    }

    /// The transcript as it was in the other layout: the earlier messages loaded, Find's words and
    /// match, the reply being read aloud, and the place, by the message at the top of the screen.
    private func takeUp(_ carried: LayoutCarry.Transcript, _ proxy: ScrollViewProxy) {
        page = carried.page
        readingID = carried.readingID
        searchText = carried.searchText
        topRow.id = carried.readingFrom
        if carried.readingFrom != nil { following = false } else { scrollToBottom(proxy, force: true) }
        // After the rows are laid out at the new width, and after Find has gone to its first
        // match for the words put back; again a moment later, for rows that grow as they load.
        Task {
            for wait in [80, 250] {
                try? await Task.sleep(for: .milliseconds(wait))
                if !carried.searchText.isEmpty { matchIndex = carried.matchIndex }
                if let from = carried.readingFrom {
                    // Drawn at the end first, the transcript took itself to be caught up and
                    // followed it again: it doesn't, and the place stays noted for the next change.
                    following = false
                    topRow.id = from
                    proxy.scrollTo(from, anchor: .top)
                    noteForLayout()
                } else if !carried.searchText.isEmpty {
                    goToMatch(carried.matchIndex, proxy)
                } else {
                    scrollToBottom(proxy, force: true)
                }
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Deliberately NOT lazy: a lazy stack materializes rows above the viewport at
                // their real heights as you scroll back, and every materialization shifts the
                // content under your finger — the page-sized jumps that kept happening. Pagination
                // (`page`) already bounds the row count, and MessageRow is Equatable, so
                // laying the whole page out upfront is affordable and makes backward scrolling
                // pixel-stable. If a session pages in enough history to feel heavy, shrink
                // the page rather than reintroducing laziness here.
                VStack(alignment: .leading, spacing: 14) {
                    if conversation.messages.isEmpty, conversation.outbox.isEmpty {
                        StartScreen(openFromCard: { card, title, load in
                            // The card's words sit past its symbol: 16 in, 26 of symbol, 12 between.
                            OpeningCover.run($cardOpening, from: card, title: title, titleInset: 54, swap: load)
                        })
                    }
                    if hiddenCount > 0 {
                        // One more page of what comes before.
                        let earlier = page.earlierCount(in: conversation.messages)
                        Button {
                            let anchor = visibleMessages.first?.id
                            page.showEarlier(conversation.messages)
                            if let anchor { Task { proxy.scrollTo(anchor, anchor: .top) } }
                        } label: {
                            Label("Show earlier messages (\(hiddenCount))", systemImage: "arrow.up.circle")
                                .font(.footnote)
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .accessibilityHint("Loads the previous \(earlier) messages")
                    }
                    // Asked once a pass, not once a row: it reads the settings and the Keychain.
                    let canLoadTools = conversation.canLoadToolDetails
                    ForEach(visibleMessages) { message in
                        messageCell(message, canLoadTools: canLoadTools)
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
                            // A message held behind the reply rises out of the composer too.
                            .transition(.asymmetric(insertion: Self.queuedArrival, removal: .opacity))
                            .id(item.rowID)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .background(ScrollHandle.Finder(handle: scrollHandle))
                }
                .padding()
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                // The rows as scroll targets, so the one at the top can be noted (`topRow`).
                .scrollTargetLayout()
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
                TranscriptEnd.isReached(g)
            } action: { _, isAtBottom in
                atBottom = isAtBottom
                // Drifting back to the end by hand counts as catching up, but only at rest:
                // mid-fling the content height can still shift (async images/diagrams) and
                // briefly read as "at the end", which hid "Jump to latest" while it was being
                // reached for.
                if isAtBottom, !following, scrollPhase == .idle { following = true }
            }
            // Rows that shrink after the jump (diagrams, math, images) can leave blank space below
            // the last message; once the scroll view is at rest, settle back onto it.
            .onScrollGeometryChange(for: Bool.self) { g in
                TranscriptEnd.isPassed(g)
            } action: { _, isPastEnd in
                pastEnd = isPastEnd
                if isPastEnd, scrollPhase == .idle { settleAtEnd(proxy) }
            }
            .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.05) { ids in
                let shown = visibleMessages
                topRow.id = ids.compactMap { id in shown.firstIndex { $0.id == id } }.min().map { shown[$0].id }
                noteForLayout()
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
            .environment(\.asksAboutSelection, true)
            // A conversation opening out of the start screen's card comes forward as the cover clears.
            .scaleEffect(cardOpening?.contentScale ?? 1)
            .overlay(alignment: .bottom) { jumpButton(proxy) }
            // What was there when the reader scrolled away, to know when something new has come.
            .onChange(of: following) { _, following in
                leftAt = following ? nil : (conversation.messages.count, conversation.messages.last?.text.utf8.count ?? 0)
            }
            .overlay {
                // Under the header and the composer, over the whole transcript.
                if let cardOpening {
                    OpeningCover(opening: cardOpening, from: theme.surfaceColor, to: theme.pageColor, text: theme.textColor)
                }
            }
            .toast($toaster.text, duration: .seconds(1.6))
            .environment(toaster)
            .animation(.easeOut(duration: 0.2), value: offersJump)
            .safeAreaInset(edge: .top, spacing: 0) { reconnectBanner }
            .safeAreaInset(edge: .top, spacing: 0) { if conversation.isIncognito { incognitoBanner } }
            .safeAreaInset(edge: .top, spacing: 0) { if showSearch { searchBar(proxy) } }
            .onChange(of: showSearch) { _, on in
                // Opened from a message search, Find already has its words: no keyboard over the
                // match, and straight to it.
                if on { searchFocused = searchText.isEmpty } else { searchText = ""; matchIndex = 0 }
                recomputeMatches()
                if on, !searchText.isEmpty { goToMatch(0, proxy) }
            }
            .onChange(of: conversation.findRequest, initial: true) { _, wanted in
                guard let wanted, !wanted.isEmpty else { return }
                conversation.findRequest = nil
                searchText = wanted
                showSearch = true
            }
            .onChange(of: searchText) { recomputeMatches(); matchIndex = 0; goToMatch(0, proxy) }
            .animation(.easeOut(duration: 0.25), value: reconnectText)
            .modifier(TurnFeedback(conversation: conversation))
            // Opening the screen, or loading a session's history: start at the newest message. Built
            // again in the other layout (an iPhone Duo opened or closed), where the reader was.
            .onAppear {
                if let carried = LayoutCarry.shared.transcript(for: conversation.id, wide: wide) {
                    takeUp(carried, proxy)
                } else {
                    scrollToBottom(proxy, force: true)
                }
                noteForLayout()
            }
            .onChange(of: page) { noteForLayout() }
            .onChange(of: searchText) { noteForLayout() }
            .onChange(of: matchIndex) { noteForLayout() }
            .onChange(of: readingID) { noteForLayout() }
            .onChange(of: following) { noteForLayout() }
            .onChange(of: conversation.id) { settlePage(reset: true); following = true; recomputeDayLabels(); recomputeMatches(); scrollToBottom(proxy, force: true) }
            .onChange(of: conversation.messages.count, initial: true) {
                // Earlier messages the reader loaded stay; otherwise the page is sized afresh.
                settlePage()
                recomputeDayLabels(); recomputeMatches(); scrollToBottom(proxy)
            }
            // Sending your own message (send, steer, or send-now on a held message) jumps to the
            // end from wherever you are; a reply appended while you read does not. It also lets
            // go of earlier messages loaded for reading.
            .onChange(of: conversation.userSendCount) { settlePage(reset: true); jumpToEnd(proxy) }
            // The streaming reply grows without changing the count; its matches append at the end.
            .onChange(of: conversation.messages.last?.text) { recomputeLastMatch(); scrollToBottom(proxy) }
            .onChange(of: conversation.outbox.count) { old, new in
                if new > old { following = true }
                scrollToBottom(proxy)
            }
            .animation(.easeOut(duration: 0.2), value: conversation.outbox)
            // (Bytes, not characters: counting characters walks the whole of the thinking.)
            .onChange(of: conversation.messages.last?.reasoning.utf8.count) { scrollToBottom(proxy) }
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

    private static let queuedArrival: AnyTransition = .offset(y: 70).combined(with: .opacity)
        .animation(.spring(duration: 0.44, bounce: 0.2))

    /// For a reply with tools, where the gateway's stored transcript can be asked: the fetch a
    /// step runs when it is opened without its result.
    private func toolDetailsLoader(for message: Message, canLoad: Bool) -> (@MainActor @Sendable () async -> Void)? {
        guard message.role == .assistant, !message.tools.isEmpty, canLoad else { return nil }
        let (conversation, id) = (conversation, message.id)
        return { await conversation.loadToolDetails(for: id) }
    }

    @ViewBuilder
    private func messageCell(_ message: Message, canLoadTools: Bool) -> some View {
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
                   onLoadToolDetails: toolDetailsLoader(for: message, canLoad: canLoadTools),
                   isReading: reading,
                   highlight: highlight(for: message.id))
            .equatable()
            // Just sent: it rises out of the composer (and the reply's row waits a beat for it).
            .modifier(MessageArrival(kind: MessageArrival.kind(for: message, isLive: live), leading: theme.promptPrefix != nil))
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
        voiceSession.readAloud(message.text, speaker: conversation.bot?.profile)
    }

    /// Something has come in below since the reader scrolled away: a reply still being written,
    /// more of it, or another message.
    private var hasNewBelow: Bool {
        guard let leftAt else { return conversation.isStreaming }
        return conversation.isStreaming || conversation.messages.count > leftAt.messages
            || (conversation.messages.last?.text.utf8.count ?? 0) > leftAt.lastLength
    }

    /// Whether "Jump to latest" is offered: the reader has scrolled away and the end is out of
    /// reach. With the end on screen there is nowhere to jump to, so the pill goes as soon as
    /// the end comes up, not when the scrolling stops, and a touch at the end doesn't bring it
    /// out (asked 2026-10-13).
    private var offersJump: Bool { !following && !atBottom && !conversation.messages.isEmpty }

    /// "Jump to latest", once the reader has scrolled away from the end: a pill over the bottom of
    /// the transcript, with a dot when something new is waiting there.
    @ViewBuilder
    private func jumpButton(_ proxy: ScrollViewProxy) -> some View {
        if offersJump {
            Button {
                jumpToEnd(proxy)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(theme.accent)
                    Text("Jump to latest")
                        .font(.subheadline.weight(.semibold))
                    if hasNewBelow { NewBelowDot(color: theme.accent, live: conversation.isStreaming) }
                }
                .padding(.horizontal, 4).padding(.vertical, 3)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .padding(.bottom, 10)
            .transition(.offset(y: 12).combined(with: .scale(scale: 0.9)).combined(with: .opacity))
            .accessibilityLabel(conversation.isStreaming ? "Jump to the live reply" : "Jump to the newest message")
            .accessibilityValue(hasNewBelow && !conversation.isStreaming ? "New messages below" : "")
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

    /// What an incognito chat is, in sight while it is open.
    private var incognitoBanner: some View {
        Label("Incognito: kept nowhere. It's deleted from your server when you leave it, and your agent is asked to save nothing from it.",
              systemImage: "eyeglasses")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
    }

    /// Reconnect strip for hermes serve; disappears on its own.
    @ViewBuilder
    private var reconnectBanner: some View {
        if conversation.connection == .hermesServe, let text = reconnectText {
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
        #if DEBUG
        if DevHooks.demoBots { return nil }   // (the sample bots have no Dashboard login to fail on)
        #endif
        return switch serve.state {
        case let .reconnecting(attempt): "Reconnecting to the Hermes Dashboard… (try \(attempt))"
        case let .failed(reason): "Hermes Dashboard: \(reason)"
        default: nil
        }
    }
}

/// Where the end of the transcript is, from what a scroll view reports about itself.
///
/// `containerSize` is the room between the bars, and `contentOffset` is where the scroll view
/// itself begins, behind the top bar: what can be read ends at the offset plus the top inset
/// plus that room. Measured on iOS 26.3 and 27.0 at the end of a transcript 11,964 points long
/// on a 956-point screen: offset 11,091, room 699, insets 158 above and 98 below. This used to
/// be worked out as if the room still had the insets in it, which came out short by both of
/// them, more than the reach below: the end never counted as reached by hand, so "Jump to
/// latest" stayed and new text was not followed until it was tapped.
nonisolated enum TranscriptEnd {
    /// How near the end counts as at it, in points.
    static let reach: CGFloat = 120
    /// How much blank space under the last message is left alone.
    static let slack: CGFloat = 24

    /// The bottom edge of what can be read, above the composer, in the content's coordinates.
    static func readableBottom(_ g: ScrollGeometry) -> CGFloat {
        g.contentOffset.y + g.contentInsets.top + g.containerSize.height
    }

    /// The whole conversation is on screen at once: there is nowhere to scroll to.
    static func fits(_ g: ScrollGeometry) -> Bool { g.contentSize.height <= g.containerSize.height }

    /// The newest message is on screen, or nearly.
    static func isReached(_ g: ScrollGeometry) -> Bool {
        fits(g) || readableBottom(g) >= g.contentSize.height - reach
    }

    /// The reader is looking at blank space below the last message.
    static func isPassed(_ g: ScrollGeometry) -> Bool {
        !fits(g) && readableBottom(g) > g.contentSize.height + slack
    }
}

/// The dot on "Jump to latest": something new is below. It pulses while a reply is still being
/// written (opacity only, which the render server animates) and holds still once it is all there.
private struct NewBelowDot: View {
    let color: Color
    let live: Bool
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(live && dim ? 0.25 : 1)
            .onChange(of: live, initial: true) { _, live in
                guard live, !reduceMotion else { dim = false; return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

/// The UIKit scroll view a SwiftUI one is drawn with, found from a view inside its content: SwiftUI
/// has no way to stop a fling, and a jump has to.
@MainActor
final class ScrollHandle {
    fileprivate weak var view: UIScrollView?
    /// It has found its scroll view.
    var isAttached: Bool { view != nil }

    /// Stops a fling where it is (a non-animated offset ends UIKit's deceleration).
    func stopCoasting() {
        guard let view, view.isDecelerating else { return }
        view.setContentOffset(view.contentOffset, animated: false)
    }

    /// Placed in the scroll view's content: once in a window, it finds the scroll view above it.
    struct Finder: UIViewRepresentable {
        let handle: ScrollHandle

        func makeUIView(context: Context) -> Probe { Probe(handle: handle) }
        func updateUIView(_ probe: Probe, context: Context) { probe.handle = handle }

        final class Probe: UIView {
            var handle: ScrollHandle

            init(handle: ScrollHandle) {
                self.handle = handle
                super.init(frame: .zero)
                isUserInteractionEnabled = false
            }

            required init?(coder: NSCoder) { nil }

            override func didMoveToWindow() {
                super.didMoveToWindow()
                var up = superview
                while let view = up, !(view is UIScrollView) { up = view.superview }
                handle.view = up as? UIScrollView
            }
        }
    }
}

/// The message at the top of the transcript's screen, kept where writing it redraws nothing.
@MainActor private final class TopRow {
    var id: UUID?
}
