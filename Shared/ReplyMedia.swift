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
        /// As the reply wrote it: absolute, from `~/`, or relative to the session's folder.
        var path: String
        var filename: String { String(path.split(separator: "/").last ?? "photo") }
        /// Neither absolute nor from home: the server finds it from the session's folder.
        var isRelative: Bool { !path.hasPrefix("/") && !path.hasPrefix("~") }
    }

    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic"]
    /// Documents worth fetching as attachments; anything else stays as text in the reply.
    private static let docExts: Set<String> = ["pdf", "txt", "md", "markdown", "csv", "json", "log",
                                              "html", "htm", "yaml", "yml", "xml", "rtf"]
    /// Sound: what the agent's speech tool writes (MP3, or Opus in an .ogg for platforms with
    /// voice bubbles), and recordings. Played where it stands in the conversation.
    static let audioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "ogg", "oga", "opus", "flac", "aiff", "aif", "caf"]
    /// A line the speech tool puts before its `MEDIA:` tag to ask a chat platform for a voice
    /// bubble. It means nothing to a reader.
    static let voiceMarker = "[[audio_as_voice]]"

    /// What a sound file is called when the server doesn't say, or says only "a file".
    static func audioMime(forExtension ext: String) -> String {
        switch ext {
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        case "ogg", "oga", "opus": "audio/ogg"
        case "aif", "aiff": "audio/aiff"
        case "caf": "audio/x-caf"
        default: "audio/\(ext)"
        }
    }

    /// Hermes's own list of what a `MEDIA:` tag delivers (`MEDIA_DELIVERY_EXTS`, which the desktop
    /// app mirrors): the end of a path written without quotes, spaces and all, is one of these.
    static let deliveryExts = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "svg", "heic", "mp4", "mov", "m4v", "avi",
                               "mkv", "webm", "3gp", "mp3", "m2a", "wav", "ogg", "opus", "m4a", "aac", "flac", "pdf", "docx",
                               "doc", "odt", "rtf", "txt", "md", "epub", "xlsx", "xls", "ods", "csv", "tsv", "json", "xml",
                               "yaml", "yml", "kmz", "kml", "geojson", "gpx", "pptx", "ppt", "odp", "key", "zip", "tar", "gz",
                               "tgz", "bz2", "xz", "7z", "rar", "apk", "ipa", "html", "htm"]
    /// A sentence's punctuation after a bare path (`open MEDIA:/tmp/a.pdf.`) isn't the path's.
    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]

    /// What the desktop app reads as a `MEDIA:` tag (its `MEDIA_TAG_RE`): a quoted path (the way to
    /// write an odd name); one from `/` or `~/`, spaces allowed, to a known extension; else the
    /// word that follows (a relative path, an unknown extension).
    private static let mediaTag: NSRegularExpression = {
        let exts = deliveryExts.sorted { $0.count > $1.count }.joined(separator: "|")
        let anchored = #"(?:~/|/)\S+?(?:[^\S\n]+\S+?)*?\.(?i:"# + exts + #")(?=[\s`"'*_,;:)\]}]|MEDIA:|$)"#
        let pattern = #"[`"']?MEDIA:\s*(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|"# + anchored + #"|[^\s`"]+)[`"']?"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// `::preview{file="page.html"}`: a page the agent made, which the desktop app shows inside
    /// the chat. Here it is the file, for now.
    private static let previewDirective = try! NSRegularExpression(
        pattern: #"(?<![^\s])::preview\{([^{}]{0,1024})\}"#)
    private static let previewFile = try! NSRegularExpression(pattern: #"file=(?:"([^"]*)"|'([^']*)')"#, options: [.caseInsensitive])

    /// Whether a reply could name a file at all, before anything costlier looks.
    static func mayName(in text: String) -> Bool {
        text.contains("MEDIA:") || text.contains("::preview") || text.contains("[IMAGE:") || text.contains("](/")
            || text.contains("](file://") || text.contains("/redde-push/device/files/")
    }

    static func candidates(in text: String) -> [Candidate] {
        guard mayName(in: text) else { return [] }
        var found: [Candidate] = []
        var seen: Set<String> = []
        // By what is written: a path named twice over (`MEDIA:/x` and then `/x`) is stripped both times.
        func add(_ whole: String, _ path: String) {
            guard seen.insert(whole).inserted else { return }
            found.append(Candidate(whole: whole, path: path))
        }
        let ns = text as NSString
        for match in mediaTag.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let (whole, path) = tag(ns.substring(with: match.range), value: ns.substring(with: match.range(at: 1))) { add(whole, path) }
        }
        // `![alt](/abs/path)` and `![alt](file:///abs/path)` (a markdown image of a server file
        // the phone can't load), `[IMAGE: /abs/path]` (the phrasing models fall back to), and a
        // file the phone handed over for the agent to look at (phone tools), which Redde's plugin
        // keeps in a folder of its own on the server: named by its bare path, in backticks or not,
        // it is shown all the same. An agent asked to "show me" the photo it was just given
        // answered with that path.
        let patterns: [Regex<(Substring, Substring)>] = [
            /!\[[^\]]*\]\((?:file:\/\/)?(\/[^)\s]+)\)/,
            /\[IMAGE:\s*(\/[^\]\s]+)\]/,
            /`?(\/[^\s`"'()\[\]]*\/redde-push\/device\/files\/[^\s`"'()\[\]]+)`?/,
        ]
        for pattern in patterns {
            for match in text.matches(of: pattern) {
                let path = String(match.output.1)
                guard let ext = path.split(separator: ".").last?.lowercased(),
                      imageExts.contains(ext) || docExts.contains(ext) || audioExts.contains(ext) else { continue }
                add(String(match.output.0), path)
            }
        }
        for match in previewDirective.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let attributes = ns.substring(with: match.range(at: 1))
            let attrs = attributes as NSString
            guard let file = previewFile.firstMatch(in: attributes, range: NSRange(location: 0, length: attrs.length)) else { continue }
            let value = file.range(at: 1).location != NSNotFound ? attrs.substring(with: file.range(at: 1)) : attrs.substring(with: file.range(at: 2))
            guard !value.isEmpty, !value.contains("://") else { continue }
            add(ns.substring(with: match.range), value)
        }
        return found
    }

    /// One `MEDIA:` match: what to strip and the path, as the desktop app reads it (quotes off, a
    /// bare path's trailing sentence punctuation left to the sentence), or nil when what follows
    /// the tag can't be a file (`MEDIA:...`, a word with no slash or extension).
    private static func tag(_ match: String, value: String) -> (whole: String, path: String)? {
        var raw = value.trimmingCharacters(in: .whitespaces)
        guard let first = raw.first else { return nil }
        let quoted = raw.count > 1 && first == raw.last && "\"'`".contains(first)
        var whole = match
        // A path with spaces runs to the next known extension, which can be a web address's
        // further along the sentence (`MEDIA:/tmp/tool.bin, not https://…/pic.jpg`): then the
        // path is the first word.
        if !quoted, raw.contains(" "), raw.contains("://"), let cut = raw.firstIndex(of: " "), let at = match.range(of: raw) {
            raw = String(raw[..<cut])
            whole = String(match[..<at.lowerBound]) + raw
        }
        var path = quoted ? String(raw.dropFirst().dropLast()) : raw
        if !quoted {
            // A trailing backtick or double quote left in the value is formatting, not the path.
            if path.hasSuffix("`") || path.hasSuffix("\"") { path.removeLast() }
            while let last = path.last, trailingPunctuation.contains(last), isPlausible(String(path.dropLast())) {
                path.removeLast()
                if whole.last == last { whole.removeLast() }
            }
        }
        // A page on the web is a link, not a file on the server.
        return isPlausible(path) && !path.contains("://") ? (whole, path) : nil
    }

    /// A path names a file when it has a folder in it or an extension (`report.md`, `../a.png`).
    private static func isPlausible(_ path: String) -> Bool {
        path.contains("/") || path.range(of: #"\.[^.]"#, options: .regularExpression) != nil
    }

    /// The reply as it reads without the files it names, and those files: what stays named after
    /// they were fetched (none could be, or there was no Dashboard login to fetch with) is shown
    /// as a file to open rather than as a path.
    static func named(in text: String) -> (text: String, files: [Candidate]) {
        let found = candidates(in: text)
        guard !found.isEmpty else { return (text, []) }
        var out = text.replacingOccurrences(of: voiceMarker, with: "")
        for file in found { out = out.replacingOccurrences(of: file.whole, with: "") }
        var paths: Set<String> = []
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), found.filter { paths.insert($0.path).inserted })
    }

    /// A path into the folder where Redde's plugin keeps what the phone handed to the agent.
    static func isFromThePhone(_ path: String) -> Bool { path.contains("/redde-push/device/files/") }

    /// Any data URL as an attachment; the kind follows the mime type, so a fetched PDF becomes
    /// a document chip and an image a photo. `name` keeps its own extension when it has one.
    static func attachment(dataURL: String, name: String) -> Attachment? {
        guard dataURL.hasPrefix("data:"), let comma = dataURL.range(of: ";base64,"),
              let data = Data(base64Encoded: String(dataURL[comma.upperBound...])), !data.isEmpty else { return nil }
        var mime = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma.lowerBound])
        // A sound file the server only called "a file" (an .opus, often) is still sound.
        let named = (name as NSString).pathExtension.lowercased()
        if audioExts.contains(named), !mime.hasPrefix("audio/") { mime = audioMime(forExtension: named) }
        let kind: Attachment.Kind = mime.hasPrefix("image/") ? .image
            : mime == "application/pdf" ? .pdf
            : mime.hasPrefix("text/") || mime == "application/json" || mime == "application/xml" ? .text
            : .other
        let ext = mime == "image/jpeg" ? "jpg" : mime == "audio/mpeg" ? "mp3" : String(mime.split(separator: "/").last ?? "bin")
        return Attachment(kind: kind, filename: name.contains(".") ? name : "\(name).\(ext)", mimeType: mime, data: data)
    }
}

extension ServeMedia {
    // The tag shapes, shared with PlainText's spoken/display stripping so the grammar
    // can't drift between rendering and speech.
    nonisolated static let spokenImageTagPattern = #"MEDIA:\S+\.(?i:png|jpe?g|gif|webp|bmp|heic)\S*"#
    nonisolated static let spokenAudioTagPattern = #"MEDIA:\S+\.(?i:mp3|m4a|aac|wav|ogg|oga|opus|flac|aiff?|caf)\b\S*"#
    nonisolated static let voiceMarkerPattern = #"\[\[audio_as_voice\]\]\s*"#
    nonisolated static let mediaTagPattern = #"MEDIA:\s*(?:"[^"\n]+"|'[^'\n]+'|`[^`\n]+`|\S+)"#
    nonisolated static let imageTagPattern = #"\[IMAGE:[^\]]*\]"#
}
