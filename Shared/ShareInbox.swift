import Foundation

/// Hand-off from the share extension to the app through the App Group container. The extension
/// writes one payload; the app takes it on its next activation (or when opened via echo://share).
nonisolated enum ShareInbox {
    static let appGroup = "group.com.goosehouse.echo"

    struct Payload: Codable, Sendable {
        var note: String            // what the user typed in the share sheet
        var text: String            // shared plain text, if any
        var urls: [String]
        var attachments: [Attachment]
        var createdAt: Date

        var isEmpty: Bool { note.isEmpty && text.isEmpty && urls.isEmpty && attachments.isEmpty }

        /// Draft text for the composer: note first, then shared text and links.
        var draft: String {
            var parts: [String] = []
            if !note.isEmpty { parts.append(note) }
            if !text.isEmpty { parts.append(text) }
            parts += urls
            return parts.joined(separator: "\n\n")
        }
    }

    /// One file per share, so sharing twice before opening the app keeps both.
    private static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "pending-shares", directoryHint: .isDirectory)
    }

    static func write(_ payload: Payload) throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.userInfo[.inlineAttachmentData] = true   // the app can't read the extension's files
        let name = ISO8601DateFormatter().string(from: .now) + "-" + UUID().uuidString + ".json"
        try encoder.encode(payload).write(to: directory.appending(path: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Returns every pending share merged into one payload (oldest first) and clears them.
    /// Off the main actor: the payloads carry the attachment bytes inline as base64, so a few
    /// shared photos are tens of MB of JSON to decode while the app is coming forward.
    static func takePending() async -> Payload? {
        await Task.detached(priority: .userInitiated) { takePendingNow() }.value
    }

    private static func takePendingNow() -> Payload? {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var merged: Payload?
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file), let p = try? decoder.decode(Payload.self, from: data) else { continue }
            if var m = merged {
                if !p.text.isEmpty { m.text += (m.text.isEmpty ? "" : "\n\n") + p.text }
                m.urls += p.urls
                m.attachments += p.attachments
                if !p.note.isEmpty { m.note += (m.note.isEmpty ? "" : "\n") + p.note }
                merged = m
            } else {
                merged = p
            }
        }
        return merged
    }
}
