import Foundation
#if os(iOS) && canImport(HealthKit)
import HealthKit
import UIKit
#endif

/// Health-aware days (asked 2026-10-28, "Proactive"; off unless the person turns it on): how they
/// slept, how much they've moved and their workouts, read from Apple Health on the iPhone and put,
/// as a few words, into the prompts of Morning Ideas, the Evening Wrap-up and the Week Ahead, so a
/// short night makes for a lighter set of ideas and a still day for a nudge. Only that summary
/// leaves the phone, to the person's own Hermes, and only into those jobs: nothing in a chat's
/// prompt, nothing on either connection a chat would wait on. Health wakes Redde when new sleep or
/// a workout is saved, and the summary is said again then (`FeedbackFold`).
nonisolated struct HealthSummary: Codable, Equatable, Sendable {
    /// Last night's sleep: how long, from when to when.
    var slept: TimeInterval?
    var fellAsleep: Date?
    var woke: Date?
    var stepsToday: Int?
    var stepsYesterday: Int?
    /// "32-minute run yesterday", newest first.
    var workouts: [String] = []
    var at: Date

    /// How long a summary is worth saying: a day's.
    static let freshFor: TimeInterval = 20 * 3600
    private static let key = "healthSummary", onKey = "healthDays"

    static func isOn(in defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: onKey) }
    static func setOn(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: onKey)
        if !on { defaults.removeObject(forKey: key) }
    }

    static func load(in defaults: UserDefaults = .standard) -> HealthSummary? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(HealthSummary.self, from: $0) }
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    /// What a job's prompt says, when it's on and the summary is fresh. Words to the model: English.
    static func note(in defaults: UserDefaults = .standard, now: Date = .now) -> String? {
        guard isOn(in: defaults), let summary = load(in: defaults), now.timeIntervalSince(summary.at) < freshFor else { return nil }
        return summary.line
    }

    var line: String? {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "h:mm a"
        let steps = NumberFormatter()
        steps.numberStyle = .decimal
        steps.locale = Locale(identifier: "en_US")
        var parts: [String] = []
        if let slept, slept >= 30 * 60 {
            let minutes = Int(slept / 60)
            var said = "slept \(minutes / 60) h \(minutes % 60) min last night"
            if let fellAsleep, let woke { said += " (\(clock.string(from: fellAsleep))–\(clock.string(from: woke)))" }
            parts.append(said)
        }
        let count: (Int) -> String = { steps.string(from: NSNumber(value: $0)) ?? "\($0)" }
        switch (stepsToday, stepsYesterday) {
        case let (today?, yesterday?): parts.append("\(count(today)) steps so far today, \(count(yesterday)) yesterday")
        case let (today?, nil): parts.append("\(count(today)) steps so far today")
        case let (nil, yesterday?): parts.append("\(count(yesterday)) steps yesterday")
        default: break
        }
        if !workouts.isEmpty { parts.append("workouts: " + workouts.prefix(3).joined(separator: ", ")) }
        guard !parts.isEmpty else { return nil }
        return "From the user's iPhone (Apple Health, shared at their choice, as of \(clock.string(from: at))): "
            + parts.joined(separator: "; ")
            + ". Let it shape what you suggest and how (a lighter day after a short night, a nudge to move after a still one), without lecturing or dwelling on it."
    }

    /// Worth saying again: sleep or workouts changed, or steps by a thousand.
    func differs(from other: HealthSummary?) -> Bool {
        guard let other else { return true }
        if slept.map({ Int($0 / 600) }) != other.slept.map({ Int($0 / 600) }) || workouts != other.workouts { return true }
        let thousands: (Int?) -> Int? = { $0.map { $0 / 1000 } }
        return thousands(stepsToday) != thousands(other.stepsToday) || thousands(stepsYesterday) != thousands(other.stepsYesterday)
    }
}

#if os(iOS) && canImport(HealthKit)
@MainActor
enum HealthDays {
    private nonisolated static let store = HKHealthStore()
    private static var observing: [HKObserverQuery] = []
    private nonisolated static let sleep = HKCategoryType(.sleepAnalysis)
    private nonisolated static let steps = HKQuantityType(.stepCount)
    private nonisolated static let workouts = HKObjectType.workoutType()
    private static var reading: [HKObjectType] { [sleep, steps, workouts] }

    static var available: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Turned on: asked for reading sleep, steps and workouts (nothing written), then watched.
    static func turnOn() async throws {
        guard available else { return }
        try await store.requestAuthorization(toShare: [], read: Set(reading))
        HealthSummary.setOn(true)
        startIfOn()
        await refresh(force: true)
    }

    /// Turned off: no more waking, the summary gone, and the jobs' prompts said again without it.
    static func turnOff() async {
        HealthSummary.setOn(false)
        observing.forEach(store.stop)
        observing = []
        try? await store.disableAllBackgroundDelivery()
        await FeedbackFold.fold()
    }

    /// At launch (Health may have woken Redde for this) and once turned on.
    static func startIfOn() {
        guard HealthSummary.isOn(), available, observing.isEmpty else { return }
        for type in [sleep, workouts] as [HKSampleType] {
            let query = observer(of: type)
            store.execute(query)
            observing.append(query)
            store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        }
    }

    /// HealthKit calls back on a queue of its own: the closure must not be the main actor's.
    private nonisolated static func observer(of type: HKSampleType) -> HKObserverQuery {
        HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
            guard error == nil else { completion(); return }
            // Called once, on whichever thread: HealthKit's "handled".
            nonisolated(unsafe) let handled = completion
            Task { @MainActor in
                let time = BackgroundTime()
                time.id = UIApplication.shared.beginBackgroundTask(withName: "health") { time.end() }
                await refresh()
                time.end()
                handled()
            }
        }
    }

    /// Read again; said to the jobs when it changed enough to matter (or `force`).
    static func refresh(force: Bool = false) async {
        guard HealthSummary.isOn(), available else { return }
        let now = Date.now
        let summary = await read(now: now)
        let before = HealthSummary.load()
        summary.save()
        if force || summary.differs(from: before) { await FeedbackFold.fold() }
    }

    /// HealthKit answers on a queue of its own: these reads are nobody's actor's.
    nonisolated static func read(now: Date = .now) async -> HealthSummary {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        async let night = lastNight(now: now)
        async let todaySteps = stepCount(from: today, to: now)
        async let yesterdaySteps = stepCount(from: yesterday, to: today)
        async let done = recentWorkouts(since: yesterday, today: today)
        let (sleep, stepsToday, stepsYesterday, workouts) = await (night, todaySteps, yesterdaySteps, done)
        return HealthSummary(slept: sleep?.slept, fellAsleep: sleep?.from, woke: sleep?.to, stepsToday: stepsToday,
                             stepsYesterday: stepsYesterday, workouts: workouts, at: now)
    }

    /// Asleep since 6 PM yesterday, overlapping samples (a watch's and a phone's) counted once.
    private nonisolated static func lastNight(now: Date) async -> (slept: TimeInterval, from: Date, to: Date)? {
        let start = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: now.addingTimeInterval(-86_400)) ?? now.addingTimeInterval(-86_400)
        let asleep = HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue)
        let samples: [HKCategorySample] = await withCheckedContinuation { done in
            let query = HKSampleQuery(sampleType: sleep, predicate: HKQuery.predicateForSamples(withStart: start, end: now),
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, found, _ in
                done.resume(returning: (found as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }
        let spans = samples.filter { asleep.contains($0.value) }.map { ($0.startDate, $0.endDate) }.sorted { $0.0 < $1.0 }
        guard let first = spans.first else { return nil }
        var total: TimeInterval = 0
        var (from, to) = first
        var last = first.1
        for span in spans.dropFirst() {
            if span.0 <= to { to = max(to, span.1) } else { total += to.timeIntervalSince(from); (from, to) = span }
            last = max(last, span.1)
        }
        total += to.timeIntervalSince(from)
        return (total, first.0, last)
    }

    private nonisolated static func stepCount(from start: Date, to end: Date) async -> Int? {
        await withCheckedContinuation { done in
            let query = HKStatisticsQuery(quantityType: steps, quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end),
                                          options: .cumulativeSum) { _, statistics, _ in
                done.resume(returning: statistics?.sumQuantity().map { Int($0.doubleValue(for: .count())) })
            }
            store.execute(query)
        }
    }

    private nonisolated static func recentWorkouts(since start: Date, today: Date) async -> [String] {
        let found: [HKWorkout] = await withCheckedContinuation { done in
            let query = HKSampleQuery(sampleType: workouts, predicate: HKQuery.predicateForSamples(withStart: start, end: nil),
                                      limit: 5, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, found, _ in
                done.resume(returning: (found as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
        return found.map { workout in
            let minutes = max(1, Int((workout.duration / 60).rounded()))
            let day = workout.startDate >= today ? "today" : "yesterday"
            return "\(minutes)-minute \(name(of: workout.workoutActivityType)) \(day)"
        }
    }

    /// Words to the model: English.
    nonisolated static func name(of activity: HKWorkoutActivityType) -> String {
        switch activity {
        case .running: "run"
        case .walking: "walk"
        case .cycling: "ride"
        case .swimming: "swim"
        case .hiking: "hike"
        case .yoga: "yoga session"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "strength workout"
        case .highIntensityIntervalTraining: "HIIT workout"
        case .elliptical: "elliptical workout"
        case .rowing: "row"
        case .dance, .cardioDance: "dance workout"
        case .pilates: "Pilates session"
        case .tennis: "tennis game"
        case .golf: "round of golf"
        default: "workout"
        }
    }
}
#endif
