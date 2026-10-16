import Foundation

/// Where a new conversation starts: a project's name and its folder on the server.
nonisolated struct ProjectPlace: Equatable, Sendable {
    var name: String
    var path: String
}

/// Projects as Redde makes them on the Dashboard: Hermes's own named projects (`projects.create`,
/// the list Hermes Desktop shows; the same in Hermes 0.21.0, 0.21.3 and 0.21.5), each over a folder
/// of its own in the server's Projects folder. A conversation is in a project when its working
/// folder is the project's, so a project's conversations share that folder: what the agent makes
/// there stays with the project.
extension HermesServeClient {
    nonisolated enum ProjectError: LocalizedError {
        case noName
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .noName: "Give the project a name."
            case let .refused(why): why
            }
        }
    }

    /// Makes the project's folder, `~/Projects/<name>` on the server (or `<root>/<name>`), if it
    /// isn't there, and the project over it. A folder that's there already, a repository say, is
    /// used as it is. The home is the one the server's file manager starts in: a hosted install
    /// that keeps its files to one folder gets its Projects folder inside that one.
    func createProject(named name: String, under root: String? = nil) async throws -> ProjectPlace {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let folderName = Self.projectFolderName(for: name) else { throw ProjectError.noName }
        let parent: String
        if let root { parent = root } else { parent = ServerFiles.join(try await folder(at: nil).path, "Projects") }
        let made = try await makeFolder(folderName, in: parent)
        try await ensureConnected()
        let result: JSONValue
        do {
            result = try await call("projects.create", params: .object([
                "name": .string(name), "folders": .array([.string(made.path)]), "primary_path": .string(made.path)]))
        } catch let error as RPCError where error.message.contains("already belongs to project") {
            throw ProjectError.refused("\(made.path) is already a project's folder. Its conversations are under that project.")
        }
        let project = result["project"]
        return ProjectPlace(name: project?["name"]?.string ?? name, path: project?["primary_path"]?.string ?? made.path)
    }

    /// A new name for a project. Its folder keeps the one it has: the conversations in it work there.
    func renameProject(_ id: String, to name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectError.noName }
        try await ensureConnected()
        _ = try await call("projects.update", params: .object(["id": .string(id), "name": .string(name)]))
    }

    /// Takes a project off Hermes's list. Its folder and its conversations stay on the server;
    /// the conversations are no longer grouped under it.
    func removeProject(_ id: String) async throws {
        try await ensureConnected()
        _ = try await call("projects.delete", params: .object(["id": .string(id)]))
    }

    /// The folder a project's name makes: the name as typed, less what a path can't hold (a
    /// slash, a colon, a line break) and a leading dot, which would hide it. Nil when nothing is left.
    nonisolated static func projectFolderName(for name: String) -> String? {
        var folder = name.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        while folder.hasPrefix(".") { folder.removeFirst() }
        folder = String(folder.trimmingCharacters(in: .whitespaces).prefix(80))
        return folder.isEmpty ? nil : folder
    }
}
