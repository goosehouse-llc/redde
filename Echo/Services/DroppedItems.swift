import Foundation
import UIKit
import UniformTypeIdentifiers

/// What a drop on the chat carries, sorted into what the composer takes: pictures and files
/// become attachments, a link or a piece of text goes into the draft.
nonisolated enum DroppedItems {
    /// What the chat accepts a drop of. `.item` covers files of any kind; the others say what
    /// else a drag can hold (a picture from a web page, a link, a selection).
    static let types: [UTType] = [.image, .fileURL, .url, .plainText, .item]
    /// More than this at once is a mistake, not a message.
    static let maximumAttachments = 8

    struct Loaded: Sendable {
        var attachments: [Attachment] = []
        var text: [String] = []
        /// Things that couldn't be taken, said the way the composer says them.
        var problems: [String] = []
    }

    /// Sorts the providers of one drop. On the main actor, where the drop arrives: the providers
    /// aren't sendable, and their callbacks (which come on other queues) are made in the
    /// nonisolated helpers below, so nothing here is tied to the actor it wasn't called on.
    @MainActor
    static func load(_ providers: [NSItemProvider]) async -> Loaded {
        var loaded = Loaded()
        for provider in providers {
            guard loaded.attachments.count < maximumAttachments else {
                loaded.problems.append("Only the first \(maximumAttachments) items were attached.")
                break
            }
            let name = provider.suggestedName
            switch kind(of: provider) {
            case .image:
                // Downsampled from the file the provider hands over, never loaded whole.
                let made = await withCheckedContinuation { requestFile(provider, as: .image, $0) { Attachment.image(fileURL: $0, filename: named(name, like: $0)) } }
                if case .success(let attachment?) = made {
                    loaded.attachments.append(attachment)
                } else {
                    loaded.problems.append("\(name ?? "A picture") couldn't be read.")
                }
            case .file(let type):
                let made = await withCheckedContinuation { requestFile(provider, as: type, $0) { try Attachment.file(url: $0) } }
                switch made {
                case .success(let attachment?): loaded.attachments.append(attachment)
                case .success(nil): loaded.problems.append("\(name ?? "A file") couldn't be read.")
                case .failure(let error): loaded.problems.append(error.localizedDescription)
                }
            case .link:
                if let link = await withCheckedContinuation({ requestLink(provider, $0) }) { loaded.text.append(link) }
            case .text:
                if let text = await withCheckedContinuation({ requestString(provider, $0) }), !text.isEmpty { loaded.text.append(text) }
            case .nothing:
                break
            }
        }
        return loaded
    }

    enum Kind: Equatable {
        case image
        /// A file, to be asked for as this type.
        case file(UTType)
        case link
        case text
        case nothing
    }

    /// What a provider holds, from the types it registered and whether a file stands behind it.
    static func kind(of provider: NSItemProvider) -> Kind {
        kind(of: provider.registeredContentTypes,
             fileBacked: provider.hasRepresentationConforming(toTypeIdentifier: UTType.data.identifier, fileOptions: .openInPlace),
             readsAsText: provider.canLoadObject(ofClass: NSString.self))
    }

    /// A text file out of Files and a sentence dragged out of a page can register the same
    /// types; what tells them apart is the file. A file is attached, loose text goes in the draft.
    static func kind(of types: [UTType], fileBacked: Bool, readsAsText: Bool) -> Kind {
        if types.contains(where: { $0.conforms(to: .image) }) { return .image }
        let content = types.first { !$0.conforms(to: .url) && $0.conforms(to: .data) }
        if let content, fileBacked || types.contains(where: { $0.conforms(to: .fileURL) }) { return .file(content) }
        if types.contains(where: { $0.conforms(to: .url) && !$0.conforms(to: .fileURL) }) { return .link }
        if readsAsText { return .text }
        // Data with no file behind it and nothing to read it as: a file all the same.
        return content.map { .file($0) } ?? .nothing
    }

    /// The name the provider suggests, with the extension of the file it handed over.
    static func named(_ suggested: String?, like url: URL) -> String {
        guard let suggested, !suggested.isEmpty else { return url.lastPathComponent }
        return (suggested as NSString).pathExtension.isEmpty && !url.pathExtension.isEmpty ? "\(suggested).\(url.pathExtension)" : suggested
    }

    // The provider calls back on a queue of its own, so these closures must belong to no actor.

    /// Runs `make` on the provider's file while it exists: it is gone once the handler returns.
    private static func requestFile<T: Sendable>(_ provider: NSItemProvider, as type: UTType,
                                                 _ continuation: CheckedContinuation<Result<T?, Error>, Never>,
                                                 make: @escaping @Sendable (URL) throws -> T?) {
        _ = provider.loadFileRepresentation(for: type) { url, _, _ in
            continuation.resume(returning: Result { try url.flatMap(make) })
        }
    }

    private static func requestLink(_ provider: NSItemProvider, _ continuation: CheckedContinuation<String?, Never>) {
        _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
            let url = object as? URL
            continuation.resume(returning: url?.isFileURL == false ? url?.absoluteString : nil)
        }
    }

    private static func requestString(_ provider: NSItemProvider, _ continuation: CheckedContinuation<String?, Never>) {
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            continuation.resume(returning: (object as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
