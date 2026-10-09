import Foundation
import Observation

/// One folder of the file browser: what is in it, and the things done to it from the screen.
/// The server is asked through `ServerFileBrowsing`, so the screen's sample data and the tests
/// drive the same code.
@Observable
final class ServerFolderModel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    /// A file picked on the phone, on its way to the server under `name`.
    struct Outgoing: Equatable {
        var local: URL
        var name: String
    }

    /// The folder asked for; nil is where the server starts.
    let path: String?
    @ObservationIgnored private let browser: any ServerFileBrowsing

    private(set) var phase: Phase = .loading
    private(set) var folder: ServerFolder?
    /// What is being done right now, in a few words ("Uploading notes.md"); nil when nothing is.
    private(set) var working: String?
    /// How far that has got, from 0 to 1, where it can be told.
    private(set) var progress: Double?
    /// Something that went wrong, to be shown and dismissed.
    var problem: String?
    /// Uploads held back because a file of that name is there already: they wait for a yes.
    private(set) var wouldReplace: [Outgoing] = []

    init(path: String?, browser: any ServerFileBrowsing) {
        self.path = path
        self.browser = browser
    }

    var isBusy: Bool { working != nil }

    func load() async {
        do {
            folder = try await browser.folder(at: path)
            phase = .loaded
        } catch {
            // What was listed stays on screen through a failed refresh.
            if folder == nil { phase = .failed(ServerFiles.explain(error)) } else { problem = ServerFiles.explain(error) }
        }
    }

    /// Sends files to this folder, one after another. One that would take the place of a file
    /// already here is held back and asked about (`wouldReplace`); one too large for Hermes is
    /// left out and said so.
    func upload(_ files: [Outgoing]) async {
        guard let folder, !isBusy else { return }
        var held: [Outgoing] = []
        var refused: [String] = []
        for file in files {
            guard let name = ServerFiles.usableName(file.name) else { refused.append("“\(file.name)” isn't a name a file can have."); continue }
            if let size = (try? file.local.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > ServerFiles.largest {
                refused.append("“\(name)” is \(ServerFiles.size(size)): Hermes takes at most \(ServerFiles.size(ServerFiles.largest)) as one file.")
                continue
            }
            if folder.entry(named: name) != nil {
                held.append(Outgoing(local: file.local, name: name))
                continue
            }
            if let failure = await send(Outgoing(local: file.local, name: name), to: folder.path, replacing: false) { refused.append(failure) }
        }
        wouldReplace = held
        if !refused.isEmpty { problem = refused.joined(separator: "\n") }
        await load()
    }

    /// The answer about the uploads that were held back.
    func replace(_ yes: Bool) async {
        let held = wouldReplace
        wouldReplace = []
        guard yes, let folder else { return }
        var refused: [String] = []
        for file in held {
            if let failure = await send(file, to: folder.path, replacing: true) { refused.append(failure) }
        }
        if !refused.isEmpty { problem = refused.joined(separator: "\n") }
        await load()
    }

    /// One upload; why it failed, or nil.
    private func send(_ file: Outgoing, to folder: String, replacing: Bool) async -> String? {
        do {
            try await watching("Uploading \(file.name)") { watch in
                _ = try await self.browser.upload(file.local, as: file.name, into: folder, replacing: replacing, watch: watch)
            }
            return nil
        } catch {
            return "“\(file.name)”: \(ServerFiles.explain(error))"
        }
    }

    /// Makes a folder here. False when the name can't be used or the server refused.
    @discardableResult
    func makeFolder(_ typed: String) async -> Bool {
        guard let folder, !isBusy else { return false }
        guard let name = ServerFiles.usableName(typed) else {
            problem = "That isn't a name a folder can have."
            return false
        }
        if folder.entry(named: name) != nil {
            problem = "Something called “\(name)” is already here."
            return false
        }
        do {
            try await watching("Making \(name)") { _ in _ = try await self.browser.makeFolder(name, in: folder.path) }
            await load()
            return true
        } catch {
            problem = ServerFiles.explain(error)
            return false
        }
    }

    /// Removes a file, or a folder and everything in it. The screen asks first.
    func delete(_ file: ServerFile) async {
        guard !isBusy else { return }
        do {
            try await watching("Deleting \(file.name)") { _ in try await self.browser.delete(file) }
        } catch {
            problem = ServerFiles.explain(error)
        }
        await load()
    }

    /// Brings a file to the phone to be looked at or shared; nil when it couldn't be.
    func fetch(_ file: ServerFile) async -> URL? {
        guard !isBusy else { return nil }
        if let size = file.size, size > ServerFiles.largest {
            problem = "“\(file.name)” is \(ServerFiles.size(size)): Hermes gives at most \(ServerFiles.size(ServerFiles.largest)) as one file."
            return nil
        }
        do {
            var copy: URL?
            try await watching("Downloading \(file.name)") { watch in copy = try await self.browser.download(file, watch: watch) }
            return copy
        } catch {
            problem = ServerFiles.explain(error)
            return nil
        }
    }

    /// Runs one piece of work under its name, with the transfer's progress read off as it goes.
    private func watching(_ what: String, _ work: (TransferWatch) async throws -> Void) async throws {
        working = what
        progress = nil
        let watch = TransferWatch()
        let reading = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                if let fraction = watch.fraction, self?.progress != fraction { self?.progress = fraction }
            }
        }
        defer {
            reading.cancel()
            working = nil
            progress = nil
        }
        try await work(watch)
    }
}
