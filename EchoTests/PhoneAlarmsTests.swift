import AlarmKit
import Foundation
import Testing
@testable import Echo

/// The alarms tools against a stand-in for iOS's alarms: what is set and with what, what is
/// refused before anything is set, what a list shows, and what happens to one that has rung.
/// AlarmKit itself (the permission, the ringing, the countdown) takes a phone.
struct PhoneAlarmsTests {
    /// Holds what it was asked to set, as iOS does until it rings.
    final class FakeAlarms: AlarmSetting, @unchecked Sendable {
        private let lock = NSLock()
        private var state = (allowed: true, rung: [(id: UUID, title: String, at: Date)](), counted: [(id: UUID, title: String, seconds: TimeInterval)](),
                             cancelled: [UUID](), holding: Set<UUID>(), failure: (any Error)?.none)
        var isAllowed: Bool { get { lock.withLock { state.allowed } } set { lock.withLock { state.allowed = newValue } } }
        private var shows = true
        var canShow: Bool { get { lock.withLock { shows } } set { lock.withLock { shows = newValue } } }
        var failure: (any Error)? { get { lock.withLock { state.failure } } set { lock.withLock { state.failure = newValue } } }
        var rung: [(id: UUID, title: String, at: Date)] { lock.withLock { state.rung } }
        var counted: [(id: UUID, title: String, seconds: TimeInterval)] { lock.withLock { state.counted } }
        var cancelled: [UUID] { lock.withLock { state.cancelled } }

        func allowed() async -> Bool { isAllowed }
        func ring(id: UUID, title: String, at date: Date) async throws {
            try lock.withLock {
                if let failure = state.failure { throw failure }
                state.rung.append((id, title, date)); state.holding.insert(id)
            }
        }
        func count(id: UUID, title: String, down seconds: TimeInterval) async throws {
            try lock.withLock {
                if let failure = state.failure { throw failure }
                state.counted.append((id, title, seconds)); state.holding.insert(id)
            }
        }
        func cancel(id: UUID) throws { lock.withLock { state.cancelled.append(id); _ = state.holding.remove(id) } }
        func held() throws -> [UUID] { lock.withLock { Array(state.holding) } }
        /// It rang and was stopped, or was swiped away on the phone: iOS no longer has it.
        func gone(_ id: UUID) { lock.withLock { _ = state.holding.remove(id) } }
    }

    struct Harness {
        let system = FakeAlarms()
        let alarms: DeviceAlarms
        /// The evening of the 13th, on the phone's own clock.
        let now = DeviceDates.parse("2026-10-13T20:00")!

        init() {
            alarms = DeviceAlarms(system: system, file: FileManager.default.temporaryDirectory.appending(path: "alarms-\(UUID().uuidString).json"))
        }

        func set(_ args: [String: JSONValue]) async throws -> JSONValue { try await alarms.set(.object(args), now: now) }
        func listed() async throws -> [JSONValue] { try await alarms.list(.object([:]))["alarms"]?.array ?? [] }
    }

    private func message(_ work: () async throws -> JSONValue) async -> String? {
        do { _ = try await work(); return nil } catch let error as DeviceToolError { return error.message } catch { return "\(error)" }
    }

    // MARK: Setting

    @Test func anAlarmIsSetForAMoment() async throws {
        let h = Harness()
        let answer = try await h.set(["title": .string("Leave for the airport"), "at": .string("2026-10-14T06:10")])
        let rung = try #require(h.system.rung.first)
        #expect(rung.title == "Leave for the airport")
        #expect(rung.at == DeviceDates.parse("2026-10-14T06:10"))
        #expect(h.system.counted.isEmpty)
        #expect(answer["set"]?["kind"]?.string == "alarm")
        #expect(answer["set"]?["title"]?.string == "Leave for the airport")
        #expect(answer["set"]?["id"]?.string == rung.id.uuidString)
        #expect(answer["set"]?["rings"]?.string == DeviceDates.string(rung.at))
    }

    @Test func aTimerCountsDownFromNow() async throws {
        let h = Harness()
        let answer = try await h.set(["title": .string("Pasta"), "minutes": .number(0.5)])
        let counted = try #require(h.system.counted.first)
        #expect(counted.title == "Pasta" && counted.seconds == 30)
        #expect(h.system.rung.isEmpty)
        #expect(answer["set"]?["kind"]?.string == "timer")
        #expect(answer["set"]?["rings"]?.string == DeviceDates.string(h.now.addingTimeInterval(30)))
    }

    @Test func itIsAnAlarmOrATimerAndNotBothOrNeither() async throws {
        let h = Harness()
        let neither = await message { try await h.set(["title": .string("x")]) }
        let both = await message { try await h.set(["title": .string("x"), "at": .string("2026-10-14T06:10"), "minutes": .number(5)]) }
        #expect(neither?.contains("one of the two") == true && both == neither)
        let untitled = await message { try await h.set(["minutes": .number(5)]) }
        #expect(untitled == DeviceToolError.missing("title").message)
        #expect(h.system.rung.isEmpty && h.system.counted.isEmpty, "Nothing is set on the way to a refusal")
        #expect(try await h.listed().isEmpty)
    }

    @Test func aTimeThatCannotRingIsRefused() async throws {
        let h = Harness()
        let passed = await message { try await h.set(["title": .string("x"), "at": .string("2026-10-13T19:00")]) }
        #expect(passed?.contains("has passed") == true)
        let dayOnly = await message { try await h.set(["title": .string("x"), "at": .string("2026-10-14")]) }
        #expect(dayOnly?.contains("time of day") == true)
        let unreadable = await message { try await h.set(["title": .string("x"), "at": .string("tomorrow at six")]) }
        #expect(unreadable?.contains("isn't a date") == true)
        for minutes: Double in [0, -3, 0.001, 24 * 60 + 1] {
            let refused = await message { try await h.set(["title": .string("x"), "minutes": .number(minutes)]) }
            #expect(refused?.contains("a second to a day") == true, "\(minutes) minutes")
        }
        #expect(h.system.rung.isEmpty && h.system.counted.isEmpty)
    }

    @Test func whatIOSRefusesIsSaidInWords() async throws {
        let h = Harness()
        h.system.isAllowed = false
        let refused = await message { try await h.set(["title": .string("x"), "minutes": .number(5)]) }
        #expect(refused == DeviceToolError.refused(.alarms).message)
        #expect(await message { try await h.alarms.list(.object([:])) } == refused)
        #expect(await message { try await h.alarms.cancel(.object(["id": .string("x")])) } == refused)
        h.system.isAllowed = true
        h.system.failure = AlarmManager.AlarmError.maximumLimitReached
        let full = await message { try await h.set(["title": .string("x"), "minutes": .number(5)]) }
        #expect(full?.contains("won't hold any more") == true)
        #expect(try await h.listed().isEmpty, "One that wasn't set isn't listed")
    }

    /// iOS shows and sounds an alarm as a Live Activity. With those off for Redde it takes the
    /// alarm and rings it unseen and unheard, so Redde doesn't set one, and says why.
    @Test func withLiveActivitiesOffNothingIsSetAndTheAgentIsToldWhy() async throws {
        let h = Harness()
        h.system.canShow = false
        let refused = await message { try await h.set(["title": .string("Tea"), "minutes": .number(1)]) }
        #expect(refused == DeviceAlarms.needsLiveActivities && refused?.contains("Live Activities") == true)
        #expect(await message { try await h.set(["title": .string("Up"), "at": .string("2026-10-14T06:10")]) } == refused)
        #expect(h.system.counted.isEmpty && h.system.rung.isEmpty)
        // What was set before can still be seen and cancelled.
        h.system.canShow = true
        let set = try await h.set(["title": .string("Tea"), "minutes": .number(1)])
        h.system.canShow = false
        #expect(try await h.listed().count == 1)
        _ = try await h.alarms.cancel(.object(["id": set["set"]?["id"] ?? .null]))
        #expect(try await h.listed().isEmpty)
    }

    // MARK: Listing and cancelling

    @Test func theOnesYetToRingAreListedSoonestFirst() async throws {
        let h = Harness()
        _ = try await h.set(["title": .string("Morning"), "at": .string("2026-10-14T06:10")])
        _ = try await h.set(["title": .string("Pasta"), "minutes": .number(10)])
        let listed = try await h.listed()
        #expect(listed.compactMap { $0["title"]?.string } == ["Pasta", "Morning"])
        #expect(listed.compactMap { $0["kind"]?.string } == ["timer", "alarm"])
        // The timer rings and is stopped: iOS lets go of it, and so does the list.
        h.system.gone(try #require(h.system.counted.first).id)
        #expect(try await h.listed().compactMap { $0["title"]?.string } == ["Morning"])
        // What is kept survives the app: another runner reads the same file.
        let later = DeviceAlarms(system: h.system, file: h.alarms.file)
        #expect(try await later.list(.object([:]))["alarms"]?.array?.count == 1)
    }

    @Test func oneIsCancelledByItsId() async throws {
        let h = Harness()
        let set = try await h.set(["title": .string("Morning"), "at": .string("2026-10-14T06:10")])
        let id = try #require(set["set"]?["id"]?.string)
        let answer = try await h.alarms.cancel(.object(["id": .string(id.lowercased())]))
        #expect(answer["cancelled"]?["title"]?.string == "Morning")
        #expect(h.system.cancelled.map(\.uuidString) == [id])
        #expect(try await h.listed().isEmpty)
        let again = await message { try await h.alarms.cancel(.object(["id": .string(id)])) }
        #expect(again?.contains("no alarm or timer with that id") == true)
        #expect(await message { try await h.alarms.cancel(.object([:])) } == DeviceToolError.missing("id").message)
    }

    // MARK: What the person is asked

    @Test func thePersonIsToldWhatIsToBeSet() {
        let timer = DeviceAsk(.alarmsSet, .object(["title": .string("Pasta"), "minutes": .number(10)]))
        #expect(timer.title == "Set a timer")
        #expect(timer.detail == "“Pasta”, for 10 minutes")
        let alarm = DeviceAsk(.alarmsSet, .object(["title": .string("Leave for the airport"), "at": .string("2026-10-14T06:10")]))
        #expect(alarm.title == "Set an alarm")
        #expect(alarm.detail.hasPrefix("“Leave for the airport”, ") && alarm.detail.contains("October 14"))
        #expect(DeviceAsk(.alarmsCancel, .object(["id": .string("x")])).title == "Cancel an alarm or a timer")
        #expect(DeviceAsk(.alarmsList, .object([:])).detail.contains("not the Clock app's"))
    }

    @Test func settingAndCancellingAreChangesAndListingIsNot() {
        #expect(DeviceTool.alarmsSet.changes && DeviceTool.alarmsCancel.changes && !DeviceTool.alarmsList.changes)
        #expect([DeviceTool.alarmsSet, .alarmsList, .alarmsCancel].allSatisfy { $0.area == .alarms })
    }
}
