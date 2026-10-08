import AVFoundation
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension Attachment {
    /// A video small enough to send. One that fits goes as it is; a bigger one is re-encoded,
    /// at medium quality and then at low, and refused only when even that is over the limit.
    /// (A minute of phone video is some 100 MB; at medium quality about 6.)
    nonisolated static func video(fileURL: URL, filename: String? = nil, maxBytes: Int = maxFileBytes) async throws -> Attachment {
        let name = filename ?? fileURL.lastPathComponent
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        if size <= maxBytes {
            let type = UTType(filenameExtension: fileURL.pathExtension)
            let mime = type?.preferredMIMEType.flatMap { $0.hasPrefix("video/") ? $0 : nil } ?? "video/mp4"
            return Attachment(kind: .other, filename: name, mimeType: mime, data: try Data(contentsOf: fileURL, options: .mappedIfSafe))
        }
        let asset = AVURLAsset(url: fileURL)
        for preset in [AVAssetExportPresetMediumQuality, AVAssetExportPresetLowQuality] {
            guard let export = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            let out = FileManager.default.temporaryDirectory.appending(path: "video-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: out) }
            try await export.export(to: out, as: .mp4)
            guard let made = try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize, made <= maxBytes else { continue }
            let stem = (name as NSString).deletingPathExtension
            return Attachment(kind: .other, filename: (stem.isEmpty ? "video" : stem) + ".mp4", mimeType: "video/mp4", data: try Data(contentsOf: out))
        }
        throw AttachmentError.videoTooLong(name)
    }

    /// Whether a file is a video, by its name: what decides between `video(fileURL:)` and `file(url:)`.
    nonisolated static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
    }
}

/// A video out of the photo library, copied to where the app can read it at leisure: the file
/// the picker hands over is gone when its callback returns.
nonisolated struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appending(path: "picked-\(UUID().uuidString).\(received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}
