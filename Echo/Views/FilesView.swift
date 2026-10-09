import PhotosUI
import QuickLook
import SwiftUI

/// Settings → Files: the folders of the Hermes host, as the Dashboard's own file manager shows
/// them. Open a folder, look at a file or change a text one, bring files up from the phone, make
/// folders, delete. Each folder is its own page of the navigation stack.
struct FilesView: View {
    /// The folder shown; nil is where the server starts.
    let path: String?

    @State private var model: ServerFolderModel
    @AppStorage("files.showHidden") private var showHidden = false
    @State private var search = ""
    @State private var preview: URL?
    @State private var pickingFiles = false
    @State private var pickingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var namingFolder = false
    @State private var folderName = ""
    @State private var goingTo = false
    @State private var typedPath = ""
    @State private var jump: String?
    @State private var deleting: ServerFile?

    /// The server behind the screen: the Dashboard, or sample data (`-echo.demoFiles`).
    static var browser: any ServerFileBrowsing {
        #if DEBUG
        if DevHooks.demoFiles { return demo }
        #endif
        return HermesServeClient.shared
    }
    #if DEBUG
    private static let demo = DemoServerFiles()
    #endif

    init(path: String? = nil) {
        self.path = path
        _model = State(initialValue: ServerFolderModel(path: path, browser: Self.browser))
    }

    private var shown: [ServerFile] { model.folder?.shown(hidden: showHidden, matching: search) ?? [] }
    private var isRoot: Bool { path == nil }
    private var title: String { model.folder?.name ?? path.map(ServerFiles.name(of:)) ?? "Files" }

    var body: some View {
        List {
            if isRoot, model.folder?.lockedRoot == nil, search.isEmpty, model.phase == .loaded {
                Section("Places") {
                    NavigationLink { FilesView(path: Self.hermesHome) } label: {
                        Label("Hermes", systemImage: "brain")
                    }
                }
            }
            if let folder = model.folder {
                Section {
                    ForEach(shown) { file in row(file) }
                    if shown.isEmpty {
                        Text(emptyNote(folder)).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(folder.path).textCase(nil).font(.caption.monospaced()).textSelection(.enabled)
                } footer: {
                    if let working = model.working {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(working + "…")
                            ProgressView(value: model.progress)
                        }
                        .padding(.top, 4)
                    } else if !showHidden, folder.entries.contains(where: \.isHidden), search.isEmpty {
                        Text("Names that start with a dot are hidden.")
                    }
                }
            }
        }
        .overlay {
            switch model.phase {
            case .loading:
                ProgressView()
            case let .failed(why):
                ContentUnavailableView {
                    Label("Couldn't open this folder", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(why)
                } actions: {
                    Button("Try Again") { Task { await model.load() } }
                }
            case .loaded:
                EmptyView()
            }
        }
        .navigationTitle(isRoot && model.folder?.lockedRoot == nil ? "Files" : title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Names in this folder")
        .refreshable { await model.load() }
        .task {
            guard model.folder == nil else { return }
            if isRoot { ServerFiles.clearLocalCopies() }   // what was fetched to look at last time
            await model.load()
        }
        .toolbar { ToolbarItem(placement: .primaryAction) { menu } }
        .quickLookPreview($preview)
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            Task { await upload(picked: urls) }
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $photos, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .onChange(of: photos) { _, picked in
            guard !picked.isEmpty else { return }
            photos = []
            Task { await upload(photos: picked) }
        }
        .alert("New Folder", isPresented: $namingFolder) {
            TextField("Name", text: $folderName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await model.makeFolder(folderName) } }
        }
        .alert("Go to Folder", isPresented: $goingTo) {
            TextField("/path/on/the/server", text: $typedPath).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Go") {
                let typed = typedPath.trimmingCharacters(in: .whitespacesAndNewlines)
                if !typed.isEmpty { jump = typed }
            }
        } message: {
            Text("A path on the Hermes host. ~ is its user's home.")
        }
        .navigationDestination(item: $jump) { FilesView(path: $0) }
        .confirmationDialog(deleting.map(Self.deleteQuestion) ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { file in
            Button(file.isDirectory ? "Delete Folder and Its Contents" : "Delete File", role: .destructive) {
                Task { await model.delete(file) }
            }
        } message: { _ in
            Text("It is removed from the Hermes host. This can't be undone.")
        }
        .alert("Replace?", isPresented: Binding(get: { !model.wouldReplace.isEmpty }, set: { if !$0 { Task { await model.replace(false) } } })) {
            Button("Replace", role: .destructive) { Task { await model.replace(true) } }
            Button("Keep", role: .cancel) { Task { await model.replace(false) } }
        } message: {
            Text(Self.replaceQuestion(model.wouldReplace.map(\.name)))
        }
        .alert("Files", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ file: ServerFile) -> some View {
        Group {
            if file.isDirectory {
                NavigationLink { FilesView(path: file.path) } label: { label(file) }
            } else if file.opensAsText {
                NavigationLink { ServerTextFileView(file: file) } label: { label(file) }
            } else {
                Button { open(file) } label: { label(file) }
                    .disabled(model.isBusy)
            }
        }
        .contextMenu {
            if !file.isDirectory {
                Button("Download and Open", systemImage: "arrow.down.circle") { open(file) }
            }
            Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = file.path }
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = file }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = file }
        }
    }

    private func label(_ file: ServerFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.symbol)
                .foregroundStyle(file.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).foregroundStyle(Color.primary).lineLimit(2)
                let detail = file.detail()
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(Color.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var menu: some View {
        Menu {
            Section {
                Button("Upload Files…", systemImage: "arrow.up.doc") { pickingFiles = true }
                Button("Upload Photos…", systemImage: "photo.on.rectangle") { pickingPhotos = true }
                Button("New Folder…", systemImage: "folder.badge.plus") {
                    folderName = ""
                    namingFolder = true
                }
            }
            .disabled(model.folder == nil || model.isBusy)
            Section {
                Toggle("Show Hidden Files", systemImage: "eye", isOn: $showHidden)
                if model.folder?.lockedRoot == nil {
                    Button("Go to Folder…", systemImage: "arrow.turn.down.right") {
                        typedPath = ""
                        goingTo = true
                    }
                }
                if let folder = model.folder {
                    Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = folder.path }
                }
            }
        } label: {
            Label("Folder Actions", systemImage: "ellipsis.circle")
        }
    }

    // MARK: Doing things

    /// The Hermes home of the profile in use: `~/.hermes`, or the profile's own.
    static var hermesHome: String {
        (Settings.shared.profileFilePath("SOUL.md") as NSString).deletingLastPathComponent
    }

    private func emptyNote(_ folder: ServerFolder) -> String {
        if !search.isEmpty { return "Nothing here by that name." }
        return folder.entries.isEmpty ? "This folder is empty." : "Only hidden files here."
    }

    static func deleteQuestion(_ file: ServerFile) -> String {
        file.isDirectory ? "Delete the folder “\(file.name)” and everything in it?" : "Delete “\(file.name)”?"
    }

    static func replaceQuestion(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: "“\(names[0])” is already in this folder."
        case 2: "“\(names[0])” and “\(names[1])” are already in this folder."
        default: "“\(names[0])” and \(names.count - 1) more are already in this folder."
        }
    }

    private func open(_ file: ServerFile) {
        Task { if let copy = await model.fetch(file) { preview = copy } }
    }

    /// Files from the Files app: read while the system lets this app at them.
    private func upload(picked urls: [URL]) async {
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        await model.upload(urls.map { .init(local: $0, name: $0.lastPathComponent) })
    }

    /// Photos and videos are written out first: the server is sent files.
    private func upload(photos picked: [PhotosPickerItem]) async {
        var files: [ServerFolderModel.Outgoing] = []
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash)) + " " + Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)).replacingOccurrences(of: ":", with: ".")
        for (i, item) in picked.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                model.problem = "One of the photos couldn't be read."
                continue
            }
            let type = item.supportedContentTypes.first
            let kind = type?.conforms(to: .movie) == true ? "Video" : "Photo"
            let ending = type?.preferredFilenameExtension ?? "jpg"
            let name = picked.count > 1 ? "\(kind) \(stamp) \(i + 1).\(ending)" : "\(kind) \(stamp).\(ending)"
            guard let local = try? ServerFiles.localCopy(named: name), (try? data.write(to: local)) != nil else { continue }
            files.append(.init(local: local, name: name))
        }
        if !files.isEmpty { await model.upload(files) }
    }
}

/// A text file on the Hermes host: read, and where all of it was read and it is words, changed
/// and saved back.
struct ServerTextFileView: View {
    let file: ServerFile
    private let browser = FilesView.browser

    @State private var content = ""
    @State private var original: ServerText?
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var preview: URL?
    @State private var fetching = false

    private var canEdit: Bool { original?.canEdit == true }
    private var dirty: Bool { canEdit && content != original?.text }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $content)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 380)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(!canEdit)
            } header: {
                Text(file.path).textCase(nil).font(.caption.monospaced())
            } footer: {
                if let original, !original.canEdit {
                    Text(original.binary ? "This isn't text after all, so it can't be changed here. Download it to look at it."
                         : "Only the start is shown: the file is larger than Hermes reads for an editor. It can't be changed here, since saving would cut it short. Download it for all of it.")
                }
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save", action: save).disabled(saving || !dirty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Download and Open", systemImage: "arrow.down.circle", action: download).disabled(fetching)
            }
        }
        .overlay { if loading { ProgressView() } }
        .quickLookPreview($preview)
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        do {
            let text = try await browser.text(of: file)
            original = text
            content = text.text
        } catch {
            self.error = ServerFiles.explain(error)
        }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await browser.write(content, to: file)
                original = ServerText(text: content)
            } catch {
                self.error = ServerFiles.explain(error)
            }
        }
    }

    private func download() {
        fetching = true
        Task {
            defer { fetching = false }
            do { preview = try await browser.download(file, watch: nil) } catch { self.error = ServerFiles.explain(error) }
        }
    }
}
