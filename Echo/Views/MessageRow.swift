import SwiftUI

struct MessageRow: View, Equatable {
    let message: Message
    var isLive = false
    /// Transcript screen: "Regenerate" on a reply, "Edit & resend" on your own message.
    var onRegenerate: (@MainActor @Sendable () -> Void)? = nil
    var onEdit: (@MainActor @Sendable () -> Void)? = nil
    /// Transcript screen: the speaker button under a reply. `isReading` is true while this
    /// reply is the one being spoken, and turns the button into Stop.
    var onReadAloud: (@MainActor @Sendable () -> Void)? = nil
    /// Transcript screen: fetches what this reply's tools were called with and returned, for a
    /// step opened without them (`Conversation.loadToolDetails`).
    var onLoadToolDetails: (@MainActor @Sendable () async -> Void)? = nil
    var isReading = false
    /// The copy / read / retry row under a finished reply. Voice mode hides it.
    var showActions = true
    /// Find in conversation: .match outlines the text, .current is the one being looked at.
    var highlight: Highlight = .none
    nonisolated enum Highlight: Equatable, Sendable { case none, match, current }

    /// The closures have no identity; compare the data so unchanged rows skip their body.
    nonisolated static func == (a: MessageRow, b: MessageRow) -> Bool {
        a.message == b.message && a.isLive == b.isLive && a.highlight == b.highlight
            && a.isReading == b.isReading && a.showActions == b.showActions
            && (a.onRegenerate == nil) == (b.onRegenerate == nil) && (a.onEdit == nil) == (b.onEdit == nil)
            && (a.onReadAloud == nil) == (b.onReadAloud == nil)
            && (a.onLoadToolDetails == nil) == (b.onLoadToolDetails == nil)
    }
    /// An image-only message renders just its attachments — no empty text bubble.
    private var hasTextBubble: Bool {
        !(shownText.isEmpty && (!message.attachments.isEmpty || !namedPictures.isEmpty))
    }

    /// A message of the person's without the lines naming its pictures on the server
    /// (`@image:`, and Hermes's "[screenshot]" for them): the pictures show instead.
    private var shownText: String {
        message.role == .user ? ServeMedia.named(in: message.text).text : message.text
    }

    /// Those pictures, while they aren't in the chat yet: each to fetch on a tap.
    private var namedPictures: [ServeMedia.Candidate] {
        message.role == .user ? ServeMedia.named(in: message.text).files : []
    }

    /// Terminal-family themes render your messages as shell input (`❯ text`), left-aligned
    /// and unbubbled, the way a prompt line sits in a terminal.
    private var promptStyled: Bool {
        theme.promptPrefix != nil && message.role == .user && !message.isSteer
    }

    /// A reply straight on the page, under the agent's name.
    private var flatReply: Bool { message.role == .assistant && theme.palette.flatReplies && message.error == nil }

    @Environment(\.theme) private var theme
    /// A bot's name, in its chat; else the agent's (`settings.headerTitle`).
    @Environment(\.replySpeaker) private var replySpeaker
    @Environment(\.replyFace) private var replyFace
    @Environment(\.fileSource) private var fileSource
    @State private var settings = Settings.shared
    /// What the person chose for each fold, once they have tapped it; until then each is open
    /// while it is what the agent is doing, and folded after.
    @State private var showThinking: Bool?
    @State private var showSteps: Bool?
    @State private var selecting = false
    @State private var fullMetrics = false
    /// Just copied: the button shows a check. `copyCount` drives the haptic.
    @State private var copied = false
    @State private var copyCount = 0
    /// The tool step that is open, and the fetch of its details where they weren't sent.
    @State private var openStep: UUID?
    @State private var loadingDetails = false
    @State private var triedDetails = false
    @State private var fullDetail: ToolDetail?
    /// The transcript's toast; absent in voice mode, which has no actions to announce.
    @Environment(Toaster.self) private var toaster: Toaster?

    var body: some View {
        // What the person asked a tagged bot is theirs, a bubble like any (`BotAsides`).
        if message.role == .user, let delivered = message.delivered, delivered.kind != .asked {
            DeliveredMessage(message: message, delivered: delivered)
        } else {
            ownBody
        }
    }

    private var ownBody: some View {
        VStack(alignment: message.role == .user && !promptStyled ? .trailing : .leading, spacing: 8) {
            if message.role == .assistant, theme.promptPrefix == nil { speakerLine }
            if message.role == .assistant, !message.reasoning.isEmpty || !message.tools.isEmpty {
                // What went into the reply, as a pair of folds in one style.
                VStack(alignment: .leading, spacing: 0) {
                    if !message.reasoning.isEmpty { thinkingFold }
                    if !message.tools.isEmpty { stepsFold }
                }
            }
            // The agent's own task list, as this reply left it.
            if message.role == .assistant, let todos = message.todos, !todos.isEmpty {
                TodoChecklist(items: todos, isLive: isLive)
            }
            if !message.subagents.isEmpty { SubagentRows(subagents: message.subagents) }
            let files = message.attachments.filter { $0.page == nil }
            if !files.isEmpty { AttachmentGallery(attachments: files) }
            // Files the reply names that aren't in the chat, and pictures a message of the
            // person's names on the server: each to fetch and open, not a path.
            if message.role != .assistant || !isLive {
                let named = message.role == .assistant ? ServeMedia.named(in: message.text).files : namedPictures
                if !named.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(named, id: \.path) { DeliveredFileChip(file: $0, source: fileSource) }
                    }
                }
            }
            if isLive, message.text.isEmpty {
                // Waiting for the first token: the app's waveform, breathing.
                WaveformPulse(color: theme.accent)
                    .padding(.horizontal, flatReply ? 2 : 16)
                    .padding(.vertical, flatReply ? 4 : 12)
                    .background(flatReply ? AnyShapeStyle(.clear) : bubble, in: .rect(cornerRadius: theme.bubbleRadius))
                    .accessibilityLabel("Waiting for reply")
            } else if message.role == .assistant, message.error == nil, hasTextBubble {
                // A reply that went on to write a message as if from the person: what it said,
                // then a warning in place of the made-up rest.
                let invented = BotMessages.inventedTurn(in: message.text)
                let said = ServeMedia.named(in: invented?.said ?? message.text).text
                if !said.isEmpty {
                    // A file the reply only names in passing opens from its path.
                    MarkdownView(text: said, isLive: isLive, selectable: false, linkPaths: !isLive)
                        .padding(.horizontal, flatReply ? 2 : 14)
                        .padding(.vertical, flatReply ? 0 : theme.bubbleVerticalPadding)
                        .background(flatReply ? AnyShapeStyle(.clear) : bubble, in: .rect(cornerRadius: theme.bubbleRadius))
                        .foregroundStyle(theme.textColor)
                        .contextMenu { replyMenu }
                        .overlay(highlightRing)
                        .sheet(isPresented: $selecting) { SelectableTextSheet(text: message.text) }
                        .modifier(OpensServerPaths(source: fileSource))
                }
                if let invented {
                    InventedTurnNote(name: replySpeaker ?? settings.headerTitle, invented: invented.invented)
                }
            } else if message.isSteer {
                Label(message.text, systemImage: "arrow.turn.down.right")
                    .chatFont(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.12), in: .capsule)
            } else if hasTextBubble, promptStyled, let prompt = theme.promptPrefix {
                Text("\(Text(prompt).bold())\(shownText)")
                    .font(theme.messageFont)
                    .foregroundStyle(theme.promptColor)
                    // The ❯ is decoration; VoiceOver (and UI tests) should get the words alone.
                    .accessibilityLabel(shownText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(highlightRing)
                    .contextMenu { userMenu }
                    .sheet(isPresented: $selecting) { SelectableTextSheet(text: message.text) }
            } else if hasTextBubble {
                Text(shownText)
                    .font(theme.userFont)
                    .padding(.horizontal, 14)
                    .padding(.vertical, theme.bubbleVerticalPadding)
                    .background {
                        if message.role == .user {
                            theme.userBubbleShape.fill(bubble)
                        } else {
                            RoundedRectangle(cornerRadius: theme.bubbleRadius).fill(bubble)
                        }
                    }
                    .foregroundStyle(message.role == .user ? theme.userBubbleText : theme.textColor)
                    .overlay(highlightRing)
                    .contextMenu { userMenu }
                    .sheet(isPresented: $selecting) { SelectableTextSheet(text: message.text) }
            }
            // The page of the first web link, with Link previews on (`LinkPreviewSlot`), once a
            // reply has finished.
            if !isLive, !message.isSteer, message.error == nil, hasTextBubble { LinkPreviewSlot(text: message.text) }
            // A map, places, the weather, the time the reply shows (`ReplyCards`), as soon as they're asked for.
            if message.role == .assistant, let cards = message.cards, !cards.isEmpty { ReplyCardsView(cards: cards, pending: isLive) }
            // Pages the agent made for the chat, live, under what it said about them.
            if message.role == .assistant, !isLive {
                ForEach(message.attachments.filter { $0.page != nil }) { AgentPage(attachment: $0, messageID: message.id) }
            }
            if showActions, message.role == .assistant, !isLive, message.error == nil, !message.text.isEmpty {
                actionRow
                    .transition(.opacity)
            }
        }
        // The reply finishing: its actions fade in, and the streaming edge fades into plain text.
        .animation(.easeOut(duration: 0.3), value: isLive)
        .frame(maxWidth: .infinity, alignment: message.role == .user && !promptStyled ? .trailing : .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.role == .user ? (message.isSteer ? String(localized: "Your steer") : String(localized: "You")) : replySpeaker ?? settings.headerTitle)
        .sensoryFeedback(.success, trigger: copyCount)
        .sheet(item: $fullDetail) { SelectableTextSheet(text: $0.text, title: $0.title, monospaced: true) }
    }

    /// Copies, ticks, turns the copy button into a check for a moment and says so in a toast.
    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        copyCount += 1
        toaster?.show(String(localized: "Copied"))
        withAnimation(.snappy(duration: 0.2)) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.snappy(duration: 0.2)) { copied = false }
        }
    }

    // MARK: - Reply parts

    /// Who is talking, and while the reply runs, for how long.
    private var speakerLine: some View {
        HStack(spacing: 6) {
            if isLive { LiveMark(color: theme.accent) }
            if let replyFace { BotAvatar(face: replyFace, name: replySpeaker ?? settings.headerTitle, size: 20) }
            Text(replySpeaker ?? settings.headerTitle).chatFont(.subheadline, weight: .semibold)
            if isLive {
                // The one place that shimmers while the reply is being worked on.
                TimelineView(.periodic(from: message.createdAt, by: 1)) { context in
                    ShimmerText(text: String(localized: "is working · \(Self.elapsed(from: message.createdAt, to: context.date))"))
                        .chatFont(.subheadline)
                        .monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "5 sec", "1 min 12 sec".
    private static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return Duration.seconds(s).formatted(.units(allowed: [.minutes, .seconds], width: .condensedAbbreviated))
    }

    // MARK: - Folds

    /// The line a reply's thinking and its tool steps each fold to: a chevron and a quiet label.
    /// One style for both, so the two read as a pair.
    private func foldHeader(open: Bool, hint: String, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .chatFont(.caption2, weight: .semibold)
                    .rotationEffect(.degrees(open ? 90 : 0))
                label()
            }
            .chatFont(.subheadline, weight: .medium)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .padding(.trailing, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hint)
    }

    /// The reply's thinking: "Thinking" while it happens, with the newest of it underneath, then
    /// "Thought for 6 s", which opens onto all of it. Open while the reply is being worked on,
    /// unless the person folds it, which they can at any moment, as with the steps.
    private var thinkingFold: some View {
        let open = showThinking ?? isLive
        return VStack(alignment: .leading, spacing: 2) {
            foldHeader(open: open, hint: open ? String(localized: "Hide thinking") : String(localized: "Show thinking")) {
                withAnimation(.snappy(duration: 0.3)) { showThinking = !open }
            } label: {
                thinkingLabel
            }
            if open { reasoningText }
        }
    }

    /// "Thinking" with a light sweeping across it while the model thinks (the speaker line
    /// counts the seconds), "Thought for 6 s" after. Replies saved before the times were kept
    /// just say "Thought".
    @ViewBuilder
    private var thinkingLabel: some View {
        if isLive, message.text.isEmpty {
            ShimmerText(text: String(localized: "Thinking"))
        } else if let started = message.reasoningStartedAt, let ended = message.reasoningEndedAt {
            // A think under a second still took a moment; "0 s" would read as nothing.
            Text("Thought for \(Self.elapsed(from: started, to: max(ended, started.addingTimeInterval(1))))")
        } else {
            Text("Thought")
        }
    }

    private var reasoningText: some View {
        // While live, the newest part: with the start shown, a long think stopped moving once it
        // passed the line limit. The whole trace is there under "Thought" afterwards.
        Text(isLive ? Self.tail(of: message.reasoning, maxCharacters: 360) : message.reasoning)
            .chatFont(.footnote)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(isLive ? 8 : nil)
            .truncationMode(.head)
            .modifier(FoldBody())
    }

    /// The tools the reply used, folded the same way: "Working · 2 tools" while they run, with a
    /// step for each underneath, then "Used 2 tools · 2.1 s". Open while the agent works and
    /// hasn't started writing; folded after, and on tap.
    private var stepsFold: some View {
        let tools = message.tools
        let working = isLive && tools.contains { $0.status == .running }
        let open = showSteps ?? (isLive && message.text.isEmpty)
        return VStack(alignment: .leading, spacing: 2) {
            foldHeader(open: open, hint: open ? String(localized: "Hide tool steps") : String(localized: "Show tool steps")) {
                withAnimation(.snappy(duration: 0.3)) { showSteps = !open }
            } label: {
                (working ? Text("Working · \(Self.toolsSummary(tools, working: true))") : Text("Used \(Self.toolsSummary(tools, working: false))"))
                    .monospacedDigit()
            }
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tools) { tool in
                        // A step opens onto what it was called with and what came back, when
                        // there is something to show or somewhere to fetch it from.
                        let canOpen = tool.args != nil || tool.output != nil || onLoadToolDetails != nil
                        let isOpen = openStep == tool.id
                        VStack(alignment: .leading, spacing: 0) {
                            Button { toggleStep(tool) } label: {
                                HStack(alignment: .center, spacing: 12) {
                                    StepMark(status: tool.status, animated: isLive)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(BotMessages.stepName(tool) ?? tool.name).chatFont(.subheadline)
                                            .foregroundStyle(tool.status == .running ? .primary : .secondary)
                                        if let preview = tool.preview, !preview.isEmpty {
                                            Text(preview).chatFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    if canOpen {
                                        Image(systemName: "chevron.right")
                                            .chatFont(.caption2, weight: .semibold)
                                            .foregroundStyle(.tertiary)
                                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                                    }
                                }
                                .padding(.vertical, 7)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .disabled(!canOpen)
                            .accessibilityLabel("Tool \(tool.name), \(Self.statusLabel(tool.status))")
                            .accessibilityHint(canOpen ? (isOpen ? String(localized: "Hides what it returned") : String(localized: "Shows what it returned")) : "")
                            if isOpen { stepDetail(tool) }
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .modifier(FoldBody())
            }
        }
        .animation(.snappy(duration: 0.3), value: tools.count)
        .animation(.snappy(duration: 0.3), value: open)
        .animation(.snappy(duration: 0.3), value: openStep)
    }

    /// A step's state, read out by VoiceOver.
    private static func statusLabel(_ status: ToolActivity.Status) -> String {
        switch status {
        case .running: String(localized: "running", comment: "A tool step's state")
        case .completed: String(localized: "completed", comment: "A tool step's state")
        case .failed: String(localized: "failed", comment: "A tool step's state")
        }
    }

    private func toggleStep(_ tool: ToolActivity) {
        openStep = openStep == tool.id ? nil : tool.id
        // Opened without its result: ask once for the whole reply's.
        guard openStep == tool.id, tool.output == nil, tool.status != .running, !triedDetails, let onLoadToolDetails else { return }
        loadingDetails = true
        Task {
            await onLoadToolDetails()
            loadingDetails = false
            triedDetails = true
        }
    }

    /// A step, opened: what the tool was called with, what it gave back, and the way to the
    /// whole text.
    private func stepDetail(_ tool: ToolActivity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let args = tool.args { detailBlock(String(localized: "Input", comment: "What a tool step was called with"), args, lines: 6) }
            if let output = tool.output {
                detailBlock(String(localized: "Output", comment: "What a tool step returned"), output, lines: 12)
            } else if tool.status == .running {
                Text("Still running.").chatFont(.caption).foregroundStyle(.secondary)
            } else if loadingDetails {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Fetching the output…")
                }
                .chatFont(.caption).foregroundStyle(.secondary)
            } else {
                Text("No output was kept for this step.").chatFont(.caption).foregroundStyle(.secondary)
            }
            if tool.args != nil || tool.output != nil {
                HStack(spacing: 18) {
                    Button("Copy") { copy(tool.output ?? tool.args ?? "") }
                        .accessibilityLabel(tool.output != nil ? String(localized: "Copy output") : String(localized: "Copy input"))
                    Button(tool.output != nil ? String(localized: "Open full output") : String(localized: "Open in full")) { fullDetail = ToolDetail(tool) }
                }
                .chatFont(.caption, weight: .medium)
                .foregroundStyle(theme.accent)
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 32).padding(.bottom, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func detailBlock(_ label: String, _ text: String, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).chatFont(.caption2, weight: .semibold).foregroundStyle(.secondary).textCase(.uppercase)
            Text(Self.head(of: text, lines: lines))
                .chatFont(.caption, design: .monospaced)
                .foregroundStyle(theme.textColor)
                .lineLimit(lines)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(theme.surfaceColor, in: .rect(cornerRadius: 10))
        }
    }

    /// The first lines of a step's text, so a long output costs the layout no more than shows.
    nonisolated static func head(of text: String, lines: Int) -> String {
        let first = text.split(separator: "\n", maxSplits: lines, omittingEmptySubsequences: false).prefix(lines)
        return String(first.joined(separator: "\n").prefix(lines * 160))
    }

    /// "3 tools", then "3 tools · 4.2 sec" once they are all done and were timed.
    private static func toolsSummary(_ tools: [ToolActivity], working: Bool) -> String {
        let count = String(localized: "\(tools.count) tools")
        guard !working, let start = tools.compactMap(\.startedAt).min(), let end = tools.compactMap(\.endedAt).max(), end > start else { return count }
        let seconds = end.timeIntervalSince(start)
        let time = seconds < 10
            ? Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .condensedAbbreviated, fractionalPart: .show(length: 1)))
            : Duration.seconds(Int(seconds)).formatted(.units(allowed: [.seconds], width: .condensedAbbreviated))
        return count + " · " + time
    }

    /// Copy, read aloud, retry, more; then how fast it came back.
    private var actionRow: some View {
        HStack(spacing: 2) {
            Button { copy(message.text) } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32, height: 32).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copied ? String(localized: "Copied") : String(localized: "Copy reply"))
            if let onReadAloud {
                actionButton(isReading ? String(localized: "Stop reading") : String(localized: "Read aloud"),
                             isReading ? "stop.fill" : "speaker.wave.2", action: onReadAloud)
            }
            if let onRegenerate {
                actionButton(String(localized: "Regenerate"), "arrow.clockwise", action: onRegenerate)
            }
            Menu { replyMenu } label: {
                Image(systemName: "ellipsis").frame(width: 32, height: 32).contentShape(.rect)
            }
            .accessibilityLabel("More")
            if let metrics = message.metrics, metrics.completedAt != nil {
                Button { withAnimation(.easeOut(duration: 0.15)) { fullMetrics.toggle() } } label: {
                    Text(fullMetrics ? metrics.summary : Self.compact(metrics))
                        .chatFont(.caption2).monospacedDigit()
                        .lineLimit(1)
                        .padding(.leading, 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(metrics.summary)
                .accessibilityHint(fullMetrics ? String(localized: "Shows fewer timings") : String(localized: "Shows every timing"))
            }
        }
        .chatFont(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.leading, -7)
    }

    private func actionButton(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 32, height: 32).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The last `maxCharacters` of `text`, starting at a word, with "…" in front when cut.
    nonisolated static func tail(of text: String, maxCharacters: Int) -> String {
        // Without counting the whole of it, which a long thinking was on every update: `suffix`
        // walks back only as far as it needs, and is all of it when the text is short enough.
        guard text.utf8.count > maxCharacters else { return text }
        var cut = text.suffix(maxCharacters)
        guard cut.startIndex > text.startIndex else { return text }
        if let space = cut.firstIndex(where: \.isWhitespace) { cut = cut[cut.index(after: space)...] }
        return "…" + cut
    }

    /// "3m 12s · 32 tok/s": how long the whole reply took, and speed. (It showed the time to the
    /// first token, which for a model that thinks first is under a second on a 3-minute reply.)
    private static func compact(_ m: TurnMetrics) -> String {
        var parts: [String] = []
        if let t = m.total ?? m.timeToFirstToken { parts.append(duration(t)) }
        if let tps = m.tokensPerSecond { parts.append(String(localized: "\(tps.formatted(.number.precision(.fractionLength(0)))) tok/s", comment: "Tokens per second")) }
        return parts.isEmpty ? m.summary : parts.joined(separator: " · ")
    }

    /// "12.3s" under a minute, "3m 12s" from there.
    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1)))
        }
        return Duration.seconds(Int(seconds.rounded())).formatted(.units(allowed: [.minutes, .seconds], width: .narrow))
    }

    @ViewBuilder
    private var replyMenu: some View {
        Button("Copy reply", systemImage: "doc.on.doc") { copy(message.text) }
        if !message.reasoning.isEmpty {
            Button("Copy thinking", systemImage: "brain") { copy(message.reasoning) }
        }
        ShareLink(item: message.text) { Label("Share…", systemImage: "square.and.arrow.up") }
        Button("Select text", systemImage: "text.cursor") { selecting = true }
        Button("Watch This…", systemImage: "eye") { WatchDraft.shared.start(PlainText.display(message.text)) }
        if let onRegenerate {
            Divider()
            Button("Regenerate", systemImage: "arrow.clockwise", action: onRegenerate).disabled(isLive)
        }
        Divider()
        Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
    }

    @ViewBuilder
    private var userMenu: some View {
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
        // Selected in a copy of its own, as a reply is: the transcript's text isn't selectable.
        Button("Select text", systemImage: "text.cursor") { selecting = true }
        if let onEdit, message.role == .user {
            Button("Edit & resend", systemImage: "pencil", action: onEdit).disabled(isLive)
        }
        Button("Watch This…", systemImage: "eye") { WatchDraft.shared.start(message.text) }
        Divider()
        Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
    }

    @ViewBuilder
    private var highlightRing: some View {
        if highlight != .none {
            RoundedRectangle(cornerRadius: theme.bubbleRadius)
                .strokeBorder(highlight == .current ? Color.orange : theme.accent.opacity(0.6), lineWidth: highlight == .current ? 3 : 2)
                .padding(flatReply ? -6 : 0)
        }
    }

    private var bubble: AnyShapeStyle {
        if message.error != nil { return AnyShapeStyle(Color.red.opacity(0.15)) }
        return message.role == .user
            ? AnyShapeStyle(theme.userBubble)
            : AnyShapeStyle(theme.assistantBubble ?? Color(.secondarySystemBackground))
    }
}

/// Secondary text with a band of light passing over it, left to right, while something is in
/// progress. Still text under Reduce Motion.
struct ShimmerText: View {
    let text: String
    /// The resting colour; the band that sweeps over it is brighter.
    var base: Color = .secondary
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .foregroundStyle(base)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        // The band is the text colour that contrasts with the background on
                        // every theme: a white one vanished into a light page.
                        LinearGradient(stops: [.init(color: .clear, location: 0),
                                               .init(color: .primary, location: 0.5),
                                               .init(color: .clear, location: 1)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: phase * geo.size.width)
                    }
                    .mask(Text(text))
                    .onAppear {
                        withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { phase = 1.2 }
                    }
                }
            }
    }
}

/// What a fold opens onto: set in from a rule down its left side, the same for the thinking and
/// for the tool steps.
private struct FoldBody: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1).fill(.quaternary).frame(width: 2)
            }
            .padding(.leading, 6)
            .clipped()
            .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// A step's whole text, for the sheet.
private struct ToolDetail: Identifiable {
    let id = UUID()
    let title: String
    let text: String

    init(_ tool: ToolActivity) {
        title = tool.name
        let input = String(localized: "Input", comment: "What a tool step was called with").localizedUppercase
        let output = String(localized: "Output", comment: "What a tool step returned").localizedUppercase
        text = [tool.args.map { input + "\n\n" + $0 }, tool.output.map { output + "\n\n" + $0 }]
            .compactMap { $0 }.joined(separator: "\n\n\n")
    }
}

/// A tool step's state: a spinner while it runs, then a check that draws itself (or a cross).
/// `animated` is off for a saved reply, where the marks just sit finished.
private struct StepMark: View {
    let status: ToolActivity.Status
    var animated: Bool
    @State private var drawn: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch status {
            case .running:
                ProgressView().controlSize(.small)
            case .completed:
                Circle().fill(.green.opacity(0.16))
                CheckShape()
                    .trim(from: 0, to: drawn)
                    .stroke(.green, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .padding(5)
            case .failed:
                Image(systemName: "xmark").chatFont(.caption, weight: .bold).foregroundStyle(.red)
                    .frame(width: 20, height: 20).background(.red.opacity(0.16), in: .circle)
            }
        }
        .frame(width: 20, height: 20)
        .onChange(of: status, initial: true) { _, status in
            guard status == .completed else { drawn = 0; return }
            if animated, !reduceMotion {
                withAnimation(.easeOut(duration: 0.4).delay(0.05)) { drawn = 1 }
            } else {
                drawn = 1
            }
        }
    }
}

nonisolated private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.midY + rect.height * 0.05))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.maxY - rect.height * 0.12))
        p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.05, y: rect.minY + rect.height * 0.18))
        return p
    }
}

#Preview {
    let conversation = Conversation()
    ContentView()
        .environment(conversation)
        .environment(VoiceSession(conversation: conversation))
}

/// A message Hermes files as the person's that isn't theirs (`Delivered`): another bot's, with its
/// creature and name, its words in a quiet bubble on the bots' side; a bot's reply to one this bot
/// sent, the same way; a background task done, as one line whose output opens on a tap.
struct DeliveredMessage: View {
    let message: Message
    let delivered: Delivered
    @Environment(\.theme) private var theme
    @State private var settings = Settings.shared
    @State private var directory = BotDirectory.shared
    @State private var showingOutput = false
    /// A bot's reply, opened.
    @State private var open = false

    private var bot: HermesBot? {
        guard let profile = delivered.profile, directory.key == settings.connectionKey else { return nil }
        return directory.roster?.bots.first { $0.name == profile }
    }

    private var name: String {
        bot?.label(mainName: settings.headerTitle) ?? (delivered.profile == "default" ? settings.headerTitle : delivered.name ?? String(localized: "A bot"))
    }

    private var face: BotFace {
        guard let profile = delivered.profile else { return BotFace(seed: "bot") }
        return (directory.key == settings.connectionKey ? directory.roster?.faces[profile] : nil) ?? (profile == "default" ? .main : BotFace(seed: profile))
    }

    var body: some View {
        switch delivered.kind {
        case .process: processLine
        case .message, .reply, .routine, .asked: botMessage
        case .answer: answer
        }
    }

    /// A tagged bot's answer in a normal chat (`BotAsides`): its face and name, its words as they
    /// are written, in the quiet bubble of the bots' side.
    private var answer: some View {
        let live = message.metrics != nil && message.metrics?.completedAt == nil && message.error == nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                BotAvatar(face: face, name: name, size: 20)
                Text(name).chatFont(.subheadline, weight: .semibold)
            }
            if message.text.isEmpty, live {
                ShimmerText(text: String(localized: "Thinking"))
                    .padding(.horizontal, 14)
            } else if !message.text.isEmpty {
                MarkdownView(text: message.text, isLive: live)
                    .padding(.horizontal, 14)
                    .padding(.vertical, theme.bubbleVerticalPadding)
                    .background(RoundedRectangle(cornerRadius: theme.bubbleRadius).fill(theme.surfaceColor.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: theme.bubbleRadius).strokeBorder(.quaternary))
                    .foregroundStyle(theme.textColor)
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                    }
            }
            if let error = message.error {
                Text(error).chatFont(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var botMessage: some View {
        // A relay that came back with nothing in it: the bot's turn failed, or gave no words.
        let unanswered = delivered.kind == .reply && message.text.isEmpty
        let heading = unanswered ? String(localized: "\(name) didn't answer")
            : delivered.kind == .reply ? String(localized: "\(name) replied")
            : delivered.kind == .routine ? String(localized: "\(delivered.title?.nilIfEmpty ?? String(localized: "A schedule")) ran")
            : String(localized: "Message from \(name)")
        // A bot's reply to one this bot sent folds away as the thinking does: what the person
        // reads (and hears) is this bot's answer, which follows it. So does what a schedule came
        // up with, which the bot answers next.
        let folds = (delivered.kind == .reply || delivered.kind == .routine) && !unanswered
        return VStack(alignment: .leading, spacing: 6) {
            if folds {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { open.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .chatFont(.caption2, weight: .semibold)
                            .rotationEffect(.degrees(open ? 90 : 0))
                        if delivered.kind == .routine {
                            Image(systemName: "clock").frame(width: 20)
                        } else {
                            BotAvatar(face: face, name: name, size: 20)
                        }
                        Text(heading).chatFont(.subheadline, weight: .medium)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(open ? String(localized: "Hides what \(name) said") : String(localized: "Shows what \(name) said"))
            } else {
                HStack(spacing: 6) {
                    BotAvatar(face: face, name: name, size: 20)
                    Text(heading).chatFont(.subheadline, weight: .semibold)
                }
            }
            if !unanswered, !folds || open {
                MarkdownView(text: message.text, isLive: false)
                    .padding(.horizontal, 14)
                    .padding(.vertical, theme.bubbleVerticalPadding)
                    .background(RoundedRectangle(cornerRadius: theme.bubbleRadius).fill(theme.surfaceColor.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: theme.bubbleRadius).strokeBorder(.quaternary))
                    .foregroundStyle(theme.textColor)
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(heading)
    }

    private var processLine: some View {
        Button { showingOutput = true } label: {
            Label(delivered.title ?? String(localized: "A background task finished"), systemImage: "gearshape.2")
                .chatFont(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityHint("Shows what it said")
        .sheet(isPresented: $showingOutput) {
            SelectableTextSheet(text: message.text, title: delivered.title ?? String(localized: "Background task"), monospaced: true)
        }
    }
}


/// In place of what a reply made up as if the person had said it (`BotMessages.inventedTurn`): a
/// warning, so nobody reads it as their own, and the words behind a tap.
struct InventedTurnNote: View {
    let name: String
    let invented: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.bubble")
                    Text("\(name) wrote a message as if from you").chatFont(.footnote, weight: .medium)
                    Image(systemName: "chevron.right").chatFont(.caption2, weight: .semibold).rotationEffect(.degrees(open ? 90 : 0))
                }
                .foregroundStyle(.orange)
                .padding(.vertical, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? String(localized: "Hides it") : String(localized: "Shows what it wrote. You didn't send it."))
            if open {
                Text(invented)
                    .chatFont(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: .rect(cornerRadius: 10))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
