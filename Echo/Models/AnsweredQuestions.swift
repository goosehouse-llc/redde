import Foundation

/// Questions answered in the chat, shown with their answers (GitHub issue 57, 2026-11-05): "after
/// a round of cards, the conversation reads as if the questions never happened". An answer row is
/// the person's message with the question it answered over it (`Message.answering`).
///
/// - A card's answer (a choice, a review, a checklist, a form) is already the person's next
///   message; it gets the card's title as its question. The title is kept by card key
///   (`CardAnswers.question(for:)`), so the message read back from the host gets it again.
/// - A question the agent asked mid-turn (Hermes's clarify) is answered on the side and leaves no
///   message on the host. Each answer becomes a row of its own, before the reply that asked, kept
///   on this device as asides are (`Conversation.keepingAsides`).
nonisolated enum AnsweredQuestions {
    /// The rows for a clarify request's answers, one per question answered, in the asked order.
    static func rows(for request: ClarifyRequest, answers: [String: String], at when: Date = .now) -> [Message] {
        request.questions.compactMap { question in
            let given = request.isBatch ? answers[question.id] : (answers[""] ?? answers.values.first)
            guard let answer = given?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else { return nil }
            var row = Message(role: .user, text: answer, createdAt: when)
            row.isSteer = true   // said into the turn under way, as a steer is: not a question of its own
            row.answering = question.question.trimmingCharacters(in: .whitespacesAndNewlines)
            return row
        }
    }

    /// What a card asked, for over its answer: its title; a choice with none, its options.
    static func question(of card: ReplyCard) -> String? {
        let asked: String? = switch card {
        case let .choice(c): c.title?.nilIfEmpty ?? c.options.map(\.title).joined(separator: " · ").nilIfEmpty
        case let .review(r): r.title
        case let .checklist(c): c.title
        case let .form(f): f.title
        default: nil
        }
        return asked?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty.map { String($0.prefix(200)) }
    }
}
