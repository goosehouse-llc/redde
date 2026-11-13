import SwiftUI
import Testing
import UIKit
@testable import Echo

/// Planned's page (2026-11-13): the header's counters, which one is next, the timeline's big
/// times, and its hue's words on the cards.
@MainActor
struct PlannedPageTests {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
    /// 10:00 on a Friday (UTC).
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 10))! }

    private func item(_ id: String, in minutes: Double, kind: ComingUp.Kind = .routine, job: String? = nil, profile: String? = "default",
                      paused: Bool = false, untimed: Bool = false, skipped: Bool = false, skipping: Bool = false) -> ComingUp.Item {
        let cron = job.flatMap { CronJob(.object(["id": .string($0), "name": .string(id), "schedule": .string("0 * * * *"),
                                                   "enabled": .bool(!paused)].merging(profile.map { ["profile": .string($0)] } ?? [:]) { a, _ in a })) }
        return ComingUp.Item(id: id, kind: kind, title: id, profile: profile, at: now.addingTimeInterval(minutes * 60), job: cron,
                             untimed: untimed, paused: paused, skipping: skipping, skipped: skipped)
    }

    @Test func countsByDayAndJobs() {
        let items = [
            item("overdue", in: -90, kind: .reminder, profile: nil),       // still today
            item("soon", in: 30, job: "a"),
            item("tonight", in: 60 * 11, job: "b"),
            item("tomorrow", in: 60 * 20, job: "a"),                   // the same job's next run: one job
            item("weekend", in: 60 * 48, kind: .event, profile: nil),
            item("paused", in: 0, job: "c", paused: true),
        ]
        let counts = ComingUp.counts(items, now: now, calendar: calendar)
        #expect(counts == ComingUp.Counts(today: 3, tomorrow: 1, ahead: 5, jobs: 3, paused: 1))
        #expect(ComingUp.counts([], now: now, calendar: calendar) == ComingUp.Counts())
    }

    @Test func theSameJobOnTwoProfilesIsTwoJobs() {
        let items = [item("x", in: 5, job: "a", profile: "default"), item("y", in: 6, job: "a", profile: "ops")]
        #expect(ComingUp.counts(items, now: now, calendar: calendar).jobs == 2)
    }

    /// The next is the soonest still to come at its own time, not skipped, paused or overdue.
    @Test func nextUpPassesOverWhatWontHappen() {
        let items = [
            item("overdue", in: -5, kind: .reminder, profile: nil),
            item("no time", in: 0, kind: .reminder, profile: nil, untimed: true),
            item("skipped", in: 3, kind: .leaveBy, profile: nil, skipped: true),
            item("skipping", in: 4, job: "s", skipping: true),
            item("paused", in: 1, job: "p", paused: true),
            item("this one", in: 12, job: "n"),
            item("later", in: 40, job: "l"),
        ]
        #expect(ComingUp.nextUp(items, now: now)?.id == "this one")
        #expect(ComingUp.nextUp(Array(items.prefix(5)), now: now) == nil)
    }

    @Test func bigTimesSplitTheirHalfOfTheDay() {
        let afternoon = now.addingTimeInterval(4 * 3600 + 15 * 60)   // 14:15
        let us = ComingUp.clock(afternoon, locale: Locale(identifier: "en_US"), calendar: calendar, timeZone: calendar.timeZone)
        #expect(us.time == "2:15")
        #expect(us.period == "PM")
        let morning = ComingUp.clock(now.addingTimeInterval(-3 * 3600), locale: Locale(identifier: "en_US"), calendar: calendar, timeZone: calendar.timeZone)
        #expect(morning.time == "7:00" && morning.period == "AM")
        let de = ComingUp.clock(afternoon, locale: Locale(identifier: "de_DE"), calendar: calendar, timeZone: calendar.timeZone)
        #expect(de.time == "14:15")
        #expect(de.period == nil)
    }

    // MARK: Colours

    private func rgb(_ color: Color, _ scheme: ColorScheme) -> (Double, Double, Double) {
        var env = EnvironmentValues()
        env.colorScheme = scheme
        let ui = UIColor(cgColor: color.resolve(in: env).cgColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private func contrast(_ x: Color, _ y: Color, _ scheme: ColorScheme) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func lum(_ c: (Double, Double, Double)) -> Double { 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2) }
        let (a, b) = (lum(rgb(x, scheme)), lum(rgb(y, scheme)))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The big times and counters are drawn in the hue stepped toward the ink, on the cards'
    /// surface and on the page, in every theme by day and after dark.
    @Test(arguments: Theme.allCases)
    func theHuesWordsRead(_ theme: Theme) {
        let tone = DrawerTone(theme.resolved(with: nil))
        let words = tone.plannedInk
        for scheme in [ColorScheme.light, .dark] {
            let name = "\(theme.rawValue) \(scheme == .dark ? "dark" : "light")"
            #expect(contrast(words, tone.surface, scheme) >= 3, "\(name): the times on a card")
            #expect(contrast(words, tone.page, scheme) >= 3, "\(name): the counters on the page")
        }
    }
}
