import Foundation
import Testing
@testable import Echo

/// A bot at work on what another asked of it, read from its chat (asked 2026-11-08).
struct HandoffTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    private var asked: [Handoff.Row] {
        [.init(role: "user", text: "What's the weather?", at: at(-3600)),
         .init(role: "assistant", text: "Sunny.", at: at(-3590)),
         .init(role: "user", text: "Message from 🤖 Sol (@hermes): Check why the backup failed last night.", at: at(-60))]
    }

    @Test func justAskedIsWorkingWithNoStepYet() throws {
        let progress = try #require(Handoff.progress(asked, now: now))
        #expect(progress.phase == .working)
        #expect(progress.from == "Sol")
        #expect(progress.step == nil && progress.steps == 0)
    }

    @Test func itsNewestStepIsWhatItIsDoing() throws {
        let rows = asked + [.init(role: "assistant", text: "", tools: ["read_file"], at: at(-50)),
                            .init(role: "tool", text: "…", at: at(-49)),
                            .init(role: "assistant", text: "Looking at the log.", tools: ["terminal"], at: at(-20)),
                            .init(role: "tool", text: "…", at: at(-18))]
        let progress = try #require(Handoff.progress(rows, now: now))
        #expect(progress.phase == .working)
        #expect(progress.step == Handoff.step("terminal"))
        #expect(progress.steps == 2)
        #expect(progress.lastActive == at(-18))
    }

    @Test func anAnswerWithNoToolsIsTheEnd() throws {
        let rows = asked + [.init(role: "assistant", text: "", tools: ["terminal"], at: at(-50)),
                            .init(role: "tool", text: "…", at: at(-49)),
                            .init(role: "assistant", text: "The disk was full; I cleared it.", at: at(-10))]
        #expect(try #require(Handoff.progress(rows, now: now)).phase == .answered)
    }

    @Test func aHandOffLongQuietIsNoLongerWorking() {
        #expect(Handoff.progress(asked, now: at(Handoff.quiet + 60)) == nil)
    }

    @Test func anOlderMessageIsNotThisHandOff() {
        #expect(Handoff.progress(asked, since: at(90), now: now) == nil)
        #expect(Handoff.progress(asked, since: at(-30), now: now) != nil, "A little before, for the two clocks")
    }

    @Test func aChatNobodyAskedAnythingOfHasNone() {
        #expect(Handoff.progress([.init(role: "user", text: "Hi", at: at(-5))], now: now) == nil)
    }

    @Test func theBotsAReplyAskedAreItsMessageAgentCalls() {
        var reply = Message(role: .assistant, text: "I've asked Scout.")
        reply.tools = [ToolActivity(name: "message_agent", preview: "@scout", status: .completed, startedAt: at(-5), args: "message: Which trailhead?\ntarget: @scout"),
                       ToolActivity(name: "message_agent", preview: "@scout", status: .completed, args: "message: And parking?\ntarget: scout"),
                       ToolActivity(name: "message_agent", status: .failed, args: "target: quill"),
                       ToolActivity(name: "terminal", status: .completed, args: "command: ls")]
        let targets = Handoff.targets(in: reply)
        #expect(targets.map(\.target) == ["scout"])
        #expect(targets.first?.at == at(-5))
    }

    @Test func toolCallsAreReadAsAListOrAsJSONText() throws {
        let list = try JSONValue.parse(Data(#"[{"id":"1","type":"function","function":{"name":"terminal","arguments":"{}"}}]"#.utf8))
        #expect(BotHandoffs.toolNames(list) == ["terminal"])
        #expect(BotHandoffs.toolNames(.string(#"[{"function":{"name":"web_search"}}]"#)) == ["web_search"])
        #expect(BotHandoffs.toolNames(nil).isEmpty)
    }

    /// Sol's card for Coder (2026-11-08): claude_card names no one, and its answer may not be here; the reply names the card.
    @Test func aCardForAnotherBotIsReadFromTheCallOrTheReply() {
        var reply = Message(role: .assistant, text: "The card is made, sir — t_10e4a128, creating lookout and paper.", createdAt: at(0))
        reply.tools = [ToolActivity(name: "claude_card", status: .completed, startedAt: at(-2), args: "repo: hermes\nrequest: Make two bots")]
        let cards = Handoff.cards(in: reply)
        #expect(cards.count == 1)
        #expect(cards.first?.id == "t_10e4a128")
        #expect(cards.first?.assignee == "claude")
        #expect(cards.first?.at == at(-2))

        var made = Message(role: .assistant, text: "Done.")
        made.tools = [ToolActivity(name: "kanban_create", status: .completed, args: "assignee: ops\ntitle: Restart Jellyfin",
                                   output: #"{"task_id": "t_ab12cd34ef", "subscribed": true}"#),
                      ToolActivity(name: "kanban_create", status: .failed, args: "assignee: ops")]
        let found = Handoff.cards(in: made)
        #expect(found.map(\.id) == ["t_ab12cd34ef"])
        #expect(found.first?.assignee == "ops")

        var unnamed = Message(role: .assistant, text: "Handed to Coder.")
        unnamed.tools = [ToolActivity(name: "claude_card", status: .completed)]
        #expect(Handoff.cards(in: unnamed).first?.id == nil, "Found on the board by its time instead")
    }
}
