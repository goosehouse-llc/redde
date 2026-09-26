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
    @State private var selecting = false
    @State private var fullMetrics = false

    var body: some View {
        VStack(alignment: message.role == .user && !promptStyled ? .trailing : .leading, spacing: 8) {
            if message.role == .assistant, theme.promptPrefix == nil { speakerLine }
            if message.role == .assistant { workRow }
            if message.role == .assistant, !message.reasoning.isEmpty, isLive || showThinking { reasoningText }
            if isLive, message.role == .assistant, !message.tools.isEmpty, message.text.isEmpty { liveSteps }
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
                    .foregroundStyle(theme.text ?? Color.primary)
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
                    .foregroundStyle(message.role == .user ? theme.userBubbleText : (theme.text ?? Color.primary))
                    .overlay(highlightRing)
                    .contextMenu { userMenu }
            }
            if showActions, message.role == .assistant, !isLive, message.error == nil, !message.text.isEmpty {
                actionRow
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user && !promptStyled ? .trailing : .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.role == .user ? (message.isSteer ? "Your steer" : "You") : settings.headerTitle)
    }

    // MARK: - Reply parts

    /// Who is talking, and while the reply runs, for how long.
    private var speakerLine: some View {
        HStack(spacing: 6) {
            Text(settings.headerTitle).font(.subheadline.weight(.semibold))
            if isLive {
                TimelineView(.periodic(from: message.createdAt, by: 1)) { context in
                    Text("is working · \(Self.elapsed(from: message.createdAt, to: context.date))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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

    /// Thinking and the tools the reply used, as small tags; tapping Thinking opens it.
    @ViewBuilder
    private var workRow: some View {
        let hasThinking = !message.reasoning.isEmpty
        let showTools = !message.tools.isEmpty && !(isLive && message.text.isEmpty)
        if hasThinking || showTools {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if hasThinking {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { showThinking.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                SparkShape().fill(.secondary).frame(width: 10, height: 10)
                                Text(isLive && message.text.isEmpty ? "Thinking…" : "Thought")
                                if !isLive {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .rotationEffect(.degrees(showThinking ? 90 : 0))
                                }
                            }
                            .modifier(WorkChip())
                        }
                        .buttonStyle(.plain)
                        .disabled(isLive)
                        .symbolEffect(.pulse, isActive: isLive && message.text.isEmpty)
                        .accessibilityLabel(showThinking ? "Hide thinking" : "Show thinking")
                    }
                    if showTools {
                        ForEach(message.tools) { tool in
                            HStack(spacing: 5) {
                                Image(systemName: "wrench.adjustable")
                                Text(tool.name)
                                statusIcon(tool.status)
                            }
                            .modifier(WorkChip())
                            .help(tool.preview ?? tool.name)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Tool \(tool.name), \(tool.status.rawValue)")
                        }
                    }
                }
                .padding(.horizontal, 1)
            }
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }

    /// While a reply is working and hasn't started writing: each tool as a step, done or running.
    private var liveSteps: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(message.tools) { tool in
                HStack(alignment: .center, spacing: 12) {
                    Group {
                        switch tool.status {
                        case .running: ProgressView().controlSize(.small)
                        case .completed:
                            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
                                .frame(width: 20, height: 20).background(.green.opacity(0.16), in: .circle)
                        case .failed:
                            Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.red)
                                .frame(width: 20, height: 20).background(.red.opacity(0.16), in: .circle)
                        }
                    }
                    .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tool.name).font(.subheadline)
                            .foregroundStyle(tool.status == .running ? .primary : .secondary)
                        if let preview = tool.preview, !preview.isEmpty {
                            Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface ?? Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
    }

    @ViewBuilder
    private func statusIcon(_ status: ToolActivity.Status) -> some View {
        switch status {
        case .running: Image(systemName: "circle.dotted").symbolEffect(.pulse).foregroundStyle(.orange)
        case .completed: Image(systemName: "checkmark").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark").foregroundStyle(.red)
        }
    }

    /// Copy, read aloud, retry, more; then how fast it came back.
    private var actionRow: some View {
        HStack(spacing: 2) {
            actionButton("Copy", "doc.on.doc") { UIPasteboard.general.string = message.text }
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
        Button("Copy reply", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
        if !message.reasoning.isEmpty {
            Button("Copy thinking", systemImage: "brain") { UIPasteboard.general.string = message.reasoning }
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

/// The small outlined tag for Thinking and each tool.
private struct WorkChip: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            .contentShape(.rect)
    }
}

#Preview {
    let conversation = Conversation()
    ContentView()
        .environment(conversation)
        .environment(VoiceSession(conversation: conversation))
}
