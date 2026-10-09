import Foundation
import Testing
@testable import Echo

/// The file browser: what the Dashboard's file manager says read into the app's own terms, the
/// requests made of it, an upload's body, and the folder model's handling of the things done
/// from the screen. `scripts/hermes-lab/lab.sh files` checks the same calls on real Hermes.
@Suite(.serialized)
struct ServerFilesTests {
    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    private func temp(_ name: String, _ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "files-test-\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        return url
    }

    // MARK: Reading what the server says

    @Test func aFolderIsReadAsTheServerListsIt() throws {
        let folder = try ServerFolder(try json(#"""
        {"path": "/home/redde/Documents", "parent": "/home/redde", "root": null, "locked_root": null, "can_change_path": true,
         "entries": [
           {"name": "Reports", "path": "/home/redde/Documents/Reports", "is_directory": true, "size": null, "mtime": 1790000000.5, "mime_type": null},
           {"name": ".drafts", "path": "/home/redde/Documents/.drafts", "is_directory": true, "size": null, "mtime": 1790000000, "mime_type": null},
           {"name": "budget.csv", "path": "/home/redde/Documents/budget.csv", "is_directory": false, "size": 412, "mtime": 1790000100, "mime_type": "text/csv"},
           {"name": "scan.pdf", "path": "/home/redde/Documents/scan.pdf", "is_directory": false, "size": 48200, "mtime": 1790000200, "mime_type": "application/pdf"},
           {"path": ""}, {"name": "no path"}
         ]}
        """#))
        #expect(folder.path == "/home/redde/Documents" && folder.parent == "/home/redde" && folder.lockedRoot == nil)
        #expect(folder.name == "Documents")
        #expect(folder.entries.map(\.name) == ["Reports", ".drafts", "budget.csv", "scan.pdf"], "entries without a path are no entries")
        let reports = try #require(folder.entry(named: "Reports"))
        #expect(reports.isDirectory && reports.size == nil && reports.modified == Date(timeIntervalSince1970: 1_790_000_000.5))
        let budget = try #require(folder.entry(named: "budget.csv"))
        #expect(!budget.isDirectory && budget.size == 412 && budget.mimeType == "text/csv" && budget.id == budget.path)

        // Dotfiles stay out unless asked for; a search goes by name, in whatever case.
        #expect(folder.shown(hidden: false).map(\.name) == ["Reports", "budget.csv", "scan.pdf"])
        #expect(folder.shown(hidden: true).count == 4)
        #expect(folder.shown(hidden: false, matching: " SCAN ").map(\.name) == ["scan.pdf"])
        #expect(folder.shown(hidden: false, matching: "drafts").isEmpty)
        #expect(folder.shown(hidden: true, matching: "drafts").map(\.name) == [".drafts"])

        // A server that keeps its file manager to one folder says which.
        let locked = try ServerFolder(try json(#"{"path": "/opt/data", "parent": null, "entries": [], "root": "/opt/data", "locked_root": "/opt/data", "can_change_path": false}"#))
        #expect(locked.lockedRoot == "/opt/data" && locked.parent == nil && locked.entries.isEmpty)
        #expect(throws: (any Error).self) { try ServerFolder(try json(#"{"entries": []}"#)) }
    }

    @Test func aFileIsKnownForTextByItsTypeOrItsEnding() {
        func file(_ name: String, _ mime: String? = nil, size: Int = 100) -> ServerFile {
            ServerFile(name: name, path: "/x/\(name)", isDirectory: false, size: size, mimeType: mime)
        }
        for text in [file("notes.md", "text/markdown"), file("deploy.sh", "application/x-sh"), file("config.yaml", "application/octet-stream"),
                     file("data.json", "application/json"), file("main.swift"), file("README"), file("Makefile", "application/octet-stream"),
                     file(".gitignore"), file("agent.log", "text/plain")] {
            #expect(text.isText && text.opensAsText, "\(text.name)")
        }
        for other in [file("photo.jpg", "image/jpeg"), file("scan.pdf", "application/pdf"), file("archive.zip", "application/zip"),
                      file("blob", "application/octet-stream"), file("movie.mp4", "video/mp4")] {
            #expect(!other.isText && !other.opensAsText, "\(other.name)")
        }
        // Text, but more of it than Hermes reads for an editor: downloaded, not opened as text.
        let long = file("huge.log", "text/plain", size: ServerFiles.textLimit + 1)
        #expect(long.isText && !long.opensAsText)
        #expect(!ServerFile(name: "notes.md", path: "/x/notes.md", isDirectory: true).isText)

        #expect(file("photo.jpg").symbol == "photo" && file("movie.mp4").symbol == "film" && file("song.mp3").symbol == "waveform")
        #expect(file("scan.pdf").symbol == "doc.richtext" && file("archive.zip").symbol == "doc.zipper")
        #expect(file("notes.md").symbol == "doc.text" && file("blob").symbol == "doc")
        #expect(ServerFile(name: "Documents", path: "/x/Documents", isDirectory: true).symbol == "folder")
        #expect(file(".env").isHidden && !file("env").isHidden)
    }

    @Test func aRowSaysHowBigAndHowOld() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let recent = ServerFile(name: "a.txt", path: "/a.txt", isDirectory: false, size: 12_000, modified: now.addingTimeInterval(-86_400 * 3))
        #expect(recent.detail(now: now).hasPrefix(ServerFiles.size(12_000) + " · "))
        #expect(!recent.detail(now: now).contains("2026"), "this year needs no year")
        let old = ServerFile(name: "b.txt", path: "/b.txt", isDirectory: false, size: 5, modified: now.addingTimeInterval(-86_400 * 500))
        #expect(old.detail(now: now).contains("2025"))
        let folder = ServerFile(name: "d", path: "/d", isDirectory: true, modified: now)
        #expect(!folder.detail(now: now).contains("·"), "a folder has a date and no size")
        #expect(ServerFile(name: "c", path: "/c", isDirectory: false).detail(now: now).isEmpty)
    }

    @Test func namesAndPaths() {
        #expect(ServerFiles.name(of: "/home/redde/Documents") == "Documents")
        #expect(ServerFiles.name(of: "/home/redde/Documents/") == "Documents")
        #expect(ServerFiles.name(of: "/") == "/")
        #expect(ServerFiles.join("/home/redde", "a b.txt") == "/home/redde/a b.txt")
        #expect(ServerFiles.join("/", "etc") == "/etc")
        #expect(ServerFiles.usableName("  notes.md ") == "notes.md")
        #expect(ServerFiles.usableName("Photo 2026-10-08 19.30.12.jpg") == "Photo 2026-10-08 19.30.12.jpg")
        for bad in ["", "   ", ".", "..", "a/b", "/etc", String(repeating: "x", count: 256)] {
            #expect(ServerFiles.usableName(bad) == nil, "\(bad.prefix(12))")
        }
    }

    @Test func refusalsAreSaidInTheScreensWords() {
        func said(_ status: Int, _ body: String) -> String { ServerFiles.explain(TransportError.http(status: status, body: body)) }
        #expect(said(403, "Access to sensitive files is not allowed") == "Hermes doesn't hand this one out: it holds credentials.")
        #expect(said(403, "Path outside managed files root").contains("outside the folder"))
        #expect(said(403, "File is not writable").contains("File is not writable"))
        #expect(said(404, "Path not found") == "It isn't there any more.")
        #expect(said(409, "File already exists") == "Something with that name is already there.")
        #expect(said(409, "Could not delete path: [Errno 66] Directory not empty").contains("Directory not empty"))
        #expect(said(413, "File is too large").contains("at most"))
        #expect(said(500, "Could not read directory: boom") == "Could not read directory: boom")
        #expect(said(502, "") == "The server answered 502.")
        #expect(ServerFiles.explain(URLError(.timedOut)) == URLError(.timedOut).localizedDescription)
    }

    // MARK: An upload's body

    @Test func anUploadIsAFormWrittenToAFile() throws {
        let source = try temp("a.bin", Data([0x00, 0xFF, 0x0D, 0x0A, 0x2D, 0x2D]))
        let (form, contentType) = try ServerFiles.uploadForm(for: source, to: "/srv/in/say \"hi\".bin", replacing: false, boundary: "B")
        defer { try? FileManager.default.removeItem(at: form) }
        #expect(contentType == "multipart/form-data; boundary=B")
        var expected = Data("--B\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n/srv/in/say \"hi\".bin\r\n".utf8)
        expected += Data("--B\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\nfalse\r\n".utf8)
        expected += Data("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"say %22hi%22.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        expected += Data([0x00, 0xFF, 0x0D, 0x0A, 0x2D, 0x2D])
        expected += Data("\r\n--B--\r\n".utf8)
        #expect(try Data(contentsOf: form) == expected)

        let replacing = try ServerFiles.uploadForm(for: source, to: "/a.bin", replacing: true, boundary: "B")
        defer { try? FileManager.default.removeItem(at: replacing.file) }
        #expect(String(decoding: try Data(contentsOf: replacing.file), as: UTF8.self).contains("name=\"overwrite\"\r\n\r\ntrue\r\n"))
        // A source that can't be read leaves no form behind.
        #expect(throws: (any Error).self) { try ServerFiles.uploadForm(for: URL(fileURLWithPath: "/no/such/file"), to: "/a", replacing: false) }
    }

    // MARK: The requests

    private func client() -> HermesServeClient {
        let settings = Settings(defaults: UserDefaults(suiteName: "files-\(UUID().uuidString)")!)
        settings.serveURL = "http://serve.test:9119"
        settings.serveUsername = "redde"
        return HermesServeClient(settings: settings, password: { "hunter2" }, tokens: HermesServeClientTests.TokenBox().store, protocolClasses: [ServeStub.self])
    }

    @Test func eachThingAsksTheDashboardsFileManager() async throws {
        ServeStub.reset()
        defer { ServeStub.reset() }
        nonisolated(unsafe) var asked: [(String, String, String)] = []   // method, path with query, body
        ServeStub.handler = { request, body in
            let url = request.url!
            let route = url.path() + (url.query(percentEncoded: true).map { "?\($0)" } ?? "")
            if url.path() != "/auth/password-login" { asked.append((request.httpMethod ?? "", route, String(decoding: body ?? Data(), as: UTF8.self))) }
            switch (request.httpMethod, url.path()) {
            case ("POST", "/auth/password-login"): return (200, Data("{}".utf8))
            case ("GET", "/api/files"):
                return (200, Data(#"{"path":"/home/redde/a b+c","parent":"/home/redde","entries":[],"root":null,"locked_root":null,"can_change_path":true}"#.utf8))
            case ("GET", "/api/files/download"):
                return url.query()?.contains("big") == true ? (413, Data(#"{"detail":"File is too large"}"#.utf8)) : (200, Data("the bytes".utf8))
            case ("POST", "/api/files/upload-stream"):
                return (200, Data(#"{"ok":true,"entry":{"name":"up.txt","path":"/home/redde/up.txt","is_directory":false,"size":9,"mtime":1790000000,"mime_type":"text/plain"}}"#.utf8))
            case ("POST", "/api/files/mkdir"):
                return (200, Data(#"{"ok":true,"entry":{"name":"New","path":"/home/redde/New","is_directory":true,"size":null,"mtime":1790000000,"mime_type":null}}"#.utf8))
            case ("DELETE", "/api/files"): return (200, Data(#"{"ok":true}"#.utf8))
            case ("GET", "/api/fs/read-text"): return (200, Data(#"{"text":"hello","truncated":true,"binary":false,"byteSize":900000}"#.utf8))
            case ("POST", "/api/fs/write-text"): return (200, Data(#"{"ok":true}"#.utf8))
            default: return (404, Data(#"{"detail":"Path not found"}"#.utf8))
            }
        }
        let client = client()

        // Where the server starts has no path; a name with a space and a plus keeps both.
        _ = try await client.folder(at: nil)
        #expect(asked.last?.1 == "/api/files")
        let folder = try await client.folder(at: "/home/redde/a b+c")
        #expect(asked.last?.1 == "/api/files?path=/home/redde/a%20b%2Bc")
        #expect(folder.path == "/home/redde/a b+c")

        let file = ServerFile(name: "notes.md", path: "/home/redde/notes.md", isDirectory: false, size: 9)
        let copy = try await client.download(file, watch: nil)
        #expect(asked.last?.1 == "/api/files/download?path=/home/redde/notes.md")
        #expect(try Data(contentsOf: copy) == Data("the bytes".utf8) && copy.lastPathComponent == "notes.md")
        // A refusal isn't taken for the file.
        let big = ServerFile(name: "big.iso", path: "/home/redde/big.iso", isDirectory: false)
        let refused = await #expect(throws: TransportError.self) { _ = try await client.download(big, watch: nil) }
        #expect(refused.map(ServerFiles.explain)?.contains("at most") == true)

        let up = try await client.upload(try temp("up.txt", Data("nine byte".utf8)), as: "up.txt", into: "/home/redde", replacing: true, watch: nil)
        #expect(up.path == "/home/redde/up.txt" && up.size == 9)
        let form = try #require(asked.last)
        #expect(form.0 == "POST" && form.1 == "/api/files/upload-stream")
        #expect(form.2.contains("name=\"path\"\r\n\r\n/home/redde/up.txt\r\n") && form.2.contains("name=\"overwrite\"\r\n\r\ntrue\r\n")
            && form.2.contains("filename=\"up.txt\"") && form.2.contains("\r\n\r\nnine byte\r\n--"))

        let made = try await client.makeFolder("New", in: "/home/redde")
        #expect(made.isDirectory && asked.last?.1 == "/api/files/mkdir")
        #expect(try json(asked.last?.2 ?? "")["path"]?.string == "/home/redde/New")

        try await client.delete(made)
        #expect(asked.last?.0 == "DELETE" && asked.last?.1 == "/api/files")
        #expect(try json(asked.last?.2 ?? "") == .object(["path": .string("/home/redde/New"), "recursive": .bool(true)]), "a folder goes with what is in it")
        try await client.delete(file)
        #expect(try json(asked.last?.2 ?? "")["recursive"]?.bool == false)

        let text = try await client.text(of: file)
        #expect(text == ServerText(text: "hello", truncated: true) && !text.canEdit, "text cut short can be read, not saved")
        try await client.write("changed", to: file)
        #expect(try json(asked.last?.2 ?? "") == .object(["path": .string("/home/redde/notes.md"), "content": .string("changed")]))
    }

    // MARK: The folder's model

    private func outgoing(_ name: String, _ text: String) throws -> ServerFolderModel.Outgoing {
        .init(local: try temp(name, Data(text.utf8)), name: name)
    }

    @Test func uploadsGoUpAndOneThatWouldReplaceIsAskedAbout() async throws {
        let server = DemoServerFiles()
        let model = ServerFolderModel(path: nil, browser: server)
        #expect(model.phase == .loading)
        await model.load()
        #expect(model.phase == .loaded && model.folder?.path == DemoServerFiles.home)
        #expect(model.folder?.entries.map(\.name) == [".hermes", "Documents", "projects", "notes.md", "photo.jpg"], "folders first, then by name")

        await model.upload([try outgoing("todo.txt", "one\n"), try outgoing("notes.md", "REPLACED\n"),
                            .init(local: try temp("x.txt", Data("x".utf8)), name: "a/b.txt")])
        #expect(model.folder?.entry(named: "todo.txt")?.size == 4, "the new file is there")
        #expect(model.wouldReplace.map(\.name) == ["notes.md"], "the one that is there already waits")
        #expect(model.problem?.contains("a/b.txt") == true, "a name with a slash is no name")
        let notes = try #require(model.folder?.entry(named: "notes.md"))
        #expect(try await server.text(of: notes).text.hasPrefix("# Notes"), "nothing was replaced unasked")

        // No: it stays as it was. Asked again and yes: it is replaced.
        await model.replace(false)
        #expect(model.wouldReplace.isEmpty)
        #expect(try await server.text(of: notes).text.hasPrefix("# Notes"))
        model.problem = nil
        await model.upload([try outgoing("notes.md", "REPLACED\n")])
        await model.replace(true)
        #expect(try await server.text(of: notes).text == "REPLACED\n")
        #expect(model.problem == nil && !model.isBusy && model.progress == nil)
    }

    @Test func aFileLargerThanHermesTakesIsNotSent() async throws {
        let model = ServerFolderModel(path: nil, browser: DemoServerFiles())
        await model.load()
        // A file of that size without writing it out: only its length is set.
        let big = FileManager.default.temporaryDirectory.appending(path: "files-test-\(UUID().uuidString)-big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(ServerFiles.largest) + 1)
        try handle.close()
        defer { try? FileManager.default.removeItem(at: big) }
        await model.upload([.init(local: big, name: "big.bin")])
        #expect(model.folder?.entry(named: "big.bin") == nil)
        #expect(model.problem?.contains("big.bin") == true && model.problem?.contains("at most") == true)
        // One the server lists as larger than it gives isn't asked for either.
        let listed = ServerFile(name: "disk.img", path: DemoServerFiles.home + "/disk.img", isDirectory: false, size: ServerFiles.largest + 1)
        model.problem = nil
        #expect(await model.fetch(listed) == nil)
        #expect(model.problem?.contains("disk.img") == true)
    }

    @Test func foldersAreMadeAndThingsAreDeleted() async throws {
        let model = ServerFolderModel(path: DemoServerFiles.home + "/Documents", browser: DemoServerFiles())
        await model.load()
        #expect(model.folder?.entries.map(\.name) == ["Reports", "budget.csv", "scan.pdf"])
        #expect(await model.makeFolder(" Inbox "))
        #expect(model.folder?.entry(named: "Inbox")?.isDirectory == true)
        #expect(!(await model.makeFolder("Inbox")) && model.problem?.contains("already here") == true)
        model.problem = nil
        #expect(!(await model.makeFolder("a/b")) && model.problem != nil)
        model.problem = nil

        // A folder goes with what is in it.
        let reports = try #require(model.folder?.entry(named: "Reports"))
        await model.delete(reports)
        #expect(model.folder?.entry(named: "Reports") == nil && model.problem == nil)
        let budget = try #require(model.folder?.entry(named: "budget.csv"))
        await model.delete(budget)
        #expect(model.folder?.entries.map(\.name) == ["Inbox", "scan.pdf"])
    }

    @Test func aFileComesToThePhoneUnderItsOwnName() async throws {
        let model = ServerFolderModel(path: DemoServerFiles.home + "/Documents", browser: DemoServerFiles())
        await model.load()
        let budget = try #require(model.folder?.entry(named: "budget.csv"))
        let copy = try #require(await model.fetch(budget))
        #expect(copy.lastPathComponent == "budget.csv")
        #expect(String(decoding: try Data(contentsOf: copy), as: UTF8.self).hasPrefix("month,spend"))
        // Gone on the server meanwhile: said, and the list is as it was.
        let ghost = ServerFile(name: "ghost.txt", path: DemoServerFiles.home + "/Documents/ghost.txt", isDirectory: false, size: 3)
        #expect(await model.fetch(ghost) == nil)
        #expect(model.problem == "It isn't there any more.")
    }

    @Test func aFolderThatCannotBeOpenedSaysWhyAndAFailedRefreshKeepsTheList() async {
        final class Flaky: ServerFileBrowsing {
            var fail = true
            let real = DemoServerFiles()
            func folder(at path: String?) async throws -> ServerFolder {
                if fail { throw TransportError.http(status: 403, body: "Path outside managed files root") }
                return try await real.folder(at: path)
            }
            func download(_ file: ServerFile, watch: TransferWatch?) async throws -> URL { try await real.download(file, watch: watch) }
            func upload(_ local: URL, as name: String, into folder: String, replacing: Bool, watch: TransferWatch?) async throws -> ServerFile {
                try await real.upload(local, as: name, into: folder, replacing: replacing, watch: watch)
            }
            func makeFolder(_ name: String, in folder: String) async throws -> ServerFile { try await real.makeFolder(name, in: folder) }
            func delete(_ file: ServerFile) async throws { try await real.delete(file) }
            func text(of file: ServerFile) async throws -> ServerText { try await real.text(of: file) }
            func write(_ text: String, to file: ServerFile) async throws { try await real.write(text, to: file) }
        }
        let server = Flaky()
        let model = ServerFolderModel(path: nil, browser: server)
        await model.load()
        #expect(model.phase == .failed("That is outside the folder this server keeps its file manager to.") && model.folder == nil)
        server.fail = false
        await model.load()
        #expect(model.phase == .loaded && model.folder != nil)
        server.fail = true
        await model.load()
        #expect(model.phase == .loaded && model.folder != nil, "what was listed stays on screen")
        #expect(model.problem?.contains("outside the folder") == true)
    }

    @Test func theQuestionsTheScreenAsks() {
        #expect(FilesView.deleteQuestion(ServerFile(name: "a.txt", path: "/a.txt", isDirectory: false)) == "Delete “a.txt”?")
        #expect(FilesView.deleteQuestion(ServerFile(name: "Old", path: "/Old", isDirectory: true)) == "Delete the folder “Old” and everything in it?")
        #expect(FilesView.replaceQuestion(["a.txt"]) == "“a.txt” is already in this folder.")
        #expect(FilesView.replaceQuestion(["a.txt", "b.txt"]) == "“a.txt” and “b.txt” are already in this folder.")
        #expect(FilesView.replaceQuestion(["a.txt", "b.txt", "c.txt"]) == "“a.txt” and 2 more are already in this folder.")
        #expect(ServerText(text: "x").canEdit && !ServerText(text: "x", truncated: true).canEdit && !ServerText(text: "x", binary: true).canEdit)
    }
}
