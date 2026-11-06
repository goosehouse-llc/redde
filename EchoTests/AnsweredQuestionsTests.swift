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

    @Test func theQuestionIsSavedWithTheMessage() throws {
        var message = Message(role: .user, text: "The Savoy")
        message.answering = "Which hotel?"
        let back = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message))
        #expect(back.answering == "Which hotel?")
    }
}
