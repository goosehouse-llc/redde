import Foundation
import Testing
@testable import Echo

/// GitHub issue 21: a share and a Siri draft can ask for a new conversation. What the app does
/// with that is in `NewConversationEntryUITests`.
struct NewConversationEntryTests {
    private func payload(_ text: String, newConversation: Bool?) -> ShareInbox.Payload {
        ShareInbox.Payload(note: "", text: text, urls: [], attachments: [], createdAt: .now, newConversation: newConversation)
    }

    @Test func aShareSavedBeforeThereWasTheChoiceStaysInTheOpenConversation() throws {
        let saved = Data(#"{"note":"","text":"hello","urls":[],"attachments":[],"createdAt":"2026-10-01T10:00:00Z"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let p = try decoder.decode(ShareInbox.Payload.self, from: saved)
        #expect(p.text == "hello")
        #expect(p.newConversation == nil)
    }

    @Test func theChoiceGoesWithTheShare() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let p = try decoder.decode(ShareInbox.Payload.self, from: encoder.encode(payload("hello", newConversation: true)))
        #expect(p.newConversation == true)
    }

    @Test func sharesMadeBeforeOpeningAreOneInANewConversationIfAnyAskedForIt() throws {
        let both = try #require(ShareInbox.merged([payload("first", newConversation: false), payload("second", newConversation: true)]))
        #expect(both.text == "first\n\nsecond")
        #expect(both.newConversation == true)
        let neither = try #require(ShareInbox.merged([payload("first", newConversation: nil), payload("second", newConversation: false)]))
        #expect(neither.newConversation != true)
        #expect(ShareInbox.merged([]) == nil)
    }

    @MainActor @Test func aQuoteToAskAboutStaysInItsConversation() {
        let router = LaunchRouter()
        router.requestDraft(text: "> a line", attachments: [])
        #expect(router.consumeDraftRequest()?.newConversation == false)
        router.requestDraft(text: "from Siri", attachments: [], newConversation: true)
        #expect(router.consumeDraftRequest()?.newConversation == true)
    }
}
