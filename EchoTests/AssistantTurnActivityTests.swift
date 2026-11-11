import Foundation
import Testing
@testable import Echo

/// A Hermes turn can arrive as several assistant messages. The transcript presents their work once.
struct AssistantTurnActivityTests {
    private func tool(_ name: String) -> ToolActivity {
        ToolActivity(name: name, status: .completed)
    }

    @Test func repeatedAssistantMessagesShareOneActivityDisclosure() throws {
        let question = Message(role: .user, text: "Find the answer.")
        var first = Message(role: .assistant, text: "")
        first.reasoning = "I should search first."
        first.tools = [tool("web_search"), tool("web_extract")]
        var second = Message(role: .assistant, text: "")
        second.reasoning = "I should verify that."
        second.tools = [tool("read_file")]
        let answer = Message(role: .assistant, text: "Here is the answer.")

        let layout = AssistantTurnActivity.layout([question, first, second, answer])
        let firstPlacement = try #require(layout[first.id])
        let secondPlacement = try #require(layout[second.id])
        let answerPlacement = try #require(layout[answer.id])

        #expect(firstPlacement.showsSpeaker)
        #expect(!secondPlacement.showsSpeaker && !answerPlacement.showsSpeaker,
                "one assistant heading represents the turn")
        #expect(firstPlacement.activity == nil && secondPlacement.activity == nil,
                "the repeated per-message folds are suppressed")
        let activity = try #require(answerPlacement.activity)
        #expect(activity.toolCount == 3 && activity.thoughtCount == 2)
        let summary = String(localized: "\(3) tools") + " · " + String(localized: "\(2) thoughts")
        #expect(activity.completedLabel == String(localized: "Used \(summary)"))
        #expect(activity.segments.map(\.messageID) == [first.id, second.id],
                "expanding keeps every activity segment in chronological order")
    }

    @Test func aRunningTurnShowsItsCurrentActivityAfterEarlierCommentary() throws {
        let question = Message(role: .user, text: "Keep looking.")
        var commentary = Message(role: .assistant, text: "I found one lead.")
        commentary.tools = [tool("web_search")]
        var current = Message(role: .assistant, text: "")
        current.reasoning = "Checking the primary source."
        current.tools = [ToolActivity(name: "web_extract", status: .running)]

        let layout = AssistantTurnActivity.layout([question, commentary, current], liveMessageID: current.id)

        #expect(layout[commentary.id]?.activity == nil)
        #expect(layout[current.id]?.activity?.toolCount == 2,
                "the open, live disclosure follows the current row instead of the earlier text")
        #expect(layout[commentary.id]?.isLiveTurn == true,
                "the one speaker heading keeps the turn's live indicator")
    }

    /// From the server, text written beside a tool call is its own row: it goes in the turn's
    /// fold, and only the answer keeps a bubble (11-10).
    @Test func workingRowsFoldIntoTheTurn() throws {
        let question = Message(role: .user, text: "When is my flight?")
        var working = Message(role: .assistant, text: "Let me check the calendar.")
        working.tools = [tool("phone_calendar_events")]
        let answer = Message(role: .assistant, text: "July 8.")
        let layout = AssistantTurnActivity.layout([question, working, answer])
        #expect(layout[working.id]?.foldsText == true)
        #expect(layout[answer.id]?.foldsText == false)
        let activity = try #require(layout[answer.id]?.activity)
        #expect(activity.segments.first?.notes == [WorkingNote(text: "Let me check the calendar.", afterTools: 0)])
        // A row with no tools keeps its words.
        let plain = Message(role: .assistant, text: "One more thing.")
        #expect(AssistantTurnActivity.layout([question, plain, answer])[plain.id]?.foldsText == false)
    }

    @Test func aCompletedReplyEndsBeforeAnAssistantOnlyTurn() throws {
        let completed = Message(role: .assistant, text: "The page is ready.")
        var next = Message(role: .assistant, text: "")
        next.beginsAssistantTurn = true
        next.reasoning = "Updating the page after its button was tapped."

        let layout = AssistantTurnActivity.layout([completed, next], liveMessageID: next.id)

        #expect(layout[completed.id]?.isGrouped == false)
        #expect(layout[next.id]?.showsSpeaker == true,
                "a turn started without a user row must not merge into the previous answer")

        let record = ConversationRecord(id: UUID(), title: "Page", createdAt: .now, updatedAt: .now,
                                        transport: .hermesSessions, serverSessionID: "s1",
                                        messages: [completed, next], assistantTurnStarts: [next.id])
        let reopened = try JSONDecoder().decode(ConversationRecord.self, from: JSONEncoder().encode(record))
        #expect(reopened.assistantTurnStarts == [next.id], "the display boundary survives a relaunch")
    }
}
