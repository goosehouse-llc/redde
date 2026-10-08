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
    private var hasTextBubble: Bool { !(message.text.isEmpty && !message.attachments.isEmpty) }

    /// Terminal-family themes render your messages as shell input (`❯ text`), left-aligned
    /// and unbubbled, the way a prompt line sits in a terminal.
    private var promptStyled: Bool {
        theme.promptPrefix != nil && message.role == .user && !message.isSteer
    }

    /// A reply straight on the page, under the agent's name.
    private var flatReply: Bool { message.role == .assistant && theme.palette.flatReplies && message.error == nil }

    @Environment(\.theme) private var theme
    @State private var settings = Settings.shared
    @State private var showThinking = false
    @State private var showSteps = false
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
            if !message.attachments.isEmpty { AttachmentGallery(attachments: message.attachments) }
            if isLive, message.text.isEmpty {
                // Waiting for the first token: the app's waveform, breathing.
                WaveformPulse(color: theme.accent)
                    .padding(.horizontal, flatReply ? 2 : 16)
                    .padding(.vertical, flatReply ? 4 : 12)
                    .background(flatReply ? AnyShapeStyle(.clear) : bubble, in: .rect(cornerRadius: theme.bubbleRadius))
                    .accessibilityLabel("Waiting for reply")
            } else if message.role == .assistant, message.error == nil, hasTextBubble {
                MarkdownView(text: message.text, isLive: isLive)
                    .padding(.horizontal, flatReply ? 2 : 14)
                    .padding(.vertical, flatReply ? 0 : theme.bubbleVerticalPadding)
                    .background(flatReply ? AnyShapeStyle(.clear) : bubble, in: .rect(cornerRadius: theme.bubbleRadius))
                    .foregroundStyle(theme.textColor)
                    .contextMenu { replyMenu }
                    .overlay(highlightRing)
                    .sheet(isPresented: $selecting) { SelectableTextSheet(text: message.text) }
            } else if message.isSteer {
                Label(message.text, systemImage: "arrow.turn.down.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.12), in: .capsule)
            } else if hasTextBubble, promptStyled, let prompt = theme.promptPrefix {
                Text("\(Text(prompt).bold())\(message.text)")
                    .font(theme.messageFont)
                    .textSelection(.enabled)
                    .foregroundStyle(theme.promptColor)
                    // The ❯ is decoration; VoiceOver (and UI tests) should get the words alone.
                    .accessibilityLabel(message.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(highlightRing)
                    .contextMenu { userMenu }
            } else if hasTextBubble {
                Text(message.text)
                    .font(theme.userFont)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, theme.bubbleVerticalPadding)
                    .background(bubble, in: .rect(cornerRadius: theme.bubbleRadius))
                    .foregroundStyle(message.role == .user ? theme.userBubbleText : theme.textColor)
                    .overlay(highlightRing)
                    .contextMenu { userMenu }
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
        .accessibilityLabel(message.role == .user ? (message.isSteer ? "Your steer" : "You") : settings.headerTitle)
        .sensoryFeedback(.success, trigger: copyCount)
        .sheet(item: $fullDetail) { SelectableTextSheet(text: $0.text, title: $0.title, monospaced: true) }
    }

    /// Copies, ticks, turns the copy button into a check for a moment and says so in a toast.
    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        copyCount += 1
        toaster?.show("Copied")
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
            Text(settings.headerTitle).font(.subheadline.weight(.semibold))
            if isLive {
                // The one place that shimmers while the reply is being worked on.
                TimelineView(.periodic(from: message.createdAt, by: 1)) { context in
                    ShimmerText(text: "is working · \(Self.elapsed(from: message.createdAt, to: context.date))")
                        .font(.subheadline)
                        .monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "5 s", "1 min 12 s".
    private static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s < 60 ? "\(s) s" : "\(s / 60) min \(s % 60) s"
    }

    // MARK: - Folds

    /// The line a reply's thinking and its tool steps each fold to: a chevron and a quiet label.
    /// One style for both, so the two read as a pair.
    private func foldHeader(open: Bool, hint: String, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                label()
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .padding(.trailing, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hint)
    }

    /// The reply's thinking: "Thinking" while it happens, with the newest of it underneath, then
    /// "Thought for 6 s", which opens onto all of it.
    private var thinkingFold: some View {
        VStack(alignment: .leading, spacing: 2) {
            foldHeader(open: showThinking || isLive, hint: showThinking ? "Hide thinking" : "Show thinking") {
                withAnimation(.snappy(duration: 0.3)) { showThinking.toggle() }
            } label: {
                thinkingLabel
            }
            .disabled(isLive)
            if isLive || showThinking { reasoningText }
        }
    }

    /// "Thinking" with a light sweeping across it while the model thinks (the speaker line
    /// counts the seconds), "Thought for 6 s" after. Replies saved before the times were kept
    /// just say "Thought".
    @ViewBuilder
    private var thinkingLabel: some View {
        if isLive, message.text.isEmpty {
            ShimmerText(text: "Thinking")
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
            .font(.footnote)
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
        let open = (isLive && message.text.isEmpty) || showSteps
        return VStack(alignment: .leading, spacing: 2) {
            foldHeader(open: open, hint: open ? "Hide tool steps" : "Show tool steps") {
                withAnimation(.snappy(duration: 0.3)) { showSteps.toggle() }
            } label: {
                Text(working ? "Working · \(Self.toolsSummary(tools, working: true))" : "Used \(Self.toolsSummary(tools, working: false))")
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
                                        Text(tool.name).font(.subheadline)
                                            .foregroundStyle(tool.status == .running ? .primary : .secondary)
                                        if let preview = tool.preview, !preview.isEmpty {
                                            Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    if canOpen {
                                        Image(systemName: "chevron.right")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                                    }
                                }
                                .padding(.vertical, 7)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .disabled(!canOpen)
                            .accessibilityLabel("Tool \(tool.name), \(tool.status.rawValue)")
                            .accessibilityHint(canOpen ? (isOpen ? "Hides what it returned" : "Shows what it returned") : "")
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
            if let args = tool.args { detailBlock("Input", args, lines: 6) }
            if let output = tool.output {
                detailBlock("Output", output, lines: 12)
            } else if tool.status == .running {
                Text("Still running.").font(.caption).foregroundStyle(.secondary)
            } else if loadingDetails {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Fetching the output…")
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No output was kept for this step.").font(.caption).foregroundStyle(.secondary)
            }
            if tool.args != nil || tool.output != nil {
                HStack(spacing: 18) {
                    Button("Copy") { copy(tool.output ?? tool.args ?? "") }
                        .accessibilityLabel("Copy \(tool.output != nil ? "output" : "input")")
                    Button(tool.output != nil ? "Open full output" : "Open in full") { fullDetail = ToolDetail(tool) }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.accent)
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 32).padding(.bottom, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func detailBlock(_ label: String, _ text: String, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(Self.head(of: text, lines: lines))
                .font(.caption.monospaced())
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

    /// "3 tools", then "3 tools · 4.2 s" once they are all done and were timed.
    private static func toolsSummary(_ tools: [ToolActivity], working: Bool) -> String {
        let count = tools.count == 1 ? "1 tool" : "\(tools.count) tools"
        guard !working, let start = tools.compactMap(\.startedAt).min(), let end = tools.compactMap(\.endedAt).max(), end > start else { return count }
        let seconds = end.timeIntervalSince(start)
        return seconds < 10 ? count + String(format: " · %.1f s", seconds) : count + " · \(Int(seconds)) s"
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
            .accessibilityLabel(copied ? "Copied" : "Copy reply")
            if let onReadAloud {
                actionButton(isReading ? "Stop reading" : "Read aloud",
                             isReading ? "stop.fill" : "speaker.wave.2", action: onReadAloud)
            }
            if let onRegenerate {
                actionButton("Regenerate", "arrow.clockwise", action: onRegenerate)
            }
            Menu { replyMenu } label: {
                Image(systemName: "ellipsis").frame(width: 32, height: 32).contentShape(.rect)
            }
            .accessibilityLabel("More")
            if let metrics = message.metrics, metrics.completedAt != nil {
                Button { withAnimation(.easeOut(duration: 0.15)) { fullMetrics.toggle() } } label: {
                    Text(fullMetrics ? metrics.summary : Self.compact(metrics))
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1)
                        .padding(.leading, 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(metrics.summary)
                .accessibilityHint(fullMetrics ? "Shows fewer timings" : "Shows every timing")
            }
        }
        .font(.subheadline)
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
        guard text.count > maxCharacters else { return text }
        var cut = text.suffix(maxCharacters)
        if let space = cut.firstIndex(where: \.isWhitespace) { cut = cut[cut.index(after: space)...] }
        return "…" + cut
    }

    /// "3m 12s · 32 tok/s": how long the whole reply took, and speed. (It showed the time to the
    /// first token, which for a model that thinks first is under a second on a 3-minute reply.)
    private static func compact(_ m: TurnMetrics) -> String {
        var parts: [String] = []
        if let t = m.total ?? m.timeToFirstToken { parts.append(duration(t)) }
        if let tps = m.tokensPerSecond { parts.append(String(format: "%.0f tok/s", tps)) }
        return parts.isEmpty ? m.summary : parts.joined(separator: " · ")
    }

    /// "12.3 s" under a minute, "3m 12s" from there.
    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let whole = Int(seconds.rounded())
        return "\(whole / 60)m \(String(format: "%02d", whole % 60))s"
    }

    @ViewBuilder
    private var replyMenu: some View {
        Button("Copy reply", systemImage: "doc.on.doc") { copy(message.text) }
        if !message.reasoning.isEmpty {
            Button("Copy thinking", systemImage: "brain") { copy(message.reasoning) }
        }
        ShareLink(item: message.text) { Label("Share…", systemImage: "square.and.arrow.up") }
        Button("Select text", systemImage: "text.cursor") { selecting = true }
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
        if let onEdit, message.role == .user {
            Button("Edit & resend", systemImage: "pencil", action: onEdit).disabled(isLive)
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
        text = [tool.args.map { "INPUT\n\n" + $0 }, tool.output.map { "OUTPUT\n\n" + $0 }]
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
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.red)
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
