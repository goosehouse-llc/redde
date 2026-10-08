import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The message composer: draft field, attachment strip and pickers, slash-command menu,
/// steer/queue/stop buttons, and edit-and-resend banner. ContentView owns only the state
/// that outside features write into (share-extension hand-off, edit callbacks, ⌘L focus);
/// everything else lives here.
struct ComposerView: View {
    @Binding var draft: String
    @Binding var pendingAttachments: [Attachment]
    /// "Edit & resend": the message being replaced; sending truncates the transcript from it.
    @Binding var editing: Message?
    @FocusState.Binding var focused: Bool
    /// The round button beside the field when there's nothing to send: voice mode, listening at
    /// once, hands-free if Settings → Voice says so.
    let openHandsFree: () -> Void
    let openModelPicker: () -> Void

    @Environment(Conversation.self) private var conversation
    @Environment(VoiceSession.self) private var voiceSession
    @Environment(\.theme) private var theme
    @State private var settings = Settings.shared
    /// The microphone in the field: speech into the draft, nothing sent.
    @State private var dictation = Dictation()
    /// The draft as it stood when dictation began; what is heard is added to this.
    @State private var dictationBase: String?
    /// The draft on a page of its own.
    @State private var showEditor = false
    /// A video being made small enough to send.
    @State private var preparingVideo = false
    /// Shift-Return on a keyboard while Return is set to send: this one line break is meant.
    @State private var lineBreakMeant = false

    /// Slash-command menu (hermes serve): what the gateway offers for the current "/…" draft.
    @State private var slashItems: [HermesServeClient.SlashCompletion] = []
    @State private var slashReplaceFrom = 1
    /// The field's height on one line, measured; the round buttons beside it match it so they
    /// sit level at any text size.
    @State private var buttonSize: CGFloat = 48
    /// A one-line field taller than this is a measuring glitch; ignore it.
    @ScaledMetric(relativeTo: .body) private var singleLineCap: CGFloat = 72
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var attachmentError: String?
    /// What the draft mentions that can be attached (`ComposerContext`), minus what was
    /// dismissed or already attached for this draft.
    @State private var contextSuggestions: [ComposerContext.Suggestion] = []
    @State private var dismissedContext: Set<String> = []
    @State private var contextBusy: String?
    /// Attachments that came from a chip: they stay in the field as filled chips, not in the
    /// strip above it.
    @State private var contextAttached: Set<UUID> = []

    private var stripAttachments: [Attachment] { pendingAttachments.filter { !contextAttached.contains($0.id) } }
    private var attachedContext: [Attachment] { pendingAttachments.filter { contextAttached.contains($0.id) } }

    /// The "/" menu is a hermes serve feature; other backends get the text as typed.
    private var slashMenuActive: Bool {
        settings.transport == .hermesServe && draft.hasPrefix("/") && !draft.contains("\n") && !conversation.isStreaming
    }

    var body: some View {
        VStack(spacing: 8) {
            if slashMenuActive, !slashItems.isEmpty { slashMenu }
            if let editing {
                HStack(spacing: 8) {
                    Image(systemName: "pencil").foregroundStyle(.secondary)
                    Text("Editing. Sending replaces this message and everything after it.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Cancel editing", systemImage: "xmark.circle.fill") { cancelEditing() }
                        .labelStyle(.iconOnly).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .accessibilityElement(children: .combine)
                .id(editing.id)
            }
            if !stripAttachments.isEmpty {
                AttachmentStrip(attachments: stripAttachments) { id in
                    pendingAttachments.removeAll { $0.id == id }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if preparingVideo {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Preparing the video…")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if let attachmentError {
                Text(attachmentError).font(.caption).foregroundStyle(.red)
            }
            composerRow
        }
        .onChange(of: draft) { old, new in
            refreshContext(new)
            returnTyped(from: old, to: new)
        }
        // A picture on the clipboard pastes into the field as an attachment (`ComposerPaste`).
        .onChange(of: focused, initial: true) { _, isFocused in
            ComposerPaste.shared.deliver = !isFocused ? nil : { attachments, problems in
                pendingAttachments += attachments
                if let problem = problems.first { attachmentError = problem }
            }
            guard isFocused else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(80))   // the field is first responder a moment after the focus says so
                ComposerPaste.shared.teachFocusedField()
            }
        }
        .onChange(of: dictation.heard) { _, heard in
            if let base = dictationBase { draft = Dictation.joined(base, heard) }
        }
        .onChange(of: dictation.phase) { _, phase in
            guard phase == .idle, let base = dictationBase else { return }
            draft = Dictation.joined(base, dictation.heard)
            dictationBase = nil
        }
        .onChange(of: dictation.problem) { _, problem in
            if let problem { attachmentError = problem }
        }
        .onDisappear { stopDictating() }
        .sensoryFeedback(.selection, trigger: dictation.isActive)
        .sheet(isPresented: $showEditor) {
            ComposerEditor(draft: $draft, sendLabel: conversation.isStreaming ? "Send after this reply" : "Send", send: send)
                .tint(theme.accent)
        }
        .onChange(of: pendingAttachments.count) {
            contextAttached = contextAttached.filter { id in pendingAttachments.contains { $0.id == id } }
            refreshContext(draft)
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
        .animation(.snappy(duration: 0.3), value: pendingAttachments.count)
        .animation(.snappy(duration: 0.3), value: editing?.id)
        .animation(.snappy(duration: 0.3), value: contextSuggestions)
        .background {
            // ⌘↩ sends from anywhere; lives here because send() does.
            Button("Send") { send() }.keyboardShortcut(.return, modifiers: .command)
                .disabled(conversation.isStreaming || (draft.trimmingCharacters(in: .whitespaces).isEmpty && pendingAttachments.isEmpty))
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
        .task(id: slashMenuActive ? draft : "") {
            guard slashMenuActive else { slashItems = []; return }
            try? await Task.sleep(for: .milliseconds(120))   // let typing settle
            guard !Task.isCancelled, let (items, from) = try? await HermesServeClient.shared.completeSlash(draft) else { return }
            slashItems = Array(items.prefix(8))
            slashReplaceFrom = from
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let image, let att = Attachment.image(image) { pendingAttachments.append(att) }
                showCamera = false
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoSelection, maxSelectionCount: 4, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls):
                for url in urls {
                    if Attachment.isVideo(url) {
                        attachVideo(at: url, named: url.lastPathComponent)
                    } else {
                        do { pendingAttachments.append(try Attachment.file(url: url)) }
                        catch { attachmentError = error.localizedDescription }
                    }
                }
            case let .failure(error):
                attachmentError = error.localizedDescription
            }
        }
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                        guard let picked = try? await item.loadTransferable(type: PickedVideo.self) else {
                            attachmentError = "That video couldn't be read."
                            continue
                        }
                        await attachVideo(picked.url, named: "video." + picked.url.pathExtension, removing: true)
                    } else if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                              let att = Attachment.image(image) {
                        pendingAttachments.append(att)
                    }
                }
                photoSelection = []
            }
        }
    }

    /// A video goes in as it is when it fits, and smaller when it doesn't; that can take a while.
    private func attachVideo(_ url: URL, named name: String, removing: Bool = false) async {
        preparingVideo = true
        defer { preparingVideo = false }
        do {
            pendingAttachments.append(try await Attachment.video(fileURL: url, filename: name))
        } catch {
            attachmentError = error.localizedDescription
        }
        if removing { try? FileManager.default.removeItem(at: url) }
    }

    private func attachVideo(at url: URL, named name: String) {
        Task { await attachVideo(url, named: name) }
    }

    // MARK: Return, and the keyboard

    /// A draft that grew by exactly one line break: Return was pressed. (A paste or a deletion
    /// changes it some other way.)
    nonisolated static func isReturn(from old: String, to new: String) -> Bool {
        guard new.utf16.count == old.utf16.count + 1 else { return false }
        let shared = new.commonPrefix(with: old)
        let rest = new.dropFirst(shared.count)
        return rest.first == "\n" && rest.dropFirst() == old.dropFirst(shared.count)
    }

    /// Settings → Return key sends: the line break Return just typed comes out again and the
    /// message goes, unless it was Shift-Return or there is nothing to send yet.
    private func returnTyped(from old: String, to new: String) {
        guard settings.returnSends, Self.isReturn(from: old, to: new) else { return }
        if lineBreakMeant {
            lineBreakMeant = false
            return
        }
        draft = old
        if hasDraft { send() }
    }

    // MARK: Dictation

    private func toggleDictation() {
        if dictation.isActive {
            dictation.stop()
        } else {
            attachmentError = nil
            dictationBase = draft
            dictation.start()
        }
    }

    /// Ends dictation where it stands; what it heard so far is in the draft already.
    private func stopDictating() {
        dictationBase = nil
        dictation.cancel()
    }

    /// Long enough that a page of its own helps.
    private var draftIsLong: Bool { draft.count > 160 || draft.filter { $0 == "\n" }.count >= 3 }

    /// Commands, skills and bundles the gateway offers for the draft. Tap one to fill it in;
    /// commands that take an argument end with a space so you keep typing.
    private var slashMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(slashItems) { item in
                Button { applySlash(item) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: item.kind == "skill" ? "sparkles" : "terminal")
                            .font(.caption).foregroundStyle(theme.accent).frame(width: 16)
                        Text(item.display.trimmingCharacters(in: .whitespaces))
                            .font(.callout.monospaced().weight(.medium))
                            .lineLimit(1)
                        if !item.meta.isEmpty {
                            Text(item.meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if item.id != slashItems.last?.id { Divider().padding(.leading, 38) }
            }
        }
        .background(theme.surfaceColor, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityLabel("Command suggestions")
    }

    private func applySlash(_ item: HermesServeClient.SlashCompletion) {
        let keep = String(draft.prefix(max(0, min(slashReplaceFrom, draft.count))))
        draft = keep + item.text
        focused = true
    }

    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty || !pendingAttachments.isEmpty }

    // MARK: Context chips

    /// A day or a file the draft mentions, one tap from being attached.
    private var contextChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Attached from a chip: filled, with its × to take it off again.
                ForEach(attachedContext) { att in
                    HStack(spacing: 6) {
                        Image(systemName: att.filename.hasPrefix("calendar-") ? "calendar" : "doc")
                        Text(att.filename.hasPrefix("calendar-") ? "Calendar attached" : att.filename).lineLimit(1)
                        Button {
                            pendingAttachments.removeAll { $0.id == att.id }
                        } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(att.filename)")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.userBubbleText)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(theme.accent, in: .capsule)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                ForEach(contextSuggestions) { suggestion in
                    HStack(spacing: 6) {
                        Button {
                            attachContext(suggestion)
                        } label: {
                            HStack(spacing: 6) {
                                if contextBusy == suggestion.id {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: suggestion.symbol)
                                }
                                Text(suggestion.title).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(contextBusy != nil)
                        Button {
                            dismissedContext.insert(suggestion.id)
                            refreshContext(draft)
                        } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(theme.accent.opacity(0.14), in: .capsule)
                    .overlay(Capsule().strokeBorder(theme.accent.opacity(0.35)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.bottom, 6)
        }
        .scrollClipDisabled()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chipRowHeight = $0 }
        .animation(.snappy(duration: 0.3), value: attachedContext)
    }

    private func refreshContext(_ draft: String) {
        let attachedNames = Set(pendingAttachments.map(\.filename))
        let recent = ComposerContext.recentFiles(current: conversation.messages, store: conversation.storeForContext)
        contextSuggestions = ComposerContext.suggestions(for: draft, recentFiles: recent).filter { suggestion in
            guard !dismissedContext.contains(suggestion.id) else { return false }
            switch suggestion {
            case let .calendar(day):
                return !attachedNames.contains("calendar-" + day.formatted(.iso8601.year().month().day()) + ".txt")
            case let .file(att):
                return !attachedNames.contains(att.filename)
            }
        }
        if draft.isEmpty { dismissedContext = [] }
    }

    private func attachContext(_ suggestion: ComposerContext.Suggestion) {
        switch suggestion {
        case let .file(att):
            contextAttached.insert(att.id)
            pendingAttachments.append(att)
        case let .calendar(day):
            contextBusy = suggestion.id
            Task {
                if let att = await ComposerContext.calendarAttachment(for: day) {
                    contextAttached.insert(att.id)
                    pendingAttachments.append(att)
                } else {
                    attachmentError = "Redde has no access to your calendar. Allow it in the iPhone's Settings → Apps → Redde."
                    dismissedContext.insert(suggestion.id)
                }
                contextBusy = nil
                refreshContext(draft)
            }
        }
    }

    /// One rounded field (attach and the text) and one round button beside it whose job
    /// follows what you're doing: hands-free voice, send, or stop.
    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 2) {
                Menu {
                    Button("Files", systemImage: "folder") { showFileImporter = true }
                    Button("Photo Library", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
                    if CameraPicker.isAvailable {
                        Button("Camera", systemImage: "camera") { showCamera = true }
                    }
                    if settings.transport == .hermesServe {
                        Divider()
                        Button("Commands", systemImage: "terminal") { draft = "/"; focused = true }
                            .disabled(conversation.isStreaming)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, height: 38)
                        .contentShape(.circle)
                }
                .accessibilityLabel("Add")
                .accessibilityHint("Add a photo or file to your message")
                TextField(dictation.isActive ? "Listening…" : conversation.canSteer ? "Steer the reply…" : "Ask \(settings.headerTitle)",
                          text: $draft, axis: .vertical)
                    .lineLimit(1 ... 5)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 9)
                    .focused($focused)
                    .onSubmit(send)
                    .submitLabel(settings.returnSends ? .send : .return)
                    // A keyboard's Return, with Return set to send: sends, and Shift-Return is the line break.
                    .onKeyPress(.return, phases: .down) { press in
                        guard settings.returnSends else { return .ignored }
                        if press.modifiers.contains(.shift) {
                            lineBreakMeant = true
                            return .ignored
                        }
                        if hasDraft { send() }
                        return .handled
                    }
                if draftIsLong {
                    Button("Open the editor", systemImage: "arrow.up.left.and.arrow.down.right") { showEditor = true }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 38)
                        .contentShape(.rect)
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows the message on a page of its own")
                        .transition(.opacity)
                }
                Button(dictation.isActive ? "Stop dictating" : "Dictate", systemImage: dictation.isActive ? "waveform" : "mic") {
                    toggleDictation()
                }
                .font(.body.weight(.medium))
                .symbolEffect(.variableColor.iterative, isActive: dictation.phase == .listening)
                .foregroundStyle(dictation.isActive ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: 34, height: 38)
                .contentShape(.rect)
                .buttonStyle(.plain)
                .disabled(voiceSession.mightBeBusy)
                .accessibilityHint(dictation.isActive ? "Ends dictation; what was said stays in the message" : "Speak your message; it is written here, not sent")
            }
            .animation(.easeOut(duration: 0.2), value: draftIsLong)
            .onGeometryChange(for: CGFloat.self) { $0.size.height + 10 } action: { height in
                // Only trust the measurement while the draft is a single line.
                if !draft.contains("\n"), height < singleLineCap { buttonSize = height }
            }
            // What the draft mentions, one tap from attached: inside the field, under the text.
            if !contextSuggestions.isEmpty || !attachedContext.isEmpty { contextChips }
            }
            .padding(5)
            .background(theme.usesGlass ? AnyShapeStyle(.clear) : AnyShapeStyle(theme.surfaceColor),
                        in: .rect(cornerRadius: buttonSize / 2))
            .glassEffect(theme.usesGlass ? .regular : .identity, in: .rect(cornerRadius: buttonSize / 2))
            // A faint ring in the accent while there is something to send.
            .overlay {
                RoundedRectangle(cornerRadius: buttonSize / 2)
                    .strokeBorder(theme.accent.opacity(focused && hasDraft ? 0.45 : 0), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.25), value: focused && hasDraft)
            trailingButtons
                .padding(.bottom, contextSuggestions.isEmpty && attachedContext.isEmpty ? 0 : chipRowHeight)
        }
        .labelStyle(.iconOnly)
    }

    /// The chip row's height, so the buttons beside the field stay level with the text line.
    @State private var chipRowHeight: CGFloat = 0

    /// Which buttons sit beside the field; the row animates between them.
    private var trailingState: String {
        if conversation.isStreaming {
            guard hasDraft else { return "stop" }
            return conversation.canSteer && !draft.trimmingCharacters(in: .whitespaces).isEmpty ? "steer+queue" : "queue"
        }
        return hasDraft ? "send" : "talk"
    }

    /// Each button springs in and the one it replaces shrinks away, instead of a hard cut.
    private var trailingButtons: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if conversation.isStreaming {
                if hasDraft {
                    // Typing during a reply: steer this answer, or queue the next question behind it.
                    if conversation.canSteer, !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                        ComposerButton(symbol: "arrow.turn.down.right", label: "Steer this reply", tint: .orange, size: buttonSize) {
                            steer()
                        }
                        .transition(Self.buttonSwap)
                    }
                    ComposerButton(symbol: "text.line.last.and.arrowtriangle.forward", label: "Send after this reply", tint: .accentColor, size: buttonSize) {
                        send()
                    }
                    .transition(Self.buttonSwap)
                } else {
                    ComposerButton(symbol: "stop.fill", label: "Stop", tint: .red, size: buttonSize) {
                        conversation.cancel()
                    }
                    .transition(Self.buttonSwap)
                }
            } else if hasDraft {
                ComposerButton(symbol: "arrow.up", label: "Send", tint: .accentColor, size: buttonSize) {
                    send()
                }
                .transition(Self.buttonSwap)
            } else {
                ComposerButton(symbol: "waveform", label: settings.handsFreeByDefault ? "Talk hands-free" : "Talk", tint: .accentColor, size: buttonSize, waveform: true) {
                    openHandsFree()
                }
                .accessibilityHint(settings.handsFreeByDefault ? "Opens voice mode and keeps listening after each reply"
                                                              : "Opens voice mode and starts listening")
                .transition(Self.buttonSwap)
            }
        }
        .animation(.snappy(duration: 0.3, extraBounce: 0.15), value: trailingState)
    }

    private static let buttonSwap: AnyTransition = .scale(scale: 0.4).combined(with: .opacity)

    private func steer() {
        let text = draft
        draft = ""
        conversation.steer(text)
    }

    private func send() {
        stopDictating()
        guard hasDraft else { return }   // Return, set to send, on an empty field
        // Bare /model opens the picker; with an argument it stays a serve slash command.
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/model" {
            draft = ""
            openModelPicker()
            return
        }
        let text = draft
        let attachments = pendingAttachments
        draft = ""
        pendingAttachments = []
        attachmentError = nil
        if let editing {
            self.editing = nil
            Task { await conversation.resend(replacing: editing.id, text: text, attachments: attachments) }
        } else {
            conversation.send(text, attachments: attachments)
            SiriHooks.donateSend(text)
        }
    }

    private func cancelEditing() {
        editing = nil
        draft = ""
        pendingAttachments = []
    }
}
