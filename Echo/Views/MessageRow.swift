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
    /// A grouped turn can open a step from any of its stored assistant messages.
    var onLoadTurnToolDetails: (@MainActor @Sendable (UUID) async -> Void)? = nil
    /// Transcript-only placement for consecutive assistant messages in one visual turn.
    var turn: AssistantTurnActivity.Placement? = nil
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
            && (a.onLoadTurnToolDetails == nil) == (b.onLoadTurnToolDetails == nil)
            && a.turn == b.turn
    }
    /// An image-only message renders just its attachments — no empty text bubble.
    /// The reply's own words: none for a row whose text is working beside its tool calls (it
    /// shows in the turn's fold), and the last note for a finished reply that wrote nothing else,
    /// stopped or failed after its notes, so it isn't left empty.
    private var replyBody: String {
        // In the chat: everything it wrote, the working with the answer, in the order it came.
        guard foldsWorkingText else {
            return (message.notes.map(\.text) + [message.text])
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
        }
        if turn?.foldsText == true { return "" }
        if !isLive, message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let last = message.notes.last {
            return last.text
        }
        return message.text
    }

    /// The working kept in the steps fold: voice mode's only (`foldsWorkingText`).
    private var foldedNotes: [WorkingNote] { foldsWorkingText ? message.notes : [] }

    private var hasTextBubble: Bool {
        !(shownText.isEmpty && (!message.attachments.isEmpty || !namedPictures.isEmpty))
    }

    /// A message of the person's without the lines naming its pictures on the server
    /// (`@image:`, and Hermes's "[screenshot]" for them): the pictures show instead.
    private var shownText: String {
        message.role == .user ? ServeMedia.named(in: message.text).text : message.text
    }

    /// A message of the person's that opens with a quote (`Quote.split`): the quote, drawn over
    /// the bubble, and the words under it, which the bubble holds.
    private var quoteSplit: (quote: String, rest: String)? {
        message.role == .user && !message.isSteer ? Quote.split(shownText) : nil
    }

    /// What the person's bubble says.
    private var bubbleText: String { quoteSplit?.rest ?? shownText }

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
    /// Why Hermes stopped this turn, when it did. Only a reply that starts with Hermes's own words
    /// looks further, at the turn's replies before it.
    private var toolStop: String? {
        guard message.text.hasPrefix("I stopped retrying because") else { return nil }
        let all = conversation?.messages ?? []
        let earlier = all.firstIndex(where: { $0.id == message.id }).map { i in
            Array(all[..<i].reversed().prefix { $0.role != .user }.reversed())
        } ?? []
        return ToolStop.reason(message, earlier: earlier)
    }

    private var flatReply: Bool { message.role == .assistant && theme.palette.flatReplies && message.error == nil }

    @Environment(\.theme) private var theme
    /// A bot's name, in its chat; else the agent's (`settings.headerTitle`).
    @Environment(\.replySpeaker) private var replySpeaker
    @Environment(\.foldsWorkingText) private var foldsWorkingText
    @Environment(\.replyFace) private var replyFace
    @Environment(\.fileSource) private var fileSource
    @State private var settings = Settings.shared
    /// What the person chose for each fold, once they have tapped it; until then each is open
    /// while it is what the agent is doing, and folded after.
    @State private var showThinking: Bool?
    @State private var showSteps: Bool?
    @State private var showTurnActivity: Bool?
    @State private var selecting = false
    /// Part of the reply being selected where it stands (`InlineSelection`).
    @State private var selectingInline = false
    @State private var fullMetrics = false
    /// Just copied: the button shows a check. `copyCount` drives the haptic.
    @State private var copied = false
    @State private var copyCount = 0
    /// The tool step that is open, and the fetch of its details where they weren't sent.
    @State private var openStep: UUID?
    @State private var loadingDetails = false
    @State private var triedDetails: Set<UUID> = []
    @State private var fullDetail: ToolDetail?
    /// A step's file change, open in full.
    @State private var patchStep: ToolActivity?
    /// The transcript's toast; absent in voice mode, which has no actions to announce.
    @Environment(Toaster.self) private var toaster: Toaster?
    /// For "Remember This": absent outside a transcript (voice mode), and so is the item.
    @Environment(Conversation.self) private var conversation: Conversation?

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
            if message.role == .assistant, theme.promptPrefix == nil, turn?.showsSpeaker != false {
                speakerLine(live: turn?.isLiveTurn ?? isLive)
            }
            // The question it answers, over the person's answer (`AnsweredQuestions`).
            if message.role == .user, let asked = message.answering, !asked.isEmpty {
                Label(asked, systemImage: "questionmark.bubble")
                    .chatFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(promptStyled ? .leading : .trailing)
                    .padding(.leading, promptStyled ? 0 : 48)
                    .accessibilityLabel(String(localized: "Answering: \(asked)", comment: "VoiceOver: the question a message of the person's answers"))
            }
            // The message it quotes, over the person's words; a tap shows that message.
            if let quoted = quoteSplit?.quote {
                QuoteBlock(quote: quoted, alignment: promptStyled ? .leading : .trailing) {
                    conversation?.reveal(quote: quoted, in: message.id)
                }
            }
            if message.role == .assistant, let activity = turn?.activity { turnActivityFold(activity) }
            if message.role == .assistant, turn?.isGrouped != true, !message.reasoning.isEmpty || !message.tools.isEmpty {
                // What went into the reply, as a pair of folds in one style.
                VStack(alignment: .leading, spacing: 0) {
                    if !message.reasoning.isEmpty { thinkingFold }
                    if !message.tools.isEmpty { stepsFold }
                }
            }
            // Watching the agent work: its browser's page and its processes' output while it works,
            // "Browsed 4 pages" after.
            if message.role == .assistant, isLive || message.tools.contains(where: { AgentBrowsing.isBrowsing($0.name) }) {
                AgentWorkStrip(tools: message.tools, isLive: isLive)
            }
            // "Remember that…" kept, "forget that…" done: a chip to the Memory page (2.4).
            if message.role == .assistant, !isLive, let change = AgentMemory.change(in: message.tools) {
                MemoryChip(change: change, profile: fileSource?.profile)
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
            if isLive, (foldsWorkingText ? message.text : replyBody).isEmpty {
                // Waiting for the first token: the app's waveform, breathing.
                WaveformPulse(color: theme.accent)
                    .padding(.horizontal, flatReply ? 2 : 16)
                    .padding(.vertical, flatReply ? 4 : 12)
                    .background(flatReply ? AnyShapeStyle(.clear) : bubble, in: .rect(cornerRadius: theme.bubbleRadius))
                    .accessibilityLabel("Waiting for reply")
            } else if message.role == .assistant, message.error == nil, hasTextBubble {
                // A reply that went on to write a message as if from the person: what it said,
                // then a warning in place of the made-up rest.
                let invented = BotMessages.inventedTurn(in: replyBody)
                let said = ServeMedia.named(in: invented?.said ?? replyBody).text
                if !said.isEmpty {
                    // A file the reply only names in passing opens from its path.
                    replyText(said)
                        .padding(.horizontal, flatReply ? 2 : 14)
                        .padding(.vertical, flatReply ? 0 : theme.bubbleVerticalPadding)
                        .background(flatReply ? AnyShapeStyle(.clear) : bubble, in: .rect(cornerRadius: theme.bubbleRadius))
                        .foregroundStyle(theme.textColor)
                        .modifier(ReplyPress(inline: selectsInline, reacts: reacts && !selectingInline, menu: { replyMenu }, reactions: { reactionPalette }, onPress: startSelecting))
                        .overlay(highlightRing)
                        .sheet(isPresented: $selecting) { SelectableTextSheet(text: message.text) }
                        .modifier(OpensServerPaths(source: fileSource))
                }
                if let invented {
                    InventedTurnNote(name: replySpeaker ?? settings.headerTitle, invented: invented.invented)
                }
                // The person's reaction, under the reply; a tap takes it back.
                if let reaction = message.reaction {
                    Button {
                        conversation?.react(to: message.id, with: nil)
                    } label: {
                        Text(reaction)
                            .font(.body)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, flatReply ? 0 : 8)
                    .padding(.top, -4)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel(String(localized: "You reacted \(reaction). Remove", comment: "VoiceOver: the reaction under a reply, which a tap takes back"))
                }
            } else if message.isSteer {
                // Added to a reply under way: the person's words, a quieter bubble of theirs in the
                // theme's colour. A rounded rectangle, never a capsule: 2026-11-01 a pasted
                // paragraph came out a brown oval (orange at 12% on the dark page).
                Label(message.text, systemImage: "arrow.turn.down.right")
                    .chatFont(.footnote)
                    .foregroundStyle(theme.textColor.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(theme.accent.opacity(0.12), in: .rect(cornerRadius: min(theme.bubbleRadius, 16)))
                    .overlay(RoundedRectangle(cornerRadius: min(theme.bubbleRadius, 16)).strokeBorder(theme.accent.opacity(0.3), lineWidth: 1))
                    .padding(.leading, 48)
                    .selectsOnTheMac()
                    .contextMenu { userMenu }
                    .sheet(isPresented: $selecting) { SelectableTextSheet(text: message.text) }
            } else if hasTextBubble, promptStyled, let prompt = theme.promptPrefix {
                Text("\(Text(prompt).bold())\(bubbleText)")
                    .font(theme.messageFont)
                    .foregroundStyle(theme.promptColor)
                    // The ❯ is decoration; VoiceOver (and UI tests) should get the words alone.
                    .accessibilityLabel(bubbleText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(highlightRing)
                    .selectsOnTheMac()
                    .contextMenu { userMenu }
                    .sheet(isPresented: $selecting) { SelectableTextSheet(text: message.text) }
            } else if hasTextBubble {
                Text(bubbleText)
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
                    .selectsOnTheMac()
                    .contextMenu { userMenu }
                    .sheet(isPresented: $selecting) { SelectableTextSheet(text: message.text) }
            }
            // The page of the first web link, with Link previews on (`LinkPreviewSlot`), once a
            // reply has finished.
            if !isLive, !message.isSteer, message.error == nil, hasTextBubble, !(foldsWorkingText && turn?.foldsText == true) { LinkPreviewSlot(text: message.text) }
            // A map, places, the weather, the time the reply shows (`ReplyCards`), as soon as they're asked for.
            if message.role == .assistant, let cards = message.cards, !cards.isEmpty { ReplyCardsView(cards: cards, pending: isLive) }
            // Bots it handed work to (`message_agent`): each at work on it or done, a tap from its chat.
            if message.role == .assistant, message.tools.contains(where: { $0.name == "message_agent" }) {
                ForEach(Handoff.targets(in: message), id: \.target) { HandoffRow(target: $0.target, at: $0.at) }
            }
            // Cards it made for other bots (`kanban_create`, `claude_card`): each followed on the board.
            if message.role == .assistant, message.tools.contains(where: { Handoff.cardTools.contains($0.name) }) {
                ForEach(Array(Handoff.cards(in: message).enumerated()), id: \.offset) { _, card in
                    HandoffCardRow(named: card.id, assignee: card.assignee, at: card.at)
                }
            }
            // A street address in a finished reply with no map of its own: a map of it (`AddressMaps`).
            if !isLive, message.error == nil, let found = AddressMaps.forReply(message) { AddressMapCard(found: found) }
            // Pages the agent made for the chat, live, under what it said about them.
            if message.role == .assistant, !isLive {
                ForEach(message.attachments.filter { $0.page != nil }) { AgentPage(attachment: $0, messageID: message.id) }
            }
            // Hermes stopped the turn itself: why, from the last call of the tool (`ToolStop`).
            if message.role == .assistant, !isLive, let why = toolStop {
                Label { Text(why) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .chatFont(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            if showActions, message.role == .assistant, !isLive, message.error == nil, !replyBody.isEmpty {
                actionRow
                    .transition(.opacity)
            }
        }
        // The reply finishing: its actions fade in, and the streaming edge fades into plain text.
        .animation(.easeOut(duration: 0.3), value: isLive)
        .animation(.snappy(duration: 0.25), value: message.reaction)
        .frame(maxWidth: .infinity, alignment: message.role == .user && !promptStyled ? .trailing : .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.role == .user ? (message.answering != nil ? String(localized: "Your answer", comment: "VoiceOver: a message of the person's that answers a question")
                                                     : message.isSteer ? String(localized: "Your steer") : String(localized: "You")) : replySpeaker ?? settings.headerTitle)
        .sensoryFeedback(.success, trigger: copyCount)
        .sheet(item: $fullDetail) { SelectableTextSheet(text: $0.text, title: $0.title, monospaced: true) }
        .sheet(item: $patchStep) { PatchView(title: $0.preview ?? BotMessages.stepName($0) ?? $0.name, patch: $0.output ?? "") }
    }

    /// The composer takes the keyboard, for the message that quotes.
    private func focusComposer() {
        LaunchRouter.shared.requestDraft(text: "", attachments: [])
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
    private func speakerLine(live: Bool) -> some View {
        HStack(spacing: 6) {
            if live { LiveMark(color: theme.accent) }
            if let replyFace { BotAvatar(face: replyFace, name: replySpeaker ?? settings.headerTitle, size: 20) }
            Text(replySpeaker ?? settings.headerTitle).chatFont(.subheadline, weight: .semibold)
            if live {
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

    /// One fold for all reasoning and tool calls in a run of assistant messages, behind one
    /// compact summary. Closed until tapped open (2026-11-13: opening while live made it open and
    /// shut over and over as the turn moved from message to message).
    private func turnActivityFold(_ activity: AssistantTurnActivity) -> some View {
        let open = showTurnActivity ?? false
        return VStack(alignment: .leading, spacing: 2) {
            foldHeader(open: open,
                       hint: open ? String(localized: "Hide turn activity", comment: "VoiceOver: folds away everything the agent thought and did in one turn")
                                  : String(localized: "Show turn activity", comment: "VoiceOver: opens everything the agent thought and did in one turn")) {
                withAnimation(.snappy(duration: 0.3)) { showTurnActivity = !open }
            } label: {
                Text(isLive ? activity.workingLabel : activity.completedLabel).monospacedDigit()
            }
            if open {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(activity.segments) { segment in
                        if !segment.reasoning.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Thought").chatFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                                Text(isLive && segment.messageID == message.id
                                     ? Self.tail(of: segment.reasoning, maxCharacters: 360) : segment.reasoning)
                                    .chatFont(.footnote)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(isLive && segment.messageID == message.id ? 8 : nil)
                                    .truncationMode(.head)
                            }
                        }
                        let notes = foldsWorkingText ? segment.notes : []
                        if !segment.tools.isEmpty || !notes.isEmpty {
                            stepRows(segment.tools, notes: notes, animated: isLive && segment.messageID == message.id,
                                     loadID: segment.messageID,
                                     load: onLoadTurnToolDetails.map { loader in
                                         { @MainActor @Sendable in await loader(segment.messageID) }
                                     })
                        }
                    }
                }
                .modifier(FoldBody())
            }
        }
        .animation(.snappy(duration: 0.3), value: open)
        .animation(.snappy(duration: 0.3), value: openStep)
    }

    /// The reply's thinking: "Thinking" while it happens, with the newest of it underneath, then
    /// "Thought for 6 s", which opens onto all of it. Closed until tapped open, live or not.
    private var thinkingFold: some View {
        let open = showThinking ?? false
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
    /// step for each underneath, then "Used 2 tools · 2.1 s". Closed until tapped open: opening
    /// itself while the reply had no words yet made it open and shut as words came and went.
    private var stepsFold: some View {
        let tools = message.tools
        let working = isLive && tools.contains { $0.status == .running }
        let open = showSteps ?? false
        return VStack(alignment: .leading, spacing: 2) {
            foldHeader(open: open, hint: open ? String(localized: "Hide tool steps") : String(localized: "Show tool steps")) {
                withAnimation(.snappy(duration: 0.3)) { showSteps = !open }
            } label: {
                (working ? Text("Working · \(Self.toolsSummary(tools, working: true))") : Text("Used \(Self.toolsSummary(tools, working: false))"))
                    .monospacedDigit()
            }
            if open {
                stepRows(tools, notes: foldedNotes, animated: isLive, loadID: message.id, load: onLoadToolDetails)
                    .modifier(FoldBody())
            }
        }
        .animation(.snappy(duration: 0.3), value: tools.count)
        .animation(.snappy(duration: 0.3), value: open)
        .animation(.snappy(duration: 0.3), value: openStep)
    }

    /// The tools and what the agent wrote between them (`WorkingNote`), in the order they came.
    @ViewBuilder
    private func stepRows(_ tools: [ToolActivity], notes: [WorkingNote], animated: Bool, loadID: UUID,
                          load: (@MainActor @Sendable () async -> Void)?) -> some View {
        if notes.isEmpty {
            toolRows(tools, animated: animated, loadID: loadID, load: load)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(WorkingStep.steps(tools: tools, notes: notes)) { step in
                    switch step {
                    case let .tools(run):
                        toolRows(run, animated: animated, loadID: loadID, load: load)
                    case let .note(text, _):
                        Text(text)
                            .chatFont(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// Tool rows shared by a message's own fold and a grouped turn's chronological disclosure.
    private func toolRows(_ tools: [ToolActivity], animated: Bool, loadID: UUID,
                          load: (@MainActor @Sendable () async -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(tools) { tool in
                // A step opens onto what it was called with and what came back, when
                // there is something to show or somewhere to fetch it from.
                let canOpen = tool.args != nil || tool.output != nil || load != nil
                let isOpen = openStep == tool.id
                VStack(alignment: .leading, spacing: 0) {
                    Button { toggleStep(tool, loadID: loadID, load: load) } label: {
                        HStack(alignment: .center, spacing: 12) {
                            StepMark(status: tool.status, animated: animated)
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
    }

    /// A step's state, read out by VoiceOver.
    private static func statusLabel(_ status: ToolActivity.Status) -> String {
        switch status {
        case .running: String(localized: "running", comment: "A tool step's state")
        case .completed: String(localized: "completed", comment: "A tool step's state")
        case .failed: String(localized: "failed", comment: "A tool step's state")
        }
    }

    private func toggleStep(_ tool: ToolActivity, loadID: UUID, load: (@MainActor @Sendable () async -> Void)?) {
        openStep = openStep == tool.id ? nil : tool.id
        // Opened without its result: ask once for the whole reply's.
        guard openStep == tool.id, tool.output == nil, tool.status != .running,
              !triedDetails.contains(loadID), let load else { return }
        loadingDetails = true
        Task {
            await load()
            loadingDetails = false
            triedDetails.insert(loadID)
        }
    }

    /// A step, opened: what the tool was called with, what it gave back, and the way to the
    /// whole text.
    private func stepDetail(_ tool: ToolActivity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // A file change shows the change itself; its input (the path, the old and new text) says it again.
            if let args = tool.args, !Patch.isPatch(tool.output) { detailBlock(String(localized: "Input", comment: "What a tool step was called with"), args, lines: 6) }
            if let output = tool.output, Patch.isPatch(output) {
                changeBlock(tool, Patch.files(output))
            } else if let output = tool.output {
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
            if tool.args != nil || tool.output != nil, !Patch.isPatch(tool.output) {
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

    /// A step that changed files (an agent over ACP): what it changed, its first lines in colour,
    /// and the way to the whole change.
    private func changeBlock(_ tool: ToolActivity, _ files: [PatchFile]) -> some View {
        let added = files.reduce(0) { $0 + $1.added }, removed = files.reduce(0) { $0 + $1.removed }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(String(localized: "Changes", comment: "A tool step that edited files: its changes")).chatFont(.caption2, weight: .semibold).foregroundStyle(.secondary).textCase(.uppercase)
                Text("+\(added)").foregroundStyle(.green)
                Text("−\(removed)").foregroundStyle(.red)
            }
            .chatFont(.caption2, weight: .semibold)
            .monospacedDigit()
            if let first = files.first {
                PatchFileLines(file: PatchFile(id: 0, path: first.path, added: first.added, removed: first.removed,
                                               lines: Array(first.lines.filter { $0.kind != .hunk }.prefix(8))), cap: 8)
                    .clipShape(.rect(cornerRadius: 10))
                    .background(theme.surfaceColor, in: .rect(cornerRadius: 10))
            }
            Button(files.count > 1 ? String(localized: "View changes to \(files.count) files") : String(localized: "View changes")) { patchStep = tool }
                .chatFont(.caption, weight: .medium)
                .foregroundStyle(theme.accent)
                .buttonStyle(.plain)
        }
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

    /// A finished reply in the transcript selects where it stands on a long-press; its menu is
    /// on its ··· button. In voice mode and a group chat, which have no ··· button, the
    /// long-press is still the menu.
    private var selectsInline: Bool {
        #if os(iOS)
        showActions && !isLive && conversation != nil
        #else
        false
        #endif
    }

    /// Reactions on a double-tap, as Messages has them.
    private var reacts: Bool {
        // On the Mac a double-click selects a word; the reactions are in the reply's menu.
        #if os(macOS)
        return false
        #else
        guard let conversation else { return false }
        return !isLive && !conversation.isWorkerTranscript
        #endif
    }

    @ViewBuilder
    private func replyText(_ said: String) -> some View {
        #if os(iOS)
        if selectingInline {
            SelectableReply(text: said, linkPaths: true) { selectingInline = false }
        } else {
            MarkdownView(text: said, isLive: isLive, selectable: false, linkPaths: !isLive)
        }
        #else
        // The Mac selects a reply's text with a drag, as text on a Mac does (2026-11-12: it had
        // no way to but Select text). A long-press there is a menu, not a selection.
        MarkdownView(text: said, isLive: isLive, selectable: true, linkPaths: !isLive)
        #endif
    }

    private func startSelecting(at point: CGPoint) {
        #if os(iOS)
        // Already selectable: the text view's own long-press moves the selection.
        guard !selectingInline else { return }
        InlineSelection.pending = point
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { selectingInline = true }
        #endif
    }

    /// The six reactions, for the double-tap's popover.
    private var reactionPalette: some View {
        HStack(spacing: 4) {
            ForEach(Reactions.all, id: \.emoji) { reaction in
                Button {
                    conversation?.react(to: message.id, with: message.reaction == reaction.emoji ? nil : reaction.emoji)
                } label: {
                    Text(reaction.emoji)
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .background(message.reaction == reaction.emoji ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.clear), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(message.reaction == reaction.emoji
                    ? String(localized: "Remove \(reaction.emoji)", comment: "VoiceOver: takes back a reaction to a reply")
                    : String(localized: "React \(reaction.emoji)", comment: "VoiceOver: reacts to a reply with an emoji"))
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var replyMenu: some View {
        // A row of reactions at the top, as Messages has them (`Reactions`).
        if let conversation, !isLive, !conversation.isWorkerTranscript {
            ControlGroup {
                ForEach(Reactions.all, id: \.emoji) { reaction in
                    Button {
                        conversation.react(to: message.id, with: message.reaction == reaction.emoji ? nil : reaction.emoji)
                    } label: {
                        Text(reaction.emoji)
                    }
                    .accessibilityLabel(message.reaction == reaction.emoji
                        ? String(localized: "Remove \(reaction.emoji)", comment: "VoiceOver: takes back a reaction to a reply")
                        : String(localized: "React \(reaction.emoji)", comment: "VoiceOver: reacts to a reply with an emoji"))
                }
            }
            .controlGroupStyle(.palette)
        }
        Button("Copy reply", systemImage: "doc.on.doc") { copy(message.text) }
        if let conversation, !isLive, !conversation.isWorkerTranscript {
            Button("Quote", systemImage: "text.quote") { conversation.quote(message, speaker: replySpeaker ?? settings.headerTitle); focusComposer() }
        }
        if !message.reasoning.isEmpty {
            Button("Copy thinking", systemImage: "brain") { copy(message.reasoning) }
        }
        ShareLink(item: message.text) { Label("Share…", systemImage: "square.and.arrow.up") }
        Button("Select text", systemImage: "text.cursor") { selecting = true }
        Button("Watch This…", systemImage: "eye") { WatchDraft.shared.start(PlainText.display(message.text)) }
        // Onto one of the person's lists (2026-11-09), where lists can be kept on this server.
        if TodayLists.shared.available, !isLive {
            Button("Add to a List…", systemImage: "checklist") { ListDraft.shared.start(PlainText.display(message.text)) }
        }
        if let conversation, !isLive {
            Button("Remember This", systemImage: "brain.head.profile") { conversation.send(AgentMemory.rememberMessage(PlainText.display(message.text))) }
            // What was done for this reply, kept to do again (asked 2026-11-04): the chat menu's, for one reply.
            if conversation.connection.isHermes, !conversation.isIncognito, !conversation.isWorkerTranscript, !conversation.isStreaming {
                Button("Make This a Routine…", systemImage: "repeat") { RoutineAsk.shared.reply = message.id }
            }
        }
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
        if let conversation, !conversation.isWorkerTranscript {
            Button("Quote", systemImage: "text.quote") {
                conversation.quote(message, speaker: nil, mine: true)
                focusComposer()
            }
        }
        // Selected in a copy of its own, as a reply is: the transcript's text isn't selectable.
        Button("Select text", systemImage: "text.cursor") { selecting = true }
        if let onEdit, message.role == .user {
            Button("Edit & resend", systemImage: "pencil", action: onEdit).disabled(isLive)
        }
        Button("Watch This…", systemImage: "eye") { WatchDraft.shared.start(message.text) }
        if TodayLists.shared.available {
            Button("Add to a List…", systemImage: "checklist") { ListDraft.shared.start(message.text) }
        }
        if let conversation, !isLive, message.role == .user {
            Button("Remember This", systemImage: "brain.head.profile") { conversation.send(AgentMemory.rememberMessage(message.text)) }
        }
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
    @Environment(\.openTaskNotices) private var openTaskNotices

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
        case .message, .reply, .routine, .asked, .task: botMessage
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
            : delivered.kind == .task ? delivered.title?.nilIfEmpty ?? String(localized: "A background task finished")
            : String(localized: "Message from \(name)")
        // A bot's reply to one this bot sent folds away as the thinking does: what the person
        // reads (and hears) is this bot's answer, which follows it. So does what a schedule came
        // up with, which the bot answers next.
        // A task's notice too, once the agent answered it (over the Hermes API it doesn't: shown open).
        // But not one whose words a notification showed (`TaskReports`): those stay open, or the
        // chat it opened read as something else than it said (GitHub #63).
        let folds = (delivered.kind == .reply || delivered.kind == .routine
                     || (delivered.kind == .task && delivered.noted == true && !openTaskNotices.contains(message.id))) && !unanswered
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
                        } else if delivered.kind == .task {
                            Image(systemName: "checklist").frame(width: 20)
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
                    if delivered.kind == .task {
                        Image(systemName: "checklist").frame(width: 20).foregroundStyle(.secondary)
                    } else {
                        BotAvatar(face: face, name: name, size: 20)
                    }
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

/// What a press on a reply's text does. In the transcript a long-press selects the text where it
/// stands (`InlineSelection`) and a double-tap brings up the reactions; elsewhere (voice mode, a
/// group chat, the Mac) the long-press is the reply's menu, as before.
private struct ReplyPress<Menu: View, Palette: View>: ViewModifier {
    let inline: Bool
    let reacts: Bool
    @ViewBuilder let menu: () -> Menu
    @ViewBuilder let reactions: () -> Palette
    let onPress: (CGPoint) -> Void
    @State private var showReactions = false

    func body(content: Content) -> some View {
        content
            // No menu at all where the press selects: an empty one still shrinks the reply as the
            // finger goes down, and on the iPad its press took the touch from the selection
            // (2026-11-11). The optional form drops it without changing the view's identity.
            .contextMenu(inline ? nil : ContextMenu { menu() })
            #if os(iOS)
            .gesture(ReplyLongPress { if inline { onPress($0) } })
            #endif
            .simultaneousGesture(TapGesture(count: 2).onEnded { if reacts { showReactions = true } })
            .popover(isPresented: $showReactions) { reactions().presentationCompactAdaptation(.popover) }
    }
}

extension View {
    /// The Mac's text selects with a drag. On the iPhone a selectable text costs a UIKit
    /// interaction per paragraph (see `MarkdownView.selectable`), so there it stays a menu's.
    @ViewBuilder
    func selectsOnTheMac() -> some View {
        #if os(macOS)
        textSelection(.enabled)
        #else
        self
        #endif
    }
}
