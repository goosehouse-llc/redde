import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Something the user attached to a message. Images are downscaled to keep the transcript file
/// and the request small; other files are carried as-is up to a cap.
nonisolated struct Attachment: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case image, pdf, text, other }

    var id: UUID = UUID()
    var kind: Kind
    var filename: String
    var mimeType: String
    /// Bytes as created; stays resident for this value's lifetime. A value decoded from the
    /// transcript has no inline bytes and reads them from the attachment store instead.
    private var inline: Data?
    private var byteCount: Int

    /// The bytes, from memory or from the attachment store on disk.
    var data: Data {
        get { inline ?? AttachmentFiles.read(id: id) ?? Data() }
        set { inline = newValue; byteCount = newValue.count }
    }

    init(id: UUID = UUID(), kind: Kind, filename: String, mimeType: String, data: Data) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.mimeType = mimeType
        self.inline = data
        self.byteCount = data.count
    }

    static func == (a: Attachment, b: Attachment) -> Bool {
        a.id == b.id && a.kind == b.kind && a.filename == b.filename && a.mimeType == b.mimeType && a.byteCount == b.byteCount
    }

    // MARK: - Codable
    // Transcript storage keeps only metadata and writes the bytes to AttachmentFiles; the share
    // inbox (a different process) asks for the bytes inline via `CodingUserInfoKey.inlineAttachmentData`.

    private enum CodingKeys: String, CodingKey { case id, kind, filename, mimeType, data, byteCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        filename = try c.decode(String.self, forKey: .filename)
        mimeType = try c.decode(String.self, forKey: .mimeType)
        inline = try c.decodeIfPresent(Data.self, forKey: .data)
        byteCount = try c.decodeIfPresent(Int.self, forKey: .byteCount) ?? inline?.count ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(filename, forKey: .filename)
        try c.encode(mimeType, forKey: .mimeType)
        try c.encode(byteCount, forKey: .byteCount)
        if encoder.userInfo[.inlineAttachmentData] as? Bool == true {
            try c.encode(data, forKey: .data)
        }
        // No side effects here: the bytes reach AttachmentFiles via persistToStore(), called
        // explicitly on ConversationStore's save path — encoding must stay pure.
    }

    /// Writes in-memory bytes to the attachment store so a metadata-only encode can be decoded
    /// later. Idempotent (the store skips existing files); a no-op once bytes live on disk.
    func persistToStore() {
        if let inline { AttachmentFiles.write(id: id, data: inline) }
    }

    static let maxImageEdge: CGFloat = 2560   // enough to read text off a photographed screen
    static let maxFileBytes = 8 * 1024 * 1024

    var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file) }

    /// Text-like files can be inlined into the prompt on transports that don't take files.
    var inlineText: String? {
        guard kind == .text, let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// Text files can be inlined into the prompt on transports that don't take files.
    var promptAddendum: String? {
        inlineText.map { "--- \(filename) ---\n\($0)" }
    }

    // MARK: - Builders

    /// For callers that already hold a decoded bitmap (camera, paste). Files and shared photos
    /// go through `image(fileURL:)`, which never decodes the full-size image.
    static func image(_ image: UIImage, filename: String = "photo.jpg") -> Attachment? {
        let scale = min(1, maxImageEdge / max(image.size.width, image.size.height))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        guard let jpeg = scaled.jpegData(compressionQuality: 0.88) else { return nil }
        return Attachment(kind: .image, filename: filename, mimeType: "image/jpeg", data: jpeg)
    }

    /// Downsamples an image file through ImageIO: a 48 MP photo never becomes a 190 MB bitmap,
    /// which matters inside the share extension's memory limit.
    static func image(fileURL: URL, filename: String? = nil) -> Attachment? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return image(source: source, filename: filename ?? fileURL.lastPathComponent)
    }

    static func image(data: Data, filename: String = "photo.jpg") -> Attachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return image(source: source, filename: filename)
    }

    private static func image(source: CGImageSource, filename: String) -> Attachment? {
        guard let cg = downsample(source, maxPixelSize: Int(maxImageEdge)) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return Attachment(kind: .image, filename: filename, mimeType: "image/jpeg", data: out as Data)
    }

    /// A small copy for a row thumbnail, decoded from the stored JPEG at the size it is shown.
    func thumbnail(maxPixelSize: Int) -> CGImage? {
        guard kind == .image, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return Self.downsample(source, maxPixelSize: maxPixelSize)
    }

    /// Orientation applied, never upscaled.
    private static func downsample(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }

    static func file(url: URL) throws -> Attachment {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        // Check the size before reading: a share extension has ~120 MB and a big video would kill it first.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxFileBytes {
            throw AttachmentError.tooLarge(url.lastPathComponent)
        }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image), let att = image(fileURL: url) { return att }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maxFileBytes else { throw AttachmentError.tooLarge(url.lastPathComponent) }
        let mime = type.preferredMIMEType ?? "application/octet-stream"
        let kind: Kind
        if type.conforms(to: .pdf) { kind = .pdf }
        else if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml) || mime.hasPrefix("text/") { kind = .text }
        else { kind = .other }
        return Attachment(kind: kind, filename: url.lastPathComponent, mimeType: mime, data: data)
    }
}

nonisolated enum AttachmentError: LocalizedError {
    case tooLarge(String)
    case unsupported(String, transport: String)

    var errorDescription: String? {
        switch self {
        case let .tooLarge(name): "\(name) is over the 8 MB attachment limit."
        case let .unsupported(kind, transport): "\(kind) attachments aren't supported on \(transport). Switch to Redde serve in Settings."
        }
    }
}


extension CodingUserInfoKey {
    /// Set to `true` on an encoder to embed attachment bytes in the JSON (share inbox hand-off).
    nonisolated static let inlineAttachmentData = CodingUserInfoKey(rawValue: "inlineAttachmentData")!
}

/// Attachment bytes on disk, one file per attachment, so the transcript JSON stays small.
nonisolated enum AttachmentFiles {
    // NSCache is thread-safe by contract; the annotation just tells Swift so.
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 64 * 1024 * 1024   // bytes; a transcript full of photos must not pin them all
        return cache
    }()

    /// Resolved once: the lookup is two FileManager calls and happens on every read and write.
    static let directory: URL? = {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        let dir = base.appending(path: "attachments")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(for id: UUID) -> URL? { directory?.appending(path: id.uuidString) }

    static func write(id: UUID, data: Data) {
        guard let url = url(for: id), !FileManager.default.fileExists(atPath: url.path) else { return }
        // Same class as the transcript that references it; a turn's attachment can be written after lock.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func read(id: UUID) -> Data? {
        let key = id.uuidString as NSString
        if let hit = cache.object(forKey: key) { return hit as Data }
        guard let url = url(for: id), let data = try? Data(contentsOf: url) else { return nil }
        cache.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    static func delete(id: UUID) {
        cache.removeObject(forKey: id.uuidString as NSString)
        if let url = url(for: id) { try? FileManager.default.removeItem(at: url) }
    }

    /// Everything, including orphans no transcript references any more. The directory itself
    /// stays: its URL is resolved once, and the next attachment writes into it.
    static func deleteAll() {
        cache.removeAllObjects()
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}
