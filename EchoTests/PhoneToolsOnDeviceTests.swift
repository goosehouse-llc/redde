import AlarmKit
import Contacts
import EventKit
import Foundation
import Photos
import Testing
@testable import Echo

/// The phone tools that go through iOS's own frameworks, run for real: the calendar, reminders,
/// contacts and the photo library of whatever the tests run on. Each needs the app to have been
/// let at that thing already, which a test can't ask for; on a simulator:
///
///     xcrun simctl privacy <simulator> grant calendar com.goosehouse.echo
///     (and reminders, contacts, photos; alarms are allowed in the app itself, see their test)
///
/// Without it a test here is skipped. What is added is taken away again.
@Suite(.serialized)
@MainActor
struct PhoneToolsOnDeviceTests {
    private static func local(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.string(from: date)
    }

    /// Nine in the morning, the day after tomorrow.
    private var morning: Date {
        let day = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: .now)) ?? .now
        return day.addingTimeInterval(9 * 3600)
    }

    @Test(.enabled(if: EKEventStore.authorizationStatus(for: .event) == .fullAccess))
    func anEventIsAddedAndFoundAgain() async throws {
        let title = "Redde test \(UUID().uuidString.prefix(8))"
        let added = try await DeviceCalendar.addEvent(.object([
            "title": .string(title), "start": .string(Self.local(morning)), "location": .string("Room 4"), "notes": .string("Bring the form"),
        ]))
        let id = try #require(added["added"]?["id"]?.string?.nilIfEmpty)
        defer {
            let store = EKEventStore()
            if let event = store.event(withIdentifier: id) { try? store.remove(event, span: .thisEvent) }
        }
        #expect(added["added"]?["title"]?.string == title && added["added"]?["all_day"]?.bool == false)
        #expect(added["added"]?["start"]?.string.flatMap { DeviceDates.parse($0) } == morning)
        #expect(added["added"]?["end"]?.string.flatMap { DeviceDates.parse($0) } == morning.addingTimeInterval(3600), "an hour, unless told otherwise")

        let day = String(Self.local(morning).prefix(10))
        let found = try await DeviceCalendar.events(.object(["start": .string(day), "end": .string(day), "query": .string(title.lowercased())]))
        let events = try #require(found["events"]?.array)
        #expect(events.count == 1 && events.first?["id"]?.string == id)
        #expect(events.first?["location"]?.string == "Room 4" && events.first?["notes"]?.string == "Bring the form")
        // The same day without its words finds it too; the day before doesn't.
        #expect(try await DeviceCalendar.events(.object(["start": .string(day), "end": .string(day)]))["events"]?.array?.contains { $0["id"]?.string == id } == true)
        let before = String(Self.local(morning.addingTimeInterval(-86400)).prefix(10))
        #expect(try await DeviceCalendar.events(.object(["start": .string(before), "end": .string(before)]))["events"]?.array?.contains { $0["id"]?.string == id } == false)

        // A day alone is an all-day event.
        let allDay = try await DeviceCalendar.addEvent(.object(["title": .string(title + " all day"), "start": .string(day)]))
        let allDayID = try #require(allDay["added"]?["id"]?.string)
        defer {
            let store = EKEventStore()
            if let event = store.event(withIdentifier: allDayID) { try? store.remove(event, span: .thisEvent) }
        }
        #expect(allDay["added"]?["all_day"]?.bool == true)
        // And what can't be done says why.
        await #expect(throws: DeviceToolError.self) { try await DeviceCalendar.addEvent(.object(["title": .string(title)])) }
        await #expect(throws: DeviceToolError.self) {
            try await DeviceCalendar.addEvent(.object(["title": .string(title), "start": .string(day), "calendar": .string("No such calendar \(UUID())")]))
        }
    }

    @Test(.enabled(if: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess))
    func aReminderIsAddedListedAndMarkedDone() async throws {
        guard EKEventStore().defaultCalendarForNewReminders() != nil else { return }   // a simulator that has never had a list
        let title = "Redde test \(UUID().uuidString.prefix(8))"
        let added = try await DeviceCalendar.addReminder(.object(["title": .string(title), "due": .string(Self.local(morning)), "notes": .string("Form B")]))
        let id = try #require(added["added"]?["id"]?.string?.nilIfEmpty)
        defer {
            let store = EKEventStore()
            if let reminder = store.calendarItem(withIdentifier: id) as? EKReminder { try? store.remove(reminder, commit: true) }
        }
        #expect(added["added"]?["due"]?.string.flatMap { DeviceDates.parse($0) } == morning)
        func listed(_ args: [String: JSONValue] = [:]) async throws -> JSONValue? {
            try await DeviceCalendar.reminders(.object(args.merging(["limit": .number(200)]) { a, _ in a }))["reminders"]?.array?.first { $0["id"]?.string == id }
        }
        let open = try #require(try await listed())
        #expect(open["title"]?.string == title && open["completed"]?.bool == false && open["notes"]?.string == "Form B")
        let list = try #require(open["list"]?.string)
        #expect(try await listed(["list": .string(list.uppercased())]) != nil, "a list is found by its name, however it is capitalised")

        let done = try await DeviceCalendar.completeReminder(.object(["id": .string(id)]))
        #expect(done["completed"]?["completed"]?.bool == true)
        #expect(try await listed() == nil, "done, it is no longer among what is to do")
        #expect(try await listed(["include_completed": .bool(true)])?["completed"]?.bool == true)
        await #expect(throws: DeviceToolError.self) { try await DeviceCalendar.completeReminder(.object(["id": .string("no-such-reminder")])) }
        await #expect(throws: DeviceToolError.self) { try await DeviceCalendar.reminders(.object(["list": .string("No such list \(UUID())")])) }
    }

    @Test(.enabled(if: CNContactStore.authorizationStatus(for: .contacts) == .authorized))
    func aContactIsLookedUp() async throws {
        // Someone to find, put there and taken away again.
        let store = CNContactStore()
        let made = CNMutableContact()
        let family = "Reddetest\(UUID().uuidString.prefix(6))"
        made.givenName = "Dana"
        made.familyName = family
        made.organizationName = "Whitfield & Co"
        made.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+1 555 010 0199"))]
        made.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: "dana@\(family.lowercased()).example" as NSString)]
        var birthday = DateComponents()
        birthday.month = 3; birthday.day = 14
        made.birthday = birthday
        let add = CNSaveRequest()
        add.add(made, toContainerWithIdentifier: nil)
        try store.execute(add)
        defer {
            if let kept = try? store.unifiedContact(withIdentifier: made.identifier, keysToFetch: []), let gone = kept.mutableCopy() as? CNMutableContact {
                let remove = CNSaveRequest()
                remove.delete(gone)
                try? store.execute(remove)
            }
        }

        let byName = try await DeviceContacts.search(.object(["query": .string(family)]))
        let found = try #require(byName["contacts"]?.array?.first)
        #expect(byName["contacts"]?.array?.count == 1)
        #expect(found["name"]?.string == "Dana \(family)" && found["organization"]?.string == "Whitfield & Co")
        #expect(found["phones"]?.array?.first?["number"]?.string == "+1 555 010 0199")
        #expect(found["emails"]?.array?.first?["address"]?.string == "dana@\(family.lowercased()).example")
        #expect(found["birthday"]?.string == "03-14", "a birthday without its year is a day of the year")
        // Whose address is this?
        let byEmail = try await DeviceContacts.search(.object(["query": .string("dana@\(family.lowercased()).example")]))
        #expect(byEmail["contacts"]?.array?.first?["name"]?.string == "Dana \(family)")
        #expect(try await DeviceContacts.search(.object(["query": .string("Nobody\(UUID().uuidString.prefix(6))")]))["contacts"]?.array?.isEmpty == true)
        await #expect(throws: DeviceToolError.missing("query")) { try await DeviceContacts.search(.object([:])) }
    }

    @Test(.enabled(if: PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized))
    func photosAreFoundAndOneIsHandedOver() async throws {
        let all = try await DevicePhotos.search(.object(["limit": .number(5)]))
        let photos = try #require(all["photos"]?.array)
        guard let first = photos.first else { return }   // a library with nothing in it
        let id = try #require(first["id"]?.string)
        #expect(["photo", "screenshot", "video"].contains(first["kind"]?.string ?? "") && (first["width"]?.int ?? 0) > 0)
        // Newest first.
        let taken = photos.compactMap { $0["taken"]?.string.flatMap { DeviceDates.parse($0) } }
        #expect(taken == taken.sorted(by: >))
        // Asked for by kind, every picture is one or the other, and none is lost between them.
        func count(_ kind: String) async throws -> Int {
            try await DevicePhotos.search(.object(["kind": .string(kind), "limit": .number(200)]))["photos"]?.array?.count ?? -1
        }
        let (any, plain, shots, videos) = (try await count("any"), try await count("photo"), try await count("screenshot"), try await count("video"))
        #expect(plain + shots + videos == any && any > 0, "\(plain) photos, \(shots) screenshots and \(videos) videos of \(any)")
        let favorites = try await DevicePhotos.search(.object(["favorites": .bool(true), "limit": .number(200)]))["photos"]?.array ?? []
        #expect(favorites.allSatisfy { $0["favorite"]?.bool == true })
        // A limit is kept, and says there is more.
        if any > 1 {
            let one = try await DevicePhotos.search(.object(["limit": .number(1)]))
            #expect(one["photos"]?.array?.count == 1 && one["more"]?.bool == true)
        }
        // Nothing was taken before the camera was invented.
        #expect(try await DevicePhotos.search(.object(["end": .string("1826-01-01")]))["photos"]?.array?.isEmpty == true)
        await #expect(throws: DeviceToolError.self) { try await DevicePhotos.search(.object(["kind": .string("hologram")])) }

        let one = try await DevicePhotos.get(.object(["id": .string(id), "max_edge": .number(640)]))
        let data = try #require(one["file"]?["base64"]?.string.flatMap { Data(base64Encoded: $0) })
        #expect(data.prefix(2) == Data([0xFF, 0xD8]), "a JPEG")
        #expect(data.count <= DeviceFiles.mostBytes && one["file"]?["name"]?.string?.hasSuffix(".jpg") == true)
        #expect(one["id"]?.string == id)
        await #expect(throws: DeviceToolError.self) { try await DevicePhotos.get(.object(["id": .string("no-such-photo")])) }
    }

    private static func index(_ look: @escaping @Sendable (PhotoIndex.Mark) async throws -> PhotoSeen) -> PhotoIndex {
        PhotoIndex(file: FileManager.default.temporaryDirectory.appending(path: "photo-index-\(UUID().uuidString)/seen.jsonl"), look: look)
    }

    /// Found by what they show. The looking is a stand-in's here (in the simulator Vision calls
    /// every picture a night sky); the library, the order and what the agent is told are real.
    @Test(.enabled(if: PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized))
    func photosAreFoundByWhatTheyShow() async throws {
        let library = PhotoIndex.library()
        guard library.count >= 3 else { return }
        let (first, second) = (library[0].id, library[1].id)
        let index = Self.index { mark in
            if mark.id == first { return PhotoSeen(labels: ["bowling": 0.6]) }
            if mark.id == second { return PhotoSeen(labels: ["bowling": 0.9, "scoreboard": 0.8, "moss": 0.1], text: "LANE 3") }
            return PhotoSeen(labels: ["waterfall": 0.9])
        }
        let found = try await DevicePhotos.search(.object(["query": .string("the bowling scoreboards")]), index: index, patience: .seconds(20))
        let photos = try #require(found["photos"]?.array)
        #expect(photos.map { $0["id"]?.string } == [second, first], "the better answer first, not the newer picture")
        #expect(photos.first?["shows"] == .array([.string("bowling"), .string("scoreboard")]) && photos.first?["text"]?.string == "LANE 3")
        #expect(photos.first?["matched"] == .array([.string("bowling"), .string("scoreboards")]) && photos.last?["matched"] == .array([.string("bowling")]))
        #expect((photos.first?["match"]?.number ?? 0) > (photos.last?["match"]?.number ?? 1))
        #expect(photos.first?["taken"]?.string != nil && photos.first?["kind"]?.string != nil, "and what a search always says of a picture")
        #expect(found["looked_at"]?.int == library.count && found["not_looked_at"] == nil && found["note"] == nil && found["more"]?.bool == false)

        let one = try await DevicePhotos.search(.object(["query": .string("waterfall"), "limit": .number(1)]), index: index, patience: .seconds(20))
        #expect(one["photos"]?.array?.count == 1 && one["more"]?.bool == (library.count > 3))
        let none = try await DevicePhotos.search(.object(["query": .string("submarine")]), index: index, patience: .seconds(20))
        #expect(none["photos"]?.array?.isEmpty == true && none["more"]?.bool == false)
        // The dates still hold, and so does what the words must be.
        #expect(try await DevicePhotos.search(.object(["query": .string("bowling"), "end": .string("1826-01-01")]), index: index)["photos"]?.array?.isEmpty == true)
        await #expect(throws: DeviceToolError.self) { try await DevicePhotos.search(.object(["query": .string("my photos")]), index: index) }
    }

    /// Photos makes its changes on a queue of its own: the closure must not be the main actor's.
    @available(iOS 27, *)
    private nonisolated static func write(_ caption: String?, on asset: PHAsset) async throws {
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest(for: asset).caption = caption }
    }

    /// iOS 27 shows an app what a person wrote on a picture in Photos. A picture is found by
    /// that also when the phone hasn't looked at it, and the answer says how many it hasn't.
    @Test(.enabled(if: PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized))
    func aPhotoIsFoundByItsCaption() async throws {
        guard #available(iOS 27, *) else { return }
        let library = PhotoIndex.library()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: library.suffix(1).map(\.id), options: nil).firstObject else { return }
        let before = asset.extendedMetadata.caption
        let word = "Redde\(UUID().uuidString.prefix(6))"
        try await Self.write("\(word) at the lake", on: asset)
        let blind = Self.index { _ in throw DeviceToolError("can't see") }
        let found = try? await DevicePhotos.search(.object(["query": .string("\(word) lake")]), index: blind, patience: .seconds(20))
        let fetched = try? await DevicePhotos.get(.object(["id": .string(asset.localIdentifier), "max_edge": .number(320)]))
        // (An empty caption takes it away. Nil, which the header says does too, leaves it: iOS 27.0.)
        try await Self.write(before ?? "", on: asset)

        let photos = try #require(found?["photos"]?.array)
        #expect(photos.count == 1 && photos.first?["id"]?.string == asset.localIdentifier)
        #expect(photos.first?["caption"]?.string == "\(word) at the lake" && photos.first?["match"]?.number == 1)
        #expect(photos.first?["shows"] == nil, "nothing was made out in it")
        #expect(found?["looked_at"]?.int == 0 && found?["not_looked_at"]?.int == library.count)
        #expect(found?["note"]?.string?.contains("looked at 0 of the \(library.count) pictures") == true)
        #expect(fetched?["caption"]?.string == "\(word) at the lake", "and it comes with the picture")
        let after = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil).firstObject
        #expect(after?.extendedMetadata.caption?.nilIfEmpty == before?.nilIfEmpty, "what was written is taken away again")
    }

    /// AlarmKit has no `simctl privacy` grant: turn Alarms on once in Settings → Phone tools on
    /// the simulator (or run `PhoneToolsUITests`, which does) and this runs.
    @Test(.enabled(if: AlarmManager.shared.authorizationState == .authorized))
    func aTimerAndAnAlarmAreSetListedAndCancelled() async throws {
        let alarms = DeviceAlarms(file: FileManager.default.temporaryDirectory.appending(path: "alarms-\(UUID().uuidString).json"))
        let timer = try await alarms.set(.object(["title": .string("Redde test timer"), "minutes": .number(10)]))
        let alarm = try await alarms.set(.object(["title": .string("Redde test alarm"), "at": .string(Self.local(morning))]))
        let ids = try [timer, alarm].map { try #require($0["set"]?["id"]?.string) }
        let listed = try await alarms.list(.object([:]))["alarms"]?.array ?? []
        #expect(listed.compactMap { $0["title"]?.string } == ["Redde test timer", "Redde test alarm"], "iOS holds both, soonest first")
        for id in ids { _ = try await alarms.cancel(.object(["id": .string(id)])) }
        #expect(try await alarms.list(.object([:]))["alarms"]?.array?.isEmpty == true)
    }
}
