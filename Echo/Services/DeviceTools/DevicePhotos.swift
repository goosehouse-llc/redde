import Foundation
import Photos
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The photo library tools: finding photos by when they were taken, what kind they are and what
/// they show, handing one over to be looked at, and deleting. A delete is put to the person by
/// iOS itself, every time, with the pictures in question shown; Redde can't skip that and
/// doesn't want to.
nonisolated enum DevicePhotos {
    static func allowed() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return true
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return status == .authorized || status == .limited
        default: return false
        }
    }

    /// How long a search by what pictures show waits for the ones not yet looked at. The agent's
    /// call is given up on after two minutes, some of which the person may spend being asked.
    static let patience = Duration.seconds(30)

    /// `start`, `end` (when taken), `kind` (photo, screenshot, video, any), `favorites`, `limit`,
    /// and `query`: what the picture shows or says, in plain words. Newest first without a
    /// query; with one, the best answers first.
    static func search(_ args: JSONValue, index: PhotoIndex = .shared, patience: Duration = patience) async throws -> JSONValue {
        guard await allowed() else { throw DeviceToolError.refused(.photos) }
        let (options, wanted) = try question(args)
        let limit = args.limit(default: 30, most: 200)
        if let text = args["query"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return try await search(for: PhotoQuery(text), options, wanted, limit: limit, index: index, patience: patience)
        }
        var photos: [JSONValue] = []
        var more = false
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, stop in
            guard wanted(asset) else { return }
            if photos.count < limit { photos.append(describe(asset)) } else { more = true; stop.pointee = true }
        }
        return .object(["photos": .array(photos), "more": .bool(more)])
    }

    /// A search by what the pictures show: the ones in question that haven't been looked at yet
    /// are looked at first, as far as `patience` goes, and then each is held against the words.
    /// What the person wrote on a picture in Photos is there for every one of them, looked at
    /// or not. The answer says how many pictures it could not go by, so that "nothing found"
    /// is not taken for "there is none".
    private static func search(for query: PhotoQuery, _ options: PHFetchOptions, _ wanted: @escaping (PHAsset) -> Bool, limit: Int,
                               index: PhotoIndex, patience: Duration) async throws -> JSONValue {
        if #available(iOS 27, macOS 27, *) { options.prefetchAssetExtendedMetadata = true }
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            if wanted(asset) { assets.append(asset) }
        }
        let marks = assets.map(PhotoIndex.Mark.init)
        await index.cover(marks, for: patience)
        let seen = await index.seen(marks)

        var found: [(asset: PHAsset, score: Double, matched: [String])] = []
        for asset in assets {
            let said = written(on: asset)
            if let hit = query.match(caption: said.caption, keywords: said.keywords, seen: seen[asset.localIdentifier]) {
                found.append((asset, hit.score, hit.matched))
            }
        }
        // The best first, and among equals the newest. An answer far behind the best one is a
        // distant relation of what was asked ("bowling" finding every ball game) and is left out.
        let best = found.map(\.score).max() ?? 0
        found.removeAll { $0.score < best * 0.4 }
        found.sort { ($0.score, $0.asset.creationDate ?? .distantPast) > ($1.score, $1.asset.creationDate ?? .distantPast) }

        let photos: [JSONValue] = found.prefix(limit).map { hit in
            var fields = describe(hit.asset).object ?? [:]
            let said = written(on: hit.asset)
            if let caption = said.caption { fields["caption"] = .string(caption) }
            if !said.keywords.isEmpty { fields["keywords"] = .array(said.keywords.map(JSONValue.string)) }
            if let made = seen[hit.asset.localIdentifier] {
                if !made.shows.isEmpty { fields["shows"] = .array(made.shows.map(JSONValue.string)) }
                if !made.text.isEmpty { fields["text"] = .string(String(made.text.prefix(160))) }
            }
            fields["match"] = .number((hit.score * 100).rounded() / 100)
            fields["matched"] = .array(hit.matched.map(JSONValue.string))
            return .object(fields)
        }
        var result: [String: JSONValue] = [
            "photos": .array(photos), "more": .bool(found.count > limit), "looked_at": .number(Double(seen.count)),
        ]
        let unseen = assets.count - seen.count
        if unseen > 0 {
            result["not_looked_at"] = .number(Double(unseen))
            result["note"] = .string("The iPhone has looked at \(seen.count) of the \(assets.count) pictures in question so far, newest first, and "
                + "goes on while Redde is open. The other \(unseen) were matched only by a caption the user wrote, if they have one: "
                + "narrow the dates, or ask again in a while, before saying there is no such picture.")
        }
        return .object(result)
    }

    /// What the person wrote on a picture in the Photos app. iOS shows it to other apps from 27.
    static func written(on asset: PHAsset) -> (caption: String?, keywords: [String]) {
        guard #available(iOS 27, macOS 27, *) else { return (nil, []) }
        let more = asset.extendedMetadata
        return (more.caption?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty, more.keywords)
    }

    /// What a search asks the library, and which of what comes back it keeps. The library is
    /// asked by date and by picture or video only, newest first. Whether a picture is a
    /// screenshot or a favorite is looked at here, one by one: asked of the library as part of
    /// the question ("pictures that are not screenshots"), it gave back one picture of six.
    static func question(_ args: JSONValue) throws -> (options: PHFetchOptions, wanted: (PHAsset) -> Bool) {
        var clauses: [String] = []
        var values: [Any] = []
        if let start = try args.date("start") { clauses.append("creationDate >= %@"); values.append(start as NSDate) }
        if var end = try args.date("end") {
            if let text = args["end"]?.string, DeviceDates.isDayOnly(text) { end = end.addingTimeInterval(86400) }
            clauses.append("creationDate < %@"); values.append(end as NSDate)
        }
        /// nil: either; true: a screenshot; false: a picture that isn't one.
        var screenshot: Bool?
        switch args["kind"]?.string?.lowercased() ?? "any" {
        case "photo", "photos":
            clauses.append("mediaType == %d"); values.append(PHAssetMediaType.image.rawValue)
            screenshot = false
        case "screenshot", "screenshots":
            clauses.append("mediaType == %d"); values.append(PHAssetMediaType.image.rawValue)
            screenshot = true
        case "video", "videos":
            clauses.append("mediaType == %d"); values.append(PHAssetMediaType.video.rawValue)
        case "any", "":
            break
        default:
            throw DeviceToolError("\"kind\" is one of: photo, screenshot, video, any.")
        }
        let favorites = args["favorites"]?.bool == true
        let options = PHFetchOptions()
        if !clauses.isEmpty { options.predicate = NSPredicate(format: clauses.joined(separator: " AND "), argumentArray: values) }
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return (options, { asset in
            (screenshot == nil || asset.mediaSubtypes.contains(.photoScreenshot) == screenshot) && (!favorites || asset.isFavorite)
        })
    }

    /// `id`, and optionally `max_edge` in pixels: the picture itself, as a JPEG small enough to
    /// send. A video gives its first frame.
    static func get(_ args: JSONValue) async throws -> JSONValue {
        guard await allowed() else { throw DeviceToolError.refused(.photos) }
        let id = try args.required("id")
        let options = PHFetchOptions()
        if #available(iOS 27, macOS 27, *) { options.prefetchAssetExtendedMetadata = true }   // its caption comes with it
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: options).firstObject else { throw DeviceToolError("There is no photo with that id.") }
        let edge = CGFloat(min(max(args["max_edge"]?.int ?? 1280, 256), 2048))
        let request = PHImageRequestOptions()
        request.deliveryMode = .highQualityFormat   // one answer, the good one
        request.resizeMode = .exact
        request.isNetworkAccessAllowed = true       // it may be in iCloud only
        let jpeg: Data? = await withCheckedContinuation { done in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: edge, height: edge), contentMode: .aspectFit, options: request) { image, _ in
                // Small enough to hand to the server in one piece (`DeviceFiles.mostBytes`): a
                // busy picture is pressed harder before it is called too big.
                let pressed = [0.72, 0.5, 0.32].lazy.compactMap { image?.jpegData(compressionQuality: $0) }.first { $0.count <= DeviceFiles.mostBytes }
                done.resume(returning: pressed)
            }
        }
        guard let jpeg else { throw DeviceToolError("The picture couldn't be read, or is too large to send at that size (it may also still be downloading from iCloud). Try a smaller max_edge.") }
        var fields = describe(asset).object ?? [:]
        if let caption = written(on: asset).caption { fields["caption"] = .string(caption) }
        fields["file"] = .object(["name": .string("photo-\(id.prefix(8)).jpg"), "base64": .string(jpeg.base64EncodedString())])
        return .object(fields)
    }

    /// `ids`. iOS shows the pictures and asks; "Don't Allow" there is a no here.
    static func delete(_ args: JSONValue) async throws -> JSONValue {
        guard await allowed() else { throw DeviceToolError.refused(.photos) }
        let ids = (args["ids"]?.array ?? []).compactMap(\.string)
        guard !ids.isEmpty else { throw DeviceToolError.missing("ids") }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else { throw DeviceToolError("None of those ids is a photo in the library.") }
        let count = assets.count
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
        } catch {
            if (error as? PHPhotosError)?.code == .userCancelled { throw DeviceToolError.denied }
            throw DeviceToolError("The photos couldn't be deleted: \(error.localizedDescription)")
        }
        return .object(["deleted": .number(Double(count)), "note": .string("They are in Recently Deleted for 30 days.")])
    }

    private static func describe(_ asset: PHAsset) -> JSONValue {
        let kind = asset.mediaType == .video ? "video" : asset.mediaSubtypes.contains(.photoScreenshot) ? "screenshot" : "photo"
        var fields: [String: JSONValue] = [
            "id": .string(asset.localIdentifier),
            "kind": .string(kind),
            "width": .number(Double(asset.pixelWidth)),
            "height": .number(Double(asset.pixelHeight)),
        ]
        if let taken = asset.creationDate { fields["taken"] = .string(DeviceDates.string(taken)) }
        if asset.isFavorite { fields["favorite"] = .bool(true) }
        if asset.mediaType == .video { fields["seconds"] = .number(asset.duration.rounded()) }
        if let place = asset.location?.coordinate {
            fields["latitude"] = .number((place.latitude * 10000).rounded() / 10000)
            fields["longitude"] = .number((place.longitude * 10000).rounded() / 10000)
        }
        return .object(fields)
    }
}
