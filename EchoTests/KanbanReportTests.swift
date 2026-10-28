import Foundation
import Testing
@testable import Echo

/// A card's report (asked 2026-10-28, after OpenDuet's task reports): what it waits on the person
/// for, its attempts, the pages it relied on, and its timeline, from Hermes's `/tasks/<id>`.
struct KanbanReportTests {
    private func detail(status: String, result: String? = nil) throws -> KanbanDetail {
        let task = try #require(KanbanTask(.object(["id": .string("t_abc123"), "title": .string("Compare routers"),
                                                    "status": .string(status), "priority": .number(1),
                                                    "result": result.map { .string($0) } ?? .null])))
        let runs = [JSONValue.object(["id": .number(7), "profile": .string("research"), "outcome": .string("completed"),
                                      "summary": .string("Picked the Deco. See https://example.com/review and https://example.org/specs."),
                                      "started_at": .number(1_000), "ended_at": .number(1_090)])].compactMap(KanbanRun.init)
        let events = [JSONValue.object(["id": .number(1), "kind": .string("created"), "created_at": .number(900)]),
                      .object(["id": .number(2), "kind": .string("blocked"), "created_at": .number(1_100),
                               "payload": .object(["reason": .string("Needs the budget")])])].compactMap(KanbanEvent.init)
        let comments = [JSONValue.object(["id": .number(3), "author": .string("alex"), "body": .string("Also https://example.com/review")])].compactMap(KanbanComment.init)
        return KanbanDetail(task: task, comments: comments, attachments: [], events: events, runs: runs)
    }

    @Test func itsSourcesAreTheLinksItReliedOnEachOnce() throws {
        let d = try detail(status: "done", result: "Done: https://example.net/answer.")
        #expect(d.sources.map(\.absoluteString) == ["https://example.net/answer", "https://example.com/review", "https://example.org/specs"])
    }

    @Test func whatItWaitsOnThePersonFor() throws {
        #expect(try detail(status: "blocked").waitingReason == "Needs the budget")
        #expect(try detail(status: "review").waitingReason?.hasPrefix("Picked the Deco") == true)
        #expect(try detail(status: "running").waitingReason == nil)
    }

    @Test func runsAndEventsAreReadAsHermesSendsThem() throws {
        let d = try detail(status: "done")
        #expect(d.runs.first?.profile == "research" && d.runs.first?.endedAt?.timeIntervalSince(d.runs.first!.startedAt!) == 90)
        #expect(d.events.map(\.kind) == ["created", "blocked"] && d.events.last?.detail == "Needs the budget")
        #expect(d.events.last?.label == KanbanStatus.label("blocked"))
    }
}
