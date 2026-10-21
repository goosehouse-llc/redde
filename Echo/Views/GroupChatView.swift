import SwiftUI

/// A group chat: the room's conversation, each bot's reply under its face and name, and a field to
/// say something to all of them or, with an @tag, to one. Hermes runs the room (`ServerGroups.swift`);
/// this screen reads what was said and says what the person types. It takes the chat's place
/// (`GroupDirectory.open`), so the list is a swipe away as it is from a conversation, and its
/// bubbles and buttons are the conversation's own.
struct GroupChatView: View {
    @State private var feed: GroupFeed
    /// The composer's focus, the chat's: the list closes the keyboard as it slides in.
    var focused: FocusState<Bool>.Binding
    /// iPhone: opens the conversation list (the button the chat has there).
    var openList: (() -> Void)?
    /// The room was ended here: the list lets it go.
    var onEnded: () -> Void = {}
    @Environment(\.theme) private var theme
    @Environment(VoiceSession.self) private var voiceSession
    @Environment(\.scenePhase) private var scenePhase
    /// The reply being read aloud.
    @State private var readingID: UUID?
    /// Talking with the group by voice, on the voice screen.
    @State private var voice = GroupVoice()
    @State private var showingVoice = false
    @Environment(Conversation.self) private var conversation
    /// Find in this chat: open, what is looked for, and which match is the one shown.
    @State private var finding = false
    @State private var findText = ""
    @State private var findIndex = 0
    @FocusState private var findFocused: Bool
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmingEnd = false
    /// The first message shown, by its number in the log: set once from the front, so a message
    /// added at the end never takes rows off the top. Earlier ones wait behind "Show earlier".
    @State private var shownFrom: Int?
    /// The newest message is on screen: a new one is followed, and rows growing keep the end in place.
    @State private var atEnd = true
    /// How many messages a page holds. The stack isn't lazy (lazy rows taking their real heights
    /// as they came into view made the scroll jump; see TranscriptView), so it is kept short.
    static let pageSize = 30

    init(room: GroupRoom, focused: FocusState<Bool>.Binding, openList: (() -> Void)?, onEnded: @escaping () -> Void = {}) {
        self.focused = focused
        self.openList = openList
        self.onEnded = onEnded
        #if DEBUG
        if room.id == GroupRoom.demo.id || room.id == GroupRoom.demoDesktop.id {
            _feed = State(initialValue: GroupFeed.demo(room))
            return
        }
        #endif
        _feed = State(initialValue: GroupFeed(room: room))
    }

    private var faces: [String: BotFace] { BotDirectory.shared.roster?.faces ?? [:] }
    private func face(_ member: GroupMember?) -> BotFace { faces[member?.profile ?? ""] ?? BotFace(seed: member?.profile ?? "bot") }

    var body: some View {
        Group {
            ScrollViewReader { proxy in
                ScrollView {
                    let page = shownRows
                    VStack(alignment: .leading, spacing: 18) {
                        if feed.room.omitted > 0 {
                            Text("Earlier messages are in Hermes Desktop.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                        if page.hidden > 0 {
                            Button {
                                let anchor = page.shown.first?.id
                                showEarlier()
                                if let anchor { Task { proxy.scrollTo(anchor, anchor: .top) } }
                            } label: {
                                Label("Show earlier messages (\(page.hidden))", systemImage: "arrow.up.circle").font(.footnote)
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        }
                        if feed.events.isEmpty, feed.sending.isEmpty { opening }
                        ForEach(page.shown) { row($0).id($0.id) }
                        ForEach(feed.sending) { mine($0.text, files: $0.files, id: $0.id, waiting: true, when: .distantPast) }
                        // Replies being written, under their bots, until the room has them.
                        ForEach(feed.drafts.filter { !$0.text.isEmpty }) { writing($0) }
                        if feed.state.waitsOnPerson || (feed.discussing || feed.state.working) && !someoneIsWriting { talking }
                        ForEach(feed.state.approvals.filter { !feed.answering.contains($0.id) }) { approval in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(feed.room.member(approval.memberID)?.label ?? "A bot") wants to run a command")
                                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                                ApprovalCard(request: approval.request) { feed.answer(approval, $0) }
                                // Hermes's approvals.timeout, 300 s unless changed; unanswered, the command isn't run.
                                Text("Not answered in about 5 minutes, it isn't run.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(feed.state.retries.filter { !feed.answering.contains($0) }, id: \.self) { retryCard($0) }
                        if let problem = feed.problem {
                            Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                // Opened at the latest, as a chat is. A blanket bottom anchor would also re-aim on
                // every change of size, pulling the page about while reading back.
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(atEnd ? .bottom : nil, for: .sizeChanges)
                .onScrollGeometryChange(for: Bool.self) { TranscriptEnd.isReached($0) } action: { _, reached in atEnd = reached }
                // Something new is followed only from the end: reading back isn't pulled away.
                .onChange(of: feed.events.count) {
                    settleShown()
                    voice.roomChanged()
                    ChatActivity.shared.roomSeen(feed.room.id, upTo: feed.seenMark)
                    if atEnd { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .onChange(of: feed.sending.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                // A reply starting to be written, from the end: its row in view (it grows in place).
                .onChange(of: feed.drafts.count) { if atEnd { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: feed.state.approvals.count + feed.state.retries.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onAppear { settleShown() }
                .safeAreaInset(edge: .top, spacing: 0) { if finding { findBar(proxy) } }
                .onChange(of: findText) { findIndex = 0; goToMatch(0, proxy) }
                .onChange(of: finding) { _, on in
                    if on { findFocused = findText.isEmpty } else { findText = ""; findIndex = 0 }
                }
                #if DEBUG
                // `-echo.groupFind <words>`: Find open on those words (screenshots).
                .onAppear {
                    if let words = DevHooks.value("-echo.groupFind") { findText = words; finding = true }
                    // `-echo.groupVoice [bot]`: the voice screen open on the room (with that bot's reply being read).
                    if DevHooks.has("-echo.groupVoice") { showingVoice = true }
                }
                #endif
            }
            .chatTextSize()
            .background(theme.pageColor)
            .foregroundStyle(theme.textColor)
            .safeAreaInset(edge: .bottom) {
                Group {
                    if feed.room.inDesktop {
                        desktopNote
                    } else {
                        GroupComposer(feed: feed, focused: focused, face: face) { showingVoice = true }
                    }
                }
                    .frame(maxWidth: 820).frame(maxWidth: .infinity)
                    // As under a conversation: solid themes have no glass to hide what scrolls past.
                    .background(theme.usesGlass ? AnyShapeStyle(.clear) : AnyShapeStyle(theme.pageColor))
            }
            .navigationTitle(feed.room.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { title }
                ToolbarItem(placement: .topBarLeading) {
                    if let openList {
                        Button("Conversations", systemImage: "list.bullet") { openList() }
                            .keyboardShortcut("k", modifiers: .command)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { menu }
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
                    }
                }
            } message: {
                Text("The bots stop and the group chat goes, on the server too. The bots' own chats stay.")
            }
            // Read while the app is in front, or while its voice screen reads the room aloud
            // (the phone locked, or in the car); not, as it was, through every background minute.
            .task(id: scenePhase == .active || voice.isOn) {
                guard scenePhase == .active || voice.isOn else { return }
                await feed.follow()
            }
            .onChange(of: feed.state) { voice.roomChanged() }
            // A reply being written is read as it is (`GroupVoice`).
            .onChange(of: feed.drafts) { voice.roomChanged() }
            .onChange(of: voiceSession.phase) { voice.sessionChanged() }
            .onChange(of: voiceSession.continuous) { voice.sessionChanged() }
            // The voice screen, as a conversation's, with the room's bots on it.
            .fullScreenCover(isPresented: $showingVoice) {
                VoiceView(session: voiceSession, onSwitchToTyping: {
                    Task { try? await Task.sleep(for: .milliseconds(450)); focused.wrappedValue = true }
                }, group: GroupVoiceScene(voice: voice, feed: feed, face: face))
                // Handed over by hand: a full-screen cover on a Mac doesn't inherit the environment.
                .environment(conversation)
                .environment(voiceSession)
                .environment(\.theme, theme)
                .onAppear {
                    voice.start(feed, session: voiceSession)
                    #if DEBUG
                    if let who = DevHooks.value("-echo.groupVoice"), !who.hasPrefix("-") {
                        Task { try? await Task.sleep(for: .seconds(1.5)); voice.demoSpeaking(who) }
                    }
                    #endif
                }
            }
            .onChange(of: showingVoice) { _, open in if !open { voice.stop() } }
            // Leaving the group chat ends talking with it: the voice session is the app's.
            .onDisappear {
                voice.stop()
                ChatActivity.shared.roomSeen(feed.room.id, upTo: feed.seenMark)
            }
        }
    }

    // MARK: Paging

    /// What the log shows: its messages and the notes on turns.
    private var rows: [GroupEvent] { feed.events.filter { $0.isMessage || $0.note(in: feed.room) != nil } }

    /// The rows from `shownFrom` on (the newest page until it is set), and how many come before.
    private var shownRows: (shown: [GroupEvent], hidden: Int) {
        let all = rows
        let start = shownFrom.map { from in all.firstIndex { $0.seq >= from } ?? all.count } ?? max(0, all.count - Self.pageSize)
        return (Array(all[start...]), start)
    }

    /// The first time there is a log, the page starts at its newest messages.
    private func settleShown() {
        guard shownFrom == nil else { return }
        let all = rows
        guard !all.isEmpty else { return }
        shownFrom = all[max(0, all.count - Self.pageSize)].seq
    }

    private func showEarlier() {
        let all = rows
        let start = shownFrom.map { from in all.firstIndex { $0.seq >= from } ?? all.count } ?? all.count
        guard start > 0 else { return }
        shownFrom = all[max(0, start - Self.pageSize)].seq
    }

    // MARK: Parts

    private var menu: some View {
        Menu {
            Button("Find in Chat", systemImage: "magnifyingglass") { withAnimation { finding = true } }
                .keyboardShortcut("f", modifiers: .command)
            // Hermes Desktop's are its own to name and end.
            if !feed.room.inDesktop {
                Button("Rename", systemImage: "pencil") { renameText = feed.room.name; renaming = true }
                MuteMenu(item: "room:" + feed.room.id)
                Divider()
                Button("End Group Chat", systemImage: "xmark.bin", role: .destructive) { confirmingEnd = true }
            }
        } label: { Label("More", systemImage: "ellipsis") }
    }

    // MARK: Find

    /// The messages the words are in, by their numbers in the log, oldest first.
    private var matches: [Int] {
        let words = findText.trimmingCharacters(in: .whitespaces)
        guard finding, !words.isEmpty else { return [] }
        return rows.filter { $0.isMessage && AttachedFileNote.strip($0.text).localizedCaseInsensitiveContains(words) }.map(\.seq)
    }

    private func highlight(_ seq: Int) -> MessageRow.Highlight {
        let found = matches
        guard let at = found.firstIndex(of: seq) else { return .none }
        return at == findIndex ? .current : .match
    }

    /// To a match, the earlier messages shown first when it is among them.
    private func goToMatch(_ index: Int, _ proxy: ScrollViewProxy) {
        let found = matches
        guard !found.isEmpty else { return }
        findIndex = (index % found.count + found.count) % found.count
        let seq = found[findIndex]
        if let from = shownFrom, seq < from { shownFrom = seq }
        Task { withAnimation { proxy.scrollTo(seq, anchor: .center) } }
    }

    private func findBar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in chat", text: $findText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused($findFocused)
                .onSubmit { goToMatch(findIndex + 1, proxy) }
                .submitLabel(.search)
            if !findText.isEmpty {
                let count = matches.count
                Text(count == 0 ? "0" : "\(findIndex + 1) of \(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(count == 0 ? "No matches" : "Match \(findIndex + 1) of \(count)")
            }
            Button("Previous match", systemImage: "chevron.up") { goToMatch(findIndex - 1, proxy) }
                .disabled(matches.count < 2)
            Button("Next match", systemImage: "chevron.down") { goToMatch(findIndex + 1, proxy) }
                .disabled(matches.count < 2)
            Button("Done") { withAnimation { finding = false } }
                .font(.body.weight(.semibold))
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// The speaker button under a reply: read it, or stop if it's the one being read.
    private func readAloud(_ id: UUID, _ text: String, speaker: String?) {
        if voiceSession.phase == .speaking {
            let wasThis = readingID == id
            voiceSession.stopSpeaking()
            readingID = nil
            if wasThis { return }
        }
        guard voiceSession.phase == .idle || { if case .error = voiceSession.phase { true } else { false } }() else { return }
        readingID = id
        voiceSession.readAloud(text, speaker: speaker)
    }

    /// In place of the field, for a room Hermes Desktop runs: Desktop answers its messages, and
    /// shares only a copy of the last few, so this one is read here and talked in there.
    private var desktopNote: some View {
        Label("This group chat runs in Hermes Desktop. Its last messages show here; to talk in it, use Desktop.",
              systemImage: "desktopcomputer")
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal).padding(.vertical, 12)
    }

    private var title: some View {
        HStack(spacing: 8) {
            FaceStack(faces: feed.room.members.prefix(3).map { (face($0), $0.label) }, size: 22)
            Text(feed.room.name).font(.headline).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var opening: some View {
        VStack(spacing: 12) {
            FaceStack(faces: feed.room.members.map { (face($0), $0.label) }, size: 44)
            Text(feed.room.members.map(\.label).formatted(.list(type: .and)))
                .font(.headline).multilineTextAlignment(.center)
            Text(feed.room.inDesktop ? "Nothing said yet in Hermes Desktop."
                 : "Say something to all of them, or start with @ and a name to ask one. A bot that has nothing to add stays quiet.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    @ViewBuilder
    private func row(_ event: GroupEvent) -> some View {
        if event.kind == "message.user" {
            let said = AttachedFileNote.split(event.text)
            mine(said.text, paths: said.paths, id: "seq-\(event.seq)", waiting: false, when: event.createdAt, highlight: highlight(event.seq))
        } else if event.kind == "message.member" {
            let member = feed.room.member(event.actorID)
            // Its seq makes the reply's id: the same message keeps its row as the log is read again.
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", event.seq)) ?? UUID()
            // Copy, read aloud, share and select, as under a conversation's reply.
            MessageRow(message: Message(id: id, role: .assistant, text: event.text, createdAt: event.createdAt),
                       onReadAloud: { @MainActor @Sendable in readAloud(id, event.text, speaker: member?.profile) },
                       isReading: readingID == id && voiceSession.phase == .speaking, highlight: highlight(event.seq))
                .equatable()
                .environment(\.replySpeaker, member?.label ?? "A bot")
                .environment(\.replyFace, face(member))
        } else if let note = event.note(in: feed.room) {
            Text(note).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }

    /// A bot writes a reply now: the room's "talking" line gives way to it.
    private var someoneIsWriting: Bool { feed.drafts.contains { !$0.text.isEmpty && $0.finishedAt == nil } }

    /// A reply being written, drawn as the conversation draws its live reply, under its bot.
    private func writing(_ draft: GroupDraft) -> some View {
        let member = feed.room.member(draft.memberID)
        return MessageRow(message: Message(id: Self.rowID("draft-" + draft.id), role: .assistant, text: draft.text, createdAt: draft.began),
                          isLive: draft.finishedAt == nil, showActions: false)
            .equatable()
            .environment(\.replySpeaker, member?.label ?? "A bot")
            .environment(\.replyFace, face(member))
    }

    /// The person's message, as the conversation draws one (the theme's bubble, its text colour),
    /// with the files it named under it: by their paths on the server once it is in the room,
    /// tapped to open; by their names while it is on its way.
    /// `when` is fixed, so the row is the same row each pass and isn't drawn again (`.equatable()`):
    /// a message made with today's date never was.
    private func mine(_ text: String, paths: [String] = [], files: [String] = [], id: String, waiting: Bool,
                      when: Date, highlight: MessageRow.Highlight = .none) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !text.isEmpty {
                MessageRow(message: Message(id: Self.rowID(id), role: .user, text: text, createdAt: when), showActions: false, highlight: highlight)
                    .equatable()
            }
            if !paths.isEmpty || !files.isEmpty {
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(paths, id: \.self) { GroupFileChip(path: $0) }
                    ForEach(Array(files.enumerated()), id: \.offset) { _, name in
                        Label(name, systemImage: "arrow.up.circle").font(.footnote).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.quaternary, in: .capsule)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .opacity(waiting ? 0.6 : 1)
    }

    /// A row's message id, the same each time the log is read (a send's id is a UUID already).
    private static func rowID(_ key: String) -> UUID {
        if let uuid = UUID(uuidString: key) { return uuid }
        var hash: UInt64 = 1469598103934665603
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return UUID(uuidString: String(format: "00000000-0000-4000-8001-%012llx", hash & 0xFFFF_FFFF_FFFF)) ?? UUID()
    }

    private var talking: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(feed.state.waitsOnPerson ? "Waiting on you"
                 : feed.state.stopping ? "Stopping…"
                 : feed.state.blocked ? "Sorting out a reply that was cut off…"
                 : "The bots are talking…")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// A reply that stopped partway (Hermes restarted mid-reply, or couldn't reach the bot): it
    /// runs again only when asked to, since Hermes can't tell how far it got.
    private func retryCard(_ task: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(feed.member(forTask: task).map { "\($0.label)'s reply" } ?? "A reply") didn't finish", systemImage: "arrow.clockwise")
                .font(.subheadline.weight(.semibold))
            Text("It stopped partway, and Hermes can't tell how far it got. Run it again?")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Retry") { feed.retry(task) }
                .buttonStyle(.bordered)
                .font(.footnote)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 14))
    }

}

/// A few bots' faces overlapping, for a group chat: each bot's face and name.
struct FaceStack: View {
    var faces: [(face: BotFace, name: String)]
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: -size * 0.35) {
            ForEach(Array(faces.enumerated()), id: \.offset) { _, bot in
                BotAvatar(face: bot.face, name: bot.name, size: size)
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
                                BotAvatar(face: faces[bot.name] ?? BotFace(seed: bot.name), name: bot.label(mainName: mainName), size: 30)
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
