import Foundation

/// The files tools: one folder, Redde's own in the Files app ("On My iPhone › Redde"), which is
/// the only place on the phone an app may read and write without the person picking each file.
/// Put something there and the agent can read it; what the agent saves there is in Files.
/// A path that tries to leave the folder is refused.
nonisolated struct DeviceFiles: Sendable {
    /// The folder. The app's Documents folder, which Info.plist shows in Files.
    var root: URL = .documentsDirectory

    /// The most text a read hands over as text, and the largest other file it hands over at all:
    /// a file goes to the server inside one command, and 450 KB is what that has been seen to
    /// carry on Hermes 0.21.0, 0.21.3 and 0.21.5 (`lab.sh device`).
    static let mostText = 200_000
    static let mostBytes = 450_000

    /// `path` inside the folder, as a place on disk. Nil for one that isn't inside it.
    func resolve(_ path: String) -> URL? {
        let cleaned = path.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleaned.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        let url = (cleaned.isEmpty ? root : root.appending(path: cleaned)).standardizedFileURL
        let base = root.standardizedFileURL.path
        return url.path == base || url.path.hasPrefix(base.hasSuffix("/") ? base : base + "/") ? url : nil
    }

    private func place(_ args: JSONValue, _ name: String = "path", required: Bool) throws -> URL {
        let path = args[name]?.string ?? ""
        if required, path.trimmingCharacters(in: CharacterSet(charactersIn: " /")).isEmpty { throw DeviceToolError.missing(name) }
        guard let url = resolve(path) else { throw DeviceToolError("That path leaves Redde's folder. Paths are inside it, like notes/list.txt.") }
        return url
    }

    /// `path` (a folder inside; the top without it).
    func list(_ args: JSONValue) throws -> JSONValue {
        let folder = try place(args, required: false)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else { throw DeviceToolError("There is no folder at that path.") }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let entries = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return .object(["folder": .string(relative(folder)), "entries": .array(entries.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            var fields: [String: JSONValue] = ["name": .string(url.lastPathComponent), "kind": .string(values?.isDirectory == true ? "folder" : "file")]
            if values?.isDirectory != true, let size = values?.fileSize { fields["bytes"] = .number(Double(size)) }
            if let changed = values?.contentModificationDate { fields["modified"] = .string(DeviceDates.string(changed)) }
            return .object(fields)
        })])
    }

    /// `path`: text comes back as text, anything else as the file itself.
    func read(_ args: JSONValue) throws -> JSONValue {
        let file = try place(args, required: true)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder) else { throw DeviceToolError("There is no file at that path.") }
        guard !isFolder.boolValue else { throw DeviceToolError("That is a folder: list it.") }
        guard let data = try? Data(contentsOf: file) else { throw DeviceToolError("The file couldn't be read.") }
        if data.count <= Self.mostText, let text = String(data: data, encoding: .utf8) {
            return .object(["path": .string(relative(file)), "text": .string(text)])
        }
        guard data.count <= Self.mostBytes else {
            throw DeviceToolError("The file is \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)): too large to hand over.")
        }
        return .object(["path": .string(relative(file)), "file": .object(["name": .string(file.lastPathComponent), "base64": .string(data.base64EncodedString())])])
    }

    /// `path`, `text`. Folders on the way are made; a file already there is replaced.
    func write(_ args: JSONValue) throws -> JSONValue {
        let file = try place(args, required: true)
        guard let text = args["text"]?.string else { throw DeviceToolError.missing("text") }
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder), isFolder.boolValue { throw DeviceToolError("There is a folder at that path.") }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file, options: .atomic)
        } catch {
            throw DeviceToolError("The file couldn't be saved: \(error.localizedDescription)")
        }
        return .object(["saved": .string(relative(file)), "bytes": .number(Double(text.utf8.count)), "where": .string("Files › On My iPhone › Redde")])
    }

    /// `path`: a file, or a folder with what is in it. Never the folder itself.
    func delete(_ args: JSONValue) throws -> JSONValue {
        let target = try place(args, required: true)
        guard target.standardizedFileURL.path != root.standardizedFileURL.path else { throw DeviceToolError.missing("path") }
        guard FileManager.default.fileExists(atPath: target.path) else { throw DeviceToolError("There is nothing at that path.") }
        do { try FileManager.default.removeItem(at: target) } catch { throw DeviceToolError("It couldn't be deleted: \(error.localizedDescription)") }
        return .object(["deleted": .string(relative(target))])
    }

    private func relative(_ url: URL) -> String {
        let base = root.standardizedFileURL.path, path = url.standardizedFileURL.path
        return path == base ? "" : String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
