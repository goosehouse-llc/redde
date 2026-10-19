import SwiftUI

/// A group chat: the room's conversation, each bot's reply under its face and name, and a field to
/// say something to all of them or, with an @tag, to one. Hermes runs the room (`ServerGroups.swift`);
/// this screen reads what was said and says what the person types.
struct GroupChatView: View {
    @State private var feed: GroupFeed
    /// The room was ended here: the list lets it go.
    var onEnded: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var draft = ""
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmingEnd = false
    @FocusState private var focused: Bool

    init(room: GroupRoom, onEnded: @escaping () -> Void = {}) {
        #if DEBUG
        if room.id == GroupRoom.demo.id {
            _feed = State(initialValue: GroupFeed.demo())
            self.onEnded = onEnded
            return
        }
        #endif
        _feed = State(initialValue: GroupFeed(room: room))
        self.onEnded = onEnded
    }

    private var faces: [String: BotFace] { BotDirectory.shared.roster?.faces ?? [:] }
    private func face(_ member: GroupMember?) -> BotFace { faces[member?.profile ?? ""] ?? BotFace(seed: member?.profile ?? "bot") }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if feed.events.isEmpty, feed.sending.isEmpty { opening }
                        ForEach(feed.events.filter { $0.isMessage || $0.note(in: feed.room) != nil }) { row($0) }
                        ForEach(feed.sending, id: \.id) { mine($0.text, waiting: true) }
                        if feed.discussing || feed.state.working { talking }
                        ForEach(feed.state.approvals) { approval in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(feed.room.member(approval.memberID)?.label ?? "A bot") wants to run a command")
                                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                                ApprovalCard(request: approval.request) { feed.answer(approval, $0) }
                            }
                        }
                        if let problem = feed.problem {
                            Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .onChange(of: feed.events.count) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: feed.sending.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .background(theme.pageColor)
            .safeAreaInset(edge: .bottom) { composer }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { title }
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Rename", systemImage: "pencil") { renameText = feed.room.name; renaming = true }
                        Divider()
                        Button("End Group Chat", systemImage: "xmark.bin", role: .destructive) { confirmingEnd = true }
                    } label: { Label("More", systemImage: "ellipsis") }
                }
            }
            .alert("Rename group chat", isPresented: $renaming) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    Task { try? await feed.rename(to: name) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("End “\(feed.room.name)”?", isPresented: $confirmingEnd, titleVisibility: .visible) {
                Button("End Group Chat", role: .destructive) {
                    Task {
                        try? await HermesServeClient.shared.disbandGroup(feed.room.id)
                        onEnded()
                        dismiss()
                    }
                }
            } message: {
                Text("The bots stop and the group chat goes, on the server too. The bots' own chats stay.")
            }
            .task { await feed.follow() }
        }
    }

    // MARK: Parts

    private var title: some View {
        HStack(spacing: 8) {
            FaceStack(faces: feed.room.members.prefix(3).map { face($0) }, size: 22)
            Text(feed.room.name).font(.headline).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var opening: some View {
        VStack(spacing: 12) {
            FaceStack(faces: feed.room.members.map { face($0) }, size: 44)
            Text(feed.room.members.map(\.label).formatted(.list(type: .and)))
                .font(.headline).multilineTextAlignment(.center)
            Text("Say something to all of them, or start with @ and a name to ask one. A bot that has nothing to add stays quiet.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    @ViewBuilder
    private func row(_ event: GroupEvent) -> some View {
        if event.kind == "message.user" {
            mine(event.text, waiting: false)
        } else if event.kind == "message.member" {
            let member = feed.room.member(event.actorID)
            // Its seq makes the reply's id: the same message keeps its row as the log is read again.
            MessageRow(message: Message(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", event.seq)) ?? UUID(),
                                        role: .assistant, text: event.text, createdAt: event.createdAt),
                       showActions: false)
                .environment(\.replySpeaker, member?.label ?? "A bot")
                .environment(\.replyFace, face(member))
        } else if let note = event.note(in: feed.room) {
            Text(note).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }

    private func mine(_ text: String, waiting: Bool) -> some View {
        Text(text)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(theme.accent, in: .rect(cornerRadius: 20))
            .foregroundStyle(.white)
            .opacity(waiting ? 0.6 : 1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var talking: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(feed.state.blocked ? "Waiting on you" : "The bots are talking…").font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// The other bots a tag being typed could be.
    private var tagSuggestions: [GroupMember] {
        guard let typed = BotMentions.typing(in: draft)?.lowercased() else { return [] }
        return feed.room.members.filter {
            typed.isEmpty || $0.handle.lowercased().hasPrefix(typed) || $0.label.lowercased().hasPrefix(typed)
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            let suggestions = tagSuggestions
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions) { member in
                        Button {
                            if let typed = BotMentions.typing(in: draft) { draft = String(draft.dropLast(typed.count + 1)) + "@" + member.handle + " " }
                            focused = true
                        } label: {
                            HStack(spacing: 10) {
                                BotAvatar(face: face(member), size: 22)
                                Text("@" + member.handle).font(.callout.weight(.medium))
                                Text(member.label).font(.caption).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(theme.surfaceColor, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message the group", text: $draft, axis: .vertical)
                    .lineLimit(1 ... 6)
                    .focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(theme.surfaceColor, in: .rect(cornerRadius: 22))
                if feed.discussing || feed.state.working, draft.isEmpty {
                    Button("Stop", systemImage: "stop.fill") { feed.stop() }
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(theme.surfaceColor, in: .circle)
                } else {
                    Button("Send", systemImage: "arrow.up") {
                        feed.send(draft)
                        draft = ""
                    }
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(theme.accent, in: .circle)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }
}

/// A few bots' faces overlapping, for a group chat.
struct FaceStack: View {
    var faces: [BotFace]
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: -size * 0.35) {
            ForEach(Array(faces.enumerated()), id: \.offset) { _, face in
                BotAvatar(face: face, size: size)
                    .background(Circle().fill(Color(.systemBackground)).padding(-1.5))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A new group chat: two to six bots, and a name.
struct NewGroupChatView: View {
    let bots: [HermesBot]
    let mainName: String
    let onCreated: (GroupRoom) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [String] = []
    @State private var name = ""
    @State private var creating = false
    @State private var problem: String?

    private var faces: [String: BotFace] { BotDirectory.shared.roster?.faces ?? [:] }
    private var chosen: [HermesBot] { picked.compactMap { name in bots.first { $0.name == name } } }
    private var defaultName: String { chosen.map { $0.label(mainName: mainName) }.formatted(.list(type: .and)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(bots) { bot in
                        Button {
                            if let i = picked.firstIndex(of: bot.name) { picked.remove(at: i) } else if picked.count < 6 { picked.append(bot.name) }
                        } label: {
                            HStack(spacing: 12) {
                                BotAvatar(face: faces[bot.name] ?? BotFace(seed: bot.name), size: 30)
                                Text(bot.label(mainName: mainName))
                                Spacer()
                                if picked.contains(bot.name) { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(picked.contains(bot.name) ? .isSelected : [])
                    }
                } header: {
                    Text("Bots")
                } footer: {
                    Text("Two to six. A message goes to all of them, or with an @tag to one; they answer one after another, and may ask each other.")
                }
                Section("Name") {
                    TextField(defaultName.isEmpty ? "Group chat" : defaultName, text: $name)
                }
                if let problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
            }
            .navigationTitle("New Group Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(picked.count < 2 || creating)
                }
            }
        }
    }

    private func create() {
        creating = true
        problem = nil
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { creating = false }
            do {
                let room = try await HermesServeClient.shared.createGroup(named: typed.isEmpty ? defaultName : typed, bots: chosen, mainName: mainName)
                dismiss()
                onCreated(room)
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
