import Foundation
import Testing
@testable import Echo

/// The chat's Session Details (asked 2026-11-02): a session read from either connection's answer,
/// its cost never a false "$0", how far back it was summarised or branched from, and what this
/// device saw of its replies and tools.
@MainActor
struct SessionDetailsTests {
    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    // MARK: - Reading the session

    @Test func theDashboardsRowIsReadAsItComes() throws {
        let row = try json("""
        {"id": "s1", "source": "desktop", "profile": "ops", "model": "qwen36-kapitsa", "billing_provider": "custom:paloma",
         "model_config": "{\\"reasoning_config\\": {\\"effort\\": \\"high\\"}, \\"max_iterations\\": 90}",
         "started_at": 1793600000.5, "last_activity_at": 1793603600, "cwd": "/home/sam/blog", "git_branch": "main",
         "message_count": 12, "tool_call_count": 7, "api_call_count": 9, "input_tokens": 120000, "output_tokens": 3400,
         "cache_read_tokens": 90000, "reasoning_tokens": 800, "estimated_cost_usd": 0.12, "actual_cost_usd": null, "cost_status": "estimated"}
        """)
        let facts = try #require(SessionFacts.parse(row))
        #expect(facts.id == "s1")
        #expect(facts.profile == "ops")
        #expect(facts.provider == "custom:paloma")
        #expect(facts.reasoningEffort == "high", "from the model's settings, kept as a string")
        #expect(facts.startedAt == Date(timeIntervalSince1970: 1793600000.5))
        #expect(facts.lastActive == Date(timeIntervalSince1970: 1793603600))
        #expect(facts.folder == "/home/sam/blog" && facts.branch == "main")
        #expect(facts.messageCount == 12 && facts.toolCallCount == 7 && facts.apiCallCount == 9)
        #expect(facts.inputTokens == 120000 && facts.cacheReadTokens == 90000 && facts.reasoningTokens == 800)
        #expect(SessionCost(facts) == .estimated(0.12))
    }

    @Test func theHermesAPIsSessionIsReadFromInsideItsEnvelope() throws {
        let answer = try json("""
        {"object": "hermes.session", "session": {"id": "api-1", "source": "api_server", "model": "gpt-5.5", "started_at": 1793600000,
         "last_active": 1793600900, "input_tokens": 5000, "output_tokens": 600, "estimated_cost_usd": 0.03, "parent_session_id": "api-0",
         "has_model_config": true}}
        """)
        let facts = try #require(SessionFacts.parse(answer))
        #expect(facts.id == "api-1")
        #expect(facts.parentID == "api-0")
        #expect(facts.provider == nil && facts.folder == nil && facts.reasoningEffort == nil, "the API doesn't say these")
        #expect(SessionCost(facts) == .estimated(0.03))
    }

    @Test func anAnswerWithoutAnIDIsNoSession() throws {
        #expect(SessionFacts.parse(try json(#"{"detail": "Session not found"}"#)) == nil)
    }

    // MARK: - Cost

    @Test func aCostNobodyKnowsIsNeverZeroDollars() {
        var facts = SessionFacts(id: "s")
        #expect(SessionCost(facts) == .notReported, "nothing said")
        #expect(SessionDetailsView.costText(SessionCost(facts)) != SessionDetailsView.costText(.actual(0.001)))

        facts.costStatus = "unknown"
        #expect(SessionCost(facts) == .unpriced, "Hermes has no price for the model")

        facts.costStatus = "included"
        facts.estimatedCost = 0
        #expect(SessionCost(facts) == .included, "a subscription's zero is 'included'")

        facts.costStatus = nil
        #expect(SessionCost(facts) == .noCharge, "a zero without a reason is 'none charged', not $0.00")
        #expect(SessionCost(facts).amount == nil)
    }

    @Test func aBillBeatsAnEstimate() {
        var facts = SessionFacts(id: "s")
        facts.estimatedCost = 0.5
        facts.actualCost = 0.42
        facts.costStatus = "actual"
        #expect(SessionCost(facts) == .actual(0.42))
        facts.costStatus = "unknown"
        #expect(SessionCost(facts) == .actual(0.42), "a bill came in for a model without a list price")
    }

    // MARK: - Lineage

    private func session(_ id: String, parent: String? = nil, compressed: Bool = false, branched: Bool = false, title: String? = nil) -> SessionFacts {
        var facts = SessionFacts(id: id)
        facts.parentID = parent
        facts.endReason = compressed ? "compression" : nil
        facts.branched = branched
        facts.title = title
        return facts
    }

    @Test func eachParentThatFilledUpCountsAsASummary() {
        let now = session("c", parent: "b")
        let parents = [session("b", parent: "a", compressed: true), session("a", compressed: true)]
        let lineage = SessionLineage.from(start: now, parents: parents, limitReached: false)
        #expect(lineage.compressions == 2)
        #expect(lineage.rootID == "a")
        #expect(!lineage.more && lineage.branchedFrom == nil)
    }

    @Test func aParentThatEndedOtherwiseEndsTheChain() {
        let now = session("c", parent: "b")
        let lineage = SessionLineage.from(start: now, parents: [session("b", parent: "a")], limitReached: false)
        #expect(lineage.compressions == 0, "a parent that didn't fill up isn't a summary")
    }

    @Test func aBranchNamesWhereItCameFrom() {
        let now = session("fork", parent: "orig", branched: true)
        let lineage = SessionLineage.from(start: now, parents: [session("orig", title: "Trip to Lisbon")], limitReached: false)
        #expect(lineage.branchedFrom == "Trip to Lisbon")
        #expect(lineage.compressions == 0)
    }

    @Test func stoppingAtTheLimitSaysThereIsMore() {
        let parents = (0 ..< SessionDetailsModel.lineageLimit).map { session("p\($0)", parent: "p\($0 + 1)", compressed: true) }
        let lineage = SessionLineage.from(start: session("now", parent: "p0"), parents: parents, limitReached: true)
        #expect(lineage.compressions == SessionDetailsModel.lineageLimit)
        #expect(lineage.more)
    }

    @Test func aSessionWithNoParentHasNoLineage() {
        #expect(SessionLineage.from(start: session("only"), parents: [], limitReached: false) == SessionLineage())
    }

    // MARK: - What this device saw

    @Test func toolsAreCountedByNameWithTheirFailures() {
        var reply = Message(role: .assistant, text: "done")
        reply.tools = [ToolActivity(name: "terminal", status: .completed), ToolActivity(name: "terminal", status: .failed),
                       ToolActivity(name: "read_file", status: .completed), ToolActivity(name: "", status: .completed)]
        var second = Message(role: .assistant, text: "again")
        second.tools = [ToolActivity(name: "terminal", status: .completed)]
        var fromBot = Message(role: .user, text: "from another bot")
        fromBot.delivered = Delivered(kind: .message, profile: "ops", name: "Home")
        let activity = SessionActivity.from([Message(role: .user, text: "hi"), reply, fromBot, second])
        #expect(activity.messages == 4)
        #expect(activity.yourMessages == 1, "another bot's message isn't the person's")
        #expect(activity.replies == 2)
        #expect(activity.tools.map(\.name) == ["terminal", "read_file"], "most used first; a nameless step isn't a tool")
        #expect(activity.tools.first?.count == 3 && activity.tools.first?.failed == 1)
        #expect(activity.toolCalls == 4 && activity.toolFailures == 1)
    }

    @Test func onlyRepliesTimedHereCountForTimeAndSpeed() {
        let sent = Date(timeIntervalSince1970: 1_000)
        var timed = Message(role: .assistant, text: "timed")
        timed.metrics = TurnMetrics(sentAt: sent, firstTokenAt: sent.addingTimeInterval(1), completedAt: sent.addingTimeInterval(11),
                                    usage: TokenUsage(input: 100, output: 500, cached: nil))
        let loaded = Message(role: .assistant, text: "loaded from the server")
        let activity = SessionActivity.from([timed, loaded])
        #expect(activity.timedReplies == 1)
        #expect(activity.replyTime == 11)
        #expect(activity.tokensPerSecond == 50)
    }
}
