import Foundation
import Testing
import UserNotifications
@testable import Echo

/// Ideas from the agent (Redde's plugin 1.9, `suggest_to_user`; asked 2026-10-28): a note of them,
/// as the plugin seals it, becomes cards; taken or put away, a card goes; after three days it goes
/// by itself.
struct AgentIdeasTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "ideas-\(UUID().uuidString)")! }

    /// What `core.ideas_note` sends, opened.
    private func note(_ ideas: [[String: String]], offer: String = "0123456789abcdef", at: Double = Date.now.timeIntervalSince1970) throws -> PushNote {
        let json: [String: Any] = ["v": 1, "k": "ideas", "at": at, "n": "dchermes", "p": "ops", "d": "Home", "i": offer, "y": ideas]
        return try JSONDecoder().decode(PushNote.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func aNoteOfIdeasBecomesCards() throws {
        let store = defaults()
        let offered = try note([["t": "Book the vet for Pickles", "w": "His jab is due Friday", "r": "Book Pickles in at the vet on Thursday"],
                                ["r": "Order more coffee beans"], ["t": "No request"]])
        #expect(offered.kind == .ideas)
        #expect(AgentIdea.take(offered, in: store))
        let cards = AgentIdea.all(in: store)
        #expect(cards.map(\.title) == ["Book the vet for Pickles", "Order more coffee beans"], "a heading from the request when none; none without a request")
        #expect(cards.first?.why == "His jab is due Friday" && cards.first?.agent == "Home" && cards.first?.profile == "ops")
        // The same offer again (a notification delivered twice) adds nothing.
        AgentIdea.take(offered, in: store)
        #expect(AgentIdea.all(in: store).count == 2)
        AgentIdea.remove(cards[0].id, in: store)
        #expect(AgentIdea.all(in: store).map(\.title) == ["Order more coffee beans"])
    }

    /// Taken, the agent gets the request and why it offered it, in the new chat.
    @Test func aTakenIdeaCarriesItsReason() {
        let idea = AgentIdea(id: "o/0", profile: "default", agent: "Sol", title: "Book the vet for Pickles",
                             why: "His jab is due Friday", request: "Book Pickles in at the vet on Thursday", at: .now)
        #expect(AgentIdea.message(for: idea) == "Book Pickles in at the vet on Thursday\n\n(Your idea, \"Book the vet for Pickles\": His jab is due Friday.)")
        var plain = idea
        plain.why = nil
        #expect(AgentIdea.message(for: plain) == "Book Pickles in at the vet on Thursday")
    }

    @Test func otherNotesAreNotIdeas() throws {
        let store = defaults()
        let widget = try JSONDecoder().decode(PushNote.self, from: Data(#"{"v":1,"k":"widget","b":"Hi"}"#.utf8))
        #expect(!AgentIdea.take(widget, in: store))
        #expect(AgentIdea.all(in: store).isEmpty)
    }

    @Test func theNewestComeFirstAndOldOnesGo() throws {
        let store = defaults()
        let old = Date.now.addingTimeInterval(-4 * 86_400).timeIntervalSince1970
        AgentIdea.take(try note([["r": "Something from last week"]], offer: "old", at: old), in: store)
        AgentIdea.take(try note([["r": "Water the plants"]], offer: "a"), in: store)
        AgentIdea.take(try note([["r": "Renew the domain"]], offer: "b"), in: store)
        #expect(AgentIdea.all(in: store).map(\.request) == ["Renew the domain", "Water the plants"])
        for n in 0 ..< 30 { AgentIdea.take(try note([["r": "Idea \(n)"]], offer: "o\(n)"), in: store) }
        #expect(AgentIdea.all(in: store).count == AgentIdea.most)
    }
}

/// The ideas notification's title has a name and a count: its plural form goes by the count.
struct AgentIdeasTitleTests {
    @Test func oneIdeaIsOneIdea() throws {
        func title(_ ideas: Int) throws -> String {
            let json: [String: Any] = ["v": 1, "k": "ideas", "d": "Sol", "y": Array(repeating: ["r": "Do it"], count: ideas)]
            let note = try JSONDecoder().decode(PushNote.self, from: JSONSerialization.data(withJSONObject: json))
            let content = UNMutableNotificationContent()
            _ = note.fill(content)
            return content.title
        }
        #expect(try title(1) == "Sol has 1 idea for you")
        #expect(try title(3) == "Sol has 3 ideas for you")
    }
}
