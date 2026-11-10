import Foundation
import Testing
@testable import Echo

/// Health as a phone tool: what the agent may ask for, how it is read before Health is touched,
/// and the small answers it gets. Health itself needs a person's yes and a device with data,
/// which a test run has not; what is around it runs here.
@MainActor
struct PhoneHealthTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 1
        return calendar
    }
    /// Monday 2 November 2026, 3 PM in New York.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 15))! }
    private let shared: [HealthKind] = [.steps, .weight, .heartRate, .sleep, .workouts, .bloodPressure]

    private func ask(_ fields: [String: JSONValue], shared: [HealthKind]? = nil) throws -> HealthAsk {
        try HealthAsk(.object(fields), shared: shared ?? self.shared, now: now, calendar: calendar)
    }

    // MARK: Off until chosen

    @Test func nothingIsSharedUntilChosenAndOldSettingsStillRead() throws {
        var settings = PhoneToolsSettings()
        #expect(settings.sharedHealth.isEmpty && settings.access(.health) == .off)
        settings.share(.steps, true)
        #expect(settings.sharedHealth.isEmpty, "chosen, but Health itself is off")
        settings.on = true
        settings.set(.health, .allow)
        settings.share(.sleep, true)
        settings.share(.steps, true)
        #expect(settings.sharedHealth == [.steps, .sleep], "in Settings' order, each once")
        settings.share(.steps, false)
        #expect(settings.sharedHealth == [.sleep])
        // Kept before Health was there: read as it was, nothing shared.
        let old = Data(#"{"on":true,"areas":{"calendar":"allow"}}"#.utf8)
        let read = try JSONDecoder().decode(PhoneToolsSettings.self, from: old)
        #expect(read.on && read.access(.calendar) == .allow && read.health.isEmpty)
        let again = try JSONDecoder().decode(PhoneToolsSettings.self, from: JSONEncoder().encode(settings))
        #expect(again == settings)
    }

    @Test func aKindNotSharedIsRefusedNamingTheSetting() {
        #expect {
            try ask(["type": .string("blood_oxygen")])
        } throws: { error in
            let message = (error as? DeviceToolError)?.message ?? ""
            return message.contains("Settings → Phone tools → Health") && message.contains("steps")
        }
        #expect(throws: DeviceToolError.self) { try ask(["type": .string("mood")]) }
        #expect(throws: DeviceToolError.missing("type")) { try ask([:]) }
        #expect(throws: DeviceToolError.self) { try ask(["type": .string("steps")], shared: []) }
    }

    @Test func theToolIsHealthsAndOnlyReads() {
        #expect(DeviceTool.healthRead.area == .health)
        #expect(!DeviceTool.healthRead.changes && !DeviceTool.healthRead.asksItself)
        #expect(DeviceArea.health.offersAsking)
        let question = DeviceAsk(.healthRead, .object(["type": .string("sleep"), "start": .string("2026-10-26")]))
        #expect(question.detail.hasPrefix(HealthKind.sleep.label))
    }

    // MARK: Reading the arguments

    @Test func defaultsAreTheLastWeekSummedOrAveraged() throws {
        let steps = try ask(["type": .string("steps")])
        #expect(steps.stat == .sum && steps.bucket == .day && steps.end == now)
        #expect(steps.start == calendar.date(from: DateComponents(year: 2026, month: 10, day: 27)))
        let weight = try ask(["type": .string("Weight")])
        #expect(weight.stat == .average)
        let workouts = try ask(["type": .string("workouts")])
        #expect(workouts.start == calendar.date(from: DateComponents(year: 2026, month: 10, day: 20)))
        // Written the ways an agent writes it.
        #expect(try ask(["type": .string("heart-rate"), "stat": .string("avg")]).kind == .heartRate)
    }

    @Test func aMeasurementCantBeAddedUpAndWordsAreChecked() {
        #expect(throws: DeviceToolError.self) { try ask(["type": .string("weight"), "stat": .string("sum")]) }
        #expect(throws: DeviceToolError.self) { try ask(["type": .string("steps"), "stat": .string("median")]) }
        #expect(throws: DeviceToolError.self) { try ask(["type": .string("steps"), "by": .string("hour")]) }
        #expect(throws: DeviceToolError.self) { try ask(["type": .string("steps"), "start": .string("2026-11-03"), "end": .string("2026-11-01")]) }
    }

    @Test func aLongRangeIsGivenInLargerBucketsToKeepItSmall() throws {
        let month = try ask(["type": .string("steps"), "start": .string("2026-10-03"), "end": .string("2026-11-01")])
        #expect(month.bucket == .day && month.note == nil)
        // The end's day is all of it.
        #expect(month.end == calendar.date(from: DateComponents(year: 2026, month: 11, day: 2)))
        let year = try ask(["type": .string("steps"), "start": .string("2025-11-02"), "by": .string("day")])
        #expect(year.bucket == .week, "53 weeks fit in 60 rows")
        #expect(year.note?.contains("by week") == true)
        let two = try ask(["type": .string("steps"), "start": .string("2020-01-01"), "by": .string("day")])
        #expect(two.bucket == .month)
        #expect(now.timeIntervalSince(two.start) <= HealthAsk.longest, "two years at most")
    }

    // MARK: Units

    @Test func numbersAreInThePersonsUnits() {
        #expect(HealthKind.distance.unit(us: true) == "mi" && HealthKind.distance.unit(us: false) == "km")
        #expect(HealthKind.weight.unit(us: true) == "lb" && HealthKind.weight.unit(us: false) == "kg")
        #expect(HealthKind.bodyTemperature.unit(us: true) == "°F" && HealthKind.water.unit(us: false) == "mL")
        #expect(HealthKind.distance.rounded(3.14159, us: true) == 3.14)
        #expect(HealthKind.weight.rounded(81.26, us: false) == 81.3)
        #expect(HealthKind.steps.rounded(8123.6, us: true) == 8124)
        #expect(HealthKind.water.rounded(64.27, us: true) == 64.3 && HealthKind.water.rounded(1900.4, us: false) == 1900)
        for kind in HealthKind.allCases where kind.hasStatistics { #expect(!kind.unit(us: true).isEmpty, "\(kind)") }
    }

    // MARK: Answers

    @Test func statisticsComeAsRowsAndATotal() throws {
        let steps = try ask(["type": .string("steps")])
        let day = { (d: Int) in self.calendar.date(from: DateComponents(year: 2026, month: 10, day: d))! }
        let answer = HealthAnswer.statistics(steps, values: [(day(28), 9001.4), (day(27), 8123.6)], overall: 17125, us: true, calendar: calendar)
        #expect(answer["unit"]?.string == "steps" && answer["by"]?.string == "day")
        #expect(answer["rows"]?.array?.first?.array?.first?.string == "2026-10-27", "oldest first")
        #expect(answer["rows"]?.array?.first?.array?.last?.number == 8124)
        #expect(answer["total"]?.number == 17125)
        #expect(answer["from"]?.string == "2026-10-27" && answer["to"]?.string == "2026-11-02")
        let none = HealthAnswer.statistics(steps, values: [], overall: nil, us: true, calendar: calendar)
        #expect(none["note"]?.string?.contains("Data Access & Devices") == true, "a no from Health reads as nothing")
        let weight = try ask(["type": .string("weight"), "by": .string("total")])
        let total = HealthAnswer.statistics(weight, values: [], overall: 181.26, us: true, calendar: calendar)
        #expect(total["value"]?.number == 181.3 && total["rows"] == nil && total["unit"]?.string == "lb")
    }

    @Test func atMostSixtyRows() throws {
        let steps = HealthAsk(kind: .steps, start: now.addingTimeInterval(-200 * 86400), end: now, stat: .sum, bucket: .day)
        let values = (0 ..< 200).map { (now.addingTimeInterval(Double(-$0) * 86400), Double($0)) }
        let answer = HealthAnswer.statistics(steps, values: values, overall: nil, us: false, calendar: calendar)
        #expect(answer["rows"]?.array?.count == HealthAsk.most)
        #expect(answer["rows"]?.array?.last?.array?.last?.number == 0, "the newest kept")
    }

    @Test func bloodPressureIsSystolicOverDiastolic() throws {
        let pressure = try ask(["type": .string("blood_pressure")])
        let answer = HealthAnswer.pressure(pressure, values: [(now, 121.4, 78.6)], overall: (120.2, 79.4), calendar: calendar)
        #expect(answer["rows"]?.array?.first?.array?.last?.string == "121/79")
        #expect(answer["overall"]?.string == "120/79")
    }

    @Test func nightsCountOverlapsOnceAndStagesFromOneSource() throws {
        let sleep = try ask(["type": .string("sleep")])
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))! }
        typealias Span = HealthAnswer.SleepSpan
        let spans = [
            // The watch: asleep 23:30–07:00 in stages, with a few minutes awake.
            Span(start: at(1, 23, 30), end: at(2, 2), stage: .core, source: "watch"),
            Span(start: at(2, 2), end: at(2, 3), stage: .deep, source: "watch"),
            Span(start: at(2, 3), end: at(2, 3, 10), stage: .awake, source: "watch"),
            Span(start: at(2, 3, 10), end: at(2, 7), stage: .rem, source: "watch"),
            // The phone: asleep 23:00–06:30, overlapping; counted once.
            Span(start: at(1, 23), end: at(2, 6, 30), stage: .asleep, source: "phone"),
            Span(start: at(1, 22, 45), end: at(2, 7, 15), stage: .inBed, source: "phone"),
        ]
        let answer = HealthAnswer.sleep(sleep, spans: spans, calendar: calendar)
        let night = try #require(answer["nights"]?.array?.first)
        #expect(night["night"]?.string == "2026-11-02", "a night is the day it ends")
        // 23:00–07:00 once: the phone's stretch covers the watch's ten minutes awake.
        #expect(night["asleep_min"]?.number == 480)
        #expect(night["in_bed_min"]?.number == 510)
        #expect(night["bed"]?.string == "23:00" && night["wake"]?.string == "07:00")
        #expect(night["deep_min"]?.number == 60 && night["rem_min"]?.number == 230 && night["awake_min"]?.number == 10)
        #expect(HealthAnswer.night(of: at(2, 14), calendar: calendar) == calendar.startOfDay(for: at(2, 14)), "a nap is that day's")
    }

    @Test func workoutsAreNewestFirstInThePersonsUnits() throws {
        let workouts = try ask(["type": .string("workouts")])
        let run = HealthAnswer.Workout(start: now.addingTimeInterval(-86400), activity: "run", minutes: 31.6, distance: 3.104, energy: 312.4)
        let walk = HealthAnswer.Workout(start: now.addingTimeInterval(-3 * 86400), activity: "walk", minutes: 20, distance: nil, energy: nil)
        let answer = HealthAnswer.workouts(workouts, [walk, run], us: true, calendar: calendar)
        let first = try #require(answer["workouts"]?.array?.first)
        #expect(first["activity"]?.string == "run" && first["min"]?.number == 32)
        #expect(first["distance"]?.string == "3.1 mi" && first["kcal"]?.number == 312)
        #expect(answer["workouts"]?.array?.last?["distance"] == nil)
    }

    // MARK: The watch's (11-10)

    @Test func aWorkoutCarriesItsHeartRateClimbAndRoute() throws {
        let workouts = try ask(["type": .string("workouts")])
        var hike = HealthAnswer.Workout(start: now.addingTimeInterval(-86400), activity: "hike", minutes: 95, distance: 4.2, energy: 610)
        hike.averageBPM = 121.4; hike.maxBPM = 158.6; hike.climb = 304.8
        hike.route = HealthAnswer.Route(start: (40.712776, -74.005974), end: (40.73061, -73.935242), points: 1824, climb: 290)
        let row = try #require(HealthAnswer.workouts(workouts, [hike], us: true, calendar: calendar)["workouts"]?.array?.first)
        #expect(row["avg_bpm"]?.number == 121 && row["max_bpm"]?.number == 159)
        #expect(row["climb"]?.string == "1000 ft", "the workout's own climb before the track's")
        #expect(row["route"]?["start"]?.string == "40.713,-74.006" && row["route"]?["points"]?.number == 1824)
        // Without them, none of it.
        let plain = HealthAnswer.Workout(start: now, activity: "walk", minutes: 20, distance: nil, energy: nil)
        let bare = try #require(HealthAnswer.workouts(workouts, [plain], us: false, calendar: calendar)["workouts"]?.array?.first)
        #expect(bare["avg_bpm"] == nil && bare["climb"] == nil && bare["route"] == nil)
        // The climb along a track: rises added, falls and GPS jitter left out.
        #expect(abs(HealthAnswer.Route.climb([100, 100.4, 99.8, 110, 105, 120, 119.5]) - 25.2) < 0.001)
    }

    @Test func ecgsAndHeartNotificationsAreLists() throws {
        let shared: [HealthKind] = [.ecg, .heartAlerts]
        let ecgs = try ask(["type": .string("ecg")], shared: shared)
        #expect(calendar.dateComponents([.day], from: ecgs.start, to: now).day == 89, "three months back by default: they're rare")
        let answer = HealthAnswer.ecg(ecgs, [
            .init(at: now.addingTimeInterval(-7200), result: "sinus rhythm", averageBPM: 64.4, symptoms: "none"),
            .init(at: now.addingTimeInterval(-86400 * 30), result: "atrial fibrillation", averageBPM: 98, symptoms: "some"),
        ], calendar: calendar)
        let newest = try #require(answer["recordings"]?.array?.first)
        #expect(newest["result"]?.string == "sinus rhythm" && newest["avg_bpm"]?.number == 64 && newest["symptoms"]?.string == "none")
        #expect(answer["note"]?.string?.contains("not a diagnosis") == true)
        let alerts = HealthAnswer.alerts(try ask(["type": .string("heart_alerts")], shared: shared), [
            .init(at: now.addingTimeInterval(-3600), kind: "high heart rate", threshold: 120),
            .init(at: now.addingTimeInterval(-86400), kind: "irregular rhythm", threshold: nil),
        ], calendar: calendar)
        #expect(alerts["alerts"]?.array?.map { $0["kind"]?.string } == ["high heart rate", "irregular rhythm"])
        #expect(alerts["alerts"]?.array?.first?["threshold_bpm"]?.number == 120)
        #expect(HealthAnswer.alerts(try ask(["type": .string("heart_alerts")], shared: shared), [], calendar: calendar)["note"] != nil)
    }

    @Test func theWatchsKindsAreMeasuredInTheirOwnUnits() {
        #expect(HealthKind.wristTemperature.unit(us: false) == "°C" && HealthKind.wristTemperature.decimals(us: false) == 2)
        #expect(HealthKind.walkingSteadiness.unit(us: true) == "%" && HealthKind.afibBurden.unit(us: true) == "%")
        #expect(HealthKind.noise.unit(us: true) == "dBA" && HealthKind.daylight.isAdded && !HealthKind.noise.isAdded)
        #expect(HealthKind.workoutRoutes.group == .workouts && HealthKind.ecg.group == .heart && HealthKind.headphones.group == .hearing)
        #expect(!HealthKind.ecg.hasStatistics && !HealthKind.heartAlerts.hasStatistics)
    }

    @Test func standHoursAndMindfulMinutesAreAddedUpByDay() throws {
        let stood = try ask(["type": .string("steps")])   // the bucketing is the same for any kind
        let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9))!
        let buckets = HealthAnswer.buckets(stood, [(morning, 1), (morning.addingTimeInterval(3600), 1), (now, 1)], calendar: calendar)
        #expect(buckets.sorted { $0.0 < $1.0 }.map(\.1) == [2, 1])
    }

    @Test func aDeviceWithoutHealthSaysWhereHealthIs() async {
        #if os(macOS)
        await #expect {
            try await DeviceHealth.read(.object(["type": .string("steps")]), shared: [.steps])
        } throws: { ($0 as? DeviceToolError)?.message.contains("iPhone") == true }
        #else
        #expect(Bool(true))
        #endif
    }
}
