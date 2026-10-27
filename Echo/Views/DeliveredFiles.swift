import SwiftUI
import UniformTypeIdentifiers

/// A file a reply names that isn't in the chat itself: it couldn't be fetched as the reply ended,
/// there was no Dashboard login to fetch it with, or it was too big to bring along (16 MB). Its
/// name, and on a tap it is fetched and opened, or it says why it can't be. A path in a reply
/// used to stay there as text (a Reddit report, 2026-10-21).
struct DeliveredFileChip: View {
    let file: ServeMedia.Candidate
    let source: FileSource?
    @State private var opened: OpenedFile?
    @State private var fetching = false
    @State private var problem: String?

    private var type: UTType? { UTType(filenameExtension: (file.filename as NSString).pathExtension) }

    private var symbol: String {
        guard let type else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .html) { return "globe" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        return "doc.text"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open() } label: {
                HStack(spacing: 6) {
                    if fetching { ProgressView().controlSize(.mini) } else {
                        Image(systemName: problem == nil ? symbol : "exclamationmark.triangle")
                    }
                    Text(file.filename).lineLimit(1).truncationMode(.middle)
                }
                .chatFont(.footnote)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary, in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(file.filename)
            .accessibilityHint(problem ?? String(localized: "Opens it, from your server"))
            if let problem {
                Text(problem).chatFont(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $opened) { FileViewer(file: $0) }
    }

    private func open() {
        guard !fetching else { return }
        fetching = true
        problem = nil
        Task {
            defer { fetching = false }
            switch await Self.fetch(file.path, in: source) {
            case .success(let url): opened = OpenedFile(url: url)
            case .failure(let why): problem = why.text
            }
        }
    }

    /// Why a file a reply names can't be opened, in words.
    struct Problem: Error { let text: String }

    /// Fetches a file a reply names through the Dashboard, on either connection: its copy on this
    /// phone, or why there isn't one.
    static func fetch(_ path: String, in source: FileSource?) async -> Result<URL, Problem> {
        let dashboard = HermesServeClient.shared
        guard await dashboard.canUse() else {
            return .failure(Problem(text: String(localized: "Files your agent sends come through the Hermes Dashboard. Add its login in Settings → Connection details.")))
        }
        do {
            return .success(try await dashboard.downloadDelivered(path: path, in: source))
        } catch TransportError.http(let status, _) where status == 404 {
            let relative = !path.hasPrefix("/") && !path.hasPrefix("~")
            return .failure(Problem(text: relative && source?.sessionID == nil
                ? String(localized: "It isn't on the server where the reply says, or the chat isn't on the server yet.")
                : String(localized: "It isn't on the server where the reply says.")))
        } catch TransportError.http(let status, _) where status == 403 {
            return .failure(Problem(text: String(localized: "The server won't share this file.")))
        } catch {
            return .failure(Problem(text: String(localized: "Couldn't fetch it: \(error.localizedDescription)")))
        }
    }
}

/// A reply's file paths open their files (`MarkdownView.linkPaths` makes them links): a tap
/// fetches the file through the Dashboard and opens it, or says under the reply why it can't.
struct OpensServerPaths: ViewModifier {
    let source: FileSource?
    @State private var opened: OpenedFile?
    /// The file being fetched, or the last one that couldn't be, and why.
    @State private var fetching: String?
    @State private var problem: (name: String, text: String)?

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content.environment(\.openURL, OpenURLAction { url in
                guard let path = ServeMedia.linkedPath(url) else { return .systemAction }
                open(path)
                return .handled
            })
            if let fetching {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Fetching \(fetching)…")
                }
                .chatFont(.caption).foregroundStyle(.secondary)
            } else if let problem {
                Label("\(problem.name): \(problem.text)", systemImage: "exclamationmark.triangle")
                    .chatFont(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $opened) { FileViewer(file: $0) }
    }

    private func open(_ path: String) {
        guard fetching == nil else { return }
        let name = String(path.split(separator: "/").last ?? Substring(path))
        fetching = name
        problem = nil
        Task {
            defer { fetching = nil }
            switch await DeliveredFileChip.fetch(path, in: source) {
            case .success(let url): opened = OpenedFile(url: url)
            case .failure(let why): problem = (name, why.text)
            }
        }
    }
}

/// A file on this phone to open: a Markdown one as it reads, anything else in QuickLook.
struct OpenedFile: Identifiable {
    let url: URL
    var id: URL { url }
    var isMarkdown: Bool { ["md", "markdown"].contains(url.pathExtension.lowercased()) }
}

/// Opens a file: a Markdown one as it reads (QuickLook shows its markup), anything else in
/// QuickLook.
struct FileViewer: View {
    let file: OpenedFile

    init(file: OpenedFile) { self.file = file }

    /// An attachment: its bytes go to a temporary file first.
    init(attachment: Attachment) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "previews")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: attachment.filename)
        try? attachment.data.write(to: url)
        file = OpenedFile(url: url)
    }

    var body: some View {
        if file.isMarkdown, let text = try? String(contentsOf: file.url, encoding: .utf8) {
            MarkdownDocument(name: file.url.lastPathComponent, text: text, url: file.url)
        } else {
            DocumentPreview(url: file.url).ignoresSafeArea()
        }
    }

    /// Whether an attachment opens as Markdown.
    static func isMarkdown(_ attachment: Attachment) -> Bool {
        ["md", "markdown"].contains((attachment.filename as NSString).pathExtension.lowercased()) || attachment.mimeType == "text/markdown"
    }
}

/// A Markdown file shown as it reads, the way replies are: with Done, and Share for the file.
struct MarkdownDocument: View {
    let name: String
    let text: String
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                MarkdownView(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { ShareLink(item: url) }
            }
        }
    }
}
