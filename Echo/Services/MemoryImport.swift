import Compression
import Foundation

/// Memory from another assistant ("memory you can see", 2.4): a ChatGPT or Claude data export,
/// read on the device, never sent anywhere whole. The person ticks what's true; only those leave the
/// device, to their own server.
///
/// - **ChatGPT**: a .zip with `conversations.json` (each conversation's `mapping` of nodes; a node's
///   `message.author.role` and `message.content.parts`), and saved memories in a file named "memor…".
/// - **Claude** (from Nov 2026): the email links a **manifest** (`data_files`: one download per
///   category, each a claude.ai link that works once, in a signed-in browser, for 24 hours). Of
///   those, `memories-000.zip` holds one JSON: `conversations_memory` (Claude's summary of the
///   person, prose and "-" lines), `project_memories` (project id → "-" lines) and `memory_files`
///   (whole Markdown notes by path); `conversations-000.zip` holds `conversations.json` (each with
///   `chat_messages`: `sender` "human", `text`, `content[]` of typed parts). Safari may unzip them:
///   a folder and a bare JSON file are read the same way. The older single .zip still reads.
///
/// Facts (short lines) suit About You; notes (whole files, project memories) suit a long-term store.
nonisolated enum MemoryImport {
    enum Source: String, Sendable { case chatGPT = "ChatGPT", claude = "Claude", unknown }

    struct Candidate: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// A memory the other assistant had saved about the person.
            case saved
            /// A line picked out of the person's own messages.
            case said
            /// A project's memory line (Claude): about a project more than the person.
            case projectMemory
            /// A whole memory file (Claude's `memory_files`): too long for About You.
            case note
        }

        var id = UUID()
        /// The fact, or a note's title.
        var text: String
        var kind: Kind = .said
        /// How many times it was said.
        var count = 1
        /// A note's text, and the folder it was in ("people", "areas", "topics", "projects", "").
        var body: String? = nil
        var folder: String? = nil

        var saved: Bool { kind == .saved }
        /// Better kept in a long-term store than in About You, which is in every prompt.
        var isNote: Bool { kind == .note || kind == .projectMemory }

        init(id: UUID = UUID(), text: String, saved: Bool, count: Int = 1) {
            self.id = id
            self.text = text
            self.kind = saved ? .saved : .said
            self.count = count
        }

        init(text: String, kind: Kind, body: String? = nil, folder: String? = nil) {
            self.text = text
            self.kind = kind
            self.body = body
            self.folder = folder
        }
    }

    struct Result: Equatable, Sendable {
        var source: Source
        var candidates: [Candidate]
        var messagesRead: Int
    }

    /// Claude's export email: what to download, and until when.
    struct Manifest: Equatable, Sendable {
        struct Part: Equatable, Sendable {
            var category: String
            var url: URL
            var filename: String
        }
        var parts: [Part]
        var createdAt: Date?
        var expiresAt: Date? { createdAt?.addingTimeInterval(24 * 3600) }

        func part(_ category: String) -> Part? { parts.first { $0.category == category } }
    }

    enum Outcome: Equatable, Sendable {
        case result(Result)
        case manifest(Manifest)
    }

    enum Failure: LocalizedError, Equatable {
        case unreadable, tooLarge, nothingFound
        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "This isn't a ChatGPT or Claude export Redde can read. Pick the .zip ChatGPT emailed you, or Claude's memories and conversations downloads (or the file Claude's email links to).")
            case .tooLarge: String(localized: "This export is too large to read on this device. Pick its memories or conversations file on its own instead.")
            case .nothingFound: String(localized: "Nothing about you turned up in this export.")
            }
        }
    }

    /// At most this much JSON is read (decompressed) per file, and this many facts and notes offered.
    static let maxBytes = 400 * 1_048_576
    static let most = 60
    static let mostNotes = 80
    /// A note's text is kept up to this; Claude's can be ~10 KB.
    static let longestNote = 20_000

    // MARK: Reading

    /// Reads one export file or several (zips, JSON files, folders Safari unzipped), off the main
    /// actor: an export can be large. A manifest alone gives `.manifest`; anything else, the merged
    /// candidates.
    @concurrent static func read(_ urls: [URL]) async throws -> Outcome {
        var source = Source.unknown
        var saved: [String] = [], said: [String] = [], extra: [Candidate] = []
        var manifest: Manifest?
        var readSomething = false
        for url in urls {
            for (name, data) in try files(at: url) {
                // One file's JSON at a time: parsed, read, let go.
                autoreleasepool {
                    guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return }
                    switch classify(json, name: name) {
                    case .manifest:
                        if let found = Self.manifest(json) { manifest = found; readSomething = true }
                    case .claudeMemories:
                        source = .claude
                        readSomething = true
                        let read = claudeMemories(json)
                        saved += read.facts
                        extra += read.notes
                    case .conversations:
                        let (kind, texts) = userMessages(json)
                        if kind != .unknown { source = source == .unknown ? kind : source; readSomething = true }
                        said += texts
                    case .savedMemories:
                        saved += savedMemories(json)
                        readSomething = true
                    case .other:
                        break
                    }
                }
            }
        }
        if let manifest, saved.isEmpty, said.isEmpty, extra.isEmpty { return .manifest(manifest) }
        guard readSomething else { throw Failure.unreadable }
        let result = Result(source: source, candidates: candidates(saved: saved, said: said) + Array(extra.prefix(mostNotes)), messagesRead: said.count)
        guard !result.candidates.isEmpty else { throw Failure.nothingFound }
        return .result(result)
    }

    @concurrent static func read(_ url: URL) async throws -> Outcome { try await read([url]) }

    /// The JSON files in what was picked: a zip's, a folder's (one level of folders down), or itself.
    static func files(at url: URL) throws -> [(name: String, data: Data)] {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            let found = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
            var out: [(String, Data)] = []
            while let file = found?.nextObject() as? URL {
                guard ["json", "zip"].contains(file.pathExtension.lowercased()) else { continue }
                let relative = url.lastPathComponent + "/" + file.path.dropFirst(url.path.count + 1)
                out += try files(at: file).map { (relative + ($0.name == file.lastPathComponent ? "" : "/" + $0.name), $0.data) }
            }
            return out
        }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            let zip = try Zip(data)
            return try zip.entries.filter { wanted($0.name) }.map { (url.lastPathComponent + "/" + $0.name, try zip.contents(of: $0, limit: maxBytes)) }
        }
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        return [(url.lastPathComponent, data)]
    }

    /// A zip's JSON files, except Claude's other parts' bulky ones that hold nothing about the person.
    static func wanted(_ name: String) -> Bool {
        let file = (name as NSString).lastPathComponent.lowercased()
        return file.hasSuffix(".json") && !file.hasPrefix(".") && !name.hasPrefix("__MACOSX")
    }

    enum Shape: Equatable { case manifest, claudeMemories, conversations, savedMemories, other }

    /// What a parsed file is, by its shape (Claude's files are named by uuid, so not by name).
    static func classify(_ json: Any, name: String) -> Shape {
        if let object = json as? [String: Any] {
            if object["data_files"] is [Any] { return .manifest }
            if object["conversations_memory"] != nil || object["memory_files"] != nil || object["project_memories"] != nil { return .claudeMemories }
        }
        if let list = json as? [[String: Any]], let first = list.first, first["mapping"] != nil || first["chat_messages"] != nil {
            return .conversations
        }
        return name.lowercased().contains("memor") ? .savedMemories : .other
    }

    // MARK: Claude's manifest

    static let claudeExportPrefix = "https://claude.ai/export/"

    /// Its downloads, only claude.ai export links (anything else in the file is dropped).
    static func manifest(_ json: Any) -> Manifest? {
        guard let object = json as? [String: Any], let files = object["data_files"] as? [[String: Any]] else { return nil }
        let parts: [Manifest.Part] = files.compactMap { file in
            guard let link = file["export_url"] as? String, link.hasPrefix(claudeExportPrefix),
                  let url = URL(string: link), url.scheme == "https", url.host == "claude.ai",
                  let category = file["category"] as? String else { return nil }
            return Manifest.Part(category: category, url: url, filename: file["filename"] as? String ?? "")
        }
        guard !parts.isEmpty else { return nil }
        let created = (object["created_at"] as? String).flatMap(isoDate)
        return Manifest(parts: parts, createdAt: created)
    }

    static func isoDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    // MARK: Claude's memories

    /// `conversations_memory` as facts; `project_memories` lines and `memory_files` as notes.
    static func claudeMemories(_ json: Any) -> (facts: [String], notes: [Candidate]) {
        guard let object = json as? [String: Any] else { return ([], []) }
        let facts = (object["conversations_memory"] as? String).map(memoryFacts) ?? []
        var notes: [Candidate] = []
        if let projects = object["project_memories"] as? [String: Any] {
            for (_, value) in projects.sorted(by: { $0.key < $1.key }) {
                guard let text = value as? String else { continue }
                for line in memoryFacts(text) { notes.append(Candidate(text: line, kind: .projectMemory)) }
            }
        }
        if let files = object["memory_files"] as? [[String: Any]] {
            for file in files {
                guard let path = file["path"] as? String, let content = (file["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !content.isEmpty else { continue }
                let (title, folder) = noteTitle(path)
                notes.append(Candidate(text: title, kind: .note, body: String(content.prefix(longestNote)), folder: folder))
            }
        }
        return (facts, notes)
    }

    /// Claude's memory text as short facts: each "-" line, and each sentence of the prose, without
    /// headings or bold labels.
    static func memoryFacts(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // A label on its own line ("**Work context**"), not a fact.
            if line.hasPrefix("**"), line.hasSuffix("**") || line.hasSuffix("**:") { continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                line = String(line.dropFirst(2))
                out.append(clean(line))
                continue
            }
            line.enumerateSubstrings(in: line.startIndex..., options: [.bySentences, .localized]) { sentence, _, _, _ in
                if let sentence { out.append(clean(sentence)) }
            }
        }
        return out.filter { $0.count >= 8 && $0.count <= 300 && !($0.hasSuffix(":") && $0.count < 60) }
    }

    private static func clean(_ text: String) -> String {
        var line = text.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        line = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return line.hasSuffix(".") ? String(line.dropLast()) : line
    }

    /// A memory file's title and folder from its path: "/people/dana-ruiz.md" → ("Person: Dana Ruiz",
    /// "people"); "/projects/<id>/plan.md" → ("Project: Plan", "projects"); "/x.md" → ("X", "").
    static func noteTitle(_ path: String) -> (String, String) {
        let parts = path.split(separator: "/").map(String.init)
        let file = ((parts.last ?? path) as NSString).deletingPathExtension
        let name = file.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        let words = name.prefix(1).uppercased() + name.dropFirst()
        guard parts.count > 1 else { return (words, "") }
        switch parts[0].lowercased() {
        case "people": return (String(localized: "Person: \(name.capitalized)"), "people")
        case "areas": return (String(localized: "Area: \(words)"), "areas")
        case "topics": return (String(localized: "Topic: \(words)"), "topics")
        case "projects": return (String(localized: "Project: \(words)"), "projects")
        default: return (words, parts[0].lowercased())
        }
    }

    // MARK: Conversations

    /// The person's own messages, oldest first, and whose export it is. Claude's: the `text` parts
    /// of `content` (never thinking, tool use or results, documents, or injected prompt blocks), or
    /// `text` where there's no content.
    static func userMessages(_ json: Any) -> (Source, [String]) {
        guard let conversations = json as? [[String: Any]] else { return (.unknown, []) }
        var texts: [(Double, String)] = []
        var source = Source.unknown
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for conversation in conversations {
            if let mapping = conversation["mapping"] as? [String: Any] {
                source = .chatGPT
                for case let node as [String: Any] in mapping.values {
                    guard let message = node["message"] as? [String: Any],
                          (message["author"] as? [String: Any])?["role"] as? String == "user",
                          let content = message["content"] as? [String: Any] else { continue }
                    let parts = (content["parts"] as? [Any] ?? []).compactMap { $0 as? String }
                    let text = parts.joined(separator: "\n")
                    if !text.isEmpty { texts.append((message["create_time"] as? Double ?? 0, text)) }
                }
            } else if let messages = conversation["chat_messages"] as? [[String: Any]] {
                source = .claude
                for message in messages where message["sender"] as? String == "human" {
                    var text: String
                    if let content = message["content"] as? [[String: Any]], !content.isEmpty {
                        text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    } else {
                        text = message["text"] as? String ?? ""
                    }
                    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let stamp = message["created_at"] as? String ?? ""
                    let when = (iso.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp))?.timeIntervalSince1970 ?? 0
                    if !text.isEmpty { texts.append((when, text)) }
                }
            }
        }
        return (source, texts.sorted { $0.0 < $1.0 }.map(\.1))
    }

    /// Saved memories in whatever shape the file has them: strings, or objects with "content",
    /// "memory", "text" or "value", at any depth.
    static func savedMemories(_ json: Any) -> [String] {
        var out: [String] = []
        func walk(_ value: Any, depth: Int) {
            guard depth < 6, out.count < 500 else { return }
            if let text = value as? String {
                if text.count >= 4, text.count <= 400 { out.append(text) }
            } else if let list = value as? [Any] {
                list.forEach { walk($0, depth: depth + 1) }
            } else if let object = value as? [String: Any] {
                if let text = ["content", "memory", "text", "value"].lazy.compactMap({ object[$0] as? String }).first {
                    walk(text, depth: depth + 1)
                } else {
                    for (key, child) in object where !["id", "uuid", "created_at", "updated_at", "type"].contains(key) { walk(child, depth: depth + 1) }
                }
            }
        }
        walk(json, depth: 0)
        return out
    }

    // MARK: Picking facts out

    /// Sentences where the person says something about themselves. Not questions, not code, not
    /// links, not a pasted page: a short line in their own words.
    static let selfStatement = try! NSRegularExpression(pattern:
        #"^(?:(?:i am|i'm|i work|i live|i have|i've got|i prefer|i like|i love|i hate|i don't like|i do not like|i use|i own|i run|i drive|i usually|i always|i never|i'm allergic|i speak|i study|i teach|i was born)\b|my (?:name|wife|husband|partner|son|daughter|kids?|children|dog|cat|job|company|team|boss|birthday|favou?rite|home|car|setup|stack|role|title|mother|mom|father|dad|sister|brother)\b|call me\b)"#,
        options: [.caseInsensitive])

    static func facts(in message: String) -> [String] {
        guard message.count < 20_000 else { return [] }
        var out: [String] = []
        message.enumerateSubstrings(in: message.startIndex..., options: [.bySentences, .localized]) { sentence, _, _, stop in
            guard var line = sentence?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            line = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard line.count >= 10, line.count <= 200, !line.contains("?"), !line.contains("http"),
                  !line.contains(where: { "{}<>;=`|\\".contains($0) }),
                  selfStatement.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { return }
            out.append(line.hasSuffix(".") || line.hasSuffix("!") ? String(line.dropLast()) : line)
            if out.count >= 10 { stop = true }
        }
        return out
    }

    /// Saved memories first, then what was said, most repeated and then most recent first; one of
    /// each (case aside), `most` at most of what was said.
    static func candidates(saved: [String], said: [String]) -> [Candidate] {
        var out: [Candidate] = []
        var seen = Set<String>()
        for text in saved {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, seen.insert(text.lowercased()).inserted { out.append(Candidate(text: text, saved: true)) }
        }
        var counts: [String: (text: String, count: Int, last: Int)] = [:]
        for (index, message) in said.enumerated() {
            for fact in facts(in: message) {
                let key = fact.lowercased()
                counts[key, default: (fact, 0, index)].count += 1
                counts[key]?.last = index
            }
        }
        let ranked = counts.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.last > $1.last }
        var added = 0
        for fact in ranked where seen.insert(fact.text.lowercased()).inserted {
            out.append(Candidate(text: fact.text, saved: false, count: fact.count))
            added += 1
            if added >= most { break }
        }
        return out
    }

    /// The message that hands the picked facts to the agent to keep in its own words (`Remember
    /// that:` brings the plugin's memory note). Capped, so a long pick stays one message.
    static func agentMessage(_ facts: [String], from source: Source) -> String {
        let from = source == .unknown ? String(localized: "another assistant") : source.rawValue
        var body = ""
        for fact in facts {
            let line = "- " + fact + "\n"
            if body.count + line.count > 4_000 { break }
            body += line
        }
        return "Remember that: these are things I told \(from). Keep the ones worth keeping as short entries in your memory, "
            + "merged with what you already know about me, and tell me in one line what you kept.\n" + body
    }

    /// Made-up export for screenshots (`-echo.demoMemory`): facts and notes together.
    static let demoResult = Result(source: .claude, candidates: [
        Candidate(text: "Prefers short answers with the steps numbered", saved: true),
        Candidate(text: "Vegetarian, and allergic to cats", saved: true),
        Candidate(text: "Works from home on Fridays", saved: true),
        Candidate(text: "My daughter is Mia and she starts school at 8:30", saved: false, count: 3),
        Candidate(text: "I'm learning Portuguese, about B1", saved: false),
        Candidate(text: "The garden plan uses raised beds on the south side", kind: .projectMemory),
        Candidate(text: "Person: Dana Ruiz", kind: .note, body: "Dana is the neighbour who waters the plants in August.\n\n- Phone in contacts\n- Allergic to bees", folder: "people"),
        Candidate(text: "Area: Health", kind: .note, body: "Runs Tuesday and Thursday mornings, about 5 km.\nPhysio in March for the left knee.", folder: "areas"),
        Candidate(text: "Topic: Home network", kind: .note, body: "Mesh Wi-Fi in three rooms; the printer is on the guest network.", folder: "topics"),
    ], messagesRead: 1_284)

    /// Made-up manifest for screenshots.
    static let demoManifest = Manifest(parts: [
        .init(category: "memories", url: URL(string: "https://claude.ai/export/demo/download/1")!, filename: "memories-000.zip"),
        .init(category: "conversations", url: URL(string: "https://claude.ai/export/demo/download/2")!, filename: "conversations-000.zip"),
    ], createdAt: Date(timeIntervalSinceNow: -3 * 3600))
}

// MARK: - Zip

/// Just enough of a zip reader for an export: the central directory, and stored or deflated files
/// (Compression's ZLIB is raw deflate). No zip64, no encryption.
nonisolated struct Zip {
    struct Entry: Equatable {
        var name: String
        var method: UInt16
        var compressedSize: Int
        var size: Int
        var localOffset: Int
    }

    let data: Data
    let entries: [Entry]

    init(_ data: Data) throws {
        self.data = data
        // The end of central directory record: its signature within the last 64 KB + 22 bytes.
        let tail = max(0, data.count - 65_557)
        guard let end = (tail..<max(tail, data.count - 21)).reversed().first(where: { Zip.u32(data, $0) == 0x0605_4B50 }) else {
            throw MemoryImport.Failure.unreadable
        }
        let count = Int(Zip.u16(data, end + 10))
        var offset = Int(Zip.u32(data, end + 16))
        guard offset != 0xFFFF_FFFF else { throw MemoryImport.Failure.tooLarge }
        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= data.count, Zip.u32(data, offset) == 0x0201_4B50 else { throw MemoryImport.Failure.unreadable }
            let method = Zip.u16(data, offset + 10)
            let compressed = Int(Zip.u32(data, offset + 20)), size = Int(Zip.u32(data, offset + 24))
            let nameLength = Int(Zip.u16(data, offset + 28)), extra = Int(Zip.u16(data, offset + 30)), comment = Int(Zip.u16(data, offset + 32))
            let local = Int(Zip.u32(data, offset + 42))
            guard offset + 46 + nameLength <= data.count else { throw MemoryImport.Failure.unreadable }
            let name = String(decoding: data[(data.startIndex + offset + 46)..<(data.startIndex + offset + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(name: name, method: method, compressedSize: compressed, size: size, localOffset: local))
            offset += 46 + nameLength + extra + comment
        }
        self.entries = entries
    }

    func contents(of entry: Entry, limit: Int) throws -> Data {
        guard entry.size <= limit, entry.compressedSize != 0xFFFF_FFFF else { throw MemoryImport.Failure.tooLarge }
        let local = entry.localOffset
        guard local + 30 <= data.count, Zip.u32(data, local) == 0x0403_4B50 else { throw MemoryImport.Failure.unreadable }
        let start = local + 30 + Int(Zip.u16(data, local + 26)) + Int(Zip.u16(data, local + 28))
        guard start + entry.compressedSize <= data.count else { throw MemoryImport.Failure.unreadable }
        let packed = data[(data.startIndex + start)..<(data.startIndex + start + entry.compressedSize)]
        switch entry.method {
        case 0: return Data(packed)
        case 8: return try Zip.inflate(Data(packed), size: entry.size)
        default: throw MemoryImport.Failure.unreadable
        }
    }

    static func inflate(_ packed: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) -> Int in
            packed.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, size,
                                          source.bindMemory(to: UInt8.self).baseAddress!, packed.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw MemoryImport.Failure.unreadable }
        return out
    }

    static func u16(_ data: Data, _ at: Int) -> UInt16 {
        guard at + 2 <= data.count else { return 0 }
        let i = data.startIndex + at
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }

    static func u32(_ data: Data, _ at: Int) -> UInt32 {
        guard at + 4 <= data.count else { return 0 }
        let i = data.startIndex + at
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }
}
