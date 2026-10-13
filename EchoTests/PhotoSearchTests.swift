import Foundation
import NaturalLanguage
import Testing
import UIKit
@testable import Echo

/// Finding a photo by what it shows: how a question in plain words is held against what is known
/// of a picture, and how what the phone makes out in the pictures is kept. What Vision really
/// says of a picture can't be tried here (in the simulator it calls every picture a night sky);
/// reading text can.
@MainActor
struct PhotoSearchTests {
    // MARK: The question

    @Test func theWordsThatAskForNothingAreLeftOut() throws {
        #expect(try PhotoQuery("Show me the photo of my dog at the beach").terms == ["dog", "beach"])
        #expect(try PhotoQuery("bowling scoreboards, Bowling").terms == ["bowling", "scoreboards"], "said twice, asked once")
        #expect(throws: DeviceToolError.self) { try PhotoQuery("the latest photos") }
        #expect(throws: DeviceToolError.self) { try PhotoQuery("  ") }
    }

    @Test func aPictureAnswersByWhatItShows() throws {
        let query = try PhotoQuery("bowling scoreboards", near: nil)
        let alley = try #require(query.match(seen: PhotoSeen(labels: ["bowling": 0.9, "scoreboard": 0.7, "people": 0.5])))
        #expect(alley.matched == ["bowling", "scoreboards"] && alley.score > 0.85, "the plural is the same word")
        let ball = try #require(query.match(seen: PhotoSeen(labels: ["bowling": 0.9, "ball": 0.8])))
        #expect(ball.matched == ["bowling"] && ball.score < alley.score, "half an answer counts for half")
        #expect(query.match(seen: PhotoSeen(labels: ["waterfall": 0.9])) == nil)
        #expect(query.match(seen: nil) == nil, "a picture nobody has looked at, with nothing written on it")
        // The less sure the phone was, the less it counts.
        let faint = try #require(query.match(seen: PhotoSeen(labels: ["bowling": 0.12])))
        #expect(faint.score < ball.score)
        // A name of two words is two words.
        let sky = try PhotoQuery("sky", near: nil)
        #expect(sky.match(seen: PhotoSeen(labels: ["blue_sky": 0.8]))?.matched == ["sky"])
    }

    @Test func whatThePersonWroteCountsInFull() throws {
        let query = try PhotoQuery("dad's birthday at the lake", near: nil)
        #expect(query.terms == ["dad", "birthday", "lake"])
        let hit = try #require(query.match(caption: "Dad turning 70. Lake house, July", keywords: ["Birthdays"], seen: nil))
        #expect(hit.matched == ["dad", "birthday", "lake"] && hit.score == 1)
    }

    @Test func textInThePictureIsMatchedAsWritten() throws {
        let query = try PhotoQuery("receipt hardware", near: NLEmbedding.wordEmbedding(for: .english))
        let hit = try #require(query.match(seen: PhotoSeen(labels: ["document": 0.9], text: "ACE HARDWARE 4410 Total 43.12")))
        #expect(hit.matched == ["hardware"])
        // No relations for what is read: "tools" is near "hardware", and isn't written there.
        let other = try PhotoQuery("tools", near: NLEmbedding.wordEmbedding(for: .english))
        #expect(other.match(seen: PhotoSeen(text: "ACE HARDWARE")) == nil)
    }

    /// "Puppy" finds the dog, less surely than "dog" does, and doesn't find the car.
    @Test(.enabled(if: NLEmbedding.wordEmbedding(for: .english) != nil))
    func aNearRelationCountsForLess() throws {
        let dog = PhotoSeen(labels: ["dog": 0.9, "animal": 0.9])
        let puppy = try PhotoQuery("puppy")
        let plain = try PhotoQuery("dog")
        let near = try #require(puppy.match(seen: dog)), exact = try #require(plain.match(seen: dog))
        #expect(near.score < exact.score && near.score >= 0.3)
        #expect(puppy.match(seen: PhotoSeen(labels: ["automobile": 0.9, "car": 0.9])) == nil)
        // Without the embedding, only the word itself.
        let bare = try PhotoQuery("puppy", near: nil)
        #expect(bare.match(seen: dog) == nil)
    }

    @Test func theAgentIsToldWhatThePhoneIsFairlySureOf() {
        #expect(PhotoSeen(labels: ["water_body": 0.85, "waterfall": 0.9, "rocks": 0.4, "moss": 0.12]).shows == ["waterfall", "water body", "rocks"])
        #expect(PhotoSeen(labels: ["daisy": 0.13, "flower": 0.14]).shows == ["flower", "daisy"], "sure of nothing, it says its best guesses")
        #expect(PhotoSeen().shows.isEmpty)
    }

    // MARK: Reading

    @Test func textInAPictureIsRead() async throws {
        let size = CGSize(width: 900, height: 420)
        let picture = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ("LANE 3 BOWLING" as NSString).draw(at: CGPoint(x: 40, y: 60), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 72), .foregroundColor: UIColor.black])
            ("Total 43.12" as NSString).draw(at: CGPoint(x: 40, y: 220), withAttributes: [.font: UIFont.systemFont(ofSize: 60), .foregroundColor: UIColor.black])
        }
        let text = try await PhotoLook.text(in: try #require(picture.cgImage))
        #expect(text.contains("BOWLING") && text.contains("43.12"), "\(text)")
        let query = try PhotoQuery("bowling lane", near: nil)
        #expect(query.match(seen: PhotoSeen(text: text))?.matched == ["bowling", "lane"])
    }

    @Test func onlyPicturesWithSomethingToReadAreRead() {
        #expect(PhotoLook.hasSomethingToRead(["scoreboard": 0.6, "bowling": 0.9]))
        #expect(PhotoLook.hasSomethingToRead(["document": 0.2]))
        #expect(!PhotoLook.hasSomethingToRead(["document": 0.1, "waterfall": 0.9]), "a faint guess isn't worth the reading")
        #expect(!PhotoLook.hasSomethingToRead(["dog": 0.9]))
    }

    // MARK: What is kept

    /// A stand-in for looking: says what it was told to, counts, and can be slow or fail.
    private final class Looker: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        var failing: Set<String> = []
        var slow: [String: Duration] = [:]

        var looks: [String: Int] { lock.withLock { counts } }

        func look(_ mark: PhotoIndex.Mark) async throws -> PhotoSeen {
            lock.withLock { counts[mark.id, default: 0] += 1 }
            if let wait = slow[mark.id] { try? await Task.sleep(for: wait) }
            if failing.contains(mark.id) { throw DeviceToolError("couldn't") }
            return PhotoSeen(labels: [mark.id: 0.9], text: mark.id == "note" ? "milk eggs" : "")
        }
    }

    private static func file() -> URL { FileManager.default.temporaryDirectory.appending(path: "photo-index-\(UUID().uuidString)/seen.jsonl") }

    @Test func eachPictureIsLookedAtOnceAndKept() async throws {
        let file = Self.file(), looker = Looker()
        let marks = ["dog", "note", "lake"].map { PhotoIndex.Mark(id: $0, edited: 1) }
        let index = PhotoIndex(file: file) { try await looker.look($0) }
        await index.cover(marks, for: .seconds(5))
        #expect(await index.seen(marks) == ["dog": PhotoSeen(labels: ["dog": 0.9]), "note": PhotoSeen(labels: ["note": 0.9], text: "milk eggs"), "lake": PhotoSeen(labels: ["lake": 0.9])])
        await index.cover(marks, for: .seconds(5))
        #expect(looker.looks == ["dog": 1, "note": 1, "lake": 1])
        #expect(await index.standing().looked == 3)

        // Redde started again: it is all still there, and nothing is looked at twice.
        let later = PhotoIndex(file: file) { try await looker.look($0) }
        await later.cover(marks, for: .seconds(5))
        #expect(await later.seen(marks).count == 3)
        #expect(looker.looks["dog"] == 1)

        // A picture edited since is another picture.
        let edited = PhotoIndex.Mark(id: "dog", edited: 2)
        #expect(await later.seen([edited]).isEmpty)
        await later.cover([edited], for: .seconds(5))
        #expect(looker.looks["dog"] == 2)
        #expect(await later.seen([edited]).count == 1)
        let again = PhotoIndex(file: file) { try await looker.look($0) }
        #expect(await again.seen([edited]).count == 1, "the later line in the file is the one that counts")

        await again.forget()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await again.seen(marks + [edited]).isEmpty)
    }

    @Test func aPictureThatCannotBeLookedAtIsLeftAlone() async throws {
        let looker = Looker()
        looker.failing = ["broken"]
        let index = PhotoIndex(file: Self.file()) { try await looker.look($0) }
        let marks = [PhotoIndex.Mark(id: "broken"), PhotoIndex.Mark(id: "fine")]
        await index.cover(marks, for: .seconds(5))
        await index.cover(marks, for: .seconds(5))
        #expect(await index.seen(marks).keys.sorted() == ["fine"])
        #expect(looker.looks == ["broken": 1, "fine": 1], "not tried again at every search")
    }

    /// A search doesn't wait for ever: it answers with what there is, and the picture that was
    /// being looked at is kept when it is done.
    @Test func aSearchWaitsOnlySoLong() async throws {
        let looker = Looker()
        looker.slow = ["slow": .milliseconds(600)]
        let index = PhotoIndex(file: Self.file()) { try await looker.look($0) }
        let marks = [PhotoIndex.Mark(id: "quick"), PhotoIndex.Mark(id: "slow")]
        let start = ContinuousClock.now
        await index.cover(marks, for: .milliseconds(150))
        #expect(ContinuousClock.now - start < .milliseconds(500))
        #expect(await index.seen(marks).keys.sorted() == ["quick"])
        try await Task.sleep(for: .milliseconds(900))
        #expect(await index.seen(marks).count == 2)
    }

    @Test func theLibraryIsWorkedThroughAndWhatIsGoneIsDropped() async throws {
        let file = Self.file(), looker = Looker()
        let index = PhotoIndex(file: file) { try await looker.look($0) }
        let library = (0 ..< 120).map { PhotoIndex.Mark(id: "p\($0)") }
        await index.catchUp(library)
        for _ in 0 ..< 200 where await index.standing().waiting > 0 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(await index.standing().looked == 120)
        #expect(looker.looks.count == 120)
        // Most of the library has been deleted since: the file is written out without it.
        let left = Array(library.prefix(20))
        await index.catchUp(left)
        #expect(await index.standing().looked == 20)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 20)
        // Stopped, nothing more is looked at.
        await index.catchUp(left + [PhotoIndex.Mark(id: "new")])
        await index.rest()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await index.standing().waiting == 0)
    }

    // MARK: What the person is told

    @Test func askingSaysWhatTheAgentIsTold() {
        let plain = DeviceAsk(.photosSearch, .object(["kind": .string("photo")]))
        #expect(plain.detail == "Photos: when each was taken, not the pictures")
        let words = DeviceAsk(.photosSearch, .object(["query": .string("bowling scoreboard"), "start": .string("2026-10-05"), "end": .string("2026-10-11")]))
        #expect(words.detail == "Photos and videos from Monday, October 5 to Sunday, October 11 that match “bowling scoreboard”: what each shows and says, not the pictures")
        #expect(PhoneToolsSettingsView.lookingLine(looked: 1204, of: 31220, working: true) == "Redde has looked at 1,204 of 31,220 pictures so far, and goes on while it is open.")
        #expect(PhoneToolsSettingsView.lookingLine(looked: 6, of: 6, working: false) == "Redde has looked at all 6 pictures.")
        #expect(PhoneToolsSettingsView.lookingLine(looked: 31200, of: 31220, working: false).hasSuffix("the others couldn't be looked at."))
        #expect(PhoneToolsSettingsView.photosNote(on: "iPad").contains("on this iPad and keeps what it finds here"))
    }
}
