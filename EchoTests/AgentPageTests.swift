import Foundation
import Testing
@testable import Echo

/// Pages the agent makes for the chat (`::preview{file=…}`, `AgentPage`): found in a reply,
/// fetched as pages, framed as the desktop app frames them, and what they send goes to the agent
/// with no message of the person's for it.
@MainActor
struct AgentPageTests {
    // MARK: In a reply

    @Test func aPreviewOfAnHTMLFileIsAPageAndAnythingElseAFile() {
        let found = ServeMedia.candidates(in: "The chart:\n::preview{file=\"charts/rain.html\"}\nand ::preview{file='/tmp/pic.png'} MEDIA:/tmp/table.html")
        #expect(found.map(\.path) == ["/tmp/table.html", "charts/rain.html", "/tmp/pic.png"])
        #expect(found.map(\.isPage) == [false, true, false], "only a ::preview of a web page is shown live; a MEDIA: page is a file")
        #expect(ServeMedia.candidates(in: "std::preview{file=\"x.html\"}").isEmpty, "not where a word doesn't start")
        #expect(ServeMedia.named(in: "Here.\n\n::preview{file=\"rain.html\"}").text == "Here.")
    }

    @Test func neitherSpokenNorShownAsText() {
        let reply = "Here's the rain.\n::preview{file=\"rain.html\"}"
        #expect(PlainText.display(reply) == "Here's the rain.")
        #expect(PlainText.spoken(reply) == "Here's the rain.\npage attached")
    }

    @Test func aPageKeepsWhereItIsFrom() throws {
        let page = AgentPage.attachment(Attachment(kind: .other, filename: "rain.html", mimeType: "application/xhtml+xml", data: Data("<p>hi</p>".utf8)),
                                        from: "charts/rain.html")
        #expect(page.page == "charts/rain.html" && page.kind == .text && page.mimeType == "text/html")
        let encoder = JSONEncoder()
        encoder.userInfo[.inlineAttachmentData] = true
        let back = try JSONDecoder().decode(Attachment.self, from: encoder.encode(page))
        #expect(back.page == "charts/rain.html" && back.data == page.data)
        let file = try JSONDecoder().decode(Attachment.self, from: encoder.encode(Attachment(kind: .text, filename: "a.md", mimeType: "text/markdown", data: Data("x".utf8))))
        #expect(file.page == nil)
    }

    // MARK: Framed

    @Test func theAppsLookComesFirstAndAfterTheDoctype() {
        let prelude = PageChrome.prelude(vars: [("--accent", "#FF0000")], dark: true, monospaced: false)
        #expect(prelude.hasPrefix("<style>:root{color-scheme:dark;--accent:#FF0000}"))
        #expect(prelude.contains("background:transparent") && prelude.contains("margin:0"))
        let framed = PageChrome.framed("<!DOCTYPE html>\n<html><body>x</body></html>", prelude: prelude)
        #expect(framed.hasPrefix("<!DOCTYPE html><meta name=\"viewport\""), "standards mode kept, and drawn for the phone's width")
        #expect(framed.contains(prelude + "\n<html>"))
        // A page that says how wide it is keeps its own; one with no doctype gets the look first.
        let own = PageChrome.framed("<meta name='viewport' content='width=600'><p>x</p>", prelude: prelude)
        #expect(own == prelude + "<meta name='viewport' content='width=600'><p>x</p>")
    }

    @Test func coloursInTheAppearanceTheyAreDrawnIn() {
        #expect(PageChrome.css(.white, dark: false) == "#FFFFFF")
        #expect(PageChrome.css(.primary, dark: true) == "#FFFFFF" && PageChrome.css(.primary, dark: false) == "#000000")
        #expect(PageChrome.css(.black.opacity(0.5), dark: false) == "rgba(0,0,0,0.500)")
    }

    // MARK: What a page sends

    @Test func aSentenceAtTheSpeedOfAHand() {
        let now = Date()
        #expect(PageIntent.evaluate("  Show Porto  ", now: now, lastAccepted: nil) == .accept("Show Porto"))
        #expect(PageIntent.evaluate("  ", now: now, lastAccepted: nil) == .reject(.init(error: "invalid")))
        #expect(PageIntent.evaluate(42, now: now, lastAccepted: nil) == .reject(.init(error: "invalid")))
        #expect(PageIntent.evaluate(String(repeating: "a", count: 501), now: now, lastAccepted: nil) == .reject(.init(error: "too_long", maxLength: 500)),
                "refused whole, never cut short")
        #expect(PageIntent.evaluate("again", now: now, lastAccepted: now.addingTimeInterval(-0.25)) == .reject(.init(error: "throttled", retryAfterMs: 750)))
        #expect(PageIntent.evaluate("again", now: now, lastAccepted: now.addingTimeInterval(-1)) == .accept("again"))
        #expect(PageIntent.Ack.ok.object["ok"] as? Bool == true)
        #expect(PageIntent.Ack(error: "too_long", maxLength: 500).object["maxLength"] as? Int == 500)
    }

    @Test func onTheHermesAPIItSaysWhereItIsFromAndIsLeftOut() {
        var request = TurnRequest(userText: "Show Porto", history: [], sessionID: "s", model: nil, instructions: nil)
        #expect(PageTurn.text(of: request) == "Show Porto")
        request.fromPage = true
        #expect(PageTurn.text(of: request) == "[From the page in the chat] Show Porto")
        #expect(BotMessages.userMessage(text: PageTurn.text(of: request), displayKind: nil, displayText: nil, at: .now) == nil)
        #expect(BotMessages.userMessage(text: "Show Porto", displayKind: nil, displayText: nil, at: .now)?.text == "Show Porto")
        #expect(HermesSessionsTransport.clientHint.contains("::preview{file=") && HermesSessionsTransport.clientHint.contains("data-hermes-send"))
    }

    // MARK: In a conversation

    /// Answers each turn with the next reply, and keeps what it was sent.
    final class Host: HermesTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String]
        private var kept: [TurnRequest] = []
        init(_ replies: [String]) { self.replies = replies }
        var requests: [TurnRequest] { lock.withLock { kept } }
        nonisolated func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
            let reply = lock.withLock { () -> String in
                kept.append(request)
                return replies.isEmpty ? "ok" : replies.removeFirst()
            }
            return AsyncThrowingStream { continuation in
                continuation.yield(.sessionID("stored-1"))
                continuation.yield(.textDelta(reply))
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }

    private func dataURL(_ html: String) -> String { "data:text/html;base64,\(Data(html.utf8).base64EncodedString())" }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() > deadline { Issue.record("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aPageArrivesLiveAndWhatItSendsGetsItAnswered() async throws {
        let settings = Settings(defaults: UserDefaults(suiteName: "page-\(UUID().uuidString)")!)
        settings.transport = .hermesServe
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "page-\(UUID().uuidString)"))
        let host = Host(["Here's the rain.\n\n::preview{file=\"rain.html\"}", "Done."])
        let c = Conversation(settings: settings, store: store, transportOverride: host)
        var files = ["rain.html": dataURL("<p>Lisbon</p>")]
        c.fetchServerFile = { path, _ in files[path] }

        for await _ in c.send("Show me the rain") {}
        try await waitUntil("the reply to settle") { !c.isStreaming }
        let reply = try #require(c.messages.last)
        #expect(reply.text == "Here's the rain.")
        let page = try #require(reply.attachments.first)
        #expect(page.page == "rain.html" && String(decoding: page.data, as: UTF8.self) == "<p>Lisbon</p>")

        // The page's button: the agent writes the page again.
        files["rain.html"] = dataURL("<p>Porto</p>")
        let count = c.messages.count
        #expect(c.sendFromPage("Show Porto instead", page: "rain.html", in: reply.id) == .sent)
        try await waitUntil("the page's turn to settle") { !c.isStreaming && c.messages.count == count + 1 }
        let sent = try #require(host.requests.last)
        #expect(sent.fromPage && sent.userText == "Show Porto instead")
        #expect(!c.messages.contains { $0.role == .user && $0.text == "Show Porto instead" }, "no bubble for what the page sent")
        #expect(c.messages.last?.text == "Done.")
        let again = try #require(c.messages.first { $0.id == reply.id }?.attachments.first)
        #expect(String(decoding: again.data, as: UTF8.self) == "<p>Porto</p>", "the page is read again")
        #expect(again.page == "rain.html")
    }

    @Test func notWhileTheAgentIsAnsweringNorOutsideAConversationOnTheServer() async throws {
        let settings = Settings(defaults: UserDefaults(suiteName: "page-\(UUID().uuidString)")!)
        settings.transport = .hermesServe
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "page-\(UUID().uuidString)"))
        let c = Conversation(settings: settings, store: store, transportOverride: ConversationLifecycleTests.ScriptedTransport([.textDelta("…")], hang: true))
        #expect(c.sendFromPage("Show Porto", page: "rain.html", in: UUID()) == .unavailable, "never the first message of a conversation")
        c.send("Take your time")
        #expect(c.isStreaming)
        #expect(c.sendFromPage("Show Porto", page: "rain.html", in: UUID()) == .busy)
        c.cancel()
        settings.transport = .chatCompletions
        #expect(c.sendFromPage("Show Porto", page: "rain.html", in: UUID()) == .unavailable)
    }
}
