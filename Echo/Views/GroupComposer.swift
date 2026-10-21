import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The field under a group chat: the conversation's own parts (Add, with Files, the photo library
/// and the camera; the pictures and files waiting to go; dictation; Send and Stop), and the bots
/// offered while an @tag is typed. A room takes text alone: what is attached goes to the server
/// and the message names it (`GroupFeed.send`).
struct GroupComposer: View {
    let feed: GroupFeed
    var focused: FocusState<Bool>.Binding
    let face: (GroupMember?) -> BotFace
    /// Talk with the group by voice (`GroupVoice`), from the empty field.
    var talk: (() -> Void)?
    @Environment(\.theme) private var theme
    @State private var draft = ""
    @State private var attachments: [Attachment] = []
    @State private var problem: String?
    @State private var dictation = Dictation()
    /// The draft as it stood when dictation began; what is heard is added to this.
    @State private var dictationBase: String?
    @State private var showPhotoPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var showCamera = false

    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    var body: some View {
        VStack(spacing: 8) {
            let suggestions = tagSuggestions
            if !suggestions.isEmpty { tags(suggestions) }
            if !attachments.isEmpty {
                AttachmentStrip(attachments: attachments) { id in attachments.removeAll { $0.id == id } }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 10) {
                field
                if feed.discussing || feed.state.working, !hasDraft {
                    ComposerButton(symbol: "stop.fill", label: "Stop", tint: .red, size: 44) { feed.stop() }
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else if !hasDraft, let talk {
                    // As under a conversation: an empty field offers to talk instead.
                    ComposerButton(symbol: "waveform", label: "Talk", tint: .accentColor, size: 44, waveform: true) { talk() }
                        .accessibilityHint("Talk with the group: what you say goes to the bots, and their replies are read to you")
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    ComposerButton(symbol: "arrow.up", label: "Send", tint: .accentColor, size: 44) { send() }
                        .disabled(!hasDraft)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.3, extraBounce: 0.15), value: feed.discussing || feed.state.working)
            .animation(.snappy(duration: 0.3, extraBounce: 0.15), value: hasDraft)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .dictating(dictation, base: $dictationBase, draft: $draft, problem: $problem)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let image, let att = Attachment.image(image) { attachments.append(att) }
                showCamera = false
            }
            .ignoresSafeArea()
        }
        // Pictures only: a bot can look at a picture on the server, not watch a video.
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoSelection, maxSelectionCount: 4, matching: .images)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls):
                for url in urls {
                    do { attachments.append(try Attachment.file(url: url)) } catch { problem = error.localizedDescription }
                }
            case let .failure(error):
                problem = error.localizedDescription
            }
        }
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data), let att = Attachment.image(image) {
                        attachments.append(att)
                    }
                }
                photoSelection = []
            }
        }
    }

    /// The conversation's field: Add, the text, and the microphone, on glass or the theme's surface.
    private var field: some View {
        HStack(alignment: .bottom, spacing: 2) {
            Menu {
                Button("Files", systemImage: "folder") { showFileImporter = true }
                Button("Photo Library", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
                if CameraPicker.isAvailable {
                    Button("Camera", systemImage: "camera") { showCamera = true }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .contentShape(.circle)
            }
            .accessibilityLabel("Add")
            .accessibilityHint("Add a photo or file to your message. It goes to your server, where the bots can open it.")
            TextField(dictation.isActive ? "Listening…" : "Message the group", text: $draft, axis: .vertical)
                .font(theme.userFont)
                .lineLimit(1 ... 6)
                .textFieldStyle(.plain)
                .padding(.vertical, 9)
                .focused(focused)
            DictateButton(dictation: dictation, toggle: toggleDictation)
        }
        .padding(.horizontal, 4)
        .background(theme.usesGlass ? AnyShapeStyle(.clear) : AnyShapeStyle(theme.surfaceColor), in: .rect(cornerRadius: 22))
        .glassEffect(theme.usesGlass ? .regular : .identity, in: .rect(cornerRadius: 22))
    }

    private func send() {
        stopDictating()
        guard hasDraft else { return }
        problem = nil
        feed.send(draft, attachments: attachments)
        draft = ""
        attachments = []
    }

    private func toggleDictation() {
        if dictation.isActive {
            dictation.stop()
        } else {
            problem = nil
            dictationBase = draft
            dictation.start()
        }
    }

    /// Ends dictation where it stands; what it heard so far is in the draft already.
    private func stopDictating() {
        dictationBase = nil
        dictation.cancel()
    }

    /// The other bots a tag being typed could be.
    private var tagSuggestions: [GroupMember] {
        guard let typed = BotMentions.typing(in: draft)?.lowercased() else { return [] }
        return feed.room.members.filter {
            typed.isEmpty || $0.handle.lowercased().hasPrefix(typed) || $0.label.lowercased().hasPrefix(typed)
        }
    }

    private func tags(_ suggestions: [GroupMember]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions) { member in
                Button {
                    if let typed = BotMentions.typing(in: draft) { draft = String(draft.dropLast(typed.count + 1)) + "@" + member.handle + " " }
                    focused.wrappedValue = true
                } label: {
                    HStack(spacing: 10) {
                        BotAvatar(face: face(member), name: member.label, size: 22)
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
}

/// A file a group chat message names (`AttachedFileNote`): its name, and on a tap it is fetched
/// from the server and shown.
struct GroupFileChip: View {
    let path: String
    @State private var opened: Attachment?
    @State private var fetching = false
    @State private var failed = false

    private var name: String { ServerFiles.sentName(of: path) }
    private var isPicture: Bool { UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .image) == true }

    var body: some View {
        Button { open() } label: {
            HStack(spacing: 6) {
                if fetching { ProgressView().controlSize(.mini) } else {
                    Image(systemName: failed ? "exclamationmark.triangle" : isPicture ? "photo" : "doc")
                }
                Text(name).lineLimit(1).truncationMode(.middle)
            }
            .font(.footnote)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.quaternary, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityHint(failed ? "Couldn't be fetched from the server. Tap to try again." : "Opens it, from your server")
        .sheet(item: $opened) { DocumentPreview(attachment: $0).ignoresSafeArea() }
    }

    private func open() {
        guard !fetching else { return }
        fetching = true
        failed = false
        Task {
            defer { fetching = false }
            do {
                let local = try await HermesServeClient.shared.download(ServerFile(name: name, path: path, isDirectory: false), watch: nil)
                let data = try Data(contentsOf: local)
                try? FileManager.default.removeItem(at: local)
                let type = UTType(filenameExtension: (name as NSString).pathExtension)
                opened = Attachment(kind: isPicture ? .image : .other, filename: name, mimeType: type?.preferredMIMEType ?? "application/octet-stream", data: data)
            } catch {
                failed = true
            }
        }
    }
}
