import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Hosts the SwiftUI share sheet. Collects the shared items, lets the user add a note, writes
/// everything to the App Group inbox, then hands off to Echo.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let root = ShareView(
            items: extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? [],
            send: { [weak self] payload in self?.finish(with: payload) },
            cancel: { [weak self] in self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled)) })
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    /// Writes the inbox and closes. Echo picks the items up the next time it comes to the
    /// foreground (extensions may not launch their host app).
    private func finish(with payload: ShareInbox.Payload) {
        do { try ShareInbox.write(payload) } catch { print("[EchoShare] inbox write failed: \(error)") }
        extensionContext?.completeRequest(returningItems: nil)
    }
}

struct ShareView: View {
    let items: [NSExtensionItem]
    let send: (ShareInbox.Payload) -> Void
    let cancel: () -> Void

    @State private var note = ""
    @State private var text = ""
    @State private var urls: [String] = []
    @State private var attachments: [Attachment] = []
    /// Row thumbnails, made once per image; the body re-runs on every keystroke in the note.
    @State private var thumbs: [UUID: UIImage] = [:]
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ask Redde about this…", text: $note, axis: .vertical)
                        .lineLimit(2 ... 6)
                } footer: {
                    Text("Optional. Everything below lands in Redde's composer the next time you open it; nothing is sent until you tap send there.")
                }
                Section("Sharing") {
                    if loading { ProgressView("Reading shared items…") }
                    if !text.isEmpty { Text(text).lineLimit(4).font(.footnote) }
                    ForEach(urls, id: \.self) { Label($0, systemImage: "link").font(.footnote).lineLimit(2) }
                    ForEach(attachments) { att in
                        if let image = thumbs[att.id] {
                            HStack {
                                Image(uiImage: image).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 8))
                                Text(att.filename).font(.footnote)
                            }
                        } else {
                            Label("\(att.filename) · \(att.sizeLabel)", systemImage: att.kind == .pdf ? "doc.richtext" : "doc.text").font(.footnote)
                        }
                    }
                    if !loading, text.isEmpty, urls.isEmpty, attachments.isEmpty {
                        Text("Nothing Redde can use in this share.").foregroundStyle(.secondary).font(.footnote)
                    }
                }
            }
            .navigationTitle("Send to Redde")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save for Redde") {
                        send(ShareInbox.Payload(note: note.trimmingCharacters(in: .whitespacesAndNewlines), text: text, urls: urls, attachments: attachments, createdAt: .now))
                    }
                    .disabled(loading || (text.isEmpty && urls.isEmpty && attachments.isEmpty && note.isEmpty))
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    if url.isFileURL { addFile(url) } else { urls.append(url.absoluteString) }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let att = await provider.loadImageAttachment(filename: provider.suggestedName ?? "photo.jpg") { add(att) }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                          let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                    addFile(url)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let shared = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    text = text.isEmpty ? shared : text + "\n" + shared
                }
            }
        }
        loading = false
    }

    private func addFile(_ url: URL) {
        if let att = try? Attachment.file(url: url) { add(att) }
    }

    private func add(_ att: Attachment) {
        attachments.append(att)
        if let cg = att.thumbnail(maxPixelSize: 132) { thumbs[att.id] = UIImage(cgImage: cg) }
    }
}

private extension NSItemProvider {
    /// Downsamples inside the completion handler: the file the provider hands over is gone
    /// once the handler returns, and the bytes themselves are never loaded into memory.
    func loadImageAttachment(filename: String) async -> Attachment? {
        await withCheckedContinuation { cont in
            _ = loadFileRepresentation(for: .image) { url, _, _ in
                cont.resume(returning: url.flatMap { Attachment.image(fileURL: $0, filename: filename) })
            }
        }
    }
}
