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
    /// The mic inside the field: voice mode, one question at a time.
    let openVoice: () -> Void
    /// The round button beside the field when there's nothing to send: voice mode, listening at
    /// once, hands-free if Settings → Voice says so.
    let openHandsFree: () -> Void
    let openModelPicker: () -> Void

    @Environment(Conversation.self) private var conversation
    @Environment(\.theme) private var theme
    @State private var settings = Settings.shared

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
    @State private var attachmentError: String?

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
            if !pendingAttachments.isEmpty {
                AttachmentStrip(attachments: pendingAttachments) { id in
                    pendingAttachments.removeAll { $0.id == id }
                }
            }
            if let attachmentError {
                Text(attachmentError).font(.caption).foregroundStyle(.red)
            }
            composerRow
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
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
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoSelection, maxSelectionCount: 4, matching: .images)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls):
                for url in urls {
                    do { pendingAttachments.append(try Attachment.file(url: url)) }
                    catch { attachmentError = error.localizedDescription }
                }
            case let .failure(error):
                attachmentError = error.localizedDescription
            }
        }
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                       let att = Attachment.image(image) {
                        pendingAttachments.append(att)
                    }
                }
                photoSelection = []
            }
        }
    }

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
        .background(theme.surface ?? Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
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

    /// One rounded field (attach, the text, a mic) and one round button beside it whose job
    /// follows what you're doing: hands-free voice, send, or stop.
    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            HStack(alignment: .bottom, spacing: 2) {
                Menu {
                    Button("Photo Library", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
                    Button("Files", systemImage: "folder") { showFileImporter = true }
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
                TextField(conversation.canSteer ? "Steer the reply…" : "Ask \(settings.headerTitle)", text: $draft, axis: .vertical)
                    .lineLimit(1 ... 5)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 9)
                    .focused($focused)
                    .onSubmit(send)
                    .submitLabel(.return)
                if !hasDraft, !conversation.isStreaming {
                    Button { openVoice() } label: {
                        Image(systemName: "mic")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 38, height: 38)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Voice")
                    .accessibilityHint("Opens voice mode to ask one question")
                }
            }
            .padding(5)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                // Only trust the measurement while the draft is a single line.
                if !draft.contains("\n"), height < singleLineCap { buttonSize = height }
            }
            .background(theme.usesGlass ? AnyShapeStyle(.clear) : AnyShapeStyle(theme.surface ?? Color(.secondarySystemBackground)),
                        in: .rect(cornerRadius: buttonSize / 2))
            .glassEffect(theme.usesGlass ? .regular : .identity, in: .rect(cornerRadius: buttonSize / 2))
            if conversation.isStreaming {
                if hasDraft {
                    // Typing during a reply: steer this answer, or queue the next question behind it.
                    if conversation.canSteer, !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                        ComposerButton(symbol: "arrow.turn.down.right", label: "Steer this reply", tint: .orange, size: buttonSize) {
                            steer()
                        }
                    }
                    ComposerButton(symbol: "text.line.last.and.arrowtriangle.forward", label: "Send after this reply", tint: .accentColor, size: buttonSize) {
                        send()
                    }
                } else {
                    ComposerButton(symbol: "stop.fill", label: "Stop", tint: .red, size: buttonSize) {
                        conversation.cancel()
                    }
                }
            } else if hasDraft {
                ComposerButton(symbol: "arrow.up", label: "Send", tint: .accentColor, size: buttonSize) {
                    send()
                }
            } else {
                ComposerButton(symbol: "waveform", label: settings.handsFreeByDefault ? "Talk hands-free" : "Talk", tint: .accentColor, size: buttonSize) {
                    openHandsFree()
                }
                .accessibilityHint(settings.handsFreeByDefault ? "Opens voice mode and keeps listening after each reply"
                                                              : "Opens voice mode and starts listening")
            }
        }
        .labelStyle(.iconOnly)
    }

    private func steer() {
        let text = draft
        draft = ""
        conversation.steer(text)
    }

    private func send() {
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
