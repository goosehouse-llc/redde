import Foundation
#if os(iOS)
import HealthKit
#endif

/// Health as a phone tool (asked 2026-11-02, "More health data"): the agent reads the Apple
/// Health data the person chose to share, each kind on its own in Settings → Phone tools →
/// Health, through one tool, `phone_health_read`. Read only: nothing is ever written to Health.
/// Answers are kept small (numbers with their units, at most 60 rows), since they go into the
/// agent's prompt. Health-aware days (`HealthDays`) is a different thing: a one-line summary for
/// the daily jobs, with its own switch.
///
/// One kind of data the agent can ask for. The raw value is its name to the agent.
nonisolated enum HealthKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case steps
    case distance = "walking_running_distance"
    case activeEnergy = "active_energy"
    case exerciseMinutes = "exercise_minutes"
    case standHours = "stand_hours"
    case flights = "flights_climbed"
    case weight
    case bmi
    case bodyFat = "body_fat"
    case heartRate = "heart_rate"
    case restingHeartRate = "resting_heart_rate"
    case heartRateVariability = "heart_rate_variability"
    case bloodPressure = "blood_pressure"
    case vo2Max = "vo2_max"
    case sleep
    case respiratoryRate = "respiratory_rate"
    case bloodOxygen = "blood_oxygen"
    case bodyTemperature = "body_temperature"
    case water
    case caffeine
    case dietaryEnergy = "dietary_energy"
    case protein
    case mindfulMinutes = "mindful_minutes"
    case workouts
    case menstrualFlow = "menstrual_flow"

    var id: String { rawValue }

    /// How Settings groups them.
    enum Group: String, CaseIterable, Sendable, Identifiable {
        case activity, body, heart, sleep, vitals, nutrition, mindfulness, workouts, cycle
        var id: String { rawValue }

        var label: String {
            switch self {
            case .activity: String(localized: "Activity", comment: "A group of Apple Health data (Settings → Phone tools → Health)")
            case .body: String(localized: "Body Measurements", comment: "A group of Apple Health data (Settings → Phone tools → Health)")
            case .heart: String(localized: "Heart", comment: "A group of Apple Health data (Settings → Phone tools → Health)")
            case .sleep: String(localized: "Sleep", comment: "A group of Apple Health data (Settings → Phone tools → Health)")
            case .vitals: String(localized: "Vitals", comment: "A group of Apple Health data (Settings → Phone tools → Health)")
            case .nutrition: String(localized: "Nutrition", comment: "A group of Apple Health data (Settings → Phone tools → Health)")
            case .mindfulness: String(localized: "Mindfulness", comment: "A group of Apple Health data (Settings → Phone tools → Health)")
            case .workouts: String(localized: "Workouts", comment: "A group of Apple Health data (Settings → Phone tools → Health)")
            case .cycle: String(localized: "Cycle Tracking", comment: "A group of Apple Health data (Settings → Phone tools → Health)")
            }
        }

        var kinds: [HealthKind] { HealthKind.allCases.filter { $0.group == self } }
    }

    var group: Group {
        switch self {
        case .steps, .distance, .activeEnergy, .exerciseMinutes, .standHours, .flights: .activity
        case .weight, .bmi, .bodyFat: .body
        case .heartRate, .restingHeartRate, .heartRateVariability, .bloodPressure, .vo2Max: .heart
        case .sleep: .sleep
        case .respiratoryRate, .bloodOxygen, .bodyTemperature: .vitals
        case .water, .caffeine, .dietaryEnergy, .protein: .nutrition
        case .mindfulMinutes: .mindfulness
        case .workouts: .workouts
        case .menstrualFlow: .cycle
        }
    }

    var label: String {
        switch self {
        case .steps: String(localized: "Steps", comment: "Apple Health data")
        case .distance: String(localized: "Walking + Running Distance", comment: "Apple Health data")
        case .activeEnergy: String(localized: "Active Energy", comment: "Apple Health data")
        case .exerciseMinutes: String(localized: "Exercise Minutes", comment: "Apple Health data")
        case .standHours: String(localized: "Stand Hours", comment: "Apple Health data")
        case .flights: String(localized: "Flights Climbed", comment: "Apple Health data")
        case .weight: String(localized: "Weight", comment: "Apple Health data")
        case .bmi: String(localized: "Body Mass Index", comment: "Apple Health data")
        case .bodyFat: String(localized: "Body Fat Percentage", comment: "Apple Health data")
        case .heartRate: String(localized: "Heart Rate", comment: "Apple Health data")
        case .restingHeartRate: String(localized: "Resting Heart Rate", comment: "Apple Health data")
        case .heartRateVariability: String(localized: "Heart Rate Variability", comment: "Apple Health data")
        case .bloodPressure: String(localized: "Blood Pressure", comment: "Apple Health data")
        case .vo2Max: String(localized: "Cardio Fitness (VO₂ max)", comment: "Apple Health data")
        case .sleep: String(localized: "Sleep", comment: "Apple Health data")
        case .respiratoryRate: String(localized: "Respiratory Rate", comment: "Apple Health data")
        case .bloodOxygen: String(localized: "Blood Oxygen", comment: "Apple Health data")
        case .bodyTemperature: String(localized: "Body Temperature", comment: "Apple Health data")
        case .water: String(localized: "Water", comment: "Apple Health data")
        case .caffeine: String(localized: "Caffeine", comment: "Apple Health data")
        case .dietaryEnergy: String(localized: "Dietary Energy", comment: "Apple Health data")
        case .protein: String(localized: "Protein", comment: "Apple Health data")
        case .mindfulMinutes: String(localized: "Mindful Minutes", comment: "Apple Health data")
        case .workouts: String(localized: "Workouts", comment: "Apple Health data")
        case .menstrualFlow: String(localized: "Menstrual Flow", comment: "Apple Health data")
        }
    }

    /// How it is read and what its answer looks like.
    enum Shape: Sendable { case added, measured, stood, mindful, sleep, workouts, flow }

    var shape: Shape {
        switch self {
        case .steps, .distance, .activeEnergy, .exerciseMinutes, .flights, .water, .caffeine, .dietaryEnergy, .protein: .added
        case .weight, .bmi, .bodyFat, .heartRate, .restingHeartRate, .heartRateVariability, .bloodPressure, .vo2Max,
             .respiratoryRate, .bloodOxygen, .bodyTemperature: .measured
        case .standHours: .stood
        case .mindfulMinutes: .mindful
        case .sleep: .sleep
        case .workouts: .workouts
        case .menstrualFlow: .flow
        }
    }

    /// Its numbers can be read as a statistic: added up, averaged, the least, the most, the latest.
    var hasStatistics: Bool { [.added, .measured, .stood, .mindful].contains(shape) }
    /// Added up (steps, water) rather than measured (weight, heart rate): what "sum" means.
    var isAdded: Bool { [.added, .stood, .mindful].contains(shape) }

    /// The unit its numbers are given in, by the person's units (`MeasureUnits`). Words to the agent.
    func unit(us: Bool) -> String {
        switch self {
        case .steps: "steps"
        case .distance: us ? "mi" : "km"
        case .activeEnergy, .dietaryEnergy: "kcal"
        case .exerciseMinutes, .mindfulMinutes: "min"
        case .standHours: "hours"
        case .flights: "flights"
        case .weight: us ? "lb" : "kg"
        case .bmi: "BMI"
        case .bodyFat, .bloodOxygen: "%"
        case .heartRate, .restingHeartRate: "bpm"
        case .heartRateVariability: "ms"
        case .bloodPressure: "mmHg"
        case .vo2Max: "mL/kg/min"
        case .respiratoryRate: "breaths/min"
        case .bodyTemperature: us ? "°F" : "°C"
        case .water: us ? "fl oz" : "mL"
        case .caffeine: "mg"
        case .protein: "g"
        case .sleep, .workouts, .menstrualFlow: ""
        }
    }

    /// How many decimals its numbers keep: enough to mean something, few enough to read.
    func decimals(us: Bool) -> Int {
        switch self {
        case .distance: 2
        case .weight, .bmi, .bodyFat, .bloodOxygen, .vo2Max, .respiratoryRate, .bodyTemperature: 1
        case .water: us ? 1 : 0
        default: 0
        }
    }

    /// A number rounded as it is given.
    func rounded(_ value: Double, us: Bool) -> Double {
        let scale = pow(10, Double(decimals(us: us)))
        return (value * scale).rounded() / scale
    }
}

/// What the agent asked `phone_health_read` for, read and checked before Health is touched.
nonisolated struct HealthAsk: Equatable, Sendable {
    enum Stat: String, CaseIterable, Sendable { case sum, average, min, max, latest }
    enum Bucket: String, CaseIterable, Sendable { case day, week, month, total }

    var kind: HealthKind
    var start: Date
    var end: Date
    var stat: Stat
    var bucket: Bucket
    /// Said with the answer: the bucket was made larger to keep within `most` rows.
    var note: String?

    /// At most this many rows go back to the agent.
    static let most = 60
    /// How far back it may look: two years.
    static let longest: TimeInterval = 2 * 366 * 86400

    /// Reads the arguments: `type` (required), `start`, `end`, `stat`, `by`. `shared` are the
    /// kinds the person chose to share; anything else is refused, naming the setting.
    init(_ args: JSONValue, shared: [HealthKind], now: Date = .now, calendar: Calendar = .current) throws {
        let name = try args.required("type").lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        guard let kind = HealthKind(rawValue: name) else {
            throw DeviceToolError("There is no Health type \"\(name)\". The ones the user shares: \(Self.list(shared)).")
        }
        guard shared.contains(kind) else {
            throw DeviceToolError("The user doesn't share \(kind.rawValue) with you: it is off in Redde on the iPhone (Settings → Phone tools → Health). "
                                  + "Shared: \(Self.list(shared)).")
        }
        self.kind = kind
        // The last week by default (two for workouts), today included.
        let today = calendar.startOfDay(for: now)
        let back = kind == .workouts ? 13 : 6
        start = try args.date("start") ?? calendar.date(byAdding: .day, value: -back, to: today) ?? today
        end = try args.date("end") ?? now
        // "Up to the 14th" means the whole of the 14th.
        if let text = args["end"]?.string, DeviceDates.isDayOnly(text) { end = calendar.date(byAdding: .day, value: 1, to: end) ?? end }
        guard end > start else { throw DeviceToolError("\"end\" has to be after \"start\".") }
        if end.timeIntervalSince(start) > Self.longest { start = end.addingTimeInterval(-Self.longest) }

        let statName = args["stat"]?.string?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        let asked = statName.isEmpty ? nil : (Stat(rawValue: statName) ?? (statName == "avg" || statName == "mean" ? .average : nil))
        if !statName.isEmpty, asked == nil { throw DeviceToolError("\"stat\" is one of sum, average, min, max or latest.") }
        stat = asked ?? (kind.isAdded ? .sum : .average)
        if kind.hasStatistics, stat == .sum, !kind.isAdded {
            throw DeviceToolError("\(kind.rawValue) is measured, not added up: ask for average, min, max or latest.")
        }

        let byName = args["by"]?.string?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        guard byName.isEmpty || Bucket(rawValue: byName) != nil else { throw DeviceToolError("\"by\" is one of day, week, month or total.") }
        let wanted = Bucket(rawValue: byName) ?? .day
        bucket = Self.bucket(wanted, from: start, to: end, calendar: calendar)
        note = bucket != wanted ? "Given by \(bucket.rawValue) rather than by \(wanted.rawValue), to keep within \(Self.most) rows." : nil
    }

    init(kind: HealthKind, start: Date, end: Date, stat: Stat, bucket: Bucket, note: String? = nil) {
        self.kind = kind; self.start = start; self.end = end; self.stat = stat; self.bucket = bucket; self.note = note
    }

    /// The bucket asked for, or the next larger one that keeps within `most` rows.
    static func bucket(_ wanted: Bucket, from start: Date, to end: Date, calendar: Calendar) -> Bucket {
        var bucket = wanted
        while bucket != .total, rows(bucket, from: start, to: end, calendar: calendar) > most {
            bucket = Bucket.allCases[(Bucket.allCases.firstIndex(of: bucket) ?? 0) + 1]
        }
        return bucket
    }

    static func rows(_ bucket: Bucket, from start: Date, to end: Date, calendar: Calendar) -> Int {
        let component: Calendar.Component
        switch bucket {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .total: return 1
        }
        let first = Self.first(of: bucket, at: start, calendar: calendar)
        return (calendar.dateComponents([component], from: first, to: end).value(for: component) ?? 0) + 1
    }

    /// Where the bucket a moment falls in begins: midnight, the week's first day, the first of the month.
    static func first(of bucket: Bucket, at date: Date, calendar: Calendar) -> Date {
        switch bucket {
        case .day, .total: calendar.startOfDay(for: date)
        case .week: calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        case .month: calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }

    /// How long one bucket is.
    var step: DateComponents {
        switch bucket {
        case .day: DateComponents(day: 1)
        case .week: DateComponents(weekOfYear: 1)
        case .month: DateComponents(month: 1)
        case .total: DateComponents(day: 3 * 366)
        }
    }

    private static func list(_ kinds: [HealthKind]) -> String {
        kinds.isEmpty ? "none" : kinds.map(\.rawValue).joined(separator: ", ")
    }
}

/// Puts what was read into the small answer the agent gets.
nonisolated enum HealthAnswer {
    /// "2026-11-02" for a day, a week or a month: its first day.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// Statistics by bucket: `values` are each bucket's start and number (already in the unit),
    /// buckets with nothing in them left out. `overall` is the whole range's, when there is one.
    static func statistics(_ ask: HealthAsk, values: [(Date, Double)], overall: Double?, us: Bool, calendar: Calendar = .current) -> JSONValue {
        let kind = ask.kind
        var fields: [String: JSONValue] = [
            "type": .string(kind.rawValue), "unit": .string(kind.unit(us: us)), "stat": .string(ask.stat.rawValue),
            "from": .string(day(ask.start, calendar: calendar)), "to": .string(day(ask.end.addingTimeInterval(-1), calendar: calendar)),
        ]
        if ask.bucket == .total {
            fields["value"] = overall.map { .number(kind.rounded($0, us: us)) } ?? .null
        } else {
            fields["by"] = .string(ask.bucket.rawValue)
            fields["rows"] = .array(values.sorted { $0.0 < $1.0 }.suffix(HealthAsk.most).map {
                .array([.string(day($0.0, calendar: calendar)), .number(kind.rounded($0.1, us: us))])
            })
            if let overall { fields[ask.stat == .sum ? "total" : "overall"] = .number(kind.rounded(overall, us: us)) }
        }
        var notes = [ask.note].compactMap { $0 }
        if values.isEmpty, overall == nil { notes.append(nothing) }
        else if ask.bucket != .total { notes.append("Periods with no data are left out.") }
        if !notes.isEmpty { fields["note"] = .string(notes.joined(separator: " ")) }
        return .object(fields)
    }

    /// Blood pressure: systolic over diastolic, both in mmHg.
    static func pressure(_ ask: HealthAsk, values: [(Date, Double, Double)], overall: (Double, Double)?, calendar: Calendar = .current) -> JSONValue {
        func said(_ pair: (Double, Double)) -> String { "\(Int(pair.0.rounded()))/\(Int(pair.1.rounded()))" }
        var fields: [String: JSONValue] = [
            "type": .string(ask.kind.rawValue), "unit": .string("mmHg (systolic/diastolic)"), "stat": .string(ask.stat.rawValue),
            "from": .string(day(ask.start, calendar: calendar)), "to": .string(day(ask.end.addingTimeInterval(-1), calendar: calendar)),
        ]
        if ask.bucket == .total {
            fields["value"] = overall.map { .string(said($0)) } ?? .null
        } else {
            fields["by"] = .string(ask.bucket.rawValue)
            fields["rows"] = .array(values.sorted { $0.0 < $1.0 }.suffix(HealthAsk.most).map { .array([.string(day($0.0, calendar: calendar)), .string(said(($0.1, $0.2)))]) })
            if let overall { fields["overall"] = .string(said(overall)) }
        }
        let notes = [ask.note, values.isEmpty && overall == nil ? nothing : nil].compactMap { $0 }
        if !notes.isEmpty { fields["note"] = .string(notes.joined(separator: " ")) }
        return .object(fields)
    }

    /// The latest reading in the range.
    static func latest(_ kind: HealthKind, value: String?, at: Date?, us: Bool) -> JSONValue {
        guard let value, let at else { return .object(["type": .string(kind.rawValue), "latest": .null, "note": .string(nothing)]) }
        return .object(["type": .string(kind.rawValue), "unit": .string(kind == .bloodPressure ? "mmHg" : kind.unit(us: us)),
                        "latest": .string(value), "at": .string(DeviceDates.string(at))])
    }

    /// When nothing came back: there may be none, or Health may not let Redde read it, which an
    /// app is never told (Health hides a "no" to reading as an empty answer).
    static let nothing = "Nothing found in that range. Either there is no data, or Health doesn't let Redde read it: "
        + "the user can check on the iPhone in Settings → Health → Data Access & Devices → Redde."

    // MARK: Sleep

    /// One stretch in bed or asleep, as Health keeps it.
    struct SleepSpan: Equatable, Sendable {
        enum Stage: String, Sendable { case inBed, asleep, core, deep, rem, awake }
        var start: Date
        var end: Date
        var stage: Stage
        /// Which app or device wrote it: overlapping stretches from a watch and a phone are counted once.
        var source: String
    }

    /// The night a stretch belongs to: the day it ends on, six hours on from its start, so an
    /// 11 PM bedtime and a 1 AM one are the same night, and an afternoon nap is that day's.
    static func night(of start: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: start.addingTimeInterval(6 * 3600))
    }

    /// Nights, newest last, at most `HealthAsk.most`: time asleep (overlaps counted once), in bed,
    /// from when to when, and the stages from whichever source recorded the most.
    static func sleep(_ ask: HealthAsk, spans: [SleepSpan], calendar: Calendar = .current) -> JSONValue {
        let nights = Dictionary(grouping: spans) { night(of: $0.start, calendar: calendar) }
        let rows: [JSONValue] = nights.keys.sorted().suffix(HealthAsk.most).map { night in
            let these = nights[night] ?? []
            let sleeping = these.filter { $0.stage != .inBed && $0.stage != .awake }
            var row: [String: JSONValue] = ["night": .string(day(night, calendar: calendar))]
            row["asleep_min"] = .number((union(sleeping) / 60).rounded())
            let bed = union(these.filter { $0.stage == .inBed })
            if bed > 0 { row["in_bed_min"] = .number((bed / 60).rounded()) }
            if let first = sleeping.map(\.start).min(), let last = sleeping.map(\.end).max() {
                row["bed"] = .string(clock(first, calendar: calendar)); row["wake"] = .string(clock(last, calendar: calendar))
            }
            // Stages from one source: two sources' stages can't be added together.
            let staged = these.filter { [.core, .deep, .rem, .awake].contains($0.stage) }
            let best = Dictionary(grouping: staged, by: \.source).max { total($0.value) < total($1.value) }?.value ?? []
            for stage in [SleepSpan.Stage.deep, .core, .rem, .awake] {
                let minutes = (best.filter { $0.stage == stage }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 60).rounded()
                if minutes > 0 { row["\(stage.rawValue)_min"] = .number(minutes) }
            }
            return .object(row)
        }
        var fields: [String: JSONValue] = ["type": .string("sleep"), "nights": .array(rows),
                                           "from": .string(day(ask.start, calendar: calendar)), "to": .string(day(ask.end.addingTimeInterval(-1), calendar: calendar))]
        if rows.isEmpty { fields["note"] = .string(nothing) }
        return .object(fields)
    }

    /// The time covered by stretches that may overlap, each moment counted once.
    static func union(_ spans: [SleepSpan]) -> TimeInterval {
        var total: TimeInterval = 0
        var current: (Date, Date)?
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let (from, to) = current, span.start <= to {
                current = (from, max(to, span.end))
            } else {
                if let (from, to) = current { total += to.timeIntervalSince(from) }
                current = (span.start, span.end)
            }
        }
        if let (from, to) = current { total += to.timeIntervalSince(from) }
        return total
    }

    private static func total(_ spans: [SleepSpan]) -> TimeInterval {
        spans.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    // MARK: Workouts and the rest

    /// One workout, as the agent is told of it.
    struct Workout: Equatable, Sendable {
        var start: Date
        var activity: String
        var minutes: Double
        var distance: Double?
        var energy: Double?
    }

    /// Newest first, at most `HealthAsk.most`.
    static func workouts(_ ask: HealthAsk, _ found: [Workout], us: Bool, calendar: Calendar = .current) -> JSONValue {
        let rows: [JSONValue] = found.sorted { $0.start > $1.start }.prefix(HealthAsk.most).map { workout in
            var row: [String: JSONValue] = ["start": .string(DeviceDates.string(workout.start)), "activity": .string(workout.activity),
                                            "min": .number(workout.minutes.rounded())]
            if let distance = workout.distance, distance > 0 {
                row["distance"] = .string("\(HealthKind.distance.rounded(distance, us: us)) \(HealthKind.distance.unit(us: us))")
            }
            if let energy = workout.energy, energy > 0 { row["kcal"] = .number(energy.rounded()) }
            return .object(row)
        }
        var fields: [String: JSONValue] = ["type": .string("workouts"), "workouts": .array(rows),
                                           "from": .string(day(ask.start, calendar: calendar)), "to": .string(day(ask.end.addingTimeInterval(-1), calendar: calendar))]
        if found.count > HealthAsk.most { fields["more"] = .number(Double(found.count - HealthAsk.most)) }
        if rows.isEmpty { fields["note"] = .string(nothing) }
        return .object(fields)
    }

    /// Menstrual flow: one row a day it was logged, at most `HealthAsk.most`, newest last.
    static func flow(_ ask: HealthAsk, days: [(Date, String)], calendar: Calendar = .current) -> JSONValue {
        let rows: [JSONValue] = days.sorted { $0.0 < $1.0 }.suffix(HealthAsk.most).map { .array([.string(day($0.0, calendar: calendar)), .string($0.1)]) }
        var fields: [String: JSONValue] = ["type": .string(HealthKind.menstrualFlow.rawValue), "days": .array(rows),
                                           "from": .string(day(ask.start, calendar: calendar)), "to": .string(day(ask.end.addingTimeInterval(-1), calendar: calendar))]
        if rows.isEmpty { fields["note"] = .string(nothing) }
        return .object(fields)
    }

    /// Category samples (stood hours, mindful sessions) put into buckets: `values` are each
    /// sample's moment and amount, summed per bucket.
    static func buckets(_ ask: HealthAsk, _ values: [(Date, Double)], calendar: Calendar = .current) -> [(Date, Double)] {
        let grouped = Dictionary(grouping: values) { HealthAsk.first(of: ask.bucket, at: $0.0, calendar: calendar) }
        return grouped.map { ($0.key, $0.value.reduce(0) { $0 + $1.1 }) }
    }
}

/// Reads Health for `phone_health_read`. Only on a device with Apple Health: an iPhone, an iPad
/// on iPadOS 17 or later; never a Mac.
nonisolated enum DeviceHealth {
    #if os(iOS)
    private static let store = HKHealthStore()
    static var available: Bool { HKHealthStore.isHealthDataAvailable() }
    #else
    static let available = false
    #endif

    /// `type`, and optionally `start`, `end`, `stat`, `by`. `shared` is what the person shares.
    static func read(_ args: JSONValue, shared: [HealthKind], us: Bool = MeasureUnits.usesUS(), now: Date = .now) async throws -> JSONValue {
        guard available else {
            throw DeviceToolError("This device has no Apple Health. Health is read on the user's iPhone: ask again with Redde open there.")
        }
        let ask = try HealthAsk(args, shared: shared, now: now)
        #if os(iOS)
        return try await run(ask, us: us)
        #else
        _ = ask
        throw DeviceToolError("This device has no Apple Health.")
        #endif
    }

    #if os(iOS)
    /// Asks iOS for reading these kinds, at the moment they are turned on. iOS asks the person
    /// once per kind and never says whether they said yes to reading: a "no" reads as no data.
    static func allow(_ kinds: [HealthKind]) async -> Bool {
        guard available else { return false }
        let types = Set(kinds.flatMap(objectTypes))
        guard !types.isEmpty else { return true }
        do { try await store.requestAuthorization(toShare: [], read: types); return true } catch { return false }
    }

    static func objectTypes(_ kind: HealthKind) -> [HKObjectType] {
        switch kind {
        case .bloodPressure: [HKQuantityType(.bloodPressureSystolic), HKQuantityType(.bloodPressureDiastolic)]
        case .sleep: [HKCategoryType(.sleepAnalysis)]
        case .standHours: [HKCategoryType(.appleStandHour)]
        case .mindfulMinutes: [HKCategoryType(.mindfulSession)]
        case .menstrualFlow: [HKCategoryType(.menstrualFlow)]
        case .workouts: [HKObjectType.workoutType()]
        default: quantity(kind).map { [$0] } ?? []
        }
    }

    private static func quantity(_ kind: HealthKind) -> HKQuantityType? {
        switch kind {
        case .steps: HKQuantityType(.stepCount)
        case .distance: HKQuantityType(.distanceWalkingRunning)
        case .activeEnergy: HKQuantityType(.activeEnergyBurned)
        case .exerciseMinutes: HKQuantityType(.appleExerciseTime)
        case .flights: HKQuantityType(.flightsClimbed)
        case .weight: HKQuantityType(.bodyMass)
        case .bmi: HKQuantityType(.bodyMassIndex)
        case .bodyFat: HKQuantityType(.bodyFatPercentage)
        case .heartRate: HKQuantityType(.heartRate)
        case .restingHeartRate: HKQuantityType(.restingHeartRate)
        case .heartRateVariability: HKQuantityType(.heartRateVariabilitySDNN)
        case .vo2Max: HKQuantityType(.vo2Max)
        case .respiratoryRate: HKQuantityType(.respiratoryRate)
        case .bloodOxygen: HKQuantityType(.oxygenSaturation)
        case .bodyTemperature: HKQuantityType(.bodyTemperature)
        case .water: HKQuantityType(.dietaryWater)
        case .caffeine: HKQuantityType(.dietaryCaffeine)
        case .dietaryEnergy: HKQuantityType(.dietaryEnergyConsumed)
        case .protein: HKQuantityType(.dietaryProtein)
        default: nil
        }
    }

    /// The unit a number is read in, and what it is multiplied by (fractions become percent).
    private static func unit(_ kind: HealthKind, us: Bool) -> (HKUnit, Double) {
        switch kind {
        case .steps, .flights, .bmi: (.count(), 1)
        case .distance: (us ? .mile() : .meterUnit(with: .kilo), 1)
        case .activeEnergy, .dietaryEnergy: (.kilocalorie(), 1)
        case .exerciseMinutes: (.minute(), 1)
        case .weight: (us ? .pound() : .gramUnit(with: .kilo), 1)
        case .bodyFat, .bloodOxygen: (.percent(), 100)
        case .heartRate, .restingHeartRate, .respiratoryRate: (.count().unitDivided(by: .minute()), 1)
        case .heartRateVariability: (.secondUnit(with: .milli), 1)
        case .bloodPressure: (.millimeterOfMercury(), 1)
        case .vo2Max: (HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute())), 1)
        case .bodyTemperature: (us ? .degreeFahrenheit() : .degreeCelsius(), 1)
        case .water: (us ? .fluidOunceUS() : .literUnit(with: .milli), 1)
        case .caffeine: (.gramUnit(with: .milli), 1)
        case .protein: (.gram(), 1)
        default: (.count(), 1)
        }
    }

    private static func run(_ ask: HealthAsk, us: Bool) async throws -> JSONValue {
        let calendar = Calendar.current
        switch ask.kind.shape {
        case .added, .measured:
            if ask.kind == .bloodPressure { return try await pressure(ask) }
            guard let type = quantity(ask.kind) else { throw DeviceToolError("That kind can't be read here.") }
            let (unit, scale) = unit(ask.kind, us: us)
            if ask.stat == .latest {
                let sample = await samples(type, ask, limit: 1, newestFirst: true).first as? HKQuantitySample
                let value = sample.map { ask.kind.rounded($0.quantity.doubleValue(for: unit) * scale, us: us) }
                return HealthAnswer.latest(ask.kind, value: value.map { "\($0)" }, at: sample?.endDate, us: us)
            }
            let options: HKStatisticsOptions = switch ask.stat {
            case .sum: .cumulativeSum
            case .min: .discreteMin
            case .max: .discreteMax
            default: ask.kind.isAdded ? .cumulativeSum : .discreteAverage
            }
            // Added kinds averaged mean "per day (or week…) on average": the buckets' sums, averaged.
            let averagedSums = ask.kind.isAdded && ask.stat == .average
            func number(_ statistics: HKStatistics?) -> Double? {
                let quantity: HKQuantity? = switch options {
                case .cumulativeSum: statistics?.sumQuantity()
                case .discreteMin: statistics?.minimumQuantity()
                case .discreteMax: statistics?.maximumQuantity()
                default: statistics?.averageQuantity()
                }
                return quantity.map { $0.doubleValue(for: unit) * scale }
            }
            let values = try await collection(type, ask, options: options, calendar: calendar).compactMap { start, statistics in
                number(statistics).map { (start, $0) }
            }
            var overall: Double?
            if averagedSums {
                overall = values.isEmpty ? nil : values.reduce(0) { $0 + $1.1 } / Double(values.count)
            } else {
                overall = number(await single(type, ask, options: options))
            }
            return HealthAnswer.statistics(ask, values: values, overall: overall, us: us, calendar: calendar)
        case .stood, .mindful:
            let type = objectTypes(ask.kind)[0] as! HKSampleType
            let found = await samples(type, ask)
            let amounts: [(Date, Double)] = found.compactMap { sample in
                guard let sample = sample as? HKCategorySample else { return nil }
                if ask.kind == .standHours { return sample.value == HKCategoryValueAppleStandHour.stood.rawValue ? (sample.startDate, 1) : nil }
                return (sample.startDate, sample.endDate.timeIntervalSince(sample.startDate) / 60)
            }
            let buckets = HealthAnswer.buckets(ask, amounts, calendar: calendar)
            let overall: Double? = switch ask.stat {
            case .sum: amounts.isEmpty ? nil : amounts.reduce(0) { $0 + $1.1 }
            case .min: buckets.map(\.1).min()
            case .max: buckets.map(\.1).max()
            default: buckets.isEmpty ? nil : buckets.reduce(0) { $0 + $1.1 } / Double(buckets.count)
            }
            if ask.stat == .latest {
                // The latest day's total: one stood hour or one session alone says little.
                let last = HealthAnswer.buckets(HealthAsk(kind: ask.kind, start: ask.start, end: ask.end, stat: .sum, bucket: .day), amounts, calendar: calendar)
                    .max { $0.0 < $1.0 }
                let at = found.map(\.endDate).max()
                return HealthAnswer.latest(ask.kind, value: last.map { "\(Int($0.1.rounded())) on \(HealthAnswer.day($0.0, calendar: calendar))" }, at: at, us: us)
            }
            return HealthAnswer.statistics(ask, values: buckets, overall: overall, us: us, calendar: calendar)
        case .sleep:
            let found = await samples(HKCategoryType(.sleepAnalysis), ask)
            let spans: [HealthAnswer.SleepSpan] = found.compactMap { sample in
                guard let sample = sample as? HKCategorySample, let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { return nil }
                let stage: HealthAnswer.SleepSpan.Stage = switch value {
                case .inBed: .inBed
                case .awake: .awake
                case .asleepCore: .core
                case .asleepDeep: .deep
                case .asleepREM: .rem
                default: .asleep
                }
                return HealthAnswer.SleepSpan(start: sample.startDate, end: sample.endDate, stage: stage, source: sample.sourceRevision.source.bundleIdentifier)
            }
            return HealthAnswer.sleep(ask, spans: spans, calendar: calendar)
        case .workouts:
            let found = await samples(HKObjectType.workoutType(), ask, limit: HealthAsk.most + 40, newestFirst: true)
            let distances: [HKQuantityType] = [HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling), HKQuantityType(.distanceSwimming),
                                               HKQuantityType(.distanceDownhillSnowSports), HKQuantityType(.distanceWheelchair)]
            let (distanceUnit, _) = unit(.distance, us: us)
            let workouts: [HealthAnswer.Workout] = found.compactMap { sample in
                guard let workout = sample as? HKWorkout else { return nil }
                let distance = distances.lazy.compactMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: distanceUnit) }.first
                let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
                return HealthAnswer.Workout(start: workout.startDate, activity: HealthDays.name(of: workout.workoutActivityType),
                                            minutes: workout.duration / 60, distance: distance, energy: energy)
            }
            return HealthAnswer.workouts(ask, workouts, us: us, calendar: calendar)
        case .flow:
            let found = await samples(HKCategoryType(.menstrualFlow), ask)
            let days: [(Date, String)] = found.compactMap { sample in
                guard let sample = sample as? HKCategorySample else { return nil }
                let level = switch sample.value {
                case HKCategoryValueVaginalBleeding.light.rawValue: "light"
                case HKCategoryValueVaginalBleeding.medium.rawValue: "medium"
                case HKCategoryValueVaginalBleeding.heavy.rawValue: "heavy"
                case HKCategoryValueVaginalBleeding.none.rawValue: "none"
                default: "logged"
                }
                return (calendar.startOfDay(for: sample.startDate), level)
            }
            // One a day: the heaviest logged.
            let order = ["none", "logged", "light", "medium", "heavy"]
            let byDay = Dictionary(days, uniquingKeysWith: { (order.firstIndex(of: $0) ?? 0) >= (order.firstIndex(of: $1) ?? 0) ? $0 : $1 })
            return HealthAnswer.flow(ask, days: byDay.map { ($0.key, $0.value) }, calendar: calendar)
        }
    }

    private static func pressure(_ ask: HealthAsk) async throws -> JSONValue {
        let calendar = Calendar.current
        let systolic = HKQuantityType(.bloodPressureSystolic), diastolic = HKQuantityType(.bloodPressureDiastolic)
        let unit = HKUnit.millimeterOfMercury()
        if ask.stat == .latest {
            let top = await samples(systolic, ask, limit: 1, newestFirst: true).first as? HKQuantitySample
            let bottom = await samples(diastolic, ask, limit: 1, newestFirst: true).first as? HKQuantitySample
            let value = top.flatMap { top in bottom.map { "\(Int(top.quantity.doubleValue(for: unit).rounded()))/\(Int($0.quantity.doubleValue(for: unit).rounded()))" } }
            return HealthAnswer.latest(.bloodPressure, value: value, at: top?.endDate, us: false)
        }
        let options: HKStatisticsOptions = ask.stat == .min ? .discreteMin : ask.stat == .max ? .discreteMax : .discreteAverage
        func number(_ statistics: HKStatistics?) -> Double? {
            let quantity = options == .discreteMin ? statistics?.minimumQuantity() : options == .discreteMax ? statistics?.maximumQuantity() : statistics?.averageQuantity()
            return quantity?.doubleValue(for: unit)
        }
        async let tops = collection(systolic, ask, options: options, calendar: calendar)
        async let bottoms = collection(diastolic, ask, options: options, calendar: calendar)
        let (high, low) = try await (tops, bottoms)
        let lows = Dictionary(low.compactMap { start, s in number(s).map { (start, $0) } }, uniquingKeysWith: { a, _ in a })
        let values: [(Date, Double, Double)] = high.compactMap { start, s in
            guard let top = number(s), let bottom = lows[start] else { return nil }
            return (start, top, bottom)
        }
        async let topAll = single(systolic, ask, options: options)
        async let bottomAll = single(diastolic, ask, options: options)
        let (t, b) = await (topAll, bottomAll)
        let overall = number(t).flatMap { top in number(b).map { (top, $0) } }
        return HealthAnswer.pressure(ask, values: values, overall: overall, calendar: calendar)
    }

    private static func predicate(_ ask: HealthAsk) -> NSPredicate {
        HKQuery.predicateForSamples(withStart: ask.start, end: ask.end, options: [])
    }

    /// The samples in the range; HealthKit answers on a queue of its own.
    private static func samples(_ type: HKSampleType, _ ask: HealthAsk, limit: Int = HKObjectQueryNoLimit, newestFirst: Bool = false) async -> [HKSample] {
        await withCheckedContinuation { done in
            let sort = newestFirst ? [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)] : nil
            let query = HKSampleQuery(sampleType: type, predicate: predicate(ask), limit: limit, sortDescriptors: sort) { _, found, _ in
                done.resume(returning: found ?? [])
            }
            store.execute(query)
        }
    }

    /// One statistic over the whole range.
    private static func single(_ type: HKQuantityType, _ ask: HealthAsk, options: HKStatisticsOptions) async -> HKStatistics? {
        await withCheckedContinuation { done in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate(ask), options: options) { _, statistics, _ in
                done.resume(returning: statistics)
            }
            store.execute(query)
        }
    }

    /// A statistic for each bucket in the range, each bucket's start with it.
    private static func collection(_ type: HKQuantityType, _ ask: HealthAsk, options: HKStatisticsOptions, calendar: Calendar) async throws -> [(Date, HKStatistics)] {
        let anchor = HealthAsk.first(of: ask.bucket, at: ask.start, calendar: calendar)
        return try await withCheckedThrowingContinuation { done in
            let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate(ask), options: options,
                                                    anchorDate: anchor, intervalComponents: ask.step)
            query.initialResultsHandler = { _, collection, error in
                if let error, (error as? HKError)?.code != .errorNoData {
                    done.resume(throwing: DeviceToolError("Health couldn't be read: \(error.localizedDescription)"))
                    return
                }
                var found: [(Date, HKStatistics)] = []
                collection?.enumerateStatistics(from: ask.start, to: ask.end) { statistics, _ in found.append((statistics.startDate, statistics)) }
                done.resume(returning: found)
            }
            store.execute(query)
        }
    }
    #endif
}
