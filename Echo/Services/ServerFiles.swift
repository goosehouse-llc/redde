import Foundation
import UniformTypeIdentifiers

/// One entry of a folder on the Hermes host, as the Dashboard's file manager lists it
/// (`GET /api/files`, the same in Hermes 0.21.0, 0.21.3 and 0.21.5).
nonisolated struct ServerFile: Identifiable, Hashable, Sendable {
    var name: String
    /// Absolute, as the server resolved it.
    var path: String
    var isDirectory: Bool
    var size: Int?
    var modified: Date?
    var mimeType: String?

    var id: String { path }

    init(name: String, path: String, isDirectory: Bool, size: Int? = nil, modified: Date? = nil, mimeType: String? = nil) {
        self.name = name; self.path = path; self.isDirectory = isDirectory
        self.size = size; self.modified = modified; self.mimeType = mimeType
    }

    init?(_ json: JSONValue) {
        guard let path = json["path"]?.string, !path.isEmpty else { return nil }
        self.path = path
        name = json["name"]?.string?.nilIfEmpty ?? ServerFiles.name(of: path)
        isDirectory = json["is_directory"]?.bool ?? false
        size = json["size"]?.int
        modified = json["mtime"]?.number.map { Date(timeIntervalSince1970: $0) }
        mimeType = json["mime_type"]?.string
    }

    var isHidden: Bool { name.hasPrefix(".") }

    private var ext: String { (name as NSString).pathExtension.lowercased() }

    /// Written in words, by its type or its ending: what the text view can show and edit.
    var isText: Bool {
        guard !isDirectory else { return false }
        if let mimeType, mimeType.hasPrefix("text/") { return true }
        if ServerFiles.textEndings.contains(ext) { return true }
        if ["application/json", "application/xml", "application/x-yaml", "application/yaml", "application/toml", "application/x-sh",
            "application/javascript", "application/x-python-code"].contains(mimeType ?? "") { return true }
        // No ending at all, and nothing the server could name: a README, a Makefile, a dotfile.
        return ext.isEmpty && (mimeType == nil || mimeType == "application/octet-stream") && (size ?? 0) <= ServerFiles.textLimit
            && ServerFiles.textNames.contains(name.lowercased())
    }

    /// Opens in the text view: text, and no more of it than Hermes reads whole.
    var opensAsText: Bool { isText && (size ?? 0) <= ServerFiles.textLimit }

    var symbol: String {
        if isDirectory { return "folder" }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return "photo" }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
            if type.conforms(to: .audio) { return "waveform" }
            if type.conforms(to: .pdf) { return "doc.richtext" }
            if type.conforms(to: .archive) { return "doc.zipper" }
        }
        return isText ? "doc.text" : "doc"
    }

    /// "12 KB · Oct 3, 2026" for a file; the date alone for a folder.
    func detail(now: Date = .now) -> String {
        var parts: [String] = []
        if !isDirectory, let size { parts.append(ServerFiles.size(size)) }
        if let modified {
            let sameYear = Calendar.current.isDate(modified, equalTo: now, toGranularity: .year)
            parts.append(modified.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year()))
        }
        return parts.joined(separator: " · ")
    }
}

/// A folder on the Hermes host and what is in it.
nonisolated struct ServerFolder: Equatable, Sendable {
    var path: String
    var parent: String?
    /// Folders first, then by name, as the server sorts them.
    var entries: [ServerFile]
    /// Set where the server keeps its file manager inside one folder (a hosted install, or
    /// `HERMES_DASHBOARD_FILES_ROOT`): nothing above it can be opened.
    var lockedRoot: String?

    init(path: String, parent: String? = nil, entries: [ServerFile] = [], lockedRoot: String? = nil) {
        self.path = path; self.parent = parent; self.entries = entries; self.lockedRoot = lockedRoot
    }

    init(_ json: JSONValue) throws {
        guard let path = json["path"]?.string, !path.isEmpty else { throw TransportError.malformed("the folder has no path") }
        self.path = path
        parent = json["parent"]?.string?.nilIfEmpty
        entries = (json["entries"]?.array ?? []).compactMap(ServerFile.init)
        lockedRoot = (json["locked_root"] ?? json["root"])?.string?.nilIfEmpty
    }

    var name: String { ServerFiles.name(of: path) }

    func entry(named name: String) -> ServerFile? { entries.first { $0.name == name } }

    /// What the list shows: without dotfiles unless asked for, and by a search of the names.
    func shown(hidden: Bool, matching search: String = "") -> [ServerFile] {
        let wanted = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { (hidden || !$0.isHidden) && (wanted.isEmpty || $0.name.localizedCaseInsensitiveContains(wanted)) }
    }
}

/// A text file as Hermes reads it for an editor (`GET /api/fs/read-text`).
nonisolated struct ServerText: Equatable, Sendable {
    var text: String
    /// Only the first part was read: more than Hermes hands an editor.
    var truncated = false
    /// Not text after all, by its first bytes.
    var binary = false

    /// All of it and all words: only then can it be changed and saved back.
    var canEdit: Bool { !truncated && !binary }
}

nonisolated enum ServerFiles {
    /// The most Hermes takes or gives as one file through its file manager.
    static let largest = 100 * 1024 * 1024
    /// The most of a text file Hermes reads for an editor; past it the text comes back cut short.
    static let textLimit = 512 * 1024

    static let textEndings: Set<String> = [
        "txt", "md", "markdown", "rst", "log", "json", "jsonl", "yaml", "yml", "toml", "ini", "conf", "cfg", "env", "csv", "tsv", "xml",
        "html", "htm", "css", "js", "mjs", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "swift", "kt", "java", "c", "h", "cpp", "hpp", "m",
        "sh", "zsh", "bash", "fish", "sql", "lua", "php", "pl", "r", "tex", "srt", "vtt", "diff", "patch", "plist", "service", "lock",
    ]
    static let textNames: Set<String> = ["readme", "license", "licence", "makefile", "dockerfile", "changelog", "notes", "todo", "authors", "procfile",
                                         ".gitignore", ".gitattributes", ".dockerignore", ".editorconfig", ".zshrc", ".bashrc", ".profile"]

    static func name(of path: String) -> String {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed == "/" ? "/" : (trimmed as NSString).lastPathComponent
    }

    /// `name` inside `folder`.
    static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    /// A name a file or a folder can be given, or nil: nothing, a path, or a way back up.
    static func usableName(_ typed: String) -> String? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"), name.utf8.count <= 255 else { return nil }
        return name
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// A refusal in the screen's words; the server's own, or the error's, where there is no
    /// better way to say it.
    static func explain(_ error: Error) -> String {
        guard case let TransportError.http(status, body) = error else { return error.localizedDescription }
        switch status {
        case 403 where body.localizedCaseInsensitiveContains("sensitive"): return "Hermes doesn't hand this one out: it holds credentials."
        case 403 where body.localizedCaseInsensitiveContains("outside"): return "That is outside the folder this server keeps its file manager to."
        case 403: return "Hermes isn't allowed to do that there. (\(body))"
        case 404: return "It isn't there any more."
        case 409 where body.localizedCaseInsensitiveContains("already exists"): return "Something with that name is already there."
        case 409: return "It couldn't be removed. (\(body))"
        case 413: return "Too large: Hermes takes and gives at most \(size(largest)) as one file."
        case 401: return "The Hermes Dashboard login was refused."
        default: return body.isEmpty ? "The server answered \(status)." : body
        }
    }

    // MARK: An upload's body

    /// Writes the multipart form `POST /api/files/upload-stream` takes (the destination, whether
    /// to replace, then the file) to a file of its own, copying `source` through in pieces so a
    /// large one is never in memory. Returns that file and the Content-Type that names its
    /// boundary; the caller removes the file.
    static func uploadForm(for source: URL, to destination: String, replacing: Bool,
                           boundary: String = "redde-\(UUID().uuidString)") throws -> (file: URL, contentType: String) {
        let form = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString).form")
        guard FileManager.default.createFile(atPath: form.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let out = try FileHandle(forWritingTo: form)
        defer { try? out.close() }
        func field(_ name: String, _ value: String) throws {
            try out.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        do {
            try field("path", destination)
            try field("overwrite", replacing ? "true" : "false")
            // A quote or a line break in a name would end the header early.
            let safe = name(of: destination).replacingOccurrences(of: "\"", with: "%22")
                .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            try out.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safe)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            while let piece = try input.read(upToCount: 1 << 20), !piece.isEmpty { try out.write(contentsOf: piece) }
            try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        } catch {
            try? FileManager.default.removeItem(at: form)
            throw error
        }
        return (form, "multipart/form-data; boundary=\(boundary)")
    }

    /// Where a download is kept for looking at: a folder of its own, so the file keeps its name.
    static func localCopy(named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "server-files/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: usableName(name) ?? "file")
    }

    /// Downloads kept for looking at are thrown away when the browser is opened again.
    static func clearLocalCopies() {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appending(path: "server-files"))
    }
}

/// How far a transfer has got, heard from the URL session as it goes.
nonisolated final class TransferWatch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Progress?

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.lock(); progress = task.progress; lock.unlock()
    }

    /// From 0 to 1, or nil while the size isn't known.
    var fraction: Double? {
        lock.lock(); defer { lock.unlock() }
        guard let progress, progress.totalUnitCount > 0 else { return nil }
        return min(1, max(0, progress.fractionCompleted))
    }
}

/// What the file browser asks of a server. `HermesServeClient` in the app; a made-up tree for
/// the screen's own look and its UI test.
protocol ServerFileBrowsing: AnyObject {
    /// The folder at `path`; nil is where the server starts (its user's home, or its one folder).
    func folder(at path: String?) async throws -> ServerFolder
    /// Fetches a file to this iPhone and returns where it is, under its own name.
    func download(_ file: ServerFile, watch: TransferWatch?) async throws -> URL
    func upload(_ local: URL, as name: String, into folder: String, replacing: Bool, watch: TransferWatch?) async throws -> ServerFile
    func makeFolder(_ name: String, in folder: String) async throws -> ServerFile
    /// Removes a file, or a folder with everything in it.
    func delete(_ file: ServerFile) async throws
    func text(of file: ServerFile) async throws -> ServerText
    func write(_ text: String, to file: ServerFile) async throws
}

extension HermesServeClient: ServerFileBrowsing {
    private static func query(_ route: String, path: String?) -> String {
        guard let path else { return route }
        var comps = URLComponents()
        comps.path = route
        comps.queryItems = [.init(name: "path", value: path)]
        // "+" in a query means a space to the server: a name with one has to say so.
        return comps.string?.replacingOccurrences(of: "+", with: "%2B") ?? route
    }

    func folder(at path: String?) async throws -> ServerFolder {
        try ServerFolder(try await restJSON("GET", Self.query("api/files", path: path)))
    }

    func download(_ file: ServerFile, watch: TransferWatch?) async throws -> URL {
        let fetched = try await restDownload(Self.query("api/files/download", path: file.path), watch: watch)
        let copy = try ServerFiles.localCopy(named: file.name)
        try FileManager.default.moveItem(at: fetched, to: copy)
        return copy
    }

    func upload(_ local: URL, as name: String, into folder: String, replacing: Bool, watch: TransferWatch?) async throws -> ServerFile {
        let destination = ServerFiles.join(folder, name)
        let (form, contentType) = try ServerFiles.uploadForm(for: local, to: destination, replacing: replacing)
        defer { try? FileManager.default.removeItem(at: form) }
        let answer = try await restUpload("api/files/upload-stream", bodyFile: form, contentType: contentType, watch: watch)
        return answer["entry"].flatMap(ServerFile.init) ?? ServerFile(name: name, path: destination, isDirectory: false)
    }

    func makeFolder(_ name: String, in folder: String) async throws -> ServerFile {
        let path = ServerFiles.join(folder, name)
        let answer = try await restJSON("POST", "api/files/mkdir", body: .object(["path": .string(path)]))
        return answer["entry"].flatMap(ServerFile.init) ?? ServerFile(name: name, path: path, isDirectory: true)
    }

    func delete(_ file: ServerFile) async throws {
        _ = try await restJSON("DELETE", "api/files", body: .object(["path": .string(file.path), "recursive": .bool(file.isDirectory)]))
    }

    func text(of file: ServerFile) async throws -> ServerText {
        let answer = try await restJSON("GET", Self.query("api/fs/read-text", path: file.path))
        return ServerText(text: answer["text"]?.string ?? "", truncated: answer["truncated"]?.bool ?? false, binary: answer["binary"]?.bool ?? false)
    }

    func write(_ text: String, to file: ServerFile) async throws {
        try await writeText(path: file.path, content: text)
    }
}

#if DEBUG
/// A server's folders made of sample data, for the file browser's own look (`-echo.demoFiles`)
/// and its UI test: a home with a few folders, text to open and change, and room to upload,
/// make folders and delete. Nothing leaves the phone.
final class DemoServerFiles: ServerFileBrowsing {
    static let home = "/home/redde"
    private var files: [String: Data] = [:]
    private var folders: Set<String> = []
    private let stamp = Date(timeIntervalSince1970: 1_790_000_000)

    init() {
        for folder in ["", "/Documents", "/Documents/Reports", "/projects", "/projects/blog", "/.hermes", "/.hermes/memories"] {
            folders.insert(Self.home + folder)
        }
        let texts: [String: String] = [
            "/notes.md": "# Notes\n\n- Renew the domain in March\n- Ask about the feed\n",
            "/Documents/budget.csv": "month,spend\nJanuary,412\nFebruary,388\n",
            "/Documents/Reports/october.md": "# October\n\nThe import finished; the image links are fixed.\n",
            "/projects/blog/README.md": "# Blog\n\nStatic site, built on push.\n",
            "/projects/blog/deploy.sh": "#!/bin/sh\nset -e\nhugo --minify\nrsync -a public/ web:/srv/blog/\n",
            "/.hermes/SOUL.md": "You are Redde: brief, exact, kind.\n",
            "/.hermes/memories/MEMORY.md": "- The blog moved to the new site in October.\n",
        ]
        for (path, text) in texts { files[Self.home + path] = Data(text.utf8) }
        files[Self.home + "/Documents/scan.pdf"] = Data(count: 48_200)
        files[Self.home + "/photo.jpg"] = Data(count: 1_240_000)
    }

    private func entry(_ path: String) -> ServerFile? {
        if folders.contains(path) { return ServerFile(name: ServerFiles.name(of: path), path: path, isDirectory: true, modified: stamp) }
        guard let data = files[path] else { return nil }
        let name = ServerFiles.name(of: path)
        return ServerFile(name: name, path: path, isDirectory: false, size: data.count, modified: stamp,
                          mimeType: UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType)
    }

    private func missing() -> Error { TransportError.http(status: 404, body: "Path not found") }

    func folder(at path: String?) async throws -> ServerFolder {
        var path = path ?? Self.home
        if path.hasPrefix("~") { path = Self.home + path.dropFirst() }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard folders.contains(path) else { throw missing() }
        let inside = (Array(folders) + Array(files.keys)).filter { ($0 as NSString).deletingLastPathComponent == path && $0 != path }
        let entries = inside.compactMap(entry).sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
        return ServerFolder(path: path, parent: path == "/" ? nil : (path as NSString).deletingLastPathComponent, entries: entries)
    }

    func download(_ file: ServerFile, watch: TransferWatch?) async throws -> URL {
        guard let data = files[file.path] else { throw missing() }
        let copy = try ServerFiles.localCopy(named: file.name)
        try data.write(to: copy)
        return copy
    }

    func upload(_ local: URL, as name: String, into folder: String, replacing: Bool, watch: TransferWatch?) async throws -> ServerFile {
        let path = ServerFiles.join(folder, name)
        guard folders.contains(folder) else { throw missing() }
        if files[path] != nil, !replacing { throw TransportError.http(status: 409, body: "File already exists") }
        files[path] = try Data(contentsOf: local)
        return try entry(path) ?? { throw missing() }()
    }

    func makeFolder(_ name: String, in folder: String) async throws -> ServerFile {
        let path = ServerFiles.join(folder, name)
        if files[path] != nil { throw TransportError.http(status: 409, body: "A file already exists at that path") }
        folders.insert(path)
        return ServerFile(name: name, path: path, isDirectory: true, modified: stamp)
    }

    func delete(_ file: ServerFile) async throws {
        guard folders.contains(file.path) || files[file.path] != nil else { throw missing() }
        folders = folders.filter { $0 != file.path && !$0.hasPrefix(file.path + "/") }
        files = files.filter { $0.key != file.path && !$0.key.hasPrefix(file.path + "/") }
    }

    func text(of file: ServerFile) async throws -> ServerText {
        guard let data = files[file.path] else { throw missing() }
        return ServerText(text: String(decoding: data, as: UTF8.self))
    }

    func write(_ text: String, to file: ServerFile) async throws {
        files[file.path] = Data(text.utf8)
    }
}
#endif
