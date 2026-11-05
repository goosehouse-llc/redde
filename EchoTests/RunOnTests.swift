import Foundation
import Testing
@testable import Echo

/// Run On (2026-11-03): a scheduled job's own model. The mark the Hermes API carries in a job's
/// name, what a job runs on, the small model the quick jobs are offered, and which jobs that moves.
@MainActor
struct RunOnTests {
    private func job(_ name: String, model: String? = nil, provider: String? = nil) -> CronJob {
        var fields: [String: JSONValue] = ["id": .string("j1"), "name": .string(name), "schedule": .string("0 21 * * *")]
        if let model { fields["model"] = .string(model) }
        if let provider { fields["provider"] = .string(provider) }
        return CronJob(.object(fields))!
    }

    private func choice(_ model: String, _ provider: String = "custom:local") -> ModelChoice {
        ModelChoice(provider: provider, providerName: "Local", model: model, name: model, isCurrent: false)
    }

    @Test func theMarkIsMadeAndTakenOffAgain() throws {
        let pick = RunOn.Pick(model: "qwen3-4b", provider: "custom:local")
        let marked = try #require(RunOn.marked("[redde-notify] Evening wrap-up", pick))
        #expect(marked == "[redde-notify] Evening wrap-up [redde-model:qwen3-4b|custom:local]")
        #expect(RunOn.unmarked(marked).name == "[redde-notify] Evening wrap-up")
        #expect(RunOn.unmarked(marked).asked == pick)
        #expect(RunOn.marked(marked, .main) == "[redde-notify] Evening wrap-up [redde-model:|]", "one mark, the latest")
        #expect(RunOn.unmarked("[redde-notify] Evening wrap-up [redde-model:|]").asked == .main)
        #expect(RunOn.marked("x", RunOn.Pick(model: "bad]name", provider: "p")) == nil, "a ] would end the mark early")
    }

    @Test func aJobsNameLosesBothMarksWhicheverComesFirst() {
        let skipFirst = job("[redde-notify] Week ahead [redde-skip:1793000000] [redde-model:qwen3-4b|custom:local]")
        let modelFirst = job("[redde-notify] Week ahead [redde-model:qwen3-4b|custom:local] [redde-skip:1793000000]")
        for job in [skipFirst, modelFirst] {
            #expect(job.name == "[redde-notify] Week ahead")
            #expect(job.skipping == Date(timeIntervalSince1970: 1_793_000_000))
            #expect(job.askedModel == RunOn.Pick(model: "qwen3-4b", provider: "custom:local"))
        }
    }

    @Test func whatAJobRunsOn() {
        #expect(RunOn.current(job("Wrap-up")) == .main)
        #expect(RunOn.current(job("Wrap-up", model: "qwen3-4b", provider: "custom:local")) == RunOn.Pick(model: "qwen3-4b", provider: "custom:local"))
        #expect(RunOn.current(job("Wrap-up [redde-model:|]", model: "qwen3-4b")) == .main, "a mark still waiting is the latest choice")
    }

    @Test func theSmallModelOffered() {
        let models = [choice("qwen36-splash"), choice("qwen36-35b-a3b"), choice("qwen3-4b"), choice("llama-3.2-3b")]
        #expect(RunOn.smallModel(in: models, remembered: nil)?.model == "llama-3.2-3b", "the smallest under 10B")
        #expect(RunOn.smallModel(in: [choice("qwen36-35b-a3b"), choice("gemma-27b")], remembered: nil) == nil, "an a3b isn't small")
        #expect(RunOn.smallModel(in: [choice("gpt-mini-x"), choice("qwen36-splash")], remembered: nil)?.model == "gpt-mini-x")
        #expect(RunOn.smallModel(in: models, remembered: RunOn.Pick(model: "qwen3-4b", provider: "custom:local"))?.model == "qwen3-4b",
                "the one the person picked before")
        #expect(RunOn.billions("qwen3.6-35b-a3b") == 35)
        #expect(RunOn.billions("qwen3-4b") == 4)
        #expect(RunOn.billions("qwen36-splash") == nil)
    }

    @Test func theQuickJobsAreTheThreeDailyOnesOnTheMainModel() {
        #expect(RunOn.quickJobs == [HeadsUps.name, EveningWrapUp.name, WeekAhead.name])
        let jobs = [job(HeadsUps.name), job(EveningWrapUp.name, model: "qwen36-splash", provider: "custom:local"),
                    job(WeekAhead.name), job(MorningIdeas.name), job("[redde-watch:w1] Price")]
        #expect(RunOn.quickTargets(in: jobs).map(\.name) == [HeadsUps.name, WeekAhead.name])
    }

    @Test func aMarkNothingTakesUpIsToldAfterTwoMinutes() {
        let waiting = job("Wrap-up [redde-model:qwen3-4b|custom:local]")
        let now = Date.now
        RunOnMarks.forget(waiting)
        #expect(!RunOnMarks.unheard(waiting, now: now), "set from another device: not known when")
        RunOnMarks.noted(waiting, at: now.addingTimeInterval(-30))
        #expect(!RunOnMarks.unheard(waiting, now: now))
        RunOnMarks.noted(waiting, at: now.addingTimeInterval(-RunOn.markUnheardAfter - 1))
        #expect(RunOnMarks.unheard(waiting, now: now))
        RunOnMarks.forget(waiting)
    }
}
