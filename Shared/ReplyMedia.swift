import Foundation

// Reply post-processing for files a hermes reply delivers by reference — the tag grammar
// (`MEDIA:<path>`, markdown data-URL images, "[IMAGE: /path]") lives here in one place:
// extraction into attachments below, and the matching spoken/display placeholders consumed
// by PlainText. Deliberately not part of the Message model.

/// Inline markdown destination scanning shared by the image extractors.
nonisolated enum MarkdownURL {
    /// The `)` closing a destination that starts right after `](`, honouring balanced
    /// parentheses inside the URL — a Wikipedia-style `/Foo_(bar).png` link must not
    /// truncate at the inner `)`.
    static func closingParen(of s: Substring, from start: Substring.Index) -> Substring.Index? {
        var depth = 1
        var i = start
        while i < s.endIndex {
            if s[i] == "(" { depth += 1 } else if s[i] == ")" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = s.index(after: i)
        }
        return nil
    }
}

/// Images the backend embedded in a finished reply as `![alt](data:image/…;base64,…)` — how the
/// sessions API delivers a MEDIA: file. Pulled out into photo attachments so the picture arrives
/// like a received photo message instead of markup inside the bubble, and the transcript text
/// stays free of megabyte base64 blobs.
nonisolated enum InlineImages {
    static func extract(from text: String) -> (text: String, attachments: [Attachment]) {
        guard text.contains("](data:image/") else { return (text, []) }
        var attachments: [Attachment] = []
        var out = ""
        var rest = Substring(text)
        while let start = rest.range(of: "![") {
            guard let mid = rest.range(of: "](", range: start.upperBound..<rest.endIndex),
                  let close = MarkdownURL.closingParen(of: rest, from: mid.upperBound) else { break }
            let afterClose = rest.index(after: close)
            let url = String(rest[mid.upperBound..<close])
            if let att = attachment(dataURL: url, alt: String(rest[start.upperBound..<mid.lowerBound])) {
                out += rest[..<start.lowerBound]
                attachments.append(att)
            } else {
                // Remote or malformed image: leave it for the markdown renderer.
                out += rest[..<afterClose]
            }
            rest = rest[afterClose...]
        }
        out += rest
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), attachments)
    }

    private static func attachment(dataURL: String, alt: String) -> Attachment? {
        attachment(dataURL: dataURL, name: alt.isEmpty || alt.lowercased() == "image" ? "photo" : alt)
    }

    /// An image data URL as a photo attachment; `name` keeps its own extension if it has one.
    static func attachment(dataURL: String, name: String) -> Attachment? {
        guard dataURL.hasPrefix("data:image/") else { return nil }
        return ServeMedia.attachment(dataURL: dataURL, name: name)
    }
}

/// Files a hermes reply references by server path. Serve doesn't intercept `MEDIA:` tags (on
/// the desktop app that's the client's job, reading its own disk), and the sessions API only
/// inlines small images — so a delivered file reaches the phone as a bare path; these are the
/// shapes it arrives in, for the app to fetch over the serve dashboard file API.
nonisolated enum ServeMedia {
    struct Candidate: Equatable {
        /// The exact text to strip from the reply once the file is fetched.
        var whole: String
        var path: String
        var filename: String { String(path.split(separator: "/").last ?? "photo") }
    }

    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic"]
    /// Documents worth fetching as attachments; anything else stays as text in the reply.
    private static let docExts: Set<String> = ["pdf", "txt", "md", "markdown", "csv", "json", "log",
                                              "html", "htm", "yaml", "yml", "xml", "rtf"]

    static func candidates(in text: String) -> [Candidate] {
        guard text.contains("/") else { return [] }
        // `MEDIA:/abs/path` (what every hermes platform hint teaches), `![alt](/abs/path)` and
        // `![alt](file:///abs/path)` (a markdown image of a server file the phone can't load),
        // and `[IMAGE: /abs/path]` (the phrasing models fall back to).
        let patterns: [Regex<(Substring, Substring)>] = [
            /MEDIA:(\/[^\s"'()\[\]]+)/,
            /!\[[^\]]*\]\((?:file:\/\/)?(\/[^)\s]+)\)/,
            /\[IMAGE:\s*(\/[^\]\s]+)\]/,
        ]
        var found: [Candidate] = []
        var seen: Set<String> = []
        for pattern in patterns {
            for match in text.matches(of: pattern) {
                let path = String(match.output.1)
                guard let ext = path.split(separator: ".").last?.lowercased(),
                      imageExts.contains(ext) || docExts.contains(ext),
                      seen.insert(String(match.output.0)).inserted else { continue }
                found.append(Candidate(whole: String(match.output.0), path: path))
            }
        }
        return found
    }

    /// Any data URL as an attachment; the kind follows the mime type, so a fetched PDF becomes
    /// a document chip and an image a photo. `name` keeps its own extension when it has one.
    static func attachment(dataURL: String, name: String) -> Attachment? {
        guard dataURL.hasPrefix("data:"), let comma = dataURL.range(of: ";base64,"),
              let data = Data(base64Encoded: String(dataURL[comma.upperBound...])), !data.isEmpty else { return nil }
        let mime = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma.lowerBound])
        let kind: Attachment.Kind = mime.hasPrefix("image/") ? .image
            : mime == "application/pdf" ? .pdf
            : mime.hasPrefix("text/") || mime == "application/json" || mime == "application/xml" ? .text
            : .other
        let ext = mime == "image/jpeg" ? "jpg" : String(mime.split(separator: "/").last ?? "bin")
        return Attachment(kind: kind, filename: name.contains(".") ? name : "\(name).\(ext)", mimeType: mime, data: data)
    }
}

extension ServeMedia {
    // The tag shapes, shared with PlainText's spoken/display stripping so the grammar
    // can't drift between rendering and speech.
    nonisolated static let spokenImageTagPattern = #"MEDIA:\S+\.(?i:png|jpe?g|gif|webp|bmp|heic)\S*"#
    nonisolated static let mediaTagPattern = #"MEDIA:\S+"#
    nonisolated static let imageTagPattern = #"\[IMAGE:[^\]]*\]"#
}
