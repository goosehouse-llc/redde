import Foundation
import Observation
import Photos
#if os(iOS)
import BackgroundTasks
#endif
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import os

/// What the phone has made out in the pictures in the library (`PhotoLook`), kept so that each
/// is looked at once: it is what lets the agent find a photo by what it shows ("the bowling
/// scoreboards") and not only by when it was taken. iOS has its own such index for the Photos
/// app's search and lends it to no other app, so Redde makes one.
///
/// It is made on the phone and stays there, in a file that is left out of backups and deleted
/// when Photos is turned off in Settings → Phone tools. Pictures are looked at newest first: a
/// search waits a while for the ones it asks about (`cover`), and the rest are worked through
/// while Redde is open (`catchUp`), slower, and not at all while the phone is saving power or
/// running hot. On battery only the newest pictures are worked through, one at a time; the rest
/// wait for the charger, while Redde is open or overnight in the background (`PhotoLooking`).
/// It was hours of the phone's hardest work on a large library (battery review, 2026-11-11).
actor PhotoIndex {
    static let shared = PhotoIndex()

    /// A picture, and when it was last changed: one edited since it was looked at is looked at
    /// again.
    nonisolated struct Mark: Hashable, Sendable {
        var id: String
        var edited: Double

        init(id: String, edited: Double = 0) { self.id = id; self.edited = edited }
        init(_ asset: PHAsset) {
            self.init(id: asset.localIdentifier, edited: ((asset.modificationDate ?? asset.creationDate)?.timeIntervalSinceReferenceDate ?? 0).rounded())
        }
    }

    /// One picture in the file, a line each.
    private nonisolated struct Line: Codable {
        var i: String
        var m: Double
        var l: [String: Double]
        var t: String?
    }

    private let file: URL
    /// Looks at a picture; `pressing` when a search waits for it (its text read more carefully).
    private let look: @Sendable (Mark, _ pressing: Bool) async throws -> PhotoSeen
    private var known: [String: (edited: Double, seen: PhotoSeen)]?
    private var handle: FileHandle?
    /// Asked about by a search, and everything else; both with the next one to look at last.
    private var urgent: [Mark] = []
    private var backlog: [Mark] = []
    private var awaited: Set<String> = []
    private var running: Set<String> = []
    /// Pictures that couldn't be looked at: left alone until Redde is next started.
    private var failed: Set<String> = []
    private var waitingForEase = false
    /// On the charger (or a Mac): the whole library is worked through, two at a time. On battery,
    /// only the newest `onBattery` pictures, one at a time.
    private var charging = true
    private var recent: Set<String> = []
    nonisolated static let onBattery = 200

    init(file: URL? = nil, look: (@Sendable (Mark) async throws -> PhotoSeen)? = nil) {
        self.file = file ?? URL.applicationSupportDirectory.appending(path: "PhotoIndex/seen.jsonl")
        if let look {
            self.look = { @Sendable mark, _ in try await look(mark) }
        } else {
            self.look = { @Sendable mark, pressing in try await PhotoIndex.lookInLibrary(mark, pressing: pressing) }
        }
    }

    // MARK: - What is known

    private func entries() -> [String: (edited: Double, seen: PhotoSeen)] {
        if let known { return known }
        var read: [String: (edited: Double, seen: PhotoSeen)] = [:]
        if let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder()
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let entry = try? decoder.decode(Line.self, from: line) else { continue }
                read[entry.i] = (entry.m, PhotoSeen(labels: entry.l, text: entry.t ?? ""))   // a later line replaces an earlier one
            }
        }
        known = read
        return read
    }

    private func isCurrent(_ mark: Mark) -> Bool { entries()[mark.id]?.edited == mark.edited }

    /// What has been made out in these pictures, for the ones that have been looked at.
    func seen(_ marks: [Mark]) -> [String: PhotoSeen] {
        let all = entries()
        var found: [String: PhotoSeen] = [:]
        for mark in marks {
            if let entry = all[mark.id], entry.edited == mark.edited { found[mark.id] = entry.seen }
        }
        return found
    }

    /// How many pictures have been looked at, and how many are still to come.
    func standing() -> (looked: Int, waiting: Int) { (entries().count, backlog.count + urgent.count + running.count) }

    private func keep(_ mark: Mark, _ seen: PhotoSeen) {
        _ = entries()
        known?[mark.id] = (mark.edited, seen)   // in place: a copy of the whole of it per picture would be felt
        guard let line = try? JSONEncoder().encode(Line(i: mark.id, m: mark.edited, l: seen.labels, t: seen.text.isEmpty ? nil : seen.text)) else { return }
        if handle == nil {
            let folder = file.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            // It can be made again from the library, and says what is in the person's pictures.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var marked = folder
            try? marked.setResourceValues(values)
            handle = try? FileHandle(forWritingTo: file)
            _ = try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: line + Data([UInt8(ascii: "\n")]))
    }

    /// Forgets everything: the file goes, and nothing more is looked at.
    func forget() {
        urgent = []; backlog = []; awaited = []
        known = [:]
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: file)
    }

    /// Writes the file out again without the pictures that are no longer in the library, and
    /// without the lines that later ones replaced.
    private func tidy(keeping ids: Set<String>) {
        let all = entries().filter { ids.contains($0.key) }
        known = all
        try? handle?.close()
        handle = nil
        let encoder = JSONEncoder()
        var data = Data()
        for (id, entry) in all {
            guard let line = try? encoder.encode(Line(i: id, m: entry.edited, l: entry.seen.labels, t: entry.seen.text.isEmpty ? nil : entry.seen.text)) else { continue }
            data += line + Data([UInt8(ascii: "\n")])
        }
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - Looking

    /// Looks at the ones of these that haven't been looked at, in the order given, three at a
    /// time, and comes back when they are done or `patience` is up, whichever is first. A
    /// picture being looked at when time is up is still finished and kept.
    func cover(_ marks: [Mark], for patience: Duration) async {
        let missing = marks.filter { !isCurrent($0) && !failed.contains($0.id) }
        guard !missing.isEmpty else { return }
        urgent = missing.reversed()
        awaited = Set(missing.map(\.id))
        pump()
        let deadline = ContinuousClock.now + patience
        while !awaited.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        urgent = []
        awaited = []
    }

    /// Works through these in the order given, when nothing more pressing is asked: `marks` is
    /// the whole library. Comes back at once; `standing` says how far it has got.
    func catchUp(_ marks: [Mark]) {
        let ids = Set(marks.map(\.id))
        let all = entries()
        let gone = all.keys.count(where: { !ids.contains($0) })
        if gone > max(50, all.count / 10) { tidy(keeping: ids) }
        backlog = marks.filter { !isCurrent($0) && !failed.contains($0.id) }.reversed()
        recent = Set(marks.prefix(Self.onBattery).map(\.id))
        pump()
    }

    /// On the charger or off it: the rest of the library is worked through, or waits for it.
    func setCharging(_ on: Bool) {
        guard on != charging else { return }
        charging = on
        pump()
    }

    /// Whether pictures are left that wait for the charger (the background run's to do).
    func waitsForCharger() -> Bool { !backlog.isEmpty && !charging }

    /// Whether any of the library is still to be looked at.
    func hasBacklog() -> Bool { !backlog.isEmpty }
    /// On battery with nothing going: what is left waits for the charger.
    func idleOnBattery() -> Bool { !charging && running.isEmpty && urgent.isEmpty }

    /// Stops working through the library. What a search asks about is still looked at.
    func rest() { backlog = [] }

    private func next() -> Mark? {
        while let mark = urgent.popLast() {
            if running.contains(mark.id) { continue }   // on its way already, and still awaited
            if isCurrent(mark) || failed.contains(mark.id) { awaited.remove(mark.id); continue }
            return mark
        }
        guard !backlog.isEmpty else { return nil }
        guard Self.atEase() else {
            // Not while the phone is saving power or hot: looked at again in a while.
            if !waitingForEase {
                waitingForEase = true
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    await self?.eased()
                }
            }
            return nil
        }
        while let mark = backlog.last {
            // On battery the newest alone; the rest stay for the charger.
            if !charging, !recent.contains(mark.id) { return nil }
            backlog.removeLast()
            if !running.contains(mark.id), !isCurrent(mark), !failed.contains(mark.id) { return mark }
        }
        return nil
    }

    private func eased() {
        waitingForEase = false
        pump()
    }

    private func pump() {
        // A search has three going at once; the library is worked through two at a time on the
        // charger, one on battery.
        while running.count < (urgent.isEmpty ? (charging ? 2 : 1) : 3), let mark = next() {
            running.insert(mark.id)
            let pressing = awaited.contains(mark.id)
            Task.detached(priority: pressing ? .userInitiated : .utility) { [look] in
                let seen = try? await look(mark, pressing)
                await self.finished(mark, seen)
            }
        }
    }

    private func finished(_ mark: Mark, _ seen: PhotoSeen?) {
        running.remove(mark.id)
        awaited.remove(mark.id)
        if let seen { keep(mark, seen) } else { failed.insert(mark.id) }
        pump()
    }

    private nonisolated static func atEase() -> Bool {
        let phone = ProcessInfo.processInfo
        return !phone.isLowPowerModeEnabled && phone.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }

    // MARK: - The library

    /// Every picture and video in the library, newest first.
    nonisolated static func library() -> [Mark] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var marks: [Mark] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in marks.append(Mark(asset)) }
        return marks
    }

    /// Looks at one picture in the library: what is in it, from the small copy the phone always
    /// has, and its text when it is the kind of picture that has some, from a larger one. A
    /// picture whose larger copy is only in iCloud is not fetched for this, and goes unread.
    /// The library's own text is read quickly; a picture a search waits for, carefully.
    nonisolated static func lookInLibrary(_ mark: Mark, pressing: Bool) async throws -> PhotoSeen {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [mark.id], options: nil).firstObject,
              let small = await picture(of: asset, edge: PhotoLook.glance) else { throw DeviceToolError("The picture couldn't be looked at.") }
        var seen = PhotoSeen(labels: try await PhotoLook.labels(in: small))
        if asset.mediaType == .image, asset.mediaSubtypes.contains(.photoScreenshot) || PhotoLook.hasSomethingToRead(seen.labels),
           let large = await picture(of: asset, edge: PhotoLook.reading) {
            seen.text = (try? await PhotoLook.text(in: large, carefully: pressing || !PhotoLook.readsQuickly)) ?? ""
        }
        return seen
    }

    private nonisolated static func picture(of asset: PHAsset, edge: Int) async -> CGImage? {
        let request = PHImageRequestOptions()
        request.deliveryMode = .highQualityFormat   // one answer
        request.resizeMode = .fast
        request.isNetworkAccessAllowed = false      // looking at the library must not download it
        return await withCheckedContinuation { done in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: edge, height: edge), contentMode: .aspectFit, options: request) { image, _ in
                done.resume(returning: image?.cgImage)
            }
        }
    }
}

/// Keeps the library being looked at while Redde is open and Photos is on in Settings → Phone
/// tools, and says how far that has got. On battery only the newest pictures are looked at; the
/// rest while the phone is charging, with Redde open or overnight (`registerOvernight`).
@Observable
final class PhotoLooking {
    static let shared = PhotoLooking()

    /// How many of the library's pictures have been looked at, how many there are, and whether
    /// the rest are still to come (some can't be looked at, and are left).
    private(set) var looked = 0
    private(set) var total = 0
    private(set) var isWorking = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let index: PhotoIndex
    @ObservationIgnored private var powerWatch: NSObjectProtocol?

    init(index: PhotoIndex = .shared) { self.index = index }

    /// Redde has come forward, or the setting has changed. With Photos off, what was made out
    /// of the pictures is thrown away.
    func resume(settings: Settings = .shared) {
        guard settings.phoneTools.access(.photos) != .off else {
            pause()
            (looked, total, isWorking) = (0, 0, false)
            Task { [index] in await index.forget() }
            return
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard task == nil, status == .authorized || status == .limited else { return }
        watchPower()
        let charging = Self.isCharging
        task = Task { [weak self, index] in
            await index.setCharging(charging)
            await self?.work(index)
            if !Task.isCancelled { self?.task = nil }
        }
    }

    /// Works through the library until it is done or there is nothing more to do now.
    private func work(_ index: PhotoIndex) async {
        let marks = await Task.detached(priority: .utility) { PhotoIndex.library() }.value
        await index.catchUp(marks)
        while !Task.isCancelled {
            let standing = await index.standing()
            total = marks.count
            looked = min(standing.looked, marks.count)
            // What waits for the charger is left for it: no reason to keep asking meanwhile.
            let waits = await index.waitsForCharger(), idle = await index.idleOnBattery()
            let parked = waits && idle
            isWorking = standing.waiting > 0 && !parked
            if standing.waiting == 0 || parked { break }
            try? await Task.sleep(for: .seconds(1))
        }
        #if os(iOS)
        if await index.hasBacklog() { Self.scheduleOvernight() }
        #endif
    }

    /// Redde has left the screen.
    func pause() {
        task?.cancel()
        task = nil
        Task { [index] in await index.rest() }
    }

    // MARK: The charger

    private static var isCharging: Bool {
        #if os(iOS)
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
        #else
        return true
        #endif
    }

    private func watchPower() {
        #if os(iOS)
        guard powerWatch == nil else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        powerWatch = NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let looking = PhotoLooking.shared
                let charging = Self.isCharging
                Task { [index = looking.index] in await index.setCharging(charging) }
                // Plugged in with Redde open: the rest of the library now.
                if charging, looking.task == nil, Conversation.appIsActive { looking.resume() }
            }
        }
        #endif
    }

    // MARK: Overnight (the iPhone's)

    #if os(iOS)
    /// The background run's identifier, in `BGTaskSchedulerPermittedIdentifiers`.
    nonisolated static let overnightID = "com.goosehouse.echo.photos"

    /// At launch, before it finishes (`PushDelegate`): the library looked through on the
    /// charger while the phone isn't in use, as iOS chooses (overnight, as a rule).
    nonisolated static func registerOvernight() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: overnightID, using: .main) { task in
            nonisolated(unsafe) let task = task
            let work = Task { @MainActor in
                let looking = PhotoLooking.shared
                guard Settings.shared.phoneTools.access(.photos) != .off else { task.setTaskCompleted(success: true); return }
                await looking.index.setCharging(true)
                await looking.work(looking.index)
                await looking.index.rest()
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = {
                work.cancel()
                Task { await PhotoIndex.shared.rest() }
            }
        }
    }

    static func scheduleOvernight() {
        guard !ProcessInfo.processInfo.isiOSAppOnMac else { return }
        let request = BGProcessingTaskRequest(identifier: overnightID)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        try? BGTaskScheduler.shared.submit(request)   // the simulator refuses it
    }
    #endif
}
