import Foundation
import Testing
@testable import Echo

/// Ahead of Your Day (asked 2026-10-30): which steps Turn On runs for what is picked and what the
/// connection can do, what it skips and why, the What's New offer made once, and a run in order
/// on a made-up server, one step failing and the rest done.
struct AheadOfYourDayTests {
    typealias Part = AheadOfYourDay.Part
    private let old = PushPlugin.State(installed: true, version: "1.9.0", enabled: true)
    private let current = PushPlugin.State(installed: true, version: PushPlugin.version, enabled: true)

    private func situation(jobs: Bool = true, dashboard: Bool = true, pairsDirectly: Bool = true, paired: Bool = false,
                           plugin: PushPlugin.State? = nil, restartPending: Bool = false, on: Set<Part> = []) -> AheadOfYourDay.Situation {
        AheadOfYourDay.Situation(jobs: jobs, dashboard: dashboard, pairsDirectly: pairsDirectly, paired: paired,
                                 plugin: plugin, restartPending: restartPending, on: on)
    }

    private func defaults() -> UserDefaults {
        let name = "AheadOfYourDayTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func theCoreSetIsTickedAndRoutinesAreNot() {
        #expect(Set(AheadOfYourDay.core) == [.morningIdeas, .headsUps, .leaveBy, .wrapUp, .weekAhead])
        #expect(AheadOfYourDay.picked(in: defaults()) == Set(AheadOfYourDay.core))
        #expect(Part.allCases.filter { $0.job == nil } == [.leaveBy], "every other part is a Hermes job")
        // The jobs are the pages' own, found again by their names.
        #expect(Part.morningIdeas.job?.name == MorningIdeas.name && Part.weekAhead.job?.name == WeekAhead.name)
    }

    @Test func aPluginFromBeforeTheBumpIsOffered() {
        // 1.9.0 servers were never offered what came after it on main: 1.10.0 tells them apart.
        #expect(old.isOutdated && !current.isOutdated)
    }

    @Test func overTheDashboardEverythingRuns() {
        let plan = AheadOfYourDay.plan(picked: Set(AheadOfYourDay.core), situation: situation(plugin: old))
        #expect(plan.plugin == .run)
        for part in AheadOfYourDay.core { #expect(plan.parts[part] == .run) }
        #expect(plan.parts[.routines] == .skip(.notPicked))
        #expect(plan.pairing == .direct)
        // Missing or switched off: installed or switched on all the same.
        #expect(AheadOfYourDay.plan(picked: [.morningIdeas], situation: situation(plugin: PushPlugin.State())).plugin == .run)
        #expect(AheadOfYourDay.plan(picked: [.morningIdeas], situation: situation(plugin: PushPlugin.State(installed: true, version: PushPlugin.version, enabled: false))).plugin == .run)
    }

    @Test func overTheHermesAPIThePluginIsTheTerminalsAndPairingTakesACode() {
        let plan = AheadOfYourDay.plan(picked: Set(AheadOfYourDay.core), situation: situation(dashboard: false, pairsDirectly: false))
        #expect(plan.plugin == .skip(.needsDashboard))
        #expect(plan.parts[.morningIdeas] == .run, "the API's jobs routes make the jobs")
        #expect(plan.pairing == .byCode)
        // Signed in to the Dashboard but chatting over the API: the plugin is there to see, pairing still takes a code.
        #expect(AheadOfYourDay.plan(picked: [.wrapUp], situation: situation(pairsDirectly: false, plugin: current)).pairing == .byCode)
    }

    @Test func withoutAConnectionOnlyLeaveByRuns() {
        let plan = AheadOfYourDay.plan(picked: Set(AheadOfYourDay.core), situation: situation(jobs: false, dashboard: false, pairsDirectly: false))
        #expect(plan.parts[.leaveBy] == .run)
        for part in [Part.morningIdeas, .headsUps, .wrapUp, .weekAhead] { #expect(plan.parts[part] == .skip(.needsConnection)) }
    }

    @Test func leaveByAloneAsksNothingOfTheServer() {
        let plan = AheadOfYourDay.plan(picked: [.leaveBy], situation: situation(jobs: false, dashboard: false))
        #expect(plan.plugin == .skip(.notNeeded))
        #expect(plan.pairing == .skip(.notNeeded))
        #expect(plan.parts[.leaveBy] == .run)
    }

    @Test func whatIsOnAlreadyIsLeftAlone() {
        let all = Set(Part.allCases)
        let plan = AheadOfYourDay.plan(picked: all, situation: situation(paired: true, plugin: current, on: all))
        #expect(plan.parts.values.allSatisfy { $0 == .skip(.alreadyOn) })
        #expect(plan.plugin == .skip(.upToDate))
        #expect(plan.pairing == .skip(.alreadyPaired))
    }

    @Test func pairingWaitsForThePlugin() {
        // Installed on a Hermes that loads it only after a restart: pairing then.
        #expect(AheadOfYourDay.plan(picked: [.morningIdeas], situation: situation(plugin: current, restartPending: true)).pairing == .skip(.waitsForRestart))
        // The Dashboard couldn't say: the terminal's command, and the code.
        let unread = AheadOfYourDay.plan(picked: [.morningIdeas], situation: situation(plugin: nil))
        #expect(unread.plugin == .skip(.unreadable))
        #expect(unread.pairing == .byCode)
    }

    @Test func onMeansWhatWasPickedIsOn() {
        #expect(AheadOfYourDay.isOn(picked: [.morningIdeas, .leaveBy], on: [.morningIdeas, .leaveBy, .routines]))
        #expect(!AheadOfYourDay.isOn(picked: Set(AheadOfYourDay.core), on: [.morningIdeas, .leaveBy]))
        #expect(!AheadOfYourDay.isOn(picked: [], on: Set(Part.allCases)), "nothing picked isn't on")
    }

    @Test func whatsNewOffersItOnce() throws {
        let release = try #require(WhatsNew.releases.first { $0.version == "2.3" })
        #expect(AheadOfYourDay.offersSetup(in: release, answered: false))
        #expect(!AheadOfYourDay.offersSetup(in: release, answered: true), "never twice")
        // 2.3.1 shows 2.3's entry, with its button; an older entry has none.
        #expect(WhatsNew.highlights(of: "2.3.1").map { AheadOfYourDay.offersSetup(in: $0, answered: false) } == true)
        let older = try #require(WhatsNew.releases.first { $0.version == "2.2" })
        #expect(!AheadOfYourDay.offersSetup(in: older, answered: false))
        // Answered is kept.
        let store = defaults()
        #expect(!AheadOfYourDay.answered(in: store))
        AheadOfYourDay.markAnswered(in: store)
        #expect(AheadOfYourDay.answered(in: store))
    }

    @Test func thePicksAreKept() {
        let store = defaults()
        AheadOfYourDay.setPicked([.leaveBy, .routines], in: store)
        #expect(AheadOfYourDay.picked(in: store) == [.leaveBy, .routines])
        AheadOfYourDay.setPicked([], in: store)
        #expect(AheadOfYourDay.picked(in: store).isEmpty, "none picked stays none, not the core set again")
    }

    /// Turn On on a made-up server: the plugin updated first, then the jobs in the sheet's order,
    /// then Leave-By Alerts; the wrap-up refused, and everything else done all the same.
    @Test func turnOnGoesInOrderAndAFailureLeavesTheRestDone() async {
        let host = FakeHost()
        host.failing = EveningWrapUp.name
        let store = defaults()
        let setup = AheadOfYourDaySetup(host: host, defaults: store)
        await setup.load()
        #expect(setup.phase == .ready && setup.plan.plugin == .run)
        await setup.turnOn()
        #expect(setup.phase == .finished)
        #expect(host.made == [MorningIdeas.name, HeadsUps.name, EveningWrapUp.name, WeekAhead.name], "in order, routines not picked")
        #expect(host.leaveByWay == setup.way)
        guard case .done = setup.status[.plugin] else { Issue.record("the plugin wasn't updated: \(String(describing: setup.status[.plugin]))"); return }
        guard case .failed = setup.status[.part(.wrapUp)] else { Issue.record("the wrap-up's failure wasn't said"); return }
        for part in [Part.morningIdeas, .headsUps, .weekAhead, .leaveBy] {
            guard case .done = setup.status[.part(part)] else { Issue.record("\(part) wasn't done"); continue }
        }
        #expect(setup.status[.part(.routines)] == nil)
        // The plugin now runs: pairing is offered with a tap at the bottom.
        #expect(setup.plan.pairing == .direct && setup.offersPairing)
        #expect(AheadOfYourDay.answered(in: store) && AheadOfYourDay.picked(in: store) == Set(AheadOfYourDay.core))
    }

    /// Leave-By's permissions not given: it says so, with the way to Settings, and the rest goes on.
    @Test func aMissingPermissionIsSaid() async {
        let host = FakeHost()
        host.missing = [.location]
        let setup = AheadOfYourDaySetup(host: host, defaults: defaults())
        setup.picked = [.leaveBy]
        await setup.load()
        await setup.turnOn()
        guard case let .needsSettings(text) = setup.status[.part(.leaveBy)] else { Issue.record("no way to Settings"); return }
        #expect(text.contains(AheadOfYourDaySetup.names([.location])))
        #expect(host.made.isEmpty)
    }

    @Test func jobsOnAlreadyAreNotMadeAgain() async throws {
        let host = FakeHost()
        host.existing = [try #require(CronJob(.object(["id": .string("j1"), "name": .string(MorningIdeas.name), "schedule": .string("0 8 * * *")])))]
        let setup = AheadOfYourDaySetup(host: host, defaults: defaults())
        await setup.load()
        #expect(setup.situation.on.contains(.morningIdeas))
        await setup.turnOn()
        #expect(!host.made.contains(MorningIdeas.name))
        #expect(setup.status[.part(.morningIdeas)] == .skipped(AheadOfYourDay.when(MorningIdeas.job, hour: 8, minute: 0)))
    }

    @Test func allOnOffersTurnOffWhichTakesTheJobsOffAndLeaveByOff() async throws {
        let host = FakeHost()
        host.existing = [try #require(CronJob(.object(["id": .string("j1"), "name": .string(MorningIdeas.name), "schedule": .string("0 8 * * *")])))]
        host.leaveByWay = .driving
        let setup = AheadOfYourDaySetup(host: host, defaults: defaults())
        setup.picked = [.morningIdeas, .leaveBy]
        await setup.load()
        #expect(setup.everythingOn)
        await setup.turnOff()
        #expect(host.removed == [MorningIdeas.name])
        #expect(!host.leaveByOn)
        #expect(setup.status[.part(.morningIdeas)] == .done(String(localized: "Turned off.")))
        #expect(!setup.everythingOn)
        #expect(setup.phase == .ready)
    }
}

/// A server whose plugin is 1.9.0 (`DemoPushPlugin`), with the jobs it is told of, over the
/// Dashboard; this device unpaired.
private final class FakeHost: AheadOfYourDayHost {
    let plugin: any PushPluginManaging = DemoPushPlugin("old")
    var existing: [CronJob] = []
    var made: [String] = []
    var failing: String?
    var missing: Set<LeaveByAlerts.Missing> = []
    var leaveByWay: LeaveTime.Mode?

    func situation() -> AheadOfYourDay.Situation {
        AheadOfYourDay.Situation(jobs: true, dashboard: true, pairsDirectly: true, paired: false)
    }

    func jobs() async throws -> [CronJob] { existing }

    func setJob(_ daily: DailyJob, hour: Int, minute: Int, replacing job: CronJob?) async throws {
        made.append(daily.name)
        if daily.name == failing { throw TransportError.http(status: 500, body: "cron is down") }
    }

    func turnOnLeaveBy(_ way: LeaveTime.Mode) async -> Set<LeaveByAlerts.Missing> {
        leaveByWay = way
        return missing
    }

    var leaveByOn: Bool { leaveByWay != nil }

    func paired() -> Bool { false }

    var removed: [String] = []

    func removeJob(_ job: CronJob) async throws {
        removed.append(job.name)
        existing.removeAll { $0.id == job.id }
    }

    func turnOffLeaveBy() async { leaveByWay = nil }
}
