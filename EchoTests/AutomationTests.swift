import Foundation
import Testing
@testable import Echo

struct AutomationTests {
    @Test func decodesRawStoreJob() throws {
        let j = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"id":"abc123def456","name":"Morning brief","prompt":"Summarize my day","enabled":true,"state":"scheduled",
         "schedule":{"kind":"cron","expr":"0 9 * * *","display":"0 9 * * *"},"schedule_display":"every day at 9am",
         "next_run_at":"2026-09-11T09:00:00","last_run_at":null,"last_status":null}
        """.utf8))
        let job = try #require(CronJob(j))
        #expect(job.id == "abc123def456" && job.schedule == "every day at 9am" && job.state == .scheduled)
        #expect(job.nextRunAt != nil)
    }

    @Test func decodesFlattenedJobAndPausedState() throws {
        let j = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"job_id":"0123456789ab","name":"Ping","prompt_preview":"check the server...","schedule":"every 30m","enabled":false,"state":"scheduled"}
        """.utf8))
        let job = try #require(CronJob(j))
        #expect(job.id == "0123456789ab" && job.schedule == "every 30m")
        #expect(job.state == .paused, "enabled=false must render as paused even if state says scheduled")
    }

    @Test func decodesKanbanTask() throws {
        let j = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"id":"t_ab12","title":"Fix login","body":"Steps…","status":"ready","priority":2,"assignee":"coder",
         "created_at":1770000000,"comment_count":1,"latest_summary":"Investigating"}
        """.utf8))
        let t = try #require(KanbanTask(j))
        #expect(t.status == "ready" && t.priority == 2 && t.commentCount == 1 && t.createdAt != nil)
    }

    @Test func decodesBlueprintAndTargets() throws {
        let bp = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"key":"morning-brief","title":"Morning brief","description":"Calendar + mail","category":"daily","scheduleHuman":"every day at 8:00",
         "fields":[{"name":"time","type":"time","label":"What time?","default":"8:00","options":[],"optional":false},
                   {"name":"deliver","type":"enum","label":"Where?","default":"origin","options":["origin","local","telegram"],"optional":false},
                   {"name":"interval_min","type":"enum","label":"How often?","default":30,"options":[15,30,60],"optional":true}]}
        """.utf8))
        let b = try #require(CronBlueprint(bp))
        #expect(b.key == "morning-brief" && b.fields.count == 3)
        #expect(b.fields[1].options == ["origin", "local", "telegram"])
        #expect(b.fields[2].defaultValue == "30" && b.fields[2].options == ["15", "30", "60"] && b.fields[2].optional)

        let t = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"id":"telegram","name":"Telegram","home_env_var":"TELEGRAM_HOME_CHANNEL","home_target_set":false}
        """.utf8))
        let target = try #require(CronDeliveryTarget(t))
        #expect(target.id == "telegram" && !target.homeTargetSet)
    }

    @Test func contextPercentNeverUsesSessionTotals() {
        // Hermes backends report cumulative prompt tokens; without a stated context there is no percentage.
        var m = TurnMetrics(sentAt: .now, completedAt: .now, usage: TokenUsage(input: 250_000, output: 900, cached: nil), contextWindow: 131_072)
        #expect(m.contextPercent == nil)
        #expect(m.summary.contains("session 251k tok"))
        // hermes serve states occupancy and window.
        m.usage = TokenUsage(input: 250_000, output: 900, cached: nil, contextUsed: 19_660, contextMax: 131_072)
        #expect(abs((m.contextPercent ?? 0) - 15.0) < 0.1)
        // Fast lane: one call's prompt + output against the detected window.
        m.usage = TokenUsage(input: 4_000, output: 96, cached: nil, contextUsed: 4_096)
        #expect(abs((m.contextPercent ?? 0) - 3.125) < 0.01)
    }
}
