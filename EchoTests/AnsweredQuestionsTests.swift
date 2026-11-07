import Foundation
import Testing
@testable import Echo

/// GitHub issue 57: questions answered in the chat show with their answers.
struct AnsweredQuestionsTests {
    private func request(_ questions: [(String, String)], batch: Bool) -> ClarifyRequest {
        ClarifyRequest(id: "c1", questions: questions.map { ClarifyQuestion(id: $0.0, question: $0.1, choices: [], multiSelect: false) }, isBatch: batch)
    }

    @Test func aClarifyAnswerBecomesARowUnderItsQuestion() {
        let rows = AnsweredQuestions.rows(for: request([("", "Which city?")], batch: false), answers: ["": "Lisbon"])
        #expect(rows.count == 1)
        #expect(rows.first?.text == "Lisbon" && rows.first?.answering == "Which city?")
        #expect(rows.first?.role == .user && rows.first?.isSteer == true, "said into the turn, not a question of its own")
    }

    @Test func aBatchGivesARowPerAnsweredQuestionInOrder() {
        let asked = request([("q1", "Which city?"), ("q2", "How many nights?"), ("q3", "Anything else?")], batch: true)
        let rows = AnsweredQuestions.rows(for: asked, answers: ["q2": "3", "q1": "Porto", "q3": "  "])
        #expect(rows.map(\.answering) == ["Which city?", "How many nights?"], "a skipped question leaves no row")
        #expect(rows.map(\.text) == ["Porto", "3"])
    }

    @Test func aCardsQuestionIsItsTitle() {
        let titled = ReplyCard.choice(.init(title: "Which hotel?", options: [.init(title: "A"), .init(title: "B")], multiple: false))
        let untitled = ReplyCard.choice(.init(title: nil, options: [.init(title: "Tea"), .init(title: "Coffee")], multiple: false))
        #expect(AnsweredQuestions.question(of: titled) == "Which hotel?")
        #expect(AnsweredQuestions.question(of: untitled) == "Tea · Coffee")
        #expect(AnsweredQuestions.question(of: .time(.init(place: nil, timeZone: nil))) == nil, "not a card that asks")
    }

    @Test func answerRowsAreKeptWhenTheChatIsReadAgain() {
        let question = Message(role: .user, text: "Book me a trip", createdAt: .now.addingTimeInterval(-60))
        var answer = Message(role: .user, text: "Lisbon", createdAt: .now.addingTimeInterval(-30))
        answer.isSteer = true
        answer.answering = "Which city?"
        let reply = Message(role: .assistant, text: "Booked.", createdAt: .now)
        // The host has the question and the reply, not the answer given on the side.
        let host = [Message(role: .user, text: "Book me a trip", createdAt: question.createdAt), Message(role: .assistant, text: "Booked.", createdAt: reply.createdAt)]
        let merged = Conversation.keepingAsides(of: [question, answer, reply], in: host)
        #expect(merged.map(\.text) == ["Book me a trip", "Lisbon", "Booked."])
        #expect(merged[1].answering == "Which city?")
    }

    @Test func answersFromATurnHermesNeverSavedAreLetGo() {
        var answer = Message(role: .user, text: "Yes, fetch it now", createdAt: .now.addingTimeInterval(-7200))
        answer.isSteer = true
        answer.answering = "Shall I start?"
        // Carried into a new chat: nothing of the turn before it.
        let fresh = [Message(role: .user, text: "Hello", createdAt: .now.addingTimeInterval(-60)), Message(role: .assistant, text: "Hi.", createdAt: .now)]
        #expect(Conversation.keepingAsides(of: [answer], in: fresh).map(\.text) == ["Hello", "Hi."])
        // The turn's question saved, its reply not: the next message is the person's.
        let lost = [Message(role: .user, text: "Pick a model", createdAt: .now.addingTimeInterval(-7300))] + fresh
        #expect(Conversation.keepingAsides(of: [answer], in: lost).map(\.text) == ["Pick a model", "Hello", "Hi."])
        // No reply yet, but a turn of a minute ago may still be going.
        var recent = answer
        recent.createdAt = .now.addingTimeInterval(-60)
        let going = [Message(role: .user, text: "Pick a model", createdAt: .now.addingTimeInterval(-120))]
        #expect(Conversation.keepingAsides(of: [recent], in: going).count == 2)
        #expect(Conversation.keepingAsides(of: [answer], in: [Message(role: .user, text: "Pick a model", createdAt: .now.addingTimeInterval(-7300))]).count == 1, "an hour on, it's gone")
    }

    @Test func theQuestionIsSavedWithTheMessage() throws {
        var message = Message(role: .user, text: "The Savoy")
        message.answering = "Which hotel?"
        let back = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message))
        #expect(back.answering == "Which hotel?")
    }
}
